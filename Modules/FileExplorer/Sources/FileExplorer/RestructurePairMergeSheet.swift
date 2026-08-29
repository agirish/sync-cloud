import Design
import SwiftUI
import Sync

/// The confirm surface for a **cross-parent** pair merge — an inbox folder mirroring its real
/// destination, a loose folder beside the container it belongs in, a child echoing its parent
/// (ROADMAP_V5 §5.2; the audit's G2).
///
/// There is no mapping to edit here and no shape to choose: the pair is two paths, and the
/// operations follow from them. So this sheet is the review section alone — the derived
/// operations, the ledger's own sentence about them, and the two buttons that write. Everything
/// it shows comes from ``RestructurePlanner/pairMergeManifest(source:destination:kind:in:profileId:manifestId:createdAt:note:)``,
/// so what is listed IS what lands; there is no second derivation to drift.
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
    /// The landing's stage, straight from the manager — the same value the plan sheet reads. A
    /// pair merge runs the identical eight steps, and showed only a button reading "Applying…".
    var applyProgress: RestructureApplyProgress?
    let onExport: (RestructureManifest) -> RestructurePlanSheet.ExportResult
    var onApply: ((RestructureManifest) async -> RestructurePlanSheet.ApplyResult)?
    let onClose: () -> Void

    @State private var createdAt = ""
    @State private var manifestId = ""
    @State private var outcome: Outcome?
    @State private var applying = false
    @State private var landed = false
    /// The manifest as it stood when Apply ran. **The sheet's whole content is a pure function of
    /// the tree**, and a successful landing changes the tree — the source is gone, so re-deriving
    /// afterwards refuses, and the operation list would be replaced by "nothing was derived"
    /// directly above a footer reporting the landing. Holding the manifest keeps the review
    /// showing what actually ran.
    @State private var landedManifest: RestructureManifest?

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
            // The three buttons below price three different acts, and only one of them is
            // obvious. This is the sentence that made the middle one placeable.
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
        // **Resizable, which it was not.** A fixed 560pt sheet over paths this deep truncated
        // both ends of every row into `…on/Form ETA-9035 (DOL).pdf → …n/Form ETA-9035 (DOL).pdf`
        // — two ellipses and no answer to "from where, to where" — and there was no way to drag
        // it wider. The ideal is sized to the real tree's paths; the minimum is the floor the
        // footer's three buttons need.
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
        return RestructurePlanner.pairMergeManifest(
            source: source, destination: destination, kind: kind, in: tree,
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
            // **Both paths in full, each on its own line, wrapping rather than truncating.**
            // Side by side with `lineLimit(1)` they were the first thing to go: on a deep tree
            // the reader got two head-ellipses and no way to tell which folder was which. These
            // are the two facts the whole sheet is about, so they get the room.
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

    /// **The two last components are frequently the same word** — a child echoing its parent is
    /// four of the five echo hits on the real tree (`TODO/IRS/IRS`, `ACI/ACI`), and a loose
    /// folder keeps its own name inside the container. "Merge IRS into IRS" names neither folder,
    /// so where the names match the title states the RELATION the card stated, and the two paths
    /// underneath stay the precise answer.
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
                // **Grows with the sheet.** The sheet became resizable so a long merge could be
                // read; capped at a fixed 200 the drag only added empty band above and below the
                // list it was meant to open up. A floor so a two-operation merge still reads as a
                // list rather than a sliver.
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
                // 86, not 74: "move folder" measures 73.81pt at the top text size against a
                // 74pt frame, so the longest verb was 0.19pt from wrapping every row.
                .frame(width: 86, alignment: .leading)
                .lineLimit(1)
            // **The name, not the path.** Both paths are stated in full in the header, and every
            // row of a pair merge runs between those same two folders — so repeating them here
            // cost the row all its width and truncated the one part that differs: the file's own
            // name. A row that goes somewhere OTHER than the common destination says where.
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
        // One element per operation. Four separate Texts per row makes a 40-operation merge a
        // 160-element walk, and this is the only Restructure review list that fragments that way
        // — the mapping sheet's rows are one Text and the removal sheet's are labelled Toggles.
        .accessibilityElement(children: .combine)
    }

    /// What one row says, with the pair's own two folders taken as read.
    ///
    /// **The common case carries no path at all.** A pair merge moves things from one named
    /// folder into one named folder, both stated in the header; a row that repeated them spent
    /// its whole width on the part the reader already knew and truncated the part they did not.
    /// So `name` is what is moving, and `detail` is present only where this row does something
    /// the header does not already describe — a nested subfolder, or a destination that is not
    /// the common one.
    static func rowText(_ action: RestructureManifest.Action, source: String, destination: String)
        -> (name: String, detail: String?) {
        let path = action.src ?? action.dst ?? "—"
        let name = relative(of: path, under: source) ?? (path as NSString).lastPathComponent
        guard let dst = action.dst, action.src != nil else { return (name, nil) }
        // **Silent when the position is mirrored.** A merge preserves structure: a file at
        // `<source>/2024/receipt.pdf` lands at `<destination>/2024/receipt.pdf`, and `name`
        // already reads `2024/receipt.pdf` — so a detail saying "into 2024/" repeats the row's
        // own text back at itself. What earns a detail is a row that does something else.
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

    /// The operation's verb in the words the card and the ledger use — not the schema's raw
    /// value, which is a wire format rather than a sentence.
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
            // The refusal's OWN folder, not the argument — they are the same on today's only
            // route, and a message naming the wrong one would be undetectable if they diverge.
            return "\(member) would have to move inside itself. Nothing was derived."
        case .targetTakenByFile(let target, _):
            // The planner's occupancy model is folder-shaped; the disk is not. Reachable here
            // because a pair's destination name can be worn by a file.
            return "A file named \(target) already stands where this would go. Nothing was "
                + "derived — the plan would have failed at apply and blamed drift."
        case .duplicateMappingRows, .conflictingTargets, .targetTakenByCase, .invalidTargetName:
            // Reachable only through the mapping editor, which this sheet does not have. Named
            // rather than defaulted so a new refusal has to be worded before it can appear —
            // which is how the two cases added by main's round-4 review surfaced here at all.
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
            Button(landed ? "Done" : "Cancel") { onClose() }
                .scaledFont(.system(size: 11))
                .keyboardShortcut(.cancelAction)
                .disabled(applying)
            // Present on a refusal too, disabled — nesting these inside the success case made
            // them VANISH rather than grey out, which reads as a sheet that changed its mind
            // about what it offers.
            let manifest = try? plan.get()
            Button("Save for later…") { if let manifest { export(manifest) } }
                .scaledFont(.system(size: 11))
                .keyboardShortcut(.defaultAction)
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
                .help("Runs the operations above. The inverse is written to disk first, every "
                      + "one is re-probed as it runs, and the landing is undoable from its own "
                      + "card after a quit — ⌘Z covers only this launch.")
            }
        }
    }

    /// **What the safe button actually does, in the words of what it is FOR.**
    ///
    /// It was labelled "Export plan…", which names a file format rather than a reason, and
    /// carried no help at all — so the one button on this sheet that moves nothing was the one
    /// nobody could place. Two things happen and both matter: a file is written that can be read
    /// in any text editor, and the plan is kept, so the finding's card swaps `Plan…` for `Review
    /// N operations` and still says so after a quit.
    static let exportHelp =
        "Keeps this plan without running it. The card swaps “Plan…” for “Review N operations” "
        + "and still says so after you quit, and the plan is also written as a dated JSON file "
        + "beside your folder survey — readable in any text editor. Nothing moves."

    /// The count is the point: the card that opened this sheet says "Review 3 operations", and a
    /// button reading only "Apply" leaves the two disagreeing about what is about to happen.
    static func applyTitle(manifest: RestructureManifest?, applying: Bool) -> String {
        if applying { return "Applying…" }
        guard let manifest else { return "Apply" }
        // `operationCount`, not `actions.count`: keeps are the signature block. Counting them
        // put "Apply 2 operations" under a card reading "Review 1 operation".
        let count = manifest.operationCount
        return "Apply \(count) operation\(count == 1 ? "" : "s")"
    }

    private static func outcomeText(_ outcome: Outcome) -> String {
        switch outcome {
        case .exported(let name): return "Exported as \(name) — nothing has moved."
        // "Applied — ", like the mapping sheet: a bare counts string reads as one more preview
        // of the list above it rather than a report that it ran.
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
        Task { @MainActor in
            let result = await run(manifest)
            applying = false
            switch result {
            case .applied(let summary):
                landed = true
                // Before the tree moves under the derivation — see `landedManifest`.
                landedManifest = manifest
                outcome = .applied(summary)
            case .refused(let refusal):
                // A refusal here is transient — a scan running, the store mid-write — so the
                // button stays armed, exactly as the removal sheet's does.
                outcome = .failed(refusal)
            }
        }
    }
}
