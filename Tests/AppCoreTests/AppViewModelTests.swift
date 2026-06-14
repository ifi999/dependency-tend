import XCTest
import Engine
@testable import AppCore

/// 기록형 가짜 어댑터: scan은 스크립트된 결과, updateCommand는 /bin/echo (실제 실행돼도 무해)
final class RecordingAdapter: PackageManagerAdapter, @unchecked Sendable {
    let id: ManagerID
    private let queue = DispatchQueue(label: "dependency-tend.recording-adapter")
    private var storedScanResult: AdapterScan
    private var shouldFailUpdates = false
    private var recordedUpdateRequests: [String] = []

    var scanResult: AdapterScan {
        get { queue.sync { storedScanResult } }
        set { queue.sync { storedScanResult = newValue } }
    }

    var failUpdates: Bool {
        get { queue.sync { shouldFailUpdates } }
        set { queue.sync { shouldFailUpdates = newValue } }
    }

    private var shouldFailWithSudoStderr = false
    /// mas가 root 소유 앱 교체를 위해 내부에서 sudo를 부르는 상황 재현
    var failWithSudoStderr: Bool {
        get { queue.sync { shouldFailWithSudoStderr } }
        set { queue.sync { shouldFailWithSudoStderr = newValue } }
    }

    private var shouldFailWithPluginNotFound = false
    /// legacy(version "unknown") 설치 기록을 claude plugin update가 인식 못 하는 상황 재현
    var failWithPluginNotFound: Bool {
        get { queue.sync { shouldFailWithPluginNotFound } }
        set { queue.sync { shouldFailWithPluginNotFound = newValue } }
    }

    var updateRequests: [String] { queue.sync { recordedUpdateRequests } }

    init(id: ManagerID, scanResult: AdapterScan) {
        self.id = id
        self.storedScanResult = scanResult
    }

    func isAvailable() -> Bool { true }
    func scan(now: Date) async throws -> AdapterScan { scanResult }
    func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        let mode = queue.sync { () -> (fail: Bool, sudo: Bool, notFound: Bool) in
            recordedUpdateRequests.append(pkg.name)
            return (shouldFailUpdates, shouldFailWithSudoStderr, shouldFailWithPluginNotFound)
        }
        if mode.sudo {
            return UpdateCommand(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c",
                            "echo 'sudo: a terminal is required to read the password' 1>&2; echo 'sudo: a password is required' 1>&2; exit 1"])
        }
        if mode.notFound {
            return UpdateCommand(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c",
                            "echo '✘ Failed to update plugin \"x\": Plugin \"x\" not found'; exit 1"])
        }
        if mode.fail {
            return UpdateCommand(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        }
        return UpdateCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["updated", pkg.name])
    }
}

final class UnsupportedUpdateAdapter: PackageManagerAdapter, @unchecked Sendable {
    let id: ManagerID
    let scanResult: AdapterScan

    init(id: ManagerID, scanResult: AdapterScan) {
        self.id = id
        self.scanResult = scanResult
    }

    func isAvailable() -> Bool { true }
    func scan(now: Date) async throws -> AdapterScan { scanResult }
    func updateCommand(for pkg: PackageInfo) -> UpdateCommand? { nil }
}

final class UnavailableAdapter: PackageManagerAdapter, @unchecked Sendable {
    let id: ManagerID

    init(id: ManagerID) {
        self.id = id
    }

    func isAvailable() -> Bool { false }
    func scan(now: Date) async throws -> AdapterScan { AdapterScan(packages: []) }
    func updateCommand(for pkg: PackageInfo) -> UpdateCommand? { nil }
}

final class FailingScanAdapter: PackageManagerAdapter, @unchecked Sendable {
    let id: ManagerID
    let error: Error

    init(id: ManagerID, error: Error) {
        self.id = id
        self.error = error
    }

    func isAvailable() -> Bool { true }
    func scan(now: Date) async throws -> AdapterScan { throw error }
    func updateCommand(for pkg: PackageInfo) -> UpdateCommand? { nil }
}

final class AppCoreMockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
    }

    private let queue = DispatchQueue(label: "dependency-tend.app-core-mock-command-runner")
    private var responses: [String: CommandOutput] = [:]
    private var recordedCalls: [Call] = []

    var calls: [Call] { queue.sync { recordedCalls } }

    func stub(_ key: String, _ output: CommandOutput) {
        queue.sync { responses[key] = output }
    }

    func run(_ executable: URL, arguments: [String],
             environment: [String: String], timeout: TimeInterval) async throws -> CommandOutput {
        let key = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        return try queue.sync {
            recordedCalls.append(Call(arguments: arguments))
            guard let output = responses[key] else {
                throw CommandError.launchFailed("AppCoreMockCommandRunner: 스텁 없음 — \(key)")
            }
            return output
        }
    }
}

final class BlockingRescanAdapter: PackageManagerAdapter, @unchecked Sendable {
    let id = ManagerID.homebrew
    private let queue = DispatchQueue(label: "dependency-tend.blocking-rescan-adapter")
    private var scanCount = 0
    private var storedScanResult: AdapterScan
    let rescanStarted = AsyncSignal()
    let allowRescan = AsyncSignal()

    init(scanResult: AdapterScan) {
        self.storedScanResult = scanResult
    }

    func setScanResult(_ result: AdapterScan) {
        queue.sync { storedScanResult = result }
    }

    func isAvailable() -> Bool { true }

    func scan(now: Date) async throws -> AdapterScan {
        let state = queue.sync { () -> (Int, AdapterScan) in
            scanCount += 1
            return (scanCount, storedScanResult)
        }
        if state.0 == 2 {
            rescanStarted.signal()
            await allowRescan.wait()
        }
        return state.1
    }

    func updateCommand(for pkg: PackageInfo) -> UpdateCommand? {
        UpdateCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["updated", pkg.name])
    }
}

