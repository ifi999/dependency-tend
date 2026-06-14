import Foundation

public struct UpdateHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let packageID: String
    public let manager: ManagerID
    public let name: String
    public let previousVersion: String?
    public let targetVersion: String?
    public let command: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(id: UUID = UUID(), timestamp: Date, packageID: String, manager: ManagerID,
                name: String, previousVersion: String?, targetVersion: String?,
                command: String, exitCode: Int32, stdout: String, stderr: String) {
        self.id = id
        self.timestamp = timestamp
        self.packageID = packageID
        self.manager = manager
        self.name = name
        self.previousVersion = previousVersion
        self.targetVersion = targetVersion
        self.command = command
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}
