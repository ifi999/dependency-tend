import Foundation

public struct HomebrewAdapter: PackageManagerAdapter {
    public let id = ManagerID.homebrew
    let brewURL: URL?
    let runner: any CommandRunning
    /// INSTALL_RECEIPT.json 읽기용. nil이면 부모-자식 연결 없이 동작 (best-effort)
    let cellarURL: URL?

    public init(brewURL: URL?, runner: any CommandRunning, cellarURL: URL? = nil) {
        self.brewURL = brewURL
        self.runner = runner
        self.cellarURL = cellarURL
    }

    public func isAvailable() -> Bool { brewURL != nil }

    /// GUI 최소 PATH 보완: brew prefix bin + 표준 경로 (brew가 띄우는 git/curl도 이 PATH를 쓴다)
    private var brewEnvironment: [String: String] {
        guard let brew = brewURL else { return [:] }
        return ["PATH": "\(brew.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    public func scan(now: Date) async throws -> AdapterScan {
        guard let brew = brewURL else { throw AdapterError.toolNotFound("brew") }
        let listF = try await runner.run(brew, arguments: ["list", "--formula", "--versions"],
                                         environment: brewEnvironment, timeout: 120)
        guard listF.exitCode == 0 else {
            throw AdapterError.commandFailed("brew list --formula: \(listF.stderr)")
        }
        let listC = try await runner.run(brew, arguments: ["list", "--cask", "--versions"],
                                         environment: brewEnvironment, timeout: 120)
        guard listC.exitCode == 0 else {
            throw AdapterError.commandFailed("brew list --cask: \(listC.stderr)")
        }
        // 직접 설치(leaves) vs 의존성 구분 — 의존성은 패널에서 부모 아래에 접힌다
        let leaves = try await runner.run(brew, arguments: ["leaves"],
                                          environment: brewEnvironment, timeout: 120)
        guard leaves.exitCode == 0 else {
            throw AdapterError.commandFailed("brew leaves: \(leaves.stderr)")
        }
        let outdated = try await runner.run(brew, arguments: ["outdated", "--json=v2"],
                                            environment: brewEnvironment, timeout: 300)
        guard outdated.exitCode == 0 else {
            throw AdapterError.commandFailed("brew outdated: \(outdated.stderr)")
        }
        let installedInfo = try? await runner.run(brew, arguments: ["info", "--json=v2", "--installed"],
                                                  environment: brewEnvironment, timeout: 120)
        let linkMetadata: [String: [String: String]]
        if let installedInfo, installedInfo.exitCode == 0 {
            linkMetadata = (try? Self.parseInstalledInfoJSON(Data(installedInfo.stdout.utf8))) ?? [:]
        } else {
            linkMetadata = [:]
        }
        let formulae = Self.parseListVersions(listF.stdout)
        let leafNames = Set(leaves.stdout.split(separator: "\n").map(String.init))
        // 부모-자식 엣지는 각 keg의 INSTALL_RECEIPT.json(실제 설치 기록)에서 읽는다.
        // 주의(실측): `brew deps`는 "현재 formula 정의" 기준이라 설치 당시와 어긋나
        // 고아가 다수 생긴다 — leaves/uses/autoremove가 보는 영수증이 정답.
        let depsMap = cellarURL.map { Self.readDepsMap(cellar: $0, formulae: formulae) } ?? [:]
        let parents = Self.dependencyParents(leaves: leafNames,
                                             depsMap: depsMap,
                                             installed: Set(formulae.map(\.name)))
        let merged = Self.merge(formulae: formulae,
                                casks: Self.parseListVersions(listC.stdout),
                                outdated: try Self.parseOutdatedJSON(Data(outdated.stdout.utf8)),
                                leaves: leafNames,
                                parents: parents,
                                linkMetadata: linkMetadata)
        return AdapterScan(packages: merged)
    }

    // MARK: - 고아 의존성 (정리 스펙 §3)

    /// `brew autoremove --dry-run`으로 부모 잃은 의존성 이름을 얻는다 (brew가 안전을 보증)
    public func orphanNames() async throws -> [String] {
        guard let brew = brewURL else { return [] }
        let out = try await runner.run(brew, arguments: ["autoremove", "--dry-run"],
                                       environment: brewEnvironment, timeout: 120)
        guard out.exitCode == 0 else {
            throw AdapterError.commandFailed("brew autoremove --dry-run: \(out.stderr)")
        }
        return Self.parseAutoremoveDryRun(out.stdout)
    }

    public func autoremoveCommand() -> UpdateCommand? {
        brewURL.map {
            UpdateCommand(executable: $0, arguments: ["autoremove"], environment: brewEnvironment)
        }
    }

    /// "==> Would autoremove N unneeded formulae:" 다음 줄들이 이름 (cleanup.rb 실측 형식)
    static func parseAutoremoveDryRun(_ text: String) -> [String] {
        var names: [String] = []
        var collecting = false
        for line in text.split(separator: "\n") {
            if line.contains("Would autoremove") {
                collecting = true
                continue
            }
            guard collecting else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("==>") { break }
            names.append(trimmed)
        }
        return names
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let brew = brewURL, pkg.manager == id else { return nil }
        if pkg.flags.contains(.cask) {
            return UpdateCommand(executable: brew, arguments: ["upgrade", "--cask", pkg.name],
                                 environment: brewEnvironment)
        }
        return UpdateCommand(executable: brew, arguments: ["upgrade", pkg.name],
                             environment: brewEnvironment)
    }

    // MARK: - 파싱 (순수 함수)

    struct OutdatedFile: Decodable {
        struct Entry: Decodable {
            let name: String
            let installedVersions: [String]
            let currentVersion: String
            let pinned: Bool
            enum CodingKeys: String, CodingKey {
                case name, pinned
                case installedVersions = "installed_versions"
                case currentVersion = "current_version"
            }
        }
        let formulae: [Entry]
        let casks: [Entry]
    }

    struct InstalledInfoFile: Decodable {
        struct Formula: Decodable {
            let name: String
            let tap: String?
            let homepage: String?
        }

        struct Cask: Decodable {
            let token: String
            let tap: String?
            let homepage: String?
        }

        let formulae: [Formula]?
        let casks: [Cask]?
    }

    static func parseOutdatedJSON(_ data: Data) throws -> OutdatedFile {
        do { return try JSONDecoder().decode(OutdatedFile.self, from: data) }
        catch { throw AdapterError.parseFailed("brew outdated JSON: \(error)") }
    }

    static func parseInstalledInfoJSON(_ data: Data) throws -> [String: [String: String]] {
        do {
            let info = try JSONDecoder().decode(InstalledInfoFile.self, from: data)
            var metadata: [String: [String: String]] = [:]
            for formula in info.formulae ?? [] {
                metadata[formula.name] = linkMetadata(name: formula.name, isCask: false,
                                                      tap: formula.tap, homepage: formula.homepage)
            }
            for cask in info.casks ?? [] {
                metadata[cask.token] = linkMetadata(name: cask.token, isCask: true,
                                                   tap: cask.tap, homepage: cask.homepage)
            }
            return metadata
        } catch {
            throw AdapterError.parseFailed("brew info JSON: \(error)")
        }
    }

    private static func linkMetadata(name: String, isCask: Bool,
                                     tap: String?, homepage: String?) -> [String: String] {
        var metadata: [String: String] = [:]
        if let tap, !tap.isEmpty {
            metadata["tap"] = tap
        }
        if usesFormulaeSite(tap: tap, isCask: isCask) {
            metadata[PackageLinkMetadata.packageURL] = PackageLinkMetadata.brewPackageURL(name: name,
                                                                                         isCask: isCask)
        }
        if let homepage = normalizedWebURL(homepage) {
            metadata[PackageLinkMetadata.homepageURL] = homepage
        }
        return metadata
    }

    private static func usesFormulaeSite(tap: String?, isCask: Bool) -> Bool {
        guard let tap, !tap.isEmpty else { return true }
        return isCask ? tap == "homebrew/cask" : tap == "homebrew/core"
    }

    private static func normalizedWebURL(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        return url.absoluteString
    }

    /// `brew list --versions` 라인 형식: "name ver1 [ver2 ...]" — 마지막 토큰이 최신 설치 버전
    static func parseListVersions(_ text: String) -> [(name: String, version: String)] {
        text.split(separator: "\n").compactMap { line in
            let tokens = line.split(separator: " ").map(String.init)
            guard tokens.count >= 2, let name = tokens.first, let version = tokens.last else { return nil }
            return (name, version)
        }
    }

    /// INSTALL_RECEIPT.json의 runtime_dependencies → 의존성 이름 목록.
    /// 깨졌거나 필드가 없으면 빈 배열 (best-effort).
    static func parseReceipt(_ data: Data) -> [String] {
        struct Receipt: Decodable {
            struct Dep: Decodable {
                let fullName: String
                enum CodingKeys: String, CodingKey { case fullName = "full_name" }
            }
            let runtimeDependencies: [Dep]?
            enum CodingKeys: String, CodingKey { case runtimeDependencies = "runtime_dependencies" }
        }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return [] }
        return (receipt.runtimeDependencies ?? []).map { dep in
            // tap 접두("user/tap/이름")는 마지막 컴포넌트만
            dep.fullName.split(separator: "/").last.map(String.init) ?? dep.fullName
        }
    }

