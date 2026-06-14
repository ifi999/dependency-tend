import Foundation

public struct MacAppStoreAdapter: PackageManagerAdapter {
    public let id = ManagerID.macAppStore
    let masURL: URL?
    let runner: any CommandRunning

    public init(masURL: URL?, runner: any CommandRunning) {
        self.masURL = masURL
        self.runner = runner
    }

    public func isAvailable() -> Bool { masURL != nil }

    public func scan(now: Date) async throws -> AdapterScan {
        guard let mas = masURL else { throw AdapterError.toolNotFound("mas") }
        let list = try await runner.run(mas, arguments: ["list"], timeout: 120)
        guard list.exitCode == 0 else {
            throw AdapterError.commandFailed("mas list: \(list.stderr)")
        }
        let outdated = try await runner.run(mas, arguments: ["outdated"], timeout: 300)
        guard outdated.exitCode == 0 else {
            throw AdapterError.commandFailed("mas outdated: \(outdated.stderr)")
        }

        let outdatedByID = Dictionary(uniqueKeysWithValues: Self.parseOutdated(outdated.stdout).map {
            ($0.appID, $0)
        })
        let packages = Self.parseList(list.stdout).map { app in
            let metadata = [
                "appID": app.appID,
                PackageLinkMetadata.packageURL: PackageLinkMetadata.appStorePackageURL(appID: app.appID)
            ]
            if let update = outdatedByID[app.appID] {
                return PackageInfo(name: app.name, manager: id,
                                   current: update.current, latest: update.latest,
                                   status: .outdated,
                                   metadata: metadata)
            }
            return PackageInfo(name: app.name, manager: id,
                               current: app.version, status: .upToDate,
                               metadata: metadata)
        }.sorted { $0.name < $1.name }

        return AdapterScan(packages: packages)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let mas = masURL, pkg.manager == id,
              let appID = pkg.metadata["appID"] else { return nil }
        return UpdateCommand(executable: mas, arguments: ["upgrade", appID])
    }

    static func parseList(_ text: String) -> [(appID: String, name: String, version: String)] {
        text.split(separator: "\n").compactMap { parseLine(String($0)) }
    }

    static func parseOutdated(_ text: String) -> [(appID: String, name: String, current: String, latest: String)] {
        text.split(separator: "\n").compactMap { line in
            guard let app = parseLine(String(line)) else { return nil }
            let versions = app.version.components(separatedBy: " -> ")
            guard versions.count == 2 else { return nil }
            return (app.appID, app.name, versions[0], versions[1])
        }
    }

    private static func parseLine(_ line: String) -> (appID: String, name: String, version: String)? {
        guard let firstSpace = line.firstIndex(of: " "),
              let openParen = line.lastIndex(of: "("),
              line.hasSuffix(")") else { return nil }
        let appID = String(line[..<firstSpace])
        let name = String(line[line.index(after: firstSpace)..<openParen])
            .trimmingCharacters(in: .whitespaces)
        let version = String(line[line.index(after: openParen)..<line.index(before: line.endIndex)])
        guard !appID.isEmpty, !name.isEmpty, !version.isEmpty else { return nil }
        return (appID, name, version)
    }
}
