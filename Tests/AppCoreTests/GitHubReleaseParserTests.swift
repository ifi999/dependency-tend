import XCTest
import Engine
@testable import AppCore

final class GitHubReleaseParserTests: XCTestCase {
    func testSelectsHighestValidNonPrereleaseSemVerRelease() throws {
        let data = Data("""
        [
          {
            "tag_name": "v1.10.0",
            "html_url": "https://github.com/ifi999/dependency-tend/releases/tag/v1.10.0",
            "body": "stable high",
            "draft": false,
            "prerelease": false,
            "assets": [
              {"name": "DependencyTend.app.zip", "browser_download_url": "https://example.com/1.10.0/DependencyTend.app.zip"},
              {"name": "DependencyTend.app.zip.sha256", "browser_download_url": "https://example.com/1.10.0/DependencyTend.app.zip.sha256"},
              {"name": "DependencyTend.update-manifest.json", "browser_download_url": "https://example.com/1.10.0/DependencyTend.update-manifest.json"},
              {"name": "DependencyTend.update-manifest.json.sig", "browser_download_url": "https://example.com/1.10.0/DependencyTend.update-manifest.json.sig"}
            ]
          },
          {
            "tag_name": "v2.0.0",
            "html_url": "https://github.com/ifi999/dependency-tend/releases/tag/v2.0.0",
            "body": "draft",
            "draft": true,
            "prerelease": false,
            "assets": [
              {"name": "DependencyTend.app.zip", "browser_download_url": "https://example.com/draft/DependencyTend.app.zip"},
              {"name": "DependencyTend.app.zip.sha256", "browser_download_url": "https://example.com/draft/DependencyTend.app.zip.sha256"},
              {"name": "DependencyTend.update-manifest.json", "browser_download_url": "https://example.com/draft/DependencyTend.update-manifest.json"},
              {"name": "DependencyTend.update-manifest.json.sig", "browser_download_url": "https://example.com/draft/DependencyTend.update-manifest.json.sig"}
            ]
          },
          {
            "tag_name": "v1.11.0-beta.1",
            "html_url": "https://github.com/ifi999/dependency-tend/releases/tag/v1.11.0-beta.1",
            "body": "prerelease",
            "draft": false,
            "prerelease": false,
            "assets": [
              {"name": "DependencyTend.app.zip", "browser_download_url": "https://example.com/beta/DependencyTend.app.zip"},
              {"name": "DependencyTend.app.zip.sha256", "browser_download_url": "https://example.com/beta/DependencyTend.app.zip.sha256"},
              {"name": "DependencyTend.update-manifest.json", "browser_download_url": "https://example.com/beta/DependencyTend.update-manifest.json"},
              {"name": "DependencyTend.update-manifest.json.sig", "browser_download_url": "https://example.com/beta/DependencyTend.update-manifest.json.sig"}
            ]
          },
          {
            "tag_name": "v1.9.0",
            "html_url": "https://github.com/ifi999/dependency-tend/releases/tag/v1.9.0",
            "body": "missing signature",
            "draft": false,
            "prerelease": false,
            "assets": [
              {"name": "DependencyTend.app.zip", "browser_download_url": "https://example.com/1.9.0/DependencyTend.app.zip"},
              {"name": "DependencyTend.app.zip.sha256", "browser_download_url": "https://example.com/1.9.0/DependencyTend.app.zip.sha256"},
              {"name": "DependencyTend.update-manifest.json", "browser_download_url": "https://example.com/1.9.0/DependencyTend.update-manifest.json"}
            ]
          }
        ]
        """.utf8)

        let release = try XCTUnwrap(GitHubReleaseParser.highestValidRelease(from: data))

        XCTAssertEqual(release.version, SemVer(major: 1, minor: 10, patch: 0))
        XCTAssertEqual(release.versionString, "1.10.0")
        XCTAssertEqual(release.tag, "v1.10.0")
        XCTAssertEqual(release.body, "stable high")
        XCTAssertEqual(release.releasePageURL.absoluteString,
                       "https://github.com/ifi999/dependency-tend/releases/tag/v1.10.0")
        XCTAssertEqual(release.zipAssetURL.absoluteString,
                       "https://example.com/1.10.0/DependencyTend.app.zip")
        XCTAssertEqual(release.signatureAssetURL.absoluteString,
                       "https://example.com/1.10.0/DependencyTend.update-manifest.json.sig")
    }

    func testReturnsNilWhenNoReleaseHasAllRequiredAssets() throws {
        let data = Data("""
        [
          {
            "tag_name": "v1.0.0",
            "html_url": "https://github.com/ifi999/dependency-tend/releases/tag/v1.0.0",
            "body": "",
            "draft": false,
            "prerelease": false,
            "assets": [
              {"name": "DependencyTend.app.zip", "browser_download_url": "https://example.com/DependencyTend.app.zip"}
            ]
          }
        ]
        """.utf8)

        XCTAssertNil(try GitHubReleaseParser.highestValidRelease(from: data))
    }
}
