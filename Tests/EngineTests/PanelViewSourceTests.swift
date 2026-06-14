import Foundation
import XCTest

final class PanelViewSourceTests: XCTestCase {
    private var panelViewCode: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent("Sources/DependencyTend/PanelView.swift"),
                                    encoding: .utf8)
            return sourceWithoutLineComments(source)
        }
    }

    private var packageRowViewCode: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent("Sources/DependencyTend/PackageRowView.swift"),
                                    encoding: .utf8)
            return sourceWithoutLineComments(source)
        }
    }

    private var logViewCode: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent("Sources/DependencyTend/LogView.swift"),
                                    encoding: .utf8)
            return sourceWithoutLineComments(source)
        }
    }

    private var pruneViewCode: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent("Sources/DependencyTend/PruneView.swift"),
                                    encoding: .utf8)
            return sourceWithoutLineComments(source)
        }
    }

    private var hoverTipCode: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let source = try String(contentsOf: root.appendingPathComponent("Sources/DependencyTend/HoverTip.swift"),
                                    encoding: .utf8)
            return sourceWithoutLineComments(source)
        }
    }

    func testIconOnlyControlsHaveExplicitAccessibilityLabels() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains(".accessibilityLabel(model.strings.refreshNow)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(model.strings.sourceToggleAccessibilityLabel"))
        XCTAssertTrue(source.contains(".accessibilityLabel(model.strings.panelSmallerAccessibilityLabel)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(model.strings.panelLargerAccessibilityLabel)"))
    }

    func testPanelHasManualLanguagePicker() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains("private var languagePicker: some View"))
        XCTAssertTrue(source.contains("ForEach(AppLanguage.allCases)"))
        XCTAssertTrue(source.contains("model.setLanguage(language)"))
        XCTAssertTrue(source.contains("model.strings.languageMenuAccessibilityLabel"))
        XCTAssertTrue(source.contains("languagePicker"))
    }

    func testFooterUsesAdaptiveLayoutForCompactPanel() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("secondaryFooterActions"))
    }

    func testHeaderHasActionMenuForSecondaryActions() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains("private var headerActionMenu: some View"))
        XCTAssertTrue(source.contains("Image(systemName: \"ellipsis.circle\")"))
        XCTAssertTrue(source.contains("Button(model.strings.checkAppUpdateTitle)"))
        XCTAssertTrue(source.contains("Button(model.strings.safeUpdatesActionTitle)"))
        XCTAssertTrue(source.contains("Button(model.strings.togglePruneTitle(isShowing: showPrune"))
        XCTAssertTrue(source.contains("Button(model.strings.toggleSourcesTitle(isShowing: showSources"))
        XCTAssertTrue(source.contains("Button(model.strings.toggleLogTitle(isShowing: showLog"))
    }

    func testPanelShowsAppUpdateCheckStateInline() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains("if model.appUpdateState != .idle { appUpdateStatusStrip(model.appUpdateState) }"))
        XCTAssertTrue(source.contains("Task { await model.checkForAppUpdate() }"))
        XCTAssertTrue(source.contains("private func appUpdateStatusStrip(_ state: AppUpdateState) -> some View"))
        XCTAssertTrue(source.contains("model.strings.appUpdateCheckingTitle"))
        XCTAssertTrue(source.contains("model.strings.appUpdateAvailableTitle(release.versionString)"))
        XCTAssertTrue(source.contains("Button(model.strings.appUpdateDownloadTitle)"))
        XCTAssertTrue(source.contains("Task { await model.prepareAppUpdate(release) }"))
        XCTAssertTrue(source.contains("model.canPrepareAppUpdate"))
        XCTAssertTrue(source.contains("Button(model.strings.appUpdateInstallTitle)"))
        XCTAssertTrue(source.contains("Task { await model.installAppUpdate(prepared) }"))
        XCTAssertTrue(source.contains("model.canInstallAppUpdate"))
        XCTAssertTrue(source.contains("model.strings.appUpdateInstallingTitle"))
        XCTAssertTrue(source.contains("Link(model.strings.appUpdateReleaseNotesTitle"))
    }

    func testTopErrorBannerUsesProminentScanErrorsOnly() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains("if !model.prominentScanErrors.isEmpty { errorBanner }"))
        XCTAssertTrue(source.contains("ForEach(model.prominentScanErrors"))
    }

    func testPanelMigratesStoredDefaultToRegularOnce() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains("panelSizePresetDefaultMigrationV3"))
        XCTAssertTrue(source.contains("migrateDefaultPanelSizeIfNeeded()"))
        XCTAssertTrue(source.contains("PanelSizePreset.defaultedRawValueAfterDefaultMigration(panelSizeRaw)"))
    }

    func testPackageRowConfirmationUsesSafetyPresentation() throws {
        let source = try packageRowViewCode

        XCTAssertTrue(source.contains("UpdateConfirmationPresentation.make(for: pkg, language: strings.language)"))
        XCTAssertTrue(source.contains("confirmationPresentation.title"))
        XCTAssertTrue(source.contains("confirmationPresentation.detail"))
        XCTAssertTrue(source.contains("confirmationPresentation.actionHint"))
    }

    func testPanelUsesLanguageAwarePresentationAPIs() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains("filter.displayName(language: model.language)"))
        XCTAssertTrue(source.contains("filter.tip(language: model.language)"))
        XCTAssertTrue(source.contains("PackageEmptyStatePresentation.make("))
        XCTAssertTrue(source.contains("language: model.language"))
        XCTAssertTrue(source.contains("progress.presentation(language: model.language)"))
        XCTAssertTrue(source.contains("UpdateSourceSummaryPresentation.text(for: visible, language: model.language)"))
    }

    func testViewsDoNotInlineBilingualStringPairs() throws {
        XCTAssertFalse(try panelViewCode.contains("text(korean:"))
        XCTAssertFalse(try packageRowViewCode.contains("text(korean:"))
        XCTAssertFalse(try logViewCode.contains("text(korean:"))
        XCTAssertFalse(try pruneViewCode.contains("text(korean:"))
    }

    func testPanelPassesFailureTerminalCommandToPackageRows() throws {
        let source = try panelViewCode

        XCTAssertTrue(source.contains("updateFailureTerminalCommand: model.lastUpdateFailureTerminalCommands[pkg.id]"))
    }

    func testPackageRowOffersCopyCommandForPermissionFailures() throws {
        let source = try packageRowViewCode

        XCTAssertTrue(source.contains("let updateFailureTerminalCommand: String?"))
        XCTAssertTrue(source.contains("Button(strings.copyCommandTitle)"))
        XCTAssertTrue(source.contains("NSPasteboard.general"))
    }

    func testHoverTipHasReadableMinimumWidth() throws {
        let source = try hoverTipCode

        XCTAssertTrue(source.contains("minTipWidth"))
        XCTAssertTrue(source.contains(".frame(minWidth: Self.minTipWidth"))
        XCTAssertFalse(source.contains(".frame(maxWidth: Self.maxTipWidth, alignment: .leading)"))
    }

    private func sourceWithoutLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(stripLineComment)
            .joined(separator: "\n")
    }

    private func stripLineComment(_ line: Substring) -> String {
        var output = ""
        var index = line.startIndex
        var isInsideString = false
        var isEscaping = false

        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
                output.append(character)
            } else if character == "/", next < line.endIndex, line[next] == "/" {
                break
            } else {
                output.append(character)
            }
            index = next
        }

        return output
    }
}
