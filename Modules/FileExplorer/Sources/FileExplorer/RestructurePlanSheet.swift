import Design
import SwiftUI
import Sync

/// The plan surface: choose the target shape, edit the family mapping, review the derived
/// operations, then export the plan or apply it.
///
/// The sheet owns no derivation logic: every operation it shows comes from
/// ``RestructurePlanner`` on each edit, so what the review lists is what the manifest carries.
struct RestructurePlanSheet: View {
    let finding: StructureFinding
    /// The parent the mapping's members are children of. An input, not `finding.family`: for a
    /// pair seeded through ``RestructurePlanRoute/seededMapping(family:member:source:target:)``
    /// the family is the pair's grandparent and the single member is the folder they sit in,
    /// because the mapping's unit is a child name inside a member.
    let family: String
    /// Every member of the family, scheme members, drift and shapeless alike: the mapping
    /// applies to all of them, and drift is the part that most needs housing.
    let members: [String]
    /// The tree as it stands now — disk-backed in the app, dictionary-backed in tests.
    let tree: RestructureTreeView
    let profileId: String
    let accent: Color
    /// A saved draft's rows, so *Review N operations* reopens the plan as it was left.
    var initialRows: [RestructureMapping.Row]?
    /// The saved draft's full picker vocabulary, including names no row uses, so a reopened
    /// draft keeps its unused choices. nil (an older draft, or none) falls back to the rows'
    /// targets.
    var initialVocabulary: [String]?
    /// The outcome of writing the export file and draft. Success carries the file name the store
    /// chose, the one on disk, so the footer never re-derives it.
    enum ExportResult: Equatable {
        case saved(filename: String)
        case failed(String)
    }
    /// Writes the file and the draft; the vocabulary rides along so the draft can reopen with
    /// the same choices on its pickers.
    let onExport: (RestructureManifest, _ vocabulary: [String]) -> ExportResult
    /// Keeps the plan as it stands when the sheet closes without landing or exporting, so Esc
    /// doesn't throw away a hand-made mapping. nil when the host keeps none.
    var onKeepDraft: ((RestructureManifest, _ vocabulary: [String]) -> Void)?
    /// Whether a saved draft is what this sheet opens on. Read once, when the sheet seeds — see
    /// `Baseline`.
    var hasSavedDraft: Bool = false
    /// Removes the saved draft: *Discard Plan*, and a close after every row went back to keep,
    /// so an undone plan's card doesn't keep showing it as planned.
    var onDiscardDraft: (() -> Void)?
    /// The landing: runs the eight-step apply and returns the summary on success or the
    /// refusal. nil hides Apply rather than promising a landing that cannot run.
    var onApply: ((RestructureManifest) async -> ApplyResult)?
    /// The paid pass, on the mapping, never on the apply. nil when the host has wired no
    /// transport; whether a key is stored is `refineOffered`'s separate question, as with the
    /// filing refine button.
    var onRefineMapping: ((MappingRefineRequest) async -> FileSyncManager.MappingRefineOutcome)?
    /// Is a key stored — the offer/invitation branch (`filingCloudRefineAvailable`'s answer).
    var refineOffered: Bool = false
    /// The model the button names, resolved the way the transport resolves it so the button
    /// cannot name one model and send another.
    var refineModelLabel: String = "Claude"
    /// The price of asking, shown beside the button where the dialog used to be (TE335): the chat's
    /// model, what it would cost, and this month against Ask Claude's limit. nil when it cannot run.
    var refineQuote: ((MappingRefineRequest) -> FileSyncManager.MappingRefineQuote?)?
    /// Opens Ask Claude's Key & Spending page, for a limit that would be passed.
    var onChangeLimit: (() -> Void)?
    /// Opens Settings on the key row — the invitation's action.
    var onConfigureRefine: (() -> Void)?
    /// Where the landing has got to while it runs, nil otherwise. Straight from the manager's
    /// published value, so the checklist shows only stages the engine reached.
    var applyProgress: RestructureApplyProgress?

    /// What a landing came back with — the summary, or the sentence that refused it.
    enum ApplyResult: Equatable {
        case applied(summary: String)
        case refused(String)
    }
    let onClose: () -> Void

    @State private var rows: [RestructureMapping.Row] = []
    @State private var vocabulary: [String] = []
    /// Every distinct child name across the family, disk-cased — the rows' sources, and the
    /// spelling authority when a scheme's lowercased vocabulary becomes target names.
    @State private var allSources: [String] = []
    /// Sibling families sharing this one's vocabulary. Resolved once at open: it walks every
    /// sibling's members, and the tree does not move under a modal sheet.
    @State private var parallelFamilies: [String] = []
    /// The group laid out, resolved beside `parallelFamilies` for the same reason.
    @State private var groupTable: RestructurePlanner.FamilyGroupTable?
    /// Collapsed by default: the pointer above is the summary, and an expanded table would push
    /// the mapping below the fold on a family with many child names.
    @State private var groupTableOpen = false
    /// Whether the mapping covers the whole group. Off by default; switching it re-seeds the
    /// rows, widening the sources to every child name across the group or narrowing them back,
    /// and keeps the targets already chosen for names that survive.
    @State private var planTogether = false
    /// Every target the user has chosen, by source name, across both widths of the mapping.
    /// `rows` narrows when the group toggle goes off, so without this a name only a sibling has
    /// would lose its target on toggling off and on again.
    @State private var targetsBySource: [String: String] = [:]
    /// Manifest ids this sheet has already landed, so a retry after a partial group apply picks
    /// up where it stopped. See ``applyGroup(_:_:)``.
    @State private var alreadyLanded: Set<String> = []
    /// The plans as they stood when Apply ran. The sheet's content is a function of the tree,
    /// and after a landing every row's source is renamed away, so re-deriving would show "nothing
    /// would change" above a footer reporting the landing.
    @State private var landedPlan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>?
    @State private var landedGroup: GroupFreeze?
    /// The plan as it stood when Apply was pressed, held for the whole landing. A landing
    /// publishes up to ~101 progress ticks, each re-rendering the sheet; without this each would
    /// re-run the planner on the main actor against a half-moved tree. Cleared on a refusal;
    /// superseded by `landedPlan` on success.
    @State private var applyingPlan: Result<RestructureManifest,
                                            RestructurePlanner.PlanRefusal>?
    @State private var applyingGroup: [(family: String,
                                        result: Result<RestructureManifest,
                                                       RestructurePlanner.PlanRefusal>)]?
    /// The tree view this presentation reads, captured once. `memoized()`'s cache lives only as
    /// long as the view value, and `LensWorkspaceView` rebuilds this sheet on every manager
    /// publish, so the cache is held in `@State` for the presentation's life.
    ///
    /// Keyed on the subject, so a sheet re-presented on another finding cannot inherit its
    /// listings. The profile root is not in the key: it doesn't change while the modal is up.
    @State private var treeBox = TreeBox()

    /// Holds the memoized tree across renders. A reference type on purpose: reading or filling
    /// it from `body` is not a state change, so it cannot invalidate the view reading it.
    @MainActor
    final class TreeBox {
        private var key: String?
        private var stored: RestructureTreeView?

        func view(key: String, build: () -> RestructureTreeView) -> RestructureTreeView {
            if self.key == key, let stored { return stored }
            let made = build()
            self.key = key
            stored = made
            return made
        }
    }

    /// The tree every derivation in this sheet reads, held for the presentation. See ``treeBox``.
    private var liveTree: RestructureTreeView {
        treeBox.view(key: "\(finding.id)|\(family)|\(members.joined(separator: ","))") { tree }
    }
    @State private var chosenScheme: Int?
    @State private var customName = ""
    /// Narrows the mapping's VIEW, never its rows — see `mappingSection`.
    @State private var filterText = ""
    @State private var outcome: Outcome?
    /// What the store already holds for this plan — see ``Baseline``. Seeded when the sheet
    /// opens, and moved by every export that saves a draft.
    @State private var baseline = Baseline(rows: [], vocabulary: [], hasDraft: false)
    @State private var createdAt = ""
    @State private var manifestId = ""

    private enum Outcome: Equatable {
        case exported(String)
        case applied(String)
        case failed(String)
    }

