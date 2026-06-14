import Engine
@testable import AppCore
import XCTest

final class UpdateSourceSummaryPresentationTests: XCTestCase {
    func testTextUsesVisiblePackagesOnly() {
        let visible = [
            PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                        current: "5.1.0", status: .unknown,
                        statusReason: .updateCommandCheck),
        ]

        XCTAssertEqual(UpdateSourceSummaryPresentation.text(for: visible), "확인 필요 1")
    }

    func testTextDescribesInventoryOnlyWithoutCallingItUpToDate() {
        let visible = [
            PackageInfo(name: "mcp:jira", manager: .claudePlugin, status: .unknown,
                        statusReason: .inventoryOnly, metadata: ["kind": "mcp"]),
        ]

        XCTAssertEqual(UpdateSourceSummaryPresentation.text(for: visible), "인벤토리 1")
    }

    func testTextExcludesInventoryOnlyFromUnknownCount() {
        let visible = [
            PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                        current: "5.1.0", status: .unknown,
                        statusReason: .updateCommandCheck),
            PackageInfo(name: "mcp:jira", manager: .claudePlugin, status: .unknown,
                        statusReason: .inventoryOnly, metadata: ["kind": "mcp"]),
        ]

        XCTAssertEqual(UpdateSourceSummaryPresentation.text(for: visible), "확인 필요 1 · 인벤토리 1")
    }

    func testTextLocalizesEnglish() {
        let visible = [
            PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                        current: "5.1.0", status: .unknown,
                        statusReason: .updateCommandCheck),
            PackageInfo(name: "mcp:jira", manager: .claudePlugin, status: .unknown,
                        statusReason: .inventoryOnly, metadata: ["kind": "mcp"]),
        ]

        XCTAssertEqual(UpdateSourceSummaryPresentation.text(for: visible, language: .english),
                       "Needs check 1 · Inventory 1")
    }

    func testTextDescribesVisibleUpToDatePackagesWithoutHiddenTotal() {
        let visible = [
            PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                        current: "5.1.0", status: .upToDate),
            PackageInfo(name: "stable-tool@example-marketplace", manager: .claudePlugin,
                        current: "1.2.0", status: .upToDate),
        ]

        XCTAssertEqual(UpdateSourceSummaryPresentation.text(for: visible), "최신 2")
    }
}
