import Foundation

public struct EditorExtensionAdapter: PackageManagerAdapter {
    public let id: ManagerID
    let cliURL: URL?
    let runner: any CommandRunning

    public init(id: ManagerID, cliURL: URL?, runner: any CommandRunning) {
        self.id = id
        self.cliURL = cliURL
        self.runner = runner
    }

    public func isAvailable() -> Bool { cliURL != nil }

    public func scan(now: Date) async throws -> AdapterScan {
        guard let cli = cliURL else { throw AdapterError.toolNotFound(id.displayName) }
        let list = try await runner.run(cli, arguments: ["--list-extensions", "--show-versions"], timeout: 120)
        guard list.exitCode == 0 else {
            throw AdapterError.commandFailed("\(cli.lastPathComponent) --list-extensions: \(list.stderr)")
        }
        let packages = Self.parseList(list.stdout).map {
            PackageInfo(name: $0.identifier, manager: id, current: $0.version, status: .unknown,
                        statusReason: .latestUnavailable,
                        metadata: Self.linkMetadata(identifier: $0.identifier, manager: id))
        }.sorted { $0.name < $1.name }
        return AdapterScan(packages: packages)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let cli = cliURL, pkg.manager == id else { return nil }
        return UpdateCommand(executable: cli, arguments: ["--install-extension", pkg.name, "--force"])
    }

    static func parseList(_ text: String) -> [(identifier: String, version: String)] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.lastIndex(of: "@"), separator > line.startIndex else { return nil }
            let identifier = String(line[..<separator])
            let version = String(line[line.index(after: separator)...])
            guard !identifier.isEmpty, !version.isEmpty else { return nil }
            return (identifier, version)
        }
    }

    private static func linkMetadata(identifier: String, manager: ManagerID) -> [String: String] {
        switch manager {
        case .vscodeExtensions:
            return [
                PackageLinkMetadata.packageURL: PackageLinkMetadata.vscodeMarketplaceURL(identifier: identifier)
            ]
        case .cursorExtensions:
            // Cursor may use VS Marketplace or Open VSX depending on install source; the CLI list output
            // does not expose the source, so avoid emitting a confidently wrong registry link.
            return [:]
        default:
            return [:]
        }
    }
}
