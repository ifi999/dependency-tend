import Foundation

public enum ManagerID: String, Codable, CaseIterable, Sendable {
    case homebrew, npmGlobal, claudePlugin
    case macAppStore, pipx, uvTool, cargoInstall
    case vscodeExtensions, cursorExtensions
    case pnpmGlobal, yarnGlobal, bunGlobal

    public var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .npmGlobal: return "npm (global)"
        case .claudePlugin: return "Claude Plugins"
        case .macAppStore: return "Mac App Store"
        case .pipx: return "pipx"
        case .uvTool: return "uv tools"
        case .cargoInstall: return "Cargo installs"
        case .vscodeExtensions: return "VS Code Extensions"
        case .cursorExtensions: return "Cursor Extensions"
        case .pnpmGlobal: return "pnpm (global)"
        case .yarnGlobal: return "Yarn (global)"
        case .bunGlobal: return "Bun (global)"
        }
    }
}

public enum PackageStatus: String, Codable, Sendable {
    case upToDate, outdated, unknown
}

public enum PackageStatusReason: String, Codable, Sendable, Equatable {
    case latestUnavailable
    case updateCommandCheck
    case inventoryOnly
    case recentlyUpdatedNeedsRestart
}

public enum Risk: Int, Codable, Sendable, Comparable {
    case low = 0, medium = 1, high = 2
    public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PackageFlag: String, Codable, Sendable {
    case pinned, major, minor, patch, cask
    /// 직접 설치가 아니라 다른 패키지가 끌고 온 의존성 (brew leaves 기준)
    case dependency
    /// 다른 생태계가 올라타 있는 런타임(node 등) — 원클릭/일괄 업데이트 대상이 아니다
    case runtime
}

public struct PackageInfo: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let manager: ManagerID
    public var current: String?
    public var latest: String?
    public var status: PackageStatus
    public var statusReason: PackageStatusReason?
    public var risk: Risk?
    public var flags: Set<PackageFlag>
    public var metadata: [String: String]

    // formula/cask 이름 충돌(예: docker) 방지를 위해 kind를 id에 포함
    public var id: String {
        let kind = flags.contains(.cask) ? "cask" : "pkg"
        // 같은 패키지가 여러 node 트리에 설치될 수 있다 (npm 등) — 트리로 구분
        let tree = metadata["tree"].map { ":\($0)" } ?? ""
        return "\(manager.rawValue):\(kind)\(tree):\(name)"
    }

    public init(name: String, manager: ManagerID, current: String? = nil, latest: String? = nil,
                status: PackageStatus = .unknown, statusReason: PackageStatusReason? = nil,
                risk: Risk? = nil,
                flags: Set<PackageFlag> = [], metadata: [String: String] = [:]) {
        self.name = name
        self.manager = manager
        self.current = current
        self.latest = latest
        self.status = status
        self.statusReason = statusReason
        self.risk = risk
        self.flags = flags
        self.metadata = metadata
    }
}

public struct ManagerAdvisory: Codable, Sendable, Hashable {
    public let manager: ManagerID
    public let message: String
    /// 수동 조치 가이드 링크 (예: Node EOL 마이그레이션 안내)
    public let url: String?
    public init(manager: ManagerID, message: String, url: String? = nil) {
        self.manager = manager
        self.message = message
        self.url = url
    }
}

/// 어댑터 한 개의 스캔 결과 (risk 분류 전 raw 데이터)
public struct AdapterScan: Sendable, Equatable {
    public var packages: [PackageInfo]
    public var advisories: [ManagerAdvisory]
    public init(packages: [PackageInfo], advisories: [ManagerAdvisory] = []) {
        self.packages = packages
        self.advisories = advisories
    }
}

public struct UpdateCommand: Sendable, Equatable, Codable {
    public let executable: URL
    public let arguments: [String]
    /// ProcessInfo 환경 위에 머지되는 추가/오버라이드 변수 (예: nvm npm의 PATH)
    public let environment: [String: String]
    public var displayString: String {
        let env = environment.keys.sorted().map { key in
            "\(key)=\(Self.shellEscaped(environment[key] ?? ""))"
        }
        let command = [Self.shellEscaped(executable.path)] + arguments.map(Self.shellEscaped)
        return (env + command).joined(separator: " ")
    }
    public init(executable: URL, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    private static func shellEscaped(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=+-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct UpdateResult: Codable, Sendable, Equatable {
    public let packageID: String
    public let command: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public var succeeded: Bool { exitCode == 0 }
    public init(packageID: String, command: String, stdout: String, stderr: String, exitCode: Int32) {
        self.packageID = packageID
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct ScanError: Codable, Sendable, Hashable {
    public let manager: ManagerID
    public let message: String
    public init(manager: ManagerID, message: String) {
        self.manager = manager
        self.message = message
    }
}

public enum SourceAvailability: String, Codable, Sendable, Equatable {
    case available
    case unavailable
    case empty
    case failed
}

public struct SourceHealth: Codable, Sendable, Equatable, Identifiable {
    public let manager: ManagerID
    public var availability: SourceAvailability
    public var packageCount: Int
    public var message: String?
    public var id: ManagerID { manager }

    public init(manager: ManagerID, availability: SourceAvailability,
                packageCount: Int, message: String? = nil) {
        self.manager = manager
        self.availability = availability
        self.packageCount = packageCount
        self.message = message
    }
}

public struct ScanResult: Codable, Sendable, Equatable {
    public var packages: [PackageInfo]
    public var advisories: [ManagerAdvisory]
    public var errors: [ScanError]
    public var sourceHealth: [SourceHealth]
    public var timestamp: Date
    public init(packages: [PackageInfo], advisories: [ManagerAdvisory],
                errors: [ScanError], sourceHealth: [SourceHealth] = [],
                timestamp: Date) {
        self.packages = packages
        self.advisories = advisories
        self.errors = errors
        self.sourceHealth = sourceHealth
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case packages, advisories, errors, sourceHealth, timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packages = try container.decode([PackageInfo].self, forKey: .packages)
        advisories = try container.decode([ManagerAdvisory].self, forKey: .advisories)
        errors = try container.decode([ScanError].self, forKey: .errors)
        sourceHealth = try container.decodeIfPresent([SourceHealth].self, forKey: .sourceHealth) ?? []
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packages, forKey: .packages)
        try container.encode(advisories, forKey: .advisories)
        try container.encode(errors, forKey: .errors)
        try container.encode(sourceHealth, forKey: .sourceHealth)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

public enum AdapterError: Error, Equatable, LocalizedError {
    case toolNotFound(String)
    case commandFailed(String)
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool): return "\(tool)을(를) 찾을 수 없습니다"
        case .commandFailed(let message): return "명령 실패: \(message)"
        case .parseFailed(let message): return "출력 파싱 실패: \(message)"
        }
    }
}

public protocol PackageManagerAdapter: Sendable {
    var id: ManagerID { get }
    func isAvailable() -> Bool
    /// raw 스캔 결과를 반환한다. risk 분류는 PackageScanner가 일괄 적용.
    func scan(now: Date) async throws -> AdapterScan
    /// nil = 이 패키지는 자동 업데이트 미지원
    func updateCommand(for pkg: PackageInfo) -> UpdateCommand?
}
