import Design
import SwiftUI
import Sync

/// The confirm surface for a cross-parent pair merge: an inbox folder mirroring its real
/// destination, a loose folder beside its container, a child echoing its parent.
///
/// There is no mapping to edit: the pair is two paths and the operations follow from them. So
/// this is the review alone: the operations, the ledger's sentence, and the buttons that write.
/// Everything comes from ``RestructurePlanner/pairMergeManifest(source:destination:kind:in:profileId:manifestId:createdAt:note:)``,
/// so what is listed is what lands.
struct RestructurePairMergeSheet: View {
    let source: String
    let destination: String
    let kind: FindingKind
    /// The tree as it stands now — disk-backed in the app, dictionary-backed in tests.
    let tree: RestructureTreeView
    let profileId: String
    let accent: Color
    /// The sentence the finding's card makes about this pair, carried into the sheet so the
    /// review opens on the claim it was opened from.
    let rationale: String
    /// The landing's stage, straight from the manager, the same value the plan sheet reads: a
    /// pair merge runs the same eight steps.
    var applyProgress: RestructureApplyProgress?
    let onExport: (RestructureManifest) -> RestructurePlanSheet.ExportResult
    var onApply: ((RestructureManifest) async -> RestructurePlanSheet.ApplyResult)?
    /// Whether the sheet opens on a plan saved by an earlier Save for Later — read once, at open,
    /// like the mapped sheet's `hasSavedDraft`.
    var hasSavedDraft: Bool = false
    /// Removes the saved plan: *Discard Plan*, which Help tells the reader to use.
    var onDiscardDraft: (() -> Void)?
    let onClose: () -> Void

    @State private var createdAt = ""
    @State private var manifestId = ""
    @State private var outcome: Outcome?
    @State private var applying = false
    @State private var landed = false
    /// The manifest as it stood when Apply ran. The sheet's content is a function of the tree,
    /// and a landing removes the source, so re-deriving afterwards would refuse and show "nothing
    /// was derived" above a footer reporting the landing. This keeps showing what ran.
    @State private var landedManifest: RestructureManifest?
    /// The manifest as it stood when Apply was pressed, held for the whole landing. A landing
    /// publishes up to ~101 progress ticks, and without this each one would re-derive on the main
    /// actor against a tree the executor is moving.
    @State private var applyingManifest: RestructureManifest?
    /// The disk view this presentation reads, captured once. `memoized()`'s cache lives only as
    /// long as the view value, and the parent rebuilds this sheet on every publish, so the cache
    /// is held here for the life of the presentation.
    @State private var treeBox = RestructurePlanSheet.TreeBox()

    /// The tree every derivation in this sheet reads. Keyed on the pair, so a sheet re-presented
    /// on a different finding cannot inherit the previous one's listings.
    private var liveTree: RestructureTreeView {
        treeBox.view(key: "\(kind.rawValue)|\(source)|\(destination)") { tree }
    }

    private enum Outcome: Equatable {
        case exported(String)
        case applied(String)
        case failed(String)
    }