    /// Cellar/<이름>/<버전>/INSTALL_RECEIPT.json을 읽어 이름 → 직접 의존성 맵 구성.
    /// 영수증이 없는 formula는 빈 deps (best-effort).
    static func readDepsMap(cellar: URL, formulae: [(name: String, version: String)]) -> [String: [String]] {
        let fm = FileManager.default
        var map: [String: [String]] = [:]
        for item in formulae {
            let name = item.name
            let kegDir = cellar.appendingPathComponent(name)
            let exactReceipt = kegDir.appendingPathComponent("\(item.version)/INSTALL_RECEIPT.json")
            let receiptURL: URL?
            if fm.fileExists(atPath: exactReceipt.path) {
                receiptURL = exactReceipt
            } else if let versions = try? fm.contentsOfDirectory(atPath: kegDir.path),
                      let version = versions.filter({ !$0.hasPrefix(".") }).sorted().last {
                receiptURL = kegDir.appendingPathComponent("\(version)/INSTALL_RECEIPT.json")
            } else {
                receiptURL = nil
            }
            map[name] = receiptURL.flatMap { try? Data(contentsOf: $0) }.map(Self.parseReceipt) ?? []
        }
        return map
    }

    static func readDepsMap(cellar: URL, formulae: [String]) -> [String: [String]] {
        readDepsMap(cellar: cellar, formulae: formulae.map { (name: $0, version: "") })
    }

