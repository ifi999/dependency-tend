import XCTest
@testable import Engine

final class PackageLinkMetadataTests: XCTestCase {
    func testReferenceLinksDeduplicateURLsByPriority() throws {
        let links = PackageLinkMetadata.referenceLinks(from: [
            PackageLinkMetadata.packageURL: "https://example.com/project",
            PackageLinkMetadata.homepageURL: "https://example.com/project",
            PackageLinkMetadata.docsURL: "https://example.com/docs",
            PackageLinkMetadata.releaseNotesURL: "https://example.com/project"
        ])

        XCTAssertEqual(links.map(\.kind), [.package, .docs])
        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://example.com/project",
            "https://example.com/docs"
        ])
    }

    func testRegistrySpecificHistoryURLs() {
        XCTAssertEqual(PackageLinkMetadata.pypiReleaseHistoryURL(name: "black"),
                       "https://pypi.org/project/black/#history")
    }
}
