import Foundation

public enum AppUpdateInstallError: Error, Equatable, LocalizedError, Sendable {
    case missingArchive(URL)
    case missingInstallerScript(URL)
    case missingValidatorScript(URL)
    case missingExecutable(URL)

    public var errorDescription: String? {
        switch self {
        case .missingArchive(let url):
            return "다운로드된 앱 업데이트 파일을 찾을 수 없습니다: \(url.path)"
        case .missingInstallerScript(let url):
            return "앱 업데이트 설치 스크립트를 찾을 수 없습니다: \(url.path)"
        case .missingValidatorScript(let url):
            return "앱 업데이트 검증 스크립트를 찾을 수 없습니다: \(url.path)"
        case .missingExecutable(let url):
            return "앱 업데이트 실행 파일을 찾을 수 없습니다: \(url.path)"
        }
    }
}

public protocol AppUpdateInstallLaunching: Sendable {
    func launch(_ executable: URL, arguments: [String],
                environment: [String: String]) throws
}

public struct ProcessAppUpdateInstallLauncher: AppUpdateInstallLaunching {
    public init() {}

    public func launch(_ executable: URL, arguments: [String],
                       environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

public struct ScriptedAppUpdateInstaller: AppUpdateInstalling {
    private let installScriptURL: URL
    private let validateScriptURL: URL
    private let bashURL: URL
    private let dittoURL: URL
    private let destinationAppURL: URL
    private let launchAfterInstall: Bool
    private let launcher: any AppUpdateInstallLaunching
    private let workDirectory: @Sendable () -> URL

    public init(installScriptURL: URL,
                validateScriptURL: URL,
                bashURL: URL = URL(fileURLWithPath: "/bin/bash"),
                dittoURL: URL = URL(fileURLWithPath: "/usr/bin/ditto"),
                destinationAppURL: URL = URL(fileURLWithPath: "/Applications/DependencyTend.app"),
                launchAfterInstall: Bool = true,
                launcher: any AppUpdateInstallLaunching = ProcessAppUpdateInstallLauncher(),
                workDirectory: @escaping @Sendable () -> URL = {
                    FileManager.default.temporaryDirectory
                        .appendingPathComponent("DependencyTendInstall-\(UUID().uuidString)",
                                                isDirectory: true)
                }) {
        self.installScriptURL = installScriptURL
        self.validateScriptURL = validateScriptURL
        self.bashURL = bashURL
        self.dittoURL = dittoURL
        self.destinationAppURL = destinationAppURL
        self.launchAfterInstall = launchAfterInstall
        self.launcher = launcher
        self.workDirectory = workDirectory
    }

    public static func bundleResource(bundle: Bundle = .main) -> ScriptedAppUpdateInstaller? {
        guard let resources = bundle.resourceURL else { return nil }
        let scripts = resources.appendingPathComponent("scripts", isDirectory: true)
        let installScript = scripts.appendingPathComponent("install-app.sh")
        let validateScript = scripts.appendingPathComponent("validate-app-bundle.sh")
        guard FileManager.default.isExecutableFile(atPath: installScript.path),
              FileManager.default.isExecutableFile(atPath: validateScript.path) else {
            return nil
        }
        return ScriptedAppUpdateInstaller(installScriptURL: installScript,
                                          validateScriptURL: validateScript,
                                          destinationAppURL: defaultDestinationAppURL(bundle: bundle))
    }

    public func install(_ prepared: PreparedAppUpdate) async throws {
        try validateInputs(prepared)
        let work = workDirectory()
        let extract = work.appendingPathComponent("extract", isDirectory: true)
        let helper = work.appendingPathComponent("install-update.sh")
        let log = prepared.logFileURL ?? prepared.archiveURL.deletingLastPathComponent()
            .appendingPathComponent("DependencyTend.install.log")

        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try helperScript(prepared: prepared, workDirectory: work,
                         extractDirectory: extract, logFile: log)
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: helper.path)
        try launcher.launch(bashURL, arguments: [helper.path], environment: [:])
    }

    private func validateInputs(_ prepared: PreparedAppUpdate) throws {
        guard FileManager.default.fileExists(atPath: prepared.archiveURL.path) else {
            throw AppUpdateInstallError.missingArchive(prepared.archiveURL)
        }
        guard FileManager.default.isExecutableFile(atPath: installScriptURL.path) else {
            throw AppUpdateInstallError.missingInstallerScript(installScriptURL)
        }
        guard FileManager.default.isExecutableFile(atPath: validateScriptURL.path) else {
            throw AppUpdateInstallError.missingValidatorScript(validateScriptURL)
        }
        for executable in [bashURL, dittoURL] where !FileManager.default.isExecutableFile(atPath: executable.path) {
            throw AppUpdateInstallError.missingExecutable(executable)
        }
    }

    private func helperScript(prepared: PreparedAppUpdate,
                              workDirectory: URL,
                              extractDirectory: URL,
                              logFile: URL) -> String {
        let launchArgument = launchAfterInstall ? "" : " --no-launch"
        return """
        #!/usr/bin/env bash
        set -euo pipefail

        LOG_FILE=\(Self.shellEscaped(logFile.path))
        WORK_DIR=\(Self.shellEscaped(workDirectory.path))
        EXTRACT_DIR=\(Self.shellEscaped(extractDirectory.path))
        ARCHIVE=\(Self.shellEscaped(prepared.archiveURL.path))
        DITTO=\(Self.shellEscaped(dittoURL.path))
        VALIDATE_SCRIPT=\(Self.shellEscaped(validateScriptURL.path))
        INSTALL_SCRIPT=\(Self.shellEscaped(installScriptURL.path))
        DESTINATION_APP=\(Self.shellEscaped(destinationAppURL.path))

        mkdir -p "$(dirname "$LOG_FILE")"
        exec >> "$LOG_FILE" 2>&1

        cleanup() {
          rm -rf "$WORK_DIR"
        }
        trap cleanup EXIT

        echo "Installing DependencyTend update from $ARCHIVE"
        mkdir -p "$EXTRACT_DIR"
        "$DITTO" -x -k "$ARCHIVE" "$EXTRACT_DIR"

        APP="$EXTRACT_DIR/DependencyTend.app"
        if [[ ! -d "$APP" ]]; then
          echo "DependencyTend.app missing from archive" >&2
          exit 65
        fi

        EXTRA_COUNT="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 ! -name 'DependencyTend.app' | wc -l | tr -d '[:space:]')"
        if [[ "$EXTRA_COUNT" != "0" ]]; then
          echo "Archive contains unexpected top-level entries" >&2
          exit 65
        fi

        "$VALIDATE_SCRIPT" "$APP"
        DEPENDENCY_TEND_SOURCE_APP="$APP" \\
        DEPENDENCY_TEND_DESTINATION_APP="$DESTINATION_APP" \\
        DEPENDENCY_TEND_SKIP_BUILD=1 \\
        "$INSTALL_SCRIPT"\(launchArgument)
        """
    }

    private static func defaultDestinationAppURL(bundle: Bundle) -> URL {
        if bundle.bundleURL.lastPathComponent == "DependencyTend.app" {
            return bundle.bundleURL
        }
        return URL(fileURLWithPath: "/Applications/DependencyTend.app")
    }

    private static func shellEscaped(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=+-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
