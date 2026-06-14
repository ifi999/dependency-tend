import Foundation
import Engine

public struct AppUpdateRelease: Equatable, Sendable {
    public let version: SemVer
    public let versionString: String
    public let tag: String
    public let releasePageURL: URL
    public let body: String
    public let zipAssetURL: URL
    public let checksumAssetURL: URL
    public let manifestAssetURL: URL
    public let signatureAssetURL: URL

    public init(version: SemVer, versionString: String, tag: String, releasePageURL: URL,
                body: String, zipAssetURL: URL, checksumAssetURL: URL,
                manifestAssetURL: URL, signatureAssetURL: URL) {
        self.version = version
        self.versionString = versionString
        self.tag = tag
        self.releasePageURL = releasePageURL
        self.body = body
        self.zipAssetURL = zipAssetURL
        self.checksumAssetURL = checksumAssetURL
        self.manifestAssetURL = manifestAssetURL
        self.signatureAssetURL = signatureAssetURL
    }
}

public enum GitHubReleaseParser {
    public static let zipAssetName = "DependencyTend.app.zip"
    public static let checksumAssetName = "DependencyTend.app.zip.sha256"
    public static let manifestAssetName = "DependencyTend.update-manifest.json"
    public static let signatureAssetName = "DependencyTend.update-manifest.json.sig"

    public static func highestValidRelease(from data: Data) throws -> AppUpdateRelease? {
        let responses = try JSONDecoder().decode([ReleaseResponse].self, from: data)
        return responses.compactMap(validRelease(from:)).max { lhs, rhs in
            lhs.version < rhs.version
        }
    }

    private static func validRelease(from response: ReleaseResponse) -> AppUpdateRelease? {
        guard !response.draft, !response.prerelease else { return nil }
        guard let parsed = strictVersion(from: response.tagName) else { return nil }
        let assets = Dictionary(response.assets.map { ($0.name, $0.browserDownloadURL) },
                                uniquingKeysWith: { first, _ in first })
        guard let zip = assets[zipAssetName],
              let checksum = assets[checksumAssetName],
              let manifest = assets[manifestAssetName],
              let signature = assets[signatureAssetName] else { return nil }
        return AppUpdateRelease(version: parsed.version,
                                versionString: parsed.versionString,
                                tag: response.tagName,
                                releasePageURL: response.htmlURL,
                                body: response.body ?? "",
                                zipAssetURL: zip,
                                checksumAssetURL: checksum,
                                manifestAssetURL: manifest,
                                signatureAssetURL: signature)
    }

    private static func strictVersion(from tag: String) -> (version: SemVer, versionString: String)? {
        let raw = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        guard raw.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              let version = SemVer.parse(raw) else { return nil }
        return (version, raw)
    }

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [AssetResponse]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case draft
            case prerelease
            case assets
        }
    }

    private struct AssetResponse: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
