import XCTest
@testable import Engine

final class RiskClassifierTests: XCTestCase {
    private func pkg(current: String? = "1.0.0", latest: String? = "1.0.1",
                     status: PackageStatus = .outdated,
                     flags: Set<PackageFlag> = []) -> PackageInfo {
        PackageInfo(name: "x", manager: .homebrew, current: current, latest: latest,
                    status: status, flags: flags)
    }

    func testRiskTable() {
        // 스펙 §3 표 그대로
        XCTAssertEqual(RiskClassifier.classify(pkg(flags: [.pinned])).risk, .high)            // pinned → high
        XCTAssertEqual(RiskClassifier.classify(pkg(latest: "2.0.0")).risk, .high)             // major → high
        XCTAssertEqual(RiskClassifier.classify(pkg(latest: "1.1.0")).risk, .medium)           // minor → medium
        XCTAssertEqual(RiskClassifier.classify(pkg(latest: "1.0.1")).risk, .low)              // patch → low
        XCTAssertEqual(RiskClassifier.classify(pkg(latest: "garbage")).risk, .medium)         // 파싱 불가 → 보수적 medium
        XCTAssertEqual(RiskClassifier.classify(pkg(latest: "1.0.1", flags: [.cask])).risk, .medium) // cask는 medium이 바닥
        XCTAssertEqual(RiskClassifier.classify(pkg(latest: "2.0.0", flags: [.cask])).risk, .high)   // cask여도 major면 high
        // 런타임(node 등)은 patch여도 high — 글로벌 트리/MCP가 올라타 있어 일괄·원클릭 대상이 아니다
        XCTAssertEqual(RiskClassifier.classify(pkg(latest: "1.0.1", flags: [.runtime])).risk, .high)
    }

    func testJumpFlagIsRecorded() {
        XCTAssertTrue(RiskClassifier.classify(pkg(latest: "2.0.0")).flags.contains(.major))
        XCTAssertTrue(RiskClassifier.classify(pkg(latest: "1.1.0")).flags.contains(.minor))
        XCTAssertTrue(RiskClassifier.classify(pkg(latest: "1.0.1")).flags.contains(.patch))
    }

    func testNonOutdatedGetsNoRisk() {
        XCTAssertNil(RiskClassifier.classify(pkg(status: .upToDate)).risk)
        XCTAssertNil(RiskClassifier.classify(pkg(status: .unknown)).risk)
    }
}
