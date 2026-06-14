import Foundation

public struct PipxAdapter: PackageManagerAdapter {
    public let id = ManagerID.pipx
    let pipxURL: URL?
    let runner: any CommandRunning

    public init(pipxURL: URL?, runner: any CommandRunning) {
        self.pipxURL = pipxURL
        self.runner = runner
    }

    public func isAvailable() -> Bool { pipxURL != nil }

    public func scan(now: Date) async throws -> AdapterScan {
        guard let pipx = pipxURL else { throw AdapterError.toolNotFound("pipx") }
        let list = try await runner.run(pipx, arguments: ["list", "--json"], timeout: 120)
        guard list.exitCode == 0 else {
            throw AdapterError.commandFailed("pipx list: \(list.stderr)")
        }
        let outdated = try await runner.run(pipx, arguments: ["list", "--outdated", "--json"], timeout: 300)
        guard outdated.exitCode == 0 else {
            throw AdapterError.commandFailed("pipx list --outdated: \(outdated.stderr)")
        }

        let installed = try Self.parseList(Data(list.stdout.utf8))
        let latestByName = try Self.parseOutdated(Data(outdated.stdout.utf8))
        let packages = installed.map { item in
            PackageInfo(name: item.name, manager: id,
                        current: item.version,
                        latest: latestByName[item.name],
                        status: latestByName[item.name] == nil ? .upToDate : .outdated,
                        metadata: [
                            PackageLinkMetadata.packageURL: PackageLinkMetadata.pypiPackageURL(name: item.name),
                            PackageLinkMetadata.releaseNotesURL: PackageLinkMetadata.pypiReleaseHistoryURL(name: item.name)
                        ])
        }.sorted { $0.name < $1.name }

        return AdapterScan(packages: packages)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let pipx = pipxURL, pkg.manager == id else { return nil }
        return UpdateCommand(executable: pipx, arguments: ["upgrade", pkg.name])
    }

    static func parseList(_ data: Data) throws -> [(name: String, version: String)] {
        try parse(data).compactMap { name, main in
            guard let version = main.packageVersion else { return nil }
            return (main.package ?? name, version)
        }
    }

    static func parseOutdated(_ data: Data) throws -> [String: String] {
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: try parse(Data(trimmed.utf8)).compactMap { name, main in
            guard let latest = main.latestVersion else { return nil }
            return (main.package ?? name, latest)
        })
    }

    private static func parse(_ data: Data) throws -> [(String, MainPackage)] {
        struct PipxList: Decodable {
            struct Venv: Decodable {
                struct Metadata: Decodable {
                    let mainPackage: MainPackage?
                    enum CodingKeys: String, CodingKey { case mainPackage = "main_package" }
                }
                let metadata: Metadata?
            }
            let venvs: [String: Venv]?
        }
        do {
            let decoded = try JSONDecoder().decode(PipxList.self, from: data)
            return (decoded.venvs ?? [:]).compactMap { name, venv in
                guard let main = venv.metadata?.mainPackage else { return nil }
                return (name, main)
            }
        } catch {
            throw AdapterError.parseFailed("pipx JSON: \(error)")
        }
    }

    struct MainPackage: Decodable {
        let package: String?
        let packageVersion: String?
        let latestVersion: String?
        enum CodingKeys: String, CodingKey {
            case package
            case packageVersion = "package_version"
            case latestVersion = "latest_version"
        }
    }
}
