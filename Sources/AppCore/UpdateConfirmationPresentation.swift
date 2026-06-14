import Engine

public struct UpdateConfirmationPresentation: Equatable, Sendable {
    public let title: String
    public let versionLine: String
    public let detail: String
    public let actionHint: String

    public static func make(for pkg: PackageInfo) -> UpdateConfirmationPresentation {
        make(for: pkg, language: .korean)
    }

    public static func make(for pkg: PackageInfo, language: AppLanguage) -> UpdateConfirmationPresentation {
        let policyReason = localizedPolicyReason(for: pkg, language: language)
        let title: String
        let detail: String
        let actionHint: String

        if pkg.flags.contains(.cask) {
            title = language == .korean ? "앱 업데이트 확인" : "Confirm app update"
            detail = language == .korean
                ? "GUI 앱(cask)은 앱 종료·재시작·권한 요청이 생길 수 있습니다. \(policyReason)"
                : "GUI apps (cask) may quit, restart, or request permissions. \(policyReason)"
            actionHint = language == .korean
                ? "열려 있는 앱과 작업을 저장한 뒤 실행하세요."
                : "Save open work before running this update."
        } else if pkg.manager == .macAppStore {
            title = language == .korean ? "앱 업데이트 확인" : "Confirm app update"
            detail = language == .korean
                ? "Mac App Store 앱은 권한 요청이나 대용량 다운로드가 생길 수 있습니다. \(policyReason)"
                : "Mac App Store apps may request permissions or download large updates. \(policyReason)"
            actionHint = language == .korean
                ? "시간 여유가 있을 때 실행하고, 필요한 작업을 먼저 저장하세요."
                : "Run this when you have time, and save important work first."
        } else if pkg.status == .unknown {
            title = language == .korean ? "업데이트 확인" : "Confirm update"
            detail = language == .korean
                ? "\(policyReason) 최신/변경 범위를 앱 안에서 단정할 수 없습니다."
                : "\(policyReason) The latest version and change scope cannot be determined inside the app."
            actionHint = language == .korean
                ? "업데이트 명령 실행 결과와 로그를 확인하세요."
                : "Check the update command output and logs after running it."
        } else if pkg.risk == .high {
            title = language == .korean ? "위험 업데이트 확인" : "Confirm risky update"
            detail = highRiskDetail(for: pkg, fallback: policyReason, language: language)
            actionHint = language == .korean
                ? "릴리즈 노트와 사용 중인 도구 영향을 확인한 뒤 실행하세요."
                : "Review release notes and tool impact before running this update."
        } else {
            title = language == .korean ? "업데이트 확인" : "Confirm update"
            detail = policyReason
            actionHint = language == .korean
                ? "영향 범위를 확인한 뒤 실행하세요."
                : "Confirm the impact before running this update."
        }

        return UpdateConfirmationPresentation(title: title,
                                              versionLine: versionLine(for: pkg, language: language),
                                              detail: detail,
                                              actionHint: actionHint)
    }

    private static func localizedPolicyReason(for pkg: PackageInfo, language: AppLanguage) -> String {
        if language == .korean {
            return UpdatePolicy.evaluate(pkg).reason ?? "\(pkg.name)은 실행 전 확인이 필요합니다"
        }
        switch UpdatePolicy.evaluate(pkg) {
        case .automatic:
            return "\(pkg.name) can run automatically."
        case .requiresConfirmation:
            switch pkg.status {
            case .unknown:
                return "The latest version cannot be determined, so confirmation is required before running the update command."
            case .outdated where pkg.risk == .high:
                return "This is a high-risk update, so confirmation is required before running it."
            default:
                return "\(pkg.name) requires confirmation before running."
            }
        case .unavailable:
            return "\(pkg.name) cannot be updated automatically."
        }
    }

    private static func versionLine(for pkg: PackageInfo, language: AppLanguage) -> String {
        switch pkg.status {
        case .outdated:
            let label = language == .korean ? "위험" : "risk"
            return "\(pkg.current ?? "-") → \(pkg.latest ?? "-") · \(label) \(riskText(pkg.risk, language: language))"
        case .unknown:
            if let current = pkg.current {
                return language == .korean
                    ? "\(current) · 최신 버전 확인 필요"
                    : "\(current) · needs latest check"
            }
            return language == .korean ? "최신 버전 확인 필요" : "Needs latest check"
        case .upToDate:
            return pkg.current ?? (language == .korean ? "업데이트 대상 아님" : "Not an update target")
        }
    }

    private static func highRiskDetail(for pkg: PackageInfo, fallback: String, language: AppLanguage) -> String {
        if pkg.flags.contains(.major) {
            return language == .korean
                ? "major 버전 변경은 호환성 문제가 생길 수 있습니다. \(fallback)"
                : "Major version changes can introduce compatibility issues. \(fallback)"
        }
        if pkg.flags.contains(.pinned) {
            return language == .korean
                ? "고정된 패키지는 의도적으로 버전을 묶어둔 상태일 수 있습니다. \(fallback)"
                : "Pinned packages may be intentionally held at this version. \(fallback)"
        }
        if pkg.flags.contains(.runtime) {
            return language == .korean
                ? "런타임 업데이트는 글로벌 패키지와 MCP 실행 경로에 영향을 줄 수 있습니다. \(fallback)"
                : "Runtime updates can affect global packages and MCP execution paths. \(fallback)"
        }
        return fallback
    }

    private static func riskText(_ risk: Risk?, language: AppLanguage) -> String {
        switch risk {
        case .high:
            return language == .korean ? "높음" : "high"
        case .medium:
            return language == .korean ? "보통" : "medium"
        case .low:
            return language == .korean ? "낮음" : "low"
        case nil:
            return language == .korean ? "알 수 없음" : "unknown"
        }
    }
}
