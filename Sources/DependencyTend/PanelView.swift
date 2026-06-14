import AppCore
import AppKit
import Engine
import ServiceManagement
import SwiftUI

struct PanelView: View {
    @ObservedObject var model: AppViewModel
    @AppStorage("panelSizePreset") private var panelSizeRaw = PanelSizePreset.defaultPreset.rawValue
    @AppStorage("panelSizePresetDefaultMigrationV3") private var didMigrateDefaultPanelSize = false
    @State private var updateConfirmation = UpdateConfirmationState()
    @State private var showLog = false
    @State private var showPrune = false
    @State private var showSources = false
    @State private var bulkPreview: BulkUpdatePreview?
    @State private var showUpToDate = false
    @State private var visibilityFilter: PackageVisibilityFilter = .all
    @AppStorage("expandedUpdateSources") private var expandedUpdateSourcesRaw = ""

    /// 직접 설치 패키지 목록에 적용되는 표시 조건
    private func passesFilters(_ pkg: PackageInfo) -> Bool {
        visibilityFilter.includes(pkg, showUpToDate: showUpToDate)
    }
    // 재검토 m7: SMAppService 호출은 번들 가드 안에서 지연 평가 — 초기값은 false
    @State private var launchAtLogin = false

    // 주의(재검토 B2): MenuBarExtra .window의 비활성 패널에서는 sheet/confirmationDialog가
    // 신뢰성 있게 표시되지 않는다 — 확인과 로그는 모두 패널 내 인라인 UI로 처리한다.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            filterBar
            if !model.advisories.isEmpty { advisoryBanner }
            if !model.prominentScanErrors.isEmpty { errorBanner }
            if model.appUpdateState != .idle { appUpdateStatusStrip(model.appUpdateState) }
            if let progress = model.updateProgress { updateProgressStrip(progress) }
            scrollableContent
            Divider()
            footer
        }
        .padding(12)
        .frame(width: panelDimensions.width, height: panelDimensions.height, alignment: .topLeading)
        .onAppear { migrateDefaultPanelSizeIfNeeded() }
    }

    private var header: some View {
        HStack {
            Text("dependency-tend").font(.headline)
            panelSizeControls
            languagePicker
            Spacer()
            if let last = model.lastScan {
                Text(last, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isScanning { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .disabled(model.isScanning)
            .accessibilityLabel(model.strings.refreshNow)
            .tip(model.strings.refreshNow, edge: .trailing)
            headerActionMenu
        }
    }

    private var languagePicker: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    model.setLanguage(language)
                } label: {
                    if model.language == language {
                        Label(language.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(language.menuTitle)
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityLabel(model.strings.languageMenuAccessibilityLabel)
        .tip(model.strings.languageMenuTip, edge: .trailing)
    }

    private var headerActionMenu: some View {
        Menu {
            Button(model.strings.refreshNow) {
                Task { await model.refresh() }
            }
            .disabled(model.isScanning)

            Button(model.strings.checkAppUpdateTitle) {
                Task { await model.checkForAppUpdate() }
            }
            .disabled(model.appUpdateState == .checking)

            Button(model.strings.safeUpdatesActionTitle) {
                showBulkPreview()
            }
            .disabled(model.safeUpdatable.isEmpty || model.isUpdating || model.isScanning)

            Divider()

            Button(model.strings.togglePruneTitle(isShowing: showPrune)) {
                showPrune.toggle()
            }
            Button(model.strings.toggleSourcesTitle(isShowing: showSources)) {
                showSources.toggle()
            }
            Button(model.strings.toggleLogTitle(isShowing: showLog)) {
                showLog.toggle()
            }
            .disabled(model.logLines.isEmpty && model.updateHistory.isEmpty && !showLog)

            Divider()

            Button(model.strings.quitTitle) {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityLabel(model.strings.moreActionsAccessibilityLabel)
        .tip(model.strings.moreActionsTip, edge: .trailing)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            // 세그먼트 컨트롤은 통짜라 칸별 호버 팁이 불가 — 칩 버튼으로 분리해 각자 팁을 단다
            ForEach(PackageVisibilityFilter.allCases, id: \.self) { filter in
                filterChip(filter)
            }
            Spacer()
            HStack {
                Toggle(model.strings.includeUpToDateTitle, isOn: $showUpToDate)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(visibilityFilter != .all) // 필터 중엔 업데이트 대상만 의미 있음
            }
            .tip(model.strings.includeUpToDateTip(isAllFilter: visibilityFilter == .all), edge: .trailing)
        }
    }

    private func filterChip(_ filter: PackageVisibilityFilter) -> some View {
        Button { visibilityFilter = filter } label: {
            Text(filter.displayName(language: model.language))
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(visibilityFilter == filter ? Color.accentColor.opacity(0.25)
                                                       : Color.gray.opacity(0.12),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .tip(filter.tip(language: model.language))
    }

    private var advisoryBanner: some View {
        ForEach(model.advisories, id: \.self) { advisory in
            HStack(spacing: 6) {
                Label(advisory.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let urlString = advisory.url, let url = URL(string: urlString) {
                    Link(model.strings.guideLinkTitle, destination: url).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var errorBanner: some View {
        ForEach(model.prominentScanErrors, id: \.self) { error in
            Label("\(error.manager.displayName): \(error.message)", systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var scrollableContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if visibleManagerSectionCount == 0 {
                    packageEmptyState
                }
                ForEach(ManagerID.allCases, id: \.self) { manager in
                    let all = model.packages(for: manager)
                    if !all.isEmpty {
                        managerSection(manager, all: all)
                    }
                }
                if let bulkPreview {
                    Divider()
                    bulkUpdatePreview(bulkPreview)
                }
                if showSources {
                    Divider()
                    sourceStatusSection
                }
                if showPrune {
                    Divider()
                    PruneView(model: model, strings: model.strings)
                }
                if showLog {
                    Divider()
                    LogView(lines: model.logLines, history: model.updateHistory, strings: model.strings)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // 목록과 펼친 보조 패널은 선택한 패널 크기 안에서 함께 스크롤된다.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var visibleManagerSectionCount: Int {
        ManagerID.allCases.filter { manager in
            let direct = model.packages(for: manager).filter { !$0.flags.contains(.dependency) }
            return !direct.filter(passesFilters).isEmpty
        }.count
    }

    private var packageEmptyState: some View {
        let presentation = packageEmptyPresentation
        return VStack(alignment: .leading, spacing: 5) {
            Text(presentation.title)
                .font(.caption)
                .bold()
            Text(presentation.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let title = presentation.restoreHiddenPackagesTitle {
                Button(title) {
                    model.restoreHiddenPackages()
                }
                .controlSize(.small)
            }
            if let title = presentation.restoreHiddenSourcesTitle {
                Button(title) {
                    model.restoreHiddenSources()
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var packageEmptyPresentation: PackageEmptyStatePresentation {
        PackageEmptyStatePresentation.make(
            isScanning: model.isScanning,
            visibilityFilter: visibilityFilter,
            showUpToDate: showUpToDate,
            hiddenPackageCount: model.hiddenPackageCount,
            hiddenSourceCount: model.hiddenSourceCount,
            language: model.language)
    }

    // MARK: - 직접 설치 패키지 목록

    @ViewBuilder
    private func managerSection(_ manager: ManagerID, all: [PackageInfo]) -> some View {
        let direct = all.filter { !$0.flags.contains(.dependency) }
        let visible = direct.filter(passesFilters)
        // 실제 표시할 행이 없는 소스는 패널에서 숨긴다
        if !visible.isEmpty {
            sectionHeader(manager, direct: direct, visible: visible)
            if isExpanded(manager) {
                if manager == .npmGlobal {
                    npmTreeGroups(visible)
                } else {
                    packageRows(visible)
                }
            }
        }
    }

    /// npm은 트리(node 런타임)별 소그룹으로 — nvm 여러 버전과 homebrew node가 공존할 수 있다
    @ViewBuilder
    private func npmTreeGroups(_ pkgs: [PackageInfo]) -> some View {
        let groups = Dictionary(grouping: pkgs) {
            $0.metadata["tree"] ?? $0.metadata["node"].map { "v\($0)" } ?? "기타"
        }
        ForEach(groups.keys.sorted(), id: \.self) { tree in
            Text(model.strings.npmTreeGroupTitle(tree))
                .font(.caption2).bold()
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .tip(model.strings.npmTreeGroupTip)
            packageRows(groups[tree] ?? [])
        }
    }

    private func packageRows(_ pkgs: [PackageInfo]) -> some View {
        ForEach(pkgs) { pkg in
            PackageRowView(pkg: pkg, strings: model.strings,
                           isUpdating: model.isUpdating,
                           isScanning: model.isScanning,
                           isRecentlyUpdated: model.recentlyUpdated.contains(pkg.id),
                           isConfirming: updateConfirmation.isConfirming(pkg),
                           isActivelyUpdating: model.updateProgress?.currentPackageID == pkg.id,
                           updateFailure: model.lastUpdateFailures[pkg.id],
                           updateFailureTerminalCommand: model.lastUpdateFailureTerminalCommands[pkg.id],
                           onUpdate: { requestUpdate(pkg) },
                           onConfirmUpdate: { confirmUpdate(pkg) },
                           onCancelUpdate: { updateConfirmation.clear() },
                           onIgnore: { model.ignore(pkg) },
                           onSnooze: { model.snooze(pkg) },
                           onHideSource: { model.hideSource(pkg.manager) })
        }
    }

    private func requestUpdate(_ pkg: PackageInfo) {
        switch updateConfirmation.request(pkg) {
        case .runImmediately:
            Task { await model.update(pkg) }
        case .requiresConfirmation:
            break
        case .blocked:
            break
        }
    }

    private func confirmUpdate(_ pkg: PackageInfo) {
        guard let confirmation = updateConfirmation.confirmation(for: pkg) else {
            updateConfirmation.clear()
            return
        }
        updateConfirmation.clear()
        Task { await model.updateConfirmed(pkg, confirmation: confirmation) }
    }

    private func updateProgressStrip(_ progress: UpdateProgress) -> some View {
        let presentation = progress.presentation(language: model.language)
        return HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
            Text(presentation.title)
                .font(.caption)
                .bold()
                .lineLimit(1)
            Spacer()
            Text(presentation.countText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.blue.opacity(0.25), lineWidth: 1)
        }
        .tip(model.strings.updateProgressTip)
    }

    private func appUpdateStatusStrip(_ state: AppUpdateState) -> some View {
        HStack(spacing: 7) {
            appUpdateStatusLabel(state)
            Spacer()
            if case .available(let release) = state {
                if model.canPrepareAppUpdate {
                    Button(model.strings.appUpdateDownloadTitle) {
                        Task { await model.prepareAppUpdate(release) }
                    }
                    .controlSize(.small)
                    .font(.caption)
                }
                Link(model.strings.appUpdateReleaseNotesTitle, destination: release.releasePageURL)
                    .font(.caption)
            }
            if case .readyToInstall(let prepared) = state, model.canInstallAppUpdate {
                Button(model.strings.appUpdateInstallTitle) {
                    Task { await model.installAppUpdate(prepared) }
                }
                .controlSize(.small)
                .font(.caption)
            }
        }
        .padding(8)
        .background(appUpdateStatusColor(state).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(appUpdateStatusColor(state).opacity(0.25), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func appUpdateStatusLabel(_ state: AppUpdateState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView()
                .controlSize(.small)
            Text(model.strings.appUpdateCheckingTitle)
                .font(.caption)
                .bold()
        case .upToDate(let version):
            Label(model.strings.appUpdateUpToDateTitle(version.versionString),
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .available(let release):
            Label(model.strings.appUpdateAvailableTitle(release.versionString),
                  systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.blue)
        case .downloading(let release):
            ProgressView()
                .controlSize(.small)
            Text(model.strings.appUpdateDownloadingTitle(release.versionString))
                .font(.caption)
                .bold()
        case .readyToInstall(let prepared):
            Label(model.strings.appUpdateReadyToInstallTitle(prepared.release.versionString),
                  systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .installing:
            Label(model.strings.appUpdateInstallingTitle, systemImage: "shippingbox.fill")
                .font(.caption)
                .foregroundStyle(.blue)
        case .failed(let message, _):
            Label(model.strings.appUpdateFailedTitle, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func appUpdateStatusColor(_ state: AppUpdateState) -> Color {
        switch state {
        case .upToDate, .readyToInstall:
            return .green
        case .failed:
            return .red
        default:
            return .blue
        }
    }

    private func sectionHeader(_ manager: ManagerID, direct: [PackageInfo],
                               visible: [PackageInfo]) -> some View {
        let summary = model.updateSourceSummary(for: manager)
        let isOpen = isExpanded(manager)
        return HStack(spacing: 6) {
            Button {
                toggleExpanded(manager)
            } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.strings.sourceToggleAccessibilityLabel(manager: manager.displayName, isOpen: isOpen))
            .tip(model.strings.sourceToggleTip(isOpen: isOpen))
            Text(manager.displayName).font(.subheadline).bold()
            // npm은 트리가 여러 개일 수 있어 헤더 대신 소그룹 헤더("node vX (소속)")로 표시한다
            if manager == .npmGlobal {
                let trees = Set(direct.compactMap { $0.metadata["tree"] })
                if trees.count > 1 {
                    Text(model.strings.runtimeCount(trees.count)).font(.caption).foregroundStyle(.secondary)
                        .tip(trees.sorted().joined(separator: " · "))
                }
            }
            Spacer()
            if let summary, summary.safeUpdatableCount > 0 {
                Button(model.strings.automaticUpdateTitle(summary.safeUpdatableCount)) {
                    showBulkPreview(for: manager)
                }
                .controlSize(.small)
                .disabled(model.isUpdating || model.isScanning)
                .tip(model.strings.automaticUpdateTip(manager: manager.displayName), edge: .trailing)
            }
            Text(UpdateSourceSummaryPresentation.text(for: visible, language: model.language))
                .font(.caption).foregroundStyle(.secondary)
                .tip(model.strings.sourceSummaryTip, edge: .trailing)
        }
        .padding(.top, 8)
    }

    private func expandedSourceIDs() -> Set<String> {
        Set(expandedUpdateSourcesRaw.split(separator: ",").map(String.init))
    }

    private func isExpanded(_ manager: ManagerID) -> Bool {
        expandedSourceIDs().contains(manager.rawValue)
    }

    private func toggleExpanded(_ manager: ManagerID) {
        var ids = expandedSourceIDs()
        if ids.contains(manager.rawValue) {
            ids.remove(manager.rawValue)
        } else {
            ids.insert(manager.rawValue)
        }
        expandedUpdateSourcesRaw = ids.sorted().joined(separator: ",")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            footerActions
            // SMAppService는 .app 번들에서만 동작 (swift run에서는 표시하지 않음)
            if Bundle.main.bundleIdentifier != nil {
                Toggle(model.strings.launchAtLoginTitle, isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            if newValue { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .font(.caption)
    }

    private var footerActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                bulkUpdateButton
                Spacer(minLength: 8)
                secondaryFooterActions
            }
            VStack(alignment: .leading, spacing: 6) {
                bulkUpdateButton
                secondaryFooterActions
            }
        }
    }

    private var bulkUpdateButton: some View {
        Button(model.strings.bulkUpdateTitle(model.safeUpdatable.count)) {
            showBulkPreview()
        }
        .disabled(model.safeUpdatable.isEmpty || model.isUpdating || model.isScanning)
    }

    private var secondaryFooterActions: some View {
        HStack(spacing: 6) {
            Button(model.strings.compactPruneTitle(isShowing: showPrune)) { showPrune.toggle() }
                .tip(model.strings.pruneTip, edge: .trailing)
            Button(model.strings.compactSourcesTitle(isShowing: showSources)) { showSources.toggle() }
                .tip(model.strings.sourcesTip, edge: .trailing)
            Button(model.strings.compactLogTitle(isShowing: showLog)) { showLog.toggle() }
                .disabled(model.logLines.isEmpty && model.updateHistory.isEmpty && !showLog)
            Button(model.strings.quitTitle) { NSApp.terminate(nil) }
        }
    }

    private func bulkUpdatePreview(_ preview: BulkUpdatePreview) -> some View {
        let runnable = preview.candidates.filter(\.canRun)
        let currentCandidates = model.currentUpdateCandidates(for: preview.candidates,
                                                              selectedIDs: preview.selectedIDs,
                                                              manager: preview.manager)
        let currentCandidateIDs = Set(currentCandidates.map(\.id))
        let commands = currentCandidates.compactMap(\.command)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(preview.title, systemImage: "terminal")
                    .font(.caption).bold()
                Spacer()
                Text("\(currentCandidates.count)/\(runnable.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(preview.candidates) { candidate in
                    bulkCandidateRow(candidate, isCurrent: !candidate.canRun || currentCandidateIDs.contains(candidate.id))
                }
            }
            HStack {
                Button(model.strings.runSelectedTitle) {
                    runBulkPreview(preview)
                }
                .disabled(currentCandidates.isEmpty || model.isUpdating || model.isScanning)
                Button(model.strings.copyCommandsTitle) {
                    copyPreviewCommands(preview)
                }
                .disabled(commands.isEmpty)
                Spacer()
                Button(model.strings.cancelTitle) {
                    bulkPreview = nil
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.blue.opacity(0.20), lineWidth: 1)
        }
    }

    private func bulkCandidateRow(_ candidate: UpdateCandidate, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Toggle("", isOn: bulkSelectionBinding(candidate))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!candidate.canRun || !isCurrent || model.isUpdating || model.isScanning)
                .accessibilityLabel(model.strings.selectPackageAccessibilityLabel(candidate.package.name))
            Circle()
                .fill(candidateRiskColor(candidate.package))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityLabel(model.strings.riskAccessibilityLabel(candidateRiskAccessibilityLabel(candidate.package)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(candidate.package.name)
                        .font(.caption)
                        .bold()
                        .lineLimit(1)
                    Spacer()
                    Text(candidateVersionText(candidate.package))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let command = candidate.command {
                    Text(isCurrent ? command : model.strings.staleCandidateText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let reason = candidate.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .tip(isCurrent ? (candidate.command ?? candidate.reason ?? "")
                       : model.strings.staleCandidateTip)
    }

    private func showBulkPreview(for manager: ManagerID? = nil) {
        let targets: [PackageInfo]
        let title: String
        if let manager {
            targets = model.safeUpdatable.filter { $0.manager == manager }
            title = model.strings.bulkPreviewTitle(manager: manager.displayName)
        } else {
            targets = model.safeUpdatable
            title = model.strings.bulkPreviewTitle(manager: nil)
        }
        let candidates = model.updateCandidates(for: targets)
        bulkPreview = BulkUpdatePreview(
            title: title,
            manager: manager,
            candidates: candidates,
            selectedIDs: Set(candidates.filter(\.canRun).map(\.id)))
    }

    private func runBulkPreview(_ preview: BulkUpdatePreview) {
        let candidates = model.currentUpdateCandidates(for: preview.candidates,
                                                       selectedIDs: preview.selectedIDs,
                                                       manager: preview.manager)
        guard !candidates.isEmpty else { return }
        bulkPreview = nil
        Task {
            await model.updateAllSafe(candidates: preview.candidates,
                                      selectedIDs: preview.selectedIDs,
                                      manager: preview.manager)
        }
    }

    private func copyPreviewCommands(_ preview: BulkUpdatePreview) {
        let commands = model.currentUpdateCommands(for: preview.candidates, selectedIDs: preview.selectedIDs)
        guard !commands.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands.joined(separator: "\n"), forType: .string)
    }

    private func bulkSelectionBinding(_ candidate: UpdateCandidate) -> Binding<Bool> {
        Binding {
            bulkPreview?.selectedIDs.contains(candidate.id) == true
        } set: { isOn in
            guard bulkPreview != nil else { return }
            if isOn {
                bulkPreview?.selectedIDs.insert(candidate.id)
            } else {
                bulkPreview?.selectedIDs.remove(candidate.id)
            }
        }
    }

    private func candidateVersionText(_ pkg: PackageInfo) -> String {
        if pkg.status == .outdated {
            return "\(pkg.current ?? "-") → \(pkg.latest ?? "-")"
        }
        return pkg.current ?? "-"
    }

    private func candidateRiskColor(_ pkg: PackageInfo) -> Color {
        switch pkg.risk {
        case .high:
            return .red
        case .medium:
            return .yellow
        case .low:
            return .green
        case nil:
            return .gray
        }
    }

    private func candidateRiskAccessibilityLabel(_ pkg: PackageInfo) -> String {
        switch pkg.risk {
        case .high:
            return model.strings.riskHighTitle
        case .medium:
            return model.strings.riskMediumTitle
        case .low:
            return model.strings.riskLowTitle
        case nil:
            return model.strings.riskUnknownTitle
        }
    }

    private var sourceStatusSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.strings.updateSourcesTitle)
                    .font(.caption).bold()
                Spacer()
                if !model.sourceHealth.isEmpty {
                    Text(model.strings.sourceHealthCount(model.sourceHealth.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if model.hiddenPackageCount > 0 {
                HStack(spacing: 6) {
                    Text(model.strings.hiddenPackagesTitle(model.hiddenPackageCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.strings.restoreAllTitle) {
                        model.restoreHiddenPackages()
                    }
                    .controlSize(.small)
                }
                .tip(model.strings.restoreHiddenPackagesTip, edge: .trailing)
            }
            if model.sourceHealth.isEmpty {
                Text(model.isScanning ? model.strings.checkingSourcesTitle : model.strings.notScannedYetTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(model.sourceHealth) { health in
                    sourceStatusRow(health)
                }
            }
            if !model.toolDiagnostics.isEmpty {
                Divider()
                toolDiagnosticsSection
            }
        }
        .padding(8)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var toolDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.strings.toolDiagnosticsTitle)
                .font(.caption)
                .bold()
            ForEach(model.toolDiagnostics) { diagnostic in
                toolDiagnosticRow(diagnostic)
            }
        }
    }

    private func toolDiagnosticRow(_ diagnostic: ToolDiagnostic) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(diagnostic.isAvailable ? .green : .secondary)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
                .accessibilityLabel("\(diagnostic.name) \(diagnostic.isAvailable ? model.strings.detectedTitle : model.strings.missingTitle)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(diagnostic.name)
                        .font(.caption)
                        .bold()
                        .lineLimit(1)
                    if let detail = diagnostic.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(diagnostic.isAvailable ? model.strings.detectedTitle : model.strings.missingTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(diagnostic.path ?? model.strings.executableMissingText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .tip(diagnostic.path ?? model.strings.executableMissingTip(diagnostic.name), edge: .trailing)
    }

    private func sourceStatusRow(_ health: SourceHealth) -> some View {
        let isHidden = model.userPolicy.hiddenManagers.contains(health.manager)
        return HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(isHidden ? .secondary : sourceStatusColor(health.availability))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
                .accessibilityLabel("\(health.manager.displayName) \(isHidden ? model.strings.hiddenTitle : sourceStatusText(health))")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(health.manager.displayName)
                        .font(.caption)
                        .bold()
                        .lineLimit(1)
                    Spacer()
                    if isHidden {
                        Text(model.strings.hiddenTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button(model.strings.restoreTitle) {
                            model.restoreHiddenSource(health.manager)
                        }
                        .controlSize(.small)
                    } else {
                        Text(sourceStatusText(health))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let message = health.message, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .tip(isHidden ? model.strings.hiddenSourceTip
                      : sourceStatusTip(health),
             edge: .trailing)
    }

    private func sourceStatusText(_ health: SourceHealth) -> String {
        switch health.availability {
        case .available:
            return model.strings.sourceAvailableText(count: health.packageCount)
        case .unavailable:
            return model.strings.sourceUnavailableText
        case .empty:
            return model.strings.sourceEmptyText
        case .failed:
            return model.strings.sourceFailedText
        }
    }

    private func sourceStatusTip(_ health: SourceHealth) -> String {
        switch health.availability {
        case .available:
            return model.strings.sourceAvailableTip(manager: health.manager.displayName)
        case .unavailable:
            return model.strings.sourceUnavailableTip(manager: health.manager.displayName)
        case .empty:
            return model.strings.sourceEmptyTip(manager: health.manager.displayName)
        case .failed:
            return health.message ?? model.strings.sourceScanFailedTip(manager: health.manager.displayName)
        }
    }

    private func sourceStatusColor(_ availability: SourceAvailability) -> Color {
        switch availability {
        case .available:
            return .green
        case .unavailable:
            return .secondary
        case .empty:
            return .blue
        case .failed:
            return .red
        }
    }

    private var panelSizeControls: some View {
        HStack(spacing: 4) {
            Button {
                panelSizeRaw = panelSize.smaller.rawValue
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .disabled(panelSize == .compact)
            .accessibilityLabel(model.strings.panelSmallerAccessibilityLabel)
            .tip(model.strings.panelSmallerAccessibilityLabel)

            Button {
                panelSizeRaw = panelSize.larger.rawValue
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(panelSize == .large)
            .accessibilityLabel(model.strings.panelLargerAccessibilityLabel)
            .tip(model.strings.panelLargerAccessibilityLabel)
        }
        .buttonStyle(.borderless)
    }

    private var panelSize: PanelSizePreset {
        PanelSizePreset(rawValueOrDefault: panelSizeRaw)
    }

    private var panelDimensions: PanelDimensions {
        panelSize.dimensions
    }

    private func migrateDefaultPanelSizeIfNeeded() {
        guard !didMigrateDefaultPanelSize else { return }
        let defaultedRaw = PanelSizePreset.defaultedRawValueAfterDefaultMigration(panelSizeRaw)
        if panelSizeRaw != defaultedRaw {
            panelSizeRaw = defaultedRaw
        }
        didMigrateDefaultPanelSize = true
    }
}

private struct BulkUpdatePreview: Equatable {
    let title: String
    let manager: ManagerID?
    let candidates: [UpdateCandidate]
    var selectedIDs: Set<String>
}
