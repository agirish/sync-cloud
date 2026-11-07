import SwiftUI
import Design
import Sync

/// What a card needs to say about a saved draft: the operation count for the trigger's words,
/// the ledger sentence for the inline line. Derived from the store's draft by the workspace, so
/// the lens never reads the store itself.
struct PlannedPlanInfo: Equatable {
    let operations: Int
    let summary: String
    /// The blast radius as numbers, once a draft makes them knowable. Derived from the draft's own
    /// manifest by the workspace, never estimated from the finding: the card's prose sentence is
    /// what the finding alone can honestly say.
    let renames: Int
    /// Folders that travel intact to a new parent. Its own count, not folded into renames, because
    /// the ledger sentence below prints it as its own clause; folded in, a card would read
    /// "1 rename" above "0 renames · 1 folder carried whole".
    let carried: Int
    let merges: Int
    let filesMove: Int

    /// The chips a card shows in place of its blast-radius sentence. The zero ones stay out, so a
    /// rename-only plan says "3 renames" rather than "3 renames · 0 merges".
    var radiusChips: [(text: String, movesFiles: Bool)] {
        var out: [(String, Bool)] = []
        if renames > 0 { out.append(("\(renames) rename\(renames == 1 ? "" : "s")", false)) }
        if carried > 0 {
            out.append(("\(carried) folder\(carried == 1 ? "" : "s") carried", true))
        }
        if merges > 0 { out.append(("\(merges) merge\(merges == 1 ? "" : "s")", false)) }
        if filesMove > 0 {
            // The verb agrees, not just the noun: one file moves, many files move.
            out.append(("\(filesMove) file\(filesMove == 1 ? " moves" : "s move")", true))
        }
        return out
    }
}

/// One ledger record, as the card needs it for its Applied and Undone states. Derived from the
/// store's `applied` section by the workspace; the lens never reads the store itself.
struct ReorganisationDisplay: Equatable, Identifiable {
    let manifestId: String
    let family: String
    /// The landing's stamp, as recorded.
    let at: String
    /// The ledger sentence, derived from what happened, never pasted.
    let summary: String
    let undoneAt: String?
    let undoSummary: String?
    /// True when a ledger undo is offered: the landing produced a profile to re-point back from
    /// and has not been undone.
    let canUndo: Bool
    /// True when the landing drained folders the removal sheet could take (the opt-in step).
    let hasEmptiedFolders: Bool
    /// The verifier's verdict, as the card states it; nil when the landing has none to state (an
    /// older record, or a landing that never reached the verifier). Silence, not a claim.
    var verifierLine: String?
    /// Why this record cannot be undone yet, when something newer stands in the way. nil on the
    /// one record that is undoable and on every record that has been undone.
    var blockedReason: String?
    var id: String { manifestId }

    /// The ledger's records as the cards state them: the whole mapping, as one rule, here so each
    /// clause is testable. `stillHasEmptiedFolders` is the one disk probe, passed in.
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
                    // function of the manifest, so on its own the button would outlive its landing,
                    // reopening a sheet of "already removed" rows.
                    hasEmptiedFolders: record.undoneAt == nil && record.summary != nil
                        && stillHasEmptiedFolders(record.manifest),
                    verifierLine: RestructureLens.verifierLine(verifiedOK: record.verifiedOK,
                                                               note: record.verifierNote),
                    // The store's order, never the view's: `undoableReorganisation` is the one
                    // spelling the engine and the Organize menu also read, so a card never offers
                    // an undo the engine refuses.
                    blockedReason: blockedReason(of: record, undoableId: undoableId))
            }
    }
}

extension ReorganisationDisplay {
    /// Why `record` offers no Undo, or nil when it does or is finished. A withheld Undo (a walk
    /// back to this folder found a landing in an overlapping one since) says so, and outranks
    /// "undo the newer first", which would not bring it back.
    static func blockedReason(of record: RestructureStore.AppliedRecord,
                              undoableId: String?) -> String? {
        guard record.undoneAt == nil, record.manifest.manifestId != undoableId else { return nil }
        if let root = record.undoWithheldBy {
            return RestructureLens.withheldText(by: root, unsure: record.undoWithheldUnsure == true)
        }
        return undoableId != nil ? RestructureLens.blockedByNewerText : nil
    }
}

