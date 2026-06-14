import XCTest
@testable import Engine

final class NpmGlobalAdapterTests: XCTestCase {
    // 실측 픽스처 (2026-06-10, 축약)
    static let lsJSON = """
    {
      "name": "lib",
      "dependencies": {
        "@google/gemini-cli": {"version": "0.24.0", "overridden": false},
        "ccusage": {"version": "17.1.6", "overridden": false},
        "npm": {"version": "10.2.4", "overridden": false}
      }
    }
    """

    static let outdatedJSON = """
    {
      "@google/gemini-cli": {
        "current": "0.24.0", "wanted": "0.45.3", "latest": "0.45.3",
        "dependent": "global",
        "location": "/Users/x/.nvm/versions/node/v18.19.1/lib/node_modules/@google/gemini-cli"
      },
      "ccusage": {
        "current": "17.1.6", "wanted": "20.0.9", "latest": "20.0.9",
        "dependent": "global",
        "location": "/Users/x/.nvm/versions/node/v18.19.1/lib/node_modules/ccusage"
      }
    }
    """

    func testParseLs() throws {
        let installed = try NpmGlobalAdapter.parseLs(Data(Self.lsJSON.utf8))
        XCTAssertEqual(installed.count, 3)
        XCTAssertEqual(installed["@google/gemini-cli"], "0.24.0")
        XCTAssertEqual(installed["npm"], "10.2.4")
    }

    func testParseOutdated() throws {
        let outdated = try NpmGlobalAdapter.parseOutdated(Data(Self.outdatedJSON.utf8))
        XCTAssertEqual(outdated.count, 2)
        XCTAssertEqual(outdated["ccusage"], "20.0.9")
    }

    func testParseOutdatedEmptyStdout() throws {
        // outdated 없을 때 npm은 빈 출력을 낼 수 있다
        XCTAssertTrue(try NpmGlobalAdapter.parseOutdated(Data()).isEmpty)
        XCTAssertTrue(try NpmGlobalAdapter.parseOutdated(Data("\n".utf8)).isEmpty)
        XCTAssertTrue(try NpmGlobalAdapter.parseOutdated(Data("{}".utf8)).isEmpty)
    }

