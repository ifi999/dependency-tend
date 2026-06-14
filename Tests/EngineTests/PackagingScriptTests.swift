import Foundation
import XCTest

final class PackagingScriptTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackagingScriptsHaveValidBashSyntax() throws {
        try assertBashSyntax(script: "scripts/make-app.sh")
        try assertBashSyntax(script: "scripts/package-release.sh")
        try assertBashSyntax(script: "scripts/validate-app-bundle.sh")
        try assertBashSyntax(script: "scripts/install-app.sh")
        try assertBashSyntax(script: "scripts/release-qa.sh")
    }

    func testVersionFileIsTheBundleShortVersionSource() throws {
        let versionURL = root.appendingPathComponent("VERSION")
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionURL.path),
                      "VERSION should be the single source for CFBundleShortVersionString")
        guard FileManager.default.fileExists(atPath: versionURL.path) else { return }

        let version = try String(contentsOf: versionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression),
                        "VERSION must be strict MAJOR.MINOR.PATCH")

        let script = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"),
                                encoding: .utf8)
        XCTAssertTrue(script.contains("VERSION_FILE"), "make-app.sh should read VERSION explicitly")
        XCTAssertFalse(script.contains("<string>1.0.0</string>"),
                       "CFBundleShortVersionString must not be hardcoded")
    }

    func testMakeAppUsesVersionFileForBundleShortVersion() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-make-app-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fakeBinary = temp.appendingPathComponent("DependencyTend")
        let app = temp.appendingPathComponent("DependencyTend.app")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let result = runScript("scripts/make-app.sh",
                               environment: [
                                   "DEPENDENCY_TEND_APP_OUTPUT": app.path,
                                   "DEPENDENCY_TEND_RELEASE_BINARY": fakeBinary.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1",
                                   "DEPENDENCY_TEND_SKIP_CODESIGN": "1"
                               ])

        XCTAssertEqual(result.status, 0, result.output)
        let expectedVersion = try String(contentsOf: root.appendingPathComponent("VERSION"),
                                         encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try String(contentsOf: app.appendingPathComponent("Contents/Info.plist"),
                              encoding: .utf8)
        XCTAssertTrue(info.contains("<key>CFBundleShortVersionString</key>"), info)
        XCTAssertTrue(info.contains("<string>\(expectedVersion)</string>"), info)
    }

    func testMakeAppBundlesInstallerScripts() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-make-app-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fakeBinary = temp.appendingPathComponent("DependencyTend")
        let app = temp.appendingPathComponent("DependencyTend.app")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let result = runScript("scripts/make-app.sh",
                               environment: [
                                   "DEPENDENCY_TEND_APP_OUTPUT": app.path,
                                   "DEPENDENCY_TEND_RELEASE_BINARY": fakeBinary.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1",
                                   "DEPENDENCY_TEND_SKIP_CODESIGN": "1"
                               ])

        XCTAssertEqual(result.status, 0, result.output)
        let scripts = app.appendingPathComponent("Contents/Resources/scripts")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: scripts.appendingPathComponent("install-app.sh").path
        ))
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: scripts.appendingPathComponent("validate-app-bundle.sh").path
        ))
    }

    func testMakeAppBundlesAppIcon() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-make-app-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fakeBinary = temp.appendingPathComponent("DependencyTend")
        let app = temp.appendingPathComponent("DependencyTend.app")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let result = runScript("scripts/make-app.sh",
                               environment: [
                                   "DEPENDENCY_TEND_APP_OUTPUT": app.path,
                                   "DEPENDENCY_TEND_RELEASE_BINARY": fakeBinary.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1",
                                   "DEPENDENCY_TEND_SKIP_CODESIGN": "1"
                               ])

        XCTAssertEqual(result.status, 0, result.output)
        let info = try String(contentsOf: app.appendingPathComponent("Contents/Info.plist"),
                              encoding: .utf8)
        XCTAssertTrue(info.contains("<key>CFBundleIconFile</key>"), info)
        XCTAssertTrue(info.contains("<string>AppIcon</string>"), info)

        let icon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: icon.path), icon.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: icon.path)
        let iconSize = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertGreaterThan(iconSize, 0)
    }

    func testMakeAppBundlesExplicitAppUpdatePublicKey() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-make-app-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fakeBinary = temp.appendingPathComponent("DependencyTend")
        let app = temp.appendingPathComponent("DependencyTend.app")
        let publicKey = temp.appendingPathComponent("DependencyTendAppUpdatePublicKey.pem")
        let keyData = Data("-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----\n".utf8)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
        try keyData.write(to: publicKey)

        let result = runScript("scripts/make-app.sh",
                               environment: [
                                   "DEPENDENCY_TEND_APP_OUTPUT": app.path,
                                   "DEPENDENCY_TEND_RELEASE_BINARY": fakeBinary.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1",
                                   "DEPENDENCY_TEND_SKIP_CODESIGN": "1",
                                   "DEPENDENCY_TEND_APP_UPDATE_PUBLIC_KEY": publicKey.path
                               ])

        XCTAssertEqual(result.status, 0, result.output)
        let bundledKey = app.appendingPathComponent(
            "Contents/Resources/DependencyTendAppUpdatePublicKey.pem"
        )
        XCTAssertEqual(try Data(contentsOf: bundledKey), keyData)
    }

    func testMakeAppFailsWhenExplicitAppUpdatePublicKeyIsMissing() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-make-app-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fakeBinary = temp.appendingPathComponent("DependencyTend")
        let app = temp.appendingPathComponent("DependencyTend.app")
        let missingPublicKey = temp.appendingPathComponent("missing-public-key.pem")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)

        let result = runScript("scripts/make-app.sh",
                               environment: [
                                   "DEPENDENCY_TEND_APP_OUTPUT": app.path,
                                   "DEPENDENCY_TEND_RELEASE_BINARY": fakeBinary.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1",
                                   "DEPENDENCY_TEND_SKIP_CODESIGN": "1",
                                   "DEPENDENCY_TEND_APP_UPDATE_PUBLIC_KEY": missingPublicKey.path
                               ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("app update public key not found"), result.output)
    }

    func testPackageReleaseCreatesVerifiedReleaseArtifacts() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-package-release-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let app = temp.appendingPathComponent("DependencyTend.app")
        let output = temp.appendingPathComponent("artifacts")
        let privateKey = temp.appendingPathComponent("manifest-private.pem")
        let publicKey = temp.appendingPathComponent("manifest-public.pem")
        let version = try currentVersion()
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try makeValidBundle(at: app, version: version, buildNumber: "42")
        try generateSigningKey(privateKey: privateKey, publicKey: publicKey)

        let result = runScript("scripts/package-release.sh",
                               environment: [
                                   "DEPENDENCY_TEND_RELEASE_APP": app.path,
                                   "DEPENDENCY_TEND_RELEASE_OUTPUT_DIR": output.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1",
                                   "DEPENDENCY_TEND_ALLOW_DIRTY": "1",
                                   "DEPENDENCY_TEND_SKIP_TAG_CHECK": "1",
                                   "DEPENDENCY_TEND_SKIP_ARCH_CHECK": "1",
                                   "DEPENDENCY_TEND_BUILD_NUMBER": "42",
                                   "DEPENDENCY_TEND_COMMIT_SHA": String(repeating: "a", count: 40),
                                   "DEPENDENCY_TEND_MANIFEST_SIGNING_KEY": privateKey.path
                               ])

        XCTAssertEqual(result.status, 0, result.output)
        let zip = output.appendingPathComponent("DependencyTend.app.zip")
        let checksum = output.appendingPathComponent("DependencyTend.app.zip.sha256")
        let manifest = output.appendingPathComponent("DependencyTend.update-manifest.json")
        let signature = output.appendingPathComponent("DependencyTend.update-manifest.json.sig")
        for artifact in [zip, checksum, manifest, signature] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path), artifact.path)
        }

        let zipList = run("/usr/bin/zipinfo", arguments: ["-1", zip.path])
        XCTAssertEqual(zipList.status, 0, zipList.output)
        XCTAssertTrue(zipList.output.split(separator: "\n").allSatisfy {
            $0 == "DependencyTend.app/" || $0.hasPrefix("DependencyTend.app/")
        }, zipList.output)

        let checksumLine = try String(contentsOf: checksum, encoding: .utf8)
        XCTAssertNotNil(checksumLine.range(of: #"^[a-f0-9]{64}\s+DependencyTend\.app\.zip\s*$"#,
                                           options: .regularExpression), checksumLine)
        let manifestText = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertTrue(manifestText.contains(#""version": "\#(version)""#), manifestText)
        XCTAssertTrue(manifestText.contains(#""buildNumber": "42""#), manifestText)
        XCTAssertTrue(manifestText.contains(#""assetName": "DependencyTend.app.zip""#), manifestText)

        let verify = run("/usr/bin/openssl",
                         arguments: ["dgst", "-sha256", "-verify", publicKey.path,
                                     "-signature", signature.path, manifest.path])
        XCTAssertEqual(verify.status, 0, verify.output)
    }

    func testValidateAppBundleChecksExecutableShape() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-bundle-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fm = FileManager.default
        let bundle = temp.appendingPathComponent("DependencyTend.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        let executable = macOS.appendingPathComponent("DependencyTend")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>DependencyTend</string>
        <key>CFBundleIdentifier</key><string>dev.ifi999.dependency-tend</string>
        </dict></plist>
        """.write(to: bundle.appendingPathComponent("Contents/Info.plist"),
                  atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let valid = runScript("scripts/validate-app-bundle.sh", arguments: [bundle.path])
        XCTAssertEqual(valid.status, 0, valid.output)

        try Data().write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let empty = runScript("scripts/validate-app-bundle.sh", arguments: [bundle.path])
        XCTAssertNotEqual(empty.status, 0)
        XCTAssertTrue(empty.output.contains("empty"), empty.output)

        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        let notExecutable = runScript("scripts/validate-app-bundle.sh", arguments: [bundle.path])
        XCTAssertNotEqual(notExecutable.status, 0)
        XCTAssertTrue(notExecutable.output.contains("not executable"), notExecutable.output)

        try fm.removeItem(at: bundle.appendingPathComponent("Contents/Info.plist"))
        let invalid = runScript("scripts/validate-app-bundle.sh", arguments: [bundle.path])
        XCTAssertNotEqual(invalid.status, 0)
        XCTAssertTrue(invalid.output.contains("Info.plist"), invalid.output)
    }

    func testInstallAppDryRunIsScopedToDependencyTendApp() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-install-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("Source/DependencyTend.app")
        let destination = temp.appendingPathComponent("DependencyTend.app")
        try makeValidBundle(at: source)

        let result = runScript("scripts/install-app.sh",
                               arguments: ["--dry-run"],
                               environment: [
                                   "DEPENDENCY_TEND_DESTINATION_APP": destination.path,
                                   "DEPENDENCY_TEND_SOURCE_APP": source.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1"
                               ])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains(destination.path), result.output)
        XCTAssertTrue(result.output.contains("DependencyTend"), result.output)
        XCTAssertTrue(result.output.contains("dry run complete"), result.output)
        XCTAssertFalse(result.output.contains("installed at"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testInstallAppDryRunFailsWhenSkippedSourceIsMissing() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-install-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let missingSource = temp.appendingPathComponent("Missing.app")
        let destination = temp.appendingPathComponent("DependencyTend.app")

        let result = runScript("scripts/install-app.sh",
                               arguments: ["--dry-run"],
                               environment: [
                                   "DEPENDENCY_TEND_DESTINATION_APP": destination.path,
                                   "DEPENDENCY_TEND_SOURCE_APP": missingSource.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1"
                               ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("app bundle not found"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testInstallAppDryRunUsesStagedReplacement() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-install-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("Source/DependencyTend.app")
        let destination = temp.appendingPathComponent("DependencyTend.app")
        try makeValidBundle(at: source)
        try makeValidBundle(at: destination)

        let result = runScript("scripts/install-app.sh",
                               arguments: ["--dry-run", "--no-launch"],
                               environment: [
                                   "DEPENDENCY_TEND_DESTINATION_APP": destination.path,
                                   "DEPENDENCY_TEND_SOURCE_APP": source.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1"
                               ])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains(".install-"), result.output)
        XCTAssertTrue(result.output.contains(".previous-"), result.output)
        let lines = result.output.split(separator: "\n").map(String.init)
        XCTAssertFalse(lines.contains("+ rm -rf \(destination.path)"), result.output)
        XCTAssertFalse(lines.contains("+ cp -R \(source.path) \(destination.path)"), result.output)
    }

    func testInstallAppRollsBackExistingDestinationWhenReplacementFails() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-install-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("Source/DependencyTend.app")
        let destination = temp.appendingPathComponent("DependencyTend.app")
        try makeValidBundle(at: source, marker: "new")
        try makeValidBundle(at: destination, marker: "old")

        let result = runScript("scripts/install-app.sh",
                               arguments: ["--no-launch"],
                               environment: [
                                   "DEPENDENCY_TEND_DESTINATION_APP": destination.path,
                                   "DEPENDENCY_TEND_SOURCE_APP": source.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1",
                                   "DEPENDENCY_TEND_ALLOW_TEST_HOOKS": "1",
                                   "DEPENDENCY_TEND_FAIL_AFTER_REPLACE": "1"
                               ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Injected install failure"), result.output)
        XCTAssertEqual(try installMarker(in: destination), "old")
        let tempNames = try FileManager.default.contentsOfDirectory(atPath: temp.path)
        XCTAssertFalse(tempNames.contains { $0.contains(".install-") }, tempNames.joined(separator: "\n"))
        XCTAssertFalse(tempNames.contains { $0.contains(".previous-") }, tempNames.joined(separator: "\n"))
    }

    func testInstallAppIgnoresFailureInjectionUnlessTestHooksAreAllowed() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-tend-install-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("Source/DependencyTend.app")
        let destination = temp.appendingPathComponent("DependencyTend.app")
        try makeValidBundle(at: source, marker: "new")
        try makeValidBundle(at: destination, marker: "old")

        let result = runScript("scripts/install-app.sh",
                               arguments: ["--no-launch"],
                               environment: [
                                   "DEPENDENCY_TEND_DESTINATION_APP": destination.path,
                                   "DEPENDENCY_TEND_SOURCE_APP": source.path,
                                   "DEPENDENCY_TEND_SKIP_BUILD": "1",
                                   "DEPENDENCY_TEND_FAIL_AFTER_REPLACE": "1"
                               ])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(result.output.contains("Injected install failure"), result.output)
        XCTAssertEqual(try installMarker(in: destination), "new")
    }

    private func assertBashSyntax(script: String) throws {
        let result = run("/bin/bash", arguments: ["-n", root.appendingPathComponent(script).path])
        XCTAssertEqual(result.status, 0, result.output)
    }

    private func makeValidBundle(at bundle: URL, marker: String? = nil,
                                 version: String? = nil, buildNumber: String? = nil) throws {
        let fm = FileManager.default
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        let executable = macOS.appendingPathComponent("DependencyTend")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>DependencyTend</string>
        <key>CFBundleIdentifier</key><string>dev.ifi999.dependency-tend</string>
        <key>CFBundleShortVersionString</key><string>\(version ?? "1.0.0")</string>
        <key>CFBundleVersion</key><string>\(buildNumber ?? "1")</string>
        </dict></plist>
        """.write(to: bundle.appendingPathComponent("Contents/Info.plist"),
                  atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if let marker {
            let resources = bundle.appendingPathComponent("Contents/Resources")
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            try marker.write(to: resources.appendingPathComponent("install-marker.txt"),
                             atomically: true, encoding: .utf8)
        }
    }

    private func installMarker(in bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("Contents/Resources/install-marker.txt"),
                   encoding: .utf8)
    }

    private func currentVersion() throws -> String {
        try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateSigningKey(privateKey: URL, publicKey: URL) throws {
        let generated = run("/usr/bin/openssl",
                            arguments: ["genrsa", "-out", privateKey.path, "2048"])
        XCTAssertEqual(generated.status, 0, generated.output)
        let exported = run("/usr/bin/openssl",
                           arguments: ["pkey", "-in", privateKey.path, "-pubout", "-out", publicKey.path])
        XCTAssertEqual(exported.status, 0, exported.output)
    }

    private func runScript(_ script: String, arguments: [String] = [],
                           environment: [String: String] = [:]) -> (status: Int32, output: String) {
        run("/bin/bash", arguments: [root.appendingPathComponent(script).path] + arguments,
            environment: environment)
    }

    private func run(_ executable: String, arguments: [String],
                     environment: [String: String] = [:]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (127, String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
