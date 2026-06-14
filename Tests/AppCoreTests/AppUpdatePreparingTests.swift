import XCTest
import Engine
import Security
@testable import AppCore

final class AppUpdatePreparingTests: XCTestCase {
    func testPublicKeyLoaderReadsPEMFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyURL = directory.appendingPathComponent("DependencyTendAppUpdatePublicKey.pem")
        let keyData = Data("-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----\n".utf8)
        try keyData.write(to: keyURL)
        let loader = AppUpdatePublicKeyLoader(publicKeyURL: { keyURL })

        XCTAssertEqual(loader.load(), keyData)
    }

    func testPublicKeyLoaderReturnsNilWhenFileIsMissing() {
        let loader = AppUpdatePublicKeyLoader(publicKeyURL: { nil })

        XCTAssertNil(loader.load())
    }

    func testPreparerDownloadsAssetsVerifiesManifestAndWritesArchive() async throws {
        let release = appRelease("1.3.0")
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)
        let manifestData = manifest(version: "1.3.0", assetSHA256: digest)
        let keys = try makeSigningKeys()
        let signature = try sign(manifestData, privateKey: keys.privateKey)
        let client = StaticAssetHTTPClient(responses: [
            release.zipAssetURL: AppUpdateHTTPResponse(data: archive, statusCode: 200),
            release.checksumAssetURL: AppUpdateHTTPResponse(data: checksum(digest), statusCode: 200),
            release.manifestAssetURL: AppUpdateHTTPResponse(data: manifestData, statusCode: 200),
            release.signatureAssetURL: AppUpdateHTTPResponse(data: signature, statusCode: 200),
        ])
        let stagingDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let preparer = GitHubAppUpdatePreparer(httpClient: client,
                                               publicKeyPEMData: keys.publicKeyPEM,
                                               stagingDirectory: stagingDirectory)

        let prepared = try await preparer.prepare(release)

        XCTAssertEqual(prepared.release, release)
        XCTAssertEqual(prepared.manifest?.versionString, "1.3.0")
        XCTAssertEqual(prepared.archiveURL.lastPathComponent, GitHubReleaseParser.zipAssetName)
        XCTAssertEqual(try Data(contentsOf: prepared.archiveURL), archive)
        XCTAssertEqual(prepared.logFileURL?.lastPathComponent, "DependencyTend.install.log")
        XCTAssertEqual(Set(client.requestedURLs), [
            release.zipAssetURL,
            release.checksumAssetURL,
            release.manifestAssetURL,
            release.signatureAssetURL,
        ])
    }

    func testPreparerRejectsFailedAssetDownload() async throws {
        let release = appRelease("1.3.0")
        let client = StaticAssetHTTPClient(responses: [
            release.zipAssetURL: AppUpdateHTTPResponse(data: Data(), statusCode: 503),
        ])
        let preparer = GitHubAppUpdatePreparer(httpClient: client,
                                               publicKeyPEMData: Data("public key".utf8),
                                               stagingDirectory: temporaryDirectory())

        do {
            _ = try await preparer.prepare(release)
            XCTFail("Expected unexpected status")
        } catch let error as AppUpdatePrepareError {
            XCTAssertEqual(error, .unexpectedStatus(url: release.zipAssetURL, statusCode: 503))
        }
    }

    func testPreparerRejectsInvalidSignatureBeforeWritingArchive() async throws {
        let release = appRelease("1.3.0")
        let archive = Data("release archive".utf8)
        let digest = AppUpdateManifestVerifier.sha256Hex(for: archive)
        let manifestData = manifest(version: "1.3.0", assetSHA256: digest)
        let keys = try makeSigningKeys()
        let client = StaticAssetHTTPClient(responses: [
            release.zipAssetURL: AppUpdateHTTPResponse(data: archive, statusCode: 200),
            release.checksumAssetURL: AppUpdateHTTPResponse(data: checksum(digest), statusCode: 200),
            release.manifestAssetURL: AppUpdateHTTPResponse(data: manifestData, statusCode: 200),
            release.signatureAssetURL: AppUpdateHTTPResponse(data: Data("bad signature".utf8), statusCode: 200),
        ])
        let stagingDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let preparer = GitHubAppUpdatePreparer(httpClient: client,
                                               publicKeyPEMData: keys.publicKeyPEM,
                                               stagingDirectory: stagingDirectory)

        do {
            _ = try await preparer.prepare(release)
            XCTFail("Expected signature failure")
        } catch let error as AppUpdateManifestError {
            XCTAssertEqual(error, .signatureVerificationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    func testInstallerRejectsMissingArchiveBeforeLaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launcher = CapturingInstallLauncher()
        let installer = try makeInstaller(in: directory, launcher: launcher)
        let prepared = PreparedAppUpdate(release: appRelease("1.3.0"),
                                         archiveURL: directory.appendingPathComponent("missing.zip"),
                                         logFileURL: directory.appendingPathComponent("install.log"))

        do {
            try await installer.install(prepared)
            XCTFail("Expected missing archive error")
        } catch let error as AppUpdateInstallError {
            XCTAssertEqual(error, .missingArchive(prepared.archiveURL))
        }
        XCTAssertNil(launcher.launchedCommand)
    }

    func testInstallerWritesDetachedHelperAndLaunchesIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("DependencyTend.app.zip")
        try Data("archive".utf8).write(to: archive)
        let launcher = CapturingInstallLauncher()
        let installer = try makeInstaller(in: directory, launcher: launcher,
                                          launchAfterInstall: false)
        let prepared = PreparedAppUpdate(release: appRelease("1.3.0"),
                                         archiveURL: archive,
                                         logFileURL: directory.appendingPathComponent("install.log"))

        try await installer.install(prepared)

        let launched = try XCTUnwrap(launcher.launchedCommand)
        XCTAssertEqual(launched.executable.lastPathComponent, "bash")
        let helper = URL(fileURLWithPath: try XCTUnwrap(launched.arguments.first))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let script = try String(contentsOf: helper, encoding: .utf8)
        XCTAssertTrue(script.contains("/usr/bin/env bash"))
        XCTAssertTrue(script.contains("ditto"))
        XCTAssertTrue(script.contains("DependencyTend.app missing from archive"))
        XCTAssertTrue(script.contains("DEPENDENCY_TEND_SOURCE_APP=\"$APP\""))
        XCTAssertTrue(script.contains("DEPENDENCY_TEND_SKIP_BUILD=1"))
        XCTAssertTrue(script.contains("--no-launch"))
        XCTAssertTrue(script.contains(prepared.archiveURL.path))
        XCTAssertTrue(script.contains(prepared.logFileURL!.path))
    }

    private final class StaticAssetHTTPClient: AppUpdateHTTPClient, @unchecked Sendable {
        private let responses: [URL: AppUpdateHTTPResponse]
        private let lock = NSLock()
        private var recordedURLs: [URL] = []

        var requestedURLs: [URL] {
            lock.withLock { recordedURLs }
        }

        init(responses: [URL: AppUpdateHTTPResponse]) {
            self.responses = responses
        }

        func data(for request: URLRequest) async throws -> AppUpdateHTTPResponse {
            let url = try XCTUnwrap(request.url)
            lock.withLock { recordedURLs.append(url) }
            return responses[url] ?? AppUpdateHTTPResponse(data: Data(), statusCode: 404)
        }
    }

    private final class CapturingInstallLauncher: AppUpdateInstallLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private var command: (executable: URL, arguments: [String], environment: [String: String])?

        var launchedCommand: (executable: URL, arguments: [String], environment: [String: String])? {
            lock.withLock { command }
        }

        func launch(_ executable: URL, arguments: [String],
                    environment: [String: String]) throws {
            lock.withLock { command = (executable, arguments, environment) }
        }
    }

    private func appRelease(_ version: String) -> AppUpdateRelease {
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

    private func checksum(_ digest: String) -> Data {
        Data("\(digest)  \(GitHubReleaseParser.zipAssetName)\n".utf8)
    }

    private func manifest(version: String, assetSHA256: String) -> Data {
        Data("""
        {
          "version": "\(version)",
          "tag": "v\(version)",
          "commitSHA": "0123456789abcdef0123456789abcdef01234567",
          "buildNumber": "42",
          "minimumAppVersion": "1.0.0",
          "assetName": "DependencyTend.app.zip",
          "assetSHA256": "\(assetSHA256)",
          "createdAt": "2026-06-14T00:00:00Z",
          "signatureFormat": "openssl-rsa-sha256"
        }
        """.utf8)
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DependencyTendTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeInstaller(in directory: URL,
                               launcher: CapturingInstallLauncher,
                               launchAfterInstall: Bool = true) throws -> ScriptedAppUpdateInstaller {
        let installScript = directory.appendingPathComponent("install-app.sh")
        let validateScript = directory.appendingPathComponent("validate-app-bundle.sh")
        let bash = directory.appendingPathComponent("bash")
        let ditto = directory.appendingPathComponent("ditto")
        for executable in [installScript, validateScript, bash, ditto] {
            try makeExecutable(executable)
        }
        return ScriptedAppUpdateInstaller(installScriptURL: installScript,
                                          validateScriptURL: validateScript,
                                          bashURL: bash,
                                          dittoURL: ditto,
                                          destinationAppURL: directory.appendingPathComponent("DependencyTend.app"),
                                          launchAfterInstall: launchAfterInstall,
                                          launcher: launcher,
                                          workDirectory: {
                                              directory.appendingPathComponent("install-work", isDirectory: true)
                                          })
    }

    private func makeExecutable(_ url: URL) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeSigningKeys() throws -> (privateKey: SecKey, publicKeyPEM: Data) {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "AppUpdatePreparingTests", code: 1)
        }
        return (privateKey, pem(label: "RSA PUBLIC KEY", der: publicDER))
    }

    private func sign(_ data: Data, privateKey: SecKey) throws -> Data {
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, data as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? NSError(domain: "AppUpdatePreparingTests", code: 2)
        }
        return signature
    }

    private func pem(label: String, der: Data) -> Data {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n".utf8)
    }
}
