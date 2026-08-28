import SwiftUI
import Design
import Sync

/// What a card needs to say about a saved draft — the operation count for the trigger's words,
/// the ledger sentence for the inline line. Derived from the store's draft by the workspace, so
/// the lens never reads the store itself.
struct PlannedPlanInfo: Equatable {
    let operations: Int
    let summary: String
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
    var id: String { manifestId }
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
    /// Opens the same sheet on §5.2's **pre-existing** empties — the crowding strip's third
    /// filter, which the roadmap decided gets a Trash route and shipped without one. nil hides
    /// the button rather than promising a sheet that does not open.
    var onRemoveStandingEmpties: (() -> Void)?

    private var isEmpty: Bool { findings.isEmpty && aboutAncestor.isEmpty }

    /// Which crowding class the strip is currently expanded on, if any.
    @State private var crowdingFilter: DeadWeightClass?

    var body: some View {
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

    private func crowdingList(_ weightClass: DeadWeightClass) -> some View {
        let paths = crowdingPaths(weightClass)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(paths, id: \.self) { path in
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
                        // Every row in the crowding list says "Reveal" — VoiceOver needs each
                        // to name where it goes.
                        .accessibilityLabel("Reveal \(path)")
                        .chromeHover()
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
            }
            // The empties' Trash route (ROADMAP_V5 §5.2, decided). Only on this class — the
            // other two are report-only and say so in their own tooltips — and only under the
            // expanded list, so the paths it would act on are on screen above the button.
            if weightClass == .empty, !paths.isEmpty, let onRemoveStandingEmpties {
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
            if let radius = Self.blastRadius(for: finding) {
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
                    Text(Self.scaffoldLandedText)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.secondary)
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
        Text(Self.kindLabel(kind))
            .scaledFont(.system(size: 9.5, weight: .semibold))
            .padding(.vertical, 1.5)
            .padding(.horizontal, 6)
            .background(Capsule().fill(.quaternary.opacity(0.35)))
            .foregroundStyle(.secondary)
            .help(Self.kindVerb(kind))
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath").scaledFont(.system(size: 10))
                Text(Self.surveyNoteText(folderCount: folderCount, surveyedAt: surveyedAt,
                                         now: Date()))
                    .fixedSize(horizontal: false, vertical: true)
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

    /// "today" / "yesterday" / "5 days ago" / "on 12 Aug 2026" — absolute past two weeks, because
    /// a checkable date beats a big round number (the release-notes rule, applied to UI).
    ///
    /// No caution tint yet, deliberately: the staleness threshold is unmeasured and ROADMAP_V5
    /// §4.1 says to ship the plain variant first and pick the number from real stamps.
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
