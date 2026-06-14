import XCTest
import Engine
@testable import AppCore

final class AppUpdateCheckingTests: XCTestCase {
    func testAppVersionParsesStrictBundleVersionsOnly() throws {
        XCTAssertEqual(AppVersion.parse("1.2.3"),
                       AppVersion(version: SemVer(major: 1, minor: 2, patch: 3),
                                  versionString: "1.2.3"))
        XCTAssertNil(AppVersion.parse("v1.2.3"))
        XCTAssertNil(AppVersion.parse("1.2"))
        XCTAssertNil(AppVersion.parse("1.2.3-beta.1"))
        XCTAssertNil(AppVersion.parse("1.2.3+5"))
    }

    func testDefaultCompareReturnsAvailableOnlyForNewerRelease() throws {
        let checker = StaticAppUpdateChecker(current: try XCTUnwrap(AppVersion.parse("1.2.3")),
                                             latest: release("1.3.0"))

        XCTAssertEqual(checker.compare(current: try XCTUnwrap(AppVersion.parse("1.2.3")),
                                       latest: release("1.3.0")),
                       .available(release: release("1.3.0")))
        XCTAssertEqual(checker.compare(current: try XCTUnwrap(AppVersion.parse("1.3.0")),
                                       latest: release("1.3.0")),
                       .upToDate(version: try XCTUnwrap(AppVersion.parse("1.3.0"))))
        XCTAssertEqual(checker.compare(current: try XCTUnwrap(AppVersion.parse("1.4.0")),
                                       latest: release("1.3.0")),
                       .upToDate(version: try XCTUnwrap(AppVersion.parse("1.4.0"))))
    }

    func testGitHubCheckerRequestsReleasesEndpointAndParsesLatestValidRelease() async throws {
        let client = CapturingAppUpdateHTTPClient(data: Data("""
        [
          {
            "tag_name": "v1.3.0",
            "html_url": "https://github.com/ifi999/dependency-tend/releases/tag/v1.3.0",
            "body": "stable",
            "draft": false,
            "prerelease": false,
            "assets": [
              {"name": "DependencyTend.app.zip", "browser_download_url": "https://example.com/1.3.0/DependencyTend.app.zip"},
              {"name": "DependencyTend.app.zip.sha256", "browser_download_url": "https://example.com/1.3.0/DependencyTend.app.zip.sha256"},
              {"name": "DependencyTend.update-manifest.json", "browser_download_url": "https://example.com/1.3.0/DependencyTend.update-manifest.json"},
              {"name": "DependencyTend.update-manifest.json.sig", "browser_download_url": "https://example.com/1.3.0/DependencyTend.update-manifest.json.sig"}
            ]
          }
        ]
        """.utf8))
        let checker = GitHubAppUpdateChecker(owner: "ifi999",
                                             repository: "dependency-tend",
                                             currentVersion: { AppVersion.parse("1.2.3")! },
                                             httpClient: client)

        let availability = try await checker.availability()

        guard case .available(let parsedRelease) = availability else {
            return XCTFail("Expected available update")
        }
        XCTAssertEqual(parsedRelease.versionString, "1.3.0")
        XCTAssertEqual(parsedRelease.body, "stable")
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://api.github.com/repos/ifi999/dependency-tend/releases")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "DependencyTend")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testGitHubCheckerThrowsWhenNoValidReleaseExists() async throws {
        let client = CapturingAppUpdateHTTPClient(data: Data("""
        [
          {
            "tag_name": "v1.3.0",
            "html_url": "https://github.com/ifi999/dependency-tend/releases/tag/v1.3.0",
            "body": "missing assets",
            "draft": false,
            "prerelease": false,
            "assets": []
          }
        ]
        """.utf8))
        let checker = GitHubAppUpdateChecker(currentVersion: { AppVersion.parse("1.2.3")! },
                                             httpClient: client)

        do {
            _ = try await checker.latestRelease()
            XCTFail("Expected noValidRelease")
        } catch let error as AppUpdateCheckError {
            XCTAssertEqual(error, .noValidRelease)
        }
    }