    @State private var applying = false
    @State private var includeFileSamples = false
    @State private var refining = false
    @State private var refineTask: Task<Void, Never>?
    @State private var proposals: [MappingRefineProposal]?
    @State private var refineFailedText: String?

    var body: some View {
        // Derived once per render and handed down: each derivation runs the planner with disk
        // listings, and the per-row margin would otherwise re-run it per row. Frozen during and
        // after a landing — see `applyingPlan` and `landedPlan`.
        let plan = landedPlan ?? applyingPlan ?? derived
        // Likewise the group's plans: `groupPlans` runs the planner once per family, and both
        // the review and the footer read it.
        let group = Self.shownGroup(landed: landedGroup, applying: applyingGroup, rows: rows,
                                    together: planTogether, alreadyLanded: alreadyLanded,
                                    live: { groupPlans })
        return VStack(alignment: .leading, spacing: 14) {
            header
            // The editing surface locks as one piece while an apply runs and once it lands. The
            // review and footer manage their own states; `refineSection` handles its own Stop,
            // since `locked` does not include `refining`.
            Group {
                shapeSection
                mappingSection(plan)
                refineSection
            }
            .disabled(locked)
            reviewSection(plan, group: group)
            if let applyProgress { progressChecklist(applyProgress) }
            footer(plan, group: group)
        }
        .padding(18)
        .frame(width: 620)
        .frame(minHeight: 460)
        .onAppear(perform: seed)
        // The sibling walk, after the first frame — see `seedGroupPointer`.
        .task { seedGroupPointer() }
        .onChange(of: rows) {
            // An edit after an export describes a new plan, so the outcome sentence clears. Never
            // an applied one, backing up the editor lock: clearing it would re-arm Export and
            // Cancel over operations that already ran.
            guard !isApplied else { return }
            outcome = nil
        }
        .onChange(of: vocabulary) {
            // The picker choices ride in the exported draft, so "Exported as …" stops being true
            // when they change. An applied outcome stays: vocabulary can't reach a landed plan.
            if case .exported = outcome { outcome = nil }
        }
    }

    /// One seam for "this sheet is finished or busy", read by the whole editing surface. An edit
    /// after Apply would otherwise re-arm Export over a landed plan, and an edit mid-apply would
    /// put the summary above a derivation of the edited rows.
    private var locked: Bool { applying || isApplied }

    // MARK: - Seeding

    private func seed() {
        guard rows.isEmpty else { return }
        let sources = RestructurePlanner.distinctSources(family: family,
                                                         members: members, in: liveTree)
        allSources = sources
        if let initialRows {
            // The draft's rows, reconciled against the sources as they stand now: a source that
            // appeared since the draft gets a fresh keep row; one that vanished drops off.
            let saved = Dictionary(initialRows.map { ($0.source, $0) },
                                   uniquingKeysWith: { first, _ in first })
            rows = Self.adjacentOrder(sources.map { saved[$0] ?? RestructureMapping.Row(source: $0) })
            // The draft's saved vocabulary first (unused choices included), then any target a
            // row uses that it somehow lacks — a picker must always offer the row's own value.
            var restored = initialVocabulary ?? []
            for target in orderedTargets(of: rows) where !restored.contains(target) {
                restored.append(target)
            }
            vocabulary = restored
        } else {
            // Default keep on every row: the editor never guesses a mapping.
            rows = Self.adjacentOrder(sources.map { RestructureMapping.Row(source: $0) })
        }
        let stamp = Self.stamp(Date())
        createdAt = stamp
        manifestId = "plan-\(finding.kind.rawValue)-\(stamp)"
        baseline = Baseline(rows: rows, vocabulary: vocabulary, hasDraft: hasSavedDraft)
    }

    /// What the store already holds for this plan, as far as the sheet knows.
    ///
    /// `rows` and `vocabulary` are what "the user changed nothing" is measured against, so a
    /// sheet opened and closed untouched mints no draft. `hasDraft` is whether a saved draft
    /// exists now: the sheet opened on one, or an export here saved one.
    ///
    /// An export moves all three: the plan it wrote is the new "no change", and its draft is the
    /// sheet's to drop if every row goes back to keep.
    struct Baseline: Equatable {
        var rows: [RestructureMapping.Row]
        var vocabulary: [String]
        var hasDraft: Bool

        /// An export saved the plan as it stands as the draft.
        mutating func exported(rows: [RestructureMapping.Row], vocabulary: [String]) {
            self.rows = rows
            self.vocabulary = vocabulary
            hasDraft = true
        }
    }

    /// What closing the sheet does to the saved plan.
    enum CloseDisposition: Equatable {
        /// Save the plan as it stands as the draft.
        case keep(RestructureManifest)
        /// Remove the saved draft: one exists, and every row is back to keep.
        case discard
        /// Leave the store as it is.
        case nothing
    }

    /// What closing now does to the saved plan.
    ///
    /// Nothing when nothing changed since the store last matched the sheet, or a landing or
    /// export already kept the plan (a re-save would drop the export's file name). Otherwise a
    /// change that derives a plan is kept, and one setting every row back to keep removes the
    /// draft. Any other refusal leaves the store alone: a half-finished clashing mapping is not
    /// a request to throw the saved plan away.
    static func closeDisposition(
        plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>,
        rows: [RestructureMapping.Row], vocabulary: [String], baseline: Baseline,
        landedOrExported: Bool) -> CloseDisposition {
        guard !landedOrExported, rows != baseline.rows || vocabulary != baseline.vocabulary else {
            return .nothing
        }
        switch plan {
        case .success(let manifest): return .keep(manifest)
        case .failure(.nothingMapped): return baseline.hasDraft ? .discard : .nothing
        case .failure: return .nothing
        }
    }

    /// Whether closing now drops an edit made since the saved plan: a clashing change derives no
    /// plan, so the close keeps the saved one as it was (``closeDisposition``), despite Help's
    /// promise that closing keeps a changed plan. The footer says so before the click.
    static func closeDropsEdit(
        plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>,
        rows: [RestructureMapping.Row], vocabulary: [String], baseline: Baseline,
        landedOrExported: Bool) -> Bool {
        guard baseline.hasDraft, !landedOrExported,
              rows != baseline.rows || vocabulary != baseline.vocabulary,
              case .failure(let refusal) = plan else { return false }
        return refusal != .nothingMapped
    }

    static let closeDropsEditSentence =
        "This change can’t be planned yet, so Close keeps the plan saved before."

    /// The footer's close button, never "Cancel" when closing keeps a plan, because it reads as a
    /// discard. "Done" after a landing; "Close" whenever a plan is or will be kept (saved,
    /// exported, landed in part, or about to be kept); "Cancel" only when closing leaves no trace.
    static func closeTitle(applied: Bool, disposition: CloseDisposition,
                           hasDraft: Bool, landedOrExported: Bool) -> String {
        if applied { return "Done" }
        if hasDraft || landedOrExported { return "Close" }
        if case .keep = disposition { return "Close" }
        return "Cancel"
    }

    /// The sibling pointer and group table, run from `.task` after the first frame. The walk
    /// lists every sibling and every sibling's members, a few hundred directory reads on a big
    /// parent, and what it yields is context, so the sheet shouldn't wait to paint for it.
    ///
    /// Still on the main actor, by necessity: `RestructureTreeView` holds non-`Sendable`
    /// closures over an unlocked cache, so it can't go to a detached task.
    ///
    /// The guard keeps a restarted `.task` from re-walking. It doesn't depend on `seed()`:
    /// nothing here reads `rows`, and SwiftUI's order of `.onAppear` and `.task` is not
    /// guaranteed.
    private func seedGroupPointer() {
        guard parallelFamilies.isEmpty, groupTable == nil else { return }
        // Only for a family mapping: on a seeded pair `family` is the pair's grandparent, a
        // folder the sheet is not planning.
        guard !isSeededPair else { return }
        let siblings = RestructurePlanner.parallelFamilies(of: family, in: liveTree)
        guard !siblings.isEmpty else { return }
        parallelFamilies = siblings
        // The subject family FIRST, so the table reads outward from the one being planned.
        groupTable = RestructurePlanner.familyGroupTable(
            families: [family] + siblings.map {
                ((family as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent($0)
            },
            in: liveTree)
    }

    private func orderedTargets(of rows: [RestructureMapping.Row]) -> [String] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let target = row.target, seen.insert(target).inserted else { return nil }
            return target
        }
    }

