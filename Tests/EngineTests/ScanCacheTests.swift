import XCTest
@testable import Engine

final class ScanCacheTests: XCTestCase {
    func testRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tend-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ScanCache(fileURL: dir.appendingPathComponent("nested/scan-cache.json"))

        XCTAssertNil(cache.load()) // 파일 없으면 nil (에러 아님)

        // 주의: ISO8601은 초 단위 — 정수 초 timestamp 사용
        let result = ScanResult(
            packages: [PackageInfo(name: "aom", manager: .homebrew, current: "3.13.1",
                                   latest: "3.14.1", status: .outdated, risk: .medium, flags: [.minor])],
            advisories: [ManagerAdvisory(manager: .npmGlobal, message: "EOL")],
            errors: [],
            timestamp: Date(timeIntervalSince1970: 1_750_000_000))
        try cache.save(result)
        XCTAssertEqual(cache.load(), result) // 중간 디렉터리 자동 생성 포함
    }

    func testCorruptFileReturnsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tend-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("scan-cache.json")
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(ScanCache(fileURL: file).load())
    }

    func testLoadsLegacyCacheWithoutSourceHealth() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tend-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("scan-cache.json")
        let json = """
        {
          "packages": [],
          "advisories": [],
          "errors": [],
          "timestamp": "2025-06-15T15:06:40Z"
        }
        """

        try Data(json.utf8).write(to: file)
        let result = try XCTUnwrap(ScanCache(fileURL: file).load())

        XCTAssertEqual(result.sourceHealth, [])
    }
}
