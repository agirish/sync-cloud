import SwiftUI
import Sync
import Events

/// The docked review card shown above the differences table during an inline review session:
/// what the current item is, what the copy would replace (sizes, dates, deltas, warnings), and
/// the per-item actions. Deliberately dumb about the queue: it renders the `session` value and
/// reports intents through closures — the host owns every session mutation and the in-flight
/// state, so a decision landing after the session was torn down (Exit mid-copy) or after the
/// user jumped rows can be applied — or dropped — with the full picture. The card's own async
/// work is display-only: statting facts and hashing for the per-item Verify.
struct ReviewCardView: View {
    let session: ReviewSession
    let paneNames: PaneProviderNames
    let accent: Color
    /// The host's file manager (test seam parity with the sync paths the decisions drive).
    let fileManager: FileManaging
    let onQuickLook: ((URL) -> Void)?
    /// True while the host runs the current item's copy/move; gates every decision entry point.
    let isActing: Bool
    /// Bumped by the host whenever a review-table row is clicked: the click hands key focus to
    /// the Table (a sibling), which would strand the card's key handlers — the card takes focus
    /// back so ⏎/⌫/␣/esc keep working. (Trade-off: the table's selection highlight always
    /// renders in its inactive style; the Status column marks the current row regardless.)
    let focusNudge: Int
    /// Copy/Move the given item (the host records the outcome from what actually happened).
    let onPrimary: (FileDifference) -> Void
    /// Skip the given item.
    let onSkip: (FileDifference) -> Void
    /// Report a per-item content-verification verdict.
    let onVerdict: (UUID, ReviewSession.VerifyVerdict) -> Void
    /// Called on Esc; the host exits the session (the header's Exit button is the other path).
    let onExit: () -> Void

    @State private var facts = ReviewCardModel.Facts()
    @State private var isVerifying = false
    @FocusState private var focused: Bool

    var body: some View {
        if let item = session.current {
            card(for: item)
        }
    }

