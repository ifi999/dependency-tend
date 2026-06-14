import XCTest
@testable import Engine

final class ModelsTests: XCTestCase {
    func testPackageInfoIDDisambiguatesByTree() {
        // 같은 패키지(npm 등)가 여러 node 트리에 설치될 수 있다 — id가 트리별로 달라야 한다
        let nvmNpm = PackageInfo(name: "npm", manager: .npmGlobal,
                                 metadata: ["tree": "v18.19.1 (nvm)"])
        let brewNpm = PackageInfo(name: "npm", manager: .npmGlobal,
                                  metadata: ["tree": "v22.22.1 (homebrew)"])
        XCTAssertNotEqual(nvmNpm.id, brewNpm.id)
    }

    func testPackageInfoIDIncludesKind() {
        let formula = PackageInfo(name: "docker", manager: .homebrew)
        var cask = PackageInfo(name: "docker", manager: .homebrew)
        cask.flags.insert(.cask)
        XCTAssertEqual(formula.id, "homebrew:pkg:docker")
        XCTAssertEqual(cask.id, "homebrew:cask:docker")
        XCTAssertNotEqual(formula.id, cask.id)
    }

    func testScanResultCodableRoundTrip() throws {
        let result = ScanResult(
            packages: [PackageInfo(name: "ripgrep", manager: .homebrew, current: "14.0.0",
                                   latest: "14.1.0", status: .outdated, risk: .medium,
                                   flags: [.minor], metadata: ["k": "v"]),
                       PackageInfo(name: "mcp:jira", manager: .claudePlugin,
                                   status: .unknown, statusReason: .inventoryOnly,
                                   metadata: ["kind": "mcp"])],
            advisories: [ManagerAdvisory(manager: .npmGlobal, message: "EOL",
                                         url: "https://nodejs.org/en/about/previous-releases")],
            errors: [ScanError(manager: .claudePlugin, message: "boom")],
            sourceHealth: [SourceHealth(manager: .homebrew, availability: .available,
                                        packageCount: 1, message: nil)],
            timestamp: Date(timeIntervalSince1970: 1_750_000_000))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(ScanResult.self, from: try enc.encode(result))
        XCTAssertEqual(decoded, result)
    }

    func testRiskIsComparable() {
        XCTAssertTrue(Risk.low < Risk.medium)
        XCTAssertTrue(Risk.medium < Risk.high)
        XCTAssertEqual(max(Risk.low, .medium), .medium)
    }

    func testUpdateResultSucceeded() {
        XCTAssertTrue(UpdateResult(packageID: "x", command: "c", stdout: "", stderr: "", exitCode: 0).succeeded)
        XCTAssertFalse(UpdateResult(packageID: "x", command: "c", stdout: "", stderr: "e", exitCode: 1).succeeded)
    }

    func testUpdateCommandDisplayStringShowsExecutablePathAndEnvironment() {
        let command = UpdateCommand(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["upgrade", "my tool"],
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin", "NPM_CONFIG_PREFIX": "/tmp/prefix"])

        XCTAssertEqual(command.displayString,
                       "NPM_CONFIG_PREFIX=/tmp/prefix PATH=/opt/homebrew/bin:/usr/bin /opt/homebrew/bin/brew upgrade 'my tool'")
    }

    func testManagerDisplayNamesIncludeAdditionalUpdateSources() {
        XCTAssertEqual(ManagerID.macAppStore.displayName, "Mac App Store")
        XCTAssertEqual(ManagerID.pipx.displayName, "pipx")
        XCTAssertEqual(ManagerID.uvTool.displayName, "uv tools")
        XCTAssertEqual(ManagerID.cargoInstall.displayName, "Cargo installs")
        XCTAssertEqual(ManagerID.vscodeExtensions.displayName, "VS Code Extensions")
        XCTAssertEqual(ManagerID.cursorExtensions.displayName, "Cursor Extensions")
        XCTAssertEqual(ManagerID.pnpmGlobal.displayName, "pnpm (global)")
        XCTAssertEqual(ManagerID.yarnGlobal.displayName, "Yarn (global)")
        XCTAssertEqual(ManagerID.bunGlobal.displayName, "Bun (global)")
    }
}
