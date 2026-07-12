import SwiftUI
import Sync

/// A sheet listing every cloud (Claude) Filing scan with its tokens and estimated cost, plus
/// lifetime totals and a clear button.
struct FilingSpendHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FilingSpendEntry] = []
    @State private var totals = FilingSpendTotals()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cloud Filing Spend").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            HStack(spacing: 24) {
                stat(FilingSpendFormat.cost(totals.costUSD), "total")
                stat(FilingSpendFormat.tokens(totals.tokens), "tokens")
                stat("\(totals.scans)", "cloud scans")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            Divider()

            if entries.isEmpty {
                Text("No cloud scans yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries.reversed()) { entry in row(entry) }
            }

            Divider()

            HStack {
                Button("Clear History", role: .destructive) {
                    FilingSpendStore.clear()
                    reload()
                }
                .disabled(totals.scans == 0)
                Spacer()
                Text("Estimates from list prices — the Anthropic Console is authoritative.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding()
        }
        .frame(width: 540, height: 440)
        .onAppear(perform: reload)
    }

    private func reload() {
        entries = FilingSpendStore.entries()
        totals = FilingSpendStore.totals()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ entry: FilingSpendEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                Text("\(FilingSpendFormat.model(entry.model)) · \(entry.fileCount) files · placed \(entry.placedCount)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(FilingSpendFormat.cost(entry.estimatedCostUSD))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text(FilingSpendFormat.tokens(entry.totalTokens))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