    // MARK: - Header

    /// True when this sheet was opened on a pair seeded into one member rather than a whole
    /// family. The affordances for reconciling siblings drop away, since there are none.
    private var isSeededPair: Bool { members.count == 1 }

    /// What this sheet is planning, in one spelling, read by the header, the manifest's family,
    /// the refine request and the merge margins. For a seeded pair it is the member's own path,
    /// because the family is its parent and can be empty.
    private var planFamily: String { Self.headerPath(family: family, members: members) }

    /// Above this many rows the filter appears. Below it, scrolling is cheaper than a control.
    static let filterAppearsAbove = 12

    /// How many rows would change something, out of how many. The default is keep, so "9 of 24
    /// mapped" tells a half-made plan from one deliberately left mostly alone.
    static func mappedCount(_ rows: [RestructureMapping.Row]) -> String {
        let mapped = rows.filter { row in
            guard let target = row.target else { return false }
            return target != row.source
        }.count
        return "\(mapped) of \(rows.count) mapped — the rest keep their name"
    }

    /// Whether a row survives the filter. Case- and punctuation-insensitive, because the editor
    /// reconciles names that differ by punctuation: `w2` has to find `Form W-2`.
    static func matches(_ source: String, filter: String) -> Bool {
        let needle = similarKey(filter)
        guard !needle.isEmpty else { return true }
        return similarKey(source).contains(needle)
    }

    /// A name reduced to what makes two spellings the same name: lowercased, letters and digits
    /// only, a trailing plural folded away.
    ///
    /// A plain tokenizer, not a regex: Swift's `\b` is a Unicode word boundary with implicit NFC
    /// normalisation, so a regex could answer differently for composed and decomposed names.
    static func similarKey(_ name: String) -> String {
        var key = name.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
        // Fold a trailing plural only when a real stem is left, so `Bus` doesn't become `bu`
        // and pair with a folder called `Bu`.
        if key.count >= 4, key.hasSuffix("s") { key.removeLast() }
        return key
    }

