import Foundation

public enum AppLanguage: String, CaseIterable, Equatable, Identifiable, Sendable {
    case korean = "ko"
    case english = "en"

    public var id: String { rawValue }

    public var menuTitle: String {
        switch self {
        case .korean:
            return "한국어"
        case .english:
            return "English"
        }
    }
}

public struct LocalizedText: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    private let values: [AppLanguage: String]

    public init(_ values: [AppLanguage: String]) {
        self.values = values
    }

    public init(dictionaryLiteral elements: (AppLanguage, String)...) {
        self.init(Dictionary(uniqueKeysWithValues: elements))
    }

    public func value(for language: AppLanguage) -> String {
        values[language] ?? values[.korean] ?? values[.english] ?? values.values.first ?? ""
    }
}

public struct LanguageStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "appLanguage") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppLanguage {
        guard let raw = defaults.string(forKey: key),
              let language = AppLanguage(rawValue: raw) else {
            return .korean
        }
        return language
    }

    public func save(_ language: AppLanguage) throws {
        defaults.set(language.rawValue, forKey: key)
    }
}

public struct AppStrings: Equatable, Sendable {
    public let language: AppLanguage

    public init(_ language: AppLanguage) {
        self.language = language
    }

    private func localized(_ text: LocalizedText) -> String {
        text.value(for: language)
    }

    public var refreshNow: String {
        localized([.korean: "지금 다시 스캔", .english: "Scan now"])
    }

    public var languageMenuAccessibilityLabel: String {
        localized([.korean: "언어 선택", .english: "Language"])
    }

    public var languageMenuTip: String {
        localized([.korean: "표시 언어를 선택합니다", .english: "Choose display language"])
    }

    public var safeUpdatesActionTitle: String {
        localized([.korean: "자동 실행 가능 업데이트", .english: "Safe updates"])
    }

    public var checkAppUpdateTitle: String {
        localized([.korean: "앱 업데이트 확인", .english: "Check app update"])
    }

    public var appUpdateCheckingTitle: String {
        localized([.korean: "앱 업데이트 확인 중", .english: "Checking app update"])
    }

    public var appUpdateDownloadTitle: String {
        localized([.korean: "다운로드", .english: "Download"])
    }

    public func appUpdateDownloadingTitle(_ version: String) -> String {
        localized([.korean: "앱 \(version) 다운로드 중",
                   .english: "Downloading app \(version)"])
    }

    public var appUpdateInstallTitle: String {
        localized([.korean: "설치", .english: "Install"])
    }

    public var appUpdateInstallingTitle: String {
        localized([.korean: "앱 업데이트 설치 중",
                   .english: "Installing app update"])
    }

    public func appUpdateReadyToInstallTitle(_ version: String) -> String {
        localized([.korean: "앱 \(version) 설치 준비됨",
                   .english: "App \(version) ready to install"])
    }

    public func appUpdateAvailableTitle(_ version: String) -> String {
        localized([.korean: "앱 \(version) 업데이트 사용 가능",
                   .english: "App \(version) available"])
    }

    public func appUpdateUpToDateTitle(_ version: String) -> String {
        localized([.korean: "앱 최신 상태 \(version)",
                   .english: "App is current \(version)"])
    }

    public var appUpdateFailedTitle: String {
        localized([.korean: "앱 업데이트 확인 실패", .english: "App update check failed"])
    }

    public var appUpdateReleaseNotesTitle: String {
        localized([.korean: "릴리즈 노트", .english: "Release notes"])
    }

    public var moreActionsAccessibilityLabel: String {
        localized([.korean: "추가 작업", .english: "More actions"])
    }

    public var moreActionsTip: String {
        localized([.korean: "업데이트, 정리, 소스, 로그, 종료",
                   .english: "Updates, cleanup, sources, logs, quit"])
    }

    public var quitTitle: String {
        localized([.korean: "종료", .english: "Quit"])
    }

