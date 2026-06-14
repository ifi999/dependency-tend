import Foundation
import XCTest

final class AppCompositionSourceTests: XCTestCase {
    private var appCompositionCode: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/AppCore/AppComposition.swift"),
                              encoding: .utf8)
        }
    }

    func testAppCompositionInjectsBundledAppUpdateInstaller() throws {
        let source = try appCompositionCode

        XCTAssertTrue(source.contains("ScriptedAppUpdateInstaller.bundleResource()"))
        XCTAssertTrue(source.contains("appUpdateInstaller: appUpdateInstaller"))
    }
}
