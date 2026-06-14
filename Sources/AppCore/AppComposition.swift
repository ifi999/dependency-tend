import Engine
import Foundation

/// 조립 루트: 실제 도구 경로로 어댑터/스캐너/실행기를 만든다.
public enum AppComposition {
    @MainActor
    public static func makeViewModel() -> AppViewModel {
        let locator = ToolLocator()
        let runner = ProcessCommandRunner()
        let adapters: [any PackageManagerAdapter] = [
            HomebrewAdapter(brewURL: locator.brew(), runner: runner,
                            cellarURL: locator.brewCellar()),
            NpmGlobalAdapter(tools: locator.npmInstallations(), runner: runner),
            ClaudePluginAdapter(registryURL: locator.claudePluginRegistry(),
                                claudeCLI: locator.claudeCLI(),
                                mcpConfigURL: locator.claudeMCPConfig(),
                                marketplaceRegistryURL: locator.claudeKnownMarketplaces()),
            MacAppStoreAdapter(masURL: locator.mas(), runner: runner),
            PipxAdapter(pipxURL: locator.pipx(), runner: runner),
            UvToolAdapter(uvURL: locator.uv(), runner: runner),
            CargoInstallAdapter(cargoURL: locator.cargo(), runner: runner),
            EditorExtensionAdapter(id: .vscodeExtensions, cliURL: locator.vscodeCLI(), runner: runner),
            EditorExtensionAdapter(id: .cursorExtensions, cliURL: locator.cursorCLI(), runner: runner),
            PnpmGlobalAdapter(pnpmURL: locator.pnpm(), runner: runner),
            YarnGlobalAdapter(yarnURL: locator.yarn(), runner: runner),
            BunGlobalAdapter(bunURL: locator.bun(), globalPackageJSON: locator.bunGlobalPackageJSON()),
        ]
        let appUpdatePreparer: (any AppUpdatePreparing)? = AppUpdatePublicKeyLoader.bundleResource()
            .load()
            .map { GitHubAppUpdatePreparer(publicKeyPEMData: $0) }
        let appUpdateInstaller: (any AppUpdateInstalling)? = ScriptedAppUpdateInstaller.bundleResource()
        let viewModel = AppViewModel(scanner: PackageScanner(adapters: adapters),
                                     executor: UpdateExecutor(runner: runner),
                                     adapters: adapters,
                                     cache: ScanCache(),
                                     ledger: RemovalLedger(),
                                     languageStore: LanguageStore(),
                                     appUpdateChecker: GitHubAppUpdateChecker(),
                                     appUpdatePreparer: appUpdatePreparer,
                                     appUpdateInstaller: appUpdateInstaller,
                                     toolDiagnostics: locator.diagnostics(),
                                     // 동일 버전 중복의 keep 판정에 사용 (정리 스펙 §3)
                                     defaultNpmTreeLabel: locator.npm()?.label)
        // 스펙 §5: 실행 → 캐시 즉시 표시(init에서 완료) → 백그라운드 스캔.
        // 시작 시 1회 스캔이 없으면 첫 자동 스캔이 24시간 뒤가 되어 뱃지가 거짓 ✓를 보인다 (재검토 B3)
        Task { await viewModel.refresh() }
        viewModel.startAutoRefresh()
        return viewModel
    }
}
