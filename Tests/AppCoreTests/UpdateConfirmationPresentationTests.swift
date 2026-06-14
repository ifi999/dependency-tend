import XCTest
import Engine
@testable import AppCore

final class UpdateConfirmationPresentationTests: XCTestCase {
    func testCaskPresentationMentionsGuiAppRisk() {
        let pkg = PackageInfo(name: "google-chrome", manager: .homebrew,
                              current: "125.0.0", latest: "126.0.0",
                              status: .outdated, risk: .medium, flags: [.cask])

        let presentation = UpdateConfirmationPresentation.make(for: pkg)

        XCTAssertEqual(presentation.title, "앱 업데이트 확인")
        XCTAssertEqual(presentation.versionLine, "125.0.0 → 126.0.0 · 위험 보통")
        XCTAssertTrue(presentation.detail.contains("앱 종료·재시작·권한 요청"))
        XCTAssertTrue(presentation.actionHint.contains("열려 있는 앱"))
    }

    func testMacAppStorePresentationMentionsDownloadAndPermissionRisk() {
        let pkg = PackageInfo(name: "Xcode", manager: .macAppStore,
                              current: "16.0", latest: "16.1",
                              status: .outdated, risk: .low)

        let presentation = UpdateConfirmationPresentation.make(for: pkg)

        XCTAssertEqual(presentation.title, "앱 업데이트 확인")
        XCTAssertTrue(presentation.detail.contains("Mac App Store"))
        XCTAssertTrue(presentation.actionHint.contains("시간"))
    }

    func testHighRiskPresentationMentionsMajorVersionJump() {
        let pkg = PackageInfo(name: "node", manager: .homebrew,
                              current: "20.0.0", latest: "22.0.0",
                              status: .outdated, risk: .high, flags: [.major])

        let presentation = UpdateConfirmationPresentation.make(for: pkg)

        XCTAssertEqual(presentation.title, "위험 업데이트 확인")
        XCTAssertEqual(presentation.versionLine, "20.0.0 → 22.0.0 · 위험 높음")
        XCTAssertTrue(presentation.detail.contains("major"))
        XCTAssertTrue(presentation.actionHint.contains("릴리즈 노트"))
    }

    func testUnknownPresentationMentionsVersionUncertainty() {
        let pkg = PackageInfo(name: "sample-plugin@example-marketplace",
                              manager: .claudePlugin,
                              current: "5.1.0",
                              status: .unknown,
                              statusReason: .updateCommandCheck)

        let presentation = UpdateConfirmationPresentation.make(for: pkg)

        XCTAssertEqual(presentation.title, "업데이트 확인")
        XCTAssertEqual(presentation.versionLine, "5.1.0 · 최신 버전 확인 필요")
        XCTAssertTrue(presentation.detail.contains("최신 버전 판단이 불확실"))
        XCTAssertTrue(presentation.actionHint.contains("업데이트 명령"))
    }

    func testEnglishUnknownPresentationMentionsVersionUncertainty() {
        let pkg = PackageInfo(name: "sample-plugin@example-marketplace",
                              manager: .claudePlugin,
                              current: "5.1.0",
                              status: .unknown,
                              statusReason: .updateCommandCheck)

        let presentation = UpdateConfirmationPresentation.make(for: pkg, language: .english)

        XCTAssertEqual(presentation.title, "Confirm update")
        XCTAssertEqual(presentation.versionLine, "5.1.0 · needs latest check")
        XCTAssertTrue(presentation.detail.contains("version cannot be determined"))
        XCTAssertTrue(presentation.actionHint.contains("update command"))
    }
}
