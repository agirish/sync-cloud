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
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
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
    /// Report a per-item content-verification verdict. The last parameter is the token of the
    /// session the verify was started under (`ReviewSession.sessionToken`), so the host can
    /// drop a verdict whose session was exited and replaced while the hash ran.
    let onVerdict: (UUID, ReviewSession.VerifyVerdict, UUID) -> Void
    /// Called on Esc; the host exits the session (the header's Exit button is the other path).
    let onExit: () -> Void

    /// Facts tagged with the item they were statted for: the card renders empty facts — never
    /// the PREVIOUS item's dates/warnings — for the frame(s) between an advance and `.task(id:)`
    /// running (a reset inside the task body lands one render too late, flashing item A's
    /// folder-replace banner on item B during fast ⏎-driven review).
    @State private var loadedFacts: (itemID: UUID, facts: ReviewCardModel.Facts)? = nil
    @State private var isVerifying = false
    /// Liveness token for the in-flight Verify. Re-minted wherever `.task(id: item.id)` resets
    /// state, so a verify completing after the card advanced compares its captured token against
    /// the LIVE `@State` (the completion closure captures the view struct, whose `@State` reads
    /// go through the live storage box) and drops its SPINNER write — otherwise a large pair's
    /// late return would clear the CURRENT item's spinner mid-hash and defeat the re-entrancy
    /// guard. Only the spinner: the verdict is reported either way and guarded on the session
    /// token instead (see `applyVerifyCompletion`).
    /// NOT comparable to a captured copy of itself: that is a tautology (the inert guard
    /// ColumnPreviewColumn.watchDownload shipped with) — one side must be the live property.
    @State private var verifyToken = UUID()
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
            verifyToken = UUID()   // orphan any verify still hashing the previous item
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
        // The keys, stated on the card itself rather than left to the hidden hint row below.
        // `ReviewKeyHints` renders at zero opacity when the reveal is off, and whether SwiftUI
        // drops a zero-opacity view from the accessibility tree is not something this project can
        // verify — there is no assistive client under `swift test`, so any test of it would pass
        // vacuously either way. So the guarantee is made here, where it does not depend on the
        // answer: this hint is unconditional and order-independent.
        .accessibilityHint(ReviewCardModel.keyHintSpeech(primaryVerb: model.primaryVerb))
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
                .scaledFont(.caption.weight(.medium))
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
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
                }
            }
        }
        .scaledFont(.callout)
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
        .scaledFont(.caption)
        .foregroundStyle(tint)
    }

    private func actionsRow(item: FileDifference, model: ReviewCardModel) -> some View {
        HStack(spacing: 8) {
            Button(model.primaryVerb) {
                onPrimary(item)
            }
            .buttonStyle(.borderedProminent)
            .chromeHover()
            .disabled(isActing || isVerifying)
            Button("Skip") {
                onSkip(item)
            }
            .chromeButtonStyle(glassLevel)
            .chromeHover(tint: accent)
            .disabled(isActing)
            if let onQuickLook {
                // One button, source side (same as ␣) — mockup style. The destination copy is
                // a right-click away on the row (Quick Look per side in the context menu).
                Button {
                    onQuickLook(URL(fileURLWithPath: item.reviewSourcePath))
                } label: {
                    Label("Quick Look", systemImage: "doc.viewfinder")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverAffordance(.segment, tint: accent))
                .shortcutKeycap("␣")
                .help(ShortcutHint.tooltip(
                    "Quick Look the copy being \(session.isMove ? "moved" : "copied") — right-click the row for the other side",
                    "␣"))
            }
            if model.canVerify {
                Button {
                    performVerify(item)
                } label: {
                    Label("Verify", systemImage: "checkmark.shield")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverAffordance(.segment, tint: accent))
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
            ReviewKeyHints(primaryVerb: model.primaryVerb)
        }
        .buttonBorderShape(.capsule)
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
        // Both captured BEFORE the unbounded hash: `token` to compare against the live @State
        // after it, `sessionToken` so the host can drop a verdict from a replaced session.
        let token = verifyToken
        let sessionToken = session.sessionToken
        Task { @MainActor in
            let same = await FileContentVerifier.filesHaveSameContent(
                leftPath: item.leftItemPath,
                rightPath: item.rightItemPath,
                fileManager: fileManager,
                // The same session cache Verify All and the lens scans use. Without it this path
                // only *said* it reused the bulk hashing: stepping back to an item, or verifying
                // one Verify All had already hashed, re-read and re-hashed both sides from disk.
                // Keyed on (path, mtime, size), so an edited file is bypassed rather than served.
                cache: ContentHashCache.shared
            )
            // `verifyToken` here is a live @State read (the closure's captured struct reads
            // through the live storage box), never a captured copy — see `verifyToken`. It
            // decides ONLY the spinner write; the verdict is reported either way.
            Self.applyVerifyCompletion(
                sameContent: same,
                liveToken: verifyToken,
                startedToken: token,
                report: { onVerdict(item.id, $0, sessionToken) },
                clearSpinner: { isVerifying = false }
            )
        }
    }

    /// Routes a finished Verify: what the completion is allowed to write back to the card.
    ///
    /// The verdict is reported UNCONDITIONALLY. It is already session-guarded downstream —
    /// `onVerdict` carries the session token and `ReviewSessionStore.recordVerdict` drops a
    /// verdict whose session was replaced — so a completion from a card that has since advanced
    /// still describes the item it actually hashed, and dropping it here would throw away a
    /// legitimate result: verify a large pair, click another row, click back, and `.task(id:)`
    /// has re-minted the token twice, leaving the user with no spinner and no answer.
    ///
    /// The SPINNER is what the token guards. `isVerifying` belongs to whatever item the card
    /// shows now; once `.task(id:)` re-minted the token it has already reset the flag for the
    /// NEW item, and a late completion writing `false` would clear that item's spinner mid-hash
    /// (the D14 bug) — so only a completion whose token is still live may touch it.
    ///
    /// Split out of the view so the rule is testable: the call site above is a single call, so
    /// the two decisions cannot drift apart without changing this function.
    /// - Parameters:
    ///   - sameContent: `FileContentVerifier`'s answer — nil when a side couldn't be hashed.
    ///   - liveToken: the card's CURRENT `verifyToken`.
    ///   - startedToken: the token captured when this verify started.
    static func applyVerifyCompletion(
        sameContent: Bool?,
        liveToken: UUID,
        startedToken: UUID,
        report: (ReviewSession.VerifyVerdict) -> Void,
        clearSpinner: () -> Void
    ) {
        let verdict: ReviewSession.VerifyVerdict =
            sameContent == true ? .identical : (sameContent == false ? .differed : .unverifiable)
        report(verdict)
        guard liveToken == startedToken else { return }
        clearSpinner()
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

/// The review card's key-cap hint row: bordered key chips with plain-text verbs between.
///
/// Permanent until now, which made it teaching clutter after the first session — the review card
/// was the one surface in the app that shouted its shortcuts at everyone, forever. It joins the
/// ⌥-hold reveal instead: **empty by default, keycaps only while ⌥ is held.**
///
/// Hidden with `.opacity`, deliberately, and not by branching the row out of the layout. The card
/// must not resize when ⌥ goes down — a card that grew a row under a settled pointer would move
/// the Copy button out from under it, mid-review, which is the one thing this feature promises
/// never to do. Opacity reserves the row's full footprint in both states, so there is no height to
/// gain and no width for the enclosing `Spacer` to redistribute.
///
/// **Accessibility does not rely on this row.** Whether SwiftUI keeps a zero-opacity view in the
/// accessibility tree is not something this project can check — there is no assistive client under
/// `swift test`, so a test either way would pass vacuously — so the card states the keys itself in
/// an unconditional `.accessibilityHint`. A VoiceOver user, who has no ⌥ hold to discover, hears
/// them whatever SwiftUI decides about this view.
///
/// **Its own type rather than a method on the card, so the reservation can be measured.** Inside
/// the card this row sits in an `HStack` with the action buttons, which are taller than it is —
/// so removing it entirely changes the card's height by nothing at all, and a card-level test of
/// the invariant passes whatever this code does. `ReviewCardShortcutRevealTests` hosts this view
/// directly for that reason; the first version of that file measured the card and proved nothing.
struct ReviewKeyHints: View {
    /// "Copy" or "Move" — whichever verb ⏎ currently performs.
    let primaryVerb: String

    @Environment(\.shortcutRevealActive) private var isShortcutRevealActive

    var body: some View {
        row
            .opacity(isShortcutRevealActive ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isShortcutRevealActive)
    }

    /// The row at full strength, which is also what the reserved footprint is measured against.
    var row: some View {
        HStack(spacing: 5) {
            keyCap("return")
            hintVerb(primaryVerb.lowercased())
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
            .scaledFont(.caption2.monospaced())
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
            .scaledFont(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func hintDot() -> some View {
        Text("·")
            .scaledFont(.caption2)
            .foregroundStyle(.quaternary)
    }
}
