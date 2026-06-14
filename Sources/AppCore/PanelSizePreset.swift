public struct PanelDimensions: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum PanelSizePreset: String, CaseIterable, Equatable, Sendable {
    case compact
    case regular
    case large

    public static let defaultPreset: PanelSizePreset = .regular

    public init(rawValueOrDefault rawValue: String) {
        self = PanelSizePreset(rawValue: rawValue) ?? Self.defaultPreset
    }

    public static func defaultedRawValueAfterDefaultMigration(_ rawValue: String) -> String {
        let storedPreset = PanelSizePreset(rawValueOrDefault: rawValue)
        return storedPreset == defaultPreset ? storedPreset.rawValue : defaultPreset.rawValue
    }

    public var dimensions: PanelDimensions {
        switch self {
        case .compact:
            return PanelDimensions(width: 400, height: 420)
        case .regular:
            return PanelDimensions(width: 440, height: 560)
        case .large:
            return PanelDimensions(width: 640, height: 760)
        }
    }

    public var smaller: PanelSizePreset {
        switch self {
        case .compact: return .compact
        case .regular: return .compact
        case .large: return .regular
        }
    }

    public var larger: PanelSizePreset {
        switch self {
        case .compact: return .regular
        case .regular: return .large
        case .large: return .large
        }
    }
}
