import XCTest
@testable import Engine

/// 테스트용 가짜 어댑터
struct StubAdapter: PackageManagerAdapter {
    let id: ManagerID
    var available = true
    var result: Result<AdapterScan, Error> = .success(AdapterScan(packages: []))

    func isAvailable() -> Bool { available }
    func scan(now: Date) async throws -> AdapterScan { try result.get() }
    func updateCommand(for pkg: PackageInfo) -> UpdateCommand? { nil }
}

final class PackageScannerTests: XCTestCase {
    let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)

    func testIsolatesFailingAdapter() async {
        // brew는 성공, npm은 실패 → npm 에러가 기록되고 brew 결과는 살아있어야 한다
        var brew = StubAdapter(id: .homebrew)
        brew.result = .success(AdapterScan(packages: [
            PackageInfo(name: "aom", manager: .homebrew, current: "3.13.1", latest: "3.14.1", status: .outdated)
        ]))
        var npm = StubAdapter(id: .npmGlobal)
        npm.result = .failure(AdapterError.toolNotFound("npm"))

        let scanner = PackageScanner(adapters: [brew, npm], now: { [n = fixedNow] in n })
        let result = await scanner.scanAll()

        XCTAssertEqual(result.packages.count, 1)
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(result.errors[0].manager, .npmGlobal)
        XCTAssertEqual(result.timestamp, fixedNow)
    }

    func testAppliesRiskClassification() async {
        var brew = StubAdapter(id: .homebrew)
        brew.result = .success(AdapterScan(packages: [
            PackageInfo(name: "minor-jump", manager: .homebrew, current: "1.0.0", latest: "1.1.0", status: .outdated),
            PackageInfo(name: "major-jump", manager: .homebrew, current: "1.0.0", latest: "2.0.0", status: .outdated),
        ]))
        let scanner = PackageScanner(adapters: [brew], now: { Date(timeIntervalSince1970: 0) })
        let result = await scanner.scanAll()
        XCTAssertEqual(result.packages.first { $0.name == "minor-jump" }?.risk, .medium)
        XCTAssertEqual(result.packages.first { $0.name == "major-jump" }?.risk, .high)
    }

    func testSkipsUnavailableAdapters() async {
        var gone = StubAdapter(id: .homebrew)
        gone.available = false
        gone.result = .failure(AdapterError.toolNotFound("brew")) // 호출되면 에러가 기록될 것
        let scanner = PackageScanner(adapters: [gone], now: { Date(timeIntervalSince1970: 0) })
        let result = await scanner.scanAll()
        XCTAssertTrue(result.packages.isEmpty)
        XCTAssertTrue(result.errors.isEmpty) // 스킵이지 실패가 아님
    }

    func testReportsSourceHealthForAllTargetAdapters() async throws {
        var available = StubAdapter(id: .homebrew)
        available.result = .success(AdapterScan(packages: [
            PackageInfo(name: "aom", manager: .homebrew, status: .upToDate)
        ]))
        var empty = StubAdapter(id: .npmGlobal)
        empty.result = .success(AdapterScan(packages: []))
        var unavailable = StubAdapter(id: .claudePlugin)
        unavailable.available = false
        var failed = StubAdapter(id: .macAppStore)
        failed.result = .failure(AdapterError.commandFailed("boom"))

        let scanner = PackageScanner(adapters: [available, empty, unavailable, failed],
                                     now: { Date(timeIntervalSince1970: 0) })
        let result = await scanner.scanAll()

        let health = Dictionary(uniqueKeysWithValues: result.sourceHealth.map { ($0.manager, $0) })
        XCTAssertEqual(try XCTUnwrap(health[.homebrew]).availability, .available)
        XCTAssertEqual(try XCTUnwrap(health[.homebrew]).packageCount, 1)
        XCTAssertEqual(try XCTUnwrap(health[.npmGlobal]).availability, .empty)
        XCTAssertEqual(try XCTUnwrap(health[.npmGlobal]).packageCount, 0)
        XCTAssertEqual(try XCTUnwrap(health[.claudePlugin]).availability, .unavailable)
        XCTAssertEqual(try XCTUnwrap(health[.macAppStore]).availability, .failed)
        XCTAssertEqual(result.errors.map(\.manager), [.macAppStore])
    }

    func testScanOnlyOneManager() async {
        var brew = StubAdapter(id: .homebrew)
        brew.result = .success(AdapterScan(packages: [PackageInfo(name: "a", manager: .homebrew, status: .upToDate)]))
        var npm = StubAdapter(id: .npmGlobal)
        npm.result = .success(AdapterScan(packages: [PackageInfo(name: "b", manager: .npmGlobal, status: .upToDate)]))
        let scanner = PackageScanner(adapters: [brew, npm], now: { Date(timeIntervalSince1970: 0) })
        let result = await scanner.scan(only: .npmGlobal)
        XCTAssertEqual(result.packages.map(\.name), ["b"])
    }

    func testCollectsAdvisories() async {
        var npm = StubAdapter(id: .npmGlobal)
        npm.result = .success(AdapterScan(packages: [],
                                          advisories: [ManagerAdvisory(manager: .npmGlobal, message: "EOL")]))
        let scanner = PackageScanner(adapters: [npm], now: { Date(timeIntervalSince1970: 0) })
        let result = await scanner.scanAll()
        XCTAssertEqual(result.advisories.count, 1)
    }
}