    func testGitHubCheckerThrowsForNonSuccessfulHTTPStatus() async throws {
        let client = CapturingAppUpdateHTTPClient(data: Data("[]".utf8), statusCode: 503)
        let checker = GitHubAppUpdateChecker(currentVersion: { AppVersion.parse("1.2.3")! },
                                             httpClient: client)

        do {
            _ = try await checker.latestRelease()
            XCTFail("Expected unexpectedStatus")
        } catch let error as AppUpdateCheckError {
            XCTAssertEqual(error, .unexpectedStatus(503))
        }
    }

    func testAppUpdateStateCarriesComparableUIStates() throws {
        let current = try XCTUnwrap(AppVersion.parse("1.2.3"))
        let latest = release("1.3.0")
        let prepared = PreparedAppUpdate(release: latest,
                                         archiveURL: URL(fileURLWithPath: "/tmp/DependencyTend.app.zip"),
                                         logFileURL: URL(fileURLWithPath: "/tmp/update.log"))
        let recovery = AppUpdateRecovery(
            releasePageURL: latest.releasePageURL,
            terminalCommand: "open https://github.com/ifi999/dependency-tend/releases",
            downloadedFileURL: prepared.archiveURL,
            statusFileURL: URL(fileURLWithPath: "/tmp/status.json"),
            logFileURL: prepared.logFileURL
        )

        XCTAssertEqual(AppUpdateState.idle, .idle)
        XCTAssertEqual(AppUpdateState.checking, .checking)
        XCTAssertEqual(AppUpdateState.upToDate(version: current), .upToDate(version: current))
        XCTAssertEqual(AppUpdateState.available(release: latest), .available(release: latest))
        XCTAssertEqual(AppUpdateState.downloading(release: latest), .downloading(release: latest))
        XCTAssertEqual(AppUpdateState.readyToInstall(prepared: prepared), .readyToInstall(prepared: prepared))
        XCTAssertEqual(AppUpdateState.installing, .installing)
        XCTAssertEqual(AppUpdateState.failed(message: "network failed", recovery: recovery),
                       .failed(message: "network failed", recovery: recovery))
    }

    private struct StaticAppUpdateChecker: AppUpdateChecking {
        let current: AppVersion
        let latest: AppUpdateRelease

        func currentVersion() -> AppVersion { current }
        func latestRelease() async throws -> AppUpdateRelease { latest }
    }

    private final class CapturingAppUpdateHTTPClient: AppUpdateHTTPClient, @unchecked Sendable {
        private let data: Data
        private let statusCode: Int
        private let lock = NSLock()
        private var recordedRequests: [URLRequest] = []

        var requests: [URLRequest] {
            lock.withLock { recordedRequests }
        }

        init(data: Data, statusCode: Int = 200) {
            self.data = data
            self.statusCode = statusCode
        }

        func data(for request: URLRequest) async throws -> AppUpdateHTTPResponse {
            lock.withLock { recordedRequests.append(request) }
            return AppUpdateHTTPResponse(data: data, statusCode: statusCode)
        }
    }

    private func release(_ version: String) -> AppUpdateRelease {
        let semVer = SemVer.parse(version)!
        return AppUpdateRelease(
            version: semVer,
            versionString: version,
            tag: "v\(version)",
            releasePageURL: URL(string: "https://github.com/ifi999/dependency-tend/releases/tag/v\(version)")!,
            body: "",
            zipAssetURL: URL(string: "https://example.com/\(version)/DependencyTend.app.zip")!,
            checksumAssetURL: URL(string: "https://example.com/\(version)/DependencyTend.app.zip.sha256")!,
            manifestAssetURL: URL(string: "https://example.com/\(version)/DependencyTend.update-manifest.json")!,
            signatureAssetURL: URL(string: "https://example.com/\(version)/DependencyTend.update-manifest.json.sig")!
        )
    }
}
