import Foundation

public struct PnpmGlobalAdapter: PackageManagerAdapter {
    public let id = ManagerID.pnpmGlobal
    let pnpmURL: URL?
    let runner: any CommandRunning

    public init(pnpmURL: URL?, runner: any CommandRunning) {
        self.pnpmURL = pnpmURL
        self.runner = runner
    }

    public func isAvailable() -> Bool { pnpmURL != nil }

    public func scan(now: Date) async throws -> AdapterScan {
        guard let pnpm = pnpmURL else { throw AdapterError.toolNotFound("pnpm") }
        let list = try await runner.run(pnpm, arguments: ["list", "-g", "--depth=0", "--json"], timeout: 120)
        guard list.exitCode == 0 else {
            throw AdapterError.commandFailed("pnpm list -g: \(list.stderr)")
        }
        let packages = try Self.parseList(Data(list.stdout.utf8)).map {
            PackageInfo(name: $0.name, manager: id, current: $0.version, status: .unknown,
                        statusReason: .latestUnavailable,
                        metadata: [
                            PackageLinkMetadata.packageURL: PackageLinkMetadata.npmPackageURL(name: $0.name)
                        ])
        }.sorted { $0.name < $1.name }
        return AdapterScan(packages: packages)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let pnpm = pnpmURL, pkg.manager == id else { return nil }
        return UpdateCommand(executable: pnpm, arguments: ["add", "-g", "\(pkg.name)@latest"])
    }

    static func parseList(_ data: Data) throws -> [(name: String, version: String)] {
        struct Root: Decodable {
            struct Dep: Decodable { let version: String? }
            let dependencies: [String: Dep]?
        }
        do {
            let roots = try JSONDecoder().decode([Root].self, from: data)
            return roots.flatMap { root in
                (root.dependencies ?? [:]).compactMap { name, dep in
                    dep.version.map { (name, $0) }
                }
            }
        } catch {
            do {
                let root = try JSONDecoder().decode(Root.self, from: data)
                return (root.dependencies ?? [:]).compactMap { name, dep in
                    dep.version.map { (name, $0) }
                }
            } catch {
                throw AdapterError.parseFailed("pnpm list JSON: \(error)")
            }
        }
    }
}

public struct YarnGlobalAdapter: PackageManagerAdapter {
    public let id = ManagerID.yarnGlobal
    let yarnURL: URL?
    let runner: any CommandRunning

    public init(yarnURL: URL?, runner: any CommandRunning) {
        self.yarnURL = yarnURL
        self.runner = runner
    }

    public func isAvailable() -> Bool { yarnURL != nil }

    public func scan(now: Date) async throws -> AdapterScan {
        guard let yarn = yarnURL else { throw AdapterError.toolNotFound("yarn") }
        let list = try await runner.run(yarn, arguments: ["global", "list", "--json"], timeout: 120)
        guard list.exitCode == 0 else {
            throw AdapterError.commandFailed("yarn global list: \(list.stderr)")
        }
        let packages = Self.parseList(list.stdout).map {
            PackageInfo(name: $0.name, manager: id, current: $0.version, status: .unknown,
                        statusReason: .latestUnavailable,
                        metadata: [
                            PackageLinkMetadata.packageURL: PackageLinkMetadata.npmPackageURL(name: $0.name)
                        ])
        }.sorted { $0.name < $1.name }
        return AdapterScan(packages: packages)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let yarn = yarnURL, pkg.manager == id else { return nil }
        return UpdateCommand(executable: yarn, arguments: ["global", "add", "\(pkg.name)@latest"])
    }

    static func parseList(_ text: String) -> [(name: String, version: String)] {
        struct YarnLine: Decodable {
            let type: String
            let data: String
        }
        return text.split(separator: "\n").compactMap { line in
            guard let decoded = try? JSONDecoder().decode(YarnLine.self, from: Data(line.utf8)),
                  decoded.type == "info",
                  let packageRef = decoded.data.split(separator: "\"").first(where: { $0.contains("@") }) else {
                return nil
            }
            return splitPackageRef(String(packageRef))
        }
    }
}

public struct BunGlobalAdapter: PackageManagerAdapter {
    public let id = ManagerID.bunGlobal
    let bunURL: URL?
    let globalPackageJSON: URL

    public init(bunURL: URL?, globalPackageJSON: URL) {
        self.bunURL = bunURL
        self.globalPackageJSON = globalPackageJSON
    }

    public func isAvailable() -> Bool {
        bunURL != nil && FileManager.default.fileExists(atPath: globalPackageJSON.path)
    }

    public func scan(now: Date) async throws -> AdapterScan {
        guard bunURL != nil else { throw AdapterError.toolNotFound("bun") }
        let data: Data
        do { data = try Data(contentsOf: globalPackageJSON) }
        catch {
            throw AdapterError.commandFailed("bun global package.json 읽기 실패: \(error.localizedDescription)")
        }
        let packages = try Self.parseManifest(data).map {
            PackageInfo(name: $0.name, manager: id, current: $0.version, status: .unknown,
                        statusReason: .latestUnavailable,
                        metadata: [
                            PackageLinkMetadata.packageURL: PackageLinkMetadata.npmPackageURL(name: $0.name)
                        ])
        }.sorted { $0.name < $1.name }
        return AdapterScan(packages: packages)
    }

    public func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        guard let bun = bunURL, pkg.manager == id else { return nil }
        return UpdateCommand(executable: bun, arguments: ["add", "-g", "\(pkg.name)@latest"])
    }

    static func parseManifest(_ data: Data) throws -> [(name: String, version: String)] {
        struct Manifest: Decodable {
            let dependencies: [String: String]?
            let devDependencies: [String: String]?
        }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            let deps = (manifest.dependencies ?? [:]).merging(manifest.devDependencies ?? [:]) { left, _ in left }
            return deps.map { name, version in (name, normalizeVersion(version)) }
        } catch {
            throw AdapterError.parseFailed("bun global package.json: \(error)")
        }
    }
}

private func splitPackageRef(_ ref: String) -> (name: String, version: String)? {
    guard let separator = ref.lastIndex(of: "@"), separator > ref.startIndex else { return nil }
    let name = String(ref[..<separator])
    let version = String(ref[ref.index(after: separator)...])
    guard !name.isEmpty, !version.isEmpty else { return nil }
    return (name, normalizeVersion(version))
}

private func normalizeVersion(_ version: String) -> String {
    version.trimmingCharacters(in: CharacterSet(charactersIn: "^~<>= "))
}
