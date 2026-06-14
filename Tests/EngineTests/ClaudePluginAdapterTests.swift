import XCTest
@testable import Engine

final class ClaudePluginAdapterTests: XCTestCase {
    // 실측 픽스처: ~/.claude/plugins/installed_plugins.json (축약)
    static let registryJSON = """
    {
     "version": 2,
     "plugins": {
      "claude-hud@claude-hud": [
       {"scope": "user",
        "installPath": "/Users/x/.claude/plugins/cache/claude-hud/claude-hud/0.0.7",
        "version": "0.0.7",
        "installedAt": "2026-03-24T23:54:37.849Z",
        "lastUpdated": "2026-03-24T23:54:37.849Z",
        "gitCommitSha": "2497b92c"}
      ],
      "ui-helper@example-marketplace": [
       {"scope": "user",
        "installPath": "/Users/x/.claude/plugins/cache/example-marketplace/ui-helper/unknown",
        "version": "unknown",
        "installedAt": "2026-02-11T03:42:19.234Z",
        "lastUpdated": "2026-04-03T03:50:04.122Z",
        "gitCommitSha": "27d2b86d"}
      ]
     }
    }
    """

    // 실측 픽스처: ~/.claude.json 최상위 mcpServers (값 구조는 type/url/command 등 — 키만 사용)
    static let mcpConfigJSON = """
    {
     "someOtherTopLevelKey": true,
     "mcpServers": {
      "codegraph": {"type": "stdio", "command": "codegraph", "args": ["serve", "--mcp"]},
      "jira": {"type": "http", "url": "https://example.com/mcp"}
     }
    }
    """

    static let stableToolRegistryJSON = """
    {
     "version": 2,
     "plugins": {
      "stable-tool@example-marketplace": [
       {"scope": "user",
        "installPath": "/Users/x/.claude/plugins/cache/example-marketplace/stable-tool/1.2.0",
        "version": "1.2.0",
        "installedAt": "2026-04-12T08:54:56.566Z",
        "lastUpdated": "2026-04-12T08:54:56.566Z",
        "gitCommitSha": "3bfc442a02e64a37bd0f312dd2ae9bd3b7d9f251"}
      ]
     }
    }
    """

    func testParse() throws {
        let pkgs = try ClaudePluginAdapter.parse(Data(Self.registryJSON.utf8))
        XCTAssertEqual(pkgs.count, 2)
        let hud = pkgs.first { $0.name == "claude-hud@claude-hud" }!
        XCTAssertEqual(hud.current, "0.0.7")
        XCTAssertEqual(hud.status, .unknown) // latest 비교 불가 → unknown (best-effort)
        XCTAssertEqual(hud.statusReason, .updateCommandCheck)
        XCTAssertEqual(hud.metadata["lastUpdated"], "2026-03-24T23:54:37.849Z")
        // version "unknown"은 current nil 처리
        let fd = pkgs.first { $0.name == "ui-helper@example-marketplace" }!
        XCTAssertNil(fd.current)
        XCTAssertEqual(fd.statusReason, .updateCommandCheck)
    }

    func testScanReadsRegistryFile() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tend-claude-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let registry = dir.appendingPathComponent("installed_plugins.json")
        try Data(Self.registryJSON.utf8).write(to: registry)

        let adapter = ClaudePluginAdapter(registryURL: registry,
                                          claudeCLI: URL(fileURLWithPath: "/fake/claude"))
        XCTAssertTrue(adapter.isAvailable())
        let scan = try await adapter.scan(now: Date())
        XCTAssertEqual(scan.packages.count, 2)