    func testParseBinNames() {
        // bin이 맵: 키들이 bin 이름
        let mapJSON = #"{"name": "@scope/pkg", "bin": {"mcp-server-fs": "./cli.js", "fs-extra": "./x.js"}}"#
        XCTAssertEqual(NpmGlobalAdapter.parseBinNames(Data(mapJSON.utf8)), ["fs-extra", "mcp-server-fs"])
        // bin이 문자열: 패키지명 마지막 컴포넌트가 bin 이름 (npm 규칙)
        let stringJSON = #"{"name": "@colbymchenry/codegraph", "bin": "./bin/cli.js"}"#
        XCTAssertEqual(NpmGlobalAdapter.parseBinNames(Data(stringJSON.utf8)), ["codegraph"])
        // bin 없음 / 깨진 JSON
        XCTAssertTrue(NpmGlobalAdapter.parseBinNames(Data(#"{"name": "x"}"#.utf8)).isEmpty)
        XCTAssertTrue(NpmGlobalAdapter.parseBinNames(Data("garbage".utf8)).isEmpty)
    }

    func testReadBinNamesFromTree() throws {
        let fm = FileManager.default
        let libRoot = fm.temporaryDirectory.appendingPathComponent("tend-bins-\(UUID().uuidString)")
        let pkgDir = libRoot.appendingPathComponent("@scope/tool")
        try fm.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: libRoot) }
        try Data(#"{"name": "@scope/tool", "bin": {"tool-cli": "./c.js"}}"#.utf8)
            .write(to: pkgDir.appendingPathComponent("package.json"))
        XCTAssertEqual(NpmGlobalAdapter.readBinNames(libRoot: libRoot, packageName: "@scope/tool"),
                       ["tool-cli"])
        XCTAssertTrue(NpmGlobalAdapter.readBinNames(libRoot: libRoot, packageName: "absent").isEmpty)
    }

    func testNodeEOLTable() {
        let mid2026 = Date(timeIntervalSince1970: 1_780_000_000) // 2026-06 무렵
        XCTAssertTrue(NpmGlobalAdapter.isNodeEOL(major: 18, on: mid2026))   // 2025-04-30 EOL
        XCTAssertTrue(NpmGlobalAdapter.isNodeEOL(major: 20, on: mid2026))   // 2026-04-30 EOL
        XCTAssertFalse(NpmGlobalAdapter.isNodeEOL(major: 22, on: mid2026))  // 2027-04-30
        XCTAssertFalse(NpmGlobalAdapter.isNodeEOL(major: 24, on: mid2026))
        XCTAssertTrue(NpmGlobalAdapter.isNodeEOL(major: 19, on: mid2026))   // 홀수 = 비-LTS
        XCTAssertTrue(NpmGlobalAdapter.isNodeEOL(major: 16, on: mid2026))   // 테이블보다 오래됨
        XCTAssertFalse(NpmGlobalAdapter.isNodeEOL(major: 26, on: mid2026))  // 테이블보다 새것
    }

    private func makeAdapter(runner: MockCommandRunner, nodeVersion: String = "18.19.1") -> NpmGlobalAdapter {
        let bin = URL(fileURLWithPath: "/fake/nvm/v\(nodeVersion)/bin")
        return NpmGlobalAdapter(
            tool: ToolLocator.NpmTool(npm: bin.appendingPathComponent("npm"),
                                      binDir: bin,
                                      nodeVersion: nodeVersion),
            runner: runner)
    }

    func testScanMergesAndEmitsEOLAdvisory() async throws {
        let runner = MockCommandRunner()
        runner.stub("npm ls -g --depth=0 --json",
                    CommandOutput(stdout: Self.lsJSON, stderr: "", exitCode: 0))
        // 함정 재현: npm outdated는 outdated가 있으면 exit 1 (정상)
        runner.stub("npm outdated -g --json",
                    CommandOutput(stdout: Self.outdatedJSON, stderr: "", exitCode: 1))
        let adapter = makeAdapter(runner: runner)
        let scan = try await adapter.scan(now: Date(timeIntervalSince1970: 1_780_000_000)) // 2026-06

        XCTAssertEqual(scan.packages.count, 3)
        let gemini = scan.packages.first { $0.name == "@google/gemini-cli" }!
        XCTAssertEqual(gemini.status, .outdated)
        XCTAssertEqual(gemini.latest, "0.45.3")
        XCTAssertEqual(gemini.metadata["node"], "18.19.1") // nvm 묶임 가시화
        XCTAssertEqual(gemini.metadata["packageURL"],
                       "https://www.npmjs.com/package/@google/gemini-cli")
        let npm = scan.packages.first { $0.name == "npm" }!
        XCTAssertEqual(npm.status, .upToDate)
        XCTAssertEqual(npm.metadata["packageURL"], "https://www.npmjs.com/package/npm")
        // npm/corepack은 사용자가 설치한 게 아니라 node 번들 — 의존성으로 취급해 기본 화면에서 숨긴다
        XCTAssertTrue(npm.flags.contains(.dependency))
        XCTAssertEqual(npm.metadata["bundled"], "node")
        let gemini2 = scan.packages.first { $0.name == "@google/gemini-cli" }!
        XCTAssertFalse(gemini2.flags.contains(.dependency)) // 직접 설치한 도구는 그대로
        // node 18은 EOL → advisory (+가이드 링크)
        XCTAssertEqual(scan.advisories.count, 1)
        XCTAssertTrue(scan.advisories[0].message.contains("18.19.1"))
        XCTAssertNotNil(scan.advisories[0].url)
        // 실측 함정 대응: 모든 npm 호출에 node bin이 PATH로 주입되어야 한다 (GUI 최소 PATH에서 exit 127 방지)
        XCTAssertTrue(runner.calls.allSatisfy {
            $0.environment["PATH"]?.contains("/fake/nvm/v18.19.1/bin") == true
        })
    }

    func testScanNoAdvisoryForSupportedNode() async throws {
        let runner = MockCommandRunner()
        runner.stub("npm ls -g --depth=0 --json",
                    CommandOutput(stdout: Self.lsJSON, stderr: "", exitCode: 0))
        runner.stub("npm outdated -g --json", CommandOutput(stdout: "", stderr: "", exitCode: 0))
        let adapter = makeAdapter(runner: runner, nodeVersion: "22.11.0")
        let scan = try await adapter.scan(now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertTrue(scan.advisories.isEmpty)
    }

    func testScanRejectsRealFailure() async {
        let runner = MockCommandRunner()
        runner.stub("npm ls -g --depth=0 --json",
                    CommandOutput(stdout: "", stderr: "ENOENT something", exitCode: 2))
        let adapter = makeAdapter(runner: runner)
        do { _ = try await adapter.scan(now: Date()); XCTFail("실패해야 함") }
        catch let e as AdapterError {
            guard case .commandFailed = e else { return XCTFail("commandFailed여야 함") }
        }
        catch { XCTFail("AdapterError여야 함: \(error)") }
    }

    func testScanMultipleTreesTagsAndRoutes() async throws {
        let runner = MockCommandRunner()
        let nvmBin = URL(fileURLWithPath: "/fake/nvm/v18.19.1/bin")
        let brewBin = URL(fileURLWithPath: "/fake/brew/Cellar/node@22/22.22.1/bin")
        let nvmTool = ToolLocator.NpmTool(npm: nvmBin.appendingPathComponent("npm"),
                                          binDir: nvmBin, nodeVersion: "18.19.1", source: "nvm")
        let brewTool = ToolLocator.NpmTool(npm: brewBin.appendingPathComponent("npm"),
                                           binDir: brewBin, nodeVersion: "22.22.1", source: "homebrew")
        // 같은 명령이라도 트리(실행 경로)별로 다른 출력 — 전체 경로 키로 스텁
        runner.stub("\(nvmTool.npm.path) ls -g --depth=0 --json",
                    CommandOutput(stdout: Self.lsJSON, stderr: "", exitCode: 0))
        runner.stub("\(nvmTool.npm.path) outdated -g --json",
                    CommandOutput(stdout: Self.outdatedJSON, stderr: "", exitCode: 1))
        runner.stub("\(brewTool.npm.path) ls -g --depth=0 --json",
                    CommandOutput(stdout: #"{"dependencies": {"npm": {"version": "10.9.0"}, "@anthropic-ai/claude-code": {"version": "2.0.0"}}}"#,
                                  stderr: "", exitCode: 0))
        runner.stub("\(brewTool.npm.path) outdated -g --json",
                    CommandOutput(stdout: "", stderr: "", exitCode: 0))

        let adapter = NpmGlobalAdapter(tools: [nvmTool, brewTool], runner: runner)
        let scan = try await adapter.scan(now: Date(timeIntervalSince1970: 1_780_000_000))

        XCTAssertEqual(scan.packages.count, 5) // nvm 3 + brew 2
        let claude = scan.packages.first { $0.name == "@anthropic-ai/claude-code" }!
        XCTAssertEqual(claude.metadata["tree"], "v22.22.1 (homebrew)")
        let gemini = scan.packages.first { $0.name == "@google/gemini-cli" }!
        XCTAssertEqual(gemini.metadata["tree"], "v18.19.1 (nvm)")
        // "npm"은 두 트리 모두에 있다 — id가 트리별로 달라야 한다
        XCTAssertEqual(Set(scan.packages.map(\.id)).count, scan.packages.count)
        // 업데이트는 해당 트리의 npm으로 라우팅 + 그 트리의 PATH 주입
        let cmd = adapter.updateCommand(for: claude)
        XCTAssertEqual(cmd?.executable.path, brewTool.npm.path)
        XCTAssertTrue(cmd?.environment["PATH"]?.contains(brewBin.path) == true)
        // EOL advisory는 node 18 트리에서만 (22는 지원 중)
        XCTAssertEqual(scan.advisories.count, 1)
        XCTAssertTrue(scan.advisories[0].message.contains("18.19.1"))
    }

    func testScanMultipleTreesReportsPartialFailures() async throws {
        let runner = MockCommandRunner()
        let goodBin = URL(fileURLWithPath: "/fake/good/v22.22.1/bin")
        let badBin = URL(fileURLWithPath: "/fake/bad/v20.19.0/bin")
        let goodTool = ToolLocator.NpmTool(npm: goodBin.appendingPathComponent("npm"),
                                           binDir: goodBin, nodeVersion: "22.22.1", source: "nvm")
        let badTool = ToolLocator.NpmTool(npm: badBin.appendingPathComponent("npm"),
                                          binDir: badBin, nodeVersion: "20.19.0", source: "nvm")
        runner.stub("\(goodTool.npm.path) ls -g --depth=0 --json",
                    CommandOutput(stdout: #"{"dependencies": {"ccusage": {"version": "20.0.9"}}}"#,
                                  stderr: "", exitCode: 0))
        runner.stub("\(goodTool.npm.path) outdated -g --json",
                    CommandOutput(stdout: "", stderr: "", exitCode: 0))
        runner.stub("\(badTool.npm.path) ls -g --depth=0 --json",
                    CommandOutput(stdout: "", stderr: "node binary missing", exitCode: 2))

        let adapter = NpmGlobalAdapter(tools: [goodTool, badTool], runner: runner)
        let scan = try await adapter.scan(now: Date(timeIntervalSince1970: 1_780_000_000))

        XCTAssertEqual(scan.packages.map(\.name), ["ccusage"])
        XCTAssertEqual(scan.advisories.count, 1)
        let advisory = try XCTUnwrap(scan.advisories.first)
        XCTAssertTrue(advisory.message.contains("일부 npm 트리"))
        XCTAssertTrue(advisory.message.contains("v20.19.0 (nvm)"))
        XCTAssertTrue(advisory.message.contains("node binary missing"))
    }

    func testUpdateCommand() {
        let adapter = makeAdapter(runner: MockCommandRunner())
        let pkg = PackageInfo(name: "ccusage", manager: .npmGlobal, status: .outdated)
        let cmd = adapter.updateCommand(for: pkg)
        XCTAssertEqual(cmd?.arguments, ["install", "-g", "ccusage@latest"])
        XCTAssertTrue(cmd?.environment["PATH"]?.contains("/fake/nvm/v18.19.1/bin") == true)
        XCTAssertNil(adapter.updateCommand(for: PackageInfo(name: "x", manager: .homebrew)))
    }

    func testUpdateCommandRefusesAmbiguousPackageWithoutNpmPathWhenMultipleTrees() {
        let firstBin = URL(fileURLWithPath: "/fake/first/bin")
        let secondBin = URL(fileURLWithPath: "/fake/second/bin")
        let first = ToolLocator.NpmTool(npm: firstBin.appendingPathComponent("npm"),
                                        binDir: firstBin, nodeVersion: "20.0.0", source: "nvm")
        let second = ToolLocator.NpmTool(npm: secondBin.appendingPathComponent("npm"),
                                         binDir: secondBin, nodeVersion: "22.0.0", source: "homebrew")
        let adapter = NpmGlobalAdapter(tools: [first, second], runner: MockCommandRunner())

        let missingPath = PackageInfo(name: "ccusage", manager: .npmGlobal, status: .outdated)
        let stalePath = PackageInfo(name: "ccusage", manager: .npmGlobal, status: .outdated,
                                    metadata: ["npmPath": "/old/npm"])

        XCTAssertNil(adapter.updateCommand(for: missingPath))
        XCTAssertNil(adapter.updateCommand(for: stalePath))
    }
}
