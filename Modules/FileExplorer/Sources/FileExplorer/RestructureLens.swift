import SwiftUI
import Design
import Sync

/// What a card needs to say about a saved draft — the operation count for the trigger's words,
/// the ledger sentence for the inline line. Derived from the store's draft by the workspace, so
/// the lens never reads the store itself.
struct PlannedPlanInfo: Equatable {
    let operations: Int
    let summary: String
    /// The blast radius as numbers, once a draft makes them knowable. **Derived from the draft's
    /// own manifest** by the workspace — never pasted, and never estimated from the finding: the
    /// card's prose sentence is what the finding alone can honestly say.
    let renames: Int
    /// Folders that travel intact to a new parent. **Its own count, not folded into renames**:
    /// the ledger sentence one line below prints it as its own clause, and folding it in made a
    /// card read "1 rename" above "0 renames · 1 folder carried whole".
    let carried: Int
    let merges: Int
    let filesMove: Int

    /// The three chips a card shows in place of its blast-radius sentence — the zero ones stay
    /// out, so a rename-only plan says "3 renames" rather than "3 renames · 0 merges".
    var radiusChips: [(text: String, movesFiles: Bool)] {
        var out: [(String, Bool)] = []
        if renames > 0 { out.append(("\(renames) rename\(renames == 1 ? "" : "s")", false)) }
        if carried > 0 {
            out.append(("\(carried) folder\(carried == 1 ? "" : "s") carried", true))
        }
        if merges > 0 { out.append(("\(merges) merge\(merges == 1 ? "" : "s")", false)) }
        if filesMove > 0 {
            // The VERB agrees, not just the noun: one file moves, many files move.
            out.append(("\(filesMove) file\(filesMove == 1 ? " moves" : "s move")", true))
        }
        return out
    }
}

/// One ledger record, as the card needs it — §5.7's Applied and Undone states. Derived from the
/// store's `applied` section by the workspace; the lens never reads the store itself.
struct ReorganisationDisplay: Equatable, Identifiable {
    let manifestId: String
    let family: String
    /// The landing's stamp, as recorded.
    let at: String
    /// The ledger sentence — derived from what happened, never pasted.
    let summary: String
    let undoneAt: String?
    let undoSummary: String?
    /// True when a ledger undo is offered: the landing produced a profile to re-point back from
    /// and has not been undone.
    let canUndo: Bool
    /// True when the landing drained folders the removal sheet could take (§5.5's opt-in step).
    let hasEmptiedFolders: Bool
    /// Step 4's verdict, as the card states it — nil when the landing has none to state, which
    /// is every record written before the field existed and every landing that never reached the
    /// verifier. Silence, not a claim.
    var verifierLine: String?
    /// Why this record cannot be undone yet, when something newer stands in the way. nil on the
    /// one record that IS undoable and on every record that has been undone.
    var blockedReason: String?
    var id: String { manifestId }

    /// The ledger's records as the cards state them — **the whole mapping, as one rule.**
    ///
    /// Extracted from the workspace's private `reorganisationDisplays`, where every clause below
    /// was unreachable from a test: mutating the verdict to `nil`, or dropping the `undoneAt`
    /// half of the block reason so an undone landing claimed something newer was in its way,
    /// left the suite green. `stillHasEmptiedFolders` is the one disk probe, passed in.
    static func rows(from records: [RestructureStore.AppliedRecord],
                     undoableId: String?,
                     stillHasEmptiedFolders: (RestructureManifest) -> Bool)
        -> [ReorganisationDisplay] {
        records
            .filter { $0.appliedUnderProfileId != nil }
            .reversed()
            .map { record in
                ReorganisationDisplay(
                    manifestId: record.manifest.manifestId,
                    family: record.manifest.family,
                    at: record.at,
                    summary: record.summary
                        ?? "this landing did not finish recording — the log from its run has the "
                        + "detail",
                    undoneAt: record.undoneAt,
                    undoSummary: record.undoSummary,
                    canUndo: record.manifest.manifestId == undoableId,
                    // Disk-probed, like `scaffoldedSubjects`: `emptiedFolders(of:)` is a pure
                    // function of the manifest, so on its own the button would outlive its own
                    // landing forever — reopening a sheet of "already removed" rows over a
                    // permanently disabled button.
                    hasEmptiedFolders: record.undoneAt == nil && record.summary != nil
                        && stillHasEmptiedFolders(record.manifest),
                    verifierLine: RestructureLens.verifierLine(verifiedOK: record.verifiedOK,
                                                               note: record.verifierNote),
                    // **The store's order, never the view's.** `undoableReorganisation` is the
                    // one spelling the engine and the Organize menu also read; a second copy
                    // here is how a card ends up offering an undo the engine refuses.
                    blockedReason: record.undoneAt == nil && undoableId != nil
                        && record.manifest.manifestId != undoableId
                        ? RestructureLens.blockedByNewerText : nil)
            }
    }
}