        let missing = ClaudePluginAdapter(registryURL: dir.appendingPathComponent("nope.json"),
                                          claudeCLI: nil)
        XCTAssertFalse(missing.isAvailable())
    }

    func testUpdateCommand() {
        let adapter = ClaudePluginAdapter(registryURL: URL(fileURLWithPath: "/fake/registry.json"),
                                          claudeCLI: URL(fileURLWithPath: "/usr/local/bin/claude"))
        let pkg = PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin)
        XCTAssertEqual(adapter.updateCommand(for: pkg)?.arguments,
                       ["plugin", "update", "sample-plugin@example-marketplace"])
        // CLI 못 찾으면 업데이트 미지원
        let noCLI = ClaudePluginAdapter(registryURL: URL(fileURLWithPath: "/fake/registry.json"),
                                        claudeCLI: nil)
        XCTAssertNil(noCLI.updateCommand(for: pkg))
        XCTAssertNil(adapter.updateCommand(for: PackageInfo(name: "x", manager: .homebrew)))
        // MCP 서버는 v1 나열만 — 업데이트 미지원
        let mcp = PackageInfo(name: "mcp:jira", manager: .claudePlugin, metadata: ["kind": "mcp"])
        XCTAssertNil(adapter.updateCommand(for: mcp))
    }

    func testParseMCPServers() throws {
        let pkgs = try ClaudePluginAdapter.parseMCPServers(Data(Self.mcpConfigJSON.utf8))
        XCTAssertEqual(pkgs.map(\.name), ["mcp:codegraph", "mcp:jira"])
        XCTAssertTrue(pkgs.allSatisfy { $0.status == .unknown && $0.metadata["kind"] == "mcp" })
        XCTAssertTrue(pkgs.allSatisfy { $0.statusReason == .inventoryOnly })
        // "(나열만)" 대신 실체를 표시할 수 있도록 설정 값을 보존한다 (사용자 피드백)
        let codegraph = pkgs[0]
        XCTAssertEqual(codegraph.metadata["mcpKind"], "local")
        XCTAssertEqual(codegraph.metadata["mcpDetail"], "codegraph serve --mcp")
        let jira = pkgs[1]
        XCTAssertEqual(jira.metadata["mcpKind"], "remote")
        XCTAssertEqual(jira.metadata["mcpDetail"], "example.com") // URL은 호스트만
    }

    func testScanIncludesMCPServersBestEffort() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tend-mcp-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let registry = dir.appendingPathComponent("installed_plugins.json")
        try Data(Self.registryJSON.utf8).write(to: registry)
        let mcpConfig = dir.appendingPathComponent("claude.json")
        try Data(Self.mcpConfigJSON.utf8).write(to: mcpConfig)

        let adapter = ClaudePluginAdapter(registryURL: registry, claudeCLI: nil,
                                          mcpConfigURL: mcpConfig)
        let scan = try await adapter.scan(now: Date())
        XCTAssertEqual(scan.packages.count, 4) // 플러그인 2 + MCP 2

        // best-effort: MCP 설정이 없어도 플러그인 스캔은 동작해야 한다
        let noMCP = ClaudePluginAdapter(registryURL: registry, claudeCLI: nil,
                                        mcpConfigURL: dir.appendingPathComponent("absent.json"))
        let scan2 = try await noMCP.scan(now: Date())
        XCTAssertEqual(scan2.packages.count, 2)
    }

    func testScanWorksWhenOnlyMCPConfigExists() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tend-mcp-only-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let mcpConfig = dir.appendingPathComponent("claude.json")
        try Data(Self.mcpConfigJSON.utf8).write(to: mcpConfig)

        let adapter = ClaudePluginAdapter(registryURL: dir.appendingPathComponent("missing.json"),
                                          claudeCLI: nil,
                                          mcpConfigURL: mcpConfig)
        XCTAssertTrue(adapter.isAvailable())
        let scan = try await adapter.scan(now: Date())
        XCTAssertEqual(scan.packages.map(\.name), ["mcp:codegraph", "mcp:jira"])
    }

    func testScanRecordsPluginUpdateCapability() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tend-claude-capability-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let registry = dir.appendingPathComponent("installed_plugins.json")
        try Data(Self.registryJSON.utf8).write(to: registry)

        let withoutCLI = ClaudePluginAdapter(registryURL: registry, claudeCLI: nil)
        let disabled = try await withoutCLI.scan(now: Date()).packages
        XCTAssertTrue(disabled.allSatisfy { $0.metadata["canUpdate"] == "false" })

        let withCLI = ClaudePluginAdapter(registryURL: registry,
                                          claudeCLI: URL(fileURLWithPath: "/usr/local/bin/claude"))
        let enabled = try await withCLI.scan(now: Date()).packages
        XCTAssertTrue(enabled.allSatisfy { $0.metadata["canUpdate"] == "true" })
    }

    func testScanMarksPluginUpToDateWhenMarketplaceManifestMatchesInstalledVersion() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tend-claude-marketplace-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let registry = dir.appendingPathComponent("installed_plugins.json")
        try Data(Self.stableToolRegistryJSON.utf8).write(to: registry)

        let marketplace = dir.appendingPathComponent("example-marketplace")
        let manifestDir = marketplace.appendingPathComponent(".claude-plugin")
        try fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try Data(#"{"name":"stable-tool","version":"1.2.0"}"#.utf8)
            .write(to: manifestDir.appendingPathComponent("plugin.json"))

        let knownMarketplaces = dir.appendingPathComponent("known_marketplaces.json")
        let knownJSON = """
        {
          "example-marketplace": {
            "source": {"source": "github", "repo": "example/example-marketplace"},
            "installLocation": "\(marketplace.path)"
          }
        }
        """
        try Data(knownJSON.utf8).write(to: knownMarketplaces)

        let adapter = ClaudePluginAdapter(registryURL: registry,
                                          claudeCLI: URL(fileURLWithPath: "/fake/claude"),
                                          marketplaceRegistryURL: knownMarketplaces)
        let scan = try await adapter.scan(now: Date())
        let stableTool = try XCTUnwrap(scan.packages.first { $0.name == "stable-tool@example-marketplace" })
        XCTAssertEqual(stableTool.current, "1.2.0")
        XCTAssertEqual(stableTool.latest, "1.2.0")
        XCTAssertEqual(stableTool.status, .upToDate)
        XCTAssertNil(stableTool.statusReason)
        XCTAssertEqual(stableTool.metadata["repositoryURL"], "https://github.com/example/example-marketplace")
        XCTAssertEqual(stableTool.metadata["packageURL"],
                       "https://github.com/example/example-marketplace/tree/main")
        XCTAssertEqual(stableTool.metadata["releaseNotesURL"],
                       "https://github.com/example/example-marketplace/releases")
    }

    func testScanUsesInstalledCacheVersionsWhenMarketplaceManifestIsMissing() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tend-claude-cache-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let cacheRoot = dir.appendingPathComponent("cache/example-marketplace/sample-plugin")
        try fm.createDirectory(at: cacheRoot.appendingPathComponent("5.0.7"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheRoot.appendingPathComponent("5.1.0"), withIntermediateDirectories: true)

        let registry = dir.appendingPathComponent("installed_plugins.json")
        let registryJSON = """
        {
          "version": 2,
          "plugins": {
            "sample-plugin@example-marketplace": [
              {
                "scope": "user",
                "installPath": "\(cacheRoot.appendingPathComponent("5.1.0").path)",
                "version": "5.1.0",
                "lastUpdated": "2026-06-10T12:47:53.448Z"
              }
            ]
          }
        }
        """
        try Data(registryJSON.utf8).write(to: registry)

        let marketplace = dir.appendingPathComponent("marketplaces/example-marketplace")
        try fm.createDirectory(at: marketplace, withIntermediateDirectories: true)
        let knownMarketplaces = dir.appendingPathComponent("known_marketplaces.json")
        let knownJSON = """
        {
          "example-marketplace": {
            "source": {"source": "github", "repo": "example/example-marketplace"},
            "installLocation": "\(marketplace.path)"
          }
        }
        """
        try Data(knownJSON.utf8).write(to: knownMarketplaces)

        let adapter = ClaudePluginAdapter(registryURL: registry,
                                          claudeCLI: URL(fileURLWithPath: "/fake/claude"),
                                          marketplaceRegistryURL: knownMarketplaces)
        let scan = try await adapter.scan(now: Date())
        let samplePlugin = try XCTUnwrap(scan.packages.first {
            $0.name == "sample-plugin@example-marketplace"
        })

        XCTAssertEqual(samplePlugin.current, "5.1.0")
        XCTAssertEqual(samplePlugin.latest, "5.1.0")
        XCTAssertEqual(samplePlugin.status, .upToDate)
    }

    func testScanUsesInstalledPluginManifestLinksBeforeMarketplaceFallback() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tend-claude-links-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let installRoot = dir.appendingPathComponent("cache/example-marketplace/sample-plugin/5.1.0")
        let manifestDir = installRoot.appendingPathComponent(".claude-plugin")
        try fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try Data("""
        {
          "name": "sample-plugin",
          "version": "5.1.0",
          "homepage": "https://github.com/example/sample-plugin",
          "repository": "https://github.com/example/sample-plugin"
        }
        """.utf8).write(to: manifestDir.appendingPathComponent("plugin.json"))

        let registry = dir.appendingPathComponent("installed_plugins.json")
        let registryJSON = """
        {
          "version": 2,
          "plugins": {
            "sample-plugin@example-marketplace": [
              {
                "scope": "user",
                "installPath": "\(installRoot.path)",
                "version": "5.1.0",
                "lastUpdated": "2026-06-10T12:47:53.448Z"
              }
            ]
          }
        }
        """
        try Data(registryJSON.utf8).write(to: registry)

        let marketplace = dir.appendingPathComponent("marketplaces/example-marketplace")
        try fm.createDirectory(at: marketplace, withIntermediateDirectories: true)
        let knownMarketplaces = dir.appendingPathComponent("known_marketplaces.json")
        let knownJSON = """
        {
          "example-marketplace": {
            "source": {"source": "github", "repo": "example/example-marketplace"},
            "installLocation": "\(marketplace.path)"
          }
        }
        """
        try Data(knownJSON.utf8).write(to: knownMarketplaces)

        let adapter = ClaudePluginAdapter(registryURL: registry,
                                          claudeCLI: URL(fileURLWithPath: "/fake/claude"),
                                          marketplaceRegistryURL: knownMarketplaces)
        let scan = try await adapter.scan(now: Date())
        let samplePlugin = try XCTUnwrap(scan.packages.first {
            $0.name == "sample-plugin@example-marketplace"
        })

        XCTAssertEqual(samplePlugin.metadata["packageURL"], "https://github.com/example/sample-plugin")
        XCTAssertEqual(samplePlugin.metadata["homepageURL"], "https://github.com/example/sample-plugin")
        XCTAssertEqual(samplePlugin.metadata["repositoryURL"], "https://github.com/example/sample-plugin")
        XCTAssertEqual(samplePlugin.metadata["releaseNotesURL"], "https://github.com/example/sample-plugin/releases")
    }
}