    /// 각 leaf의 전이적(transitive) 의존성 닫힘을 계산해 의존성 → 부모 leaf들 맵을 만든다.
    /// 설치되지 않은 이름은 무시. 공유 의존성은 모든 부모에 연결 (Gradle 트리처럼 중복 표시).
    static func dependencyParents(leaves: Set<String>,
                                  depsMap: [String: [String]],
                                  installed: Set<String>) -> [String: [String]] {
        var parents: [String: Set<String>] = [:]
        for leaf in leaves {
            var visited: Set<String> = []
            var queue = depsMap[leaf] ?? []
            while let dep = queue.popLast() {
                guard installed.contains(dep), !visited.contains(dep) else { continue }
                visited.insert(dep)
                if !leaves.contains(dep) { parents[dep, default: []].insert(leaf) }
                queue.append(contentsOf: depsMap[dep] ?? [])
            }
        }
        return parents.mapValues { $0.sorted() }
    }

    static func merge(formulae: [(name: String, version: String)],
                      casks: [(name: String, version: String)],
                      outdated: OutdatedFile,
                      leaves: Set<String>,
                      parents: [String: [String]],
                      linkMetadata: [String: [String: String]] = [:]) -> [PackageInfo] {
        let outF = Dictionary(uniqueKeysWithValues: outdated.formulae.map { ($0.name, $0) })
        let outC = Dictionary(uniqueKeysWithValues: outdated.casks.map { ($0.name, $0) })

        func build(_ items: [(name: String, version: String)],
                   outdatedMap: [String: OutdatedFile.Entry], isCask: Bool) -> [PackageInfo] {
            items.map { item in
                var flags: Set<PackageFlag> = isCask ? [.cask] : []
                var metadata = linkMetadata[item.name]
                    ?? Self.linkMetadata(name: item.name, isCask: isCask, tap: nil, homepage: nil)
                // 런타임(node 계열)은 글로벌 npm 트리·MCP가 올라타 있다 —
                // 원클릭으로 올리면 트리가 흔들릴 수 있어 버튼을 막는다 (사용자 피드백)
                if !isCask && (item.name == "node" || item.name.hasPrefix("node@")) {
                    flags.insert(.runtime)
                }
                // cask는 항상 직접 설치. formula는 leaves에 없으면 의존성.
                if !isCask && !leaves.contains(item.name) {
                    flags.insert(.dependency)
                    if let parentNames = parents[item.name] {
                        metadata["parents"] = parentNames.joined(separator: ",")
                    }
                }
                if let o = outdatedMap[item.name] {
                    if o.pinned { flags.insert(.pinned) }
                    return PackageInfo(name: item.name, manager: .homebrew,
                                       current: o.installedVersions.last ?? item.version,
                                       latest: o.currentVersion, status: .outdated,
                                       flags: flags, metadata: metadata)
                }
                return PackageInfo(name: item.name, manager: .homebrew,
                                   current: item.version, latest: nil, status: .upToDate,
                                   flags: flags, metadata: metadata)
            }
        }
        return (build(formulae, outdatedMap: outF, isCask: false)
                + build(casks, outdatedMap: outC, isCask: true))
            .sorted { $0.name < $1.name }
    }
}
