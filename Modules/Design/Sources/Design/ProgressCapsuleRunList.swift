import SwiftUI

/// One run in the capsule's list — its snapshot, what it is, when it started and how it stops.
public struct ProgressCapsuleListedRun: Identifiable {
    /// Stable for the run's life, so its row keeps its place while its numbers change.
    public let id: String
    public var run: ProgressCapsuleRun
    /// The run's kind, as a symbol: a file operation, a PDF tool, Save as PDF.
    public var symbol: String
    public var startedAt: Date?
    /// `nil` for a run with nothing to stop between — one file being saved as PDF.
    public var onCancel: (() -> Void)?

    public init(id: String, run: ProgressCapsuleRun, symbol: String, startedAt: Date?,
                onCancel: (() -> Void)?) {
        self.id = id
        self.run = run
        self.symbol = symbol
        self.startedAt = startedAt
        self.onCancel = onCancel
    }
}

/// **Every run going at once, each with its own Stop** (TE217, TE219) — what the capsule's count
/// button opens while two or more runs share it. Newest first, as the capsule draws them.
///
/// The newest run's Stop is the default button, and ⌘. presses it too (decision CJ): ⌘. on the
/// capsule opened this list, so the same key again stops the run the capsule was drawing, and
/// never one the reader could not see named.
public struct ProgressCapsuleRunList: View {
    let runs: [ProgressCapsuleListedRun]

    public init(runs: [ProgressCapsuleListedRun]) {
        self.runs = runs
    }

    public static let width: CGFloat = 380

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Running · \(runs.count)")
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(runs.enumerated()), id: \.element.id) { index, listed in
                if index > 0 { Divider().padding(.leading, 12) }
                ProgressCapsuleRunRow(listed: listed, isNewest: index == 0)
            }
        }
        .padding(.bottom, 6)
        .frame(width: Self.width, alignment: .leading)
        .background {
            // ⌘. stops the newest, as Return does — a second key on its Stop, which a button
            // cannot carry, so it rides on one of its own that draws nothing.
            if let newest = runs.first, let stop = newest.onCancel {
                Button("", action: stop)
                    .keyboardShortcut(AppChord.cancelOperation.key, modifiers: AppChord.cancelOperation.modifiers)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct ProgressCapsuleRunRow: View {
    let listed: ProgressCapsuleListedRun
    let isNewest: Bool

    var body: some View {
        let run = listed.run
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: listed.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(run.note ?? run.title)
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    ProgressView(value: run.fraction, total: 1)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                    if run.total > 0 {
                        Text(ProgressCapsule.formattedCount(completed: run.completed, total: run.total))
                            .scaledFont(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    if let detail = run.detail {
                        Text(detail)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let startedAt = listed.startedAt {
                        Text("started \(Text(startedAt, style: .relative)) ago")
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            if let stop = listed.onCancel {
                stopButton(stop, run: run)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.summary)
    }

    @ViewBuilder private func stopButton(_ stop: @escaping () -> Void, run: ProgressCapsuleRun) -> some View {
        if isNewest {
            Button(run.cancelTitle, action: stop)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .accentedProminent()
                .help(ShortcutHint.tooltip(run.cancelHelp, AppChord.cancelOperation.display))
        } else {
            Button(run.cancelTitle, action: stop)
                .controlSize(.small)
                .help(run.cancelHelp)
        }
    }
}
