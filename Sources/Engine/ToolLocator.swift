import Foundation

/// GUI 앱은 로그인 셸 PATH를 상속받지 않는다 — 모든 도구를 절대경로로 해석한다.
public struct ToolLocator: Sendable {
    public let home: URL
    let brewCandidates: [String]
    let npmSystemCandidates: [String]
    let claudeCandidatesOverride: [String]?
    let toolCandidatesOverride: [String: [String]]

    let claudeSystemCandidates: [String]
    private static let nodeManagedToolNames: Set<String> = ["pnpm", "yarn", "bun", "corepack"]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                brewCandidates: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
                npmSystemCandidates: [String] = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"],
                claudeCandidates: [String]? = nil,
                claudeSystemCandidates: [String] = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
                toolCandidates: [String: [String]] = [:]) {
        self.home = home
        self.brewCandidates = brewCandidates
        self.npmSystemCandidates = npmSystemCandidates
        self.claudeCandidatesOverride = claudeCandidates
        self.claudeSystemCandidates = claudeSystemCandidates
        self.toolCandidatesOverride = toolCandidates
    }

    public func brew() -> URL? { firstExecutable(brewCandidates) }

    public func diagnostics() -> [ToolDiagnostic] {
        var rows: [ToolDiagnostic] = [
            ToolDiagnostic(id: "homebrew", name: "Homebrew", path: brew()?.path),
        ]
        let npmTools = npmInstallations()
        if npmTools.isEmpty {
            rows.append(ToolDiagnostic(id: "npm", name: "npm", path: nil,
                                       detail: "global npm tree not found"))
        } else {
            rows.append(contentsOf: npmTools.map {
                ToolDiagnostic(id: "npm:\($0.label)", name: "npm",
                               path: $0.npm.path, detail: $0.label)
            })
        }
        rows.append(contentsOf: [
            ToolDiagnostic(id: "claude", name: "Claude CLI", path: claudeCLI()?.path),
            ToolDiagnostic(id: "mas", name: "mas", path: mas()?.path),
            ToolDiagnostic(id: "pipx", name: "pipx", path: pipx()?.path),
            ToolDiagnostic(id: "uv", name: "uv", path: uv()?.path),
            ToolDiagnostic(id: "cargo", name: "cargo", path: cargo()?.path),
            ToolDiagnostic(id: "vscode", name: "VS Code CLI", path: vscodeCLI()?.path),
            ToolDiagnostic(id: "cursor", name: "Cursor CLI", path: cursorCLI()?.path),
            ToolDiagnostic(id: "pnpm", name: "pnpm", path: pnpm()?.path),
            ToolDiagnostic(id: "yarn", name: "Yarn", path: yarn()?.path),
            ToolDiagnostic(id: "bun", name: "Bun", path: bun()?.path),
        ])
        return rows
    }

    /// brew prefix의 Cellar — 각 keg의 INSTALL_RECEIPT.json(실제 설치 의존성 기록)을 읽는 데 쓴다
    public func brewCellar() -> URL? {
        brew()?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Cellar")
    }

    public func claudeCLI() -> URL? {
        if let override = claudeCandidatesOverride {
            return firstExecutable(override)
        }
        // 네이티브 설치(~/.local/bin)가 최우선 — 공식 설치기는 자가 업데이트라 가장 신선하다.
        // nvm 트리의 claude는 낡은 npm 잔재인 경우가 많아(실측 2.1.17 vs 2.1.174)
        // 구버전 CLI로 plugin update를 돌리면 "not found"로 깨진다.
        // 단, .claude/local의 레거시 래퍼보다는 nvm이 낫다 — 맨 뒤로.
        var candidates = [home.appendingPathComponent(".local/bin/claude").path]
        candidates.append(contentsOf: claudeSystemCandidates)
        candidates.append(contentsOf: versionManagerShimCandidates(named: "claude"))
        if let versioned = versionedNodeTool(named: "claude") {
            candidates.append(versioned.path)
        }
        candidates.append(home.appendingPathComponent(".claude/local/claude").path)
        return firstExecutable(candidates)
    }

    public func mas() -> URL? { tool("mas") }
    public func pipx() -> URL? { tool("pipx") }
    public func uv() -> URL? { tool("uv") }
    public func cargo() -> URL? { tool("cargo") }
    public func pnpm() -> URL? { tool("pnpm") }
    public func yarn() -> URL? { tool("yarn") }
    public func bun() -> URL? { tool("bun") }

    public func vscodeCLI() -> URL? {
        tool("code", extraCandidates: [
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
            home.appendingPathComponent("Applications/Visual Studio Code.app/Contents/Resources/app/bin/code").path,
        ])
    }

    public func cursorCLI() -> URL? {
        tool("cursor", extraCandidates: [
            "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
            home.appendingPathComponent("Applications/Cursor.app/Contents/Resources/app/bin/cursor").path,
        ])
    }

    public func claudePluginRegistry() -> URL {
        home.appendingPathComponent(".claude/plugins/installed_plugins.json")
    }

    public func claudeKnownMarketplaces() -> URL {
        home.appendingPathComponent(".claude/plugins/known_marketplaces.json")
    }

    /// MCP 서버 설정 — 최상위 mcpServers 키가 있는 파일 (실측 확인)
    public func claudeMCPConfig() -> URL {
        home.appendingPathComponent(".claude.json")
    }

    public func bunGlobalPackageJSON() -> URL {
        home.appendingPathComponent(".bun/install/global/package.json")
    }

    public struct NpmTool: Equatable, Sendable {
        public let npm: URL
        /// 실측 함정 대응: npm은 `#!/usr/bin/env node` — 실행 시 PATH에 주입할 node bin 디렉터리
        public let binDir: URL
        /// "18.19.1" 형태. 시스템 npm 폴백이면 빈 문자열.
        public let nodeVersion: String
        /// 설치 출처: "nvm" / "fnm" / "volta" / "asdf" / "mise" / "homebrew" / "system"
        public let source: String
        public init(npm: URL, binDir: URL, nodeVersion: String, source: String = "nvm") {
            self.npm = npm
            self.binDir = binDir
            self.nodeVersion = nodeVersion
            self.source = source
        }

        /// 패널 소그룹/업데이트 라우팅용 표시 라벨 (예: "v22.22.1 (homebrew)")
        public var label: String {
            nodeVersion.isEmpty ? source : "v\(nodeVersion) (\(source))"
        }
    }

    /// 설치된 **모든** npm 트리: nvm/fnm 전 버전 + shim 매니저 + 시스템(homebrew) npm.
    /// default 하나만 보면 다른 node 버전이나 매니저의 글로벌 패키지가 사각지대가 된다.
    public func npmInstallations() -> [NpmTool] {
        var tools: [NpmTool] = []
        var seenResolvedPaths = Set<String>()
        func appendUnique(_ tool: NpmTool) {
            let resolved = tool.npm.resolvingSymlinksInPath().path
            guard seenResolvedPaths.insert(resolved).inserted else { return }
            tools.append(tool)
        }

        for executable in nvmExecutables(named: "npm").sorted(by: { $0.version < $1.version }) {
            appendUnique(NpmTool(npm: executable.executable, binDir: executable.binDir,
                                 nodeVersion: executable.raw, source: "nvm"))
        }
        for executable in fnmExecutables(named: "npm").sorted(by: { $0.version < $1.version }) {
            appendUnique(NpmTool(npm: executable.executable, binDir: executable.binDir,
                                 nodeVersion: executable.raw, source: "fnm"))
        }
        for tool in npmShimInstallations() {
            appendUnique(tool)
        }
        if let system = firstExecutable(npmSystemCandidates) {
            let resolved = system.resolvingSymlinksInPath().path
            // 버전 매니저 쪽으로 링크된 시스템 npm은 중복 — 제외
            if !managedNodePrefixes().contains(where: { resolved.hasPrefix($0) }) {
                appendUnique(NpmTool(npm: system,
                                     binDir: system.deletingLastPathComponent(),
                                     nodeVersion: Self.homebrewNodeVersion(fromResolvedPath: resolved) ?? "",
                                     source: resolved.contains("/Cellar/") ? "homebrew" : "system"))
            }
        }
        return tools
    }

    /// ".../Cellar/node@22/22.22.1_3/..." → "22.22.1" (brew revision 접미 제거)
    static func homebrewNodeVersion(fromResolvedPath path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let cellarIndex = parts.firstIndex(of: "Cellar"), parts.count > cellarIndex + 2 else { return nil }
        return parts[cellarIndex + 2].split(separator: "_").first.map(String.init)
    }

    /// nvm default alias(완전 일치 → major prefix 일치) > nvm 최고 버전 > 시스템 npm 순으로 해석
    public func npm() -> NpmTool? {
        if let nvm = preferredNvmExecutable(named: "npm") {
            return NpmTool(npm: nvm.executable, binDir: nvm.binDir, nodeVersion: nvm.raw)
        }
        if let fnm = preferredFnmExecutable(named: "npm") {
            return NpmTool(npm: fnm.executable, binDir: fnm.binDir,
                           nodeVersion: fnm.raw, source: "fnm")
        }
        if let shim = npmShimInstallations().first {
            return shim
        }
        if let system = firstExecutable(npmSystemCandidates) {
            return NpmTool(npm: system, binDir: system.deletingLastPathComponent(), nodeVersion: "")
        }
        return nil
    }

    /// npm이 아닌 JS CLI(pnpm/yarn/bun/corepack/claude)는 nvm/fnm 버전 폴더에서도 직접 찾는다.
    public func versionedNodeTool(named executableName: String) -> URL? {
        preferredVersionedNodeExecutable(named: executableName)?.executable
    }

    private struct NvmExecutable {
        let version: SemVer
        let executable: URL
        let binDir: URL
        let raw: String
    }

    private func preferredVersionedNodeExecutable(named executableName: String) -> NvmExecutable? {
        preferredNvmExecutable(named: executableName) ?? preferredFnmExecutable(named: executableName)
    }

    private func preferredNvmExecutable(named executableName: String) -> NvmExecutable? {
        let candidates = nvmExecutables(named: executableName)
        let aliasFile = home.appendingPathComponent(".nvm/alias/default")
        if let alias = (try? String(contentsOf: aliasFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            let normalized = alias.hasPrefix("v") ? String(alias.dropFirst()) : alias
            if let exact = candidates.first(where: { $0.raw == normalized }) { return exact }
            // "18" 같은 major-only alias는 prefix 매칭 (일치 중 가장 높은 버전)
            if let best = candidates.filter({ $0.raw.hasPrefix(normalized + ".") })
                .max(by: { $0.version < $1.version }) { return best }
        }
        return candidates.max(by: { $0.version < $1.version })
    }

    private func preferredFnmExecutable(named executableName: String) -> NvmExecutable? {
        fnmExecutables(named: executableName)
            .max(by: { $0.version < $1.version })
    }

    private func nvmExecutables(named executableName: String) -> [NvmExecutable] {
        let fm = FileManager.default
        let versionsDir = home.appendingPathComponent(".nvm/versions/node")
        guard let names = try? fm.contentsOfDirectory(atPath: versionsDir.path) else { return [] }
        return names.compactMap { dirName in
            let raw = dirName.hasPrefix("v") ? String(dirName.dropFirst()) : dirName
            guard let sv = SemVer.parse(raw) else { return nil }
            let binDir = versionsDir.appendingPathComponent("\(dirName)/bin")
            let executable = binDir.appendingPathComponent(executableName)
            guard fm.isExecutableFile(atPath: executable.path) else { return nil }
            return NvmExecutable(version: sv, executable: executable, binDir: binDir, raw: raw)
        }
    }

    private func fnmExecutables(named executableName: String) -> [NvmExecutable] {
        let fm = FileManager.default
        let versionsDir = home.appendingPathComponent(".fnm/node-versions")
        guard let names = try? fm.contentsOfDirectory(atPath: versionsDir.path) else { return [] }
        return names.compactMap { dirName in
            let raw = dirName.hasPrefix("v") ? String(dirName.dropFirst()) : dirName
            guard let sv = SemVer.parse(raw) else { return nil }
            let binDir = versionsDir.appendingPathComponent("\(dirName)/installation/bin")
            let executable = binDir.appendingPathComponent(executableName)
            guard fm.isExecutableFile(atPath: executable.path) else { return nil }
            return NvmExecutable(version: sv, executable: executable, binDir: binDir, raw: raw)
        }
    }

    private func npmShimInstallations() -> [NpmTool] {
        let fm = FileManager.default
        let candidates: [(source: String, url: URL)] = [
            ("volta", home.appendingPathComponent(".volta/bin/npm")),
            ("asdf", home.appendingPathComponent(".asdf/shims/npm")),
            ("mise", home.appendingPathComponent(".local/share/mise/shims/npm")),
        ]
        return candidates.compactMap { source, url in
            guard fm.isExecutableFile(atPath: url.path) else { return nil }
            return NpmTool(npm: url, binDir: url.deletingLastPathComponent(),
                           nodeVersion: "", source: source)
        }
    }

    private func managedNodePrefixes() -> [String] {
        [
            home.appendingPathComponent(".nvm").path,
            home.appendingPathComponent(".fnm").path,
            home.appendingPathComponent(".volta").path,
            home.appendingPathComponent(".asdf").path,
            home.appendingPathComponent(".local/share/mise").path,
        ]
    }

    private func versionManagerShimCandidates(named name: String) -> [String] {
        [
            home.appendingPathComponent(".volta/bin/\(name)").path,
            home.appendingPathComponent(".asdf/shims/\(name)").path,
            home.appendingPathComponent(".local/share/mise/shims/\(name)").path,
        ]
    }

    private func firstExecutable(_ paths: [String]) -> URL? {
        var seen = Set<String>()
        return paths.first { seen.insert($0).inserted && FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func tool(_ name: String, extraCandidates: [String] = []) -> URL? {
        if let override = toolCandidatesOverride[name] {
            return firstExecutable(override)
        }
        let isNodeManaged = Self.nodeManagedToolNames.contains(name)
        var candidates: [String] = []
        if isNodeManaged, let versioned = versionedNodeTool(named: name) {
            candidates.append(versioned.path)
        }
        if isNodeManaged {
            candidates.append(contentsOf: versionManagerShimCandidates(named: name))
            candidates.append(home.appendingPathComponent(".bun/bin/\(name)").path)
        }
        candidates.append(contentsOf: [
            home.appendingPathComponent(".local/bin/\(name)").path,
            home.appendingPathComponent(".cargo/bin/\(name)").path,
        ])
        if !isNodeManaged {
            candidates.append(home.appendingPathComponent(".bun/bin/\(name)").path)
            candidates.append(contentsOf: versionManagerShimCandidates(named: name))
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ])
        candidates.append(contentsOf: extraCandidates)
        return firstExecutable(candidates)
    }
}
