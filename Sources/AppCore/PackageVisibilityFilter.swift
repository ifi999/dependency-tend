import Engine

public enum PackageVisibilityFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case automatic
    case requiresConfirmation

    public var displayName: String {
        displayName(language: .korean)
    }

    public func displayName(language: AppLanguage) -> String {
        switch self {
        case .all where language == .korean:
            return "전체"
        case .all:
            return "All"
        case .automatic where language == .korean:
            return "자동"
        case .automatic:
            return "Auto"
        case .requiresConfirmation where language == .korean:
            return "⚠ 확인"
        case .requiresConfirmation:
            return "⚠ Confirm"
        }
    }

    public var tip: String {
        tip(language: .korean)
    }

    public func tip(language: AppLanguage) -> String {
        switch self {
        case .all where language == .korean:
            return "모든 항목 표시"
        case .all:
            return "Show all items"
        case .automatic where language == .korean:
            return "자동 실행 가능 — formula/CLI 위주. GUI 앱(cask/MAS)은 개별 확인으로 분리됩니다"
        case .automatic:
            return "Safe automatic updates — mostly formula/CLI items. GUI apps (cask/MAS) stay separate for individual confirmation"
        case .requiresConfirmation where language == .korean:
            return "실행 전 확인이 필요한 업데이트 — GUI 앱(cask/MAS), major 점프, 위험도 불확실 항목 등"
        case .requiresConfirmation:
            return "Updates requiring confirmation — GUI apps (cask/MAS), major jumps, uncertain risk, and similar cases"
        }
    }

    public func includes(_ pkg: PackageInfo, showUpToDate: Bool) -> Bool {
        if pkg.metadata["kind"] == "mcp" {
            return self == .all && showUpToDate
        }
        switch self {
        case .all:
            return showUpToDate || pkg.status != .upToDate
        case .automatic:
            return UpdatePolicy.evaluate(pkg).isAutomatic
        case .requiresConfirmation:
            return UpdatePolicy.evaluate(pkg).requiresConfirmation
        }
    }
}
