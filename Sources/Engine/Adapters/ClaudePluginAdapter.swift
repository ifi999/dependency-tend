import Foundation

/// Claude Code 플러그인 — best-effort (스펙 §4).
/// 스캔은 installed_plugins.json 파싱만으로 수행(명령 실행 없음).
/// marketplace manifest를 찾을 수 있으면 latest를 비교하고, 없으면 .unknown으로 남긴다.
/// MCP 서버는 ~/.claude.json의 mcpServers 키에서 나열만 한다 (업데이트 미지원).
public struct ClaudePluginAdapter: PackageManagerAdapter {
    public let id = ManagerID.claudePlugin
    let registryURL: URL
    let claudeCLI: URL?
    let mcpConfigURL: URL?
    let marketplaceRegistryURL: URL?

    public init(registryURL: URL, claudeCLI: URL?, mcpConfigURL: URL? = nil,
                marketplaceRegistryURL: URL? = nil) {
        self.registryURL = registryURL
        self.claudeCLI = claudeCLI
        self.mcpConfigURL = mcpConfigURL
        self.marketplaceRegistryURL = marketplaceRegistryURL
    }

    public func isAvailable() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: registryURL.path)
            || mcpConfigURL.map { fm.fileExists(atPath: $0.path) } == true
    }

    public func scan(now: Date) async throws -> AdapterScan {
        let fm = FileManager.default
        var packages: [PackageInfo] = []
        if fm.fileExists(atPath: registryURL.path) {
            let data: Data
            do { data = try Data(contentsOf: registryURL) }
            catch { throw AdapterError.commandFailed("플러그인 레지스트리 읽기 실패: \(error.localizedDescription)") }
            let marketplaceMetadata = Self.loadMarketplaceMetadata(from: marketplaceRegistryURL)
            packages = try Self.parse(data, latestVersions: marketplaceMetadata.latestVersions,
                                      pluginLinks: marketplaceMetadata.pluginLinks,
                                      marketplaceRepos: marketplaceMetadata.marketplaceRepos).map { pkg in
                var out = pkg
                out.metadata["canUpdate"] = claudeCLI == nil ? "false" : "true"
                return out
            }
        }
        // MCP 서버는 best-effort 나열 — 설정이 없거나 깨져도 플러그인 스캔을 막지 않는다
        if let mcpConfigURL,
           let mcpData = try? Data(contentsOf: mcpConfigURL),
           let mcpServers = try? Self.parseMCPServers(mcpData) {
            packages.append(contentsOf: mcpServers)
        }
        return AdapterScan(packages: packages)
    }

    static func parse(_ data: Data, latestVersions: [String: String] = [:],
                      pluginLinks: [String: [String: String]] = [:],
                      marketplaceRepos: [String: String] = [:]) throws -> [PackageInfo] {
        struct Registry: Decodable {
            struct Entry: Decodable {
                let scope: String?
                let version: String?
                let installPath: String?
                let lastUpdated: String?
            }
            let plugins: [String: [Entry]]
        }
        let registry: Registry
        do { registry = try JSONDecoder().decode(Registry.self, from: data) }
        catch { throw AdapterError.parseFailed("installed_plugins.json: \(error)") }

        return registry.plugins.compactMap { key, entries -> PackageInfo? in
            guard let entry = entries.first else { return nil }
            var metadata: [String: String] = [:]
            if let lastUpdated = entry.lastUpdated { metadata["lastUpdated"] = lastUpdated }
            if let scope = entry.scope { metadata["scope"] = scope }
            var hasPluginSpecificLinks = false
            if let links = entry.installPath.flatMap(Self.installedPluginLinks) {
                metadata.merge(links) { _, new in new }
                hasPluginSpecificLinks = true
            }
            if let links = pluginLinks[key] {
                metadata.merge(links) { current, _ in current }
                hasPluginSpecificLinks = true
            } else if !hasPluginSpecificLinks,
                      let marketplaceName = Self.marketplaceName(from: key),
                      let repo = marketplaceRepos[marketplaceName] {
                metadata[PackageLinkMetadata.repositoryURL] = PackageLinkMetadata.githubRepositoryURL(repo: repo)
                metadata[PackageLinkMetadata.packageURL] = PackageLinkMetadata.githubRepositoryURL(repo: repo)
                metadata[PackageLinkMetadata.releaseNotesURL] = PackageLinkMetadata.githubReleaseNotesURL(repo: repo)
            }
            let current = (entry.version == "unknown") ? nil : entry.version
            let latest = latestVersions[key] ?? entry.installPath.flatMap(Self.latestCachedVersion)
            let status = Self.status(current: current, latest: latest)
            return PackageInfo(name: key, manager: .claudePlugin, current: current,
                               latest: latest,
                               status: status,
                               statusReason: status == .unknown ? .updateCommandCheck : nil,
                               metadata: metadata)
        }.sorted { $0.name < $1.name }
    }

    private struct MarketplaceMetadata {
        let latestVersions: [String: String]
        let pluginLinks: [String: [String: String]]
        let marketplaceRepos: [String: String]
    }

    private static func loadMarketplaceMetadata(from registryURL: URL?) -> MarketplaceMetadata {
        guard let registryURL,
              let data = try? Data(contentsOf: registryURL) else {
            return MarketplaceMetadata(latestVersions: [:], pluginLinks: [:], marketplaceRepos: [:])
        }

        struct KnownMarketplace: Decodable {
            struct Source: Decodable {
                let source: String?
                let repo: String?
            }
            let source: Source?
            let installLocation: String?
        }

        guard let marketplaces = try? JSONDecoder().decode([String: KnownMarketplace].self, from: data) else {
            return MarketplaceMetadata(latestVersions: [:], pluginLinks: [:], marketplaceRepos: [:])
        }

        var versions: [String: String] = [:]
        var links: [String: [String: String]] = [:]
        var repos: [String: String] = [:]
        for (marketplaceName, marketplace) in marketplaces {
            if marketplace.source?.source == "github", let repo = marketplace.source?.repo, !repo.isEmpty {
                repos[marketplaceName] = repo
            }
            guard let installLocation = marketplace.installLocation else { continue }
            let root = URL(fileURLWithPath: installLocation)
            for manifest in pluginManifests(in: root) {
                let key = "\(manifest.name)@\(marketplaceName)"
                versions[key] = manifest.version
                if let repo = repos[marketplaceName] {
                    links[key] = [
                        PackageLinkMetadata.repositoryURL: PackageLinkMetadata.githubRepositoryURL(repo: repo),
                        PackageLinkMetadata.packageURL: PackageLinkMetadata.githubTreeURL(repo: repo,
                                                                                         path: manifest.relativePath),
                        PackageLinkMetadata.releaseNotesURL: PackageLinkMetadata.githubReleaseNotesURL(repo: repo),
                    ]
                }
            }
        }
        return MarketplaceMetadata(latestVersions: versions, pluginLinks: links,
                                   marketplaceRepos: repos)
    }

    static func loadMarketplaceVersions(from registryURL: URL?) -> [String: String] {
        loadMarketplaceMetadata(from: registryURL).latestVersions
    }

    private static func pluginManifests(in root: URL) -> [(name: String, version: String, relativePath: String)] {
        let fm = FileManager.default
        var pluginRoots: [URL] = [root]

        for folder in ["plugins", "external_plugins"] {
            let parent = root.appendingPathComponent(folder)
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else {
                continue
            }
            pluginRoots.append(contentsOf: children)
        }

        return pluginRoots.compactMap { pluginRoot in
            let manifestURL = pluginRoot.appendingPathComponent(".claude-plugin/plugin.json")
            guard let data = try? Data(contentsOf: manifestURL) else { return nil }
            struct Manifest: Decodable {
                let name: String
                let version: String?
            }
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
                  let version = manifest.version,
                  !manifest.name.isEmpty,
                  !version.isEmpty else { return nil }
            return (manifest.name, version, relativePath(of: pluginRoot, under: root))
        }
    }

    private static func relativePath(of child: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath != rootPath, childPath.hasPrefix(rootPath + "/") else { return "" }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private static func marketplaceName(from pluginKey: String) -> String? {
        guard let separator = pluginKey.lastIndex(of: "@"),
              separator < pluginKey.index(before: pluginKey.endIndex) else { return nil }
        return String(pluginKey[pluginKey.index(after: separator)...])
    }

    private static func latestCachedVersion(installPath: String) -> String? {
        let pluginRoot = URL(fileURLWithPath: installPath).deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: pluginRoot.path) else {
            return nil
        }
        return names.compactMap { name -> (version: SemVer, raw: String)? in
            let normalized = name.hasPrefix("v") ? String(name.dropFirst()) : name
            guard let version = SemVer.parse(normalized) else { return nil }
            return (version, normalized)
        }.max { lhs, rhs in
            lhs.version < rhs.version
        }?.raw
    }

    private static func installedPluginLinks(installPath: String) -> [String: String]? {
        let manifestURL = URL(fileURLWithPath: installPath)
            .appendingPathComponent(".claude-plugin/plugin.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }

        struct Manifest: Decodable {
            let homepage: String?
            let repository: Repository?
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }

        var links: [String: String] = [:]
        let homepage = normalizedURL(manifest.homepage)
        let repository = normalizedURL(manifest.repository?.url)
        if let homepage {
            links[PackageLinkMetadata.homepageURL] = homepage
        }
        if let repository {
            links[PackageLinkMetadata.repositoryURL] = repository
            if let releaseNotesURL = githubReleaseNotesURL(repositoryURL: repository) {
                links[PackageLinkMetadata.releaseNotesURL] = releaseNotesURL
            }
        }
        if let primaryURL = homepage ?? repository {
            links[PackageLinkMetadata.packageURL] = primaryURL
        }
        return links.isEmpty ? nil : links
    }

    private struct Repository: Decodable {
        let url: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                url = string
            } else if let object = try? container.decode(RepositoryObject.self) {
                url = object.url
            } else {
                url = nil
            }
        }
    }

    private struct RepositoryObject: Decodable {
        let url: String?
    }

    private static func normalizedURL(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if value.hasPrefix("git+") { value.removeFirst(4) }
        if value.hasPrefix("git@github.com:") {
            value = "https://github.com/" + value.dropFirst("git@github.com:".count)
        }
        if value.hasSuffix(".git") { value.removeLast(4) }
        return URL(string: value)?.absoluteString
    }

    private static func githubReleaseNotesURL(repositoryURL: String) -> String? {
        let prefix = "https://github.com/"
        guard repositoryURL.hasPrefix(prefix) else { return nil }
        let repo = String(repositoryURL.dropFirst(prefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard repo.split(separator: "/").count >= 2 else { return nil }
        return PackageLinkMetadata.githubReleaseNotesURL(repo: repo)
    }

    private static func status(current: String?, latest: String?) -> PackageStatus {
        guard let current, let latest else { return .unknown }
        if let currentVersion = SemVer.parse(current), let latestVersion = SemVer.parse(latest) {
            return currentVersion < latestVersion ? .outdated : .upToDate
        }
        return current == latest ? .upToDate : .unknown
    }

    /// ~/.claude.json 최상위 mcpServers — "(나열만)" 대신 실체를 표시할 수 있도록
    /// 설정 값(원격 URL 호스트 / 로컬 실행 명령)을 metadata로 보존한다.
    static func parseMCPServers(_ data: Data) throws -> [PackageInfo] {
        struct Config: Decodable {
            struct Server: Decodable {
                let type: String?
                let command: String?
                let args: [String]?
                let url: String?
            }
            let mcpServers: [String: Server]?
        }
        let config: Config
        do { config = try JSONDecoder().decode(Config.self, from: data) }
        catch { throw AdapterError.parseFailed(".claude.json: \(error)") }
        return (config.mcpServers ?? [:]).sorted { $0.key < $1.key }.map { name, server in
            var metadata: [String: String] = ["kind": "mcp"]
            if let url = server.url {
                metadata["mcpKind"] = "remote"
                metadata["mcpDetail"] = URL(string: url)?.host ?? url
            } else if let command = server.command {
                metadata["mcpKind"] = "local"
                metadata["mcpDetail"] = ([command] + (server.args ?? [])).joined(separator: " ")
            }
            return PackageInfo(name: "mcp:\(name)", manager: .claudePlugin,
                               status: .unknown, statusReason: .inventoryOnly,
                               metadata: metadata)
        }
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let cli = claudeCLI, pkg.manager == id,
              !pkg.name.hasPrefix("mcp:") else { return nil } // MCP는 v1 나열만
        return UpdateCommand(executable: cli, arguments: ["plugin", "update", pkg.name])
    }
}
