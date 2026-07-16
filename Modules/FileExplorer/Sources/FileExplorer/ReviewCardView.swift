import SwiftUI
import Sync
import Events
import Design

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

    /// Facts tagged with the item they were statted for: the card renders empty facts — never
    /// the PREVIOUS item's dates/warnings — for the frame(s) between an advance and `.task(id:)`
    /// running (a reset inside the task body lands one render too late, flashing item A's
    /// folder-replace banner on item B during fast ⏎-driven review).
    @State private var loadedFacts: (itemID: UUID, facts: ReviewCardModel.Facts)? = nil
    @State private var isVerifying = false
    @FocusState private var focused: Bool

    var body: some View {
        if let item = session.current {
            card(for: item)
        }
    }

    @ViewBuilder
    private func card(for item: FileDifference) -> some View {
        let facts = loadedFacts?.itemID == item.id ? loadedFacts!.facts : ReviewCardModel.Facts()
        let model = ReviewCardModel.make(
            difference: item, facts: facts, paneNames: paneNames, isMove: session.isMove)
        VStack(alignment: .leading, spacing: 10) {
            headerRow(item: item, model: model)
            factsRow(model: model)
            if let warningText = model.warningText {
                statusRow(warningText, systemImage: "exclamationmark.triangle.fill", tint: SemanticColor.warning)
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
        .onKeyPress(.return) {
            // Both gates: a copy mid-verify would overwrite the destination while the hash
            // reads it (same exclusion the bulk paths enforce via isVerifyAllRunning).
            if !isActing && !isVerifying { onPrimary(item) }
            return .handled
        }
        // .down only, no .repeat: Skip is synchronous and decided rows are unrevisitable, so
        // a held-a-beat-too-long ⌫ must not mass-skip the queue.
        .onKeyPress(keys: [.delete], phases: .down) { _ in
            if !isActing { onSkip(item) }
            return .handled
        }
        .onKeyPress(.space) { quickLookKeyPressed(item) }
        .onKeyPress(.escape) {
            onExit()
            return .handled
        }
        .task(id: item.id) {
            isVerifying = false
            // Deferred one turn: a FocusState write in the same transaction that inserts the
            // view can be silently dropped (same gotcha as the header search field).
            Task { @MainActor in
                // Don't yank key focus mid-typing: an async outcome can advance the item while
                // the user is in a text field (Settings overlay, rename prompt) — claiming
                // focus then would redirect their next Return into a Copy. Field editors are
                // NSTextView, so this covers every AppKit text-input surface.
                if !(NSApp.keyWindow?.firstResponder is NSTextView) {
                    focused = true
                }
            }
            let loaded = await Self.loadFacts(for: item, fileManager: fileManager)
            // Stale-guard: the user may have decided/jumped while the stat ran.
            if !Task.isCancelled, session.current?.id == item.id {
                loadedFacts = (item.id, loaded)
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
        HStack(spacing: 8) {
            // Real file icon in a tile (mockup style), not the diff-type glyph — the direction
            // chip's "new / replaces existing" carries the type signal here.
            Image(nsImage: FileIconCache.icon(name: model.fileName, isDirectory: model.isFolder))
                .resizable()
                .frame(width: 22, height: 22)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.quaternary.opacity(0.5))
                )
            // Name first, dimmed parent path after — the decision is about the file, the
            // location is context.
            Text(model.fileName)
                .fontWeight(.semibold)
                .layoutPriority(1)
            if !model.parentPath.isEmpty {
                Text(model.parentPath + "/")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("\(model.directionText) · \(model.directionDetail)")
                .font(.caption.weight(.medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(accent.opacity(0.14)))
                .layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    @ViewBuilder
    private func factsRow(model: ReviewCardModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            if let newItemText = model.newItemText {
                Text(newItemText)
                    .foregroundStyle(.secondary)
            } else {
                inlineFact(label: model.primaryVerb == "Move" ? "Moving" : "Copying", size: model.sourceSizeText, date: model.sourceDateText)
                    .help(model.sourceLabel)
                if model.destinationLabel != nil {
                    inlineFact(label: "Replaces", size: model.destinationSizeText, date: model.destinationDateText)
                        .help(model.destinationLabel ?? "")
                }
                if let deltaText = model.deltaText {
                    let tint: Color = model.sourceIsOlder ? SemanticColor.warning : SemanticColor.success
                    Text(deltaText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
                }
            }
        }
        .font(.callout)
    }

    /// One inline fact run: "Copying: **2.4 MB** · Jul 8, 6:12 PM" (mockup style). The date
    /// placeholder holds the width while the stat loads so the row doesn't jump.
    private func inlineFact(label: String, size: String?, date: String?) -> Text {
        (Text("\(label): ").foregroundStyle(.secondary)
            + Text(size ?? "—").fontWeight(.semibold)
            + Text(" · \(date ?? "…")").foregroundStyle(.secondary))
            .monospacedDigit()
    }

    @ViewBuilder
    private func verdictRow(_ verdict: ReviewSession.VerifyVerdict) -> some View {
        switch verdict {
        case .identical:
            statusRow("Contents verified identical — only the dates differ.", systemImage: "checkmark.seal.fill", tint: SemanticColor.success)
        case .differed:
            statusRow("Contents differ — this is a real change.", systemImage: "exclamationmark.triangle.fill", tint: SemanticColor.warning)
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
            .disabled(isActing || isVerifying)
            Button("Skip") {
                onSkip(item)
            }
            .buttonStyle(.bordered)
            .disabled(isActing)
            if let onQuickLook {
                // One button, source side (same as ␣) — mockup style. The destination copy is
                // a right-click away on the row (Quick Look per side in the context menu).
                Button {
                    onQuickLook(URL(fileURLWithPath: item.reviewSourcePath))
                } label: {
                    Label("Quick Look", systemImage: "doc.viewfinder")
                }
                .buttonStyle(.borderless)
                .help("Quick Look the copy being \(session.isMove ? "moved" : "copied") (space) — right-click the row for the other side")
            }
            if model.canVerify {
                Button {
                    performVerify(item)
                } label: {
                    Label("Verify", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderless)
                // isActing too: hashing a destination the in-flight copy is overwriting
                // would record a verdict over half-written content.
                .disabled(isVerifying || isActing)
                .help("Checksum both sides to confirm whether the contents actually differ")
            }
            if isActing || isVerifying {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            keyHints(model: model)
        }
        .buttonBorderShape(.capsule)
    }

    /// The mockup's key-cap hint row: bordered key chips with plain-text verbs between.
    private func keyHints(model: ReviewCardModel) -> some View {
        HStack(spacing: 5) {
            keyCap("return")
            hintVerb(model.primaryVerb.lowercased())
            hintDot()
            keyCap("⌫")
            hintVerb("skip")
            hintDot()
            keyCap("space")
            hintVerb("quick look")
            hintDot()
            keyCap("esc")
            hintVerb("exit")
        }
    }

    private func keyCap(_ symbol: String) -> some View {
        Text(symbol)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }

    private func hintVerb(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func hintDot() -> some View {
        Text("·")
            .font(.caption2)
            .foregroundStyle(.quaternary)
    }

    // MARK: Actions

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
    /// volumes a synchronous stat can block for seconds (same reason as `statExists`). Uses the
    /// injected `FileManaging` so the facts describe the same disk the copy and Verify run
    /// against (a mocked manager must not have the warning read the real disk).
    nonisolated static func loadFacts(for difference: FileDifference, fileManager: FileManaging) async -> ReviewCardModel.Facts {
        let sourcePath = difference.reviewSourcePath
        let destinationPath = difference.reviewDestinationPath
        let needsDestination = difference.type == .differentDates
        return await Task.detached(priority: .userInitiated) {
            var facts = ReviewCardModel.Facts()
            facts.sourceModified = (try? fileManager.attributesOfItem(atPath: sourcePath))?[.modificationDate] as? Date
            guard needsDestination else { return facts }
            facts.destinationModified = (try? fileManager.attributesOfItem(atPath: destinationPath))?[.modificationDate] as? Date
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: destinationPath, isDirectory: &isDirectory), isDirectory.boolValue {
                facts.destinationIsDirectory = true
                let destinationURL = URL(fileURLWithPath: destinationPath)
                if let enumerator = fileManager.enumerator(at: destinationURL, includingPropertiesForKeys: nil, options: [], errorHandler: nil) {
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
