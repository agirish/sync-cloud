import SwiftUI
import Sync
import Design

/// The docked review card above the differences table during an inline review: the current
/// item, what the copy would replace (sizes, dates, deltas, warnings), and the per-item actions.
/// Deliberately dumb about the queue: it renders `session` and reports intents through closures.
/// The host owns every session mutation and the in-flight state, so a decision landing after
/// Exit mid-copy, or after the user jumped rows, is applied or dropped with the full picture.
/// The card's own async work is display-only: statting facts and hashing for Verify.
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
    /// the Table, a sibling, so the card takes it back to keep ⏎/⌫/␣/esc working. The cost: the
    /// table's selection highlight always draws inactive; the Status column marks the row.
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

    /// Facts tagged with the item they were statted for, so between an advance and `.task(id:)`
    /// running the card renders empty facts, never the previous item's. A reset inside the task
    /// body lands a render too late and would flash one item's banner on the next.
    @State private var loadedFacts: (itemID: UUID, facts: ReviewCardModel.Facts)? = nil
    @State private var isVerifying = false
    /// Liveness token for the in-flight Verify, re-minted wherever `.task(id: item.id)` resets
    /// state. A verify completing after the card advanced compares its captured token with the
    /// live `@State` and drops its spinner write, so it can't clear the current item's spinner
    /// mid-hash. Only the spinner: the verdict is guarded on the session token instead (see
    /// `applyVerifyCompletion`). **Never** compare it with a captured copy of itself, which is
    /// always equal; one side must be the live property.
    @State private var verifyToken = UUID()
    /// Every Verify this card started, so leaving Review stops their reads, which have no size
    /// cap. Advancing to another item does not: a late verdict is still wanted (see
    /// `applyVerifyCompletion`).
    @State private var verifyTasks: [Task<Void, Never>] = []
    @FocusState private var focused: Bool
    /// A long run elsewhere in the window; the primary copy/move waits for it.
    @Environment(\.runWriteLock) private var runWriteLock

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
        // The card is the review's key-event anchor: focusable so the keys work the moment the
        // session starts, and not window-level `.keyboardShortcut`s, which are consulted before
        // the first responder and would eat Return/Space typed into fields elsewhere in the
        // window (see the pane Quick Look comment in ContentView+SplitLayout).
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // The way back that the `focused` guard below needs: a card that lost key focus has dead
        // keys, and clicking it is what a user will try. `.focusable()` alone doesn't claim focus
        // on click, and `.contentShape` makes the padding and background hittable, since an
        // unfilled shape is hit-tested only where painted. `reclaimFocus()` defers a turn, as
        // `.task(id:)` does, because a `@FocusState` write in the click's own transaction can be
        // dropped. `FilingWalkthroughCard` carries the same pair.
        .contentShape(Rectangle())
        .onTapGesture { reclaimFocus() }
        // ⏎: both Enter keycaps, `.down` only, plain keystrokes only.
        //
        // `.keypadEnter` beside `.return`: the keypad's Enter sends U+0003, not U+000D, and
        // SwiftUI matches on the character, so `.return` alone misses it. See
        // `KeyEquivalent.keypadEnter`.
        //
        // `press.isPlainKeystroke`, because `onKeyPress` passes modified presses through, so ⌘⏎
        // and ⇧⏎ would copy. Not `modifiers.isEmpty`, which refuses every keypad Enter (they
        // carry `.numericPad` + `.function`). `.down` only, because a held ⏎ repeats, and
        // `isActing` closes only when the async outcome lands, so repeats could launch several
        // copies of one row. ␣ and esc take modified presses, but neither moves bytes.
        //
        // `focused`, as on `FilingWalkthroughCard`'s decision keys: `.onKeyPress` fires for a key
        // delivered anywhere in its subtree, so with a descendant focused (Skip, Quick Look,
        // Verify) the handler still runs with `focused` false, and ⏎ on a focused Skip would
        // copy. `ReviewCardKeyTests.anAncestorHandlerStillFiresForAKeyAimedAtAFocusedDescendant`
        // pins that premise. Full Keyboard Access can't be tested here (`NSApp` is nil under
        // `swift test`), so check by hand when touching this: with FKA on, Tab to Skip and press
        // ⏎; nothing may be copied or moved, and ⌫ must not skip the row.
        .onKeyPress(keys: [.return, .keypadEnter], phases: .down) { press in
            guard press.isPlainKeystroke, focused else { return .ignored }
            // Both gates: a copy mid-verify would overwrite the destination while the hash
            // reads it (the bulk paths enforce the same via isVerifyAllRunning).
            if !isActing && !isVerifying && runWriteLock == nil { onPrimary(item) }
            return .handled
        }
        // `.down` only: Skip is synchronous and decided rows are unrevisitable, so a held ⌫
        // must not mass-skip the queue. `press.isPlainKeystroke`, so ⌘⌫ and ⌥⌫ are `.ignored`
        // for whoever owns them; it checks ⌘⌥⌃⇧ only, since `.capsLock` rides on every event
        // while the lock is on (see `KeyPress.isPlainKeystroke`). `focused` as for ⏎ above.
        //
        // ⌫ only, not →, though Organize's Rules walkthrough takes both: elsewhere in Compare →
        // means "to the right pane", and a → pressed from that habit would spend a row.
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.isPlainKeystroke, focused else { return .ignored }
            if !isActing { onSkip(item) }
            return .handled
        }
        .onKeyPress(.space) { quickLookKeyPressed(item) }
        .onKeyPress(.escape) {
            onExit()
            return .handled
        }
        .onDisappear {
            verifyTasks.forEach { $0.cancel() }
            verifyTasks.removeAll()
        }
        .task(id: item.id) {
            isVerifying = false
            verifyToken = UUID()   // orphan any verify still hashing the previous item
            // Deferred one turn: a FocusState write in the transaction that inserts the view can
            // be silently dropped (as with the header search field).
            Task { @MainActor in
                // Don't take key focus mid-typing: an async outcome can advance the item while
                // the user is in a text field, and their next Return would become a Copy. Field
                // editors are NSTextView, so this covers every AppKit text input.
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
        // The keys, stated on the card itself. `ReviewKeyHints` renders at zero opacity when the
        // reveal is off, and whether SwiftUI then drops it from the accessibility tree can't be
        // tested, so this hint is unconditional.
        .accessibilityHint(ReviewCardModel.keyHintSpeech(primaryVerb: model.primaryVerb))
    }

    // MARK: Rows

    private func headerRow(item: FileDifference, model: ReviewCardModel) -> some View {
        HStack(spacing: 8) {
            // Real file icon in a tile, not the diff-type glyph: the direction chip's "new /
            // replaces existing" carries the type.
            Image(nsImage: FileIconCache.icon(name: model.fileName, isDirectory: model.isFolder))
                .resizable()
                .frame(width: 22, height: 22)
                .padding(5)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
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
                .foregroundStyle(.primary)
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
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
                }
            }
        }
        .scaledFont(.callout)
    }

    /// One inline fact run: "Copying: **2.4 MB** · Jul 8, 6:12 PM". The date
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
            statusRow("Couldn’t verify (a side was unreadable or not downloaded).", systemImage: "questionmark.circle", tint: .secondary)
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
            .accentedProminent()
            .chromeHover()
            .disabled(isActing || isVerifying)
            .lockedDuringRun()
            Button("Skip") {
                onSkip(item)
            }
            .chromeButtonStyle(glassLevel)
            .chromeHover(tint: accent)
            .disabled(isActing)
            if let onQuickLook {
                // One button, source side (same as ␣). The destination's Quick Look is in the
                // row's context menu.
                Button {
                    // Focus back to the card, as the walkthrough card's `recoveringFocus` does:
                    // this button can take key focus under Full Keyboard Access, and ⏎/⌫ are
                    // guarded on `focused`. The item doesn't change, so `.task(id:)`'s claim
                    // never fires for it.
                    reclaimFocus()
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
                    // Same as Quick Look above: Verify leaves the item alone, so nothing else
                    // gives the card its focus back.
                    reclaimFocus()
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

    /// Puts key focus back on the card, one turn later.
    ///
    /// One spelling for every route that can take focus off it (a click on the card body or on
    /// one of its buttons). The turn matters: a `@FocusState` write inside the transaction
    /// handling the click can be dropped.
    private func reclaimFocus() {
        Task { @MainActor in focused = true }
    }

    private func quickLookKeyPressed(_ item: FileDifference) -> KeyPress.Result {
        guard let onQuickLook else { return .ignored }
        onQuickLook(URL(fileURLWithPath: item.reviewSourcePath))
        return .handled
    }

    /// Per-item content check, reusing the bulk Verify's hashing but reporting the verdict to
    /// the host rather than feeding `verifiedIdenticalForCopy`, whose bulk dialog would be wrong
    /// mid-review. Read-only, so a late verdict is harmless; the host drops it if the session
    /// is gone.
    private func performVerify(_ item: FileDifference) {
        guard !isVerifying else { return }
        isVerifying = true
        // Both captured before the unbounded hash: `token` to compare with the live @State
        // after it, `sessionToken` so the host can drop a verdict from a replaced session.
        let token = verifyToken
        let sessionToken = session.sessionToken
        verifyTasks.append(Task { @MainActor in
            let same = await FileContentVerifier.filesHaveSameContent(
                leftPath: item.leftItemPath,
                rightPath: item.rightItemPath,
                fileManager: fileManager,
                // The session cache Verify All and the lens scans use, so a pair already hashed
                // isn't read again. Keyed on (path, mtime, size, file number, ctime), so an
                // edited file is bypassed rather than served.
                cache: ContentHashCache.shared
            )
            // `verifyToken` here is a live @State read (the captured struct reads through the
            // live storage box), never a copy — see `verifyToken`. It decides only the spinner.
            Self.applyVerifyCompletion(
                sameContent: same,
                stopped: Task.isCancelled,
                liveToken: verifyToken,
                startedToken: token,
                report: { onVerdict(item.id, $0, sessionToken) },
                clearSpinner: { isVerifying = false }
            )
        })
    }

    /// Routes a finished Verify: what the completion is allowed to write back to the card.
    ///
    /// The verdict is reported unconditionally: it is session-guarded downstream (`onVerdict`
    /// carries the session token, and `ReviewSessionStore.recordVerdict` drops one from a
    /// replaced session), and a completion from a card that has since advanced still describes
    /// the item it hashed. Dropping it would leave someone who clicked away and back with no
    /// answer.
    ///
    /// The token guards only the spinner. `isVerifying` belongs to the item shown now, and a
    /// late completion writing `false` would clear that item's spinner mid-hash.
    ///
    /// Split out of the view so the rule is testable; the call site is a single call.
    /// - Parameters:
    ///   - sameContent: `FileContentVerifier`'s answer — nil when a side couldn't be hashed.
    ///   - stopped: the verify was cancelled (the card left Review). Its nil says nothing about
    ///     the files, so no verdict is reported — "couldn't verify" would blame a readable pair.
    ///   - liveToken: the card's current `verifyToken`.
    ///   - startedToken: the token captured when this verify started.
    static func applyVerifyCompletion(
        sameContent: Bool?,
        stopped: Bool = false,
        liveToken: UUID,
        startedToken: UUID,
        report: (ReviewSession.VerifyVerdict) -> Void,
        clearSpinner: () -> Void
    ) {
        let verdict: ReviewSession.VerifyVerdict =
            sameContent == true ? .identical : (sameContent == false ? .differed : .unverifiable)
        if !stopped { report(verdict) }
        guard liveToken == startedToken else { return }
        clearSpinner()
    }

    // MARK: Facts

    /// How many destination-folder descendants to count before giving up ("1000+ items"): the
    /// number orients the folder-replace warning; it is not an audit.
    private nonisolated static let childCountCap = 1000

    /// Stats what `FileDifference` doesn't carry: both sides' modification dates and, for a
    /// folder about to be replaced, how much it contains. Off the main actor, because a stat on a
    /// network or cloud volume can block for seconds. Uses the injected `FileManaging`, so the
    /// facts describe the disk the copy and Verify run against.
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
                // `childCount`, not a bare enumerator: an enumerator is non-nil and yields
                // nothing for a folder that can't be listed, which would read as "0 items will be
                // removed". An unreadable folder leaves the count nil, so the warning says
                // "everything".
                let counted = fileManager.childCount(of: destinationURL, options: [], cap: childCountCap)
                switch counted.outcome {
                case .unreadable:
                    facts.destinationChildCount = nil
                case .listed, .listedWithUnreadableDescendants:
                    facts.destinationChildCount = counted.count
                    facts.destinationChildCountCapped = counted.isCapped
                    facts.destinationChildCountIsPartial = counted.outcome == .listedWithUnreadableDescendants
                }
            }
            return facts
        }.value
    }
}

/// The review card's key-cap hint row: bordered key chips with plain-text verbs between.
///
/// Part of the ⌥-hold reveal: empty by default, keycaps only while ⌥ is held.
///
/// Hidden with `.opacity`, not branched out of the layout, so the card never resizes when ⌥
/// goes down and the Copy button can't move under a settled pointer.
///
/// Accessibility doesn't rely on this row: whether SwiftUI keeps a zero-opacity view in the
/// accessibility tree can't be tested, so the card states the keys in an unconditional
/// `.accessibilityHint`.
///
/// Its own type so the reserved footprint can be measured: in the card it shares an `HStack`
/// with taller buttons, so a card-level test couldn't see it. `ReviewCardShortcutRevealTests`
/// hosts it directly.
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
