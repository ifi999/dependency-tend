public struct PackageEmptyStatePresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let restoreHiddenPackagesTitle: String?
    public let restoreHiddenSourcesTitle: String?

    public static func make(isScanning: Bool,
                            visibilityFilter: PackageVisibilityFilter,
                            showUpToDate: Bool,
                            hiddenPackageCount: Int,
                            hiddenSourceCount: Int) -> PackageEmptyStatePresentation {
        make(isScanning: isScanning,
             visibilityFilter: visibilityFilter,
             showUpToDate: showUpToDate,
             hiddenPackageCount: hiddenPackageCount,
             hiddenSourceCount: hiddenSourceCount,
             language: .korean)
    }

    public static func make(isScanning: Bool,
                            visibilityFilter: PackageVisibilityFilter,
                            showUpToDate: Bool,
                            hiddenPackageCount: Int,
                            hiddenSourceCount: Int,
                            language: AppLanguage) -> PackageEmptyStatePresentation {
        if isScanning {
            return PackageEmptyStatePresentation(
                title: language == .korean ? "스캔 중" : "Scanning",
                detail: language == .korean
                    ? "업데이트 소스를 확인하고 있습니다."
                    : "Checking update sources.",
                restoreHiddenPackagesTitle: nil,
                restoreHiddenSourcesTitle: nil)
        }
        if visibilityFilter != .all {
            return PackageEmptyStatePresentation(
                title: language == .korean
                    ? "\(visibilityFilter.displayName(language: language)) 항목 없음"
                    : "No \(visibilityFilter.displayName(language: language)) items",
                detail: language == .korean
                    ? "현재 필터에 해당하는 직접 설치 패키지가 없습니다."
                    : "No directly installed packages match the current filter.",
                restoreHiddenPackagesTitle: nil,
                restoreHiddenSourcesTitle: nil)
        }
        if hiddenSourceCount > 0 {
            let packagePart = hiddenPackageCount > 0 ? ", 숨긴 패키지 \(hiddenPackageCount)개" : ""
            let englishPackagePart = hiddenPackageCount > 0 ? ", \(hiddenPackageCount) hidden packages" : ""
            return PackageEmptyStatePresentation(
                title: language == .korean
                    ? (hiddenPackageCount > 0 ? "숨긴 항목 있음" : "숨긴 소스 있음")
                    : (hiddenPackageCount > 0 ? "Hidden items" : "Hidden sources"),
                detail: language == .korean
                    ? "숨긴 업데이트 소스 \(hiddenSourceCount)개\(packagePart)가 목록에서 제외되어 있습니다. 필요하면 복원할 수 있습니다."
                    : "\(hiddenSourceCount) hidden update sources\(englishPackagePart) are excluded from the list. Restore them if needed.",
                restoreHiddenPackagesTitle: hiddenPackageCount > 0
                    ? (language == .korean ? "숨긴 패키지 복원" : "Restore hidden packages")
                    : nil,
                restoreHiddenSourcesTitle: language == .korean ? "숨긴 소스 복원" : "Restore hidden sources")
        }
        if hiddenPackageCount > 0 {
            return PackageEmptyStatePresentation(
                title: language == .korean ? "숨긴 패키지 있음" : "Hidden packages",
                detail: language == .korean
                    ? "숨김/무시한 항목이 목록에서 제외되어 있습니다. 필요하면 모두 복원할 수 있습니다."
                    : "Hidden or ignored items are excluded from the list. Restore them if needed.",
                restoreHiddenPackagesTitle: language == .korean ? "숨김 모두 복원" : "Restore all hidden items",
                restoreHiddenSourcesTitle: nil)
        }
        if !showUpToDate {
            return PackageEmptyStatePresentation(
                title: language == .korean ? "업데이트 대상 없음" : "No updates",
                detail: language == .korean
                    ? "최신 상태 항목까지 보려면 상단의 최신 포함을 켜세요."
                    : "Turn on Include current at the top to show up-to-date items too.",
                restoreHiddenPackagesTitle: nil,
                restoreHiddenSourcesTitle: nil)
        }
        return PackageEmptyStatePresentation(
            title: language == .korean ? "표시할 패키지 없음" : "No packages to show",
            detail: language == .korean
                ? "감지된 업데이트 소스에 표시할 항목이 없습니다."
                : "Detected update sources do not have any displayable items.",
            restoreHiddenPackagesTitle: nil,
            restoreHiddenSourcesTitle: nil)
    }
}