/// Organize ▸ Restructure: families of sibling folders that were shaped differently at different
/// times.
///
/// Reporting first, acting only through reviewed plans. A finding says *these thirteen folders
/// use four different internal shapes*. The actions are bounded: the backlog scaffold
/// (create-only, one ⌘Z), and `Plan…`, which derives a manifest from a family mapping and ends at
/// a reviewable file and a saved draft, with nothing moved. Applying a manifest is a separate,
/// guarded step.
///
/// The states are distinct, and none borrows another's words: no profile means the detectors have
/// nothing to read, no findings means they ran and the tree agrees with itself, a list means it
/// does not, and a card with a draft says "Planned, not applied", a claim about a file, not the tree.
struct RestructureLens: View {
    let findings: [StructureFinding]
    /// Findings about a folder the scope sits *inside* (``ScopeRelation/aboutAncestor``), surfaced,
    /// not dropped. Restructure compares sibling families, so under a scope pointed at a leaf the
    /// `inside` list is often honestly empty, and without these the lens would look broken at the
    /// depth people scope to. Kept visually subordinate, as context rather than work in the scope;
    /// the rail badge does not count them.
    var aboutAncestor: [StructureFinding] = []
    let hasProfile: Bool
    /// How many folders this lens's answer covers: scoped, not the whole survey, so the clean
    /// state's count is about the same folder as the list. nil when there is no profile, or when
    /// the scope is a subtree the survey has never seen; the sentence then drops the count rather
    /// than inventing a zero.
    let folderCount: Int?
    /// When the survey last looked at the tree, or nil when unknown: a corpus that predates the
    /// stamp, or no profile at all.
    var surveyedAt: Date? = nil
    /// Whether a duplicate scan's groups are on hand. The duplicated-taxonomy detector reads the
    /// scan, not the profile, so with no scan its findings are absent, not clean, and the lens says
    /// so rather than letting silence claim health.
    var hasDuplicateScan: Bool = false
    /// Whether Organize is narrowed to a subtree: the clean state says a different thing about a
    /// folder than about the whole tree.
    var isScoped: Bool = false
    /// The provider this lens's answer covers, for the setup card's title: it compares sibling
    /// families across the surveyed tree, not inside the focused folder.
    var providerName: String?
    /// The crowding classification for this scope, path → class, already narrowed. Counts, not
    /// findings: always non-zero on a real tree, so it renders as the strip's three filters and
    /// never takes a badge.
    var deadWeight: [String: DeadWeightClass] = [:]
    let accent: Color
    let onReveal: (String) -> Void
    /// *Never suggest this again*: writes the finding's `kind × subject` into the store. nil
    /// hides the menu item rather than offering a promise nothing keeps.
    var onSuppress: ((StructureFinding) -> Void)?
    /// How many findings *Never suggest this again* has hidden, and the way back for all of them,
    /// so a mis-click doesn't hide a finding for good.
    var hiddenCount: Int = 0
    var onShowHidden: (() -> Void)?
    /// The backlog scaffold: creates the folders the family's vouched vocabulary expects, then
    /// hands the flat files to To File. Only rendered on a backlog card whose scaffold is
    /// non-empty; an all-drift family has nothing to copy and gets the hand-off alone.
    var onScaffold: ((StructureFinding) -> Void)?
    /// The To File hand-off, scoped to the finding's subject: the per-file half of a backlog or
    /// loose-files finding, sent to the surface that already makes per-file judgements.
    var onHandOff: ((StructureFinding) -> Void)?
    /// Opens a plan over the lens. Which plan is ``RestructurePlanRouting``'s answer, not this
    /// callback's: a family mapping for a shape, the same mapping seeded for a pair under one
    /// parent, a confirm sheet for a pair across parents. nil hides the button rather than
    /// promising a sheet that does not open.
    var onPlan: ((StructureFinding) -> Void)?
    /// Saved drafts by finding id, for *Planned, not applied*: the card carries the plan's ledger
    /// sentence inline, and its trigger reads *Review N operations* instead of *Plan…*.
    var plannedPlans: [String: PlannedPlanInfo] = [:]
    /// Subjects whose scaffold has already landed (from the store's ledger). Until the survey is
    /// re-derived the profile stays stale after a landing, so the finding keeps rendering, and its
    /// card must say the survey has not caught up rather than offer the same landing twice.
    var scaffoldedSubjects: Set<String> = []
    /// Whether the user has opened this answer this launch
    /// (``FileSyncManager/hasReviewedStructure``). False puts the setup card in front of a result
    /// that already exists, because it is read off a survey that may be weeks old, and the card is
    /// where that gets said.
    ///
    /// No default, unlike the other inputs here: a defaulted `true` would silently switch the gate
    /// off for any call site that forgets the argument.
    let hasReviewed: Bool
    /// Reveals the findings — the setup card's trigger once there is a survey to read.
    var onReview: (() -> Void)?
    /// Re-derives the folder memory from the tree as it stands now: the card's secondary action,
    /// the one that makes the answer more current. nil on a machine with nothing to re-survey.
    var onUpdateSurvey: (() -> Void)?
    /// True while a landing is running, the re-derive included. The refresh walks the whole tree
    /// (about five seconds on a real one), so every control that starts one is disabled and says so
    /// meanwhile, rather than looking idle and collecting refusals.
    var isRefreshing: Bool = false
    /// The Applied and Undone cards: the ledger's records, newest first. Rendered in the clean
    /// state too: a successful apply makes the finding vanish, and the clean state is where *Undo
    /// this reorganisation* has to live to be findable.
    var reorganisations: [ReorganisationDisplay] = []
    /// One point per stamped survey, for the trend line. The chart's own rule returns nil until two
    /// exist, rather than the view checking a count.
    var trend: [RestructureTrendChart.Point] = []
    /// Runs the ledger's stored inverse for one record. Not ⌘Z: both exist, and the card says
    /// which this is.
    var onUndoReorganisation: ((String) -> Void)?
    /// Opens the removal sheet, scoped to the folders that record's landing emptied.
    var onRemoveEmptied: ((String) -> Void)?
    /// Opens the Help book at Restructure's own page. nil hides the affordance: a pointer at
    /// documentation that goes nowhere is worse than none.
    var onOpenHelp: (() -> Void)?
    /// Re-derives the survey from the tree as it stands, for the Scaffolded card, whose sentence
    /// describes a wait that only this ends. Carries the asking card's subject so a refusal lands
    /// on the card that asked. nil hides the button.
    var onRefreshSurvey: ((String) -> Void)?
    /// What the last refresh refused with, and which card asked: a sentence on the card rather
    /// than a queue, because the guards are the landing's and "wait for the scan" means press it
    /// again. Keyed by subject, so the refusal shows under the card that asked, not every one.
    var refreshSurveyRefusal: (subject: String, sentence: String)?
    /// Opens the same sheet on pre-existing empties, the crowding strip's third filter. nil hides
    /// the button rather than promising a sheet that does not open.
    var onRemoveStandingEmpties: (() -> Void)?

    private var isEmpty: Bool { findings.isEmpty && aboutAncestor.isEmpty }

    /// Which crowding class's list is open, if any; a chip toggles it. `initialCrowdingFilter`
    /// seeds it, so tests can render the expanded list, where the removal button lives.
    @State private var crowdingFilter: DeadWeightClass?
    /// Seeds ``crowdingFilter`` at first appearance. nil (every list closed) everywhere but the
    /// tests that need the expanded state on screen.
    var initialCrowdingFilter: DeadWeightClass?
    /// Which top-level branches of a grouped crowding list are open. Empty on open: a grouped
    /// list that expanded itself would be the flat list it replaces.
    @State private var expandedBranches: Set<String> = []

