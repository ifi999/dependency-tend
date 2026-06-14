import Foundation

public struct CargoInstallAdapter: PackageManagerAdapter {
    public let id = ManagerID.cargoInstall
    let cargoURL: URL?
    let runner: any CommandRunning

    public init(cargoURL: URL?, runner: any CommandRunning) {
        self.cargoURL = cargoURL
        self.runner = runner
    }

    public func isAvailable() -> Bool { cargoURL != nil }

    public func scan(now: Date) async throws -> AdapterScan {
        guard let cargo = cargoURL else { throw AdapterError.toolNotFound("cargo") }
        let list = try await runner.run(cargo, arguments: ["install", "--list"], timeout: 120)
        guard list.exitCode == 0 else {
            throw AdapterError.commandFailed("cargo install --list: \(list.stderr)")
        }
        let packages = Self.parseList(list.stdout).map {
            PackageInfo(name: $0.name, manager: id, current: $0.version, status: .unknown,
                        statusReason: .latestUnavailable,
                        metadata: [
                            PackageLinkMetadata.packageURL: PackageLinkMetadata.cratesPackageURL(name: $0.name),
                            PackageLinkMetadata.docsURL: PackageLinkMetadata.docsRsURL(name: $0.name)
                        ])
        }.sorted { $0.name < $1.name }
        return AdapterScan(packages: packages)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let cargo = cargoURL, pkg.manager == id else { return nil }
        return UpdateCommand(executable: cargo, arguments: ["install", pkg.name])
    }

    static func parseList(_ text: String) -> [(name: String, version: String)] {
        text.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard !line.isEmpty, line.first?.isWhitespace == false, line.hasSuffix(":") else { return nil }
            let tokens = line.dropLast().split(separator: " ").map(String.init)
            guard tokens.count >= 2 else { return nil }
            let versionToken = tokens[1]
            let version = versionToken.hasPrefix("v") ? String(versionToken.dropFirst()) : versionToken
            return (tokens[0], version)
        }
    }
}
