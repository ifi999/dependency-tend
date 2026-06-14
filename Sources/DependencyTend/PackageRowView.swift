import AppKit
import AppCore
import Engine
import SwiftUI

struct PackageRowView: View {
    let pkg: PackageInfo
    let strings: AppStrings
    let isUpdating: Bool
    let isScanning: Bool
    let isRecentlyUpdated: Bool
    let isConfirming: Bool
    let isActivelyUpdating: Bool
    let updateFailure: String?
    let updateFailureTerminalCommand: String?
    let onUpdate: () -> Void
    let onConfirmUpdate: () -> Void
    let onCancelUpdate: () -> Void
    let onIgnore: () -> Void
    let onSnooze: () -> Void
    let onHideSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(riskColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(strings.riskAccessibilityLabel(riskAccessibilityLabel))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(displayName).font(.callout).lineLimit(1)
                        if isMCP {
                            Text("MCP")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .foregroundStyle(.purple)
                                .background(Color.purple.opacity(0.15), in: Capsule())
                                .tip(strings.mcpServerTip)
                        }
                    }
                    Text(versionText).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !linkItems.isEmpty {
                    Menu {
                        ForEach(linkItems) { item in
                            Link(destination: item.url) {
                                Label(item.title, systemImage: item.systemImage)
                            }
                        }
                    } label: {
                        Image(systemName: "link")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .accessibilityLabel(strings.relatedLinksTitle)
                    .tip(strings.relatedLinksTitle, edge: .trailing)
                }
                if pkg.flags.contains(.pinned) {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel(strings.pinnedPackageAccessibilityLabel)
                        .tip(strings.pinnedPackageTip, edge: .trailing)
                }
                Menu {
                    Button(strings.ignoreTitle, action: onIgnore)
                    Button(strings.hideFor30DaysTitle, action: onSnooze)
                    Button(strings.hideSourceTitle, action: onHideSource)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .accessibilityLabel(strings.packageActionsAccessibilityLabel(displayName))
                .tip(strings.hideOrIgnoreTip, edge: .trailing)
                if isActivelyUpdating {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text(strings.runningTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                } else if isConfirming {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(confirmationPresentation.title)
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Button(strings.runTitle, action: onConfirmUpdate)
                                .controlSize(.small)
                                .disabled(isUpdating || isScanning)
                            Button(strings.cancelTitle, action: onCancelUpdate)
                                .controlSize(.small)
                        }
                        Text(confirmationPresentation.versionLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .multilineTextAlignment(.trailing)
                        Text(confirmationPresentation.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                        Text(confirmationPresentation.actionHint)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    .frame(maxWidth: 260, alignment: .trailing)
                    .tip("\(confirmationPresentation.detail) \(confirmationPresentation.actionHint)",
                         edge: .trailing)
                } else if isRecentlyUpdated {
                    // 특히 unknown 상태(Claude 플러그인)는 최신 판정이 불가해 버튼이 영구히 남는다 —
                    // "방금 성공" 마커로 버튼을 대체해 피드백을 준다
                    Text(strings.updatedTitle)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .tip(pkg.manager == .claudePlugin
                             ? strings.claudeRestartRequiredTip
                             : strings.updatedThisRunTip,
                             edge: .trailing)
                } else if showsUpdateButton {
                    Button(updateButtonTitle, action: onUpdate)
                        .controlSize(.small)
                        // 재검토 M4: brew는 pinned upgrade를 거부한다 — 버튼 비활성 + 안내
                        .disabled(isUpdating || isScanning || updateDisabledReason != nil)
                        .tip(updateButtonHelp, edge: .trailing)
                }
            }
            if let updateFailure, !updateFailure.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(strings.recentFailurePrefix): \(updateFailure)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    if let updateFailureTerminalCommand, !updateFailureTerminalCommand.isEmpty {
                        Button(strings.copyCommandTitle) {
                            copy(updateFailureTerminalCommand)
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .fixedSize()
                        .tip(strings.copyFailureRecoveryCommandTip, edge: .trailing)
                        .accessibilityLabel(strings.failureRecoveryCommandAccessibilityLabel(displayName))
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private var isMCP: Bool { pkg.metadata["kind"] == "mcp" }

    /// MCP 항목은 "mcp:" 접두 대신 태그 칩으로 구분한다
    private var displayName: String {
        isMCP && pkg.name.hasPrefix("mcp:") ? String(pkg.name.dropFirst(4)) : pkg.name
    }

    private var showsUpdateButton: Bool {
        if isMCP { return false } // MCP는 설정 항목 — 업데이트 실체는 다른 매니저/원격에 있다
        return pkg.status == .outdated || pkg.status == .unknown
    }

    private var updateDisabledReason: String? {
        if pkg.flags.contains(.runtime) {
            return strings.runtimeUpdateBlockedReason
        }
        if pkg.flags.contains(.pinned) {
            return strings.pinnedUpdateBlockedReason(pkg.name)
        }
        if pkg.manager == .claudePlugin, pkg.metadata["canUpdate"] == "false" {
            return strings.claudeCLIMissingUpdateReason
        }
        if pkg.statusReason == .inventoryOnly {
            return strings.inventoryOnlyUpdateReason
        }
        return nil
    }

    private var updateButtonTitle: String {
        if pkg.status == .unknown {
            return updatePolicy.requiresConfirmation
                ? strings.reviewTitle
                : strings.checkUpdateTitle
        }
        return updatePolicy.requiresConfirmation
            ? strings.reviewTitle
            : strings.updateTitle
    }

    private var updateButtonHelp: String {
        if let reason = updateDisabledReason { return reason }
        if pkg.status == .unknown {
            switch pkg.statusReason {
            case .updateCommandCheck:
                return strings.updateCommandCheckHelp
            case .latestUnavailable:
                return strings.latestUnavailableUpdateHelp
            case .inventoryOnly:
                return strings.inventoryOnlyUpdateReason
            case .recentlyUpdatedNeedsRestart:
                return strings.recentlyUpdatedNeedsRestartHelp
            case nil:
                break
            }
            return strings.genericUnknownUpdateHelp
        }
        if let reason = updatePolicy.reason { return reason }
        return ""
    }

    private var updatePolicy: UpdatePolicy {
        UpdatePolicy.evaluate(pkg)
    }

    private var confirmationPresentation: UpdateConfirmationPresentation {
        UpdateConfirmationPresentation.make(for: pkg, language: strings.language)
    }

    private var linkItems: [PackageLinkItem] {
        PackageLinkMetadata.referenceLinks(from: pkg.metadata).map { link in
            PackageLinkItem(title: title(for: link.kind),
                            systemImage: systemImage(for: link.kind),
                            url: link.url)
        }
    }

    private func title(for kind: PackageLinkMetadata.LinkKind) -> String {
        switch kind {
        case .package: return strings.packageLinkPackageTitle
        case .homepage: return strings.homepageTitle
        case .docs: return strings.docsTitle
        case .repository: return "GitHub"
        case .releaseNotes: return strings.releaseNotesTitle
        }
    }

    private func systemImage(for kind: PackageLinkMetadata.LinkKind) -> String {
        switch kind {
        case .package: return "shippingbox"
        case .homepage: return "house"
        case .docs: return "book"
        case .repository: return "chevron.left.forwardslash.chevron.right"
        case .releaseNotes: return "tag"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var versionText: String {
        switch pkg.status {
        case .outdated:
            return "\(pkg.current ?? "-") → \(pkg.latest ?? "-")"
        case .upToDate:
            return pkg.current ?? "-"
        case .unknown:
            if isMCP {
                // "(나열만)" 같은 앱 사정 대신 실체를 보여준다 (사용자 피드백)
                switch pkg.metadata["mcpKind"] {
                case "remote":
                    return strings.remoteMCPVersionText(detail: pkg.metadata["mcpDetail"] ?? "-")
                case "local":
                    return strings.localMCPVersionText(detail: pkg.metadata["mcpDetail"] ?? "-")
                default:
                    return strings.mcpConfigurationText
                }
            }
            if let lastUpdated = pkg.metadata["lastUpdated"].map({ String($0.prefix(10)) }) {
                return "\(pkg.current ?? "-") · \(unknownReasonText) · \(lastUpdated)"
            }
            if let current = pkg.current { return "\(current) · \(unknownReasonText)" }
            return unknownReasonText
        }
    }

    private var unknownReasonText: String {
        switch pkg.statusReason {
        case .updateCommandCheck:
            return strings.unknownUpdateCommandCheckText
        case .latestUnavailable:
            return strings.latestUnavailableText
        case .inventoryOnly:
            return strings.inventoryText
        case .recentlyUpdatedNeedsRestart:
            return strings.restartRequiredText
        case nil:
            return strings.latestVersionNeedsCheckingText
        }
    }

    private var riskColor: Color {
        guard pkg.status == .outdated else { return .gray.opacity(0.4) }
        switch pkg.risk {
        case .high: return .red
        case .medium: return .yellow
        case .low: return .green
        case nil: return .gray
        }
    }

    private var riskAccessibilityLabel: String {
        guard pkg.status == .outdated else {
            return strings.notUpdateTargetRiskTitle
        }
        switch pkg.risk {
        case .high: return strings.riskHighTitle
        case .medium: return strings.riskMediumTitle
        case .low: return strings.riskLowTitle
        case nil: return strings.riskUnknownTitle
        }
    }
}

private struct PackageLinkItem: Identifiable {
    let title: String
    let systemImage: String
    let url: URL

    var id: String { "\(title):\(url.absoluteString)" }
}
