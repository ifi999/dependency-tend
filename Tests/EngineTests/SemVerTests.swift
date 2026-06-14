import XCTest
@testable import Engine

final class SemVerTests: XCTestCase {
    func testParseTable() {
        // (입력, 기대 major.minor.patch) — nil은 파싱 실패 기대
        let cases: [(String, (Int, Int, Int)?)] = [
            ("1.2.3", (1, 2, 3)),
            ("v18.19.1", (18, 19, 1)),       // npm/node 스타일 v 접두
            ("23.0.1_3", (23, 0, 1)),        // brew revision 접미
            ("1.2.3-beta.1", (1, 2, 3)),     // prerelease
            ("1.2.3+build5", (1, 2, 3)),     // build metadata
            ("5.1", (5, 1, 0)),              // patch 생략
            ("7", (7, 0, 0)),                // minor/patch 생략
            ("1.2.3.4", (1, 2, 3)),          // 4세그먼트 → 앞 3개
            ("unknown", nil),
            ("", nil),
        ]
        for (input, expected) in cases {
            let got = SemVer.parse(input)
            if let e = expected {
                XCTAssertEqual(got, SemVer(major: e.0, minor: e.1, patch: e.2), "input: \(input)")
            } else {
                XCTAssertNil(got, "input: \(input)")
            }
        }
    }

    func testJumpTable() {
        let cases: [(String, String, PackageFlag?)] = [
            ("1.2.3", "2.0.0", .major),
            ("1.2.3", "1.3.0", .minor),
            ("1.2.3", "1.2.4", .patch),
            ("0.24.0", "0.45.3", .minor),    // 실측: gemini-cli
            ("3.13.1", "3.14.1", .minor),    // 실측: aom (brew)
            ("1.2.3", "1.2.3", nil),         // 동일
            ("2.0.0", "1.0.0", nil),         // 다운그레이드
            ("garbage", "1.0.0", nil),       // 파싱 불가
        ]
        for (from, to, expected) in cases {
            XCTAssertEqual(SemVer.jump(from: from, to: to), expected, "\(from) → \(to)")
        }
    }

    func testComparable() {
        XCTAssertTrue(SemVer(major: 18, minor: 19, patch: 1) < SemVer(major: 20, minor: 0, patch: 0))
    }
}
