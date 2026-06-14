import XCTest
@testable import Engine

final class HomebrewAdapterTests: XCTestCase {
    // 실측 픽스처: brew outdated --json=v2 (축약)
    static let outdatedJSON = """
    {
     "formulae": [
      {"name": "aom", "installed_versions": ["3.13.1"], "current_version": "3.14.1",
       "pinned": false, "pinned_version": null},
      {"name": "apache-arrow", "installed_versions": ["23.0.1_3"], "current_version": "24.0.0_3",
       "pinned": true, "pinned_version": "23.0.1_3"}
     ],
     "casks": [
      {"name": "mitmproxy", "installed_versions": ["12.2.1"], "current_version": "12.2.3",
       "pinned": false, "pinned_version": null}
     ]
    }
    """

    static let listFormulaeText = """
    aom 3.13.1
    apache-arrow 23.0.1_3
    node@22 22.22.1_3
    ripgrep 14.1.1
    """

    static let listCasksText = """
    mitmproxy 12.2.1
    obsidian 1.6.7
    """

    // brew leaves: 직접 설치한 최상위 formulae (aom은 빠짐 → 의존성)
    static let leavesText = """
    apache-arrow
    node@22
    ripgrep
    """

    static let installedInfoJSON = """
    {
      "formulae": [
        {"name": "aom", "full_name": "aom", "tap": "homebrew/core",
         "homepage": "https://aomedia.googlesource.com/aom"},
        {"name": "custom-tool", "full_name": "example/tools/custom-tool", "tap": "example/tools",
         "homepage": "https://example.com/custom-tool"}
      ],
      "casks": [
        {"token": "mitmproxy", "full_token": "mitmproxy", "tap": "homebrew/cask",
         "homepage": "https://mitmproxy.org"},
        {"token": "custom-app", "full_token": "example/tools/custom-app", "tap": "example/tools",
         "homepage": "https://example.com/custom-app"}
      ]
    }
    """

    /// 임시 Cellar 생성: 각 formula의 INSTALL_RECEIPT.json에 runtime_dependencies 기록
    private func makeCellar(receipts: [String: [String]]) throws -> URL {
        let fm = FileManager.default
        let cellar = fm.temporaryDirectory.appendingPathComponent("tend-cellar-\(UUID().uuidString)")
        for (name, deps) in receipts {
            let kegDir = cellar.appendingPathComponent("\(name)/1.0.0")
            try fm.createDirectory(at: kegDir, withIntermediateDirectories: true)
            let entries = deps.map { "{\"full_name\": \"\($0)\"}" }.joined(separator: ", ")
            try Data("{\"runtime_dependencies\": [\(entries)]}".utf8)
                .write(to: kegDir.appendingPathComponent("INSTALL_RECEIPT.json"))
        }
        return cellar
    }

    func testParseOutdatedJSON() throws {
        let parsed = try HomebrewAdapter.parseOutdatedJSON(Data(Self.outdatedJSON.utf8))
        XCTAssertEqual(parsed.formulae.count, 2)
        XCTAssertEqual(parsed.formulae[0].name, "aom")
        XCTAssertEqual(parsed.formulae[0].installedVersions, ["3.13.1"])
        XCTAssertEqual(parsed.formulae[0].currentVersion, "3.14.1")
        XCTAssertFalse(parsed.formulae[0].pinned)
        XCTAssertTrue(parsed.formulae[1].pinned)
        XCTAssertEqual(parsed.casks.count, 1)
    }

