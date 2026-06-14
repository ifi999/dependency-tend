import Combine
import Engine
import Foundation

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public private(set) var packages: [PackageInfo] = []
    @Published public private(set) var advisories: [ManagerAdvisory] = []
    @Published public private(set) var scanErrors: [ScanError] = []
    @Published public private(set) var sourceHealth: [SourceHealth] = []
    @Published public private(set) var lastScan: Date?
    @Published public private(set) var isScanning = false
    @Published public private(set) var isUpdating = false
    @Published public private(set) var updateProgress: UpdateProgress?
    @Published public private(set) var logLines: [String] = []
    @Published public private(set) var updateHistory: [UpdateHistoryEntry] = []
    @Published public private(set) var toolDiagnostics: [ToolDiagnostic] = []
    @Published public private(set) var language: AppLanguage
    @Published public private(set) var appUpdateState: AppUpdateState = .idle
    /// 이번 실행에서 업데이트에 성공한 패키지 id들.
    /// unknown 상태(Claude 플러그인)는 rescan으로도 "최신" 판정이 불가하므로
    /// 이 마커가 "방금 업데이트됨 — 재시작 필요"를 보여주는 유일한 수단이다.
    @Published public private(set) var recentlyUpdated: Set<String> = []
    @Published public private(set) var lastUpdateFailures: [String: String] = [:]
    @Published public private(set) var lastUpdateFailureTerminalCommands: [String: String] = [:]
    @Published public private(set) var userPolicy = UserPolicy()

    private let scanner: PackageScanner
    private let executor: UpdateExecutor
    private let adapters: [any PackageManagerAdapter]
    private let cache: ScanCache
    private let ledger: RemovalLedger
    private let policyStore: UserPolicyStore
    private let historyStore: UpdateHistoryStore
    private let languageStore: LanguageStore
    private let appUpdateChecker: (any AppUpdateChecking)?
    private let appUpdatePreparer: (any AppUpdatePreparing)?
    private let appUpdateInstaller: (any AppUpdateInstalling)?
    private let now: @Sendable () -> Date
    private let defaultNpmTreeLabel: String?
    private var allPackages: [PackageInfo] = []
    private var autoRefreshTask: Task<Void, Never>?
    private var lastUpdateFailureContexts: [String: UpdateFailureContext] = [:]

    /// 정리(가지치기) 상태 — 복구 장부와 brew 고아 의존성 (정리 스펙)
    @Published public private(set) var recentRemovals: [RemovalRecord] = []
    @Published public private(set) var orphanNames: [String] = []
    @Published public private(set) var orphanPruneConfirmation: [String]?

    public init(scanner: PackageScanner, executor: UpdateExecutor,
                adapters: [any PackageManagerAdapter], cache: ScanCache,
                ledger: RemovalLedger = RemovalLedger(),
                policyStore: UserPolicyStore = UserPolicyStore(),
                historyStore: UpdateHistoryStore = UpdateHistoryStore(),
                languageStore: LanguageStore = LanguageStore(),
                appUpdateChecker: (any AppUpdateChecking)? = nil,
                appUpdatePreparer: (any AppUpdatePreparing)? = nil,
                appUpdateInstaller: (any AppUpdateInstalling)? = nil,
                toolDiagnostics: [ToolDiagnostic] = [],
                now: @escaping @Sendable () -> Date = { Date() },
                defaultNpmTreeLabel: String? = nil) {
        self.scanner = scanner
        self.executor = executor
        self.adapters = adapters
        self.cache = cache
        self.ledger = ledger
        self.policyStore = policyStore
        self.historyStore = historyStore
        self.languageStore = languageStore
        self.appUpdateChecker = appUpdateChecker
        self.appUpdatePreparer = appUpdatePreparer
        self.appUpdateInstaller = appUpdateInstaller
        self.toolDiagnostics = toolDiagnostics
        self.now = now
        self.defaultNpmTreeLabel = defaultNpmTreeLabel
        self.recentRemovals = ledger.load()
        self.userPolicy = policyStore.load()
        self.updateHistory = historyStore.loadLatest()
        self.language = languageStore.load()
        // 캐시된 결과를 즉시 표시 (스펙 §5: 실행 → 캐시 즉시 표시 → 백그라운드 스캔)
        if let cached = cache.load() {
            allPackages = cached.packages
            applyPolicyToVisiblePackages()
            advisories = cached.advisories
            scanErrors = cached.errors
            sourceHealth = cached.sourceHealth
            lastScan = cached.timestamp
        }
    }

    // MARK: - 정리 (가지치기)

    public var pruneSuggestions: [PruneSuggestion] {
        let visiblePackageIDs = Set(packages.map(\.id))
        return PruneAdvisor.suggestions(packages: allPackages, defaultNpmTreeLabel: defaultNpmTreeLabel)
            .filter { visiblePackageIDs.contains($0.target.id) }
    }

    public var pruneSourceHealthMessages: [String] {
        sourceHealth.compactMap { health in
            switch (health.manager, health.availability) {
            case (.homebrew, .unavailable), (.homebrew, .failed):
                return pruneHealthMessage(health, impact: "고아 의존성 정리 확인")
            case (.npmGlobal, .unavailable), (.npmGlobal, .failed):
                return pruneHealthMessage(health, impact: "중복 잔재 제안")
            default:
                return nil
            }
        }
    }

    public var prominentScanErrors: [ScanError] {
        let sourceFailureManagers = sourceHealth
            .filter { $0.availability == .failed }
            .map(\.manager)
        return scanErrors.filter { !sourceFailureManagers.contains($0.manager) }
    }

    private func pruneHealthMessage(_ health: SourceHealth, impact: String) -> String {
        let detail = health.message.map { ": \($0)" } ?? ""
        return "\(health.manager.displayName) 데이터를 읽지 못해 \(impact)이 제한됩니다\(detail)"
    }

    public func prune(_ suggestion: PruneSuggestion) async {
        // 차단된 제안은 절대 실행하지 않는다 (MCP 참조/런타임 — 정리 스펙 §2-①)
        guard suggestion.blockReason == nil, !isUpdating else { return }
        // 스테일 가드 (재검증 반영): id뿐 아니라 **버전까지** 일치해야 실행 —
        // 제안 생성 후 외부에서 업그레이드/삭제됐으면 옛 명령·옛 버전 박제를 막는다
        guard packages.contains(where: {
            $0.id == suggestion.target.id && $0.current == suggestion.target.current
        }) else {
            logLines.append("ℹ︎ 정리 제안이 오래되어 실행하지 않았습니다 — 다시 스캔 후 시도하세요")
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        // 복구 기록을 **삭제 전에** 박제 — 기록할 수 없으면 삭제하지 않는다 (복구 없는 삭제 금지)
        let record = RemovalRecord(id: UUID().uuidString, date: Date(),
                                   packageID: suggestion.target.id,
                                   name: suggestion.target.name,
                                   tree: suggestion.target.metadata["tree"],
                                   version: suggestion.target.current,
                                   restore: suggestion.restoreCommand)
        do {
            try ledger.append(record)
        } catch {
            logLines.append("✗ 복구 기록 저장 실패 — 삭제를 중단합니다. 수동 명령: \(suggestion.removeCommand.displayString)")
            return
        }
        recentRemovals = ledger.load()
        let result = await executor.run(suggestion.removeCommand, packageID: suggestion.target.id)
        appendLog(result)
        if result.succeeded {
            await rescan(manager: suggestion.target.manager)
            logLines.append(postPruneCheck(removedName: suggestion.target.name,
                                           bins: PruneAdvisor.bins(of: suggestion.target)))
        } else {
            // 삭제 실패 — 미리 박제한 기록은 회수
            try? ledger.remove(id: record.id)
            recentRemovals = ledger.load()
            recordUpdateState(result, package: suggestion.target)
            await rescan(manager: suggestion.target.manager)
        }
    }

    /// 사후 검증 (정리 스펙 §2-⑤): 재스캔 후의 MCP 설정이 방금 삭제한 이름/bin을 여전히 참조하는지 실제로 본다
    private func postPruneCheck(removedName: String, bins: [String]) -> String {
        let mcp = PruneAdvisor.mcpReferenceInfo(packages: allPackages)
        if mcp.hasUnknowable {
            return "ℹ︎ 삭제 후 점검: 해석 불가한 MCP 설정이 있어 완전한 검증은 불가합니다"
        }
        if PruneAdvisor.isReferencedByMCP(name: removedName, bins: bins, details: mcp.details) {
            return "⚠ 삭제 후 점검: MCP 설정이 \(removedName)을(를) 여전히 참조합니다 — 다른 트리 사본이 PATH에 있는지 확인하세요"
        }
        return "✓ 삭제 후 점검: 남은 MCP 참조 없음. 복구는 정리 뷰에서"
    }

    public func restore(_ record: RemovalRecord) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        let result = await executor.run(record.restore, packageID: record.packageID)
        appendLog(result)
        if result.succeeded {
            try? ledger.remove(id: record.id)
            recentRemovals = ledger.load()
        }
        // packageID 접두에서 매니저 복원 (재검증 반영: npm 하드코딩 제거)
        let manager = record.packageID.split(separator: ":").first
            .flatMap { ManagerID(rawValue: String($0)) } ?? .npmGlobal
        await rescan(manager: manager)
    }

    public func refreshOrphans() async {
        guard let brew = adapters.compactMap({ $0 as? HomebrewAdapter }).first else {
            orphanNames = []
            orphanPruneConfirmation = nil
            return
        }
        orphanNames = (try? await brew.orphanNames()) ?? []
        if let confirmed = orphanPruneConfirmation, confirmed != orphanNames {
            orphanPruneConfirmation = nil
        }
    }

    public func requestPruneOrphans() {
        orphanPruneConfirmation = orphanNames.isEmpty ? nil : orphanNames
    }

    public func cancelPruneOrphans() {
        orphanPruneConfirmation = nil
    }

    public func pruneOrphans() async {
        guard let confirmed = orphanPruneConfirmation,
              confirmed == orphanNames, !confirmed.isEmpty else {
            logLines.append("ℹ︎ 고아 의존성 정리 확인이 필요합니다")
            return
        }
        guard let brew = adapters.compactMap({ $0 as? HomebrewAdapter }).first,
              let command = brew.autoremoveCommand(), !isUpdating else { return }
        orphanPruneConfirmation = nil
        isUpdating = true
        defer { isUpdating = false }
        let result = await executor.run(command, packageID: "homebrew:autoremove")
        appendLog(result)
        await refreshOrphans()
        await rescan(manager: .homebrew)
    }

    // MARK: - 파생 상태

    public var outdatedCount: Int { directOutdatedCount }

    public var highRiskCount: Int {
        directHighRiskCount
    }

    /// 직접 설치(의존성 아님) 기준 카운트 — 뱃지는 이걸 쓴다 (패널 기본 화면과 일치)
    public var directOutdatedCount: Int {
        packages.filter { $0.status == .outdated && !$0.flags.contains(.dependency) }.count
    }

    public var directHighRiskCount: Int {
        packages.filter { $0.status == .outdated && $0.risk == .high && !$0.flags.contains(.dependency) }.count
    }

    public var dependencyOutdatedCount: Int {
        packages.filter { $0.status == .outdated && $0.flags.contains(.dependency) }.count
    }

    public var strings: AppStrings { AppStrings(language) }

    public var canPrepareAppUpdate: Bool {
        appUpdatePreparer != nil
    }

    public var canInstallAppUpdate: Bool {
        appUpdateInstaller != nil
    }

    /// 뱃지: 직접 설치 기준. 의존성만 outdated면 기본 사용자 화면은 최신으로 본다.
    public var badgeText: String {
        let direct = directOutdatedCount
        if direct > 0 {
            let high = directHighRiskCount
            return high > 0 ? "⬆\(direct) ⚠\(high)" : "⬆\(direct)"
        }
        return "✓"
    }

    public func packages(for manager: ManagerID) -> [PackageInfo] {
        packages.filter { $0.manager == manager }
    }

    public func sourceHealth(for manager: ManagerID) -> SourceHealth? {
        sourceHealth.first { $0.manager == manager }
    }

    public var hiddenPackageCount: Int {
        userPolicy.ignoredPackageIDs.union(userPolicy.snoozedPackages.keys).count
    }

    public var hiddenSourceCount: Int {
        userPolicy.hiddenManagers.count
    }

    /// 일괄 업데이트 대상: 앱이 확인 없이 자동 실행해도 되는 직접 설치 항목.
    public var safeUpdatable: [PackageInfo] {
        packages.filter { UpdatePolicy.evaluate($0).isAutomatic }
    }

    public func updateSourceSummary(for manager: ManagerID) -> UpdateSourceSummary? {
        let direct = packages.filter { $0.manager == manager && !$0.flags.contains(.dependency) }
        guard !direct.isEmpty else { return nil }
        return UpdateSourceSummary(
            manager: manager,
            totalCount: direct.count,
            outdatedCount: direct.filter { $0.status == .outdated }.count,
            unknownCount: direct.filter { $0.status == .unknown && !Self.isInventoryOnly($0) }.count,
            highRiskCount: direct.filter { $0.status == .outdated && $0.risk == .high }.count,
            safeUpdatableCount: direct.filter { UpdatePolicy.evaluate($0).isAutomatic }.count)
    }

    public func updateCandidates(for packages: [PackageInfo]) -> [UpdateCandidate] {
        packages.map { pkg in
            guard let adapter = adapters.first(where: { $0.id == pkg.manager }) else {
                return UpdateCandidate(package: pkg, command: nil, canRun: false,
                                       reason: "업데이트 어댑터를 찾을 수 없습니다")
            }
            guard let command = adapter.updateCommand(for: pkg) else {
                return UpdateCandidate(package: pkg, command: nil, canRun: false,
                                       reason: "자동 업데이트를 지원하지 않습니다")
            }
            return UpdateCandidate(package: pkg, command: command.displayString,
                                   canRun: true, reason: nil)
        }
    }

    public func currentUpdateCommands(for candidates: [UpdateCandidate], selectedIDs: Set<String>) -> [String] {
        currentUpdateCandidates(for: candidates, selectedIDs: selectedIDs).compactMap(\.command)
    }

    public func currentUpdateCandidates(
        for candidates: [UpdateCandidate],
        selectedIDs: Set<String>,
        manager: ManagerID? = nil
    ) -> [UpdateCandidate] {
        candidates.compactMap { candidate in
            guard selectedIDs.contains(candidate.id), candidate.canRun,
                  let currentPackage = currentVisiblePackage(matching: candidate.package),
                  manager == nil || currentPackage.manager == manager,
                  UpdateConfirmationSnapshot(currentPackage) == UpdateConfirmationSnapshot(candidate.package),
                  UpdatePolicy.evaluate(currentPackage).isAutomatic,
                  let adapter = adapters.first(where: { $0.id == currentPackage.manager }),
                  let command = adapter.updateCommand(for: currentPackage) else {
                return nil
            }
            return UpdateCandidate(package: currentPackage, command: command.displayString,
                                   canRun: true, reason: nil)
        }
    }

    public func ignore(_ pkg: PackageInfo) {
        userPolicy.ignoredPackageIDs.insert(pkg.id)
        userPolicy.snoozedPackages.removeValue(forKey: pkg.id)
        persistPolicyAndRefreshVisiblePackages()
    }

    public func snooze(_ pkg: PackageInfo, days: Int = 30) {
        userPolicy.snoozedPackages[pkg.id] = now().addingTimeInterval(TimeInterval(days) * 86_400)
        userPolicy.ignoredPackageIDs.remove(pkg.id)
        persistPolicyAndRefreshVisiblePackages()
    }

    public func hideSource(_ manager: ManagerID) {
        userPolicy.hiddenManagers.insert(manager)
        persistPolicyAndRefreshVisiblePackages()
    }

    public func restoreHiddenSource(_ manager: ManagerID) {
        userPolicy.hiddenManagers.remove(manager)
        persistPolicyAndRefreshVisiblePackages()
    }

    public func restoreHiddenSources() {
        userPolicy.hiddenManagers.removeAll()
        persistPolicyAndRefreshVisiblePackages()
    }

    public func restoreHiddenPackages() {
        userPolicy.ignoredPackageIDs.removeAll()
        userPolicy.snoozedPackages.removeAll()
        persistPolicyAndRefreshVisiblePackages()
    }

    public func setLanguage(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        try? languageStore.save(language)
    }

    // MARK: - 액션

    public func checkForAppUpdate() async {
        guard appUpdateState != .checking else { return }
        guard let appUpdateChecker else {
            appUpdateState = .failed(message: "앱 업데이트 확인기가 설정되지 않았습니다", recovery: nil)
            return
        }
        appUpdateState = .checking
        do {
            switch try await appUpdateChecker.availability() {
            case .upToDate(let version):
                appUpdateState = .upToDate(version: version)
            case .available(let release):
                appUpdateState = .available(release: release)
            }
        } catch {
            appUpdateState = .failed(message: Self.appUpdateFailureMessage(for: error), recovery: nil)
        }
    }

    public func prepareAppUpdate(_ release: AppUpdateRelease) async {
        switch appUpdateState {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }
        guard case .available(let availableRelease) = appUpdateState,
              availableRelease == release else {
            appUpdateState = .failed(message: "앱 업데이트 상태가 바뀌었습니다 — 다시 확인하세요",
                                     recovery: AppUpdateRecovery(releasePageURL: release.releasePageURL))
            return
        }
        guard let appUpdatePreparer else {
            appUpdateState = .failed(message: "앱 업데이트 준비기가 설정되지 않았습니다",
                                     recovery: AppUpdateRecovery(releasePageURL: release.releasePageURL))
            return
        }
        appUpdateState = .downloading(release: release)
        do {
            appUpdateState = .readyToInstall(prepared: try await appUpdatePreparer.prepare(release))
        } catch {
            appUpdateState = .failed(message: Self.appUpdateFailureMessage(for: error),
                                     recovery: AppUpdateRecovery(releasePageURL: release.releasePageURL))
        }
    }

    public func installAppUpdate(_ prepared: PreparedAppUpdate) async {
        switch appUpdateState {
        case .checking, .downloading, .installing:
            return
        default:
            break
        }
        let recovery = AppUpdateRecovery(releasePageURL: prepared.release.releasePageURL,
                                         downloadedFileURL: prepared.archiveURL,
                                         logFileURL: prepared.logFileURL)
        guard case .readyToInstall(let currentPrepared) = appUpdateState,
              currentPrepared == prepared else {
            appUpdateState = .failed(message: "앱 업데이트 상태가 바뀌었습니다 — 다시 확인하세요",
                                     recovery: recovery)
            return
        }
        guard let appUpdateInstaller else {
            appUpdateState = .failed(message: "앱 업데이트 설치기가 설정되지 않았습니다",
                                     recovery: recovery)
            return
        }
        appUpdateState = .installing
        do {
            try await appUpdateInstaller.install(prepared)
            appUpdateState = .upToDate(version: AppVersion(version: prepared.release.version,
                                                           versionString: prepared.release.versionString))
        } catch {
            appUpdateState = .failed(message: Self.appUpdateFailureMessage(for: error),
                                     recovery: recovery)
        }
    }

    public func refresh() async {
        // 업데이트 중 24h 타이머가 발화해도 스캔과 업그레이드가 동시 실행되지 않게 막는다
        guard !isScanning, !isUpdating else { return }
        isScanning = true
        defer { isScanning = false }
        await scanAllAndApply()
    }

    public func update(_ pkg: PackageInfo) async {
        await update(pkg, confirmation: nil)
    }

    public func updateConfirmed(_ pkg: PackageInfo, confirmation: UpdateConfirmationSnapshot) async {
        await update(pkg, confirmation: confirmation)
    }

    private func update(_ pkg: PackageInfo, confirmation: UpdateConfirmationSnapshot?) async {
        guard !isUpdating else { return }
        guard !isScanning else {
            logLines.append("ℹ︎ 스캔 중에는 업데이트를 시작하지 않습니다")
            return
        }
        guard let currentPackage = currentPackage(matching: pkg) else {
            logLines.append("ℹ︎ \(pkg.name): 패키지 상태가 바뀌었습니다 — 다시 스캔 후 시도하세요")
            return
        }
        guard UpdateConfirmationSnapshot(currentPackage) == UpdateConfirmationSnapshot(pkg) else {
            logLines.append("ℹ︎ \(pkg.name): 패키지 상태가 바뀌었습니다 — 다시 확인하세요")
            return
        }
        switch UpdatePolicy.evaluate(currentPackage) {
        case .automatic:
            break
        case .requiresConfirmation(let reason):
            guard confirmation == UpdateConfirmationSnapshot(currentPackage) else {
                logLines.append("ℹ︎ \(currentPackage.name): \(reason) — 다시 확인하세요")
                return
            }
        case .unavailable(let reason):
            logLines.append("ℹ︎ \(currentPackage.name): \(reason)")
            return
        }
        guard let adapter = adapters.first(where: { $0.id == currentPackage.manager }) else { return }
        isUpdating = true
        updateProgress = UpdateProgress(currentPackageID: currentPackage.id, currentPackageName: currentPackage.name,
                                        completed: 0, total: 1, mode: .single)
        defer {
            updateProgress = nil
            isUpdating = false
        }
        let result = await executor.update(currentPackage, using: adapter)
        appendLog(result)
        recordUpdateOutcome(result, package: currentPackage)
        updateProgress = UpdateProgress(currentPackageID: currentPackage.id, currentPackageName: currentPackage.name,
                                        completed: 1, total: 1, mode: .single)
        await rescan(manager: currentPackage.manager)
    }

    public func updateAllSafe() async {
        await updateAll(safeUpdatable)
    }

    public func updateAllSafe(selectedIDs: Set<String>) async {
        await updateAll(safeUpdatable.filter { selectedIDs.contains($0.id) })
    }

    public func updateAllSafe(for manager: ManagerID) async {
        await updateAll(safeUpdatable.filter { $0.manager == manager })
    }

    public func updateAllSafe(for manager: ManagerID, selectedIDs: Set<String>) async {
        await updateAll(safeUpdatable.filter { $0.manager == manager && selectedIDs.contains($0.id) })
    }

    public func updateAllSafe(
        candidates: [UpdateCandidate],
        selectedIDs: Set<String>,
        manager: ManagerID? = nil
    ) async {
        await updateAll(currentUpdateCandidates(for: candidates, selectedIDs: selectedIDs,
                                                manager: manager).map(\.package))
    }

    private func updateAll(_ targets: [PackageInfo]) async {
        guard !targets.isEmpty, !isUpdating else { return }
        guard !isScanning else {
            logLines.append("ℹ︎ 스캔 중에는 업데이트를 시작하지 않습니다")
            return
        }
        isUpdating = true
        defer {
            updateProgress = nil
            isUpdating = false
        }
        for (index, pkg) in targets.enumerated() {
            updateProgress = UpdateProgress(currentPackageID: pkg.id, currentPackageName: pkg.name,
                                            completed: index, total: targets.count, mode: .bulk)
            guard let adapter = adapters.first(where: { $0.id == pkg.manager }) else { continue }
            let result = await executor.update(pkg, using: adapter)
            appendLog(result)
            recordUpdateOutcome(result, package: pkg)
        }
        if let last = targets.last {
            updateProgress = UpdateProgress(currentPackageID: last.id, currentPackageName: last.name,
                                            completed: targets.count, total: targets.count, mode: .bulk)
        }
        await scanAllAndApply()
    }

    public func startAutoRefresh(interval: TimeInterval = 86_400) { // 기본 24h (스펙 §5)
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    // MARK: - 내부

    private func currentPackage(matching pkg: PackageInfo) -> PackageInfo? {
        allPackages.first { $0.id == pkg.id }
    }

    private func currentVisiblePackage(matching pkg: PackageInfo) -> PackageInfo? {
        packages.first { $0.id == pkg.id }
    }

    private func apply(_ result: ScanResult) {
        allPackages = result.packages
        applyPolicyToVisiblePackages()
        advisories = result.advisories
        scanErrors = result.errors
        sourceHealth = result.sourceHealth
        lastScan = result.timestamp
        pruneRecentlyUpdated()
        pruneUpdateFailures()
    }

    private func rescan(manager: ManagerID) async {
        let result = await scanner.scan(only: manager)
        allPackages.removeAll { $0.manager == manager }
        allPackages.append(contentsOf: result.packages)
        allPackages.sort { ($0.manager.rawValue, $0.name) < ($1.manager.rawValue, $1.name) }
        applyPolicyToVisiblePackages()
        advisories.removeAll { $0.manager == manager }
        advisories.append(contentsOf: result.advisories)
        scanErrors.removeAll { $0.manager == manager }
        scanErrors.append(contentsOf: result.errors)
        sourceHealth.removeAll { $0.manager == manager }
        sourceHealth.append(contentsOf: result.sourceHealth)
        sourceHealth.sort { Self.managerOrder($0.manager) < Self.managerOrder($1.manager) }
        lastScan = result.timestamp
        pruneRecentlyUpdated()
        pruneUpdateFailures()
        try? cache.save(ScanResult(packages: allPackages, advisories: advisories,
                                   errors: scanErrors, sourceHealth: sourceHealth,
                                   timestamp: result.timestamp))
    }

    private func scanAllAndApply() async {
        let result = await scanner.scanAll()
        apply(result)
        try? cache.save(result)
    }

    private func applyPolicyToVisiblePackages() {
        pruneExpiredSnoozes()
        let current = now()
        packages = allPackages.filter { pkg in
            guard !userPolicy.hiddenManagers.contains(pkg.manager),
                  !userPolicy.ignoredPackageIDs.contains(pkg.id) else {
                return false
            }
            if let snoozedUntil = userPolicy.snoozedPackages[pkg.id] {
                return snoozedUntil <= current
            }
            return true
        }
    }

    private func pruneExpiredSnoozes() {
        let current = now()
        let expired = userPolicy.snoozedPackages.filter { $0.value <= current }.map(\.key)
        guard !expired.isEmpty else { return }
        for id in expired {
            userPolicy.snoozedPackages.removeValue(forKey: id)
        }
        try? policyStore.save(userPolicy)
    }

    private func persistPolicyAndRefreshVisiblePackages() {
        try? policyStore.save(userPolicy)
        applyPolicyToVisiblePackages()
    }

    private func pruneRecentlyUpdated() {
        let byID = Dictionary(grouping: allPackages, by: \.id).mapValues { $0[0] }
        recentlyUpdated = recentlyUpdated.filter { id in
            guard let pkg = byID[id] else { return false }
            return pkg.status == .unknown
        }
    }

    private func pruneUpdateFailures() {
        let byID = Dictionary(grouping: allPackages, by: \.id).mapValues { $0[0] }
        lastUpdateFailures = lastUpdateFailures.filter { id, _ in
            guard let pkg = byID[id] else {
                lastUpdateFailureContexts.removeValue(forKey: id)
                lastUpdateFailureTerminalCommands.removeValue(forKey: id)
                return false
            }
            guard pkg.status != .upToDate else {
                lastUpdateFailureContexts.removeValue(forKey: id)
                lastUpdateFailureTerminalCommands.removeValue(forKey: id)
                return false
            }
            if let context = lastUpdateFailureContexts[id], !context.matches(pkg) {
                lastUpdateFailureContexts.removeValue(forKey: id)
                lastUpdateFailureTerminalCommands.removeValue(forKey: id)
                return false
            }
            return true
        }
    }

    private func recordUpdateOutcome(_ result: UpdateResult, package: PackageInfo) {
        persistUpdateHistory(result, package: package)
        recordUpdateState(result, package: package)
    }

    private func recordUpdateState(_ result: UpdateResult, package: PackageInfo) {
        if result.succeeded {
            recentlyUpdated.insert(result.packageID)
            lastUpdateFailures.removeValue(forKey: result.packageID)
            lastUpdateFailureContexts.removeValue(forKey: result.packageID)
            lastUpdateFailureTerminalCommands.removeValue(forKey: result.packageID)
        } else {
            lastUpdateFailures[result.packageID] = Self.failureMessage(for: result, manager: package.manager)
            lastUpdateFailureContexts[result.packageID] = UpdateFailureContext(package)
            if let command = Self.permissionFailureTerminalCommand(for: result) {
                lastUpdateFailureTerminalCommands[result.packageID] = command
            } else {
                lastUpdateFailureTerminalCommands.removeValue(forKey: result.packageID)
            }
        }
    }

    private func persistUpdateHistory(_ result: UpdateResult, package: PackageInfo) {
        let entry = UpdateHistoryEntry(timestamp: now(), packageID: result.packageID,
                                       manager: package.manager, name: package.name,
                                       previousVersion: package.current,
                                       targetVersion: package.latest,
                                       command: result.command,
                                       exitCode: result.exitCode,
                                       stdout: result.stdout,
                                       stderr: result.stderr)
        do {
            try historyStore.append(entry)
            updateHistory = historyStore.loadLatest()
        } catch {
            logLines.append("⚠ 업데이트 히스토리 저장 실패: \(error.localizedDescription)")
        }
    }

    private static func failureMessage(for result: UpdateResult, manager: ManagerID) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // claude plugin update의 "not found" — 실측 원인: 구버전 CLI(예: nvm 트리의 낡은
        // npm 잔재 2.1.17)가 현재 레지스트리를 인식 못 하거나, 마켓플레이스에서 제거된 경우
        if manager == .claudePlugin,
           (result.stdout + result.stderr).contains("not found") {
            return "claude CLI가 플러그인을 찾지 못했습니다 — CLI가 구버전이거나 마켓플레이스에서 제거됐을 수 있습니다. 터미널에서 `claude --version`과 `claude plugin list`를 확인하세요"
        }
        // sudo가 TTY 없이 비밀번호를 요구한 경우 — GUI 앱에서는 해결 불가한 환경 제약
        // (예: root 소유의 MAS 앱을 mas가 교체하려 할 때). raw 에러 대신 행동 안내로.
        if Self.isSudoPasswordFailure(stderr) {
            if manager == .macAppStore {
                return "관리자 권한이 필요해 mas로는 업데이트할 수 없습니다 — App Store에서 직접 업데이트하세요 (행의 링크 메뉴 → 패키지)"
            }
            return "관리자 권한(비밀번호)이 필요한 작업이라 앱에서 실행할 수 없습니다 — 터미널에서 진행하세요"
        }
        if Self.isPermissionDeniedFailure(stderr) {
            if manager == .npmGlobal {
                return "관리자 권한이 필요한 npm 전역 패키지입니다 — 앱에서 삭제/업데이트할 수 없습니다. 터미널에서 소유권을 확인한 뒤 관리자 권한으로 정리하세요"
            }
            return "관리자 권한이 필요한 작업이라 앱에서 실행할 수 없습니다 — 터미널에서 권한을 확인하세요"
        }
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty { return stdout }
        return "exit \(result.exitCode)"
    }

    private static func appUpdateFailureMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func isSudoPasswordFailure(_ stderr: String) -> Bool {
        stderr.contains("sudo") && stderr.contains("password")
    }

    private static func isPermissionDeniedFailure(_ stderr: String) -> Bool {
        stderr.contains("EACCES") || stderr.localizedCaseInsensitiveContains("permission denied")
    }

    private static func permissionFailureTerminalCommand(for result: UpdateResult) -> String? {
        guard Self.isPermissionDeniedFailure(result.stderr) else { return nil }
        return Self.commandRequiringAdminPrivileges(result.command)
    }

    private static func commandRequiringAdminPrivileges(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sudo ") { return trimmed }
        if Self.startsWithEnvironmentAssignment(trimmed) {
            return "sudo env \(trimmed)"
        }
        return "sudo \(trimmed)"
    }

    private static func startsWithEnvironmentAssignment(_ command: String) -> Bool {
        guard let firstToken = command.split(separator: " ", maxSplits: 1).first else { return false }
        guard let equalIndex = firstToken.firstIndex(of: "=") else { return false }
        return equalIndex > firstToken.startIndex
    }

    private func appendLog(_ result: UpdateResult) {
        logLines.append("$ \(result.command)")
        if !result.stdout.isEmpty { logLines.append(result.stdout.trimmingCharacters(in: .newlines)) }
        if !result.stderr.isEmpty { logLines.append(result.stderr.trimmingCharacters(in: .newlines)) }
        if result.succeeded {
            logLines.append("✓ \(result.packageID) 업데이트 성공")
            if result.packageID.hasPrefix("\(ManagerID.claudePlugin.rawValue):") {
                logLines.append("ℹ︎ 적용에는 Claude Code 재시작이 필요합니다")
            }
        } else {
            logLines.append("✗ \(result.packageID) 실패 (exit \(result.exitCode))")
            if Self.isSudoPasswordFailure(result.stderr) {
                logLines.append("ℹ︎ 관리자 권한(비밀번호)이 필요한 업데이트 — App Store 또는 터미널에서 진행하세요")
            } else if Self.isPermissionDeniedFailure(result.stderr) {
                logLines.append("ℹ︎ 관리자 권한이 필요한 작업 — 터미널에서 소유권과 권한을 확인하세요")
            }
        }
    }

    private static func managerOrder(_ manager: ManagerID) -> Int {
        ManagerID.allCases.firstIndex(of: manager) ?? Int.max
    }

    private static func isInventoryOnly(_ pkg: PackageInfo) -> Bool {
        pkg.statusReason == .inventoryOnly || pkg.metadata["kind"] == "mcp"
    }
}

private struct UpdateFailureContext {
    let current: String?
    let lastUpdated: String?

    init(_ package: PackageInfo) {
        current = package.current
        lastUpdated = package.metadata["lastUpdated"]
    }

    func matches(_ package: PackageInfo) -> Bool {
        current == package.current && lastUpdated == package.metadata["lastUpdated"]
    }
}
