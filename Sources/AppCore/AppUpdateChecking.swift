import Foundation
import Engine

public struct AppVersion: Equatable, Comparable, Sendable {
    public let version: SemVer
    public let versionString: String

    public init(version: SemVer, versionString: String) {
        self.version = version
        self.versionString = versionString
    }

    public static func parse(_ raw: String) -> AppVersion? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              let version = SemVer.parse(trimmed) else { return nil }
        return AppVersion(version: version, versionString: trimmed)
    }

    public static func bundleVersion(bundle: Bundle = .main) -> AppVersion {
        let candidates = [
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        ]
        for candidate in candidates {
            if let candidate, let version = parse(candidate) {
                return version
            }
        }
        return AppVersion(version: SemVer(major: 0, minor: 0, patch: 0), versionString: "0.0.0")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.version < rhs.version
    }
}

public enum AppUpdateCheckError: Error, Equatable, LocalizedError, Sendable {
    case invalidReleasesURL(String)
    case unexpectedStatus(Int)
    case noValidRelease

    public var errorDescription: String? {
        switch self {
        case .invalidReleasesURL(let raw):
            return "잘못된 GitHub releases URL입니다: \(raw)"
        case .unexpectedStatus(let statusCode):
            return "GitHub releases 요청 실패: HTTP \(statusCode)"
        case .noValidRelease:
            return "설치 가능한 DependencyTend 릴리스를 찾지 못했습니다"
        }
    }
}

public enum AppUpdateAvailability: Equatable, Sendable {
    case upToDate(version: AppVersion)
    case available(release: AppUpdateRelease)
}

public struct AppUpdateHTTPResponse: Equatable, Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol AppUpdateHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> AppUpdateHTTPResponse
}

public struct URLSessionAppUpdateHTTPClient: AppUpdateHTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> AppUpdateHTTPResponse {
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return AppUpdateHTTPResponse(data: data, statusCode: statusCode)
    }
}

public protocol AppUpdateChecking: Sendable {
    func currentVersion() -> AppVersion
    func latestRelease() async throws -> AppUpdateRelease
    func compare(current: AppVersion, latest: AppUpdateRelease) -> AppUpdateAvailability
}

public extension AppUpdateChecking {
    func compare(current: AppVersion, latest: AppUpdateRelease) -> AppUpdateAvailability {
        if current.version < latest.version {
            return .available(release: latest)
        }
        return .upToDate(version: current)
    }

    func availability() async throws -> AppUpdateAvailability {
        let current = currentVersion()
        let latest = try await latestRelease()
        return compare(current: current, latest: latest)
    }
}

public struct GitHubAppUpdateChecker: AppUpdateChecking {
    private let owner: String
    private let repository: String
    private let currentVersionProvider: @Sendable () -> AppVersion
    private let httpClient: any AppUpdateHTTPClient

    public init(owner: String = "ifi999",
                repository: String = "dependency-tend",
                currentVersion: @escaping @Sendable () -> AppVersion = { AppVersion.bundleVersion() },
                httpClient: any AppUpdateHTTPClient = URLSessionAppUpdateHTTPClient()) {
        self.owner = owner
        self.repository = repository
        self.currentVersionProvider = currentVersion
        self.httpClient = httpClient
    }

    public func currentVersion() -> AppVersion {
        currentVersionProvider()
    }

    public func latestRelease() async throws -> AppUpdateRelease {
        let request = try releasesRequest()
        let response = try await httpClient.data(for: request)
        guard 200..<300 ~= response.statusCode else {
            throw AppUpdateCheckError.unexpectedStatus(response.statusCode)
        }
        guard let release = try GitHubReleaseParser.highestValidRelease(from: response.data) else {
            throw AppUpdateCheckError.noValidRelease
        }
        return release
    }

    private func releasesRequest() throws -> URLRequest {
        let rawURL = "https://api.github.com/repos/\(owner)/\(repository)/releases"
        guard let url = URL(string: rawURL) else {
            throw AppUpdateCheckError.invalidReleasesURL(rawURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DependencyTend", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }
}

public enum AppUpdatePrepareError: Error, Equatable, LocalizedError, Sendable {
    case unexpectedStatus(url: URL, statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let url, let statusCode):
            return "업데이트 파일 다운로드 실패: HTTP \(statusCode) \(url.absoluteString)"
        }
    }
}

public protocol AppUpdatePreparing: Sendable {
    func prepare(_ release: AppUpdateRelease) async throws -> PreparedAppUpdate
}

public protocol AppUpdateInstalling: Sendable {
    func install(_ prepared: PreparedAppUpdate) async throws
}

public struct AppUpdatePublicKeyLoader {
    public static let defaultResourceName = "DependencyTendAppUpdatePublicKey"