    public var includeUpToDateTitle: String {
        localized([.korean: "최신 포함", .english: "Include current"])
    }

    public func includeUpToDateTip(isAllFilter: Bool) -> String {
        if isAllFilter {
            return localized([.korean: "직접 설치된 최신 상태 항목과 MCP 설정까지 모두 표시",
                              .english: "Show current direct installs and MCP configuration entries"])
        }
        return localized([.korean: "필터 중에는 업데이트 대상만 의미가 있어 비활성화됩니다",
                          .english: "Only update candidates are meaningful while a filter is active"])
    }

    public var guideLinkTitle: String {
        localized([.korean: "가이드", .english: "Guide"])
    }

    public func sourceToggleAccessibilityLabel(manager: String, isOpen: Bool) -> String {
        if isOpen {
            return localized([.korean: "\(manager) 접기", .english: "Collapse \(manager)"])
        }
        return localized([.korean: "\(manager) 펼치기", .english: "Expand \(manager)"])
    }

    public func sourceToggleTip(isOpen: Bool) -> String {
        if isOpen {
            return localized([.korean: "소스 접기", .english: "Collapse source"])
        }
        return localized([.korean: "소스 펼치기", .english: "Expand source"])
    }

    public func npmTreeGroupTitle(_ tree: String) -> String {
        localized([.korean: "node \(tree) 소속", .english: "node \(tree) tree"])
    }

    public var npmTreeGroupTip: String {
        localized([.korean: "이 트리의 npm으로 설치/업데이트됩니다",
                   .english: "Installs and updates with npm from this tree"])
    }

    public var updateProgressTip: String {
        localized([.korean: "업데이트 명령 실행 후 결과 스캔까지 완료되면 사라집니다",
                   .english: "Clears after the update command and follow-up scan finish"])
    }

    public func runtimeCount(_ count: Int) -> String {
        localized([.korean: "런타임 \(count)개", .english: "\(count) runtimes"])
    }

    public func automaticUpdateTitle(_ count: Int) -> String {
        localized([.korean: "자동 업데이트 \(count)", .english: "Auto update \(count)"])
    }

    public func automaticUpdateTip(manager: String) -> String {
        localized([.korean: "\(manager)의 자동 실행 가능 항목만 업데이트. GUI 앱(cask/MAS)은 개별 확인으로 분리됩니다",
                   .english: "Updates only safe items in \(manager). GUI apps (cask/MAS) stay separated for manual confirmation."])
    }

    public var sourceSummaryTip: String {
        localized([.korean: "직접 설치 패키지 기준", .english: "Direct installs only"])
    }

    public var launchAtLoginTitle: String {
        localized([.korean: "로그인 시 자동 시작", .english: "Launch at login"])
    }

    public func bulkUpdateTitle(_ count: Int) -> String {
        localized([.korean: "자동 실행 가능 일괄 업데이트 (\(count))",
                   .english: "Bulk safe updates (\(count))"])
    }

    public func togglePruneTitle(isShowing: Bool) -> String {
        isShowing
            ? localized([.korean: "정리 닫기", .english: "Hide cleanup"])
            : localized([.korean: "정리 보기", .english: "Show cleanup"])
    }

    public func toggleSourcesTitle(isShowing: Bool) -> String {
        isShowing
            ? localized([.korean: "소스 닫기", .english: "Hide sources"])
            : localized([.korean: "소스 보기", .english: "Show sources"])
    }

    public func toggleLogTitle(isShowing: Bool) -> String {
        isShowing
            ? localized([.korean: "로그 닫기", .english: "Hide logs"])
            : localized([.korean: "로그 보기", .english: "Show logs"])
    }

    public func compactPruneTitle(isShowing: Bool) -> String {
        isShowing
            ? localized([.korean: "정리 닫기", .english: "Hide cleanup"])
            : localized([.korean: "정리", .english: "Cleanup"])
    }