    var body: some View {
        // The Help pointer rides the whole lens, not the crowding strip, which renders only where
        // the scope has dead-weight folders: the pointer must show on a clean subtree and in all
        // three card states, where a reader is most likely to be lost.
        lensBody
            .overlay(alignment: .topTrailing) {
                helpPointer.padding(.top, 6).padding(.trailing, 10)
            }
            .onAppear {
                if let initialCrowdingFilter, crowdingFilter == nil {
                    crowdingFilter = initialCrowdingFilter
                }
            }
    }

    @ViewBuilder
    private var lensBody: some View {
        if !hasProfile {
            noProfileState
        } else if !hasReviewed {
            readyState
        } else if isEmpty {
            // The strip renders in the clean state too: the seal answers shape, the strip answers
            // crowding, and without it the empties filter would be unreachable when it is the only
            // thing left to do. The reorganisation cards render here because this is the state a
            // successful apply lands in.
            if deadWeight.isEmpty && reorganisations.isEmpty && !showsHiddenRow {
                cleanState
            } else {
                // Scrollable, because this state accumulates: every successful apply lands its card
                // here, and an expanded crowding filter lists hundreds of paths, which a plain
                // VStack would clip past the lens bounds.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !deadWeight.isEmpty {
                            crowdingStrip.padding(12)
                        }
                        trendChart.padding(.horizontal, 12)
                        if !reorganisations.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(reorganisations, content: reorganisationCard)
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                        }
                        if showsHiddenRow { hiddenRow.padding(.horizontal, 12) }
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
                    trendChart
                    ForEach(reorganisations, content: reorganisationCard)
                    // The grouping rule's render half: rows arrive sorted so a folder's findings
                    // are adjacent, and the second card about one folder drops the path heading,
                    // a second thing about the same place, not a repeat.
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
                    if showsHiddenRow { hiddenRow }
                }
                .padding(12)
            }
        }
    }

    private var showsHiddenRow: Bool { hiddenCount > 0 && onShowHidden != nil }

    /// The way back from *Never suggest this again*.
    private var hiddenRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.hiddenSentence(hiddenCount))
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Show Them Again") { onShowHidden?() }
                .scaledFont(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .chromeHover()
                .help("Bring back the findings here hidden with “Never Suggest This Again”")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    static func hiddenSentence(_ count: Int) -> String {
        count == 1 ? "1 finding is hidden with “Never Suggest This Again”."
            : "\(count.formatted()) findings are hidden with “Never Suggest This Again”."
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
            // The verifier's verdict, on the card rather than only in the log: "did this check
            // out" is the question an Applied card exists to answer.
            if let verifierLine = record.verifierLine {
                Text(verifierLine)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Why the undo is not offered here, said before the click rather than as a refusal
            // after it. Derived from the store's own order, never re-derived in the view.
            if let blocked = record.blockedReason {
                Text(blocked)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if record.undoneAt == nil {
                HStack(spacing: 14) {
                    if record.canUndo, let onUndoReorganisation {
                        Button("Undo This Reorganization…") {
                            onUndoReorganisation(record.manifestId)
                        }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .chromeHover()
                        .lockedDuringRun()
                        .help("Asks first, then runs the inverse stored in the ledger and "
                              + "re-points the survey back — it survives a quit, and it is not ⌘Z.")
                    }
                    if record.hasEmptiedFolders, let onRemoveEmptied {
                        Button("Remove Emptied Folders…") { onRemoveEmptied(record.manifestId) }
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

    /// The verifier's verdict as one line, or nil when the record has none to give. Absent is not
    /// a pass: an older record, or a landing that refused before the verifier ran, says nothing
    /// rather than claiming agreement.
    static func verifierLine(verifiedOK: Bool?, note: String?) -> String? {
        guard let verifiedOK else { return nil }
        guard verifiedOK else {
            return "The check found a disagreement — \(note ?? "the log has it")."
        }
        return "Verified — the tree matches what the plan said it would do."
    }

    /// Why a landing that is not the newest cannot be undone yet: the ledger unwinds newest first,
    /// and saying so keeps a greyed row from being a mystery.
    static let blockedByNewerText =
        "Undo the newer reorganization first — the ledger unwinds one at a time, newest back."

    /// Why a landing taken up again by a walk back to its folder cannot be undone: a landing in an
    /// overlapping folder has moved what its Undo would put back, or (`unsure`) that folder's
    /// history can't say whether one did, which is not a reorganization to blame.
    static func withheldText(by root: String, unsure: Bool = false) -> String {
        unsure
            ? "This can’t be undone anymore — SyncCloud can’t tell whether “\(root)” was "
                + "reorganized since you last worked in this folder, so it won’t risk it."
            : "This can’t be undone anymore — a reorganization in “\(root)” has moved these "
                + "folders since you last worked in this one."
    }

    /// The path a landing's card is headed with. `"."` is the profile's spelling for the tree root
    /// (a removal of empties across the tree has no closer family), and rendered as is would head
    /// the card with a full stop. `""` means the same, so both are named.
    static func familyHeading(_ family: String) -> String {
        family == "." || family.isEmpty ? "Across the tree" : family
    }

    /// The card's sentence. Applied and Undone are different claims and neither borrows the
    /// other's words. The Undone line carries the undo run's own counts, because an undo never
    /// pretends the tree was untouched.
    static func reorganisationLine(_ record: ReorganisationDisplay, now: Date = Date(),
                                   locale: Locale? = nil) -> String {
        if let undoneAt = record.undoneAt {
            let tail = record.undoSummary.map { " — \($0)" } ?? ""
            return "Undone \(landingPhrase(undoneAt, now: now, locale: locale))\(tail). "
                + "Anything skipped as drift is named in the log."
        }
        return "Applied \(landingPhrase(record.at, now: now, locale: locale)) — \(record.summary)."
    }

    /// The ledger stamp in words: "today at 12:04", "yesterday at 09:14", "on 12 Aug 2026 at
    /// 09:14", not the stored machine stamp ("2026-08-28T12:04:00"). An unparseable stamp renders
    /// as itself: a wrong spelling of the truth beats a pretty invention.
    ///
    /// The time and date follow the reader's region and clock ("today at 2:04 PM" on a 12-hour
    /// Mac, "on 12 Aug 2026" in Britain). `locale` exists for tests only.
    static func landingPhrase(_ stamp: String, now: Date = Date(), locale: Locale? = nil) -> String {
        guard let date = Self.stampParser.date(from: stamp) else {
            return stamp
        }
        let time = Self.stampClock.string(from: date, locale: locale)
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "today at \(time)"
        case 1: return "yesterday at \(time)"
        default: return "on \(Self.absolute(date, locale: locale)) at \(time)"
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
    /// tree, like `cleanTitle`/`cleanMessage`. With nothing found inside the scope the list opens
    /// straight onto findings about a different folder, so that form says outright that the
    /// scope itself had none.
    static func ancestorHeading(hasFindingsHere: Bool) -> String {
        hasFindingsHere
            ? "About the folder above this one:"
            : "Nothing about this folder itself — but about the folder above it:"
    }

    // MARK: The crowding strip

    /// Three counts above the findings, each a filter into a list. Crowding is a property of the
    /// scope, always non-zero on a real tree, so these are chips, not cards, and none takes a
    /// badge. Only the empties carry an action (the removal sheet); the other two are report-only.
    private var crowdingStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(DeadWeightClass.allCases, id: \.self) { weightClass in
                    crowdingChip(weightClass)
                }
                Spacer(minLength: 0)
            }
            // Frosted and Clear: the chosen chip's wash as one glass lens that glides between
            // chips, grows out of the one you pick and melts back when the filter clears.
            .selectionLensHost(Self.crowdingLensChannel, selected: crowdingFilter,
                               style: .wash(.capsule, color: accent, opacity: Self.crowdingWash))
            if let crowdingFilter {
                crowdingList(crowdingFilter)
            }
        }
    }

    /// The trend line, under the crowding chips where there are any and on its own where there
    /// are not. It hangs off the lens, not the strip, which renders only under
    /// `!deadWeight.isEmpty`: the clean tree is where "33 → 0 findings · 4 landings" says most.
    @ViewBuilder
    private var trendChart: some View {
        if trend.count >= 2 {
            RestructureTrendChart(points: trend, accent: accent)
                .padding(.top, 2)
        }
    }

    /// Whether the expanded list ends in a Trash route: only for the empties. The other two
    /// classes are report-only for reasons their tooltips state (a single-file leaf can be a
    /// destination waiting for its next file; hoisting a pass-through renames every path beneath
    /// it), so trashing them would act on the judgement the strip refuses to make.
    static func offersStandingRemoval(_ weightClass: DeadWeightClass, pathCount: Int,
                                      hasHandler: Bool) -> Bool {
        weightClass == .empty && pathCount > 0 && hasHandler
    }

    /// A pointer at the Help page that explains the plan flow and why the ledger's undo is not ⌘Z,
    /// for the reader most in need of it. One affordance, through the app's existing Help front
    /// door, never a second overlay or a sheet.
    @ViewBuilder
    private var helpPointer: some View {
        if let onOpenHelp {
            Button(action: onOpenHelp) {
                Image(systemName: "questionmark.circle")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            // `.help` is the tooltip, not the name; a glyph-only control needs both.
            .accessibilityLabel("About Restructure")
            // Says what this page covers; the ⌘Z explanation lives on *Apply, and take it back*.
            .help("What Restructure looks for, and how a plan is reviewed before anything moves.")
            .chromeHover()
        }
    }

    /// The Help topic this lens points at; see ``OrganizeHelpTopics/restructure``.
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

    /// How many paths a class holds, counted, never listed: `crowdingPaths(_:)` filters and sorts
    /// the whole map, which a chip's number doesn't need on every render. `static`, taking the map,
    /// so it can be checked against `crowdingPaths`' count without mounting the lens; the two must
    /// agree or a chip labels a list it does not describe.
    static func crowdingCount(_ deadWeight: [String: DeadWeightClass],
                              _ weightClass: DeadWeightClass) -> Int {
        deadWeight.count { $0.value == weightClass }
    }

    private func crowdingCount(_ weightClass: DeadWeightClass) -> Int {
        Self.crowdingCount(deadWeight, weightClass)
    }

    /// The chosen chip's wash, named once because the strip's selection lens wears it too.
    static let crowdingWash: Double = 0.18
    /// The strip's selection lens; see `SelectionLens`.
    static let crowdingLensChannel = SelectionLensChannel("restructure.crowding")

    private func crowdingChip(_ weightClass: DeadWeightClass) -> some View {
        let count = crowdingCount(weightClass)
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
        // The chosen chip's wash is the marker; the lens carries it in Frosted and Clear. One shape
        // in both states, so a change of chip tweens rather than cross-fades.
        .background(SelectionLensGround(Capsule(), isSelected: isSelected,
                                        selected: accent.opacity(Self.crowdingWash),
                                        unselected: .quaternary.opacity(0.30)))
        .selectionLensStop(Self.crowdingLensChannel, id: weightClass)
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        // A selected chip stays clickable at zero: the removal sheet can drain a class while its
        // filter is open, and a selected-and-disabled chip would leave no way to clear the filter.
        .disabled(count == 0 && !isSelected)
        .opacity(count == 0 && !isSelected ? 0.4 : 1)
        .help(Self.crowdingHelp(weightClass))
    }

    /// Why the number is a number and not a button: each class states its own reason.
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

    /// Above this many paths a flat list stops being surveyable and the rows are grouped by their
    /// top-level folder; below it, grouping only adds a disclosure to open. On a real tree
    /// (~503 single-file, ~86 pass-through, 20 empties) this groups the first two and leaves the
    /// empties flat, their removal button one click away.
    static let crowdingGroupingThreshold = 40

    /// Paths grouped by first path component, biggest branch first: the rule, so the threshold
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
            // Count descending, then name: the biggest pile is the one worth opening first, and
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
            // The empties' Trash route, only on this class and only under the expanded list. Past
            // the grouping threshold the list is branch rows, not paths; either way the sheet it
            // opens is the review, and every row there is re-probed and ticked one by one.
            if Self.offersStandingRemoval(weightClass, pathCount: paths.count,
                                          hasHandler: onRemoveStandingEmpties != nil),
               let onRemoveStandingEmpties {
                Button("Remove Empty Folders…") { onRemoveStandingEmpties() }
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
                // Every row in the crowding list says "Reveal", so VoiceOver needs each to name
                // where it goes.
                .accessibilityLabel("Reveal \(path)")
                .chromeHover()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
    }

    /// One branch's disclosure, collapsed on open, so five hundred paths become a dozen lines you
    /// can read before deciding which to expand.
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
        // The chevron is the only visual state, invisible to VoiceOver, so the value says it. A
        // disclosure, not a selection: `.isSelected` reads as "this row is picked".
        .accessibilityLabel("\(branch), \(count) folder\(count == 1 ? "" : "s")")
        .accessibilityValue(expandedBranches.contains(branch) ? "expanded" : "collapsed")
        .accessibilityHint("Shows the folders in this branch")
        .help(expandedBranches.contains(branch) ? "Hide the folders in this branch"
                                                : "Show the folders in this branch")
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
                // `Plan…` takes the action slot on the cards that have one, and `Reveal` is
                // demoted. A drafted plan changes the trigger's words: the plan exists, so the
                // button offers its review, not its creation.
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
            // The eras at a glance, when the family is about years. The text rows below stay
            // authoritative: this draws the same information in order, never replacing the list
            // of what each era contains.
            if let segments = Self.eraSegments(schemes: finding.schemes, drift: finding.drift,
                                               shapeless: finding.shapeless) {
                eraStrip(segments, schemes: finding.schemes)
            }
            // The schemes are shown rather than asserted: the eras are visible, and so is the odd
            // year out. A verdict that only said "these disagree" would be asking to be trusted.
            ForEach(Array(finding.schemes.enumerated()), id: \.offset) { _, scheme in
                schemeRow(scheme)
            }
            // The members no scheme holds, rendered instead of swallowed. Drift is greyed: members
            // whose shape no second sibling vouches for. The shape-less sibling gets its own words:
            // "no shape of its own" is a different sentence from "disagrees with the others".
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
            // Where a draft exists the numbers are known, so the card states them instead of
            // describing the shape of the cost. The sentence is the no-draft fallback, the honest
            // answer when nothing has been derived yet.
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
                // Planned, not applied: the ledger inline, so the card says what the draft would
                // do without opening the sheet, and says plainly that nothing has happened yet.
                Text("Planned, not applied — \(plan.summary).")
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            actionRow(for: finding)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `lensCard()`, as every lens's content cards wear it, not a hand-rolled slab. The scheme
        // rows inside keep their quiet inner fills.
        .lensCard()
        .contextMenu {
            if let onSuppress {
                Button("Never Suggest This Again") { onSuppress(finding) }
            }
        }
    }

    /// The actions below a finding: the scaffold and the To File hand-off, on the two kinds whose
    /// fix is per-file or create-only. Plans are offered by the card's `Plan…` button.
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
                            Button("Update the Survey") { onRefreshSurvey(finding.subject) }
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
                    Button("Set Up Like Its Siblings") { onScaffold(finding) }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                        .chromeHover()
                        .lockedDuringRun()
                        .help("Creates \(scaffold.joined(separator: ", ")) — folders only, one "
                              + "⌘Z — then opens To File scoped here for the flat files.")
                }
                if let onHandOff {
                    Button("File These…") { onHandOff(finding) }
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
                Button("File These…") { onHandOff(finding) }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .chromeHover()
                    .help("Opens To File scoped to this folder — which year each file belongs "
                          + "to is a per-file judgment.")
            }
        default:
            EmptyView()
        }
    }

    /// The Update the Survey button's tooltip: why it is worth pressing, and what it costs,
    /// including the part a reader would not guess: it replaces the hand-built profile with a
    /// derived one, as a plan's landing does. Said here so the change is sanctioned, not a surprise.
    static let refreshSurveyHelp =
        "Re-reads the tree and refreshes what has been learned, so the folders this scaffold created "
        + "are in it and this finding goes. It replaces the survey with a freshly derived one, "
        + "the same way applying a plan does."

    /// What a backlog card says once its scaffold has landed but the survey has not been
    /// re-derived: applied is not resolved, and neither borrows the other's sentence.
    static let scaffoldLandedText =
        "Scaffolded — the survey hasn’t caught up yet, so this stays until it is updated."

    /// The plan trigger's words: *Plan…* creates, *Review N operations* reopens what exists, the
    /// trigger for the Planned state. The two never both show.
    private func planTriggerTitle(for finding: StructureFinding) -> String {
        Self.planTriggerTitle(planned: plannedPlans[finding.id])
    }

    /// What the plan trigger promises: the surface it opens, which differs by kind. A shape finding
    /// opens the mapping editor with its choose-a-shape step; a pair opens a review of operations
    /// already determined. Both end in a sheet that moves nothing until its own Apply is pressed,
    /// and that is said either way.
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
        return "Review \(planned.operations) Operation\(planned.operations == 1 ? "" : "s")"
    }

    private func kindTag(_ kind: FindingKind) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: Self.kindSymbol(kind))
                .scaledFont(.system(size: 8.5, weight: .semibold))
                // The glyph, and only the glyph, takes the accent: accent on 9.5pt text is the
                // contrast trap the amber-on-body-text rule exists for, and a tag is not a control.
                .foregroundStyle(Self.glyphTakesAccent(kind) ? AnyShapeStyle(accent)
                                                             : AnyShapeStyle(.secondary))
                // Decorative: the label beside it says which kind this is, and the tooltip says
                // what acting on it would do.
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

    /// Whether a kind's glyph takes the accent: the same question the Plan button asks.
    /// `FindingKind.carriesPlan`, the rail badge's rule, is deliberately wider: it counts
    /// `duplicatedTaxonomy`, which has no plan surface, so tinting on it would promise a plan the
    /// card does not offer.
    static func glyphTakesAccent(_ kind: FindingKind) -> Bool {
        switch kind {
        case .shape, .shadowAxis, .echoName, .mirroredInbox, .looseBesideContainer: return true
        case .backlog: return true      // its card ends in the scaffold landing
        case .deadWeight, .looseAboveSeries, .duplicatedTaxonomy, .ask: return false
        }
    }

    /// One symbol per kind, so a mixed list sorts by eye before it is read. Exhaustive on purpose:
    /// a detector added later fails to compile here rather than rendering a blank square. Each
    /// symbol says what the finding is, not what would be done about it (the tooltip's job), so two
    /// kinds whose fix is a merge still look different.
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

    /// The kind tag's noun: short enough for a chip, distinct enough to sort a mixed list by eye.
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

    /// The verb the tag's tooltip carries: what acting on this class of finding would do, so the
    /// class of change is legible before any sheet opens.
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
        // Reports, for now: no plan surface exists, so the tooltip must not promise the merge in
        // words any more than `glyphTakesAccent` lets the glyph promise it.
        case .duplicatedTaxonomy: return "Reports the pair — no plan yet"
        case .ask: return "Asks — the answer is remembered, nothing moves"
        }
    }

    /// The line under the path: each kind states what it saw, in its own words.
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
            return "\(looseFiles == 1 ? "1 file" : "\(looseFiles.formatted()) files") above \(seriesFolders) year folders"
        case (_, .looseBesideContainer(let container)):
            return "belongs in \((container as NSString).lastPathComponent)/"
        case (_, .duplicatedTaxonomy(let counterpart, let matched)):
            // The counterpart's whole path, not its last component: the claim is that two
            // branches hold the same documents, and `Forms` alone would not say which two.
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

    /// The card's blast-radius sentence: the honest cost, derived from the finding's own shape,
    /// and the sentence that makes someone open the sheet. nil for the kinds whose subtitle
    /// already carries the whole story.
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
            return "Per-file judgment — these hand off to To File, scoped here."
        case (_, .looseBesideContainer):
            return "A plan here moves one folder — its files ride along."
        case (_, .duplicatedTaxonomy):
            // The one plan-bearing kind without its own Plan: resolving it merges two branches,
            // a judgement the Duplicates lens's per-group review owns.
            return "Two branches hold the same documents — resolving them merges files, "
                + "reviewed per group in Duplicates."
        default:
            return nil
        }
    }

    // MARK: The era strip (§5.1)

    /// One segment of the era strip: a contiguous run of year-named members that share a scheme.
    struct EraSegment: Equatable {
        /// The scheme these members belong to, or nil for drift, which is drawn hollow because
        /// "no two agree on one shape" is the absence of a scheme, not a fourth one.
        let scheme: Int?
        /// What the segment is labelled: a single year, or `first–last`.
        let label: String
        /// How many members it covers; the strip is proportional, so this is its width.
        let count: Int
    }

    /// The eras across a shape family, in year order, so where each era begins and ends is one
    /// glance rather than something assembled from comma-joined text.
    ///
    /// nil, and no strip, when the family is not about years: `Photos, Invitations, Receipts` has
    /// no order to draw. The bar is 80% of members parsing as years, so one oddly-named member
    /// among fifteen years does not suppress it. The year test is
    /// ``FolderProfileEntry/looksLikeYear(_:)`` and nothing else, so there is one answer to "is
    /// this a year".
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
            // Shapeless members are members: left out of `total`, a family of four years and ten
            // unnamed folders would pass the bar and draw eras over less than a third of it.
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

    /// A run's label: `2013` alone, `2013–2015` once it has grown, built from the run's own first
    /// and last member. The separator is an en dash and a fiscal member carries an ASCII hyphen,
    /// so splitting on the en dash alone keeps a member's own hyphen (`2014-2015`) intact.
    private static func spanLabel(from existing: String, to newest: String) -> String {
        let first = existing.components(separatedBy: "\u{2013}").first ?? existing
        return first == newest ? first : "\(first)\u{2013}\(newest)"
    }

    /// The strip itself: a segment per era, proportional to how many folders it covers. Drift is
    /// hollow. No animation: nothing here moves, and an implicit one would ride on any state
    /// change above it.
    ///
    /// The proportion needs the available width, and a `GeometryReader` is greedy in both axes, so
    /// in a card it takes all the vertical space. The natural row is laid out hidden to set the
    /// strip's bounds, and the measured one is overlaid inside them. Not `layoutPriority`, which
    /// decides who gets space first, not how much: the largest era would swallow the row.
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

    /// Each segment's width: the row's space, less the gaps, shared out by member count. A rule
    /// rather than an expression inside the reader, because "proportional" is the strip's whole
    /// claim, and a render comparison can't check it (different counts also mean different labels).
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
    /// hue, by the accent-fill convention rather than a palette of its own.
    private func schemeOpacity(_ scheme: Int) -> Double {
        // No step below 0.17: lighter, an era reads as the hollow drift treatment it must be told
        // apart from, and a filled segment carries no border to tell them apart.
        Self.schemeOpacities[scheme % Self.schemeOpacities.count]
    }

    /// Four depths of the accent, each far enough from the next to read as a different era and
    /// all far enough from nothing to read as filled.
    static let schemeOpacities: [Double] = [0.30, 0.20, 0.42, 0.26]

    /// The strip is a picture; this is the sentence it makes. Schemes are named by their
    /// vocabulary, as the rows below name them: an ordinal ("shape 1") is a number nothing else on
    /// the card establishes.
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

    /// A drift, shapeless or scaffold row: `schemeRow`'s two-column shape with a note instead of a
    /// vocabulary.
    private func extraRow(members: String, note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(members)
                .scaledFont(.system(size: 11, weight: .medium))
                .frame(width: 150, alignment: .leading)
                .lineLimit(2)
                // The whole list, which two lines at 150pt cut off past about four names.
                .help(members)
            Text(note)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.30)))
    }

    /// A scheme row for the setup card's sample: `schemeRow`'s two-column shape at sample scale.
    /// A separate body, not a fake `StructureFinding.Scheme` through the real one, so no invented
    /// family is one type-check away from the list of real ones.
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
        let members = scheme.members.joined(separator: ", ")
        return HStack(alignment: .top, spacing: 8) {
            Text(members)
                .scaledFont(.system(size: 11, weight: .medium))
                .frame(width: 150, alignment: .leading)
                .lineLimit(2)
                // The members are the finding, and two lines at 150pt hold about four names, so
                // the whole list shows on hover.
                .help(members)
            // The vocabulary these siblings agree on, the intersection. A union would advertise
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

    /// The clean state's words, as values so they can be asserted without rendering. The title
    /// changes with the subject: "the tree agrees with itself" is a claim about the whole tree,
    /// and under a scope this lens has only looked at part of it.
    static func cleanTitle(isScoped: Bool) -> String {
        isScoped ? "This folder agrees with itself" : "The tree agrees with itself"
    }

    static func cleanMessage(folderCount: Int?) -> String {
        let tail = "No family of sibling folders is using more than one internal shape."
        guard let folderCount else { return tail }
        // Grouped, like the setup card's footnote: "3013" in running prose is a number the eye has
        // to stop and parse.
        return "Checked \(folderCount.formatted()) folder\(folderCount == 1 ? "" : "s"). " + tail
    }

    /// Restructure before it has anything to read: the setup card, like every other lens's
    /// before-screen, with the job, the safety contract and sample rows in the shape real findings
    /// take. The samples matter most here: a structure finding (a family, a count of shapes, a row
    /// per shape naming the subfolders its members agree on) is Organize's least self-explanatory.
    ///
    /// It has no trigger: the folder profile is built against the tree and read from disk at
    /// launch, and no screen in the app makes one, so a button would be a promise nothing keeps.
    /// The card states where the answer would come from and stops; `LensSetupCard` draws without
    /// a trigger for this.
    private var noProfileState: some View {
        LensSetupCard(
            intro: LensIntros.restructure(providerName: providerName),
            accent: accent,
            triggerTitle: "Set Up the Survey",
            triggerSymbol: "gearshape",
            // These three are required by `LensSetupCard` and, with `onStart: nil` below, never
            // rendered: the card draws its trigger and its `.help` only inside `if let onStart`.
            // Kept true anyway, and naming no destination (Settings ▸ Organize has no survey
            // control), because unrendered copy goes stale unchecked and shows the moment
            // somebody wires a trigger here.
            triggerHelp: "Restructure reads the survey of your tree rather than the disk, so it "
                + "needs that survey first.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: samplesAccessibility,
            onStart: nil,
            footnote: AnyView(noSurveyNote),
            samples: { samples }
        )
    }

    /// Why there is nothing to press. Sits in the slot the reveal card puts its "read from a
    /// survey of N folders" line in: a fact about the input, under the card.
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

    /// Says what is missing, and not where to get it: no screen builds a survey (see
    /// ``noProfileState``), and naming a destination that cannot help would mislead.
    static let noSurveyNoteText =
        "This tree has no folder survey yet, so there is nothing to compare. "
        + "Organize’s other lenses read the disk directly and work without one."

    /// Restructure with a survey to read, before the user has asked for the answer this launch:
    /// the same card, over results that already exist. Other lenses' findings live only in
    /// memory, so a relaunch puts them back on the card by itself; Restructure's come from a
    /// profile read at startup, and without this the lens would open on an answer nobody asked
    /// for. See ``FileSyncManager/hasReviewedStructure``.
    ///
    /// The trigger reveals rather than computes, and says so: the findings are in hand and the
    /// click is free. The re-survey is what costs something and makes the answer current, so it
    /// is the secondary button; "Rescan" on the primary would promise a fresh look and deliver a
    /// cached one. The footnote, in the slot To File uses for its last pass's cost, says the
    /// results are cached.
    private var readyState: some View {
        LensSetupCard(
            intro: LensIntros.restructure(providerName: providerName),
            accent: accent,
            triggerTitle: Self.revealTitle(findingCount: findings.count),
            triggerSymbol: findings.isEmpty ? "checkmark.circle" : "list.bullet.rectangle",
            triggerHelp: findings.isEmpty
                ? "Show what the survey says about this tree’s folder shapes. Already computed — nothing is read from disk."
                : "Show the families the survey found disagreeing. Already computed — nothing is read from disk.",
            samplesTitle: "What a finding looks like",
            samplesAccessibility: samplesAccessibility,
            onStart: onReview,
            secondary: onUpdateSurvey.map {
                LensSetupCard.SecondaryAction(
                    title: isRefreshing ? "Updating the Survey…" : "Update the Survey",
                    symbol: "arrow.clockwise",
                    help: isRefreshing
                        ? "Re-reading the tree now — this takes a few seconds."
                        : "Re-read the tree and refresh what these findings come "
                        + "from. Slower, and the only thing here that makes the answer current.",
                    action: $0,
                    isBusy: isRefreshing)
            },
            footnote: AnyView(surveyNote),
            samples: { samples }
        )
    }

    /// The reveal trigger's words: a count of what opens, every finding this lens will render,
    /// ancestor list excluded. The rail badge counts only the plan-bearing kinds, because a badge
    /// you cannot drive to zero stops being read, so the two may differ by design: the badge says
    /// how much work is here, this says how much you will see.
    ///
    /// Zero is its own phrasing, not "Show 0 findings", which reads as a button that does nothing.
    /// It usually opens the clean state, but a scope with no findings can still have ancestor
    /// ones; "Check the shapes" is true of both.
    static func revealTitle(findingCount: Int) -> String {
        guard findingCount > 0 else { return "Check the Shapes" }
        return "Show \(findingCount) Finding\(findingCount == 1 ? "" : "s")"
    }

    /// Says where the answer came from, so "update" is a choice rather than a guess.
    ///
    /// The corpus's `surveyedAt` moves on every survey, even one that changes nothing, so
    /// "surveyed N days ago" dates the last look, not the last change. A nil `surveyedAt` (an
    /// older corpus) claims coverage only, rather than inventing a date.
    ///
    /// The count is what this answer covers, not how big the survey is: `folderCount` is scoped,
    /// so the note says "Covers N", as ``cleanMessage`` says "Checked N", never "a survey of N".
    @ViewBuilder
    private var surveyNote: some View {
        let stale = Self.surveyIsStale(surveyedAt, now: Date())
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The glyph, and only the glyph, takes the tint: amber on 11pt body text is the
                // documented contrast trap, so the sentence keeps its ordinary colour.
                Image(systemName: stale ? "clock.badge.exclamationmark"
                                        : "clock.arrow.circlepath")
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text(Self.surveyNoteText(folderCount: folderCount, surveyedAt: surveyedAt,
                                         now: Date()))
                    .fixedSize(horizontal: false, vertical: true)
                // The remedy beside the warning: a caution with nothing to do about it is one
                // people learn to scroll past.
                if stale, let onUpdateSurvey {
                    Button(isRefreshing ? "Updating the Survey…" : "Update the Survey") { onUpdateSurvey() }
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        // Not the accent while it is running: an accented control reads as
                        // "press me", and this one is the thing already in progress.
                        .foregroundStyle(isRefreshing ? AnyShapeStyle(.secondary)
                                                      : AnyShapeStyle(accent))
                        .chromeHover()
                        .disabled(isRefreshing)
                        .help(isRefreshing
                              ? "Re-reading the tree now — this takes a few seconds."
                              : "Re-reads the tree and refreshes what these findings "
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

    /// The one detector that reads a scan says when the scan has not run: absent is not clean.
    static let taxonomyStalenessText =
        "The duplicated-taxonomy check reads the duplicate scan, which hasn’t run — those "
        + "findings are absent, not clean."

    static func surveyNoteText(folderCount: Int?, surveyedAt: Date? = nil,
                               now: Date = Date(), locale: Locale? = nil) -> String {
        let tail = "Read from the folder survey, not from your disk. Update it if the tree has changed since."
        var head: [String] = []
        if let folderCount {
            head.append("Covers \(folderCount.formatted()) folder\(folderCount == 1 ? "" : "s").")
        }
        if let surveyedAt {
            head.append("Surveyed \(Self.surveyedPhrase(surveyedAt, now: now, locale: locale)).")
        }
        return (head + [tail]).joined(separator: " ")
    }

    /// How old a survey has to be before the note takes its caution tint. Picked from real
    /// stamps: a month of use saw one re-survey, and a current survey nineteen days old. A
    /// fortnight would tint the ordinary state, so the caution stops being read; a month would
    /// rarely fire. Three weeks sits past the ordinary age and short of never.
    static let staleSurveyDays = 21

    /// Whether the survey is old enough to say so. Unknown is not stale: an older corpus has no
    /// date, and warning about an unknown age would be the same overreach as inventing the date.
    static func surveyIsStale(_ surveyedAt: Date?, now: Date) -> Bool {
        guard let surveyedAt else { return false }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: surveyedAt),
            to: Calendar.current.startOfDay(for: now)).day ?? 0
        return days >= staleSurveyDays
    }

    /// "today" / "yesterday" / "5 days ago" / "on 12 Aug 2026": absolute past two weeks, because a
    /// checkable date beats a big round number. The caution tint is ``surveyIsStale``'s, on the
    /// glyph beside this sentence, not on it.
    static func surveyedPhrase(_ surveyedAt: Date, now: Date, locale: Locale? = nil) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: surveyedAt),
            to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<0:
            // A stamp from the future is a wrong clock somewhere; the date is still the fact.
            return "on \(Self.absolute(surveyedAt, locale: locale))"
        case 0: return "today"
        case 1: return "yesterday"
        case 2...13: return "\(days) days ago"
        default: return "on \(Self.absolute(surveyedAt, locale: locale))"
        }
    }

    private static func absolute(_ date: Date, locale: Locale? = nil) -> String {
        Self.stampDate.string(from: date, locale: locale)
    }

    /// The formatters these cards read stamps with, built once each, because `DateFormatter` setup
    /// is expensive and every ledger card would otherwise pay it on every redraw.
    ///
    /// The zone is re-checked rather than pinned (`ZoneRefreshedFormatter`'s job): a cached
    /// formatter would keep the zone it was built in, so a landing stamped this morning would read
    /// an hour out after a flight. Internal, not private, so
    /// `theStampFormattersFollowTheSystemZone` can drive the refresh without mutating the
    /// process-wide `NSTimeZone.default`, which would race every other suite.
    ///
    /// The parser is fixed POSIX, because the stamp is machine text; the clock and date a person
    /// reads follow the reader's region, like every other date in Browse.
    static let stampParser = ZoneRefreshedFormatter.fixed("yyyy-MM-dd'T'HH:mm:ss")
    static let stampClock = ZoneRefreshedFormatter.localized(date: .none, time: .short)
    static let stampDate = ZoneRefreshedFormatter.localized(date: .medium, time: .none)

    private var samplesAccessibility: String {
        "Example of the structure-finding format: a family of sibling folders, how many of them "
        + "use how many different internal shapes, and one row per shape listing the subfolders "
        + "its members agree on. These are samples, not folders in your tree."
    }

    /// The sample finding both card states show: the real card's shape at sample scale, with the
    /// family path, the verdict line, and one row per shape (members left, the subfolders they
    /// agree on right). Drawn, because "two internal shapes" means nothing until you see the two.
    /// One definition for both states, so the diagram can't disagree with itself.
    private var samples: some View {
        LensSetupSampleRow {
            VStack(alignment: .leading, spacing: 5) {
                Text("Family/Daughter/Events")
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
