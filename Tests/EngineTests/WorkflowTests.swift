import Foundation
import XCTest

final class WorkflowTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testCIWorkflowCancelsSupersededRuns() throws {
        let workflow = root.appendingPathComponent(".github/workflows/ci.yml")
        let text = try String(contentsOf: workflow)

        XCTAssertTrue(text.contains("concurrency:"), text)
        XCTAssertTrue(text.contains("cancel-in-progress: true"), text)
        XCTAssertTrue(text.contains("github.workflow"), text)
        XCTAssertTrue(text.contains("github.ref"), text)
    }
}