    public func compactSourcesTitle(isShowing: Bool) -> String {
        isShowing
            ? localized([.korean: "소스 닫기", .english: "Hide sources"])
            : localized([.korean: "소스", .english: "Sources"])
    }

    public func compactLogTitle(isShowing: Bool) -> String {
        isShowing
            ? localized([.korean: "로그 닫기", .english: "Hide logs"])
            : localized([.korean: "로그", .english: "Logs"])
    }

    public var pruneTip: String {
        localized([.korean: "잔재 가지치기 — 증거 기반 제안과 복구 장부",
                   .english: "Cleanup with evidence-based suggestions and restore history"])
    }

    public var sourcesTip: String {
        localized([.korean: "지원 업데이트 소스 감지 상태",
                   .english: "Detected status for supported update sources"])
    }

    public var runSelectedTitle: String {
        localized([.korean: "선택 항목 실행", .english: "Run selected"])
    }

    public var copyCommandTitle: String {
        localized([.korean: "명령 복사", .english: "Copy command"])
    }

    public var copyCommandsTitle: String {
        localized([.korean: "명령 복사", .english: "Copy commands"])
    }

    public var cancelTitle: String {
        localized([.korean: "취소", .english: "Cancel"])
    }

    public func selectPackageAccessibilityLabel(_ name: String) -> String {
        localized([.korean: "\(name) 선택", .english: "Select \(name)"])
    }

    public func riskAccessibilityLabel(_ label: String) -> String {
        localized([.korean: "위험도 \(label)", .english: "Risk \(label)"])
    }

    public var staleCandidateText: String {
        localized([.korean: "상태가 바뀌었습니다 — 다시 미리보기를 열어주세요",
                   .english: "Status changed. Open the preview again."])
    }

    public var staleCandidateTip: String {
        localized([.korean: "현재 목록과 맞지 않아 실행 대상에서 제외했습니다",
                   .english: "Excluded because it no longer matches the current list"])
    }

    public func bulkPreviewTitle(manager: String?) -> String {
        if let manager {
            return localized([.korean: "\(manager) 업데이트 미리보기",
                              .english: "\(manager) update preview"])
        }
        return localized([.korean: "자동 실행 가능 업데이트 미리보기",
                          .english: "Safe update preview"])
    }

    public var updateSourcesTitle: String {
        localized([.korean: "업데이트 소스", .english: "Update sources"])
    }

    public func sourceHealthCount(_ count: Int) -> String {
        localized([.korean: "\(count)개 확인", .english: "\(count) checked"])
    }

    public func hiddenPackagesTitle(_ count: Int) -> String {
        localized([.korean: "숨긴 패키지 \(count)개", .english: "\(count) hidden packages"])
    }

    public var restoreAllTitle: String {
        localized([.korean: "모두 복원", .english: "Restore all"])
    }

    public var restoreHiddenPackagesTip: String {
        localized([.korean: "무시/숨김 처리한 패키지를 다시 표시합니다",
                   .english: "Show ignored or hidden packages again"])
    }

    public var checkingSourcesTitle: String {
        localized([.korean: "소스 확인 중", .english: "Checking sources"])
    }

    public var notScannedYetTitle: String {
        localized([.korean: "아직 스캔 전", .english: "Not scanned yet"])
    }

    public var toolDiagnosticsTitle: String {
        localized([.korean: "환경 진단", .english: "Environment diagnostics"])
    }

    public var detectedTitle: String {
        localized([.korean: "감지됨", .english: "Detected"])
    }

    public var missingTitle: String {
        localized([.korean: "없음", .english: "Missing"])
    }

    public var executableMissingText: String {
        localized([.korean: "실행 파일을 찾지 못했습니다", .english: "Executable not found"])
    }

    public func executableMissingTip(_ name: String) -> String {
        localized([.korean: "\(name) 실행 파일을 찾지 못했습니다",
                   .english: "\(name) executable not found"])
    }

    public var hiddenTitle: String {
        localized([.korean: "숨김", .english: "Hidden"])
    }