/// Organize ▸ Restructure: families of sibling folders that were shaped differently at different
/// times.
///
/// **Reporting first, acting only through reviewed plans.** A finding says *these thirteen
/// folders use four different internal shapes*. Two actions exist so far, both bounded: the
/// backlog scaffold (create-only, one ⌘Z) and §5.4's `Plan…`, which derives a manifest from a
/// family mapping and ends at `Export plan…` — a reviewable file and a saved draft, with nothing
/// moved. The Apply that lands a manifest is §5.5's, behind its six invariants.
///
/// The states are distinct on purpose, and none borrows another's words: **no profile** means the
/// detectors have nothing to read, **no findings** means they ran and the tree agrees with
/// itself, a list means it does not — and a card with a draft says **Planned, not applied**
/// (§5.7), which is a claim about a file, never about the tree.
struct RestructureLens: View {
    let findings: [StructureFinding]
    /// Findings about a folder the scope sits *inside* — see ``ScopeRelation/aboutAncestor``.
    ///
    /// **Surfaced rather than dropped, and that is a design requirement rather than a nicety.**
    /// Restructure compares sibling *families*, so under a scope pointed at a leaf the `inside`
    /// list is frequently empty — that is the honest answer, not a bug. Dropping the ancestor
    /// findings on top of it would leave the lens looking permanently broken at exactly the depth
    /// people scope to, which is one of the three reasons live-binding scope to the pane was
    /// rejected. They are kept visually subordinate: this is context about the surroundings, not
    /// work in the scope, and the rail badge deliberately does not count them.
    var aboutAncestor: [StructureFinding] = []
    let hasProfile: Bool
    /// How many folders this lens's answer covers — **nil when that is not known**.
    ///
    /// Scoped, not the whole survey. It was `profile.folders.count`, so the clean state said
    /// "Checked 3,013 folders" while the list above it had been narrowed to one subtree: a number
    /// about the tree beside an answer about a folder. Nil when there is no profile, or when the
    /// scope is a subtree the survey has never seen — in which case the sentence drops the count
    /// rather than inventing a zero.
    let folderCount: Int?
    /// When the survey last looked at the tree, or nil when unknown — a corpus that predates the
    /// stamp, or no profile at all (ROADMAP_V5 §4.1).
    var surveyedAt: Date? = nil
    /// Whether a duplicate scan's groups are on hand — §5.9's staleness truth: the
    /// duplicated-taxonomy detector reads the scan, not the profile, so with no scan its findings
    /// are ABSENT, not clean, and the lens says so rather than letting silence claim health.
    var hasDuplicateScan: Bool = false
    /// Whether Organize is narrowed to a subtree — the clean state says a different thing about a
    /// folder than about the whole tree.
    var isScoped: Bool = false
    /// The provider this lens's answer covers, for the setup card's title — it compares sibling
    /// families across the surveyed tree, not inside the focused folder.
    var providerName: String?
    /// The crowding classification for this scope — path → class, already narrowed. Counts, not
    /// findings: always non-zero on a real tree, so it renders as the strip's three filters and
    /// never takes a badge (ROADMAP_V5 §5.2).
    var deadWeight: [String: DeadWeightClass] = [:]
    let accent: Color
    let onReveal: (String) -> Void
    /// *Never suggest this again* — writes the finding's `kind × subject` into the store. nil
    /// hides the menu item rather than offering a promise nothing keeps.
    var onSuppress: ((StructureFinding) -> Void)?
    /// The backlog scaffold (§5.2): creates the folders the family's vouched vocabulary expects,
    /// then hands the flat files to To File. Only rendered on a backlog card whose scaffold is
    /// non-empty — an all-drift family has nothing to copy and gets the hand-off alone.
    var onScaffold: ((StructureFinding) -> Void)?
    /// The To File hand-off, scoped to the finding's subject — the per-file half of a backlog or
    /// loose-files finding, sent to the surface that already makes per-file judgements.
    var onHandOff: ((StructureFinding) -> Void)?
    /// §5.4's plan surface — opens a plan over the lens. WHICH plan is
    /// ``RestructurePlanRouting``'s answer, not this callback's: a family mapping for a shape, the
    /// same mapping seeded for a pair under one parent, a confirm sheet for a pair across
    /// parents. nil hides the button rather than promising a sheet that does not open.
    var onPlan: ((StructureFinding) -> Void)?
    /// Saved drafts by finding id — §5.7's *Planned, not applied*: the card carries the plan's
    /// ledger sentence inline, and its trigger reads *Review N operations* instead of *Plan…*.
    var plannedPlans: [String: PlannedPlanInfo] = [:]
    /// Subjects whose scaffold has already landed (from the store's ledger). Until §5.5's
    /// re-derive exists the profile stays stale after a landing, so the finding keeps rendering —
    /// and its card must say the survey has not caught up rather than offer the same landing
    /// twice. §5.7's third sentence, not a borrowed one.
    var scaffoldedSubjects: Set<String> = []
    /// Whether the user has opened this answer **this launch** — see
    /// ``FileSyncManager/hasReviewedStructure``. False puts the setup card in front of a result
    /// that already exists, which is the whole point: it is read off a survey that may be weeks
    /// old, and the card is where that gets said.
    ///
    /// **No default**, unlike the other optional inputs here. A defaulted `true` is a gate that
    /// switches itself off for any call site that forgets the argument, and nothing would fail —
    /// which is the whole failure mode this flag exists to prevent. The compiler is a better
    /// guard than a comment.
    let hasReviewed: Bool
    /// Reveals the findings — the setup card's trigger once there is a survey to read.
    var onReview: (() -> Void)?
    /// Re-derives the folder memory from the tree as it stands now. The card's *secondary*
    /// action: the primary only reveals what is already computed, so this is the one that makes
    /// the answer more current. nil on a machine with nothing to re-survey.
    var onUpdateSurvey: (() -> Void)?
    /// §5.7's Applied and Undone cards — the ledger's records, newest first. Rendered in the
    /// clean state too, deliberately: a successful apply makes the finding vanish, and the clean
    /// state is exactly where *Undo this reorganisation* has to live to be findable.
    var reorganisations: [ReorganisationDisplay] = []
    /// Runs the ledger's stored inverse for one record. Not ⌘Z — both exist, and the card says
    /// which this is.
    var onUndoReorganisation: ((String) -> Void)?
    /// Opens §5.5's removal sheet, scoped to the folders that record's landing emptied.
    var onRemoveEmptied: ((String) -> Void)?
    /// Opens the Help book at Restructure's own page. nil hides the affordance — this is a
    /// pointer at documentation, and one that goes nowhere is worse than none.
    var onOpenHelp: (() -> Void)?
    /// Re-derives the survey from the tree as it stands — §5.7's Scaffolded card, whose own
    /// sentence describes a wait with nothing to end it. Carries the asking card's subject so a
    /// refusal lands on the card that asked. nil hides the button.
    var onRefreshSurvey: ((String) -> Void)?
    /// What the last refresh refused with, and **which card asked** — a sentence on the card
    /// rather than a queue, because the guards are the landing's and "wait for the scan" means
    /// press it again. Keyed by subject: a single string rendered under every scaffolded card,
    /// which is a refusal reported for presses that never happened.
    var refreshSurveyRefusal: (subject: String, sentence: String)?
    /// Opens the same sheet on §5.2's **pre-existing** empties — the crowding strip's third
    /// filter, which the roadmap decided gets a Trash route and shipped without one. nil hides
    /// the button rather than promising a sheet that does not open.
    var onRemoveStandingEmpties: (() -> Void)?

    private var isEmpty: Bool { findings.isEmpty && aboutAncestor.isEmpty }

    /// Which crowding class the strip is currently expanded on, if any.
    @State private var crowdingFilter: DeadWeightClass?
    /// Which top-level branches of a grouped crowding list are open. Empty on open — a grouped
    /// list that expanded itself would be the flat list it replaces.
    @State private var expandedBranches: Set<String> = []

    var body: some View {
        // The Help pointer rides the whole lens rather than the crowding strip: the strip renders
        // only where the scope has dead-weight folders, so on a clean subtree — and in all three
        // card states — the affordance vanished exactly where a reader is most likely to be lost.
        lensBody.overlay(alignment: .topTrailing) {
            helpPointer.padding(.top, 6).padding(.trailing, 10)
        }
    }

