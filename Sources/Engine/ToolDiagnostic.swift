import Foundation

public struct ToolDiagnostic: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let path: String?
    public let detail: String?

    public var isAvailable: Bool { path != nil }

    public init(id: String, name: String, path: String?, detail: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.detail = detail
    }
}