    public var restoreTitle: String {
        localized([.korean: "복원", .english: "Restore"])
    }

    public var hiddenSourceTip: String {
        localized([.korean: "메인 목록에서 숨긴 소스입니다. 복원하면 다시 표시됩니다",
                   .english: "This source is hidden from the main list. Restore it to show again."])
    }

    public func sourceAvailableText(count: Int) -> String {
        localized([.korean: "감지됨 · \(count)개", .english: "Detected · \(count)"])
    }

    public var sourceUnavailableText: String {
        localized([.korean: "미설치", .english: "Not installed"])
    }

    public var sourceEmptyText: String {
        localized([.korean: "항목 없음", .english: "No items"])
    }

    public var sourceFailedText: String {
        localized([.korean: "오류", .english: "Error"])
    }

    public func sourceAvailableTip(manager: String) -> String {
        localized([.korean: "\(manager)에서 업데이트 대상을 확인했습니다",
                   .english: "Found update candidates from \(manager)"])
    }

    public func sourceUnavailableTip(manager: String) -> String {
        localized([.korean: "\(manager) CLI 또는 설정을 찾지 못했습니다",
                   .english: "Could not find the \(manager) CLI or configuration"])
    }

    public func sourceEmptyTip(manager: String) -> String {
        localized([.korean: "\(manager)에 표시할 항목이 없습니다",
                   .english: "\(manager) has no items to show"])
    }

    public func sourceScanFailedTip(manager: String) -> String {
        localized([.korean: "\(manager) 스캔에 실패했습니다",
                   .english: "\(manager) scan failed"])
    }

    public var panelSmallerAccessibilityLabel: String {
        localized([.korean: "패널 작게", .english: "Smaller panel"])
    }

    public var panelLargerAccessibilityLabel: String {
        localized([.korean: "패널 크게", .english: "Larger panel"])
    }

    public var riskHighTitle: String {
        localized([.korean: "높음", .english: "High"])
    }

    public var riskMediumTitle: String {
        localized([.korean: "보통", .english: "Medium"])
    }

    public var riskLowTitle: String {
        localized([.korean: "낮음", .english: "Low"])
    }

    public var riskUnknownTitle: String {
        localized([.korean: "알 수 없음", .english: "Unknown"])
    }

    public var notUpdateTargetRiskTitle: String {
        localized([.korean: "업데이트 대상 아님", .english: "Not an update target"])
    }

    public var currentRunLogTitle: String {
        localized([.korean: "현재 실행 로그", .english: "Current run log"])
    }

    public var copyLogTitle: String {
        localized([.korean: "로그 복사", .english: "Copy log"])
    }

    public var noLogText: String {
        localized([.korean: "(로그 없음)", .english: "(No logs)"])
    }

    public var updateHistoryTitle: String {
        localized([.korean: "업데이트 히스토리", .english: "Update history"])
    }

    public var noHistoryText: String {
        localized([.korean: "(히스토리 없음)", .english: "(No history)"])
    }

    public var mcpServerTip: String {
        localized([.korean: "~/.claude.json에 설정된 MCP 서버 — 업데이트는 이 명령을 제공하는 패키지/서비스 쪽에서 합니다",
                   .english: "MCP server configured in ~/.claude.json. Update the package or service that provides this command."])
    }

    public var relatedLinksTitle: String {
        localized([.korean: "관련 링크", .english: "Related links"])
    }

    public var pinnedPackageAccessibilityLabel: String {
        localized([.korean: "pinned 패키지", .english: "Pinned package"])
    }

    public var pinnedPackageTip: String {
        localized([.korean: "pinned — 의도적으로 고정된 패키지",
                   .english: "Pinned intentionally"])
    }

    public var ignoreTitle: String {
        localized([.korean: "무시", .english: "Ignore"])
    }

    public var hideFor30DaysTitle: String {
        localized([.korean: "30일 숨김", .english: "Hide 30 days"])
    }