    /// The rows in the order the editor shows them: near-identical names adjacent, so `Payment`
    /// and `Payments` are decided in one place. Otherwise the disk's order, so nothing else moves.
    static func adjacentOrder(_ rows: [RestructureMapping.Row]) -> [RestructureMapping.Row] {
        var firstSeen: [String: Int] = [:]
        for (index, row) in rows.enumerated() where firstSeen[similarKey(row.source)] == nil {
            firstSeen[similarKey(row.source)] = index
        }
        return rows.enumerated().sorted { left, right in
            let leftGroup = firstSeen[similarKey(left.element.source)] ?? left.offset
            let rightGroup = firstSeen[similarKey(right.element.source)] ?? right.offset
            if leftGroup != rightGroup { return leftGroup < rightGroup }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// The sources that share their similar-key with another — the quiet marker that says why two
    /// rows are neighbours. Asked once for the whole list, in one pass, not per row (O(rows²) per
    /// render). A source has a neighbour when its key is shared with another distinct source;
    /// duplicate sources are refused by the derivation (`duplicateMappingRows`).
    static func sourcesWithSimilarNeighbour(_ rows: [RestructureMapping.Row]) -> Set<String> {
        var sourcesByKey: [String: Set<String>] = [:]
        for row in rows { sourcesByKey[similarKey(row.source), default: []].insert(row.source) }
        var out: Set<String> = []
        for (_, sources) in sourcesByKey where sources.count > 1 { out.formUnion(sources) }
        return out
    }

    /// "merges into `Forms` in N members", per source name, derived once for the whole plan in
    /// one pass over the actions rather than a manifest scan per visible row.
    static func mergeMembers(in plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>,
                             family: String) -> [String: Int] {
        guard case .success(let manifest) = plan else { return [:] }
        let prefix = family.isEmpty ? "" : family + "/"
        var members: [String: Set<String>] = [:]
        for action in manifest.actions {
            guard action.action == .moveFile || action.action == .moveDir,
                  let src = action.src, src.hasPrefix(prefix) else { continue }
            let parts = src.dropFirst(prefix.count).split(separator: "/", maxSplits: 2)
            guard parts.count >= 2 else { continue }
            members[String(parts[1]), default: []].insert(String(parts[0]))
        }
        return members.mapValues(\.count)
    }

    /// The folder this mapping runs over, as the header names it: the family path, or for a
    /// seeded pair (one member) the member's own path, since its family can be the empty string.
    static func headerPath(family: String, members: [String]) -> String {
        guard members.count == 1 else { return family }
        return (family as NSString).appendingPathComponent(members[0])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(planFamily)
                .scaledFont(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Text(isSeededPair
                 ? "One mapping for this folder — the operations below are derived from it, "
                    + "never typed."
                 : "One mapping, edited once, applied to every member — the operations below "
                    + "are derived from it, never typed.")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
            if !parallelFamilies.isEmpty {
                // A plan for one family alone can leave its siblings disagreeing with it.
                Text("Shares its vocabulary with \(parallelFamilies.joined(separator: ", ")) — "
                     + "a shape chosen here alone may leave them disagreeing. Worth planning "
                     + "together.")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let groupTable {
                    groupTableDisclosure(groupTable)
                    Toggle(isOn: Binding(get: { planTogether },
                                         set: { planTogether = $0; reseedForGroup($0) })) {
                        Text("Plan all \(groupTable.families.count) together")
                            .scaledFont(.system(size: 10.5, weight: .medium))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(locked)
                    .help("Edits ONE mapping over every child name in the group. Each family’s "
                          + "plan is still derived against its own folders and reviewed "
                          + "separately below, and they land one after another.")
                }
            }
        }
    }


    /// Every family the shared mapping covers — the subject first, then its parallels.
    private var groupFamilies: [String] { groupTable?.families ?? [family] }

    /// Widen or narrow the mapping to the whole group, keeping every target already chosen for
    /// a source that survives the change.
    private func reseedForGroup(_ together: Bool) {
        // Clear the filter with the width: narrowing below `filterAppearsAbove` rows hides the
        // field, and a filter left applied could empty the editor with nothing to undo it.
        filterText = ""
        let sources = together
            ? RestructurePlanner.groupSources(families: groupFamilies, in: liveTree)
            : RestructurePlanner.distinctSources(family: family, members: members, in: liveTree)
        let widened = Self.rewidened(rows: rows, to: sources, remembering: targetsBySource)
        targetsBySource = widened.remembered
        allSources = sources
        rows = widened.rows
    }

    /// Re-cut the mapping to a different set of sources without losing typed work. Narrowing
    /// drops rows, so the targets are remembered apart from `rows`, keyed by source name, which
    /// is what a target is chosen against.
    static func rewidened(rows: [RestructureMapping.Row], to sources: [String],
                          remembering targets: [String: String])
        -> (rows: [RestructureMapping.Row], remembered: [String: String]) {
        var remembered = targets
        for row in rows {
            // A row set back to keep forgets its target, or "keep" couldn't be expressed for a
            // source that leaves and comes back.
            if let target = row.target { remembered[row.source] = target }
            else { remembered[row.source] = nil }
        }
        let rebuilt = sources.map {
            RestructureMapping.Row(source: $0, target: remembered[$0])
        }
        return (adjacentOrder(rebuilt), remembered)
    }

    /// The per-family plans a shared mapping derives. `body` reads it once per render, beside
    /// `derived`, because each read runs the planner with disk listings for every family.
    private var groupPlans: [(family: String,
                              result: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)] {
        RestructurePlanner.groupManifests(
            families: groupFamilies, mapping: RestructureMapping(rows: rows), kind: finding.kind,
            in: liveTree, profileId: profileId, manifestIdPrefix: manifestId, createdAt: createdAt,
            // The subject family is planned over the members this sheet reviewed, not whatever
            // is on disk now, so Apply never touches a member the list never named.
            membersByFamily: [family: members])
    }

    /// The disclosure's line: the count that decides whether opening the grid is worth it. A
    /// group that already agrees says so in words.
    ///
    /// `families` is never below 2: the table exists only when the subject has a parallel
    /// sibling (`seedGroupPointer`), and it lists the subject too.
    static func groupHeaderText(disagreements: Int, families: Int) -> String {
        guard disagreements > 0 else {
            return families == 2 ? "Both families already agree on every name"
                : "These \(families.formatted()) families already agree on every name"
        }
        // "all 2" reads as a typo; two families are "both".
        return "\(disagreements.formatted()) name\(disagreements == 1 ? "" : "s") "
            + "\(disagreements == 1 ? "is" : "are") not shared by "
            + (families == 2 ? "both" : "all \(families.formatted())")
    }

    /// The group as a grid, the sibling pointer opened out. A `DisclosureGroup`, not a permanent
    /// panel: the pointer's sentence is the summary, and the grid is for when that isn't enough.
    @ViewBuilder
    private func groupTableDisclosure(_ table: RestructurePlanner.FamilyGroupTable) -> some View {
        let apart = table.disagreements.count
        DisclosureGroup(isExpanded: $groupTableOpen) {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        ForEach(table.families, id: \.self) { family in
                            Text((family as NSString).lastPathComponent)
                                .scaledFont(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(table.rows, id: \.name) { row in
                        GridRow {
                            Text(row.name)
                                .scaledFont(.system(size: 10.5,
                                                    weight: row.isUniversal ? .regular : .medium))
                                .foregroundStyle(row.isUniversal ? AnyShapeStyle(.secondary)
                                                                 : AnyShapeStyle(.primary))
                            ForEach(Array(row.presentIn.enumerated()), id: \.offset) { cell in
                                // Present or not, nothing else: a count would suggest weight,
                                // and a "wrong" marker would assert a shape before the user
                                // chose one.
                                Text(cell.element ? "✓" : "—")
                                    .scaledFont(.system(size: 10))
                                    .foregroundStyle(cell.element ? AnyShapeStyle(accent)
                                                                  : AnyShapeStyle(.tertiary))
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        } label: {
            Text(Self.groupHeaderText(disagreements: apart, families: table.families.count))
                .scaledFont(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(.automatic)
    }

    // MARK: - 1. The target shape

    @ViewBuilder
    private var shapeSection: some View {
        // A pair carries no schemes, so its label says "name"; the free-text field stays,
        // because naming a target the tree hasn't got is what a rename needs.
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(isSeededPair ? "Target name" : "Target shape")
            // Nothing pre-selected: neither recency nor majority is the authority on the shape.
            ForEach(Array(finding.schemes.enumerated()), id: \.offset) { index, scheme in
                schemeChoice(index: index, scheme: scheme)
            }
            if Self.newestMembersAreDrift(finding) {
                Text("The newest folders here are drift sharing no scheme — there is no current "
                     + "shape, and that is the finding rather than a failure to name one.")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                TextField("Name it myself — add a folder name", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.system(size: 11))
                    .frame(width: 260)
                    .help("Add a target name of your own — one folder name, then Return or Add")
                    .onSubmit(addCustomName)
                Button("Add") { addCustomName() }
                    .scaledFont(.system(size: 11))
                    .disabled(!canAddCustomName())
            }
            if !customName.trimmingCharacters(in: .whitespaces).isEmpty,
               !RestructurePlanner.isValidTargetName(customName) {
                // Why Add is grey, said where the typing happens: a target is one folder name,
                // and a path-shaped one would aim a rename outside the family.
                Text("One folder name — no /, no :, no dot traversal.")
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func schemeChoice(index: Int, scheme: StructureFinding.Scheme) -> some View {
        Button {
            chosenScheme = index
            // The detector lowercases its vocabulary; target names take the disk-cased spelling
            // the family uses. Typed names survive a scheme change, so the user never has to
            // retype them.
            let chosen = scheme.vocabulary.map { word in
                allSources.first { $0.lowercased() == word } ?? word.localizedCapitalized
            }
            let typed = vocabulary.filter { name in
                !allSources.contains(name) && !chosen.contains(name)
            }
            vocabulary = chosen + typed
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: chosenScheme == index ? "largecircle.fill.circle" : "circle")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(chosenScheme == index ? accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(scheme.vocabulary.joined(separator: " · "))
                            .scaledFont(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        if let label = Self.schemeLabel(index: index, in: finding) {
                            Text(label)
                                .scaledFont(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(scheme.members.joined(separator: ", "))
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Use these names as the targets in the mapping below")
        // The chosen state otherwise lives only in an SF-symbol swap — invisible to VoiceOver.
        .accessibilityAddTraits(chosenScheme == index ? [.isSelected] : [])
    }

    /// Whether `Add` can do anything; a name already in the vocabulary would be swallowed
    /// silently.
    func canAddCustomName() -> Bool {
        let name = customName.trimmingCharacters(in: .whitespaces)
        return RestructurePlanner.isValidTargetName(name) && !vocabulary.contains(name)
    }

    private func addCustomName() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        // The planner's rule (one folder name, no separators or traversal), checked at the door:
        // a "Tax/2024" or "../Shared" target would move folders outside the family. The
        // derivation refuses one too; this keeps it out of every picker.
        guard RestructurePlanner.isValidTargetName(name), !vocabulary.contains(name) else {
            return
        }
        vocabulary.append(name)
        chosenScheme = nil
        customName = ""
    }

    // MARK: - 2. The mapping editor

    private func mappingSection(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) -> some View {
        // Both derived once for the whole list, not per row, so a filter keystroke stays linear
        // — see `mergeMembers` and `sourcesWithSimilarNeighbour`.
        let members = Self.mergeMembers(in: plan, family: family)
        let neighboured = Self.sourcesWithSimilarNeighbour(rows)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionLabel(isSeededPair
                             ? "Mapping — one row per name in this folder, default keep"
                             : planTogether
                                ? "Mapping — one row per name found across the group, default keep"
                                : "Mapping — one row per name found across the family, default keep")
                Spacer(minLength: 8)
                Text(Self.mappedCount(rows))
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            // Past a dozen rows the list stops being scannable. The filter narrows the view only:
            // `rows` stays complete, so the derived manifest is the same with a filter active.
            if rows.count > Self.filterAppearsAbove {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Filter names", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(.system(size: 11))
                        .frame(width: 220)
                        .accessibilityLabel("Filter the mapping by name")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach($rows) { $row in
                        if Self.matches(row.source, filter: filterText) {
                            mappingRow($row, members: members, neighboured: neighboured)
                        }
                    }
                }
            }
            .frame(maxHeight: 210)
        }
    }

    private func mappingRow(_ row: Binding<RestructureMapping.Row>,
                            members: [String: Int], neighboured: Set<String>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(row.wrappedValue.source)
                    .scaledFont(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                // A quiet marker saying why this row sits beside its neighbour.
                if neighboured.contains(row.wrappedValue.source) {
                    Image(systemName: "link")
                        .scaledFont(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Near-identical to the row beside it")
                }
            }
            .frame(width: 220, alignment: .leading)
            Picker("", selection: row.target) {
                Text("Keep").tag(String?.none)
                ForEach(pickerTargets(for: row.wrappedValue), id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .labelsHidden()
            // The visible label is the source name to its left; VoiceOver needs the tie made
            // explicit.
            .accessibilityLabel("Target for \(row.wrappedValue.source)")
            .help("Choose the name “\(row.wrappedValue.source)” becomes — Keep leaves it as it is")
            .scaledFont(.system(size: 11))
            .frame(width: 180)
            if let margin = margin(for: row.wrappedValue, members: members) {
                // The cost of a choice, visible where it is made.
                Text(margin)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// The dropdown's names: the chosen vocabulary, plus whatever this row already points at
    /// (a draft can carry a name the current vocabulary no longer lists).
    private func pickerTargets(for row: RestructureMapping.Row) -> [String] {
        var names = vocabulary
        if let target = row.target, !names.contains(target) { names.append(target) }
        return names
    }

    // MARK: - 2b. Refine with Claude (§5.6)

    /// The price beside the button, and why it is off when it is: over the limit, or no price for the
    /// model. Never a dead end: Change Limit… is here.
    @ViewBuilder
    private func refinePriceLine(_ quote: FileSyncManager.MappingRefineQuote?) -> some View {
        if let quote {
            VStack(alignment: .leading, spacing: 3) {
                Text("≈ \(AskClaudeSpend.format(quote.costUSD)) on \(quote.modelName), the chat’s model"
                     + (quote.limitUSD > 0 ? " · this month \(AskClaudeSpend.format(quote.spentUSD)) of \(AskClaudeSpend.format(quote.limitUSD))" : ""))
                    .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if quote.exceedsLimit {
                    HStack(spacing: 8) {
                        Text("This would pass your monthly limit. Raise it, or wait for the month to turn.")
                            .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let onChangeLimit { Button("Change Limit…", action: onChangeLimit).controlSize(.small) }
                    }
                }
            }
        } else if refineQuote != nil {
            Text("Refine Names isn’t available on \(refineModelLabel): no price is known for it, so the cost can’t be checked. "
                 + "Switch the chat to another model in the Ask Claude panel.")
                .scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var refineSection: some View {
        if onRefineMapping != nil {
            let quote = refineQuote?(refineRequest())
            VStack(alignment: .leading, spacing: 6) {
                if refineOffered {
                    HStack(spacing: 10) {
                        // The one live control while a refine is in flight, since the footer
                        // holds Cancel; without it a hung request leaves the sheet dead for the
                        // transport's 90 s timeout.
                        Button {
                            refining ? stopRefine() : runRefine()
                        } label: {
                            Label(refining ? "Stop Asking"
                                  : "Ask \(refineModelLabel) About \(rows.count) Folder "
                                    + "Name\(rows.count == 1 ? "" : "s")",
                                  systemImage: refining ? "stop.circle" : "sparkles")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(rows.isEmpty || (!refining && quote?.exceedsLimit == true) || (!refining && refineQuote != nil && quote == nil))
                        .help(refining
                              ? "Stop waiting for the answer — a request already sent may still bill"
                              : "Send these folder names to \(refineModelLabel) for proposed names — "
                                + "billed to your API key. Nothing changes until you accept a proposal.")
                        Toggle("Include up to 5 file names per folder", isOn: $includeFileSamples)
                            .toggleStyle(.checkbox)
                            .scaledFont(.system(size: 10.5))
                            .disabled(refining)
                            .help("Also send up to 5 file names from each folder, so the model can "
                                  + "see what’s inside. File contents are never sent.")
                    }
                    refinePriceLine(quote)
                    // The itemised payload disclosure, at the button rather than behind it; the
                    // toggle's clause appears only when the toggle is on.
                    Text(Self.payloadDisclosure(includesFileNames: includeFileSamples,
                                                acrossGroup: planTogether))
                        // Consent copy (what leaves the machine, who pays), so it is set to be
                        // read: 11pt secondary, never the faint tertiary.
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let onConfigureRefine {
                    Button(action: onConfigureRefine) {
                        Label("Refine Names with Claude…", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Proposes consistent names for this family’s folders — billed to your "
                          + "own API key, set up in Settings ▸ Organize. The mapping stays "
                          + "yours: accepting a proposal edits a row, and the plan re-derives.")
                }
                if let refineFailedText {
                    Text(refineFailedText)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if let proposals {
                    proposalList(proposals)
                }
            }
        }
    }

    @ViewBuilder
    private func proposalList(_ proposals: [MappingRefineProposal]) -> some View {
        // Capped and scrollable like the mapping, the operations and the preview, so many
        // wrapped proposals can't push the footer off a short display.
        ScrollView { proposalRows(proposals) }
            .frame(maxHeight: 170)
    }

    private func proposalRows(_ proposals: [MappingRefineProposal]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(proposals) { proposal in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(proposal.source)
                        .scaledFont(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: 180, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.proposalLine(proposal))
                            .scaledFont(.system(size: 10.5,
                                                weight: proposal.verdict == .declined
                                                    ? .regular : .medium))
                            .foregroundStyle(proposal.verdict == .declined
                                             ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        Text(proposal.why)
                            .scaledFont(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // A proposal that reverses another, or the user's own row, is labelled,
                        // or a reviewer reads the pair as a bug.
                        if let note = MappingRefineProtocol.reversalNote(for: proposal,
                                                                         among: proposals,
                                                                         rows: rows) {
                            // A warm capsule, not warm text: amber 9.5pt text fails contrast, so
                            // the tint is a fill under `.secondary` text, like the radius chip
                            // and the crowding tag.
                            Text(note)
                                .scaledFont(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 1)
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Color.orange.opacity(0.16)))
                        }
                    }
                    Spacer(minLength: 4)
                    if let accepted = acceptedTarget(of: proposal),
                       rows.first(where: { $0.source == proposal.source })?.target != accepted {
                        Button("Accept") { accept(proposal) }
                            // Every row says "Accept"; VoiceOver needs each to name its proposal.
                            .accessibilityLabel(
                                "Accept for \(proposal.source): \(Self.proposalLine(proposal))")
                            .scaledFont(.system(size: 10.5, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(accent)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Radius.well).fill(.quaternary.opacity(0.2)))
    }

    /// What accepting would set the row's target to — nil-in-optional for keep, absent for
    /// declined (nothing to accept).
    private func acceptedTarget(of proposal: MappingRefineProposal) -> String?? {
        switch proposal.verdict {
        case .propose(let target): return .some(target)
        case .keep: return .some(nil)
        case .declined: return nil
        }
    }

    /// No path to the disk that skips the manifest: accepting edits the mapping row, and the
    /// derivation and review re-run as for any edit.
    private func accept(_ proposal: MappingRefineProposal) {
        guard let target = acceptedTarget(of: proposal),
              let index = rows.firstIndex(where: { $0.source == proposal.source }) else { return }
        rows[index].target = target
        if let newTarget = target, !vocabulary.contains(newTarget) {
            vocabulary.append(newTarget)
        }
    }

    private func runRefine() {
        guard !refining, let onRefineMapping else { return }
        let request = refineRequest()
        refining = true
        refineFailedText = nil
        // A failed run must not leave an earlier run's proposals under its failure sentence.
        proposals = nil
        refineTask = Task { @MainActor in
            let outcome = await onRefineMapping(request)
            // Stopped by hand: `stopRefine` already wrote the sentence, and the cancelled
            // transport's answer (usually `.unavailable`) must not replace it.
            guard !Task.isCancelled else { return }
            refining = false
            switch outcome {
            case .proposals(let result):
                proposals = result
            case .overLimit:
                refineFailedText = "Nothing was sent — it would pass your monthly Claude limit. "
                    + "Raise it in Settings ▸ Ask Claude, or wait for the month to turn."
            case .hiddenFromClaude:
                refineFailedText = "Nothing was sent — part of this family is hidden from Claude."
            case .unavailable:
                refineFailedText = "The pass didn’t run — the key, the monthly limit or the "
                    + "network said no. Settings ▸ Ask Claude has the details."
            }
        }
    }

    private func stopRefine() {
        refineTask?.cancel()
        refineTask = nil
        refining = false
        // Cancelling stops the wait; a request already sent may still complete and bill.
        refineFailedText = "Stopped — nothing was accepted. If the request had already gone "
            + "out, it may still bill."
    }

    private func refineRequest() -> MappingRefineRequest {
        var samples: [String: [String]] = [:]
        if includeFileSamples {
            for row in rows {
                var names: [String] = []
                for member in members where names.count < 5 {
                    let path = (((family as NSString).appendingPathComponent(member))
                        as NSString).appendingPathComponent(row.source)
                    if let files = tree.files(path) {
                        names.append(contentsOf: files.prefix(5 - names.count))
                    }
                }
                if !names.isEmpty { samples[row.source] = names }
            }
        }
        var vocabularies = finding.schemes.map(\.vocabulary)
        if !vocabulary.isEmpty { vocabularies.append(vocabulary) }
        // `family`, not `planFamily`: consumers read a member as a child of the family, and on
        // a seeded pair `planFamily` is already `family/member`, which would double the member.
        // With the group on, `rows` holds every sibling family's child names too, so the hidden
        // check must read their members as well as this family's.
        let drawnFrom = planTogether
            ? groupFamilies.flatMap { group in
                (liveTree.childFolders(group) ?? []).map { (group as NSString).appendingPathComponent($0) }
            }
            : members.map { (family as NSString).appendingPathComponent($0) }
        return MappingRefineRequest(family: family, members: members, rows: rows,
                                    candidateVocabularies: vocabularies,
                                    sampleFileNames: samples, drawnFrom: drawnFrom)
    }

    /// The disclosure sentence, itemised: the toggle's clause exactly when the payload carries
    /// it, and the never-clause always.
    ///
    /// `acrossGroup` is not cosmetic: with the group toggle on, `rows` carries the sibling
    /// families' names too, and a disclosure must never understate what leaves the machine.
    static func payloadDisclosure(includesFileNames: Bool, acrossGroup: Bool = false) -> String {
        var sent = acrossGroup
            ? "Sends the folder paths, member names and candidate names of this family AND the "
                + "sibling families you are planning with it"
            : "Sends this family’s folder paths, member names and candidate names"
        if includesFileNames { sent += ", plus up to 5 file names per folder" }
        return sent + ". File contents are never sent. Billed to your API key."
    }

    /// One proposal's verdict, as its row's first line.
    static func proposalLine(_ proposal: MappingRefineProposal) -> String {
        switch proposal.verdict {
        case .propose(let target): return "→ \(target)"
        case .keep: return "keep"
        case .declined: return "declined — not enough evidence to say"
        }
    }

    // MARK: - 3. Review

    private var derived: Result<RestructureManifest, RestructurePlanner.PlanRefusal> {
        RestructurePlanner.manifest(
            family: family, members: members,
            mapping: RestructureMapping(rows: rows), kind: finding.kind, in: liveTree,
            profileId: profileId, manifestId: manifestId, createdAt: createdAt,
            // What the landing is called. For a seeded pair the family is the grandparent, which
            // would head the ledger card "Across the tree" for folders inside one parent.
            recordedFamily: planFamily)
    }

    /// What each family's own plan comes to: the group at a glance, beside the subject's full
    /// list. A family whose plan refuses is shown, not dropped.
    @ViewBuilder
    private func groupReview(
        _ plans: [(family: String,
                   result: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)])
        -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(plans, id: \.family) { plan in
                HStack(spacing: 6) {
                    Text((plan.family as NSString).lastPathComponent)
                        .scaledFont(.system(size: 10.5, weight: .medium))
                    Spacer(minLength: 6)
                    switch plan.result {
                    case .success(let manifest):
                        Text(RestructureLedger(of: manifest).summary)
                            .scaledFont(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    case .failure(let refusal):
                        Text(Self.refusalText(refusal))
                            .scaledFont(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.18)))
    }

    @ViewBuilder
    private func reviewSection(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>,
        group: [(family: String,
                 result: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)])
        -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Derived operations")
            // A batch never skips the per-family review: one shared row can be right for this
            // family and wrong for a sibling, so each family's counts are derived separately.
            if !group.isEmpty { groupReview(group) }
            switch plan {
            case .success(let manifest):
                Text(RestructureLedger(of: manifest).summary)
                    .scaledFont(.system(size: 11, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Self.operationLines(of: manifest, walkedFamily: family),
                                id: \.self) { line in
                            Text(line)
                                .scaledFont(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                // The operations say what runs; this says what it leaves. One member is enough,
                // since the mapping applies to all alike and the list above is exhaustive.
                if let exemplar = Self.previewMember(of: manifest, family: family,
                                                    members: members),
                   let preview = RestructurePlanner.preview(member: exemplar, in: manifest,
                                                            tree: liveTree) {
                    treePreview(exemplar, preview)
                }
            case .failure(let refusal):
                Text(Self.refusalText(refusal))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Which member the before/after is drawn for: the first one the plan touches, in manifest
    /// order, since an untouched member would draw two identical columns.
    ///
    /// A static rule so a test can check it: a render comparison can't, because sheets with
    /// different plans differ elsewhere too.
    static func previewMember(of manifest: RestructureManifest,
                              family: String, members: [String]) -> String? {
        for action in manifest.actions where action.action != .keep {
            guard let path = action.src ?? action.dst else { continue }
            for member in members {
                let full = (family as NSString).appendingPathComponent(member)
                if RestructurePaths.isInside(path, of: full) { return full }
            }
        }
        return nil
    }

    /// Two mono columns — the member as it stands, and as this plan would leave it.
    private func treePreview(_ member: String,
                             _ preview: RestructurePlanner.RestructurePreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\((member as NSString).lastPathComponent) — before and after")
                .scaledFont(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            // Capped and scrollable, like the mapping and the operations: the sheet has no outer
            // ScrollView, so a big member at the largest text size would push the footer off
            // the display.
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    previewColumn("NOW", rows: preview.before)
                    previewColumn("AFTER", rows: preview.after)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
        }
    }

    private func previewColumn(_ title: String,
                               rows: [RestructurePlanner.RestructurePreview.Row]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .scaledFont(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .scaledFont(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let files = row.files {
                        Text("\(files)")
                            .scaledFont(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                if let note = Self.fateNote(row.fate) {
                    Text(note)
                        .scaledFont(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.18)))
    }

    /// What became of a row, in the after column's words. nil for a folder the plan never
    /// touched, so the notes that appear are worth reading.
    static func fateNote(_ fate: RestructurePlanner.RestructurePreview.Fate) -> String? {
        switch fate {
        case .renamedFrom(let old): return "was \(old)"
        case .mergedFrom(let old, let sources):
            let absorbed = "absorbed \(sources.joined(separator: ", "))"
            return old.map { "was \($0), " + absorbed } ?? absorbed
        case .created: return "created"
        case .kept: return "kept — no slot in the target shape"
        case .unchanged: return nil
        }
    }

    // MARK: - Footer

    private func footer(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>,
        group: [(family: String,
                 result: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)])
        -> some View {
        HStack(spacing: 10) {
            switch outcome {
            case .exported(let name):
                Text("Exported as \(name) — nothing has been moved.")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .applied(let summary):
                Text("Applied — \(summary).")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .failed(let sentence):
                Text(sentence)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            case nil:
                if Self.closeDropsEdit(plan: plan, rows: rows, vocabulary: vocabulary,
                                       baseline: baseline, landedOrExported: landedOrExported) {
                    Text(Self.closeDropsEditSentence)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            // The one way to drop a saved plan without landing it. Destructive, never the
            // default and with no key: ⏎ stays on Export, the safe act.
            if baseline.hasDraft, onDiscardDraft != nil, !isApplied, alreadyLanded.isEmpty {
                Button("Discard Plan", role: .destructive) {
                    onDiscardDraft?()
                    onClose()
                }
                    .scaledFont(.system(size: 11))
                    .disabled(applying || refining)
                    .help("Removes this saved plan, so its card no longer shows it as planned. "
                          + "Nothing moves, and an exported file stays where it is.")
            }
            // Held while an apply or a paid refine is in flight: a close mid-apply reads as
            // abort, but the landing keeps running, and its refusal or the paid proposals would
            // arrive in a torn-down view.
            let disposition = Self.closeDisposition(
                plan: plan, rows: rows, vocabulary: vocabulary, baseline: baseline,
                landedOrExported: landedOrExported)
            Button(Self.closeTitle(applied: isApplied, disposition: disposition,
                                   hasDraft: baseline.hasDraft,
                                   landedOrExported: landedOrExported)) {
                switch disposition {
                case .keep(let manifest): onKeepDraft?(manifest, vocabulary)
                case .discard: onDiscardDraft?()
                case .nothing: break
                }
                onClose()
            }
                .scaledFont(.system(size: 11))
                .keyboardShortcut(.cancelAction)
                .disabled(applying || refining)
            // Export keeps ⏎, the safe act; landing is a deliberate click styled as destructive.
            // Disabled once applied: a draft saved after the landing would mark operations that
            // just ran as "Planned, not applied". Exports the whole group when the group is
            // being planned. No ellipsis: it writes the file and keeps the plan at once.
            Button(group.isEmpty ? "Export Plan" : "Export \(group.count) Plans") {
                if group.isEmpty { exportPlan(plan) } else { exportGroup(group) }
            }
                .scaledFont(.system(size: 11, weight: .semibold))
                .keyboardShortcut(.defaultAction)
                .accentedProminent()
                .help(group.isEmpty
                      ? "Keep this plan without running it — saved as a dated JSON file beside your "
                        + "folder survey. Nothing moves."
                      : "Keep these \(group.count) plans without running them — each saved as a dated "
                        + "JSON file beside your folder survey. Nothing moves.")
                .disabled(group.isEmpty
                          ? ((try? plan.get()) == nil || applying || isApplied)
                          : (group.allSatisfy { (try? $0.result.get()) == nil }
                             || applying || isApplied))
            if let onApply {
                if !group.isEmpty {
                    let landable = group.compactMap { try? $0.result.get() }
                        .filter { !alreadyLanded.contains($0.manifestId) }
                    Button(applying
                           ? "Applying…"
                           : "Apply to \(landable.count) \(landable.count == 1 ? "Family" : "Families")") {
                        applyGroup(group, onApply)
                    }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .disabled(landable.isEmpty || applying || isApplied)
                        .lockedDuringRun()
                        .help("Lands each family’s own plan, one after another — never at once, "
                              + "because each landing re-derives the survey the next one reads. "
                              + "It stops at the first refusal, leaving the rest unrun.")
                } else {
                    Button(applyTitle(plan)) { apply(plan, onApply) }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                        .disabled((try? plan.get()) == nil || applying || isApplied)
                        .lockedDuringRun()
                        .help("Runs the reviewed operations now: renames and merges on disk, one "
                              + "grouped ⌘Z, the inverse in the ledger, and the survey "
                              + "re-derived.")
                }
            }
        }
    }

    /// The landing's eight steps as they run. The order is the point: the inverse reaches disk
    /// before anything moves, and the verify is a separate pass afterwards.
    private func progressChecklist(_ progress: RestructureApplyProgress) -> some View {
        RestructureApplyChecklist(progress: progress, accent: accent)
    }
}

/// The landing's eight steps as they run, for whichever sheet is landing: a pair merge runs
/// the same `applyPlan` in the same inverse-first order.
struct RestructureApplyChecklist: View {
    let progress: RestructureApplyProgress
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RestructureApplyProgress.Stage.allCases, id: \.rawValue) { stage in
                HStack(spacing: 6) {
                    Image(systemName: RestructurePlanSheet.stageSymbol(stage, current: progress.stage))
                        .scaledFont(.system(size: 9))
                        .foregroundStyle(stage < progress.stage ? AnyShapeStyle(accent)
                                                                : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    Text(stage == progress.stage ? progress.line()
                                                 : RestructureApplyProgress.label(stage))
                        .scaledFont(.system(size: 10.5,
                                            weight: stage == progress.stage ? .semibold
                                                                            : .regular))
                        .foregroundStyle(stage <= progress.stage ? AnyShapeStyle(.secondary)
                                                                 : AnyShapeStyle(.tertiary))
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Applying — \(progress.line())")
    }
}

extension RestructurePlanSheet {

    /// Done, doing, still to come. A landing only moves forward, so a stage behind the current
    /// one is finished and one ahead has not started.
    static func stageSymbol(_ stage: RestructureApplyProgress.Stage,
                            current: RestructureApplyProgress.Stage) -> String {
        if stage < current { return "checkmark.circle.fill" }
        if stage == current { return "circle.dotted" }
        return "circle"
    }

    private var isApplied: Bool {
        if case .applied = outcome { return true }
        return false
    }

    /// An export is cleared by the next edit (see the `onChange`s above), so a standing one means
    /// the draft on disk already is this plan, with its file name — which a re-save would drop.
    private var landedOrExported: Bool {
        switch outcome {
        case .applied, .exported: return true
        case .failed, nil: return !alreadyLanded.isEmpty
        }
    }

    private func applyTitle(_ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)
        -> String {
        // `operationCount`, not `actions.count`: keeps are the signature block, not operations.
        let count = (try? plan.get())?.operationCount ?? 0
        return applying ? "Applying…" : "Apply \(count) Operation\(count == 1 ? "" : "s")"
    }

    private func apply(_ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>,
                       _ run: @escaping (RestructureManifest) async -> ApplyResult) {
        // `.disabled` holds only if SwiftUI re-rendered between a double-click's two clicks;
        // this guard is what stops a second apply racing the first.
        guard !applying, let manifest = try? plan.get() else { return }
        applying = true
        // Frozen for the whole landing — see `applyingPlan`.
        applyingPlan = .success(manifest)
        Task { @MainActor in
            let result = await run(manifest)
            applying = false
            switch result {
            case .applied(let summary):
                // Freeze the review on what actually ran, before the next render re-derives
                // against the tree this landing just changed.
                landedPlan = .success(manifest)
                applyingPlan = nil
                outcome = .applied(summary)
            case .refused(let refusal):
                // Nothing landed, so the sheet derives from the mapping again, to edit against.
                applyingPlan = nil
                outcome = .failed(refusal)
            }
        }
    }

    /// Land each family's plan in turn.
    ///
    /// Sequentially, never in parallel: every landing re-derives the survey and replaces the
    /// active profile, so a second at once would run against a profile the first invalidated.
    ///
    /// Stops at the first refusal, rather than leaving the tree half-reorganised in ways the
    /// reader must untangle. What landed before it stays landed, each under its own manifest id
    /// and undoable on its own.
    ///
    /// A retry resumes rather than restarting: `applyPlan` refuses a repeat manifest id and the
    /// sheet's ids are stable, so `alreadyLanded` skips the families that already succeeded.
    private func applyGroup(
        _ plans: [(family: String,
                   result: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)],
        _ run: @escaping (RestructureManifest) async -> ApplyResult) {
        guard !applying else { return }
        let landable = plans
            .compactMap { plan -> (String, RestructureManifest)? in
                (try? plan.result.get()).map { (plan.family, $0) }
            }
            .filter { !alreadyLanded.contains($0.1.manifestId) }
        guard !landable.isEmpty else { return }
        applying = true
        // The group's own freeze, for `applyingPlan`'s reason: `groupPlans` runs the planner
        // once per family.
        applyingGroup = plans
        Task { @MainActor in
            var landed: [String] = []
            var refusal: String?
            for (family, manifest) in landable {
                switch await run(manifest) {
                case .applied(let summary):
                    alreadyLanded.insert(manifest.manifestId)
                    landed.append("\((family as NSString).lastPathComponent): \(summary)")
                case .refused(let sentence):
                    refusal = "\((family as NSString).lastPathComponent) refused — \(sentence)"
                }
                if refusal != nil { break }
            }
            applying = false
            // The review freezes on these plans whatever ran, so after a partial apply the
            // remaining families keep their reviewed operations on screen for the retry.
            landedGroup = GroupFreeze(plans: plans, rows: rows, together: planTogether)
            applyingGroup = nil
            if let refusal {
                outcome = .failed(landed.isEmpty
                    ? refusal
                    : refusal + ". Landed before it: " + landed.joined(separator: "; ")
                        + " — each is undoable on its own.")
            } else {
                outcome = .applied(landed.joined(separator: "; "))
            }
        }
    }

    typealias GroupPlan = (family: String,
                           result: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)

    /// A group landing's plans, with the mapping they were planned from.
    struct GroupFreeze {
        let plans: [GroupPlan]
        let rows: [RestructureMapping.Row]
        let together: Bool
    }

    /// The group the review shows and Apply runs.
    ///
    /// While a landing runs, the plans it started with. Once it has run, the plans it ran, so after
    /// a partial apply the rest of the group keeps its reviewed operations on screen for the retry,
    /// but only while the mapping is the one they came from. A refusal unlocks the mapping, and a
    /// retry after an edit has to land the edited plans: the frozen ones would apply the manifests
    /// from before it. A family that already landed keeps the plan it landed with.
    static func shownGroup(landed: GroupFreeze?, applying: [GroupPlan]?,
                           rows: [RestructureMapping.Row], together: Bool,
                           alreadyLanded: Set<String>, live: () -> [GroupPlan]) -> [GroupPlan] {
        if let applying { return applying }
        guard let landed else { return together ? live() : [] }
        if landed.rows == rows, landed.together == together { return landed.plans }
        guard together else { return [] }
        return live().map { plan in
            guard let frozen = landed.plans.first(where: { $0.family == plan.family }),
                  let manifest = try? frozen.result.get(),
                  alreadyLanded.contains(manifest.manifestId) else { return plan }
            return frozen
        }
    }

    /// Export every family's plan, one file each, the shape the landing takes, so the files
    /// match what Apply would run.
    private func exportGroup(
        _ plans: [(family: String,
                   result: Result<RestructureManifest, RestructurePlanner.PlanRefusal>)]) {
        var names: [String] = []
        var failure: String?
        for plan in plans {
            guard let manifest = try? plan.result.get() else { continue }
            switch onExport(manifest, vocabulary) {
            case .saved(let filename): names.append(filename)
            case .failed(let sentence): failure = sentence
            }
            if failure != nil { break }
        }
        // Every file written saved a draft beside it, a partial group included.
        if !names.isEmpty { baseline.exported(rows: rows, vocabulary: vocabulary) }
        if let failure {
            outcome = .failed(names.isEmpty ? failure
                              : failure + " Written before it: " + names.joined(separator: ", "))
        } else {
            outcome = .exported(names.joined(separator: ", "))
        }
    }

    private func exportPlan(
        _ plan: Result<RestructureManifest, RestructurePlanner.PlanRefusal>) {
        guard let manifest = try? plan.get() else { return }
        switch onExport(manifest, vocabulary) {
        case .saved(let filename):
            baseline.exported(rows: rows, vocabulary: vocabulary)
            outcome = .exported(filename)
        case .failed(let failure): outcome = .failed(failure)
        }
    }

    // MARK: - Small pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .scaledFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    /// "merges into `Forms` in 3 members": how many members this row's choice makes a merge in,
    /// read off ``mergeMembers(in:family:)`` (derived once per render), so the margin can never
    /// disagree with the review below.
    private func margin(for row: RestructureMapping.Row, members: [String: Int]) -> String? {
        guard let target = row.target, target != row.source,
              let memberCount = members[row.source], memberCount > 0 else { return nil }
        return "merges into \(target) in \(memberCount) member\(memberCount == 1 ? "" : "s")"
    }

    // MARK: - Static rules (tested without the view)

    /// The label a scheme wears in the chooser: what it is, never a recommendation. *The largest
    /// group* for the widest membership; *the most recent* from the members' year tokens, never
    /// from scheme order.
    static func schemeLabel(index: Int, in finding: StructureFinding) -> String? {
        // Labels tell choices apart; on a lone scheme "the most recent" would read as a
        // recommendation.
        guard finding.schemes.count > 1 else { return nil }
        var parts: [String] = []
        if index == 0 { parts.append("the largest group") }
        if index == mostRecentSchemeIndex(of: finding) { parts.append("the most recent") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The vouched scheme whose members reach the newest year — nil when no member of any scheme
    /// carries a year token at all.
    static func mostRecentSchemeIndex(of finding: StructureFinding) -> Int? {
        let newest = finding.schemes.enumerated().compactMap { index, scheme -> (Int, Int)? in
            let years = scheme.members.compactMap(maxYear(in:))
            guard let top = years.max() else { return nil }
            return (index, top)
        }
        return newest.max { $0.1 < $1.1 }?.0
    }

    /// True when the newest members are drift or shapeless: then there is no current shape, and
    /// the sheet says so.
    static func newestMembersAreDrift(_ finding: StructureFinding) -> Bool {
        let driftYears = (finding.drift + finding.shapeless).compactMap(maxYear(in:))
        let schemeYears = finding.schemes.flatMap(\.members).compactMap(maxYear(in:))
        guard let newestDrift = driftYears.max() else { return false }
        guard let newestScheme = schemeYears.max() else { return true }
        return newestDrift > newestScheme
    }

    /// The largest plausible year token in a member's name — `2016-2019` reads 2019,
    /// `IRS Docs - 2023` reads 2023, `CA State` reads nothing.
    static func maxYear(in name: String) -> Int? {
        var years: [Int] = []
        var digits = ""
        for character in name + " " {
            if character.isNumber {
                digits.append(character)
            } else {
                if digits.count == 4, let year = Int(digits), (1900...2200).contains(year) {
                    years.append(year)
                }
                digits = ""
            }
        }
        return years.max()
    }

    /// The review list: renames one line each, a merge one line per source-into-target with its
    /// file and folder counts, keeps by name, every line prefixed by its member.
    static func operationLines(of manifest: RestructureManifest,
                               walkedFamily: String? = nil) -> [String] {
        // The family the paths were walked from, not always the recorded one: a seeded pair
        // records the member's own path, and stripping that would yield the child name.
        let family = walkedFamily ?? manifest.family
        let familyPrefix = family.isEmpty ? "" : family + "/"
        func member(of path: String?) -> String {
            guard let path, path.hasPrefix(familyPrefix) else { return "" }
            return String(path.dropFirst(familyPrefix.count).split(separator: "/").first ?? "")
        }
        func name(_ path: String?) -> String {
            ((path ?? "") as NSString).lastPathComponent
        }
        // A merge is many primitive moves; the sheet groups them per (source dir, target dir),
        // and every line keeps the position its first action held, so the list reads in the
        // order the manifest runs.
        var ordered: [(order: Int, text: String)] = []
        var mergeCounts: [String: (member: String, source: String, target: String,
                                   files: Int, folders: Int, order: Int)] = [:]
        for (index, action) in manifest.actions.enumerated() {
            switch action.action {
            case .renameDir:
                let carried = action.filesCarried ?? 0
                ordered.append((index, "\(member(of: action.src)) · rename \(name(action.src)) → "
                    + "\(name(action.dst)) (\(carried) file\(carried == 1 ? "" : "s"))"))
            case .moveFile, .moveDir:
                let sourceDir = ((action.src ?? "") as NSString).deletingLastPathComponent
                let targetDir = ((action.dst ?? "") as NSString).deletingLastPathComponent
                let key = sourceDir + "→" + targetDir
                var entry = mergeCounts[key] ?? (member(of: action.src), name(sourceDir),
                                                 name(targetDir), 0, 0, index)
                if action.action == .moveFile { entry.files += 1 } else { entry.folders += 1 }
                mergeCounts[key] = entry
            case .keep:
                ordered.append((index, "\(member(of: action.src)) · keep \(name(action.src))"))
            case .createDir:
                ordered.append((index, "\(member(of: action.dst)) · create \(name(action.dst))/"))
            case .removeEmptyDir:
                ordered.append((index,
                                "\(member(of: action.src)) · remove empty \(name(action.src))/"))
            }
        }
        for entry in mergeCounts.values {
            var counts = ["\(entry.files) file\(entry.files == 1 ? "" : "s")"]
            if entry.folders > 0 {
                counts.append("\(entry.folders) folder\(entry.folders == 1 ? "" : "s")")
            }
            ordered.append((entry.order, "\(entry.member) · merge \(entry.source) into "
                + "\(entry.target) (\(counts.joined(separator: ", ")))"))
        }
        return ordered.sorted { $0.order < $1.order }.map(\.text)
    }

    static func refusalText(_ refusal: RestructurePlanner.PlanRefusal) -> String {
        switch refusal {
        case .nothingMapped:
            return "Every row is keep — nothing would change. Map at least one name to see the "
                + "operations it derives."
        case .unknownFiles(let source):
            return "A merge needs the files inside \(source), and they could not be listed. "
                + "Check the folder is reachable and try again."
        case .unresolvableOrder(let member):
            return "The mapping loops through a merge in \(member) in a way that cannot be "
                + "ordered safely. Simplify the circular renames and try again."
        case .conflictingTargets(let first, let second):
            return "\(first) and \(second) differ only by capitalization, and this volume "
                + "cannot hold both side by side. Pick one spelling."
        case .targetTakenByCase(let target, let standing, let member):
            return "\(member) already holds \(standing), which differs from \(target) only by "
                + "capitalization — the volume cannot hold both. Map \(standing) to \(target) "
                + "to step its case up, reuse its spelling — or, if this plan moves "
                + "\(standing) elsewhere, land that change on its own first."
        case .duplicateMappingRows(let source):
            return "The mapping lists \(source) on two rows, and the rows may disagree — one "
                + "row per name. Remove the duplicate and try again."
        case .invalidTargetName(let target):
            return "“\(target)” is not one folder name — a target cannot carry a path "
                + "separator or dot traversal. Rename it to a single name and try again."
        case .targetTakenByFile(let target, let member):
            return "\(member) holds a FILE named \(target), and a folder cannot take a "
                + "standing file’s name. Move or rename the file first."
        }
    }

    /// The shared stamp, for callers composing their own manifest ids (the removal step).
    static func nowStamp() -> String { stamp(Date()) }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}
