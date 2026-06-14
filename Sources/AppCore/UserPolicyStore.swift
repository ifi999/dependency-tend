import Engine
import Foundation

public struct UserPolicy: Codable, Equatable, Sendable {
    public var ignoredPackageIDs: Set<String>
    public var snoozedPackages: [String: Date]
    public var hiddenManagers: Set<ManagerID>

    public init(ignoredPackageIDs: Set<String> = [],
                snoozedPackages: [String: Date] = [:],
                hiddenManagers: Set<ManagerID> = []) {
        self.ignoredPackageIDs = ignoredPackageIDs
        self.snoozedPackages = snoozedPackages
        self.hiddenManagers = hiddenManagers
    }
}

public struct UserPolicyStore: Sendable {
    public let fileURL: URL

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dependency-tend/user-policy.json")
    }

    public init(fileURL: URL = UserPolicyStore.defaultURL()) {
        self.fileURL = fileURL
    }

    public func load() -> UserPolicy {
        guard let data = try? Data(contentsOf: fileURL) else { return UserPolicy() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UserPolicy.self, from: data)) ?? UserPolicy()
    }

    public func save(_ policy: UserPolicy) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(policy).write(to: fileURL, options: .atomic)
    }
}