    public var hideSourceTitle: String {
        localized([.korean: "소스 숨김", .english: "Hide source"])
    }

    public func packageActionsAccessibilityLabel(_ displayName: String) -> String {
        localized([.korean: "\(displayName) 작업", .english: "\(displayName) actions"])
    }

    public var hideOrIgnoreTip: String {
        localized([.korean: "숨김/무시", .english: "Hide or ignore"])
    }

    public var runningTitle: String {
        localized([.korean: "실행 중", .english: "Running"])
    }

    public var runTitle: String {
        localized([.korean: "실행", .english: "Run"])
    }

    public var updatedTitle: String {
        localized([.korean: "✓ 업데이트됨", .english: "✓ Updated"])
    }

    public var claudeRestartRequiredTip: String {
        localized([.korean: "적용에는 Claude Code 재시작이 필요합니다",
                   .english: "Restart Claude Code to apply"])
    }

    public var updatedThisRunTip: String {
        localized([.korean: "이번 실행에서 업데이트 완료", .english: "Updated in this run"])
    }

    public var recentFailurePrefix: String {
        localized([.korean: "최근 실패", .english: "Recent failure"])
    }

    public var copyFailureRecoveryCommandTip: String {
        localized([.korean: "터미널에서 직접 확인 후 실행할 명령을 복사합니다",
                   .english: "Copy the command to inspect and run in Terminal"])
    }

    public func failureRecoveryCommandAccessibilityLabel(_ displayName: String) -> String {
        localized([.korean: "\(displayName) 실패 복구 명령 복사",
                   .english: "Copy \(displayName) recovery command"])
    }

    public var runtimeUpdateBlockedReason: String {
        localized([.korean: "런타임 — 글로벌 패키지·MCP가 이 버전에 묶여 있어 원클릭 업데이트를 막아뒀습니다. 마이그레이션 계획 후 터미널에서 올리세요",
                   .english: "Runtime. Global packages and MCP entries are tied to this version, so one-click updates are blocked. Plan the migration and update in Terminal."])
    }

    public func pinnedUpdateBlockedReason(_ packageName: String) -> String {
        localized([.korean: "pinned — `brew unpin \(packageName)` 후 업데이트할 수 있습니다",
                   .english: "Pinned. Run `brew unpin \(packageName)` before updating."])
    }

    public var claudeCLIMissingUpdateReason: String {
        localized([.korean: "Claude CLI를 찾을 수 없어 업데이트할 수 없습니다",
                   .english: "Cannot update because the Claude CLI was not found"])
    }

    public var inventoryOnlyUpdateReason: String {
        localized([.korean: "인벤토리 항목이라 업데이트 대상이 아닙니다",
                   .english: "Inventory item; not an update target"])
    }

    public var reviewTitle: String {
        localized([.korean: "확인", .english: "Review"])
    }

    public var checkUpdateTitle: String {
        localized([.korean: "업데이트 확인", .english: "Check update"])
    }

    public var updateTitle: String {
        localized([.korean: "업데이트", .english: "Update"])
    }

    public var updateCommandCheckHelp: String {
        localized([.korean: "최신 버전 비교가 불가해 업데이트 명령으로 확인/실행합니다",
                   .english: "Version comparison is unavailable, so the update command checks and runs it"])
    }

    public var latestUnavailableUpdateHelp: String {
        localized([.korean: "최신 버전 정보가 없어 업데이트 명령으로 확인/실행합니다",
                   .english: "Latest version is unavailable, so the update command checks and runs it"])
    }

    public var recentlyUpdatedNeedsRestartHelp: String {
        localized([.korean: "적용에는 앱 재시작이 필요합니다",
                   .english: "Restart the app to apply"])
    }

    public var genericUnknownUpdateHelp: String {
        localized([.korean: "최신 버전 비교가 불가해 각 도구의 업데이트 명령으로 확인합니다",
                   .english: "Version comparison is unavailable, so the tool's update command checks it"])
    }

