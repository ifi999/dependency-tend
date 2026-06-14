import XCTest
@testable import Engine

final class ToolLocatorTests: XCTestCase {
    var tempHome: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tempHome = fm.temporaryDirectory.appendingPathComponent("tend-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempHome)
    }

    private func makeExecutable(at path: URL) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: path.path, contents: Data("#!/bin/sh\n".utf8),
                      attributes: [.posixPermissions: 0o755])
    }

    func testNpmPrefersNvmDefaultAlias() throws {
        try makeExecutable(at: tempHome.appendingPathComponent(".nvm/versions/node/v18.19.1/bin/npm"))
        try makeExecutable(at: tempHome.appendingPathComponent(".nvm/versions/node/v20.11.0/bin/npm"))
        try fm.createDirectory(at: tempHome.appendingPathComponent(".nvm/alias"), withIntermediateDirectories: true)
        try "18.19.1".write(to: tempHome.appendingPathComponent(".nvm/alias/default"),
                            atomically: true, encoding: .utf8)
        let tool = ToolLocator(home: tempHome).npm()
        XCTAssertEqual(tool?.nodeVersion, "18.19.1") // default alias 우선 (최신 20.11.0이 아니라)
        XCTAssertEqual(tool?.npm.path, tempHome.appendingPathComponent(".nvm/versions/node/v18.19.1/bin/npm").path)
        // 실측 함정 대응: npm 실행에 PATH로 주입할 node bin 디렉터리를 보존해야 한다
        XCTAssertEqual(tool?.binDir.path, tempHome.appendingPathComponent(".nvm/versions/node/v18.19.1/bin").path)
    }

    func testNpmAliasMajorOnlyMatchesByPrefix() throws {
        // nvm alias가 "18"처럼 major만일 수도 있다 — prefix로 매칭해야 한다
        try makeExecutable(at: tempHome.appendingPathComponent(".nvm/versions/node/v18.19.1/bin/npm"))
        try makeExecutable(at: tempHome.appendingPathComponent(".nvm/versions/node/v20.11.0/bin/npm"))
        try fm.createDirectory(at: tempHome.appendingPathComponent(".nvm/alias"), withIntermediateDirectories: true)
        try "18".write(to: tempHome.appendingPathComponent(".nvm/alias/default"),
                       atomically: true, encoding: .utf8)
        XCTAssertEqual(ToolLocator(home: tempHome).npm()?.nodeVersion, "18.19.1")
    }

    func testNpmInstallationsFindsAllTrees() throws {
        // nvm 두 버전 + homebrew node — default alias 하나만 보던 사각지대 해소
        try makeExecutable(at: tempHome.appendingPathComponent(".nvm/versions/node/v18.19.1/bin/npm"))
        try makeExecutable(at: tempHome.appendingPathComponent(".nvm/versions/node/v22.21.1/bin/npm"))
        let brewNpm = tempHome.appendingPathComponent("Cellar/node@22/22.22.1_3/bin/npm")
        try makeExecutable(at: brewNpm)
        let tools = ToolLocator(home: tempHome, npmSystemCandidates: [brewNpm.path]).npmInstallations()
        XCTAssertEqual(tools.map(\.nodeVersion), ["18.19.1", "22.21.1", "22.22.1"])
        XCTAssertEqual(tools.map(\.source), ["nvm", "nvm", "homebrew"])
        XCTAssertEqual(tools[2].label, "v22.22.1 (homebrew)")
    }

    func testNpmInstallationsFindsFnmAndShimManagers() throws {
        try makeExecutable(at: tempHome.appendingPathComponent(".fnm/node-versions/v21.5.0/installation/bin/npm"))
        try makeExecutable(at: tempHome.appendingPathComponent(".volta/bin/npm"))
        try makeExecutable(at: tempHome.appendingPathComponent(".asdf/shims/npm"))
        try makeExecutable(at: tempHome.appendingPathComponent(".local/share/mise/shims/npm"))

        let tools = ToolLocator(home: tempHome, npmSystemCandidates: []).npmInstallations()

        XCTAssertEqual(tools.map(\.source), ["fnm", "volta", "asdf", "mise"])
        XCTAssertEqual(tools.map(\.nodeVersion), ["21.5.0", "", "", ""])
        XCTAssertEqual(try XCTUnwrap(tools.first).label, "v21.5.0 (fnm)")
    }

    func testNpmFallsBackToFnmWhenNoNvm() throws {
        let fnmNpm = tempHome.appendingPathComponent(".fnm/node-versions/v21.5.0/installation/bin/npm")
        try makeExecutable(at: fnmNpm)

        let tool = ToolLocator(home: tempHome, npmSystemCandidates: []).npm()

        XCTAssertEqual(tool?.source, "fnm")
        XCTAssertEqual(tool?.npm.path, fnmNpm.path)
        XCTAssertEqual(tool?.label, "v21.5.0 (fnm)")
    }

    func testNpmFallsBackToHighestVersion() throws {
        try makeExecutable(at: tempHome.appendingPathComponent(".nvm/versions/node/v18.19.1/bin/npm"))
        try makeExecutable(at: tempHome.appendingPathComponent(".nvm/versions/node/v20.11.0/bin/npm"))
        // alias 없음 → 가장 높은 버전
        let tool = ToolLocator(home: tempHome).npm()
        XCTAssertEqual(tool?.nodeVersion, "20.11.0")
    }

    func testNpmNilWhenNothingInstalled() {
        XCTAssertNil(ToolLocator(home: tempHome, npmSystemCandidates: []).npm())
    }

    func testBrewUsesInjectedCandidates() throws {
        let fakeBrew = tempHome.appendingPathComponent("bin/brew")
        try makeExecutable(at: fakeBrew)
        XCTAssertEqual(ToolLocator(home: tempHome, brewCandidates: [fakeBrew.path]).brew()?.path, fakeBrew.path)
        XCTAssertNil(ToolLocator(home: tempHome, brewCandidates: ["/no/such/brew"]).brew())
        // Cellar = brew prefix/Cellar (INSTALL_RECEIPT 읽기용)
        XCTAssertEqual(ToolLocator(home: tempHome, brewCandidates: [fakeBrew.path]).brewCellar()?.path,
                       tempHome.appendingPathComponent("Cellar").path)
    }

    func testDiagnosticsReportAvailableAndMissingTools() throws {
        let fakeBrew = tempHome.appendingPathComponent("bin/brew")
        let fakeClaude = tempHome.appendingPathComponent("bin/claude")
        try makeExecutable(at: fakeBrew)
        try makeExecutable(at: fakeClaude)

        let locator = ToolLocator(
            home: tempHome,
            brewCandidates: [fakeBrew.path],
            npmSystemCandidates: [],
            claudeCandidates: [fakeClaude.path],
            toolCandidates: ["mas": ["/missing/mas"]])

        let diagnostics = locator.diagnostics()
        let byID = Dictionary(uniqueKeysWithValues: diagnostics.map { ($0.id, $0) })

        XCTAssertEqual(byID["homebrew"]?.path, fakeBrew.path)
        XCTAssertEqual(byID["claude"]?.path, fakeClaude.path)
        XCTAssertEqual(byID["mas"]?.isAvailable, false)
    }

    func testClaudeConfigPaths() {
        let locator = ToolLocator(home: tempHome)
        XCTAssertEqual(locator.claudePluginRegistry().path,
                       tempHome.appendingPathComponent(".claude/plugins/installed_plugins.json").path)
        XCTAssertEqual(locator.claudeKnownMarketplaces().path,
                       tempHome.appendingPathComponent(".claude/plugins/known_marketplaces.json").path)
        XCTAssertEqual(locator.claudeMCPConfig().path,
                       tempHome.appendingPathComponent(".claude.json").path)
    }

    func testClaudeCLIPrefersNativeInstallerOverNvmAndStaleWrapper() throws {
        let nvmClaude = tempHome.appendingPathComponent(".nvm/versions/node/v24.15.0/bin/claude")
        let localClaude = tempHome.appendingPathComponent(".claude/local/claude")
        try makeExecutable(at: nvmClaude)
        try makeExecutable(at: localClaude)
        // 시스템 경로(/opt/homebrew 등)는 기계 상태에 오염되지 않게 비워서 테스트 (hermetic)
        let locator = { ToolLocator(home: self.tempHome, claudeSystemCandidates: []) }
        // nvm은 .claude/local의 낡은 래퍼보다는 우선
        XCTAssertEqual(locator().claudeCLI()?.path, nvmClaude.path)

        // 그러나 네이티브 설치(~/.local/bin, 자가 업데이트)가 있으면 그것이 최우선 —
        // 실측: nvm 트리의 claude는 낡은 npm 잔재(2.1.17 vs 2.1.174)인 경우가 많고
        // 구버전 CLI는 plugin update가 "not found"로 깨진다
        let nativeClaude = tempHome.appendingPathComponent(".local/bin/claude")
        try makeExecutable(at: nativeClaude)
        XCTAssertEqual(locator().claudeCLI()?.path, nativeClaude.path)
    }

    func testJavaScriptToolsPreferVersionManagerPathsBeforeStaleLocalWrappers() throws {
        let stalePnpm = tempHome.appendingPathComponent(".local/bin/pnpm")
        let nvmPnpm = tempHome.appendingPathComponent(".nvm/versions/node/v22.11.0/bin/pnpm")
        try makeExecutable(at: stalePnpm)
        try makeExecutable(at: nvmPnpm)
        XCTAssertEqual(ToolLocator(home: tempHome).pnpm()?.path, nvmPnpm.path)

        let staleYarn = tempHome.appendingPathComponent(".local/bin/yarn")
        let fnmYarn = tempHome.appendingPathComponent(".fnm/node-versions/v20.10.0/installation/bin/yarn")
        try makeExecutable(at: staleYarn)
        try makeExecutable(at: fnmYarn)
        XCTAssertEqual(ToolLocator(home: tempHome).yarn()?.path, fnmYarn.path)

        let staleBun = tempHome.appendingPathComponent(".local/bin/bun")
        let voltaBun = tempHome.appendingPathComponent(".volta/bin/bun")
        try makeExecutable(at: staleBun)
        try makeExecutable(at: voltaBun)
        XCTAssertEqual(ToolLocator(home: tempHome).bun()?.path, voltaBun.path)
    }

    func testGenericToolsFindCommonShimManagers() throws {
        let asdfPipx = tempHome.appendingPathComponent(".asdf/shims/pipx")
        let miseUv = tempHome.appendingPathComponent(".local/share/mise/shims/uv")
        try makeExecutable(at: asdfPipx)
        try makeExecutable(at: miseUv)

        let locator = ToolLocator(home: tempHome)
        XCTAssertEqual(locator.pipx()?.path, asdfPipx.path)
        XCTAssertEqual(locator.uv()?.path, miseUv.path)
    }

    func testClaudeCLIUsesVersionManagerShimBeforeLegacyLocalWrapper() throws {
        let legacyClaude = tempHome.appendingPathComponent(".claude/local/claude")
        let voltaClaude = tempHome.appendingPathComponent(".volta/bin/claude")
        try makeExecutable(at: legacyClaude)
        try makeExecutable(at: voltaClaude)

        let locator = { ToolLocator(home: self.tempHome, claudeSystemCandidates: []) }
        XCTAssertEqual(locator().claudeCLI()?.path, voltaClaude.path)

        let nativeClaude = tempHome.appendingPathComponent(".local/bin/claude")
        try makeExecutable(at: nativeClaude)
        XCTAssertEqual(locator().claudeCLI()?.path, nativeClaude.path)
    }

    func testAdditionalToolPathsUseOverridesAndKnownLocations() throws {
        let fakeMas = tempHome.appendingPathComponent("bin/mas")
        let fakeCode = tempHome.appendingPathComponent("bin/code")
        try makeExecutable(at: fakeMas)
        try makeExecutable(at: fakeCode)

        let locator = ToolLocator(home: tempHome, toolCandidates: [
            "mas": [fakeMas.path],
            "code": [fakeCode.path],
        ])

        XCTAssertEqual(locator.mas()?.path, fakeMas.path)
        XCTAssertEqual(locator.vscodeCLI()?.path, fakeCode.path)
        XCTAssertEqual(locator.bunGlobalPackageJSON().path,
                       tempHome.appendingPathComponent(".bun/install/global/package.json").path)
    }
}
