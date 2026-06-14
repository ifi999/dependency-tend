import Engine

public struct UpdateCandidate: Sendable, Equatable, Identifiable {
    public let package: PackageInfo
    public let command: String?
    public let canRun: Bool
    public let reason: String?

    public var id: String { package.id }

    public init(package: PackageInfo, command: String?, canRun: Bool, reason: String?) {
        self.package = package
        self.command = command
        self.canRun = canRun
        self.reason = reason
    }
}