    public var packageLinkPackageTitle: String {
        localized([.korean: "패키지", .english: "Package"])
    }

    public var homepageTitle: String {
        localized([.korean: "홈페이지", .english: "Homepage"])
    }

    public var docsTitle: String {
        localized([.korean: "문서", .english: "Docs"])
    }

    public var releaseNotesTitle: String {
        localized([.korean: "릴리즈 노트", .english: "Release notes"])
    }

    public func remoteMCPVersionText(detail: String) -> String {
        localized([.korean: "원격 서버 · \(detail) — 서버 측에서 관리",
                   .english: "Remote server · \(detail) — managed server-side"])
    }

    public func localMCPVersionText(detail: String) -> String {
        localized([.korean: "로컬 실행 · \(detail)",
                   .english: "Local command · \(detail)"])
    }

    public var mcpConfigurationText: String {
        localized([.korean: "MCP 서버 설정", .english: "MCP server configuration"])
    }

    public var unknownUpdateCommandCheckText: String {
        localized([.korean: "업데이트 명령으로 확인 가능", .english: "Check with update command"])
    }

    public var latestUnavailableText: String {
        localized([.korean: "최신 버전 정보 없음", .english: "Latest version unavailable"])
    }

    public var inventoryText: String {
        localized([.korean: "인벤토리", .english: "Inventory"])
    }

    public var restartRequiredText: String {
        localized([.korean: "재시작 필요", .english: "Restart required"])
    }

    public var latestVersionNeedsCheckingText: String {
        localized([.korean: "최신 버전 확인 필요", .english: "Latest version needs checking"])
    }

    public var pruneSectionTitle: String {
        localized([.korean: "정리 — 잔재 가지치기", .english: "Cleanup - prune leftovers"])
    }

    public var noPruneLeftoversTitle: String {
        localized([.korean: "정리할 잔재 없음 ✓", .english: "No leftovers to clean up ✓"])
    }

    public var recentRemovalsTitle: String {
        localized([.korean: "최근 삭제 — 복구 가능", .english: "Recent removals - restorable"])
    }

    public var deleteTitle: String {
        localized([.korean: "삭제", .english: "Delete"])
    }

    public var deleteSuggestionTip: String {
        localized([.korean: "확인 단계를 거쳐 삭제합니다. 삭제 후에도 아래 장부에서 복구 가능",
                   .english: "Deletes after confirmation. You can restore from the history below."])
    }

    public var cleanupTitle: String {
        localized([.korean: "정리", .english: "Clean up"])
    }

    public var orphanCleanupTip: String {
        localized([.korean: "brew가 고아로 판단한 의존성입니다. 확인 후 brew autoremove를 실행합니다",
                   .english: "Dependencies that brew considers orphaned. After confirmation, runs brew autoremove."])
    }

    public func confirmDeleteTitle(name: String, tree: String) -> String {
        localized([.korean: "정말 삭제할까요? \(name) (\(tree))",
                   .english: "Delete \(name)? (\(tree))"])
    }

    public func orphanCleanupConfirmationTitle(_ count: Int) -> String {
        localized([.korean: "고아 의존성 \(count)개를 정리할까요?",
                   .english: "Clean up \(count) orphaned dependencies?"])
    }

    public var runBrewAutoremoveTitle: String {
        localized([.korean: "brew autoremove 실행", .english: "Run brew autoremove"])
    }

    public func orphanPreview(visible: String, remaining: Int) -> String {
        if remaining > 0 {
            return localized([.korean: "대상: \(visible) 외 \(remaining)개",
                              .english: "Targets: \(visible) and \(remaining) more"])
        }
        return localized([.korean: "대상: \(visible)", .english: "Targets: \(visible)"])
    }

    public func restoreRemovalTip(_ command: String) -> String {
        localized([.korean: "삭제 당시 버전으로 재설치: \(command)",
                   .english: "Reinstall the version recorded at removal: \(command)"])
    }
}
