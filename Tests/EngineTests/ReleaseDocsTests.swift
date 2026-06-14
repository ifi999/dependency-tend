import Foundation
import XCTest

final class ReleaseDocsTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testReadmeKeepsReleaseChecksSelfContained() throws {
        let readme = try read("README.md")

        XCTAssertTrue(readme.contains("./scripts/release-qa.sh"))
        XCTAssertFalse(readme.contains("docs/release.md"))
        XCTAssertFalse(readme.contains("docs/release-qa.md"))
    }

    func testReleaseQAScriptDoesNotReferenceIgnoredDocs() throws {
        let script = try read("scripts/release-qa.sh")

        XCTAssertTrue(script.contains("swift test"))
        XCTAssertTrue(script.contains("./scripts/validate-app-bundle.sh"))
        XCTAssertTrue(script.contains("./scripts/install-app.sh --dry-run --no-launch"))
        XCTAssertFalse(script.contains("docs/release"))
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