    private let publicKeyURL: () -> URL?

    public init(publicKeyURL: @escaping () -> URL?) {
        self.publicKeyURL = publicKeyURL
    }

    public static func bundleResource(name: String = defaultResourceName,
                                      bundle: Bundle = .main) -> AppUpdatePublicKeyLoader {
        AppUpdatePublicKeyLoader {
            bundle.url(forResource: name, withExtension: "pem")
        }
    }

    public func load() -> Data? {
        guard let url = publicKeyURL() else { return nil }
        return try? Data(contentsOf: url)
    }
}

public struct GitHubAppUpdatePreparer: AppUpdatePreparing {
    private let httpClient: any AppUpdateHTTPClient
    private let publicKeyPEMData: Data
    private let stagingDirectory: URL

    public init(httpClient: any AppUpdateHTTPClient = URLSessionAppUpdateHTTPClient(),
                publicKeyPEMData: Data,
                stagingDirectory: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("DependencyTendUpdates", isDirectory: true)) {
        self.httpClient = httpClient
        self.publicKeyPEMData = publicKeyPEMData
        self.stagingDirectory = stagingDirectory
    }

    public func prepare(_ release: AppUpdateRelease) async throws -> PreparedAppUpdate {
        let archiveData = try await downloadAsset(at: release.zipAssetURL)
        let checksumData = try await downloadAsset(at: release.checksumAssetURL)
        let manifestData = try await downloadAsset(at: release.manifestAssetURL)
        let signatureData = try await downloadAsset(at: release.signatureAssetURL)
        let manifest = try AppUpdateManifestVerifier.verify(release: release,
                                                            manifestData: manifestData,
                                                            checksumData: checksumData,
                                                            archiveData: archiveData,
                                                            signatureData: signatureData,
                                                            publicKeyPEMData: publicKeyPEMData)
        let archiveURL = try writeArchive(archiveData, release: release)
        return PreparedAppUpdate(release: release, archiveURL: archiveURL,
                                 logFileURL: installLogURL(for: release),
                                 manifest: manifest)
    }

    private func downloadAsset(at url: URL) async throws -> Data {
        let response = try await httpClient.data(for: assetRequest(url: url))
        guard 200..<300 ~= response.statusCode else {
            throw AppUpdatePrepareError.unexpectedStatus(url: url, statusCode: response.statusCode)
        }
        return response.data
    }

    private func assetRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("DependencyTend", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func writeArchive(_ data: Data, release: AppUpdateRelease) throws -> URL {
        let releaseDirectory = stagingDirectory.appendingPathComponent(release.tag, isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
        let archiveURL = releaseDirectory.appendingPathComponent(GitHubReleaseParser.zipAssetName)
        try data.write(to: archiveURL, options: [.atomic])
        return archiveURL
    }

    private func installLogURL(for release: AppUpdateRelease) -> URL {
        stagingDirectory
            .appendingPathComponent(release.tag, isDirectory: true)
            .appendingPathComponent("DependencyTend.install.log")
    }
}

public struct PreparedAppUpdate: Equatable, Sendable {
    public let release: AppUpdateRelease
    public let archiveURL: URL
    public let logFileURL: URL?
    public let manifest: AppUpdateManifest?

    public init(release: AppUpdateRelease, archiveURL: URL,
                logFileURL: URL?, manifest: AppUpdateManifest? = nil) {
        self.release = release
        self.archiveURL = archiveURL
        self.logFileURL = logFileURL
        self.manifest = manifest
    }
}

public struct AppUpdateRecovery: Equatable, Sendable {
    public let releasePageURL: URL?
    public let terminalCommand: String?
    public let downloadedFileURL: URL?
    public let statusFileURL: URL?
    public let logFileURL: URL?

    public init(releasePageURL: URL? = nil, terminalCommand: String? = nil,
                downloadedFileURL: URL? = nil, statusFileURL: URL? = nil,
                logFileURL: URL? = nil) {
        self.releasePageURL = releasePageURL
        self.terminalCommand = terminalCommand
        self.downloadedFileURL = downloadedFileURL
        self.statusFileURL = statusFileURL
        self.logFileURL = logFileURL
    }
}

public enum AppUpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(version: AppVersion)
    case available(release: AppUpdateRelease)
    case downloading(release: AppUpdateRelease)
    case readyToInstall(prepared: PreparedAppUpdate)
    case installing
    case failed(message: String, recovery: AppUpdateRecovery?)
}