    @ViewBuilder
    private func card(for item: FileDifference) -> some View {
        let model = ReviewCardModel.make(
            difference: item, facts: facts, paneNames: paneNames, isMove: session.isMove)
        VStack(alignment: .leading, spacing: 10) {
            headerRow(item: item, model: model)
            factsRow(model: model)
            if let warningText = model.warningText {
                statusRow(warningText, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let verdict = session.verdict(for: item.id) {
                verdictRow(verdict)
            }
            actionsRow(item: item, model: model)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accent.opacity(0.4), lineWidth: 1)
        )
        .tint(accent)
        // The card is the review's key-event anchor: focusable so the keyboard loop works the
        // moment the session starts, deliberately NOT window-level `.keyboardShortcut`s — a key
        // equivalent is consulted before the first responder and would eat Return/Space typed
        // into fields elsewhere in the window (the Settings overlay; see the pane Quick Look
        // comment in ContentView+SplitLayout).
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.return) { keyAct { onPrimary(item) } }
        .onKeyPress(.delete) { keyAct { onSkip(item) } }
        .onKeyPress(.space) { quickLookKeyPressed(item) }
        .onKeyPress(.escape) {
            onExit()
            return .handled
        }
        .task(id: item.id) {
            // Deferred one turn: a FocusState write in the same transaction that inserts the
            // view can be silently dropped (same gotcha as the header search field).
            Task { @MainActor in focused = true }
            facts = ReviewCardModel.Facts()
            let loaded = await Self.loadFacts(for: item)
            // Stale-guard: the user may have decided/jumped while the stat ran.
            if !Task.isCancelled, session.current?.id == item.id {
                facts = loaded
            }
        }
        .onChange(of: focusNudge) { _, _ in
            Task { @MainActor in focused = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reviewing \(model.parentPath.isEmpty ? model.fileName : model.parentPath + "/" + model.fileName)")
    }

    // MARK: Rows

    private func headerRow(item: FileDifference, model: ReviewCardModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: DifferenceGlyph.symbol(for: item.type, filled: true))
                .foregroundStyle(DifferenceGlyph.color(for: item.type))
                .symbolRenderingMode(.hierarchical)
            if !model.parentPath.isEmpty {
                Text(model.parentPath + "/")
                    .foregroundStyle(.secondary)
            }
            Text(model.fileName)
                .fontWeight(.semibold)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text("\(model.directionText) · \(model.directionDetail)")
                .font(.caption.weight(.medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(accent.opacity(0.12)))
                .layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    @ViewBuilder
    private func factsRow(model: ReviewCardModel) -> some View {
        HStack(alignment: .top, spacing: 20) {
            if let newItemText = model.newItemText {
                Text(newItemText)
                    .foregroundStyle(.secondary)
            } else {
                factGroup(label: model.sourceLabel, size: model.sourceSizeText, date: model.sourceDateText)
                if let destinationLabel = model.destinationLabel {
                    factGroup(label: destinationLabel, size: model.destinationSizeText, date: model.destinationDateText)
                }
                if let deltaText = model.deltaText {
                    let tint: Color = model.sourceIsOlder ? .orange : .green
                    Text(deltaText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(tint.opacity(0.12)))
                }
            }
        }
        .font(.callout)
    }

    private func factGroup(label: String, size: String?, date: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(size ?? "—")
                    .fontWeight(.medium)
                Text("·")
                    .foregroundStyle(.tertiary)
                // Dates stat asynchronously; the placeholder keeps the row from jumping.
                Text(date ?? "…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .monospacedDigit()
        }
    }

    @ViewBuilder
    private func verdictRow(_ verdict: ReviewSession.VerifyVerdict) -> some View {
        switch verdict {
        case .identical:
            statusRow("Contents verified identical — only the dates differ.", systemImage: "checkmark.seal.fill", tint: .green)
        case .differed:
            statusRow("Contents differ — this is a real change.", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .unverifiable:
            statusRow("Couldn't verify (a side was unreadable or too large to hash).", systemImage: "questionmark.circle", tint: .secondary)
        }
    }

    private func statusRow(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(tint)
    }

    private func actionsRow(item: FileDifference, model: ReviewCardModel) -> some View {
        HStack(spacing: 8) {
            Button(model.primaryVerb) {
                onPrimary(item)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isActing)
            Button("Skip") {
                onSkip(item)
            }
            .buttonStyle(.bordered)
            .disabled(isActing)
            if let onQuickLook {
                ForEach(DifferenceRowMenu.existingSides(for: item, paneNames: paneNames), id: \.paneName) { side in
                    Button {
                        onQuickLook(URL(fileURLWithPath: side.path))
                    } label: {
                        Label(side.paneName, systemImage: "eye")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .help("Quick Look the \(side.paneName) copy")
                }
            }
            if model.canVerify {
                Button {
                    performVerify(item)
                } label: {
                    Label("Verify", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderless)
                .disabled(isVerifying)
                .help("Checksum both sides to confirm whether the contents actually differ")
            }
            if isActing || isVerifying {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Text("⏎ \(model.primaryVerb.lowercased()) · ⌫ skip · ␣ quick look · esc exit")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonBorderShape(.capsule)
    }

    // MARK: Actions

    /// Runs a key-triggered decision unless one is already in flight; always consumes the key
    /// (an ignored Return/Delete rattling around the window helps nobody mid-review).
    private func keyAct(_ action: () -> Void) -> KeyPress.Result {
        if !isActing { action() }
        return .handled
    }

    private func quickLookKeyPressed(_ item: FileDifference) -> KeyPress.Result {
        guard let onQuickLook else { return .ignored }
        onQuickLook(URL(fileURLWithPath: item.reviewSourcePath))
        return .handled
    }

    /// Per-item content check, reusing the bulk Verify's hashing — but reporting the verdict to
    /// the host instead of feeding `verifiedIdenticalForCopy` (whose bulk copy-to-match-dates
    /// dialog would be wrong mid-review). Read-only, so a verdict landing late is harmless —
    /// the host drops it if the session is gone.
    private func performVerify(_ item: FileDifference) {
        guard !isVerifying else { return }
        isVerifying = true
        Task { @MainActor in
            let same = await FileContentVerifier.filesHaveSameContent(
                leftPath: item.leftItemPath,
                rightPath: item.rightItemPath,
                fileManager: fileManager
            )
            let verdict: ReviewSession.VerifyVerdict =
                same == true ? .identical : (same == false ? .differed : .unverifiable)
            onVerdict(item.id, verdict)
            isVerifying = false
        }
    }

    // MARK: Facts

    /// How many destination-folder descendants to count before giving up ("1000+ items") —
    /// the number is orientation for the folder-replace warning, not an audit.
    private nonisolated static let childCountCap = 1000

    /// Stats what `FileDifference` doesn't carry: both sides' modification dates, and — for a
    /// folder about to be replaced — how much it contains. Off the main actor: on network/cloud
    /// volumes a synchronous stat can block for seconds (same reason as `statExists`).
    nonisolated static func loadFacts(for difference: FileDifference) async -> ReviewCardModel.Facts {
        let sourcePath = difference.reviewSourcePath
        let destinationPath = difference.reviewDestinationPath
        let needsDestination = difference.type == .differentDates
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var facts = ReviewCardModel.Facts()
            facts.sourceModified = (try? fm.attributesOfItem(atPath: sourcePath))?[.modificationDate] as? Date
            guard needsDestination else { return facts }
            facts.destinationModified = (try? fm.attributesOfItem(atPath: destinationPath))?[.modificationDate] as? Date
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: destinationPath, isDirectory: &isDirectory), isDirectory.boolValue {
                facts.destinationIsDirectory = true
                if let enumerator = fm.enumerator(atPath: destinationPath) {
                    var count = 0
                    while enumerator.nextObject() != nil {
                        count += 1
                        if count >= childCountCap {
                            facts.destinationChildCountCapped = true
                            break
                        }
                    }
                    facts.destinationChildCount = count
                }
            }
            return facts
        }.value
    }
}
