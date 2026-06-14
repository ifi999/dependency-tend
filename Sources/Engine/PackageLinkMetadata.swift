import Foundation

public enum PackageLinkMetadata {
    public static let packageURL = "packageURL"
    public static let homepageURL = "homepageURL"
    public static let docsURL = "docsURL"
    public static let repositoryURL = "repositoryURL"
    public static let releaseNotesURL = "releaseNotesURL"

    public enum LinkKind: String, Sendable {
        case package, homepage, docs, repository, releaseNotes
    }

    public struct ReferenceLink: Identifiable, Sendable, Equatable {
        public let kind: LinkKind
        public let url: URL

        public var id: String { "\(kind.rawValue):\(url.absoluteString)" }

        public init(kind: LinkKind, url: URL) {
            self.kind = kind
            self.url = url
        }
    }

    public static func appStorePackageURL(appID: String) -> String {
        "https://apps.apple.com/app/id\(encodePath(appID))"
    }

    public static func brewPackageURL(name: String, isCask: Bool) -> String {
        let kind = isCask ? "cask" : "formula"
        return "https://formulae.brew.sh/\(kind)/\(encodePath(name))"
    }

    public static func cratesPackageURL(name: String) -> String {
        "https://crates.io/crates/\(encodePath(name))"
    }

    public static func docsRsURL(name: String) -> String {
        "https://docs.rs/\(encodePath(name))"
    }

    public static func npmPackageURL(name: String) -> String {
        "https://www.npmjs.com/package/\(encodePath(name))"
    }

    public static func pypiPackageURL(name: String) -> String {
        "https://pypi.org/project/\(encodePath(name))/"
    }

    public static func pypiReleaseHistoryURL(name: String) -> String {
        "https://pypi.org/project/\(encodePath(name))/#history"
    }

    public static func vscodeMarketplaceURL(identifier: String) -> String {
        "https://marketplace.visualstudio.com/items?itemName=\(encodeQuery(identifier))"
    }

    public static func githubRepositoryURL(repo: String) -> String {
        "https://github.com/\(encodePath(repo))"
    }

    public static func githubTreeURL(repo: String, path: String) -> String {
        let suffix = path.isEmpty ? "" : "/\(encodePath(path))"
        return "\(githubRepositoryURL(repo: repo))/tree/main\(suffix)"
    }

    public static func githubReleaseNotesURL(repo: String) -> String {
        "\(githubRepositoryURL(repo: repo))/releases"
    }

    public static func referenceLinks(from metadata: [String: String]) -> [ReferenceLink] {
        var seen = Set<String>()
        return orderedLinkKeys.compactMap { kind, key in
            guard let rawURL = metadata[key],
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  seen.insert(url.absoluteString).inserted else {
                return nil
            }
            return ReferenceLink(kind: kind, url: url)
        }
    }

    private static let orderedLinkKeys: [(LinkKind, String)] = [
        (.package, packageURL),
        (.homepage, homepageURL),
        (.docs, docsURL),
        (.repository, repositoryURL),
        (.releaseNotes, releaseNotesURL),
    ]

    private static func encodePath(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodeQuery(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
