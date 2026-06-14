import Engine

public enum UpdatePolicy: Equatable, Sendable {
    case automatic
    case requiresConfirmation(reason: String)
    case unavailable(reason: String)

    public static func evaluate(_ pkg: PackageInfo) -> UpdatePolicy {
        if pkg.flags.contains(.dependency) {
            return .unavailable(reason: "하위 의존성은 부모 패키지 업데이트에 맡깁니다")
        }
        if pkg.statusReason == .inventoryOnly || pkg.metadata["kind"] == "mcp" {
            return .unavailable(reason: "인벤토리 항목이라 업데이트 대상이 아닙니다")
        }
        if pkg.flags.contains(.runtime) {
            return .unavailable(reason: "런타임은 글로벌 패키지·MCP가 묶여 있어 자동 실행에서 제외합니다")
        }
        if pkg.flags.contains(.pinned) {
            return .unavailable(reason: "pinned 패키지는 자동 실행에서 제외합니다")
        }
        if pkg.status == .unknown {
            return .requiresConfirmation(reason: "최신 버전 판단이 불확실해 업데이트 명령 실행 전 확인이 필요합니다")
        }
        guard pkg.status == .outdated else {
            return .unavailable(reason: "업데이트 대상이 아닙니다")
        }
        if pkg.flags.contains(.cask) {
            return .requiresConfirmation(
                reason: "GUI 앱(cask)은 앱 종료·재시작·권한 요청이 생길 수 있어 자동 일괄에서 제외합니다")
        }
        if pkg.manager == .macAppStore {
            return .requiresConfirmation(
                reason: "Mac App Store 앱은 권한 요청이나 대용량 다운로드가 생길 수 있어 자동 일괄에서 제외합니다")
        }
        if pkg.risk == .high {
            return .requiresConfirmation(reason: "위험 등급 업데이트라 실행 전 확인이 필요합니다")
        }
        guard let risk = pkg.risk, risk < .high else {
            return .requiresConfirmation(reason: "위험도 판단이 불확실해 실행 전 확인이 필요합니다")
        }
        return .automatic
    }

    public var isAutomatic: Bool {
        self == .automatic
    }

    public var requiresConfirmation: Bool {
        if case .requiresConfirmation = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .automatic:
            return nil
        case .requiresConfirmation(let reason), .unavailable(let reason):
            return reason
        }
    }
}