    var body: some View {
        // Derived once per render and handed down, the plan sheet's rule: the header, the list
        // and the footer all read the same value rather than each re-running the planner.
        let plan = derived
        return VStack(alignment: .leading, spacing: 12) {
            header
            operationsSection(plan)
            // The three buttons below price three different acts; this says what the middle,
            // least obvious one does.
            Text(Self.exportHelp)
                .scaledFont(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let applyProgress {
                RestructureApplyChecklist(progress: applyProgress, accent: accent)
            }
            footer(plan)
        }
        .padding(18)
        // Resizable, because deep paths truncate in a fixed-width sheet. The ideal width suits
        // real paths; the minimum is what the footer's three buttons need.
        .frame(minWidth: 520, idealWidth: 720, maxWidth: .infinity,
               minHeight: 400, idealHeight: 560, maxHeight: .infinity)
        .onAppear(perform: seed)
    }

    private func seed() {
        guard createdAt.isEmpty else { return }
        let stamp = RestructurePlanSheet.nowStamp()
        createdAt = stamp
        manifestId = "plan-\(kind.rawValue)-\(stamp)"
    }

    private var derived: Result<RestructureManifest, RestructurePlanner.PlanRefusal> {
        if let landedManifest { return .success(landedManifest) }
        // Frozen for the duration of a landing, not just after it — see `applyingManifest`.
        if let applyingManifest { return .success(applyingManifest) }
        return RestructurePlanner.pairMergeManifest(
            source: source, destination: destination, kind: kind, in: liveTree,
            profileId: profileId, manifestId: manifestId, createdAt: createdAt,
            note: Self.note(source: source, destination: destination))
    }

    /// The manifest's own written justification — read in a text editor, away from this sheet.
    static func note(source: String, destination: String) -> String {
        "Pair merge: \(source) into \(destination). Derived from the pair alone — there is no "
        + "mapping to edit, and the emptied folder is left standing for the removal step."
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.title(source: source, destination: destination))
                .scaledFont(.system(size: 13, weight: .semibold))
            // Both paths in full, each on its own line, wrapping rather than truncating: they
            // are the two facts the sheet is about.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text("From")
                        .scaledFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(source)
                        .scaledFont(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GridRow {
                    Text("Into")
                        .scaledFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(destination)
                        .scaledFont(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.chip)
                .fill(.quaternary.opacity(0.22)))
            Text(rationale)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The sheet's title. The two last components are often the same word (`TODO/IRS/IRS`), and
    /// "Merge IRS into IRS" names neither folder, so then the title states the relation instead;
    /// the paths underneath stay the precise answer.
    static func title(source: String, destination: String) -> String {
        let from = (source as NSString).lastPathComponent
        let into = (destination as NSString).lastPathComponent
        guard from == into else { return "Merge \(from) into \(into)" }
        let sourceParent = (source as NSString).deletingLastPathComponent
        if sourceParent == destination { return "Merge \(from) into its parent" }
        let destinationParent = (destination as NSString).deletingLastPathComponent
        return "Merge \(from) into "
            + "\(RestructurePaths.familyLabel(destinationParent))/\(into)"
    }

    // MARK: - The operations

    @ViewBuilder
    private func operationsSection(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch plan {
            case .success(let manifest):
                Text(RestructureLedger(of: manifest).summary)
                    .scaledFont(.system(size: 11, weight: .medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(manifest.actions.enumerated()), id: \.offset) { _, action in
                            operationRow(action)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Grows with the sheet, so resizing opens up the list. The floor keeps a
                // two-operation merge reading as a list, not a sliver.
                .frame(minHeight: 120, maxHeight: .infinity)
            case .failure(let refusal):
                // A refusal is a sentence, never an empty list that reads as "nothing to do".
                Text(Self.refusalText(refusal, source: source))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func operationRow(_ action: RestructureManifest.Action) -> some View {
        let item = Self.rowText(action, source: source, destination: destination)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.verb(action.action))
                .scaledFont(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                // 86pt: "move folder" is 73.8pt at the largest text size, too close to wrapping
                // in 74.
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)
            // The name, not the path: the header states both paths, so repeating them would
            // truncate the part that differs. A row going elsewhere says where.
            Text(item.name)
                .scaledFont(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = item.detail {
                Text(detail)
                    .scaledFont(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if action.collisionExpected == true {
                Text("both kept")
                    .scaledFont(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 8)
        // One accessibility element per operation, like the other Restructure review lists, not
        // four per row.
        .accessibilityElement(children: .combine)
    }

    /// What one row says, with the pair's two folders (stated in the header) taken as read.
    /// `name` is what moves; `detail` appears only where the row does something the header
    /// doesn't describe, such as a renamed collision or a destination outside the common one.
    static func rowText(_ action: RestructureManifest.Action, source: String, destination: String)
        -> (name: String, detail: String?) {
        let path = action.src ?? action.dst ?? "—"
        let name = relative(of: path, under: source) ?? (path as NSString).lastPathComponent
        guard let dst = action.dst, action.src != nil else { return (name, nil) }
        // Silent when the position is mirrored: `<source>/2024/a.pdf` landing at
        // `<destination>/2024/a.pdf` already reads `2024/a.pdf` in `name`.
        let landedAs = relative(of: dst, under: destination)
        if landedAs == name { return (name, nil) }
        if let landedAs, (landedAs as NSString).deletingLastPathComponent
            == (name as NSString).deletingLastPathComponent {
            // Same folder, different name — a collision the planner resolved by keeping both.
            return (name, "as \((dst as NSString).lastPathComponent)")
        }
        if let landedAs { return (name, "into \(landedAs)") }
        // Not under the destination at all: the one case that needs the whole path.
        return (name, "→ \(dst)")
    }

    /// `path` with `root/` taken off the front, or nil when it does not sit under `root`.
    /// Component-wise, so a sibling sharing a name prefix is not mistaken for a child.
    static func relative(of path: String, under root: String) -> String? {
        guard path != root else { return nil }
        guard RestructurePaths.isInside(path, of: root) else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    /// The operation's verb in the card's and ledger's words, not the schema's raw value.
    static func verb(_ kind: RestructureManifest.ActionKind) -> String {
        switch kind {
        case .createDir: return "create"
        case .renameDir: return "rename"
        case .moveDir: return "move folder"
        case .moveFile: return "move file"
        case .keep: return "keep"
        case .removeEmptyDir: return "remove"
        }
    }

    /// Why no plan could be derived, in the sheet's own words.
    static func refusalText(_ refusal: RestructurePlanner.PlanRefusal, source: String) -> String {
        switch refusal {
        case .nothingMapped:
            return "There is nothing to move — the two paths already resolve to one folder."
        case .unknownFiles(let path):
            return "The files inside \(path) could not be listed, and a merge that cannot name "
                + "what it moves is a guess. Nothing was derived."
        case .unresolvableOrder(let member):
            // The refusal's own folder, not the argument: the same today, but if they ever
            // diverge, naming the wrong one would go unnoticed.
            return "\(member) would have to move inside itself. Nothing was derived."
        case .targetTakenByFile(let target, _):
            // The planner's occupancy model is folder-shaped; the disk is not. Reachable here
            // because a pair's destination name can be worn by a file.
            return "A file named \(target) already stands where this would go. Nothing was "
                + "derived — the plan would have failed at apply and blamed drift."
        case .duplicateMappingRows, .conflictingTargets, .targetTakenByCase, .invalidTargetName:
            // Reachable only through the mapping editor, which this sheet lacks. Named, not
            // defaulted, so a new refusal has to be worded before it can appear.
            return "This pair cannot be planned automatically."
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        HStack(spacing: 10) {
            if let outcome {
                Text(Self.outcomeText(outcome))
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            // The mapped sheet's Discard Plan, word for word: destructive, never the default and
            // with no key — ⏎ stays on Save for Later, the safe act.
            if Self.offersDiscard(hasSavedDraft: hasSavedDraft, canDiscard: onDiscardDraft != nil,
                                  landed: landed) {
                Button("Discard Plan", role: .destructive) {
                    onDiscardDraft?()
                    onClose()
                }
                    .scaledFont(.system(size: 11))
                    .disabled(applying)
                    .help("Removes this saved plan, so its card no longer shows it as planned. "
                          + "Nothing moves, and an exported file stays where it is.")
            }
            Button(Self.closeTitle(landed: landed, hasSavedDraft: hasSavedDraft)) { onClose() }
                .scaledFont(.system(size: 11))
                .keyboardShortcut(.cancelAction)
                .disabled(applying)
            // Present on a refusal too, disabled, so the buttons grey out rather than vanish.
            let manifest = try? plan.get()
            // No ellipsis: it saves at once, with no panel.
            Button("Save for Later") { if let manifest { export(manifest) } }
                .scaledFont(.system(size: 11))
                .keyboardShortcut(.defaultAction)
                .accentedProminent()
                .disabled(manifest == nil || applying || landed)
                .help(Self.exportHelp)
            if let onApply {
                Button(Self.applyTitle(manifest: manifest, applying: applying)) {
                    if let manifest { apply(manifest, run: onApply) }
                }
                .scaledFont(.system(size: 11, weight: .semibold))
                // The one control here that moves files wears the colour the mapping sheet's
                // Apply wears; the two sheets must not price the same act differently.
                .foregroundStyle(.red)
                .disabled(manifest == nil || applying || landed)
                .lockedDuringRun()
                .help("Runs the operations above. The inverse is written to disk first, every "
                      + "one is re-probed as it runs, and the landing is undoable from its own "
                      + "card after a quit — ⌘Z covers only this launch.")
            }
        }
    }

    /// The mapped sheet's rule (`RestructurePlanSheet.closeTitle`): never "Cancel" beside a
    /// saved plan that closing keeps, because it reads as a discard.
    static func closeTitle(landed: Bool, hasSavedDraft: Bool) -> String {
        landed ? "Done" : hasSavedDraft ? "Close" : "Cancel"
    }

    /// Discard Plan shows on a sheet opened on a saved plan, until a landing has consumed it.
    static func offersDiscard(hasSavedDraft: Bool, canDiscard: Bool, landed: Bool) -> Bool {
        hasSavedDraft && canDiscard && !landed
    }

    /// What Save for Later does, in terms of what it is for: the plan is kept, so the card
    /// shows it as planned even after a quit, and a readable file is written. Nothing moves.
    static let exportHelp =
        "Keeps this plan without running it. The card swaps “Plan…” for “Review N operations” "
        + "and still says so after you quit, and the plan is also written as a dated JSON file "
        + "beside your folder survey — readable in any text editor. Nothing moves."

    /// Carries the count, so the button agrees with the card's "Review N operations".
    static func applyTitle(manifest: RestructureManifest?, applying: Bool) -> String {
        if applying { return "Applying…" }
        guard let manifest else { return "Apply" }
        // `operationCount`, not `actions.count`: keeps are the signature block, and counting
        // them would disagree with the card.
        let count = manifest.operationCount
        return "Apply \(count) Operation\(count == 1 ? "" : "s")"
    }

    private static func outcomeText(_ outcome: Outcome) -> String {
        switch outcome {
        case .exported(let name): return "Exported as \(name) — nothing has moved."
        // "Applied — ", like the mapping sheet, so it reads as a report, not another preview.
        case .applied(let summary): return "Applied — \(summary)"

        case .failed(let sentence): return sentence
        }
    }

    private func export(_ manifest: RestructureManifest) {
        switch onExport(manifest) {
        case .saved(let filename): outcome = .exported(filename)
        case .failed(let sentence): outcome = .failed(sentence)
        }
    }

    private func apply(_ manifest: RestructureManifest,
                       run: @escaping (RestructureManifest) async
                           -> RestructurePlanSheet.ApplyResult) {
        guard !applying, !landed else { return }
        applying = true
        outcome = nil
        applyingManifest = manifest
        Task { @MainActor in
            let result = await run(manifest)
            applying = false
            switch result {
            case .applied(let summary):
                landed = true
                // Before the tree moves under the derivation — see `landedManifest`.
                landedManifest = manifest
                applyingManifest = nil
                outcome = .applied(summary)
            case .refused(let refusal):
                // A refusal here is transient (a scan running, the store mid-write), so the
                // button stays armed, as the removal sheet's does, and the derivation reads the
                // tree again because nothing moved.
                applyingManifest = nil
                outcome = .failed(refusal)
            }
        }
    }
}
