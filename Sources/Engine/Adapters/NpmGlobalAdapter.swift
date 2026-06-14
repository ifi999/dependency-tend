import Foundation

public struct NpmGlobalAdapter: PackageManagerAdapter {
    public let id = ManagerID.npmGlobal
    /// 설치된 모든 npm 트리 (nvm 전 버전 + homebrew/system) — 트리별로 글로벌이 따로 산다
    let tools: [ToolLocator.NpmTool]
    let runner: any CommandRunning

    public init(tools: [ToolLocator.NpmTool], runner: any CommandRunning) {
        self.tools = tools
        self.runner = runner
    }

    /// 단일 트리 호환 init (기존 호출부/테스트 유지)
    public init(tool: ToolLocator.NpmTool?, runner: any CommandRunning) {
        self.init(tools: tool.map { [$0] } ?? [], runner: runner)
    }

    public func isAvailable() -> Bool { !tools.isEmpty }

    /// 실측 함정 대응: nvm npm은 `#!/usr/bin/env node` — 해당 트리의 node bin을 PATH로 명시 주입해야
    /// GUI 최소 PATH에서도 동작한다 (없으면 exit 127)
    private func environment(for tool: ToolLocator.NpmTool) -> [String: String] {
        ["PATH": "\(tool.binDir.path):/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    public func scan(now: Date) async throws -> AdapterScan {
        guard !tools.isEmpty else { throw AdapterError.toolNotFound("npm") }
        var packages: [PackageInfo] = []
        var advisories: [ManagerAdvisory] = []
        var lastError: Error?
        var partialFailures: [String] = []
        for tool in tools {
            do {
                let tree = try await scanTree(tool, now: now)
                packages.append(contentsOf: tree.packages)
                advisories.append(contentsOf: tree.advisories)
            } catch {
                lastError = error // 한 트리가 깨져도 나머지 트리는 살린다
                partialFailures.append(Self.partialFailureMessage(for: tool, error: error))
            }
        }
        if packages.isEmpty, let lastError { throw lastError }
        if !partialFailures.isEmpty {
            advisories.append(ManagerAdvisory(
                manager: id,
                message: "일부 npm 트리를 읽지 못했습니다: \(partialFailures.joined(separator: " · "))"))
        }
        return AdapterScan(packages: packages, advisories: advisories)
    }

    private static func partialFailureMessage(for tool: ToolLocator.NpmTool, error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return "\(tool.label): \(message)"
    }

    private func scanTree(_ tool: ToolLocator.NpmTool, now: Date) async throws -> AdapterScan {
        let env = environment(for: tool)
        let ls = try await runner.run(tool.npm, arguments: ["ls", "-g", "--depth=0", "--json"],
                                      environment: env, timeout: 120)
        // npm ls는 peer-dep 문제 시 exit 1 + 유효 JSON을 낸다 — exit 0/1 허용
        guard ls.exitCode == 0 || ls.exitCode == 1, !ls.stdout.isEmpty else {
            throw AdapterError.commandFailed("npm ls (\(tool.label)): \(ls.stderr)")
        }
        let outdated = try await runner.run(tool.npm, arguments: ["outdated", "-g", "--json"],
                                            environment: env, timeout: 300)
        // 함정: npm outdated는 outdated 패키지가 있으면 exit 1 (정상 케이스)
        guard outdated.exitCode == 0 || outdated.exitCode == 1 else {
            throw AdapterError.commandFailed("npm outdated (\(tool.label)): \(outdated.stderr)")
        }
        let installed = try Self.parseLs(Data(ls.stdout.utf8))
        let latestMap = try Self.parseOutdated(Data(outdated.stdout.utf8))
        // bin 이름 수집 — MCP 참조 판정(PruneAdvisor)이 bin ≠ 패키지명 케이스를 잡을 수 있게
        let libRoot = tool.binDir.deletingLastPathComponent()
            .appendingPathComponent("lib/node_modules")

        var advisories: [ManagerAdvisory] = []
        if let major = SemVer.parse(tool.nodeVersion)?.major, Self.isNodeEOL(major: major, on: now) {
            advisories.append(ManagerAdvisory(
                manager: id,
                message: "Node v\(tool.nodeVersion)은(는) EOL입니다. node 업그레이드 후 글로벌 패키지 재설치를 권장합니다 (글로벌 패키지는 이 node 버전에 묶여 있습니다).",
                url: "https://nodejs.org/en/about/previous-releases"))
        }

        let packages: [PackageInfo] = installed.map { entry -> PackageInfo in
            let name = entry.key
            let version = entry.value
            var metadata = [PackageLinkMetadata.packageURL: PackageLinkMetadata.npmPackageURL(name: name)]
            if !tool.nodeVersion.isEmpty { metadata["node"] = tool.nodeVersion }
            metadata["tree"] = tool.label          // 패널 소그룹 + id 구분
            metadata["npmPath"] = tool.npm.path    // 업데이트 라우팅
            let bins = Self.readBinNames(libRoot: libRoot, packageName: name)
            if !bins.isEmpty { metadata["bins"] = bins.joined(separator: ",") }
            var flags: Set<PackageFlag> = []
            // npm/corepack은 사용자가 설치한 게 아니라 node 배포판에 딸려오는 번들 —
            // brew 의존성과 같은 논리로 기본 화면·뱃지·일괄에서 제외한다
            if name == "npm" || name == "corepack" {
                flags.insert(.dependency)
                metadata["bundled"] = "node"
            }
            return PackageInfo(name: name, manager: id, current: version,
                               latest: latestMap[name],
                               status: latestMap[name] != nil ? .outdated : .upToDate,
                               flags: flags,
                               metadata: metadata)
        }.sorted { (lhs: PackageInfo, rhs: PackageInfo) -> Bool in
            lhs.name < rhs.name
        }

        return AdapterScan(packages: packages, advisories: advisories)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard pkg.manager == id else { return nil }
        // 패키지가 속한 트리의 npm으로 라우팅 — 다른 트리 npm으로 설치하면 엉뚱한 곳에 들어간다
        let tool: ToolLocator.NpmTool?
        if let npmPath = pkg.metadata["npmPath"] {
            tool = tools.first { $0.npm.path == npmPath }
        } else {
            tool = tools.count == 1 ? tools.first : nil
        }
        guard let tool else { return nil }
        return UpdateCommand(executable: tool.npm, arguments: ["install", "-g", "\(pkg.name)@latest"],
                             environment: environment(for: tool))
    }

    // MARK: - 파싱 (순수 함수)

    /// `npm ls -g --depth=0 --json` → [패키지명: 설치 버전]
    static func parseLs(_ data: Data) throws -> [String: String] {
        struct Ls: Decodable {
            struct Dep: Decodable { let version: String? }
            let dependencies: [String: Dep]?
        }
        do {
            let ls = try JSONDecoder().decode(Ls.self, from: data)
            return (ls.dependencies ?? [:]).compactMapValues(\.version)
        } catch {
            throw AdapterError.parseFailed("npm ls JSON: \(error)")
        }
    }

    /// `npm outdated -g --json` → [패키지명: latest]. outdated 없으면 빈 출력 가능.
    static func parseOutdated(_ data: Data) throws -> [String: String] {
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [:] }
        struct Entry: Decodable { let latest: String? }
        do {
            let map = try JSONDecoder().decode([String: Entry].self, from: Data(trimmed.utf8))
            return map.compactMapValues(\.latest)
        } catch {
            throw AdapterError.parseFailed("npm outdated JSON: \(error)")
        }
    }