    func testParseListVersions() {
        let items = HomebrewAdapter.parseListVersions(Self.listFormulaeText)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].name, "aom")
        XCTAssertEqual(items[0].version, "3.13.1")
        // 여러 버전 설치 시 마지막(최신) 토큰
        let multi = HomebrewAdapter.parseListVersions("node 18.19.1 20.1.0")
        XCTAssertEqual(multi[0].version, "20.1.0")
        // 빈 입력
        XCTAssertTrue(HomebrewAdapter.parseListVersions("").isEmpty)
    }

    func testParseReceipt() {
        let json = """
        {"runtime_dependencies": [{"full_name": "aom", "version": "3.13.1"},
                                  {"full_name": "someuser/tap/custom-lib"}]}
        """
        // tap 접두("user/tap/이름")는 마지막 컴포넌트만
        XCTAssertEqual(HomebrewAdapter.parseReceipt(Data(json.utf8)), ["aom", "custom-lib"])
        XCTAssertEqual(HomebrewAdapter.parseReceipt(Data("{}".utf8)), [])
        XCTAssertEqual(HomebrewAdapter.parseReceipt(Data("garbage".utf8)), []) // 깨진 영수증 → 빈 deps
    }

    func testReadDepsMapFromCellar() throws {
        let cellar = try makeCellar(receipts: ["apache-arrow": ["aom"], "aom": []])
        defer { try? FileManager.default.removeItem(at: cellar) }
        let map = HomebrewAdapter.readDepsMap(cellar: cellar,
                                              formulae: ["apache-arrow", "aom", "ripgrep"])
        XCTAssertEqual(map["apache-arrow"], ["aom"])
        XCTAssertEqual(map["aom"], [])
        XCTAssertEqual(map["ripgrep"], []) // 영수증 없음 → 빈 deps (best-effort)
    }

    func testReadDepsMapUsesInstalledVersionNotLexicographicLast() throws {
        let fm = FileManager.default
        let cellar = fm.temporaryDirectory.appendingPathComponent("tend-cellar-version-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: cellar) }
        let oldDir = cellar.appendingPathComponent("pkg/9.10.0")
        let installedDir = cellar.appendingPathComponent("pkg/10.0.0")
        try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try Data("{\"runtime_dependencies\": [{\"full_name\": \"wrong-lib\"}]}".utf8)
            .write(to: oldDir.appendingPathComponent("INSTALL_RECEIPT.json"))
        try Data("{\"runtime_dependencies\": [{\"full_name\": \"right-lib\"}]}".utf8)
            .write(to: installedDir.appendingPathComponent("INSTALL_RECEIPT.json"))

        let map = HomebrewAdapter.readDepsMap(cellar: cellar,
                                              formulae: [(name: "pkg", version: "10.0.0")])
        XCTAssertEqual(map["pkg"], ["right-lib"])
    }

    func testDependencyParentsComputesTransitiveClosure() {
        // a → b → c, d → c : c는 a와 d 둘 다의 (전이적) 의존성
        let parents = HomebrewAdapter.dependencyParents(
            leaves: ["a", "d"],
            depsMap: ["a": ["b"], "b": ["c"], "d": ["c"], "c": []],
            installed: ["a", "b", "c", "d"])
        XCTAssertEqual(parents["b"], ["a"])
        XCTAssertEqual(parents["c"], ["a", "d"]) // 공유 의존성은 양쪽 부모 모두
        XCTAssertNil(parents["a"]) // leaf 자신은 의존성이 아님
        // 설치 안 된 이름은 무시
        let p2 = HomebrewAdapter.dependencyParents(
            leaves: ["a"], depsMap: ["a": ["ghost"]], installed: ["a"])
        XCTAssertTrue(p2.isEmpty)
    }

    func testParseInstalledInfoBuildsConservativeLinks() throws {
        let metadata = try HomebrewAdapter.parseInstalledInfoJSON(Data(Self.installedInfoJSON.utf8))

        XCTAssertEqual(metadata["aom"]?[PackageLinkMetadata.packageURL],
                       "https://formulae.brew.sh/formula/aom")
        XCTAssertEqual(metadata["aom"]?[PackageLinkMetadata.homepageURL],
                       "https://aomedia.googlesource.com/aom")
        XCTAssertEqual(metadata["mitmproxy"]?[PackageLinkMetadata.packageURL],
                       "https://formulae.brew.sh/cask/mitmproxy")
        XCTAssertEqual(metadata["mitmproxy"]?[PackageLinkMetadata.homepageURL],
                       "https://mitmproxy.org")

        XCTAssertNil(metadata["custom-tool"]?[PackageLinkMetadata.packageURL])
        XCTAssertEqual(metadata["custom-tool"]?[PackageLinkMetadata.homepageURL],
                       "https://example.com/custom-tool")
        XCTAssertNil(metadata["custom-app"]?[PackageLinkMetadata.packageURL])
        XCTAssertEqual(metadata["custom-app"]?[PackageLinkMetadata.homepageURL],
                       "https://example.com/custom-app")
    }

    func testMerge() throws {
        let outdated = try HomebrewAdapter.parseOutdatedJSON(Data(Self.outdatedJSON.utf8))
        let linkMetadata = try HomebrewAdapter.parseInstalledInfoJSON(Data(Self.installedInfoJSON.utf8))
        let pkgs = HomebrewAdapter.merge(
            formulae: HomebrewAdapter.parseListVersions(Self.listFormulaeText + "\ncustom-tool 1.0.0"),
            casks: HomebrewAdapter.parseListVersions(Self.listCasksText + "\ncustom-app 2.0.0"),
            outdated: outdated,
            leaves: ["apache-arrow", "ripgrep"],
            parents: ["aom": ["apache-arrow"]],
            linkMetadata: linkMetadata)
        XCTAssertEqual(pkgs.count, 8)

        // 런타임(node 계열)은 글로벌 패키지·MCP가 올라타 있어 원클릭 업데이트 대상이 아니다
        let node = pkgs.first { $0.name == "node@22" }!
        XCTAssertTrue(node.flags.contains(.runtime))

        let aom = pkgs.first { $0.name == "aom" }!
        XCTAssertEqual(aom.status, .outdated)
        XCTAssertEqual(aom.latest, "3.14.1")
        XCTAssertFalse(aom.flags.contains(.cask))
        XCTAssertTrue(aom.flags.contains(.dependency)) // leaves에 없음 → 의존성
        XCTAssertEqual(aom.metadata["parents"], "apache-arrow") // 부모 기록 (트리 표시용)
        XCTAssertEqual(aom.metadata["packageURL"], "https://formulae.brew.sh/formula/aom")
        XCTAssertEqual(aom.metadata["homepageURL"], "https://aomedia.googlesource.com/aom")

        let arrow = pkgs.first { $0.name == "apache-arrow" }!
        XCTAssertTrue(arrow.flags.contains(.pinned))
        XCTAssertFalse(arrow.flags.contains(.dependency)) // 직접 설치

        let ripgrep = pkgs.first { $0.name == "ripgrep" }!
        XCTAssertEqual(ripgrep.status, .upToDate)
        XCTAssertNil(ripgrep.latest)
        XCTAssertFalse(ripgrep.flags.contains(.dependency))
        XCTAssertFalse(ripgrep.flags.contains(.runtime)) // 일반 도구는 런타임 아님

        let mitm = pkgs.first { $0.name == "mitmproxy" }!
        XCTAssertTrue(mitm.flags.contains(.cask))
        XCTAssertEqual(mitm.status, .outdated)
        XCTAssertFalse(mitm.flags.contains(.dependency)) // cask는 항상 직접 설치
        XCTAssertEqual(mitm.metadata["packageURL"], "https://formulae.brew.sh/cask/mitmproxy")
        XCTAssertEqual(mitm.metadata["homepageURL"], "https://mitmproxy.org")

        let obsidian = pkgs.first { $0.name == "obsidian" }!
        XCTAssertTrue(obsidian.flags.contains(.cask))
        XCTAssertEqual(obsidian.status, .upToDate)

        let customTool = pkgs.first { $0.name == "custom-tool" }!
        XCTAssertNil(customTool.metadata["packageURL"]) // third-party tap: formulae.brew.sh 추측 금지
        XCTAssertEqual(customTool.metadata["homepageURL"], "https://example.com/custom-tool")

        let customApp = pkgs.first { $0.name == "custom-app" }!
        XCTAssertNil(customApp.metadata["packageURL"]) // third-party cask tap도 추측 금지
        XCTAssertEqual(customApp.metadata["homepageURL"], "https://example.com/custom-app")
    }

    func testScanMergesWithReceiptDeps() async throws {
        let runner = MockCommandRunner()
        runner.stub("brew list --formula --versions",
                    CommandOutput(stdout: Self.listFormulaeText, stderr: "", exitCode: 0))
        runner.stub("brew list --cask --versions",
                    CommandOutput(stdout: Self.listCasksText, stderr: "", exitCode: 0))
        runner.stub("brew leaves",
                    CommandOutput(stdout: Self.leavesText, stderr: "", exitCode: 0))
        runner.stub("brew outdated --json=v2",
                    CommandOutput(stdout: Self.outdatedJSON, stderr: "", exitCode: 0))
        runner.stub("brew info --json=v2 --installed",
                    CommandOutput(stdout: Self.installedInfoJSON, stderr: "", exitCode: 0))
        let cellar = try makeCellar(receipts: ["apache-arrow": ["aom"], "aom": []])
        defer { try? FileManager.default.removeItem(at: cellar) }
        let adapter = HomebrewAdapter(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                                      runner: runner, cellarURL: cellar)
        let scan = try await adapter.scan(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(scan.packages.count, 6)
        XCTAssertTrue(scan.advisories.isEmpty)
        XCTAssertEqual(runner.calls.count, 5)
        // 직접 설치/의존성 구분 + 영수증 기반 부모 연결이 스캔 결과에 반영
        let aom = scan.packages.first { $0.name == "aom" }!
        XCTAssertTrue(aom.flags.contains(.dependency))
        XCTAssertEqual(aom.metadata["parents"], "apache-arrow")
        XCTAssertEqual(aom.metadata["homepageURL"], "https://aomedia.googlesource.com/aom")
        XCTAssertFalse(scan.packages.first { $0.name == "ripgrep" }!.flags.contains(.dependency))
    }

    func testScanThrowsOnCommandFailure() async {
        let runner = MockCommandRunner()
        runner.stub("brew list --formula --versions",
                    CommandOutput(stdout: "", stderr: "brew broke", exitCode: 1))
        runner.stub("brew list --cask --versions", CommandOutput(stdout: "", stderr: "", exitCode: 0))
        runner.stub("brew outdated --json=v2", CommandOutput(stdout: "{}", stderr: "", exitCode: 0))
        let adapter = HomebrewAdapter(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), runner: runner)
        do {
            _ = try await adapter.scan(now: Date())
            XCTFail("실패해야 함")
        } catch let e as AdapterError {
            guard case .commandFailed(let msg) = e else { return XCTFail("commandFailed여야 함") }
            XCTAssertTrue(msg.contains("brew broke")) // stderr가 보존되어야 함
        } catch { XCTFail("AdapterError여야 함: \(error)") }
    }

    func testScanThrowsWhenBrewMissing() async {
        let adapter = HomebrewAdapter(brewURL: nil, runner: MockCommandRunner())
        do { _ = try await adapter.scan(now: Date()); XCTFail("실패해야 함") }
        catch let e as AdapterError { XCTAssertEqual(e, .toolNotFound("brew")) }
        catch { XCTFail("AdapterError여야 함") }
    }

    func testParseAutoremoveDryRun() {
        // 실제 형식 (brew cleanup.rb 소스 확인): "==> Would autoremove N unneeded formulae:" + 이름 줄들
        let output = """
        ==> Would autoremove 2 unneeded formulae:
        aom
        lz4
        """
        XCTAssertEqual(HomebrewAdapter.parseAutoremoveDryRun(output), ["aom", "lz4"])
        XCTAssertTrue(HomebrewAdapter.parseAutoremoveDryRun("").isEmpty) // 고아 0개면 출력 없음
    }

    func testOrphanNamesAndAutoremoveCommand() async throws {
        let runner = MockCommandRunner()
        runner.stub("brew autoremove --dry-run",
                    CommandOutput(stdout: "==> Would autoremove 1 unneeded formula:\naom\n",
                                  stderr: "", exitCode: 0))
        let adapter = HomebrewAdapter(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                                      runner: runner)
        let names = try await adapter.orphanNames()
        XCTAssertEqual(names, ["aom"])
        XCTAssertEqual(adapter.autoremoveCommand()?.arguments, ["autoremove"])
    }

    func testUpdateCommandFormulaVsCask() {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let adapter = HomebrewAdapter(brewURL: brew, runner: MockCommandRunner())
        let formula = PackageInfo(name: "aom", manager: .homebrew, status: .outdated)
        var cask = PackageInfo(name: "mitmproxy", manager: .homebrew, status: .outdated)
        cask.flags.insert(.cask)
        XCTAssertEqual(adapter.updateCommand(for: formula)?.arguments, ["upgrade", "aom"])
        XCTAssertEqual(adapter.updateCommand(for: cask)?.arguments, ["upgrade", "--cask", "mitmproxy"])
        // 다른 매니저의 패키지는 거부
        let npmPkg = PackageInfo(name: "x", manager: .npmGlobal)
        XCTAssertNil(adapter.updateCommand(for: npmPkg))
    }
}
