import Foundation
import XCTest
@testable import AppCore

final class AppLanguageTests: XCTestCase {
    private var appLanguageSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent("Sources/AppCore/AppLanguage.swift"),
                              encoding: .utf8)
        }
    }

    func testDefaultsToKoreanWhenNoValueIsStored() {
        let defaults = UserDefaults(suiteName: "AppLanguageTests.default.\(UUID().uuidString)")!
        let store = LanguageStore(defaults: defaults, key: "language")

        XCTAssertEqual(store.load(), .korean)
    }

    func testPersistsEnglishSelection() throws {
        let defaults = UserDefaults(suiteName: "AppLanguageTests.persist.\(UUID().uuidString)")!
        let store = LanguageStore(defaults: defaults, key: "language")

        try store.save(.english)

        XCTAssertEqual(store.load(), .english)
        XCTAssertEqual(defaults.string(forKey: "language"), "en")
    }

    func testUnknownStoredValueFallsBackToKorean() {
        let defaults = UserDefaults(suiteName: "AppLanguageTests.fallback.\(UUID().uuidString)")!
        defaults.set("fr", forKey: "language")
        let store = LanguageStore(defaults: defaults, key: "language")

        XCTAssertEqual(store.load(), .korean)
    }

    func testCoreStringsSwitchBetweenKoreanAndEnglish() {
        XCTAssertEqual(AppStrings(.korean).refreshNow, "지금 다시 스캔")
        XCTAssertEqual(AppStrings(.english).refreshNow, "Scan now")
    }

    func testAppUpdateStringsSwitchBetweenKoreanAndEnglish() {
        XCTAssertEqual(AppStrings(.korean).checkAppUpdateTitle, "앱 업데이트 확인")
        XCTAssertEqual(AppStrings(.english).checkAppUpdateTitle, "Check app update")
        XCTAssertEqual(AppStrings(.korean).appUpdateCheckingTitle, "앱 업데이트 확인 중")
        XCTAssertEqual(AppStrings(.english).appUpdateCheckingTitle, "Checking app update")
        XCTAssertEqual(AppStrings(.korean).appUpdateDownloadTitle, "다운로드")
        XCTAssertEqual(AppStrings(.english).appUpdateDownloadTitle, "Download")
        XCTAssertEqual(AppStrings(.korean).appUpdateDownloadingTitle("1.2.3"), "앱 1.2.3 다운로드 중")
        XCTAssertEqual(AppStrings(.english).appUpdateDownloadingTitle("1.2.3"), "Downloading app 1.2.3")
        XCTAssertEqual(AppStrings(.korean).appUpdateInstallTitle, "설치")
        XCTAssertEqual(AppStrings(.english).appUpdateInstallTitle, "Install")
        XCTAssertEqual(AppStrings(.korean).appUpdateInstallingTitle, "앱 업데이트 설치 중")
        XCTAssertEqual(AppStrings(.english).appUpdateInstallingTitle, "Installing app update")
        XCTAssertEqual(AppStrings(.korean).appUpdateReadyToInstallTitle("1.2.3"), "앱 1.2.3 설치 준비됨")
        XCTAssertEqual(AppStrings(.english).appUpdateReadyToInstallTitle("1.2.3"), "App 1.2.3 ready to install")
        XCTAssertEqual(AppStrings(.korean).appUpdateAvailableTitle("1.2.3"), "앱 1.2.3 업데이트 사용 가능")
        XCTAssertEqual(AppStrings(.english).appUpdateAvailableTitle("1.2.3"), "App 1.2.3 available")
    }

    func testLocalizedTextResolvesExactAndFallbackValues() {
        let translated: LocalizedText = [.korean: "한국어", .english: "English"]
        let fallback: LocalizedText = [.korean: "한국어만 있음"]

        XCTAssertEqual(translated.value(for: .english), "English")
        XCTAssertEqual(fallback.value(for: .english), "한국어만 있음")
    }

    func testLocalizedTextProvidesFallbackWhenLanguageValueIsMissing() throws {
        let source = try appLanguageSource

        XCTAssertTrue(source.contains("public func value(for language: AppLanguage"))
        XCTAssertTrue(source.contains("values[language]"))
        XCTAssertTrue(source.contains("values[.korean]"))
    }

    func testAppStringsUsesExtensibleLocalizedTextInsteadOfTwoLanguageHelper() throws {
        let source = try appLanguageSource

        XCTAssertTrue(source.contains("public struct LocalizedText"))
        XCTAssertFalse(source.contains("public func text(korean: String, english: String)"))
    }
}