final class AsyncSignal: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dependency-tend.async-signal")
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let continuations = queue.sync { () -> [CheckedContinuation<Void, Never>] in
            signaled = true
            let current = waiters
            waiters.removeAll()
            return current
        }
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = queue.sync { () -> Bool in
                if signaled { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
}

final class AsyncCounter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dependency-tend.async-counter")
    private var count = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    @discardableResult
    func increment() -> Int {
        let continuations = queue.sync { () -> [CheckedContinuation<Void, Never>] in
            count += 1
            let ready = waiters.filter { $0.target <= count }.map(\.continuation)
            waiters.removeAll { $0.target <= count }
            return ready
        }
        continuations.forEach { $0.resume() }
        return value
    }

    var value: Int { queue.sync { count } }

    func wait(for target: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = queue.sync { () -> Bool in
                if count >= target { return true }
                waiters.append((target, continuation))
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
}

final class StepwiseCommandRunner: CommandRunning, @unchecked Sendable {
    let started = AsyncCounter()
    let allowed = AsyncCounter()

    func allowNext() {
        allowed.increment()
    }

    func run(_ executable: URL, arguments: [String],
             environment: [String: String], timeout: TimeInterval) async throws -> CommandOutput {
        let index = started.increment()
        await allowed.wait(for: index)
        return CommandOutput(stdout: "updated \(arguments.last ?? "")\n", stderr: "", exitCode: 0)
    }
}

final class ScriptedAppUpdateChecker: AppUpdateChecking, @unchecked Sendable {
    let current: AppVersion
    let latest: AppUpdateRelease
    let error: Error?

    init(current: AppVersion, latest: AppUpdateRelease, error: Error? = nil) {
        self.current = current
        self.latest = latest
        self.error = error
    }

    func currentVersion() -> AppVersion { current }

    func latestRelease() async throws -> AppUpdateRelease {
        if let error { throw error }
        return latest
    }
}

final class BlockingAppUpdateChecker: AppUpdateChecking, @unchecked Sendable {
    let current: AppVersion
    let latest: AppUpdateRelease
    let latestReleaseStarted = AsyncSignal()
    let allowLatestRelease = AsyncSignal()

    init(current: AppVersion, latest: AppUpdateRelease) {
        self.current = current
        self.latest = latest
    }

    func currentVersion() -> AppVersion { current }

    func latestRelease() async throws -> AppUpdateRelease {
        latestReleaseStarted.signal()
        await allowLatestRelease.wait()
        return latest
    }
}

final class BlockingAppUpdatePreparer: AppUpdatePreparing, @unchecked Sendable {
    let prepared: PreparedAppUpdate
    let error: Error?
    let prepareStarted = AsyncSignal()
    let allowPrepare = AsyncSignal()
    private let lock = NSLock()
    private var recordedReleases: [AppUpdateRelease] = []

    var requestedReleases: [AppUpdateRelease] {
        lock.withLock { recordedReleases }
    }

    init(prepared: PreparedAppUpdate, error: Error? = nil) {
        self.prepared = prepared
        self.error = error
    }

    func prepare(_ release: AppUpdateRelease) async throws -> PreparedAppUpdate {
        lock.withLock { recordedReleases.append(release) }
        prepareStarted.signal()
        await allowPrepare.wait()
        if let error { throw error }
        return prepared
    }
}

final class BlockingAppUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
    let error: Error?
    let installStarted = AsyncSignal()
    let allowInstall = AsyncSignal()
    private let lock = NSLock()
    private var recordedPreparedUpdates: [PreparedAppUpdate] = []

    var installedUpdates: [PreparedAppUpdate] {
        lock.withLock { recordedPreparedUpdates }
    }

    init(error: Error? = nil) {
        self.error = error
    }

    func install(_ prepared: PreparedAppUpdate) async throws {
        lock.withLock { recordedPreparedUpdates.append(prepared) }
        installStarted.signal()
        await allowInstall.wait()
        if let error { throw error }
    }
}

@MainActor
final class AppViewModelTests: XCTestCase {
    private lazy var tempCache: ScanCache! = ScanCache(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("tend-vm-\(UUID().uuidString)/cache.json"))
    private lazy var tempPolicy: UserPolicyStore! = UserPolicyStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("tend-policy-\(UUID().uuidString)/policy.json"))
    private lazy var tempHistory: UpdateHistoryStore! = UpdateHistoryStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("tend-history-\(UUID().uuidString)/history.jsonl"))

    private func makePackages() -> [PackageInfo] {
        [
            // patch 점프 → low (안전)
            PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.0", latest: "1.0.1", status: .outdated),
            // major 점프 → high (위험)
            PackageInfo(name: "risky-pkg", manager: .homebrew, current: "1.0.0", latest: "2.0.0", status: .outdated),
            // 최신
            PackageInfo(name: "fine-pkg", manager: .homebrew, current: "1.0.0", status: .upToDate),
        ]
    }

    private func makeVM(adapter: any PackageManagerAdapter,
                        runner: any CommandRunning = ProcessCommandRunner(),
                        policyStore: UserPolicyStore? = nil,
                        historyStore: UpdateHistoryStore? = nil,
                        appUpdateChecker: (any AppUpdateChecking)? = nil,
                        appUpdatePreparer: (any AppUpdatePreparing)? = nil,
                        appUpdateInstaller: (any AppUpdateInstalling)? = nil,
                        toolDiagnostics: [ToolDiagnostic] = [],
                        now: @escaping @Sendable () -> Date = { Date() }) -> AppViewModel {
        AppViewModel(scanner: PackageScanner(adapters: [adapter], now: { Date(timeIntervalSince1970: 1_750_000_000) }),
                     executor: UpdateExecutor(runner: runner),
                     adapters: [adapter],
                     cache: tempCache,
                     ledger: RemovalLedger(fileURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("tend-vm-ledger-\(UUID().uuidString)/ledger.json")),
                     policyStore: policyStore ?? tempPolicy,
                     historyStore: historyStore ?? tempHistory,
                     appUpdateChecker: appUpdateChecker,
                     appUpdatePreparer: appUpdatePreparer,
                     appUpdateInstaller: appUpdateInstaller,
                     toolDiagnostics: toolDiagnostics,
                     now: now)
    }

    private func makeVM(adapters: [any PackageManagerAdapter],
                        runner: any CommandRunning = ProcessCommandRunner(),
                        policyStore: UserPolicyStore? = nil,
                        historyStore: UpdateHistoryStore? = nil,
                        appUpdateChecker: (any AppUpdateChecking)? = nil,
                        appUpdatePreparer: (any AppUpdatePreparing)? = nil,
                        appUpdateInstaller: (any AppUpdateInstalling)? = nil,
                        toolDiagnostics: [ToolDiagnostic] = [],
                        now: @escaping @Sendable () -> Date = { Date() }) -> AppViewModel {
        AppViewModel(scanner: PackageScanner(adapters: adapters, now: { Date(timeIntervalSince1970: 1_750_000_000) }),
                     executor: UpdateExecutor(runner: runner),
                     adapters: adapters,
                     cache: tempCache,
                     policyStore: policyStore ?? tempPolicy,
                     historyStore: historyStore ?? tempHistory,
                     appUpdateChecker: appUpdateChecker,
                     appUpdatePreparer: appUpdatePreparer,
                     appUpdateInstaller: appUpdateInstaller,
                     toolDiagnostics: toolDiagnostics,
                     now: now)
    }

    func testInitStoresToolDiagnostics() {
        let diagnostics = [
            ToolDiagnostic(id: "homebrew", name: "Homebrew", path: "/opt/homebrew/bin/brew"),
        ]
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                        toolDiagnostics: diagnostics)

        XCTAssertEqual(vm.toolDiagnostics, diagnostics)
    }

    func testCheckForAppUpdatePublishesCheckingThenAvailable() async throws {
        let latest = appRelease("1.3.0")
        let checker = BlockingAppUpdateChecker(current: try XCTUnwrap(AppVersion.parse("1.2.3")),
                                               latest: latest)
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                        appUpdateChecker: checker)

        let task = Task { await vm.checkForAppUpdate() }
        await checker.latestReleaseStarted.wait()

        XCTAssertEqual(vm.appUpdateState, .checking)

        checker.allowLatestRelease.signal()
        await task.value

        XCTAssertEqual(vm.appUpdateState, .available(release: latest))
    }

    func testCheckForAppUpdatePublishesUpToDateWhenNoNewerReleaseExists() async throws {
        let current = try XCTUnwrap(AppVersion.parse("1.3.0"))
        let checker = ScriptedAppUpdateChecker(current: current, latest: appRelease("1.3.0"))
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                        appUpdateChecker: checker)

        await vm.checkForAppUpdate()

        XCTAssertEqual(vm.appUpdateState, .upToDate(version: current))
    }

    func testCheckForAppUpdatePublishesFailureState() async throws {
        let checker = ScriptedAppUpdateChecker(current: try XCTUnwrap(AppVersion.parse("1.2.3")),
                                               latest: appRelease("1.3.0"),
                                               error: AppUpdateCheckError.noValidRelease)
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                        appUpdateChecker: checker)

        await vm.checkForAppUpdate()

        guard case .failed(let message, _) = vm.appUpdateState else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(message.contains("DependencyTend"))
    }

    func testPrepareAppUpdatePublishesDownloadingThenReady() async throws {
        let latest = appRelease("1.3.0")
        let checker = ScriptedAppUpdateChecker(current: try XCTUnwrap(AppVersion.parse("1.2.3")),
                                               latest: latest)
        let prepared = PreparedAppUpdate(release: latest,
                                         archiveURL: URL(fileURLWithPath: "/tmp/DependencyTend.app.zip"),
                                         logFileURL: nil)
        let preparer = BlockingAppUpdatePreparer(prepared: prepared)
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                        appUpdateChecker: checker,
                        appUpdatePreparer: preparer)
        await vm.checkForAppUpdate()
        XCTAssertEqual(vm.appUpdateState, .available(release: latest))

        let task = Task { await vm.prepareAppUpdate(latest) }
        await preparer.prepareStarted.wait()

        XCTAssertEqual(vm.appUpdateState, .downloading(release: latest))

        preparer.allowPrepare.signal()
        await task.value

        XCTAssertEqual(preparer.requestedReleases, [latest])
        XCTAssertEqual(vm.appUpdateState, .readyToInstall(prepared: prepared))
    }

    func testCanPrepareAppUpdateReflectsInjectedPreparer() {
        let latest = appRelease("1.3.0")
        let prepared = PreparedAppUpdate(release: latest,
                                         archiveURL: URL(fileURLWithPath: "/tmp/DependencyTend.app.zip"),
                                         logFileURL: nil)
        let withPreparer = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                                  appUpdatePreparer: BlockingAppUpdatePreparer(prepared: prepared))
        let withoutPreparer = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])))

        XCTAssertTrue(withPreparer.canPrepareAppUpdate)
        XCTAssertFalse(withoutPreparer.canPrepareAppUpdate)
    }

    func testInstallAppUpdatePublishesInstallingThenUpToDate() async throws {
        let latest = appRelease("1.3.0")
        let prepared = PreparedAppUpdate(release: latest,
                                         archiveURL: URL(fileURLWithPath: "/tmp/DependencyTend.app.zip"),
                                         logFileURL: nil)
        let preparer = BlockingAppUpdatePreparer(prepared: prepared)
        let installer = BlockingAppUpdateInstaller()
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                        appUpdateChecker: ScriptedAppUpdateChecker(current: try XCTUnwrap(AppVersion.parse("1.2.3")),
                                                                   latest: latest),
                        appUpdatePreparer: preparer,
                        appUpdateInstaller: installer)
        await vm.checkForAppUpdate()
        let prepareTask = Task { await vm.prepareAppUpdate(latest) }
        await preparer.prepareStarted.wait()
        preparer.allowPrepare.signal()
        await prepareTask.value
        XCTAssertEqual(vm.appUpdateState, .readyToInstall(prepared: prepared))

        let installTask = Task { await vm.installAppUpdate(prepared) }
        await installer.installStarted.wait()

        XCTAssertEqual(vm.appUpdateState, .installing)

        installer.allowInstall.signal()
        await installTask.value

        XCTAssertEqual(installer.installedUpdates, [prepared])
        XCTAssertEqual(vm.appUpdateState,
                       .upToDate(version: AppVersion(version: latest.version,
                                                     versionString: latest.versionString)))
    }

    func testInstallAppUpdatePublishesFailureWithRecovery() async throws {
        let latest = appRelease("1.3.0")
        let prepared = PreparedAppUpdate(release: latest,
                                         archiveURL: URL(fileURLWithPath: "/tmp/DependencyTend.app.zip"),
                                         logFileURL: URL(fileURLWithPath: "/tmp/dependency-tend-install.log"))
        let preparer = BlockingAppUpdatePreparer(prepared: prepared)
        let installer = BlockingAppUpdateInstaller(
            error: AppUpdatePrepareError.unexpectedStatus(url: latest.zipAssetURL, statusCode: 503)
        )
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                        appUpdateChecker: ScriptedAppUpdateChecker(current: try XCTUnwrap(AppVersion.parse("1.2.3")),
                                                                   latest: latest),
                        appUpdatePreparer: preparer,
                        appUpdateInstaller: installer)
        await vm.checkForAppUpdate()
        let prepareTask = Task { await vm.prepareAppUpdate(latest) }
        await preparer.prepareStarted.wait()
        preparer.allowPrepare.signal()
        await prepareTask.value

        let installTask = Task { await vm.installAppUpdate(prepared) }
        await installer.installStarted.wait()
        installer.allowInstall.signal()
        await installTask.value

        guard case .failed(let message, let recovery) = vm.appUpdateState else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(message.contains("HTTP 503"))
        XCTAssertEqual(recovery?.downloadedFileURL, prepared.archiveURL)
        XCTAssertEqual(recovery?.logFileURL, prepared.logFileURL)
    }

    func testPrepareAppUpdatePublishesFailureWithRecovery() async throws {
        let latest = appRelease("1.3.0")
        let checker = ScriptedAppUpdateChecker(current: try XCTUnwrap(AppVersion.parse("1.2.3")),
                                               latest: latest)
        let prepared = PreparedAppUpdate(release: latest,
                                         archiveURL: URL(fileURLWithPath: "/tmp/DependencyTend.app.zip"),
                                         logFileURL: nil)
        let preparer = BlockingAppUpdatePreparer(
            prepared: prepared,
            error: AppUpdatePrepareError.unexpectedStatus(url: latest.zipAssetURL, statusCode: 503)
        )
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])),
                        appUpdateChecker: checker,
                        appUpdatePreparer: preparer)
        await vm.checkForAppUpdate()

        let task = Task { await vm.prepareAppUpdate(latest) }
        await preparer.prepareStarted.wait()
        preparer.allowPrepare.signal()
        await task.value

        guard case .failed(let message, let recovery) = vm.appUpdateState else {
            return XCTFail("Expected failed state")
        }
        XCTAssertTrue(message.contains("HTTP 503"))
        XCTAssertEqual(recovery?.releasePageURL, latest.releasePageURL)
    }

    func testLanguageSelectionLoadsAndPersists() throws {
        let defaults = UserDefaults(suiteName: "AppViewModelTests.language.\(UUID().uuidString)")!
        let languageStore = LanguageStore(defaults: defaults, key: "language")
        try languageStore.save(.english)

        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: []))
        let vm = AppViewModel(
            scanner: PackageScanner(adapters: [adapter]),
            executor: UpdateExecutor(runner: ProcessCommandRunner()),
            adapters: [adapter],
            cache: tempCache,
            policyStore: tempPolicy,
            historyStore: tempHistory,
            languageStore: languageStore)

        XCTAssertEqual(vm.language, .english)
        XCTAssertEqual(vm.strings.refreshNow, "Scan now")

        vm.setLanguage(.korean)

        XCTAssertEqual(vm.language, .korean)
        XCTAssertEqual(vm.strings.refreshNow, "지금 다시 스캔")
        XCTAssertEqual(defaults.string(forKey: "language"), "ko")
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

    func testPruneRemovesRecordsLedgerAndRestores() async {
        // 트리 간 중복 → 잔재 제안 → 삭제(장부 기록) → 복구(장부 비움)
        let duplicates = [
            PackageInfo(name: "codex", manager: .npmGlobal, current: "0.139.0", status: .upToDate,
                        metadata: ["tree": "A", "npmPath": "/bin/echo"]),
            PackageInfo(name: "codex", manager: .npmGlobal, current: "0.101.0", status: .upToDate,
                        metadata: ["tree": "B", "npmPath": "/bin/echo"]),
        ]
        let adapter = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: duplicates))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()

        let suggestions = vm.pruneSuggestions
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].target.metadata["tree"], "B") // 낮은 버전이 잔재

        await vm.prune(suggestions[0])
        XCTAssertEqual(vm.recentRemovals.count, 1)
        XCTAssertEqual(vm.recentRemovals[0].name, "codex")
        XCTAssertEqual(vm.recentRemovals[0].version, "0.101.0") // 버전 박제

        await vm.restore(vm.recentRemovals[0])
        XCTAssertTrue(vm.recentRemovals.isEmpty) // 복구하면 장부에서 제거
    }

    func testPruneRefusesBlockedSuggestion() async {
        // MCP가 참조하는 패키지는 차단 — prune을 불러도 아무 일도 일어나지 않아야 한다
        let packages = [
            PackageInfo(name: "codegraph", manager: .npmGlobal, current: "1.0.0", status: .upToDate,
                        metadata: ["tree": "A", "npmPath": "/bin/echo"]),
            PackageInfo(name: "codegraph", manager: .npmGlobal, current: "0.9.0", status: .upToDate,
                        metadata: ["tree": "B", "npmPath": "/bin/echo"]),
            PackageInfo(name: "mcp:codegraph", manager: .claudePlugin, status: .unknown,
                        metadata: ["kind": "mcp", "mcpDetail": "codegraph serve --mcp"]),
        ]
        let adapter = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: packages))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        // 주의: refresh는 npmGlobal 어댑터만 있으므로 mcp 패키지는 packages에 없음 —
        // 제안 계산에 쓰일 전체 목록 기준으로 확인하기 위해 직접 advisor를 거친 결과를 사용
        let suggestions = PruneAdvisor.suggestions(packages: packages)
        XCTAssertNotNil(suggestions[0].blockReason)
        await vm.prune(suggestions[0])
        XCTAssertTrue(vm.recentRemovals.isEmpty) // 차단된 제안은 실행 안 됨
    }

    func testPruneUsesHiddenMCPRowsAsSafetyEvidence() async throws {
        let packages = [
            PackageInfo(name: "codegraph", manager: .npmGlobal, current: "1.0.0", status: .upToDate,
                        metadata: ["tree": "A", "npmPath": "/bin/echo"]),
            PackageInfo(name: "codegraph", manager: .npmGlobal, current: "0.9.0", status: .upToDate,
                        metadata: ["tree": "B", "npmPath": "/bin/echo"]),
            PackageInfo(name: "mcp:codegraph", manager: .claudePlugin, status: .unknown,
                        metadata: ["kind": "mcp", "mcpDetail": "codegraph serve --mcp"]),
        ]
        let adapter = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: packages))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()

        vm.hideSource(.claudePlugin)

        XCTAssertFalse(vm.packages.contains { $0.metadata["kind"] == "mcp" })
        let suggestion = try XCTUnwrap(vm.pruneSuggestions.first)
        XCTAssertNotNil(suggestion.blockReason)
    }

    func testPruneOrphansRequiresExplicitConfirmationRequest() async {
        let runner = AppCoreMockCommandRunner()
        runner.stub("brew autoremove --dry-run",
                    CommandOutput(stdout: "==> Would autoremove 1 unneeded formula:\naom\n",
                                  stderr: "", exitCode: 0))
        runner.stub("brew autoremove",
                    CommandOutput(stdout: "Removed aom\n", stderr: "", exitCode: 0))
        let adapter = HomebrewAdapter(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                                      runner: runner)
        let vm = makeVM(adapter: adapter, runner: runner)

        await vm.refreshOrphans()
        await vm.pruneOrphans()
        XCTAssertFalse(runner.calls.contains { $0.arguments == ["autoremove"] })

        vm.requestPruneOrphans()
        XCTAssertEqual(vm.orphanPruneConfirmation, ["aom"])

        await vm.pruneOrphans()

        XCTAssertTrue(runner.calls.contains { $0.arguments == ["autoremove"] })
        XCTAssertNil(vm.orphanPruneConfirmation)
    }

    func testPruneRefusesVersionMismatchedStaleSuggestion() async {
        // 재검증: id는 같아도 버전이 바뀌었으면(외부에서 업그레이드 등) 옛 제안을 실행하지 않는다
        let current = PackageInfo(name: "tool", manager: .npmGlobal, current: "3.0.0",
                                  status: .upToDate, metadata: ["tree": "B", "npmPath": "/bin/echo"])
        let staleSuggestion = PruneAdvisor.suggestions(packages: [
            PackageInfo(name: "tool", manager: .npmGlobal, current: "2.0.0", // 옛 스캔 기준
                        status: .upToDate, metadata: ["tree": "B", "npmPath": "/bin/echo"]),
            PackageInfo(name: "tool", manager: .npmGlobal, current: "9.0.0",
                        status: .upToDate, metadata: ["tree": "A", "npmPath": "/bin/echo"]),
        ])[0]
        let adapter = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: [
            current,
            PackageInfo(name: "tool", manager: .npmGlobal, current: "9.0.0",
                        status: .upToDate, metadata: ["tree": "A", "npmPath": "/bin/echo"]),
        ]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        await vm.prune(staleSuggestion)
        XCTAssertTrue(vm.recentRemovals.isEmpty)
        XCTAssertTrue(vm.logLines.contains { $0.contains("오래되어") })
    }

    func testPruneAbortsWhenLedgerWriteFails() async throws {
        // 재검증: 복구 기록을 못 남기면 삭제 자체를 중단한다 (복구 없는 삭제 금지)
        let fm = FileManager.default
        let lockedDir = fm.temporaryDirectory.appendingPathComponent("tend-locked-\(UUID().uuidString)")
        try fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path) // 쓰기 금지
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
            try? fm.removeItem(at: lockedDir)
        }
        let duplicates = [
            PackageInfo(name: "tool", manager: .npmGlobal, current: "2.0.0", status: .upToDate,
                        metadata: ["tree": "A", "npmPath": "/bin/echo"]),
            PackageInfo(name: "tool", manager: .npmGlobal, current: "1.0.0", status: .upToDate,
                        metadata: ["tree": "B", "npmPath": "/bin/echo"]),
        ]
        let adapter = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: duplicates))
        let vm = AppViewModel(
            scanner: PackageScanner(adapters: [adapter], now: { Date(timeIntervalSince1970: 1_750_000_000) }),
            executor: UpdateExecutor(runner: ProcessCommandRunner()),
            adapters: [adapter], cache: tempCache,
            ledger: RemovalLedger(fileURL: lockedDir.appendingPathComponent("sub/ledger.json")),
            policyStore: tempPolicy,
            historyStore: tempHistory)
        await vm.refresh()
        let suggestion = vm.pruneSuggestions[0]
        await vm.prune(suggestion)
        XCTAssertTrue(vm.recentRemovals.isEmpty)
        XCTAssertTrue(vm.logLines.contains { $0.contains("삭제를 중단") })
        XCTAssertFalse(vm.logLines.contains { $0.contains("✓") }) // 삭제가 실행되지 않았음
    }

    func testPrunePermissionFailureShowsAdminGuidance() async throws {
        let runner = AppCoreMockCommandRunner()
        runner.stub("npm uninstall -g @openai/codex",
                    CommandOutput(stdout: "", stderr: """
                    npm ERR! code EACCES
                    npm ERR! syscall rename
                    npm ERR! path /usr/local/lib/node_modules/@openai/codex
                    npm ERR! dest /usr/local/lib/node_modules/@openai/.codex-vdnmINeK
                    npm ERR! Error: EACCES: permission denied, rename '/usr/local/lib/node_modules/@openai/codex' -> '/usr/local/lib/node_modules/@openai/.codex-vdnmINeK'
                    """, exitCode: 243))
        let duplicates = [
            PackageInfo(name: "@openai/codex", manager: .npmGlobal, current: "0.139.0", status: .upToDate,
                        metadata: ["tree": "nvm", "npmPath": "/bin/echo"]),
            PackageInfo(name: "@openai/codex", manager: .npmGlobal, current: "0.128.0",
                        latest: "0.139.0", status: .outdated,
                        metadata: ["tree": "system", "npmPath": "/usr/local/bin/npm"]),
        ]
        let adapter = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: duplicates))
        let vm = makeVM(adapter: adapter, runner: runner)
        await vm.refresh()

        let suggestion = try XCTUnwrap(vm.pruneSuggestions.first)
        await vm.prune(suggestion)

        let failure = try XCTUnwrap(vm.lastUpdateFailures[suggestion.target.id])
        XCTAssertTrue(failure.contains("관리자 권한"), "권한 안내 메시지여야 함: \(failure)")
        XCTAssertFalse(failure.contains("npm ERR!"), "raw npm 로그를 행 오류로 노출하면 안 됨: \(failure)")
        XCTAssertEqual(vm.lastUpdateFailureTerminalCommands[suggestion.target.id],
                       "sudo env PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin /usr/local/bin/npm uninstall -g '@openai/codex'")
        XCTAssertTrue(vm.recentRemovals.isEmpty)
    }

    func testPruneRefusesStaleSuggestion() async {
        // 제안 생성 후 패키지가 이미 사라진 경우(스테일) — 실행하지 않아야 한다
        let stale = PackageInfo(name: "ghost", manager: .npmGlobal, current: "1.0.0",
                                status: .upToDate, metadata: ["tree": "B", "npmPath": "/bin/echo"])
        let suggestion = PruneAdvisor.suggestions(packages: [
            stale,
            PackageInfo(name: "ghost", manager: .npmGlobal, current: "2.0.0",
                        status: .upToDate, metadata: ["tree": "A", "npmPath": "/bin/echo"]),
        ])[0]
        // VM의 packages에는 ghost가 없음 (다른 스캔 결과)
        let adapter = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: []))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        await vm.prune(suggestion)
        XCTAssertTrue(vm.recentRemovals.isEmpty) // 스테일 제안은 거부
    }

    func testRefreshComputesBadgeAndCounts() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        XCTAssertEqual(vm.packages.count, 3)
        XCTAssertEqual(vm.outdatedCount, 2)
        XCTAssertEqual(vm.highRiskCount, 1)
        XCTAssertEqual(vm.badgeText, "⬆2 ⚠1")
        XCTAssertEqual(vm.safeUpdatable.map(\.name), ["safe-pkg"]) // high 제외
        XCTAssertNotNil(vm.lastScan)
        XCTAssertNotNil(tempCache.load()) // 캐시 저장됨
    }

    func testRefreshPublishesSourceHealth() async throws {
        let brew = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.0",
                        latest: "1.0.1", status: .outdated)
        ]))
        let npm = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: []))
        let vm = makeVM(adapters: [brew, npm])

        await vm.refresh()

        let health = Dictionary(uniqueKeysWithValues: vm.sourceHealth.map { ($0.manager, $0) })
        XCTAssertEqual(try XCTUnwrap(health[.homebrew]).availability, .available)
        XCTAssertEqual(try XCTUnwrap(health[.homebrew]).packageCount, 1)
        XCTAssertEqual(try XCTUnwrap(health[.npmGlobal]).availability, .empty)
        XCTAssertEqual(try XCTUnwrap(health[.npmGlobal]).packageCount, 0)
    }

    func testProminentScanErrorsExcludeSourceHealthFailures() async {
        let adapter = FailingScanAdapter(
            id: .pnpmGlobal,
            error: AdapterError.commandFailed("pnpm list -g: configured global bin directory is not in PATH")
        )
        let vm = makeVM(adapter: adapter)

        await vm.refresh()

        XCTAssertEqual(vm.scanErrors.count, 1)
        XCTAssertEqual(vm.sourceHealth.first?.availability, .failed)
        XCTAssertTrue(vm.prominentScanErrors.isEmpty)
    }

    func testPruneSourceHealthMessagesExplainUnavailableInputs() async {
        let brew = UnavailableAdapter(id: .homebrew)
        let npm = UnavailableAdapter(id: .npmGlobal)
        let vm = makeVM(adapters: [brew, npm])

        await vm.refresh()

        XCTAssertEqual(vm.pruneSourceHealthMessages, [
            "Homebrew 데이터를 읽지 못해 고아 의존성 정리 확인이 제한됩니다: 도구를 찾을 수 없습니다",
            "npm (global) 데이터를 읽지 못해 중복 잔재 제안이 제한됩니다: 도구를 찾을 수 없습니다"
        ])
    }

    func testBadgeCountsDirectOnly() async {
        // 뱃지는 직접 설치 기준 — 의존성 outdated는 숫자에 안 들어간다 (패널 기본 화면과 일치)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "direct-patch", manager: .homebrew, current: "1.0.0", latest: "1.0.1",
                        status: .outdated),
            PackageInfo(name: "dep-patch", manager: .homebrew, current: "1.0.0", latest: "1.0.1",
                        status: .outdated, flags: [.dependency]),
        ]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        XCTAssertEqual(vm.badgeText, "⬆1")
        XCTAssertEqual(vm.directOutdatedCount, 1)
        XCTAssertEqual(vm.dependencyOutdatedCount, 1)
        // 사용자 액션 대상은 직접 설치 패키지만 — 의존성은 부모 업데이트/재스캔에 맡긴다
        XCTAssertEqual(vm.safeUpdatable.map(\.name), ["direct-patch"])
    }

    func testFormulaPatchUpdatesRemainAutomaticBulkSafe() async {
        let brew = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "ripgrep", manager: .homebrew, current: "14.1.0",
                        latest: "14.1.1", status: .outdated),
            PackageInfo(name: "google-chrome", manager: .homebrew, current: "125.0.0",
                        latest: "125.0.1", status: .outdated, flags: [.cask]),
        ]))
        let vm = makeVM(adapter: brew)

        await vm.refresh()

        XCTAssertEqual(vm.safeUpdatable.map(\.name), ["ripgrep"])
        await vm.updateAllSafe()
        XCTAssertEqual(brew.updateRequests, ["ripgrep"])
    }

    func testCaskAndMacAppStoreUpdatesAreNotAutomaticByDefault() async throws {
        let brew = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "google-chrome", manager: .homebrew, current: "125.0.0",
                        latest: "125.0.1", status: .outdated, flags: [.cask]),
        ]))
        let mas = RecordingAdapter(id: .macAppStore, scanResult: AdapterScan(packages: [
            PackageInfo(name: "Xcode", manager: .macAppStore, current: "16.0",
                        latest: "16.1", status: .outdated),
        ]))
        let vm = makeVM(adapters: [brew, mas])

        await vm.refresh()

        XCTAssertTrue(vm.safeUpdatable.isEmpty)
        XCTAssertEqual(try XCTUnwrap(vm.updateSourceSummary(for: .homebrew)).safeUpdatableCount, 0)
        XCTAssertEqual(try XCTUnwrap(vm.updateSourceSummary(for: .macAppStore)).safeUpdatableCount, 0)

        await vm.updateAllSafe()

        XCTAssertEqual(brew.updateRequests, [])
        XCTAssertEqual(mas.updateRequests, [])
    }

    func testRuntimeFormulaeStayBlockedFromAutomaticBulkUpdates() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "node", manager: .homebrew, current: "22.11.0",
                        latest: "22.11.1", status: .outdated, flags: [.runtime]),
        ]))
        let vm = makeVM(adapter: adapter)

        await vm.refresh()

        XCTAssertEqual(vm.packages.first?.risk, .high)
        XCTAssertTrue(vm.safeUpdatable.isEmpty)
        await vm.updateAllSafe()
        XCTAssertEqual(adapter.updateRequests, [])
    }

    func testBadgeIgnoresWhenOnlyDepsOutdated() async {
        // 직접 설치는 다 최신, 의존성만 outdated → 기본 사용자 화면은 최신으로 본다
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "fine", manager: .homebrew, current: "1.0.0", status: .upToDate),
            PackageInfo(name: "dep", manager: .homebrew, current: "1.0.0", latest: "1.0.1",
                        status: .outdated, flags: [.dependency]),
        ]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        XCTAssertEqual(vm.outdatedCount, 0)
        XCTAssertEqual(vm.highRiskCount, 0)
        XCTAssertEqual(vm.dependencyOutdatedCount, 1)
        XCTAssertEqual(vm.badgeText, "✓")
        XCTAssertTrue(vm.safeUpdatable.isEmpty)
    }

    func testBadgeWhenAllUpToDate() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "fine", manager: .homebrew, status: .upToDate)
        ]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        XCTAssertEqual(vm.badgeText, "✓")
    }

    func testIgnorePersistsAcrossViewModelRestarts() async {
        let package = PackageInfo(name: "noisy", manager: .homebrew, current: "1.0.0",
                                  latest: "1.0.1", status: .outdated)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [package]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages[0]

        vm.ignore(target)

        XCTAssertTrue(vm.packages.isEmpty)

        let restarted = makeVM(adapter: adapter, policyStore: tempPolicy)
        await restarted.refresh()
        XCTAssertTrue(restarted.packages.isEmpty)

        restarted.restoreHiddenPackages()
        XCTAssertEqual(restarted.packages.map(\.name), ["noisy"])
    }

    func testSnoozeHidesPackageUntilExpiry() async throws {
        let package = PackageInfo(name: "later", manager: .homebrew, current: "1.0.0",
                                  latest: "1.0.1", status: .outdated)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [package]))
        let store = try XCTUnwrap(tempPolicy)
        var policy = UserPolicy()
        policy.snoozedPackages[package.id] = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(policy)

        let active = makeVM(adapter: adapter, policyStore: store,
                            now: { Date(timeIntervalSince1970: 1_790_000_000) })
        await active.refresh()
        XCTAssertTrue(active.packages.isEmpty)

        let expired = makeVM(adapter: adapter, policyStore: store,
                             now: { Date(timeIntervalSince1970: 1_810_000_000) })
        await expired.refresh()
        XCTAssertEqual(expired.packages.map(\.name), ["later"])
        XCTAssertTrue(expired.userPolicy.snoozedPackages.isEmpty)
    }

    func testHiddenSourceFiltersMainListAndCanBeRestored() async {
        let brew = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "brew-tool", manager: .homebrew, current: "1.0.0",
                        latest: "1.0.1", status: .outdated),
        ]))
        let npm = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: [
            PackageInfo(name: "npm-tool", manager: .npmGlobal, current: "1.0.0",
                        latest: "1.0.1", status: .outdated),
        ]))
        let vm = makeVM(adapters: [brew, npm])
        await vm.refresh()

        vm.hideSource(.homebrew)

        XCTAssertEqual(vm.packages.map(\.name), ["npm-tool"])
        XCTAssertTrue(vm.userPolicy.hiddenManagers.contains(.homebrew))
        XCTAssertNotNil(vm.sourceHealth(for: .homebrew))

        vm.restoreHiddenSource(.homebrew)

        XCTAssertEqual(vm.packages.map(\.name), ["brew-tool", "npm-tool"])
        XCTAssertFalse(vm.userPolicy.hiddenManagers.contains(.homebrew))
    }

    func testUpdateAppendsLogAndRescans() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first { $0.name == "safe-pkg" }!
        await vm.update(target)
        XCTAssertTrue(vm.logLines.contains { $0.contains("✓") && $0.contains("safe-pkg") })
    }

    func testSuccessfulUpdatePersistsHistoryEntry() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_123)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        let vm = makeVM(adapter: adapter, now: { timestamp })
        await vm.refresh()
        let target = try XCTUnwrap(vm.packages.first { $0.name == "safe-pkg" })

        await vm.update(target)

        let entry = try XCTUnwrap(vm.updateHistory.first)
        XCTAssertEqual(entry.timestamp, timestamp)
        XCTAssertEqual(entry.packageID, target.id)
        XCTAssertEqual(entry.manager, .homebrew)
        XCTAssertEqual(entry.name, "safe-pkg")
        XCTAssertEqual(entry.previousVersion, "1.0.0")
        XCTAssertEqual(entry.targetVersion, "1.0.1")
        XCTAssertEqual(entry.command, "/bin/echo updated safe-pkg")
        XCTAssertEqual(entry.exitCode, 0)
        XCTAssertTrue(entry.stdout.contains("updated safe-pkg"))
        XCTAssertTrue(entry.stderr.isEmpty)

        XCTAssertEqual(tempHistory.loadLatest().first, entry)
    }

    func testFailedUpdateIsLoggedAsFailure() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        adapter.failUpdates = true
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first { $0.name == "safe-pkg" }!
        await vm.update(target)
        XCTAssertTrue(vm.logLines.contains { $0.contains("✗") && $0.contains("safe-pkg") })
        XCTAssertFalse(vm.logLines.contains { $0.contains("✓") && $0.contains("safe-pkg") })
    }

    func testFailedUpdateHistorySurvivesRestart() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_456)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        adapter.failUpdates = true
        let vm = makeVM(adapter: adapter, now: { timestamp })
        await vm.refresh()
        let target = try XCTUnwrap(vm.packages.first { $0.name == "safe-pkg" })

        await vm.update(target)

        let failed = try XCTUnwrap(vm.updateHistory.first)
        XCTAssertEqual(failed.timestamp, timestamp)
        XCTAssertEqual(failed.packageID, target.id)
        XCTAssertEqual(failed.manager, .homebrew)
        XCTAssertEqual(failed.name, "safe-pkg")
        XCTAssertEqual(failed.previousVersion, "1.0.0")
        XCTAssertEqual(failed.targetVersion, "1.0.1")
        XCTAssertEqual(failed.command, "/usr/bin/false")
        XCTAssertEqual(failed.exitCode, 1)

        let restarted = makeVM(adapter: adapter, historyStore: tempHistory)
        XCTAssertEqual(restarted.updateHistory.first, failed)
    }

    func testFailedUpdateStoresPackageSpecificFailureMessage() async {
        let adapter = RecordingAdapter(id: .claudePlugin, scanResult: AdapterScan(packages: [
            PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                        current: "5.0.7", status: .unknown, metadata: ["canUpdate": "true"])
        ]))
        adapter.failUpdates = true
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first!

        await vm.updateConfirmed(target, confirmation: UpdateConfirmationSnapshot(target))

        XCTAssertEqual(vm.lastUpdateFailures[target.id], "exit 1")
    }

    func testSuccessfulUpdateClearsPreviousFailureMessage() async {
        let package = PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                                  current: "5.0.7", status: .unknown, metadata: ["canUpdate": "true"])
        let adapter = RecordingAdapter(id: .claudePlugin, scanResult: AdapterScan(packages: [package]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first!

        adapter.failUpdates = true
        await vm.updateConfirmed(target, confirmation: UpdateConfirmationSnapshot(target))
        XCTAssertNotNil(vm.lastUpdateFailures[target.id])

        adapter.failUpdates = false
        await vm.updateConfirmed(target, confirmation: UpdateConfirmationSnapshot(target))

        XCTAssertNil(vm.lastUpdateFailures[target.id])
    }

    func testRefreshClearsStaleFailureWhenPackageChangedAfterFailure() async {
        let failedPackage = PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                                        current: "5.0.7", status: .unknown,
                                        metadata: ["canUpdate": "true",
                                                   "lastUpdated": "2026-06-10T01:00:00Z"])
        let adapter = RecordingAdapter(id: .claudePlugin, scanResult: AdapterScan(packages: [failedPackage]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first!

        adapter.failUpdates = true
        await vm.updateConfirmed(target, confirmation: UpdateConfirmationSnapshot(target))
        XCTAssertNotNil(vm.lastUpdateFailures[target.id])

        let updatedPackage = PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                                         current: "5.1.0", status: .unknown,
                                         metadata: ["canUpdate": "true",
                                                    "lastUpdated": "2026-06-10T02:00:00Z"])
        adapter.failUpdates = false
        adapter.scanResult = AdapterScan(packages: [updatedPackage])
        await vm.refresh()

        XCTAssertNil(vm.lastUpdateFailures[target.id])
    }

    func testSuccessfulUpdateClearsRecentlyUpdatedWhenRescanShowsUpToDate() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first { $0.name == "safe-pkg" }!
        adapter.scanResult = AdapterScan(packages: [
            PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.1",
                        status: .upToDate)
        ])
        await vm.update(target)
        XCTAssertFalse(vm.recentlyUpdated.contains(target.id))
    }

    func testSuccessfulUpdateKeepsRecentlyUpdatedWhenRescanCannotDetermineFreshness() async {
        // unknown 상태(Claude 플러그인)는 rescan으로도 "최신" 판정이 불가 —
        // "방금 성공" 마커가 유일한 피드백 수단이다
        let plugin = PackageInfo(name: "opaque@marketplace", manager: .claudePlugin,
                                 current: "unknown", status: .unknown,
                                 metadata: ["canUpdate": "true"])
        let adapter = RecordingAdapter(id: .claudePlugin, scanResult: AdapterScan(packages: [plugin]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first { $0.name == "opaque@marketplace" }!
        adapter.scanResult = AdapterScan(packages: [plugin])

        await vm.updateConfirmed(target, confirmation: UpdateConfirmationSnapshot(target))

        XCTAssertTrue(vm.recentlyUpdated.contains(target.id))
    }

    func testRefreshClearsRecentlyUpdatedWhenPackageIsOutdatedAgain() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first { $0.name == "safe-pkg" }!
        adapter.scanResult = AdapterScan(packages: [
            PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.1",
                        status: .upToDate)
        ])
        await vm.update(target)
        XCTAssertFalse(vm.recentlyUpdated.contains(target.id))

        adapter.scanResult = AdapterScan(packages: [
            PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.1",
                        latest: "1.0.2", status: .outdated)
        ])
        await vm.refresh()
        XCTAssertFalse(vm.recentlyUpdated.contains(target.id))
    }

    func testUpdateKeepsUpdatingFlagWhileRescanIsInFlight() async {
        let initial = PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.0",
                                  latest: "1.0.1", status: .outdated)
        let adapter = BlockingRescanAdapter(scanResult: AdapterScan(packages: [initial]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first!

        let updateTask = Task { await vm.update(target) }
        await adapter.rescanStarted.wait()
        XCTAssertTrue(vm.isUpdating)

        adapter.setScanResult(AdapterScan(packages: [
            PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.1",
                        status: .upToDate)
        ]))
        adapter.allowRescan.signal()
        await updateTask.value
        XCTAssertFalse(vm.isUpdating)
    }

    func testSingleUpdatePublishesProgressUntilRescanCompletes() async {
        let initial = PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.0",
                                  latest: "1.0.1", status: .outdated)
        let adapter = BlockingRescanAdapter(scanResult: AdapterScan(packages: [initial]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first!

        let updateTask = Task { await vm.update(target) }
        await adapter.rescanStarted.wait()

        XCTAssertEqual(vm.updateProgress?.currentPackageName, "safe-pkg")
        XCTAssertEqual(vm.updateProgress?.completed, 1)
        XCTAssertEqual(vm.updateProgress?.total, 1)
        XCTAssertEqual(vm.updateProgress?.mode, .single)

        adapter.setScanResult(AdapterScan(packages: [
            PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.1",
                        status: .upToDate)
        ]))
        adapter.allowRescan.signal()
        await updateTask.value
        XCTAssertNil(vm.updateProgress)
    }

    func testUpdateAllSafeAdvancesProgressBetweenPackages() async {
        let packages = [
            PackageInfo(name: "first-safe", manager: .homebrew, current: "1.0.0",
                        latest: "1.0.1", status: .outdated),
            PackageInfo(name: "second-safe", manager: .homebrew, current: "2.0.0",
                        latest: "2.0.1", status: .outdated),
        ]
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: packages))
        let runner = StepwiseCommandRunner()
        let vm = makeVM(adapter: adapter, runner: runner)
        await vm.refresh()

        let updateTask = Task { await vm.updateAllSafe() }
        await runner.started.wait(for: 1)
        XCTAssertEqual(vm.updateProgress?.currentPackageName, "first-safe")
        XCTAssertEqual(vm.updateProgress?.completed, 0)
        XCTAssertEqual(vm.updateProgress?.total, 2)
        XCTAssertEqual(vm.updateProgress?.mode, .bulk)

        runner.allowNext()
        await runner.started.wait(for: 2)
        XCTAssertEqual(vm.updateProgress?.currentPackageName, "second-safe")
        XCTAssertEqual(vm.updateProgress?.completed, 1)
        XCTAssertEqual(vm.updateProgress?.total, 2)
        XCTAssertEqual(vm.updateProgress?.mode, .bulk)

        runner.allowNext()
        await updateTask.value
        XCTAssertNil(vm.updateProgress)
    }

    func testUpdateProgressPresentationUsesSpinnerOnlyIndicator() {
        let progress = UpdateProgress(currentPackageID: "homebrew:pkg:second-safe",
                                      currentPackageName: "second-safe",
                                      completed: 1, total: 2, mode: .bulk)

        XCTAssertEqual(progress.presentation.title, "second-safe 업데이트 중")
        XCTAssertEqual(progress.presentation.countText, "2/2")
        XCTAssertFalse(progress.presentation.showsLinearProgress)
    }

    func testUpdateProgressPresentationLocalizesEnglishTitle() {
        let progress = UpdateProgress(currentPackageID: "homebrew:pkg:second-safe",
                                      currentPackageName: "second-safe",
                                      completed: 1, total: 2, mode: .bulk)

        let presentation = progress.presentation(language: .english)

        XCTAssertEqual(presentation.title, "second-safe updating")
        XCTAssertEqual(presentation.countText, "2/2")
        XCTAssertFalse(presentation.showsLinearProgress)
    }

    func testPanelSizePresetStepsWithinBounds() {
        XCTAssertEqual(PanelSizePreset.regular.smaller, .compact)
        XCTAssertEqual(PanelSizePreset.regular.larger, .large)
        XCTAssertEqual(PanelSizePreset.compact.smaller, .compact)
        XCTAssertEqual(PanelSizePreset.large.larger, .large)
    }

    func testPanelSizePresetRestoresInvalidRawValueToRegular() {
        XCTAssertEqual(PanelSizePreset(rawValueOrDefault: "giant"), .regular)
        XCTAssertEqual(PanelSizePreset(rawValueOrDefault: PanelSizePreset.large.rawValue), .large)
    }

    func testPanelSizePresetDefaultIsRegular() {
        XCTAssertEqual(PanelSizePreset.defaultPreset, .regular)
    }

    func testPanelSizePresetDefaultMigrationNormalizesStoredSelectionsToRegular() {
        XCTAssertEqual(PanelSizePreset.defaultedRawValueAfterDefaultMigration(PanelSizePreset.compact.rawValue),
                       PanelSizePreset.regular.rawValue)
        XCTAssertEqual(PanelSizePreset.defaultedRawValueAfterDefaultMigration(PanelSizePreset.large.rawValue),
                       PanelSizePreset.regular.rawValue)
        XCTAssertEqual(PanelSizePreset.defaultedRawValueAfterDefaultMigration(PanelSizePreset.regular.rawValue),
                       PanelSizePreset.regular.rawValue)
    }

    func testPackageVisibilityFilterUsesConfirmationPolicy() {
        let safeFormula = PackageInfo(name: "safe", manager: .homebrew,
                                      current: "1.0.0", latest: "1.0.1",
                                      status: .outdated, risk: .low)
        let cask = PackageInfo(name: "slack", manager: .homebrew,
                               current: "1.0.0", latest: "1.0.1",
                               status: .outdated, risk: .low, flags: [.cask])
        let masApp = PackageInfo(name: "xcode", manager: .macAppStore,
                                 current: "1.0.0", latest: "1.0.1",
                                 status: .outdated, risk: .low)
        let highRisk = PackageInfo(name: "node", manager: .homebrew,
                                   current: "20.0.0", latest: "22.0.0",
                                   status: .outdated, risk: .high)

        XCTAssertTrue(PackageVisibilityFilter.automatic.includes(safeFormula, showUpToDate: false))
        XCTAssertFalse(PackageVisibilityFilter.requiresConfirmation.includes(safeFormula,
                                                                             showUpToDate: false))
        XCTAssertTrue(PackageVisibilityFilter.requiresConfirmation.includes(cask, showUpToDate: false))
        XCTAssertTrue(PackageVisibilityFilter.requiresConfirmation.includes(masApp, showUpToDate: false))
        XCTAssertTrue(PackageVisibilityFilter.requiresConfirmation.includes(highRisk, showUpToDate: false))
    }

    func testPackageVisibilityFilterLocalizesLabelsAndTips() {
        XCTAssertEqual(PackageVisibilityFilter.all.displayName(language: .english), "All")
        XCTAssertEqual(PackageVisibilityFilter.automatic.displayName(language: .english), "Auto")
        XCTAssertEqual(PackageVisibilityFilter.requiresConfirmation.displayName(language: .english), "⚠ Confirm")
        XCTAssertEqual(PackageVisibilityFilter.all.tip(language: .english), "Show all items")
        XCTAssertTrue(PackageVisibilityFilter.automatic.tip(language: .english).contains("formula/CLI"))
    }

    func testPackageEmptyStatePresentationMentionsHiddenSources() {
        let presentation = PackageEmptyStatePresentation.make(
            isScanning: false,
            visibilityFilter: .all,
            showUpToDate: false,
            hiddenPackageCount: 0,
            hiddenSourceCount: 2)

        XCTAssertEqual(presentation.title, "숨긴 소스 있음")
        XCTAssertTrue(presentation.detail.contains("숨긴 업데이트 소스 2개"))
        XCTAssertNil(presentation.restoreHiddenPackagesTitle)
        XCTAssertEqual(presentation.restoreHiddenSourcesTitle, "숨긴 소스 복원")
    }

    func testPackageEmptyStatePresentationPrioritizesActiveFilterOverHiddenSources() {
        let presentation = PackageEmptyStatePresentation.make(
            isScanning: false,
            visibilityFilter: .automatic,
            showUpToDate: false,
            hiddenPackageCount: 0,
            hiddenSourceCount: 2)

        XCTAssertEqual(presentation.title, "자동 항목 없음")
        XCTAssertTrue(presentation.detail.contains("현재 필터"))
        XCTAssertNil(presentation.restoreHiddenPackagesTitle)
        XCTAssertNil(presentation.restoreHiddenSourcesTitle)
    }

    func testPackageEmptyStatePresentationLocalizesEnglish() {
        let presentation = PackageEmptyStatePresentation.make(
            isScanning: false,
            visibilityFilter: .automatic,
            showUpToDate: false,
            hiddenPackageCount: 0,
            hiddenSourceCount: 2,
            language: .english)

        XCTAssertEqual(presentation.title, "No Auto items")
        XCTAssertTrue(presentation.detail.contains("current filter"))
        XCTAssertNil(presentation.restoreHiddenPackagesTitle)
        XCTAssertNil(presentation.restoreHiddenSourcesTitle)
    }

    func testRestoreHiddenSourcesClearsAllHiddenManagers() async {
        let vm = makeVM(adapter: RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [])))
        vm.hideSource(.homebrew)
        vm.hideSource(.claudePlugin)

        vm.restoreHiddenSources()

        XCTAssertEqual(vm.hiddenSourceCount, 0)
        XCTAssertTrue(vm.userPolicy.hiddenManagers.isEmpty)
    }

    func testFailedUpdateIsNotMarkedRecentlyUpdated() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        adapter.failUpdates = true
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first { $0.name == "safe-pkg" }!
        await vm.update(target)
        XCTAssertFalse(vm.recentlyUpdated.contains(target.id))
    }

    func testSudoFailureGetsFriendlyGuidance() async {
        // root 소유 앱(예: MAS의 RunCat)은 mas가 내부에서 sudo를 부르는데, GUI 앱은 TTY가
        // 없어 비밀번호를 받을 수 없다 — raw sudo 에러 대신 행동 가능한 안내로 변환되어야 한다
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        adapter.failWithSudoStderr = true
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first { $0.name == "safe-pkg" }!
        await vm.update(target)
        let failure = vm.lastUpdateFailures[target.id]
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.contains("관리자 권한") == true, "안내 메시지여야 함: \(failure ?? "nil")")
        XCTAssertFalse(failure?.contains("a terminal is required") == true) // raw 에러 노출 금지
    }

    func testMacAppStoreSudoFailureGuidesToAppStoreEvenWithFullPathCommand() async {
        let package = PackageInfo(name: "RunCat", manager: .macAppStore, current: "12.0.0",
                                  latest: "12.1.0", status: .outdated, risk: .low)
        let adapter = RecordingAdapter(id: .macAppStore, scanResult: AdapterScan(packages: [package]))
        adapter.failWithSudoStderr = true
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages[0]

        await vm.updateConfirmed(target, confirmation: UpdateConfirmationSnapshot(target))

        let failure = vm.lastUpdateFailures[target.id]
        XCTAssertTrue(failure?.contains("App Store에서 직접 업데이트") == true,
                      "MAS 전용 안내여야 함: \(failure ?? "nil")")
    }

    func testPluginNotFoundFailureGetsDiagnosticGuidance() async {
        // "not found"의 실측 원인: 구버전 CLI(nvm 트리의 낡은 npm 잔재)가 레지스트리를
        // 인식 못 하거나 마켓플레이스에서 제거된 경우 — raw 에러 대신 진단 안내로 변환
        let adapter = RecordingAdapter(id: .claudePlugin, scanResult: AdapterScan(packages: [
            PackageInfo(name: "ui-helper@example-marketplace", manager: .claudePlugin,
                        status: .unknown),
        ]))
        adapter.failWithPluginNotFound = true
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages[0]
        await vm.updateConfirmed(target, confirmation: UpdateConfirmationSnapshot(target))
        let failure = vm.lastUpdateFailures[target.id]
        XCTAssertTrue(failure?.contains("구버전") == true, "진단 안내여야 함: \(failure ?? "nil")")
        XCTAssertFalse(failure?.contains("✘ Failed") == true) // raw 에러 노출 금지
    }

    func testUpdateAllSafeSkipsHighRisk() async {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        await vm.updateAllSafe()
        XCTAssertTrue(adapter.updateRequests.contains("safe-pkg"))
        XCTAssertFalse(adapter.updateRequests.contains("risky-pkg")) // high는 일괄에서 제외
        XCTAssertFalse(adapter.updateRequests.contains("fine-pkg"))
    }

    func testUpdateAllSafeForManagerOnlyUpdatesThatSource() async {
        let brew = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "brew-safe", manager: .homebrew, current: "1.0.0",
                        latest: "1.0.1", status: .outdated),
        ]))
        let npm = RecordingAdapter(id: .npmGlobal, scanResult: AdapterScan(packages: [
            PackageInfo(name: "npm-safe", manager: .npmGlobal, current: "1.0.0",
                        latest: "1.0.1", status: .outdated),
        ]))
        let vm = makeVM(adapters: [brew, npm])
        await vm.refresh()

        await vm.updateAllSafe(for: .npmGlobal)

        XCTAssertEqual(brew.updateRequests, [])
        XCTAssertEqual(npm.updateRequests, ["npm-safe"])
    }

    func testSafeUpdateCandidatesExcludeHighRiskAndExposeCommands() async throws {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: makePackages()))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()

        let candidates = vm.updateCandidates(for: vm.safeUpdatable)

        XCTAssertEqual(candidates.map(\.package.name), ["safe-pkg"])
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertTrue(candidate.canRun)
        XCTAssertEqual(candidate.command, "/bin/echo updated safe-pkg")
        XCTAssertNil(candidate.reason)
    }

    func testUpdateCandidatesShowUnsupportedCommandsAsDisabled() async throws {
        let package = PackageInfo(name: "manual-only", manager: .uvTool, current: "1.0.0",
                                  latest: "1.0.1", status: .outdated, risk: .low)
        let adapter = UnsupportedUpdateAdapter(id: .uvTool, scanResult: AdapterScan(packages: [package]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()

        let candidate = try XCTUnwrap(vm.updateCandidates(for: vm.packages).first)

        XCTAssertFalse(candidate.canRun)
        XCTAssertNil(candidate.command)
        XCTAssertEqual(candidate.reason, "자동 업데이트를 지원하지 않습니다")
    }

    func testCurrentUpdateCommandsDropStalePreviewCandidates() async throws {
        let initial = PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.0",
                                  latest: "1.0.1", status: .outdated, risk: .low)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [initial]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let candidates = vm.updateCandidates(for: vm.safeUpdatable)
        XCTAssertEqual(candidates.compactMap(\.command), ["/bin/echo updated safe-pkg"])

        adapter.scanResult = AdapterScan(packages: [
            PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.0",
                        latest: "2.0.0", status: .outdated, risk: .high),
        ])
        await vm.refresh()

        let commands = vm.currentUpdateCommands(for: candidates, selectedIDs: Set(candidates.map(\.id)))

        XCTAssertEqual(commands, [])
    }

    func testCurrentUpdateCommandsDropIgnoredPreviewCandidates() async throws {
        let initial = PackageInfo(name: "safe-pkg", manager: .homebrew, current: "1.0.0",
                                  latest: "1.0.1", status: .outdated, risk: .low)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [initial]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let candidates = vm.updateCandidates(for: vm.safeUpdatable)
        let target = try XCTUnwrap(vm.packages.first)

        vm.ignore(target)
        let commands = vm.currentUpdateCommands(for: candidates, selectedIDs: Set(candidates.map(\.id)))

        XCTAssertEqual(commands, [])
    }

    func testUpdateAllSafeSelectedIDsOnlyRunsSelectedPackages() async {
        let packages = [
            PackageInfo(name: "first-safe", manager: .homebrew, current: "1.0.0",
                        latest: "1.0.1", status: .outdated),
            PackageInfo(name: "second-safe", manager: .homebrew, current: "2.0.0",
                        latest: "2.0.1", status: .outdated),
        ]
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: packages))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let selected = Set(vm.packages.filter { $0.name == "second-safe" }.map(\.id))

        await vm.updateAllSafe(selectedIDs: selected)

        XCTAssertEqual(adapter.updateRequests, ["second-safe"])
    }

    func testUpdateSourceSummaryCountsDirectPackagesByStatus() async throws {
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [
            PackageInfo(name: "safe", manager: .homebrew, current: "1.0.0",
                        latest: "1.0.1", status: .outdated),
            PackageInfo(name: "risky", manager: .homebrew, current: "1.0.0",
                        latest: "2.0.0", status: .outdated),
            PackageInfo(name: "unknown", manager: .homebrew, current: "1.0.0",
                        status: .unknown),
            PackageInfo(name: "fine", manager: .homebrew, current: "1.0.0",
                        status: .upToDate),
            PackageInfo(name: "dep", manager: .homebrew, current: "1.0.0",
                        latest: "1.0.1", status: .outdated, flags: [.dependency]),
        ]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()

        let summary = try XCTUnwrap(vm.updateSourceSummary(for: .homebrew))

        XCTAssertEqual(summary.manager, .homebrew)
        XCTAssertEqual(summary.totalCount, 4)
        XCTAssertEqual(summary.outdatedCount, 2)
        XCTAssertEqual(summary.unknownCount, 1)
        XCTAssertEqual(summary.highRiskCount, 1)
        XCTAssertEqual(summary.safeUpdatableCount, 1)
    }

    func testUpdateSourceSummaryExcludesInventoryOnlyFromUnknownCount() async throws {
        let adapter = RecordingAdapter(id: .claudePlugin, scanResult: AdapterScan(packages: [
            PackageInfo(name: "sample-plugin@example-marketplace", manager: .claudePlugin,
                        current: "5.1.0", status: .unknown,
                        statusReason: .updateCommandCheck),
            PackageInfo(name: "mcp:jira", manager: .claudePlugin, status: .unknown,
                        statusReason: .inventoryOnly, metadata: ["kind": "mcp"]),
        ]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()

        let summary = try XCTUnwrap(vm.updateSourceSummary(for: .claudePlugin))

        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.unknownCount, 1)
    }

    func testHighRiskUpdateRequestRequiresConfirmationState() {
        var confirmation = UpdateConfirmationState()
        let target = PackageInfo(name: "k6", manager: .homebrew, current: "1.7.1",
                                 latest: "2.0.0", status: .outdated, risk: .high)

        let decision = confirmation.request(target)

        XCTAssertEqual(decision, .requiresConfirmation(packageID: target.id))
        XCTAssertTrue(confirmation.isConfirming(target))
    }

    func testUnknownUpdateRequestRequiresConfirmationState() {
        var confirmation = UpdateConfirmationState()
        let target = PackageInfo(name: "sample-plugin@example-marketplace",
                                 manager: .claudePlugin,
                                 current: "5.1.0",
                                 status: .unknown,
                                 statusReason: .updateCommandCheck)

        let decision = confirmation.request(target)

        XCTAssertEqual(decision, .requiresConfirmation(packageID: target.id))
        XCTAssertTrue(confirmation.isConfirming(target))
    }

    func testUnavailableUpdateRequestIsBlocked() {
        var confirmation = UpdateConfirmationState()
        let target = PackageInfo(name: "fzf", manager: .homebrew,
                                 current: "0.73.1", status: .upToDate)

        let decision = confirmation.request(target)

        XCTAssertEqual(decision, .blocked(packageID: target.id,
                                          reason: "업데이트 대상이 아닙니다"))
        XCTAssertFalse(confirmation.isConfirming(target))
    }

    func testConfirmationInvalidatesWhenPackageStateChanges() {
        var confirmation = UpdateConfirmationState()
        let target = PackageInfo(name: "k6", manager: .homebrew, current: "1.7.1",
                                 latest: "2.0.0", status: .outdated, risk: .high)
        let changed = PackageInfo(name: "k6", manager: .homebrew, current: "1.7.1",
                                  latest: "3.0.0", status: .outdated, risk: .high)

        _ = confirmation.request(target)

        XCTAssertFalse(confirmation.isConfirming(changed))
    }

    func testGuiAppUpdateRequestsRequireConfirmationState() {
        var confirmation = UpdateConfirmationState()
        let cask = PackageInfo(name: "google-chrome", manager: .homebrew, current: "125.0.0",
                               latest: "125.0.1", status: .outdated, risk: .medium, flags: [.cask])
        let mas = PackageInfo(name: "Xcode", manager: .macAppStore, current: "16.0",
                              latest: "16.1", status: .outdated, risk: .low)

        XCTAssertEqual(confirmation.request(cask), .requiresConfirmation(packageID: cask.id))
        XCTAssertTrue(confirmation.isConfirming(cask))

        XCTAssertEqual(confirmation.request(mas), .requiresConfirmation(packageID: mas.id))
        XCTAssertTrue(confirmation.isConfirming(mas))
    }

    func testSafeUpdateRequestRunsImmediatelyAndClearsConfirmation() {
        let risky = PackageInfo(name: "k6", manager: .homebrew, current: "1.7.1",
                                latest: "2.0.0", status: .outdated, risk: .high)
        let safe = PackageInfo(name: "fzf", manager: .homebrew, current: "0.72.0",
                               latest: "0.73.1", status: .outdated, risk: .low)
        var confirmation = UpdateConfirmationState()
        _ = confirmation.request(risky)

        let decision = confirmation.request(safe)

        XCTAssertEqual(decision, .runImmediately)
        XCTAssertFalse(confirmation.isConfirming(risky))
    }

    func testUpdateConfirmationStateDoesNotExposeIgnoredPackageIDInitializer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AppCore/UpdateConfirmationState.swift"),
                                encoding: .utf8)

        XCTAssertFalse(sourceWithoutLineComments(source).contains("init(packageID:"),
                       "UpdateConfirmationState must not expose an initializer that accepts and ignores packageID")
    }

    private func sourceWithoutLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(stripLineComment)
            .joined(separator: "\n")
    }

    private func stripLineComment(_ line: Substring) -> String {
        var output = ""
        var index = line.startIndex
        var isInsideString = false
        var isEscaping = false

        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)

            if isInsideString {
                output.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
                output.append(character)
            } else if character == "/", next < line.endIndex, line[next] == "/" {
                break
            } else {
                output.append(character)
            }
            index = next
        }

        return output
    }

    func testAppViewModelRefusesUnavailableDirectUpdate() async {
        let package = PackageInfo(name: "already-current", manager: .homebrew,
                                  current: "1.0.0", status: .upToDate)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [package]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first!

        await vm.update(target)

        XCTAssertEqual(adapter.updateRequests, [])
        XCTAssertTrue(vm.logLines.contains { $0.contains("업데이트 대상이 아닙니다") })
    }

    func testAppViewModelRequiresConfirmationForRiskyDirectUpdate() async {
        let package = PackageInfo(name: "k6", manager: .homebrew, current: "1.7.1",
                                  latest: "2.0.0", status: .outdated, risk: .high)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [package]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first!

        await vm.update(target)

        XCTAssertEqual(adapter.updateRequests, [])
        XCTAssertTrue(vm.logLines.contains { $0.contains("실행 전 확인") })
    }

    func testAppViewModelRunsConfirmedRiskyUpdate() async {
        let package = PackageInfo(name: "k6", manager: .homebrew, current: "1.7.1",
                                  latest: "2.0.0", status: .outdated, risk: .high)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [package]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let target = vm.packages.first!

        await vm.updateConfirmed(target, confirmation: UpdateConfirmationSnapshot(target))

        XCTAssertEqual(adapter.updateRequests, ["k6"])
    }

    func testAppViewModelRefusesStaleConfirmation() async {
        let package = PackageInfo(name: "k6", manager: .homebrew, current: "1.7.1",
                                  latest: "2.0.0", status: .outdated, risk: .high)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: [package]))
        let vm = makeVM(adapter: adapter)
        await vm.refresh()
        let oldConfirmation = UpdateConfirmationSnapshot(vm.packages.first!)

        adapter.scanResult = AdapterScan(packages: [
            PackageInfo(name: "k6", manager: .homebrew, current: "1.7.1",
                        latest: "3.0.0", status: .outdated, risk: .high)
        ])
        await vm.refresh()
        let changed = vm.packages.first!

        await vm.updateConfirmed(changed, confirmation: oldConfirmation)

        XCTAssertEqual(adapter.updateRequests, [])
        XCTAssertTrue(vm.logLines.contains { $0.contains("다시 확인") })
    }

    func testInitLoadsCachedState() async throws {
        let cached = ScanResult(packages: makePackages(), advisories: [], errors: [],
                                sourceHealth: [SourceHealth(manager: .homebrew,
                                                            availability: .available,
                                                            packageCount: 3,
                                                            message: nil)],
                                timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        try tempCache.save(cached)
        let adapter = RecordingAdapter(id: .homebrew, scanResult: AdapterScan(packages: []))
        let vm = makeVM(adapter: adapter)
        // refresh 전에도 캐시가 바로 보여야 한다
        XCTAssertEqual(vm.packages.count, 3)
        XCTAssertEqual(vm.sourceHealth, cached.sourceHealth)
        XCTAssertNotNil(vm.lastScan)
    }
}
