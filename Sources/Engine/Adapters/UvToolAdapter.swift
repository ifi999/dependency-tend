import Foundation

public struct UvToolAdapter: PackageManagerAdapter {
    public let id = ManagerID.uvTool
    let uvURL: URL?
    let runner: any CommandRunning

    public init(uvURL: URL?, runner: any CommandRunning) {
        self.uvURL = uvURL
        self.runner = runner
    }

    public func isAvailable() -> Bool { uvURL != nil }

    public func scan(now: Date) async throws -> AdapterScan {
        guard let uv = uvURL else { throw AdapterError.toolNotFound("uv") }
        let list = try await runner.run(uv, arguments: ["tool", "list", "--show-paths"], timeout: 120)
        guard list.exitCode == 0 else {
            throw AdapterError.commandFailed("uv tool list: \(list.stderr)")
        }
        let packages = Self.parseList(list.stdout).map {
            PackageInfo(name: $0.name, manager: id, current: $0.version, status: .unknown,
                        statusReason: .latestUnavailable,
                        metadata: [
                            PackageLinkMetadata.packageURL: PackageLinkMetadata.pypiPackageURL(name: $0.name),
                            PackageLinkMetadata.releaseNotesURL: PackageLinkMetadata.pypiReleaseHistoryURL(name: $0.name)
                        ])
        }.sorted { $0.name < $1.name }
        return AdapterScan(packages: packages)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let uv = uvURL, pkg.manager == id else { return nil }
        return UpdateCommand(executable: uv, arguments: ["tool", "upgrade", pkg.name])
    }

    static func parseList(_ text: String) -> [(name: String, version: String)] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("-") else { return nil }
            let tokens = line.split(separator: " ").map(String.init)
            guard tokens.count >= 2 else { return nil }
            let version = tokens[1].hasPrefix("v") ? String(tokens[1].dropFirst()) : tokens[1]
            return (tokens[0], version)
        }
    }
}