    @ViewBuilder
    private var lensBody: some View {
        if !hasProfile {
            noProfileState
        } else if !hasReviewed {
            readyState
        } else if isEmpty {
            // The strip renders in the clean state too — settled by rendering it (the roadmap's
            // open question): the seal answers *shape*, the strip answers *crowding*, and a strip
            // that vanished on a clean tree would make the empties filter unreachable exactly
            // when it is the only thing left to do. The reorganisation cards render here for the
            // stronger reason their doc states: this is the state a successful apply lands in.
            if deadWeight.isEmpty && reorganisations.isEmpty {
                cleanState
            } else {
                // Scrollable, because this is the state that ACCUMULATES: every successful apply
                // lands its card here, and an expanded crowding filter lists hundreds of paths —
                // a plain VStack clipped them all past the lens bounds with no way to reach them.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !deadWeight.isEmpty {
                            crowdingStrip.padding(12)
                        }
                        if !reorganisations.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(reorganisations, content: reorganisationCard)
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                        }
                        // A floor, not a fill: inside a ScrollView "all the remaining space"
                        // does not exist, and without it the seal huddled against the cards.
                        cleanState.frame(minHeight: 240)
                    }
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !deadWeight.isEmpty {
                        crowdingStrip
                    }
                    ForEach(reorganisations, content: reorganisationCard)
                    // §5.2's grouping rule, the render half: rows arrive sorted so a folder's
                    // findings are adjacent, and the second card about one folder drops the path
                    // heading — a second thing about the same place, not a repeat.
                    ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
                        findingCard(finding,
                                    showsPath: index == 0
                                        || findings[index - 1].subject != finding.subject)
                    }
                    if !aboutAncestor.isEmpty {
                        ancestorHeader
                        ForEach(aboutAncestor) { finding in
                            findingCard(finding, showsPath: true).opacity(0.72)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: §5.7's Applied and Undone cards

    @ViewBuilder
    private func reorganisationCard(_ record: ReorganisationDisplay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.familyHeading(record.family))
                    .scaledFont(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text(record.undoneAt == nil ? "Applied" : "Undone")
                    .scaledFont(.system(size: 9.5, weight: .semibold))
                    .padding(.vertical, 1.5)
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(.quaternary.opacity(0.35)))
                    .foregroundStyle(.secondary)
            }
            Text(Self.reorganisationLine(record))
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Step 4's verdict. It has only ever been in the log, which is the one place nobody
            // reads after the fact — and "did this check out" is the question an Applied card
            // exists to answer.
            if let verifierLine = record.verifierLine {
                Text(verifierLine)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Why the undo is not offered here, said BEFORE the click rather than as a refusal
            // after it. Derived from the store's own order — never re-derived in the view.
            if let blocked = record.blockedReason {
                Text(blocked)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if record.undoneAt == nil {
                HStack(spacing: 14) {
                    if record.canUndo, let onUndoReorganisation {
                        Button("Undo this reorganisation") {
                            onUndoReorganisation(record.manifestId)
                        }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .chromeHover()
                        .help("Runs the inverse stored in the ledger and re-points the survey "
                              + "back — it survives a quit, and it is not ⌘Z.")
                    }
                    if record.hasEmptiedFolders, let onRemoveEmptied {
                        Button("Remove emptied folders…") { onRemoveEmptied(record.manifestId) }
                            .scaledFont(.system(size: 11, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(accent)
                            .chromeHover()
                            .help("Only folders this landing itself emptied, only to the Trash, "
                                  + "and only the ones you tick.")
                    }
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lensCard()
    }

    /// Step 4's verdict as one line, or nil when the record has none to give. **Absent is not a
    /// pass**: a record from before the field existed, and a landing that refused before the
    /// verifier ran, both say nothing rather than claiming agreement.
    static func verifierLine(verifiedOK: Bool?, note: String?) -> String? {
        guard let verifiedOK else { return nil }
        guard verifiedOK else {
            return "The check found a disagreement — \(note ?? "the log has it")."
        }
        return "Verified — the tree matches what the plan said it would do."
    }

    /// Why a landing that is not the newest cannot be undone yet. The ledger unwinds newest
    /// first, and saying so on the card is the difference between a greyed row and a mystery.
    static let blockedByNewerText =
        "Undo the newer reorganisation first — the ledger unwinds one at a time, newest back."

    /// The path a landing's card is headed with. `"."` is the profile's own spelling for the tree
    /// root, and a removal of empties scattered across the tree has no closer family than that —
    /// rendering the character itself would head the card with a full stop. `""` reaches the same
    /// state from the other direction, so both are named.
    static func familyHeading(_ family: String) -> String {
        family == "." || family.isEmpty ? "Across the tree" : family
    }

    /// The card's sentence — Applied and Undone are different claims and neither borrows the
    /// other's words (§5.7). The Undone line carries the undo run's own counts, because an undo
    /// never pretends the tree was untouched.
    static func reorganisationLine(_ record: ReorganisationDisplay, now: Date = Date()) -> String {
        if let undoneAt = record.undoneAt {
            let tail = record.undoSummary.map { " — \($0)" } ?? ""
            return "Undone \(landingPhrase(undoneAt, now: now))\(tail). "
                + "Anything skipped as drift is named in the log."
        }
        return "Applied \(landingPhrase(record.at, now: now)) — \(record.summary)."
    }

    /// The ledger stamp in words — "today at 12:04", "yesterday at 09:14", "on 12 Aug 2026 at
    /// 09:14". The record stores the machine stamp ("2026-08-28T12:04:00"), and this was the one
    /// user sentence in the app rendering it verbatim, a literal `T` included, one line under a
    /// footnote that says "Surveyed yesterday". An unparseable stamp renders as itself — a wrong
    /// spelling of the truth beats a pretty invention.
    static func landingPhrase(_ stamp: String, now: Date = Date()) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = parser.date(from: stamp) else { return stamp }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm"
        let time = clock.string(from: date)
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "today at \(time)"
        case 1: return "yesterday at \(time)"
        default: return "on \(Self.absolute(date)) at \(time)"
        }
    }

    /// Names what the section below it is, in the words the design asked for: these findings are
    /// about the folder above the one you scoped to.
    private var ancestorHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.left.up")
                .scaledFont(.system(size: 10, weight: .semibold))
            Text(Self.ancestorHeading(hasFindingsHere: !findings.isEmpty))
                .scaledFont(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.top, findings.isEmpty ? 0 : 6)
    }

    /// The ancestor section's heading, as a value so it can be asserted without an accessibility
    /// tree — the same reason `cleanTitle`/`cleanMessage` are static.
    ///
    /// The two forms are not decoration. With nothing found inside the scope the list would
    /// otherwise open straight onto findings about a *different* folder, which reads as the lens
    /// having answered the question it was asked; the first form says outright that it did not.
    static func ancestorHeading(hasFindingsHere: Bool) -> String {
        hasFindingsHere
            ? "About the folder above this one:"
            : "Nothing about this folder itself — but about the folder above it:"
    }

    // MARK: The crowding strip

    /// Three counts above the findings, each a filter into a list (ROADMAP_V5 §5.2). Crowding is
    /// a property of the scope — always non-zero on a real tree — so these are chips, not cards,
    /// and none of them takes a badge. Only the empties will carry an action (§5.5's removal
    /// sheet); the other two are report-only in 5.0, and the strip says the number, offers the
    /// list, and offers no button.
    private var crowdingStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(DeadWeightClass.allCases, id: \.self) { weightClass in
                    crowdingChip(weightClass)
                }
                Spacer(minLength: 0)
            }
            if let crowdingFilter {
                crowdingList(crowdingFilter)
            }
        }
    }

    /// Whether the expanded list ends in a Trash route (ROADMAP_V5 §5.2's decided behaviour).
    ///
    /// **Only the empties.** The other two classes are report-only for reasons their own tooltips
    /// state — a single-file leaf can be a destination waiting for its next file, and hoisting a
    /// pass-through renames every path beneath it — so offering to trash them would be acting on
    /// the one judgement the strip deliberately refuses to make.
    static func offersStandingRemoval(_ weightClass: DeadWeightClass, pathCount: Int,
                                      hasHandler: Bool) -> Bool {
        weightClass == .empty && pathCount > 0 && hasHandler
    }

    /// **Where the anxiety is.** The Help book already explains the plan flow and why the
    /// ledger's undo is not ⌘Z; nothing in the lens pointed at it, so the reader most in need of
    /// that page was the one least likely to go looking. One affordance, routed through the app's
    /// existing Help front door — never a second overlay, and never a sheet.
    @ViewBuilder
    private var helpPointer: some View {
        if let onOpenHelp {
            Button(action: onOpenHelp) {
                Image(systemName: "questionmark.circle")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            // `.help` is the tooltip, not the name — a glyph-only control needs both.
            .accessibilityLabel("About Restructure")
            // Says what THIS page covers. The earlier wording promised the ⌘Z explanation, which
            // lives on *Apply, and take it back* — a tooltip that promises another page's content
            // is a pointer that misses.
            .help("What Restructure looks for, and how a plan is reviewed before anything moves.")
            .chromeHover()
        }
    }

    /// The Help topic this lens points at — see ``OrganizeHelpTopics/restructure``.
    static let helpTopicID = OrganizeHelpTopics.restructure

    static func crowdingLabel(_ weightClass: DeadWeightClass, count: Int) -> String {
        switch weightClass {
        case .passThrough: return "\(count) pass-through"
        case .singleFileLeaf: return "\(count) single-file"
        case .empty: return "\(count) empty"
        }
    }

    private func crowdingPaths(_ weightClass: DeadWeightClass) -> [String] {
        deadWeight.filter { $0.value == weightClass }.map(\.key).sorted()
    }

    private func crowdingChip(_ weightClass: DeadWeightClass) -> some View {
        let count = crowdingPaths(weightClass).count
        let isSelected = crowdingFilter == weightClass
        return Button {
            crowdingFilter = isSelected ? nil : weightClass
            // A grouped list that opened already-expanded is the flat list it replaces, and the
            // branches of one class mean nothing in another.
            expandedBranches = []
        } label: {
            Text(Self.crowdingLabel(weightClass, count: count))
                .scaledFont(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(isSelected ? AnyShapeStyle(accent.opacity(0.18))
                                              : AnyShapeStyle(.quaternary.opacity(0.30))))
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        // A SELECTED chip stays clickable at zero: the removal sheet can drain a class while
        // its filter is open, and a selected-and-disabled chip left no way to ever clear the
        // filter — the stub list under it was unreachable furniture.
        .disabled(count == 0 && !isSelected)
        .opacity(count == 0 && !isSelected ? 0.4 : 1)
        .help(Self.crowdingHelp(weightClass))
    }

    /// Why the number is a number and not a button — each class states its own reason.
    static func crowdingHelp(_ weightClass: DeadWeightClass) -> String {
        switch weightClass {
        case .passThrough:
            return "Folders holding nothing but one subfolder. Report-only: hoisting one renames "
                + "every path beneath it, for a defect that costs one click in a column view."
        case .singleFileLeaf:
            return "Folders holding exactly one file. Report-only: a folder can look like debt "
                + "and be a destination waiting for its next file, and nothing in its own shape "
                + "separates the two."
        case .empty:
            return "Folders holding nothing at all. Open the list to send them to the removal "
                + "sheet — nothing is deleted; folders go to the Trash."
        }
    }

    /// Above this many paths a flat list stops being surveyable and the rows are grouped by
    /// their top-level folder. Below it the flat list is the better answer — grouping twelve
    /// paths adds a disclosure to open before anything can be read.
    ///
    /// The single-file class is ~503 paths on the real tree, the pass-through ~86 and the
    /// empties 20, so on that tree this groups the first two and leaves the empties flat —
    /// which is also what keeps their removal button one click away.
    static let crowdingGroupingThreshold = 40

    /// Paths grouped by first path component, biggest branch first — the rule, so the threshold
    /// and the ordering can be asserted without a view. nil when the list is short enough to
    /// read flat.
    static func crowdingBranches(_ paths: [String]) -> [(branch: String, paths: [String])]? {
        guard paths.count > crowdingGroupingThreshold else { return nil }
        var byBranch: [String: [String]] = [:]
        for path in paths {
            // A top-level folder is its own branch rather than being dropped: the profile keys
            // paths relative to the root, so a bare name has no first component to group under.
            let branch = path.split(separator: "/").first.map(String.init) ?? path
            byBranch[branch, default: []].append(path)
        }
        return byBranch
            .map { (branch: $0.key, paths: $0.value.sorted()) }
            // Count descending, then name — the biggest pile is the one worth opening first, and
            // a stable tiebreak keeps the order from moving between renders.
            .sorted { ($1.paths.count, $0.branch) < ($0.paths.count, $1.branch) }
    }

    private func crowdingList(_ weightClass: DeadWeightClass) -> some View {
        let paths = crowdingPaths(weightClass)
        let branches = Self.crowdingBranches(paths)
        return VStack(alignment: .leading, spacing: 2) {
            if let branches {
                ForEach(branches, id: \.branch) { group in
                    branchRow(group.branch, count: group.paths.count)
                    if expandedBranches.contains(group.branch) {
                        ForEach(group.paths, id: \.self) { path in
                            crowdingRow(path).padding(.leading, 14)
                        }
                    }
                }
            } else {
                ForEach(paths, id: \.self) { path in
                    crowdingRow(path)
                }
            }
            // The empties' Trash route (ROADMAP_V5 §5.2, decided). Only on this class — the
            // other two are report-only and say so in their own tooltips — and only under the
            // expanded list. Past the grouping threshold that list is branch rows rather than
            // paths, so the button sits under names rather than folders; the sheet it opens is
            // the review either way, and every row there is re-probed and ticked one by one.
            if Self.offersStandingRemoval(weightClass, pathCount: paths.count,
                                          hasHandler: onRemoveStandingEmpties != nil),
               let onRemoveStandingEmpties {
                Button("Remove empty folders…") { onRemoveStandingEmpties() }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .chromeHover()
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .help("Opens the removal sheet on these folders — you tick which ones, "
                          + "date buckets start ticked, and they go to the Trash as one "
                          + "undoable landing.")
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.18)))
    }

    private func crowdingRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Text(path)
                .scaledFont(.system(size: 10.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Button("Reveal") { onReveal(path) }
                .scaledFont(.system(size: 10, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                // Every row in the crowding list says "Reveal" — VoiceOver needs each to name
                // where it goes.
                .accessibilityLabel("Reveal \(path)")
                .chromeHover()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
    }

    /// One branch's disclosure. Collapsed on open, every one of them: the whole point is that
    /// five hundred paths become a dozen lines you can read before deciding which to expand.
    private func branchRow(_ branch: String, count: Int) -> some View {
        Button {
            if expandedBranches.contains(branch) {
                expandedBranches.remove(branch)
            } else {
                expandedBranches.insert(branch)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expandedBranches.contains(branch)
                      ? "chevron.down" : "chevron.right")
                    .scaledFont(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(branch)
                    .scaledFont(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count)")
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        // The chevron is the only visual state, which is invisible to VoiceOver.
        // A disclosure, not a selection: `.isSelected` reads as "this row is picked", and a
        // collapsed row carried no state at all.
        .accessibilityLabel("\(branch), \(count) folder\(count == 1 ? "" : "s")")
        .accessibilityValue(expandedBranches.contains(branch) ? "expanded" : "collapsed")
        .accessibilityHint("Shows the folders in this branch")
        .chromeHover()
    }

    // MARK: Finding cards

    private func findingCard(_ finding: StructureFinding, showsPath: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if showsPath {
                        Text(finding.subject)
                            .scaledFont(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    HStack(spacing: 6) {
                        kindTag(finding.kind)
                        Text(Self.subtitle(for: finding))
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                // §5.4's sheet exists now, so `Plan…` takes the action slot on the cards that
                // have one and `Reveal` is demoted to the secondary spot — the demotion this
                // comment used to promise. A drafted plan changes the trigger's words: the plan
                // already exists, so the button offers its review, not its creation (§5.7).
                if let onPlan, RestructurePlanRouting.carriesPlanSurface(finding) {
                    Button(planTriggerTitle(for: finding)) { onPlan(finding) }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .chromeHover()
                        .help(Self.planHelp(for: finding))
                }
                let hasPlan = onPlan != nil && RestructurePlanRouting.carriesPlanSurface(finding)
                Button("Reveal") { onReveal(finding.subject) }
                    .scaledFont(.system(size: 11, weight: hasPlan ? .regular : .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(hasPlan ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
                    .chromeHover()
            }
            // The eras at a glance, when the family is about years — the text rows below stay,
            // and stay authoritative: this is the same information drawn in order, never a
            // replacement for the list of what each era actually contains.
            if let segments = Self.eraSegments(schemes: finding.schemes, drift: finding.drift,
                                               shapeless: finding.shapeless) {
                eraStrip(segments, schemes: finding.schemes)
            }
            // The schemes are shown rather than asserted: the eras are visible, and so is the odd
            // year out. A verdict that only said "these disagree" would be asking to be trusted.
            ForEach(Array(finding.schemes.enumerated()), id: \.offset) { _, scheme in
                schemeRow(scheme)
            }
            // §5.1's two recovered rows — the drop paths, rendered instead of swallowed. Drift is
            // greyed: members of the family whose shape no second sibling vouches for. The
            // shape-less sibling gets its own words, because "no shape of its own" is a different
            // sentence from "disagrees with the others".
            if !finding.drift.isEmpty {
                extraRow(members: finding.drift.joined(separator: ", "),
                         note: "drift — no two agree on one shape")
                    .opacity(0.6)
            }
            if !finding.shapeless.isEmpty {
                extraRow(members: finding.shapeless.joined(separator: ", "),
                         note: "no shape of its own")
            }
            if let scaffold = Self.scaffoldLine(for: finding) {
                extraRow(members: scaffold.members, note: scaffold.note)
            }
            // Where a draft exists the numbers are KNOWN, so the card states them instead of
            // describing the shape of the cost. The sentence stays as the no-draft fallback —
            // it is the honest answer when nothing has been derived yet.
            if let chips = plannedPlans[finding.id]?.radiusChips, !chips.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        Text(chip.text)
                            .scaledFont(.system(size: 9.5, weight: .medium))
                            .padding(.vertical, 1.5)
                            .padding(.horizontal, 6)
                            .background(Capsule().fill(chip.movesFiles
                                                       ? AnyShapeStyle(Color.orange.opacity(0.16))
                                                       : AnyShapeStyle(.quaternary.opacity(0.30))))
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let radius = Self.blastRadius(for: finding) {
                Text(radius)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if let plan = plannedPlans[finding.id] {
                // §5.7's Planned-not-applied: the ledger inline, so the card says what the
                // draft would do without opening the sheet — and says plainly that nothing
                // has happened yet.
                Text("Planned, not applied — \(plan.summary).")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            actionRow(for: finding)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The C2 recipe, not a hand-rolled slab: every other lens's content cards wear
        // lensCard(), and this was the one set outside the family — flat gray, radius 9, and
        // no lit-glass hairline in dark. The scheme rows inside keep their quiet inner fills.
        .lensCard()
        .contextMenu {
            if let onSuppress {
                Button("Never suggest this again") { onSuppress(finding) }
            }
        }
    }

    /// The actions a finding can offer today — the scaffold and the To File hand-off, on the two
    /// kinds whose fix is per-file or create-only. Everything else waits for §5.4's `Plan…`.
    @ViewBuilder
    private func actionRow(for finding: StructureFinding) -> some View {
        switch finding.detail {
        case .backlog(let scaffold, _):
            HStack(spacing: 14) {
                if scaffoldedSubjects.contains(finding.subject) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.scaffoldLandedText)
                            .scaledFont(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let onRefreshSurvey {
                            Button("Update the survey now") { onRefreshSurvey(finding.subject) }
                                .scaledFont(.system(size: 11, weight: .semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(accent)
                                .chromeHover()
                                .help(Self.refreshSurveyHelp)
                        }
                        if let refreshSurveyRefusal,
                           refreshSurveyRefusal.subject == finding.subject {
                            Text(refreshSurveyRefusal.sentence)
                                .scaledFont(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if !scaffold.isEmpty, let onScaffold {
                    Button("Set up like its siblings") { onScaffold(finding) }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .chromeHover()
                        .help("Creates \(scaffold.joined(separator: ", ")) — folders only, one "
                              + "⌘Z — then opens To File scoped here for the flat files.")
                }
                if let onHandOff {
                    Button("File these…") { onHandOff(finding) }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .chromeHover()
                        .help("Opens To File scoped to this folder — the surface that judges "
                              + "files one at a time.")
                }
            }
        case .looseAboveSeries:
            if let onHandOff {
                Button("File these…") { onHandOff(finding) }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .chromeHover()
                    .help("Opens To File scoped to this folder — which year each file belongs "
                          + "to is a per-file judgement.")
            }
        default:
            EmptyView()
        }
    }

    /// What a backlog card says once its scaffold has landed but the survey has not been
    /// re-derived — applied is not resolved, and neither word may borrow the other's sentence.
    /// Why the button is worth pressing, and what it costs — **including the part a reader would
    /// not guess**: this is the first thing a scaffold causes that replaces the hand-built
    /// profile with a derived one. A plan's own landing does the same at its step 6; saying so
    /// here is the difference between a sanctioned change and a surprise.
    static let refreshSurveyHelp =
        "Re-reads the tree and rebuilds the folder memory, so the folders this scaffold created "
        + "are in it and this finding goes. It replaces the survey with a freshly derived one, "
        + "the same way applying a plan does."

    static let scaffoldLandedText =
        "Scaffolded — the survey hasn’t caught up yet, so this stays until it is updated."

    /// The plan trigger's words: *Plan…* creates, *Review N operations* reopens what exists —
    /// §5.7's stated trigger for the Planned state, and the pair must never both show.
    private func planTriggerTitle(for finding: StructureFinding) -> String {
        Self.planTriggerTitle(planned: plannedPlans[finding.id])
    }

    /// What the plan trigger promises — **the surface it opens**, which is not the same on every
    /// kind. A shape finding opens the mapping editor with its choose-a-shape step; a pair opens
    /// a review of operations that are already determined. Both end in a sheet that moves nothing
    /// until its own Apply is pressed, and that half is said either way.
    static func planHelp(for finding: StructureFinding) -> String {
        let tail = " Opening the sheet moves nothing; only its Apply button does."
        switch RestructurePlanRouting.route(for: finding) {
        case .familyMapping:
            return "Choose the target shape and map every name once — the operations are derived "
                + "for review." + tail
        case .seededMapping:
            return "Opens the mapping for this folder with the pair already filled in — the "
                + "operations are derived for review." + tail
        case .pairMerge:
            return "Reviews the operations this merge would run, derived from the two folders."
                + tail
        case nil:
            return "No plan is derived for this kind."
        }
    }

    static func planTriggerTitle(planned: PlannedPlanInfo?) -> String {
        guard let planned else { return "Plan…" }
        return "Review \(planned.operations) operation\(planned.operations == 1 ? "" : "s")"
    }

    private func kindTag(_ kind: FindingKind) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: Self.kindSymbol(kind))
                .scaledFont(.system(size: 8.5, weight: .semibold))
                // **The glyph, and only the glyph.** The capsule's fill and its text keep the
                // shipped treatment: accent on 9.5pt text is exactly the contrast trap the
                // repo's amber-on-body-text rule exists for, and a tag is not a control.
                .foregroundStyle(Self.glyphTakesAccent(kind) ? AnyShapeStyle(accent)
                                                             : AnyShapeStyle(.secondary))
                // Decorative — the label beside it already says which kind this is, and the
                // tooltip says what acting on it would do.
                .accessibilityHidden(true)
            Text(Self.kindLabel(kind))
                .scaledFont(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 6)
        .background(Capsule().fill(.quaternary.opacity(0.35)))
        .help(Self.kindVerb(kind))
    }

    /// Whether a kind's glyph takes the accent — **the same question the Plan button asks**.
    ///
    /// `FindingKind.carriesPlan` is the rail badge's rule and is deliberately wider: it counts
    /// `duplicatedTaxonomy`, which has no plan surface at all until §5.9 is measured. Tinting on
    /// it promised a plan the card does not offer, which is the one thing a glyph this small can
    /// still get wrong.
    static func glyphTakesAccent(_ kind: FindingKind) -> Bool {
        switch kind {
        case .shape, .shadowAxis, .echoName, .mirroredInbox, .looseBesideContainer: return true
        case .backlog: return true      // its card ends in the scaffold landing
        case .deadWeight, .looseAboveSeries, .duplicatedTaxonomy, .ask: return false
        }
    }

    /// One symbol per kind, so a mixed list sorts by eye before it is read (ROADMAP_V5 §5.1's
    /// stated aim for the tag).
    ///
    /// **Exhaustive on purpose**: a detector added later fails to compile here rather than
    /// rendering a blank square. Each symbol says what the finding IS, not what would be done
    /// about it — the verb is the tooltip's job, and two kinds whose fix is a merge still look
    /// different because they were found by different rules.
    static func kindSymbol(_ kind: FindingKind) -> String {
        switch kind {
        case .shape: return "square.on.square.dashed"
        case .backlog: return "calendar.badge.plus"
        case .shadowAxis: return "calendar.badge.exclamationmark"
        case .echoName: return "doc.on.doc"
        case .mirroredInbox: return "tray.full"
        case .deadWeight: return "wind"
        case .looseAboveSeries: return "doc.badge.ellipsis"
        case .looseBesideContainer: return "arrow.turn.down.right"
        case .duplicatedTaxonomy: return "arrow.triangle.branch"
        case .ask: return "questionmark.circle"
        }
    }

    /// The kind tag's noun — short enough for a chip, distinct enough to sort a mixed list by eye.
    static func kindLabel(_ kind: FindingKind) -> String {
        switch kind {
        case .shape: return "Shape"
        case .backlog: return "Series"
        case .shadowAxis: return "Year in name"
        case .echoName: return "Echo"
        case .mirroredInbox: return "Mirrored inbox"
        case .deadWeight: return "Dead weight"
        case .looseAboveSeries: return "Loose files"
        case .looseBesideContainer: return "Loose folder"
        case .duplicatedTaxonomy: return "Duplicated"
        case .ask: return "Ask"
        }
    }

    /// The verb the tag's tooltip carries — what acting on this class of finding would do
    /// (ROADMAP_V5 §5.1: the class of change is legible before any sheet opens).
    static func kindVerb(_ kind: FindingKind) -> String {
        switch kind {
        case .shape: return "Renames or merges folders"
        case .backlog: return "Creates folders and hands the files to To File"
        case .shadowAxis: return "Renames or merges into the year run"
        case .echoName: return "Merges two spellings of one name"
        case .mirroredInbox: return "Merges the mirror into its destination"
        case .deadWeight: return "Reports — no plan"
        case .looseAboveSeries: return "Hands the files to To File"
        case .looseBesideContainer: return "Moves the folder into its container"
        case .duplicatedTaxonomy: return "Merges two folders holding the same documents"
        case .ask: return "Asks — the answer is remembered, nothing moves"
        }
    }

    /// The line under the path — each kind states what it saw, in its own words.
    static func subtitle(for finding: StructureFinding) -> String {
        switch (finding.kind, finding.detail) {
        case (.shape, _):
            return "\(finding.memberCount) folders, \(finding.schemes.count) internal shapes"
        case (_, .backlog(_, let looseFiles)):
            return "\(looseFiles) file\(looseFiles == 1 ? "" : "s"), no folders yet"
        case (_, .shadowAxis(let target, let exists)):
            return exists ? "hides the year \(target), which exists beside it"
                          : "hides the year \(target)"
        case (_, .echoName(let counterpart, let relation)):
            let name = (counterpart as NSString).lastPathComponent
            return relation == .parentChild ? "echoes its parent, \(name)"
                                            : "echoes \(name) beside it"
        case (_, .mirroredInbox(let destination)):
            return "mirrors \(destination)"
        case (_, .looseAboveSeries(let looseFiles, let seriesFolders)):
            return "\(looseFiles) files above \(seriesFolders) year folders"
        case (_, .looseBesideContainer(let container)):
            return "belongs in \((container as NSString).lastPathComponent)/"
        case (_, .duplicatedTaxonomy(let counterpart, let matched)):
            // The counterpart's whole path, not its last component: the claim is that two
            // BRANCHES hold the same documents, and `Forms` alone would not say which two.
            return "\(matched) of its documents also sit in \(counterpart)"
        default:
            return ""
        }
    }

    /// The scaffold's own row, for a backlog card: what *Set up like its siblings* would create,
    /// or the honest sentence when the family vouches for nothing.
    static func scaffoldLine(for finding: StructureFinding) -> (members: String, note: String)? {
        guard case .backlog(let scaffold, _) = finding.detail else { return nil }
        guard !scaffold.isEmpty else {
            return (members: "—", note: "no shared shape to copy — the files go to To File as they are")
        }
        return (members: scaffold.joined(separator: ", "), note: "what its siblings expect")
    }

    /// The card's blast-radius sentence (ROADMAP_V5 §5.1): the honest cost, derived from the
    /// finding's own shape, and the sentence that makes someone open the sheet. nil for the kinds
    /// whose subtitle already carries the whole story.
    static func blastRadius(for finding: StructureFinding) -> String? {
        switch (finding.kind, finding.detail) {
        case (.shape, _):
            // A bijection of names exists when every vouched scheme agrees on the same number of
            // subfolders; anything else needs at least one merge to converge.
            let sizes = Set(finding.schemes.map(\.vocabulary.count))
            return sizes.count <= 1 && !sizes.contains(0)
                ? "A plan here is folder renames — no file would move."
                : "Converging these shapes needs merges — files would move."
        case (_, .backlog(let scaffold, _)):
            return scaffold.isEmpty ? nil
                : "Creates folders only — nothing moves, nothing to undo but empty folders."
        case (_, .shadowAxis(_, let exists)):
            return exists ? "A plan here is one merge — its files would move into the year."
                          : "A plan here is one rename — no file would move."
        case (_, .echoName):
            return "A plan here is a merge — one folder wearing two names becomes one."
        case (_, .mirroredInbox):
            return "A plan here merges the mirror into its destination — files would move."
        case (_, .looseAboveSeries):
            return "Per-file judgement — these hand off to To File, scoped here."
        case (_, .looseBesideContainer):
            return "A plan here moves one folder — its files ride along."
        case (_, .duplicatedTaxonomy):
            // The one plan-bearing kind without its own Plan yet: resolving it merges two
            // branches, which is a judgement the Duplicates lens's per-group review owns today.
            return "Two branches hold the same documents — resolving them merges files, "
                + "reviewed per group in Duplicates."
        default:
            return nil
        }
    }

    // MARK: The era strip (§5.1)

    /// One segment of the era strip — a contiguous run of year-named members that share a scheme.
    struct EraSegment: Equatable {
        /// The scheme these members belong to, or nil for drift — which is drawn hollow because
        /// "no two agree on one shape" is the absence of a scheme, not a fourth one.
        let scheme: Int?
        /// What the segment is labelled: a single year, or `first–last`.
        let label: String
        /// How many members it covers — the strip is proportional, so this is its width.
        let count: Int
    }

    /// The eras across a shape family, in year order, or **nil when this family is not about
    /// years at all**.
    ///
    /// Scheme members are mostly years and are shown as comma-joined text, which makes the one
    /// thing a reader wants — where each era begins and ends — something you assemble in your
    /// head. Drawn in order it is one glance.
    ///
    /// **Nil is the common, correct answer for a non-year family** and the strip simply does not
    /// render: a family of `Photos, Invitations, Receipts` has no order to draw, and inventing
    /// one would be worse than the text rows it sits above. The bar is 80% of members parsing as
    /// year tokens, so one oddly-named member among fifteen years does not suppress it.
    ///
    /// The year test is ``FolderProfileEntry/looksLikeYear(_:)`` and **nothing else** — it
    /// already accepts a bare year and a two-part span, and a second parser here would be a
    /// second answer to "is this a year" living one file away from the first.
    static func eraSegments(schemes: [StructureFinding.Scheme],
                            drift: [String], shapeless: [String] = []) -> [EraSegment]? {
        var dated: [(sort: Int, name: String, scheme: Int?)] = []
        var total = 0
        for (index, scheme) in schemes.enumerated() {
            for member in scheme.members {
                total += 1
                if let year = sortYear(of: member) {
                    dated.append((year, member, index))
                }
            }
        }
        for member in drift + shapeless {
            total += 1
            // Shapeless members are members: leaving them out of `total` let a family of four
            // years and ten unnamed folders pass the bar at 100% and draw "the eras across a
            // shape family" over less than a third of it.
            if let year = sortYear(of: member) { dated.append((year, member, nil)) }
        }
        guard total > 0, Double(dated.count) / Double(total) >= 0.8 else { return nil }
        // Two segments need two members; one bar labelled with one year is the text row again.
        guard dated.count > 1 else { return nil }

        dated.sort { ($0.sort, $0.name) < ($1.sort, $1.name) }
        var segments: [EraSegment] = []
        for entry in dated {
            if var last = segments.last, last.scheme == entry.scheme {
                segments.removeLast()
                last = EraSegment(scheme: entry.scheme,
                                  label: Self.spanLabel(from: last.label, to: entry.name),
                                  count: last.count + 1)
                segments.append(last)
            } else {
                segments.append(EraSegment(scheme: entry.scheme, label: entry.name, count: 1))
            }
        }
        return segments
    }

    /// The sort key for a year-named member: its first four-digit part, so a fiscal span
    /// (`2014-2015`) sorts with the year it opens rather than being refused.
    private static func sortYear(of name: String) -> Int? {
        guard FolderProfileEntry.looksLikeYear(name) else { return nil }
        return name.split(separator: "-").first.flatMap { Int($0) }
    }

    /// A run's label — `2013` alone, `2013–2015` once it has grown. Built from the run's own
    /// first and last member so a span inside it (`2014-2015`) does not smuggle a second dash in.
    /// A run's label — `2013` alone, `2013–2015` once it has grown.
    ///
    /// The separator is an EN DASH and a fiscal member carries an ASCII hyphen, so splitting on
    /// the wrong one turned a run opening at `2014-2015` into `2014-2015–2016`. Splitting on the
    /// en dash alone is what keeps the member's own hyphen intact inside the label.
    private static func spanLabel(from existing: String, to newest: String) -> String {
        let first = existing.components(separatedBy: "\u{2013}").first ?? existing
        return first == newest ? first : "\(first)\u{2013}\(newest)"
    }

    /// The strip itself: a segment per era, **proportional to how many folders it covers**.
    /// Drift is hollow. Deliberately no animation — nothing here moves, and an implicit one
    /// would ride on any state change above it.
    ///
    /// The proportion needs the available width, and a `GeometryReader` is greedy in BOTH axes
    /// and reports nothing about its own content — dropped into a card it takes all the vertical
    /// space there is. So the natural row is laid out hidden to establish the strip's height and
    /// width, and the measured one is overlaid inside those bounds, where the reader can only
    /// fill what the hidden row already claimed.
    ///
    /// `layoutPriority` is NOT the tool for this and was the first attempt: it decides who gets
    /// space FIRST, not who gets how much, so the largest era swallowed the row and the other
    /// two rendered at zero width. Rendering the strip is what showed it.
    private func eraStrip(_ segments: [EraSegment],
                          schemes: [StructureFinding.Scheme]) -> some View {
        segmentRow(segments, widths: nil)
            .hidden()
            .overlay {
                GeometryReader { geo in
                    segmentRow(segments,
                               widths: Self.eraSegmentWidths(segments, available: geo.size.width))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.eraStripLabel(segments, schemes: schemes))
    }

    private static let eraSegmentSpacing: CGFloat = 3

    /// Each segment's width: the row's space, less the gaps, shared out by member count.
    ///
    /// A rule rather than an expression inside the reader, because "proportional" is the strip's
    /// whole claim and nothing else can check it — the first version used `layoutPriority` and
    /// drew one full-width segment past a green suite. A render comparison could not see it
    /// either: two families with different counts also have different LABELS, so the images
    /// differ whether or not the widths do.
    static func eraSegmentWidths(_ segments: [EraSegment], available: CGFloat) -> [CGFloat] {
        let total = max(1, segments.reduce(0) { $0 + $1.count })
        let gaps = eraSegmentSpacing * CGFloat(max(0, segments.count - 1))
        let usable = max(0, available - gaps)
        return segments.map { usable * CGFloat($0.count) / CGFloat(total) }
    }

    private func segmentRow(_ segments: [EraSegment], widths: [CGFloat]?) -> some View {
        HStack(spacing: Self.eraSegmentSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                Text(segment.label)
                    .scaledFont(.system(size: 9.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.vertical, 2.5)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: widths.map { $0[index] } ?? .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.chip)
                            .fill(segment.scheme == nil
                                  ? AnyShapeStyle(.clear)
                                  : AnyShapeStyle(accent.opacity(schemeOpacity(segment.scheme!)))))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.chip)
                            .strokeBorder(.quaternary, lineWidth: segment.scheme == nil ? 1 : 0))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Each scheme gets its own depth of the accent so two eras are told apart without a second
    /// hue — the accent-fill convention, not a palette of my own.
    private func schemeOpacity(_ scheme: Int) -> Double {
        // No step below 0.17: at 0.11 the fourth era read as the hollow drift treatment it has
        // to be distinguishable FROM, and a filled segment carries no border to tell them apart.
        Self.schemeOpacities[scheme % Self.schemeOpacities.count]
    }

    /// Four depths of the accent, each far enough from the next to read as a different era and
    /// all far enough from nothing to read as filled.
    static let schemeOpacities: [Double] = [0.30, 0.20, 0.42, 0.26]

    /// The strip is a picture; this is the sentence it makes.
    /// The strip is a picture; this is the sentence it makes.
    ///
    /// Schemes are named by their VOCABULARY, the way the rows below name them. An ordinal
    /// ("shape 1") is a number nothing else on the card establishes, so a reader hearing it has
    /// nothing to map it onto.
    static func eraStripLabel(_ segments: [EraSegment],
                              schemes: [StructureFinding.Scheme] = []) -> String {
        let parts = segments.map { segment -> String in
            guard let index = segment.scheme else { return "\(segment.label), drift" }
            guard index < schemes.count, !schemes[index].vocabulary.isEmpty else {
                return "\(segment.label), one shape"
            }
            return "\(segment.label), \(schemes[index].vocabulary.joined(separator: " and "))"
        }
        return "Eras: " + parts.joined(separator: "; ")
    }

    /// A drift / shapeless / scaffold row — `schemeRow`'s two-column shape with a note instead of
    /// a vocabulary.
    private func extraRow(members: String, note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(members)
                .scaledFont(.system(size: 11, weight: .medium))
                .frame(width: 150, alignment: .leading)
                .lineLimit(2)
            Text(note)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.30)))
    }

    /// A scheme row for the setup card's sample — `schemeRow`'s two-column shape at sample scale.
    /// Deliberately a separate body rather than a `StructureFinding.Scheme` fed through the real
    /// one: the sample is a diagram, and building a fake finding to draw it would put an invented
    /// family one type-check away from the list of real ones.
    private func sampleSchemeRow(members: String, vocabulary: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(members)
                .scaledFont(.system(size: 10.5, weight: .medium))
                .frame(width: 140, alignment: .leading)
                .lineLimit(2)
            Text(vocabulary)
                .scaledFont(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.30)))
    }

    private func schemeRow(_ scheme: StructureFinding.Scheme) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(scheme.members.joined(separator: ", "))
                .scaledFont(.system(size: 11, weight: .medium))
                .frame(width: 150, alignment: .leading)
                .lineLimit(2)
            // The vocabulary these siblings AGREE on — the intersection. A union would advertise
            // one member's stray extra as part of the convention.
            Text(scheme.vocabulary.isEmpty
                 ? "no shared subfolders"
                 : scheme.vocabulary.joined(separator: " · "))
                .scaledFont(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.30)))
    }

    private var cleanState: some View {
        EmptyStateView(icon: "checkmark.seal",
                       title: Self.cleanTitle(isScoped: isScoped),
                       message: Self.cleanMessage(folderCount: folderCount))
    }

    /// The clean state's words, as values so they can be asserted without rendering.
    ///
    /// The title changes with the subject because "the tree agrees with itself" is a claim about
    /// the whole tree, and under a scope this lens has only looked at part of it.
    static func cleanTitle(isScoped: Bool) -> String {
        isScoped ? "This folder agrees with itself" : "The tree agrees with itself"
    }

    static func cleanMessage(folderCount: Int?) -> String {
        let tail = "No family of sibling folders is using more than one internal shape."
        guard let folderCount else { return tail }
        // Grouped, like the setup card's footnote one state over: the real tree is 3,013 folders
        // and "3013" in running prose is a number the eye has to stop and parse.
        return "Checked \(folderCount.formatted()) folder\(folderCount == 1 ? "" : "s"). " + tail
    }

    /// Restructure before it has anything to read — **the setup card, like every other lens.**
    ///
    /// This was a centred `EmptyStateView`: the icon, two sentences, and no way to act on them.
    /// It is this lens's "before" screen, so it wears what the other lenses' before-screens wear
    /// — the job, the safety contract, one trigger, and sample rows in the shape real findings
    /// take. The samples matter more here than anywhere else, because a structure finding is the
    /// least self-explanatory result Organize produces: a family, a count of shapes, and one row
    /// per shape naming the subfolders that shape's members agree on.
    ///
    /// **It has no trigger, and that is the honest rendering.** The first draft put a prominent
    /// "Set up the survey" button here, routed at Settings ▸ Organize — which is where the state
    /// this replaced told people to go, and which **has no survey control on it**: an inbox path,
    /// a kept-names list, and pointers to two other tabs. The folder profile is an artifact built
    /// against the tree and read from disk at launch; no screen in the app makes one. A big blue
    /// button landing on a page with nothing to do is worse than no button, and worse than the
    /// sentence it was promoted from, because a button is a promise. So the card states where the
    /// answer would come from and stops — `LensSetupCard` draws without a trigger for exactly
    /// this.
    private var noProfileState: some View {
        LensSetupCard(
            intro: LensIntros.restructure(providerName: providerName),
            accent: accent,
            triggerTitle: "Set up the survey",
            triggerSymbol: "gearshape",
            // These three are REQUIRED by `LensSetupCard` and, with `onStart: nil` below, are
            // never rendered — the card draws its trigger, and that trigger's `.help`, only
            // inside `if let onStart`. Kept true anyway: this one used to end "Opens Settings ▸
            // Organize", which names a real tab (`SettingsTab.filing` is shown as "Organize") and
            // is exactly the promise the paragraph above says was withdrawn — that tab has no
            // survey control, and no screen in the app builds a survey at all. Copy nothing
            // renders is copy nothing checks, so it stays stale silently and becomes wrong AND
            // visible the moment somebody wires a trigger here.
            triggerHelp: "Restructure reads the survey of your tree rather than the disk, so it "
                + "needs that survey first.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: samplesAccessibility,
            onStart: nil,
            footnote: AnyView(noSurveyNote),
            samples: { samples }
        )
    }

    /// Why there is nothing to press. Sits in the same slot the reveal card puts its "read from a
    /// survey of N folders" line in — a fact about the input, under the card.
    @ViewBuilder
    private var noSurveyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").scaledFont(.system(size: 10))
            Text(Self.noSurveyNoteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaledFont(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// **Says what is missing, and does not say where to get it.** The state this replaced ended
    /// "Settings ▸ Organize sets it up", which was not true then either — see ``noProfileState``.
    /// Naming a destination that cannot help is the part worth not repeating.
    static let noSurveyNoteText =
        "This tree has no folder survey yet, so there is nothing to compare. "
        + "Organize's other lenses read the disk directly and work without one."

    /// Restructure with a survey to read, **before the user has asked for the answer this
    /// launch** — the same card, over results that already exist.
    ///
    /// This is the state the other lenses get for nothing. Their findings live only in memory, so
    /// a relaunch puts them back on the card by itself; Restructure's are derived from a profile
    /// read off disk during startup, so without this it was the one lens that opened straight
    /// onto an answer nobody had asked for. See ``FileSyncManager/hasReviewedStructure``.
    ///
    /// **The trigger reveals rather than computes, and the wording never pretends otherwise.**
    /// There is nothing to run: the findings are already in hand, and the click is free. What
    /// costs something — and what makes the answer current — is the re-survey, so that is the
    /// secondary button rather than the primary. Saying "Rescan" on the primary here would
    /// promise a fresh look at the disk and deliver a cached one.
    ///
    /// The footnote is where "these are cached" is actually said, in the slot To File uses for
    /// what its last cloud pass cost — a fact about work already done, under the card rather than
    /// in front of it.
    private var readyState: some View {
        LensSetupCard(
            intro: LensIntros.restructure(providerName: providerName),
            accent: accent,
            triggerTitle: Self.revealTitle(findingCount: findings.count),
            triggerSymbol: findings.isEmpty ? "checkmark.circle" : "list.bullet.rectangle",
            triggerHelp: findings.isEmpty
                ? "Show what the survey says about this tree's folder shapes. Already computed — nothing is read from disk."
                : "Show the families the survey found disagreeing. Already computed — nothing is read from disk.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: samplesAccessibility,
            onStart: onReview,
            secondary: onUpdateSurvey.map {
                LensSetupCard.SecondaryAction(
                    title: "Update the survey",
                    symbol: "arrow.clockwise",
                    help: "Re-read the tree and rebuild the folder memory these findings come "
                        + "from. Slower, and the only thing here that makes the answer current.",
                    action: $0)
            },
            footnote: AnyView(surveyNote),
            samples: { samples }
        )
    }

    /// The reveal trigger's words. **A count, of what opens** — every finding this lens will
    /// render, ancestor list excluded. Since §5.1 the rail badge counts a SUBSET of this: the
    /// plan-bearing kinds only, because a badge you cannot drive to zero stops being read. The
    /// two numbers therefore may differ, deliberately — the badge answers "how much work is
    /// here", this answers "how much will I see" — and this doc is where that difference is a
    /// decision rather than a drift.
    ///
    /// Zero is its own phrasing rather than "Show 0 findings", which reads as a button that does
    /// nothing. What it opens is usually the clean state — but not always, because a scope with
    /// no findings of its own can still have ancestor ones, and those do render. "Check the
    /// shapes" is deliberately the one wording that is true of both.
    static func revealTitle(findingCount: Int) -> String {
        guard findingCount > 0 else { return "Check the shapes" }
        return "Show \(findingCount) finding\(findingCount == 1 ? "" : "s")"
    }

    /// Says where the answer came from, so "update" is a choice rather than a guess.
    ///
    /// **The freshness claim became truthful in §4.1** — the corpus's `surveyedAt` now moves on
    /// every survey, including one that changes nothing, so "surveyed N days ago" dates the last
    /// LOOK rather than the last change. Before that stamp existed this note deliberately claimed
    /// coverage only; a nil `surveyedAt` (a corpus from before the stamp) still falls back to
    /// exactly that older sentence rather than inventing a date.
    ///
    /// **And the count is what this ANSWER covers, not how big the survey is.** `folderCount` is
    /// scoped (see its own doc), so under a narrowing it is 79 where the survey is 3,013 — and
    /// the first draft read "Read from a survey of 79 folders", which attaches the scoped number
    /// to the artifact and describes neither. That is the same too-wide/too-narrow slip
    /// ``cleanMessage`` was already fixed for one state over, which is why it says "Checked N"
    /// rather than naming the survey. This says "Covers N" for the same reason.
    @ViewBuilder
    private var surveyNote: some View {
        let stale = Self.surveyIsStale(surveyedAt, now: Date())
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // **The glyph, and only the glyph.** Amber on 11pt body text is the documented
                // contrast trap; §4.1's rule is that the tint lands here and the sentence keeps
                // its ordinary colour.
                Image(systemName: stale ? "clock.badge.exclamationmark"
                                        : "clock.arrow.circlepath")
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text(Self.surveyNoteText(folderCount: folderCount, surveyedAt: surveyedAt,
                                         now: Date()))
                    .fixedSize(horizontal: false, vertical: true)
                // The remedy beside the warning: a caution with nothing to do about it is a
                // caution people learn to scroll past.
                if stale, let onUpdateSurvey {
                    Button("Rescan") { onUpdateSurvey() }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .chromeHover()
                        .help("Re-reads the tree and rebuilds the folder memory these findings "
                              + "come from. Slower, and the only thing here that makes the "
                              + "answer current.")
                }
            }
            if !hasDuplicateScan {
                Text(Self.taxonomyStalenessText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .scaledFont(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    /// §5.9's honesty line: the one detector that reads a scan says when the scan has not run —
    /// absent is not clean.
    static let taxonomyStalenessText =
        "The duplicated-taxonomy check reads the duplicate scan, which hasn’t run — those "
        + "findings are absent, not clean."

    static func surveyNoteText(folderCount: Int?, surveyedAt: Date? = nil,
                               now: Date = Date()) -> String {
        let tail = "Read from the folder survey, not from your disk. Update it if the tree has changed since."
        var head: [String] = []
        if let folderCount {
            head.append("Covers \(folderCount.formatted()) folder\(folderCount == 1 ? "" : "s").")
        }
        if let surveyedAt {
            head.append("Surveyed \(Self.surveyedPhrase(surveyedAt, now: now)).")
        }
        return (head + [tail]).joined(separator: " ")
    }

    /// How old a survey has to be before the note takes its caution tint.
    ///
    /// **Measured, not chosen** (2026-08-28, this machine). A month of log — 2026-07-28 to
    /// 2026-08-28, launched most days — contains exactly ONE completed re-survey, on 9 Aug, and
    /// the survey artifacts on disk (`filing-corpus.json`, `filing-memory.json`,
    /// `folder-profile.json`) were all still dated 9 Aug: nineteen days old and current.
    ///
    /// So a fortnight would tint the state this tree is in most of the time, which is how a
    /// caution stops being read; a month would not fire inside the only interval ever observed.
    /// Three weeks sits past the ordinary age and short of never. §4.1 said to ship the plain
    /// variant first and pick the number from real stamps — these are the stamps.
    static let staleSurveyDays = 21

    /// Whether the survey is old enough to say so. **Unknown is not stale**: a corpus from before
    /// §4.1's stamp existed has no date, and inventing a warning about an unknown age would be
    /// the same overreach as inventing the date.
    static func surveyIsStale(_ surveyedAt: Date?, now: Date) -> Bool {
        guard let surveyedAt else { return false }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: surveyedAt),
            to: Calendar.current.startOfDay(for: now)).day ?? 0
        return days >= staleSurveyDays
    }

    /// "today" / "yesterday" / "5 days ago" / "on 12 Aug 2026" — absolute past two weeks, because
    /// a checkable date beats a big round number (the release-notes rule, applied to UI).
    ///
    /// The caution tint is ``surveyIsStale``'s, and it lands on the glyph beside this sentence
    /// rather than on the sentence — see ``staleSurveyDays`` for where the number came from.
    static func surveyedPhrase(_ surveyedAt: Date, now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: surveyedAt),
            to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<0:
            // A stamp from the future is a wrong clock somewhere; the date is still the fact.
            return "on \(Self.absolute(surveyedAt))"
        case 0: return "today"
        case 1: return "yesterday"
        case 2...13: return "\(days) days ago"
        default: return "on \(Self.absolute(surveyedAt))"
        }
    }

    private static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    private var samplesAccessibility: String {
        "Example of the structure-finding format: a family of sibling folders, how many of them "
        + "use how many different internal shapes, and one row per shape listing the subfolders "
        + "its members agree on. These are samples, not folders in your tree."
    }

    /// The sample finding both card states show — the real card's own shape at sample scale: the
    /// family path, the verdict line, and one row per shape with members on the left and the
    /// subfolders those members AGREE on (the intersection, never a union) on the right. Drawn
    /// rather than described, because "two internal shapes" means nothing until you have seen
    /// the two.
    ///
    /// One definition, not one per state: two copies of a diagram that exists to teach one layout
    /// is how the diagram starts disagreeing with itself.
    private var samples: some View {
        LensSetupSampleRow {
            VStack(alignment: .leading, spacing: 5) {
                Text("Family/Aditi/Events")
                    .scaledFont(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("13 folders, 2 internal shapes")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                sampleSchemeRow(members: "Naming Ceremony, Birthday",
                                vocabulary: "Photos · Invitations")
                sampleSchemeRow(members: "Graduation",
                                vocabulary: "no shared subfolders")
            }
        }
    }
}
