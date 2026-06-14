import AppKit
import AppCore
import Engine
import SwiftUI

/// 패널 내 인라인 로그 섹션 (sheet 아님 — 재검토 B2)
struct LogView: View {
    let lines: [String]
    let history: [UpdateHistoryEntry]
    let strings: AppStrings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            currentRunSection
            historySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentRunSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(strings.currentRunLogTitle)
                    .font(.caption)
                    .bold()
                Spacer()
                Button(strings.copyLogTitle) { copy(logText) }
                    .disabled(lines.isEmpty)
            }
            Text(lines.isEmpty ? strings.noLogText : logText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.updateHistoryTitle)
                .font(.caption)
                .bold()
            if history.isEmpty {
                Text(strings.noHistoryText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history) { entry in
                    historyRow(entry)
                }
            }
        }
    }

    private func historyRow(_ entry: UpdateHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label(entry.name, systemImage: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(entry.succeeded ? .green : .red)
                Text(entry.manager.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(versionText(for: entry))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("$ \(entry.command)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button(strings.copyCommandTitle) { copy(entry.command) }
            }
            if let output = outputText(for: entry) {
                Text(output)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(7)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var logText: String {
        lines.joined(separator: "\n")
    }

    private func versionText(for entry: UpdateHistoryEntry) -> String {
        let before = entry.previousVersion ?? "unknown"
        let after = entry.targetVersion ?? "unknown"
        return "\(before) → \(after) · exit \(entry.exitCode)"
    }

    private func outputText(for entry: UpdateHistoryEntry) -> String? {
        let stdout = snippet(entry.stdout)
        let stderr = snippet(entry.stderr)
        let parts = [
            stdout.isEmpty ? nil : "stdout: \(stdout)",
            stderr.isEmpty ? nil : "stderr: \(stderr)"
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    private func snippet(_ text: String, limit: Int = 180) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