    // MARK: - bin 이름 (MCP 참조 판정용)

    /// lib/node_modules/<이름>/package.json의 bin 필드 → bin 이름 목록 (없거나 깨지면 빈 배열)
    static func readBinNames(libRoot: URL, packageName: String) -> [String] {
        let packageJSON = libRoot.appendingPathComponent(packageName)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageJSON) else { return [] }
        return parseBinNames(data)
    }

    /// bin이 맵이면 키들이 bin 이름, 문자열이면 패키지명의 마지막 컴포넌트가 bin 이름 (npm 규칙)
    static func parseBinNames(_ data: Data) -> [String] {
        struct PackageJSON: Decodable {
            let name: String?
            let bin: Bin?
            enum Bin: Decodable {
                case single, map([String: String])
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let map = try? container.decode([String: String].self) {
                        self = .map(map)
                    } else {
                        _ = try container.decode(String.self)
                        self = .single
                    }
                }
            }
        }
        guard let pkg = try? JSONDecoder().decode(PackageJSON.self, from: data) else { return [] }
        switch pkg.bin {
        case .map(let map):
            return map.keys.sorted()
        case .single:
            let last = (pkg.name ?? "").split(separator: "/").last.map(String.init)
            return last.map { [$0] } ?? []
        case nil:
            return []
        }
    }

    // MARK: - Node EOL

    /// 공식 EOL 일정. 홀수 메이저는 비-LTS(항상 EOL 취급), 테이블보다 오래된 메이저도 EOL.
    static func isNodeEOL(major: Int, on date: Date) -> Bool {
        if major % 2 == 1 { return true }
        let eolDates: [Int: DateComponents] = [
            18: DateComponents(year: 2025, month: 4, day: 30),
            20: DateComponents(year: 2026, month: 4, day: 30),
            22: DateComponents(year: 2027, month: 4, day: 30),
            24: DateComponents(year: 2028, month: 4, day: 30),
        ]
        guard let comps = eolDates[major] else { return major < 18 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)! < date
    }
}
