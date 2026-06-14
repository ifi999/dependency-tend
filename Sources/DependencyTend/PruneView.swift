import AppCore
import Engine
import SwiftUI

/// 정리(가지치기) 뷰 — 파괴적 동작은 업데이트 화면과 분리된 이 공간에서만 (정리 스펙 §2-③).
/// 제안은 증거와 함께, 차단 항목은 사유와 함께, 삭제는 장부 기록과 함께.
struct PruneView: View {
    @ObservedObject var model: AppViewModel
    let strings: AppStrings
    @State private var confirming: PruneSuggestion?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.pruneSectionTitle).font(.subheadline).bold()
            if model.pruneSuggestions.isEmpty && model.orphanNames.isEmpty
                && model.pruneSourceHealthMessages.isEmpty {
                Text(strings.noPruneLeftoversTitle).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.pruneSourceHealthMessages, id: \.self) { message in
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(model.pruneSuggestions) { suggestion in
                suggestionRow(suggestion)
            }
            if !model.orphanNames.isEmpty { orphanRow }
            if let suggestion = confirming { confirmBar(suggestion) }
            if let orphanConfirmation = model.orphanPruneConfirmation {
                orphanConfirmBar(orphanConfirmation)
            }
            if !model.recentRemovals.isEmpty {
                Text(strings.recentRemovalsTitle).font(.caption).bold()
                    .foregroundStyle(.secondary).padding(.top, 4)
                // 최신 10건만 — 장부 무한 누적이 패널을 비대하게 만들지 않게 (재검증 반영)
                ForEach(Array(model.recentRemovals.suffix(10).reversed())) { record in
                    removalRow(record)
                }
            }
        }
        .task { await model.refreshOrphans() }
    }

    private func suggestionRow(_ suggestion: PruneSuggestion) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(suggestion.target.name)  \(suggestion.target.current ?? "-") · \(suggestion.target.metadata["tree"] ?? "")")
                    .font(.callout).lineLimit(1)
                // 증거 기반 제안 — 결론만 말하지 않는다 (정리 스펙 §2-②)
                Text(suggestion.evidence).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let reason = suggestion.blockReason {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    .tip(reason, edge: .trailing)
            } else {
                Button(strings.deleteTitle) { confirming = suggestion }
                    .controlSize(.small)
                    .disabled(model.isUpdating)
                    .tip(strings.deleteSuggestionTip, edge: .trailing)
            }
        }
    }

    private var orphanRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("고아 의존성 \(model.orphanNames.count)개").font(.callout)
                Text(model.orphanNames.prefix(5).joined(separator: ", ")
                     + (model.orphanNames.count > 5 ? " 외 \(model.orphanNames.count - 5)개" : ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(strings.cleanupTitle) { model.requestPruneOrphans() }
                .controlSize(.small)
                .disabled(model.isUpdating)
                .tip(strings.orphanCleanupTip, edge: .trailing)
        }
    }

    private func confirmBar(_ suggestion: PruneSuggestion) -> some View {
        HStack(spacing: 8) {
            Text(strings.confirmDeleteTitle(name: suggestion.target.name,
                                            tree: suggestion.target.metadata["tree"] ?? ""))
                .font(.caption).foregroundStyle(.red).lineLimit(1)
            Spacer()
            Button(strings.deleteTitle) {
                confirming = nil
                Task { await model.prune(suggestion) }
            }
            .disabled(model.isUpdating) // 행 버튼과 동일한 이중 클릭 방어 (재검증 반영)
            Button(strings.cancelTitle) { confirming = nil }
                .disabled(model.isUpdating)
        }
        .padding(6)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func orphanConfirmBar(_ names: [String]) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.orphanCleanupConfirmationTitle(names.count))
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
                Text(orphanPreview(names))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(strings.runBrewAutoremoveTitle) { Task { await model.pruneOrphans() } }
                .disabled(model.isUpdating)
            Button(strings.cancelTitle) { model.cancelPruneOrphans() }
                .disabled(model.isUpdating)
        }
        .padding(6)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func orphanPreview(_ names: [String]) -> String {
        let visible = names.prefix(8).joined(separator: ", ")
        let remaining = names.count - min(names.count, 8)
        return strings.orphanPreview(visible: visible, remaining: remaining)
    }

    private func removalRow(_ record: RemovalRecord) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(record.name) \(record.version ?? "")").font(.caption).lineLimit(1)
                HStack(spacing: 3) {
                    Text("\(record.tree ?? "") ·")
                    Text(record.date, format: .relative(presentation: .named))
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(strings.restoreTitle) { Task { await model.restore(record) } }
                .controlSize(.small)
                .disabled(model.isUpdating)
                .tip(strings.restoreRemovalTip(record.restore.displayString), edge: .trailing)
        }
    }
}
