import SwiftUI
import Design

// MARK: - The rail item

/// What a rail item has to say about its lens, and so how it is dressed.
///
/// The same three states ``OrganizeOverviewState`` models, deliberately: never conflate "ran and
/// found nothing" with "never looked", since a zero is a claim a lens that hasn't scanned can't
/// make. `LensWorkspaceView` derives both surfaces from the same counts, so they share one
/// vocabulary.
enum RailItemState: Equatable {
    /// This lens has findings here. The count is the whole scoped list, never the filtered view.
    case reporting(Int)
    /// It ran and found nothing. Says so by going quiet, not by drawing a `0`.
    case clean
    /// It hasn't run here at all. Never a zero: that would be a claim it can't support.
    case notScanned
    /// Not a finding at all: neither `clean` nor `notScanned`, which both describe a scan whose
    /// answer was a count.
    ///
    /// Rules, Storage and the overview item wear it. Rules is configuration you keep, which never
    /// reports and never goes quiet; Storage's analyzer runs, but produces a report with no verb, so
    /// a badge would promise work and "nothing here" would be false. The shared meaning is "no count
    /// here means something needs you", which `OrganizeLens.carriesBadge` decides.
    case configuration
}

/// One item on Organize's lens rail: glyph, name, and a badge only when there is something to
/// report.
///
/// The place is unconditional: it is what "Organize this folder" lands on, before any scan. The
/// claim is conditional: nothing to report draws no number at all, not a greyed one and not a `0`.
///
/// It wears a capsule because a capsule is a control. Every rail item is a button, so dropping the
/// capsule on the quiet ones would dress live controls as prose.
///
/// ## The tint says "has work", not "is clickable"
///
/// The capsule carries the control claim; the wash carries the finding. A reporting item is
/// accent-tinted with an accent glyph; a quiet one takes a neutral wash and a secondary glyph.
/// Both are plainly buttons, and which of the six want you is legible before you read a number.
struct RailItemLabel: View {
    /// The selected item's wash, and the ring around it, named once because the rail's selection
    /// lens wears the same two values (`LensWorkspaceView.railLensStyle`).
    static let selectedWash: Double = 0.22
    static let ringWidth: CGFloat = 2

    let title: String
    let systemImage: String
    let state: RailItemState
    let isSelected: Bool
    let accent: Color
    /// Whether the row can afford this item's label; see ``OrganizeRailMetrics``. At `.iconOnly` the
    /// name survives in the tooltip and the accessibility label, as the workspace bar's segments do
    /// when they shed.
    var style: OrganizeRailStyle = .full
    /// What the rail's selection lens is drawing: `.today` at Solid, under Reduce Transparency and
    /// outside the rail. Glass is what lets the count arrive rather than appear, and what takes the
    /// selected item's own wash away.
    @Environment(\.selectionLensMaterial) private var lensMaterial

    /// Findings: the one state that colours the item.
    private var isReporting: Bool {
        if case .reporting = state { return true }
        return false
    }

    /// The badge's digits, abbreviated past three of them.
    ///
    /// A four-digit badge (`1,192`) widens the rail on the day it most needs to fit, and shouts
    /// over a small count that may matter more, since a badge encodes list size, never urgency.
    /// The exact figure stays in the tooltip and in row 2's readout.
    ///
    /// `nonisolated` because ``OrganizeRailMetrics`` measures this string off the main actor, and a
    /// `View`'s static members inherit `@MainActor`. Restating the rule in the model instead would
    /// let the measured and drawn text diverge.
    nonisolated static func badgeText(_ count: Int) -> String {
        guard count >= 1000 else { return count.formatted() }
        let thousands = Double(count) / 1000
        return thousands >= 10
            ? "\(Int(thousands.rounded(.down)))k"
            : String(format: "%.1fk", (thousands * 10).rounded(.down) / 10)
    }

    /// What VoiceOver reads for one rail item: its name, then what it has to say.
    ///
    /// Pure and static so the composition can be asserted without an assistive client: the suite
    /// has no accessibility tree to read back, so an assertion against the live view would pass
    /// whatever the label said.
    ///
    /// The count is spoken in full: `1.2k` is a width compromise the row makes, and a spoken label
    /// has no such constraint.
    nonisolated static func accessibilityLabel(title: String, state: RailItemState) -> String {
        switch state {
        case .reporting(let count):
            return "\(title), \(count.formatted())"
        case .clean:
            return "\(title), nothing found"
        case .notScanned:
            return "\(title), not scanned"
        case .configuration:
            // Rules, Storage and the overview item. None reports, so none has a state to announce,
            // and "nothing found" on Rules would be the claim the badge refuses to make.
            return title
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .scaledFont(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isSelected || isReporting ? accent : Color.secondary)
            if style == .full {
                Text(title)
                    .scaledFont(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .fixedSize()
            }
            switch state {
            case .reporting(let count):
                Text(Self.badgeText(count))
                    .scaledFont(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    .fixedSize()
                    // Frosted and Clear: the count drops into the item when a scan finds something,
                    // and melts out when it goes to zero, animated by the rail, which owns the row
                    // (`LensWorkspaceView.railCountsArrive`). Solid keeps plain `.opacity`.
                    .transition(lensMaterial == .today ? .opacity : SelectionLensArrival.transition)
            case .notScanned:
                // Not a zero, and not nothing either: a lens that never ran here is a different fact
                // from one that came back clean, and the row is the only place that shows without
                // opening the lens. The tooltip says it in words.
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 4, height: 4)
            case .clean, .configuration:
                EmptyView()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        // The state has to be spoken, because it is carried in colour: a reporting item differs
        // from a quiet one by its tint, and an unscanned one from a clean one by a 4pt dot, neither
        // of which reaches VoiceOver. Colour must never be a state's only carrier (as with the
        // scan-freshness pill, where `ScanFreshness` supplies a spoken form).
        .accessibilityLabel(Self.accessibilityLabel(title: title, state: state))
        // 0.14 is the `Pill` wash this row's other capsules use, so a reporting item reads as the
        // same kind of thing. The quiet rungs drop to a neutral fill of the same weight, keeping
        // the capsule (and so the control claim) while spending no colour on a lens with nothing to
        // say.
        //
        // The selected item's wash and ring are Solid's marker: in Frosted and Clear the rail's
        // selection lens carries them, and the item draws neither. Under a lens the selected wash
        // goes to 0 in the same branch rather than a branch of its own, so Solid's 0.22 ↔ 0.14 tween
        // on a change of selection stays one tween, not a cross-fade between two capsules.
        .background {
            if isReporting || isSelected {
                Capsule().fill(accent.opacity(isSelected ? (lensMaterial == .today ? Self.selectedWash : 0)
                                                         : 0.14))
            } else {
                Capsule().fill(Color.secondary.opacity(0.10))
            }
        }
        .overlay {
            if isSelected {
                SelectionLensTodayMarker { Capsule().strokeBorder(accent, lineWidth: Self.ringWidth) }
            }
        }
        .contentShape(Capsule())
    }
}

// MARK: - The scope chip

/// The one chip naming what Organize is answering about.
///
/// A view of its own rather than a `@ViewBuilder` inside `LensWorkspaceView`, so it can be rendered
/// and read back: `OrganizeScopeChipTests` asserts the label really says what it claims. A test
/// that only checks the band is inked can't see a label truncated to an identical stub.
///
/// It names the subtree and its folder count: "Legal" says which folder but not how much of the
/// tree that is, and the count is what makes a lens reporting zero read as a real answer rather
/// than a broken lens.
///
/// ## The suspended state
///
/// One lens deliberately doesn't apply the scope (see ``OrganizeLens/isScoped``), and the chip has
/// to say so rather than disappear: a vanished chip would read as "the scope was cleared", when it
/// is parked and comes back. So suspended draws the same words in secondary ink over a neutral
/// capsule, with no ✕: there is nothing to clear here, and a ✕ that threw away a scope this lens
/// isn't using would be a one-way trip.
struct ScopeChipLabel: View {
    let name: String
    /// Folders inside the scope, or nil when there is no profile to count against.
    let folderCount: Int?
    let accent: Color
    /// True when a scope is set and the lens on screen is not applying it.
    var isSuspended: Bool = false
    /// Clears the scope. nil withholds the ✕ entirely, which is what suspended passes. An optional
    /// rather than a `Bool` beside a closure, so the two can't disagree about whether the button is
    /// there.
    let onClear: (() -> Void)?

    /// The count's words, factored out so a test can assert the string without reading pixels for
    /// the parts that pixels are a poor instrument for.
    static func folderCountText(_ count: Int) -> String {
        "\(count) folder\(count == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "scope")
                .scaledFont(.system(size: 9.5, weight: .semibold))
            Text(name)
                .scaledFont(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if let folderCount {
                Text(Self.folderCountText(folderCount))
                    .scaledFont(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .scaledFont(.system(size: 8.5, weight: .bold))
                }
                .buttonStyle(.plain)
                .chromeHover()
                .help("Organize everything again")
                .accessibilityLabel("Clear scope")
            } else {
                // The suspension, said in the chip and not only the tooltip: a chip that merely went
                // grey would read as disabled chrome. "Paused" is the shortest word that says the
                // scope is standing rather than gone.
                Text("paused")
                    .scaledFont(.system(size: 9.5, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Scope paused on this lens")
            }
        }
        // Label colour when live: the accent is the wash, and a word in the accent on a wash of it
        // doesn't read.
        .foregroundStyle(isSuspended ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        // Neutral while suspended: the accent wash is what makes the chip read as live narrowing,
        // and keeping it under grey text would say two things at once.
        .background(Capsule().fill(isSuspended ? AnyShapeStyle(.quaternary)
                                               : AnyShapeStyle(accent.opacity(0.14))))
        // `fixedSize` so the chip keeps its natural width rather than being squeezed into an
        // ellipsis by its row: a truncated scope name is a scope claim you can't read, which is
        // worse than one that pushes the readout beside it.
        .fixedSize()
    }
}

// MARK: - The overview

/// What one lens has to say for the current scope.
///
/// Three states, and absence must never be ambiguous between clean and can't-run. A lens that has
/// never scanned says so and offers to; a lens that scanned and found nothing says that, quietly;
/// only a lens with findings takes a section.
enum OrganizeOverviewState: Equatable {
    /// Findings, with the headline number and up to ``OrganizeOverview/exampleLimit`` examples.
    /// Several, because one line under a count of 722 only proves the list is non-empty; three cost
    /// nothing in the empty column and tell you whether the duplicate is the video you meant to keep
    /// two copies of.
    ///
    /// ## `examples` holds identifiers, and a lens with nothing of the sort passes none
    ///
    /// The slot renders monospaced, because what belongs in it is filenames and paths
    /// (`Invoice.pdf → Finance`, `clip.mp4 — 2 copies`), where a fixed pitch lets you read a
    /// machine-generated name a character at a time. A summary is not that, and `prefix(3)` of an
    /// unsorted list is not a sample. Summaries go in the blurb, in the system font a sentence
    /// wants (To File's "31 ready, 11 unsure"). So the rule for this slot is: rows you could act on,
    /// or nothing. `noLensPutsProseInTheExampleSlot` is the guard.
    case findings(count: Int, headline: String, examples: [String])
    /// Ran, found nothing. Reported on the quiet trailing line rather than as a section.
    case clean
    /// Never ran here. Never rendered as a zero: a zero would be a claim this lens can't make.
    case notScanned
    /// An answer that is not a backlog: Storage's report, and the reason this case exists rather
    /// than Storage borrowing ``findings``.
    ///
    /// `findings` renders count-forward (a number in a pill, examples beneath, and a way in
    /// captioned with the count), which on Storage would read as a to-do, "Open Storage — 62 ›", for
    /// a lens with no verb that touches a file: the misread the badge rule exists to prevent.
    ///
    /// So a receipt: when it ran, over what, and what it found, rendered like `clean`'s quiet card
    /// with the numbers restored. `headline` is the standing fact ("214.6 GB"), `detail` the
    /// provenance ("Analyzed Tuesday · ~/Documents").
    ///
    /// Deliberately not counted by ``Ledger``: `countedLenses` gates on `carriesBadge`, which
    /// excludes this lens without a line of ledger code.
    case receipt(headline: String, detail: String)
}

/// One lens's contribution to the overview.
struct OrganizeOverviewSection: Identifiable {
    let lens: OrganizeLens
    let blurb: String
    let state: OrganizeOverviewState
    /// Whether this lens's answer is stale right now because the filing scan is republishing it.
    let isScanning: Bool

    var id: String { lens.rawValue }
}

/// Organize's landing: every lens's answer for the current scope, on one page.
///
/// This is the rail's unselected state, not a seventh rail item: a rail whose default landing is
/// one lens would leave the other five behind items you have to remember to visit. You land here,
/// so nothing has to be remembered, and clicking the selected rail item comes back.
///
/// Sections vanish at zero. What replaces a vanished section is a line on the quiet footer saying
/// the check ran, the difference between "clean" and "never looked".
struct OrganizeOverview: View {
    let sections: [OrganizeOverviewSection]
    let scopeLabel: String?
    let accent: Color
    /// The loose-files inbox offered as a visible scope shortcut, or nil when there is no inbox
    /// folder (or it is already the scope).
    ///
    /// Visible and clicked, never an automatic retarget: where the pane happens to sit must not
    /// decide the subject. The scope is sticky across launches, so it is clicked once.
    ///
    /// Not the default scope: scoped to `TODO`, Renames falls to 0 and five of the six lenses go
    /// dark on launch. The inbox is the right subject for To File and the wrong one for the rest.
    var inboxShortcut: InboxShortcut?

    /// The backlog nudge, when one is due: the sentence, the verb, and dismissal.
    ///
    /// Outside the ledger entirely. A check that can never run must not sit in the ratio's
    /// denominator, and a nudge is not a check at all: nothing scans to produce it and only the
    /// user's own filing closes it. So it is counted nowhere.
    var backlogNudge: BacklogNudge?

    struct BacklogNudge {
        /// The sentence, from `RestructureNudge.sentence(for:)`: derived, never composed here.
        let sentence: String
        /// Opens the Restructure lens on the first due finding, through the same resolver route
        /// the Organize menu's verbs use.
        let setUp: () -> Void
        /// Records the year for every due finding, so the same gap is quiet until the next one.
        let dismiss: () -> Void
    }

    struct InboxShortcut {
        /// The inbox's leaf name: "TODO" unless the setting was changed.
        let name: String
        /// Loose files sitting in it, or nil when the last scan didn't cover the inbox and the
        /// number is unknown.
        ///
        /// Optional because the count comes from one scan's published queue: scoped elsewhere, or
        /// before any scan, nothing in that list is under the inbox, and "0 loose files" while the
        /// inbox holds fifty would talk the user out of the very click this offers. Absent beats a
        /// wrong zero, as with the rail badges.
        let looseFileCount: Int?
        let apply: () -> Void
    }

    /// The cross-lens facts, and the one place on this screen they belong.
    ///
    /// Deliberately no total: 722 duplicate groups plus 1 structure finding is not "723 things",
    /// it is arithmetic over incompatible units. The overview rail item carries no badge for the
    /// same reason (`LensWorkspaceView.organizeOverviewRailItem`). What is here instead is three
    /// facts, each true on its own terms, that no single lens can state.
    struct Ledger: Equatable {
        /// Lenses that have run here, over lenses that can run at all (Rules excluded: it never
        /// scans). The one number that describes the screen rather than the tree.
        var checksRun = 0
        var checksTotal = 0
        /// Of `checksRun`, the lenses with findings. The meter tints this many segments accent; the
        /// rest of the run segments fill quiet, since clean is a completed check, not a blank.
        var checksReporting = 0
        /// Ran and found nothing.
        var checksClean: Int { checksRun - checksReporting }
        /// Reclaimable bytes, pre-formatted by the caller, or nil when Duplicates hasn't run or has
        /// nothing to reclaim.
        ///
        /// A string rather than an `Int` so this file stays free of `Sync`: `formatBytes` lives on
        /// `FileSyncManager`, and a presentation type shouldn't depend on the engine.
        var reclaimable: String?
        /// Folders inside the current scope, or nil when there is no profile to count against: the
        /// same honest-absence rule ``ScopeChipLabel`` follows.
        var scopeFolders: Int?

        /// Whether the strip has anything worth the row. On a first launch nothing has run and no
        /// profile exists, and a strip reading "0 of 5" over an empty pane is chrome.
        var isEmpty: Bool { checksRun == 0 && reclaimable == nil && scopeFolders == nil }

        /// The ledger for a set of sections.
        ///
        /// A static function rather than arithmetic inside `LensWorkspaceView`, so the two
        /// derivations that could go wrong can be asserted without mounting a view: a lens counts
        /// as run whenever it isn't `notScanned` (`clean` is a completed check, and counting only
        /// the reporting ones is the easy undercount), and the denominator is the lenses that can
        /// run at all.
        ///
        /// `reclaimable` and `scopeFolders` come in from the caller because both need `Sync`.
        ///
        /// `runnablePasses` narrows both halves of the ratio to the checks this host can run; see
        /// ``countedLenses(runnablePasses:)`` for why that differs from every badge-carrying lens.
        static func derived(from sections: [OrganizeOverviewSection],
                            runnablePasses: Set<OrganizePass>,
                            reclaimable: String?, scopeFolders: Int?) -> Self {
            let counted = countedLenses(runnablePasses: runnablePasses)
            return Self(
                checksRun: sections.filter {
                    counted.contains($0.lens) && $0.state != .notScanned
                }.count,
                checksTotal: counted.count,
                checksReporting: sections.filter {
                    guard counted.contains($0.lens) else { return false }
                    if case .findings = $0.state { return true } else { return false }
                }.count,
                reclaimable: reclaimable,
                scopeFolders: scopeFolders)
        }

        /// The checks tile's caption: the run's composition when something has run, the plain
        /// gloss before then. Absent parts rather than zeroes, the rule every badge follows.
        static func meterCaption(run: Int, reporting: Int, clean: Int) -> String {
            guard run > 0 else { return "checks have run" }
            let parts = [reporting > 0 ? "\(reporting) reporting" : nil,
                         clean > 0 ? "\(clean) clean" : nil].compactMap { $0 }
            return parts.isEmpty ? "checks have run" : parts.joined(separator: " · ")
        }

        /// The lenses the ratio is over: those that can report and whose pass this host can start.
        ///
        /// Two exclusions. Rules never scans, so a denominator of six would stick at "5 of 6" with
        /// every check complete. Restructure's pass is the folder survey: `resurveyFilingMemory`
        /// returns early without an existing profile, and `ContentView` withholds the handler in
        /// that state, so with no filing profile Restructure can never run and the ledger would read
        /// "4 of 5" forever. A ratio that can't be closed claims outstanding work against a button
        /// that doesn't exist.
        ///
        /// The same predicate governs whether the pass is offered a card at all, so the ledger, the
        /// cards and the footer can't disagree about which checks are real here.
        static func countedLenses(runnablePasses: Set<OrganizePass>) -> Set<OrganizeLens> {
            Set(OrganizeLens.allCases.filter { lens in
                guard lens.carriesBadge, let pass = OrganizePass(producing: lens) else {
                    return false
                }
                return runnablePasses.contains(pass)
            })
        }
    }

    var ledger = Ledger()

    /// The passes this host can actually start.
    ///
    /// Not every pass is always runnable, and that is expected: folder memory is driven by an
    /// optional handler (`LensWorkspaceView.onUpdateFolderMemory` is `(() -> Void)?`, and the
    /// CLI-driven and preview hosts pass nothing), so its card must explain the state without
    /// offering a button that would do nothing. A `Set` rather than a closure so a test can state
    /// the host's capabilities as a value.
    var runnablePasses: Set<OrganizePass> = Set(OrganizePass.allCases)

    let onOpen: (OrganizeLens) -> Void
    /// Starts a pass. It scans: a control captioned "Scan…" must never just navigate to a lens and
    /// leave you to find that lens's own scan button.
    let onRun: (OrganizePass) -> Void
    /// Runs Storage's analysis. Its own handler, not `onRun`: `onRun` takes an `OrganizePass`, and
    /// Storage is in no pass. Its report has a lifecycle of its own, restored across launches,
    /// which is why it isn't one of the checks the ledger counts. `rescanControl(for:)` mints its
    /// button from `OrganizePass(producing:)` and would have nothing to mint from here, so the
    /// receipt carries its own verb.
    ///
    /// Optional like `onUpdateFolderMemory`, for the same reason: a host that can't run it gets a
    /// card that says so rather than a button that no-ops.
    var onBuildStorage: (() -> Void)?
    /// Whether Storage's analysis is running right now. The card's verb is withheld while it is,
    /// gated exactly as the header's own button is.
    var isBuildingStorage: Bool = false

    /// The document survey's card, or nil where there is nothing to say about one.
    ///
    /// Nil on a machine with no folder profile, and nil once the corpus covers the tree: then the
    /// incremental *Refresh what’s learned* is the right pass and a click away, so offering three
    /// hours beside it would offer the worse of two answers.
    var documentSurvey: DocumentSurveyCardState?
    var onStartDocumentSurvey: (() -> Void)?
    /// The interrupted card's *Start over*: discards the progress on disk, then starts.
    var onStartDocumentSurveyOver: (() -> Void)?
    var onResumeDocumentSurvey: (() -> Void)?
    var onPauseDocumentSurvey: (() -> Void)?
    var onStopDocumentSurvey: (() -> Void)?
    /// Opens Help at the topic the privacy line points to.
    var onOpenSurveyHelp: (() -> Void)?
    /// The settled receipt's verb: the incremental re-survey.
    var onUpdateDocumentSurvey: (() -> Void)?

    private var reporting: [OrganizeOverviewSection] {
        sections.filter { if case .findings = $0.state { return true } else { return false } }
    }

    private var clean: [OrganizeOverviewSection] {
        sections.filter { $0.state == .clean }
    }

    /// The sections that are reports rather than backlogs: Storage today, and anything else that
    /// concludes something about the tree without proposing work.
    private var receipts: [OrganizeOverviewSection] {
        sections.filter { if case .receipt = $0.state { return true } else { return false } }
    }

    /// The passes offered a card: every lens they answer is `.notScanned`, and this host can start
    /// them.
    ///
    /// All of them, not any: a pass is offered only when running it would change every lens behind
    /// the offer. The file pass can't split today (one flag publishes its three), but the rule is
    /// right regardless: a card headed "hasn't run here" over a lens that has an answer would be
    /// false about the lens it names.
    ///
    /// And runnable: the folder-memory card appears when there is no profile, which is exactly when
    /// `ContentView` withholds `onUpdateFolderMemory` and `resurveyFilingMemory` returns early. A
    /// card offering a scan that can't run is worse than a quiet line, so such a lens falls back to
    /// ``strandedUnscanned``.
    var pendingPasses: [OrganizePass] {
        OrganizePass.allCases.filter { pass in
            guard runnablePasses.contains(pass) else { return false }
            let mine = sections.filter { pass.lenses.contains($0.lens) }
            return !mine.isEmpty && mine.allSatisfy { $0.state == .notScanned }
        }
    }

    /// Lenses that haven't run and whose pass is not on offer above, so the invitation is never
    /// dropped for a lens no pass card speaks for.
    ///
    /// Two ways in. A pass this host can't start (folder memory with no profile) is reported here
    /// as a quiet line instead of a dead card; and a pass that has answered some of its lenses but
    /// not all would strand the rest, which the flags can't produce today but the rule allows.
    var strandedUnscanned: [OrganizeOverviewSection] {
        let offered = Set(pendingPasses.flatMap(\.lenses))
        return sections.filter { $0.state == .notScanned && !offered.contains($0.lens) }
    }

    /// The one stranded lens that carries a pass's offer: the first in rail order, so which row
    /// holds the button is stable. Private, because counting rows that match a function returning
    /// one optional can only answer 0 or 1; ``offersPassRun(for:)`` is the seam, and it is the
    /// footer's own condition.
    private func firstStrandedLens(of pass: OrganizePass) -> OrganizeLens? {
        strandedUnscanned.first { pass.lenses.contains($0.lens) }?.lens
    }

    /// Whether this footer row draws the run button for its pass: the predicate the footer itself
    /// branches on, not a restatement of it. The rule and the thing under test have to be one
    /// expression, or a test can stay green with the dedupe deleted from the view (as with
    /// ``offersRescan(for:)``).
    func offersPassRun(for section: OrganizeOverviewSection) -> Bool {
        guard section.state == .notScanned,
              let pass = OrganizePass(producing: section.lens),
              runnablePasses.contains(pass) else { return false }
        return firstStrandedLens(of: pass) == section.lens
    }

    /// Whether a row that has already answered offers to re-run the scan behind it.
    ///
    /// Extracted from the view so the rule can be asserted directly rather than inferred from
    /// pixels, and because pixels can't express the property that matters most: the answer does
    /// not move with the data. See ``OrganizePass/answersOneLens``.
    func offersRescan(for section: OrganizeOverviewSection) -> Bool {
        guard case .findings = section.state, !section.isScanning,
              let pass = OrganizePass(producing: section.lens) else { return false }
        return pass.answersOneLens && runnablePasses.contains(pass)
    }

    /// How many examples a finding row draws. Three fits the room: the row's other tenants are two
    /// 14pt lines and a button, and the pane is a full window column.
    static let exampleLimit = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !ledger.isEmpty { ledgerStrip }
                // Only if it has nowhere better to go; see ``nudgeHost``. A due nudge names one of
                // Restructure's own findings, so it rides that card; this is the fallback that keeps
                // it from vanishing if it ever can't.
                if let backlogNudge, nudgeHost == nil { nudgeLine(backlogNudge) }
                ForEach(reporting) { section in
                    sectionView(section)
                }
                ForEach(pendingPasses) { pass in
                    passCard(pass)
                }
                // A lens no pass speaks for, in the state it spends most of its life in (Storage
                // before its first analysis): a card on the same rung as the pass offers, because it
                // is the same kind of thing, a check that hasn't run and can be run from here.
                ForEach(strandedCards) { section in
                    strandedCard(section)
                }
                // `documentSurvey` counts here too: an "everything is clear" panel above a card
                // offering three hours of reading would contradict itself.
                if reporting.isEmpty && pendingPasses.isEmpty && receipts.isEmpty
                    && strandedCards.isEmpty && documentSurvey == nil {
                    allClearState
                }
                // The survey card sits above the receipts and below the offers: while offered or
                // running it is closer to work than to an answer, and when finished it is a receipt
                // like Storage's. One position through every state, so the feature doesn't look
                // like three.
                //
                // Receipts come after the findings and the offers, before the footer: a receipt is
                // not work, so it mustn't sit above things that are, and it is not nothing, so it
                // doesn't belong on the quiet trailing line with the clean checks.
                if let documentSurvey {
                    DocumentSurveyCard(state: documentSurvey, accent: accent,
                                       onStart: onStartDocumentSurvey,
                                       onStartOver: onStartDocumentSurveyOver,
                                       onResume: onResumeDocumentSurvey,
                                       onPause: onPauseDocumentSurvey,
                                       onStop: onStopDocumentSurvey,
                                       onOpenHelp: onOpenSurveyHelp,
                                       onUpdate: onUpdateDocumentSurvey)
                }
                ForEach(receipts) { section in
                    receiptCard(section)
                }
                if let inboxShortcut { inboxOffer(inboxShortcut) }
                if !strandedLines.isEmpty || !clean.isEmpty {
                    footer
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: The backlog nudge

    /// The reporting card a due nudge belongs to, or nil when there is none to attach it to.
    ///
    /// The nudge is a callout of one of Restructure's rows, not a sibling of its card:
    /// `LensWorkspaceView.backlogNudge()` derives it from `scopedStructureFindings`, and the
    /// overview's Restructure section counts the same findings through the same `.inside` scope
    /// filter, so the folder the sentence names is one the pill above it counts. Drawn as a card of
    /// its own it reads as a second, headless subject.
    ///
    /// The nil case is a real fallback. The two derivations agree today (same list, same scope,
    /// same filter, and `due` is a subset of the findings), so this can't be nil while a nudge is
    /// due. If that ever stops being true, the fallback keeps a time-sensitive line from
    /// disappearing silently; ``theNudgeSurvivesLosingItsHost`` is the test.
    var nudgeHost: OrganizeOverviewSection? {
        guard backlogNudge != nil else { return nil }
        return reporting.first { $0.lens == .restructure }
    }

    /// The nudge outside the lens, said the month it happens: one sentence, its verb, and a way to
    /// make it go away until next year.
    ///
    /// A card whose verb is a button, like every other verb on the page. It is still not a check
    /// (nothing scans to produce it, and the ledger counts it nowhere), and with no lede under it
    /// its sentence is set as a sentence rather than as a heading.
    private func nudgeLine(_ nudge: BacklogNudge) -> some View {
        OverviewCard(
            symbol: "calendar.badge.plus",
            title: nudge.sentence,
            accent: accent,
            // The card's only verb, so it is the primary: the same rule the survey's lone Refresh
            // follows, which puts it on the same vertical line as every other one.
            actions: [OverviewCardAction(title: Self.nudgeVerbTitle, rank: .primary,
                                         help: Self.nudgeVerbHelp, run: nudge.setUp)],
            dismiss: Self.nudgeDismissal(nudge)) { }
    }

    /// The nudge's verb and its tooltip, in one place because the nudge has two renderings (the row
    /// inside its host card and the standalone fallback card), which must offer the same action
    /// under the same words.
    static let nudgeVerbTitle = "Set Up…"
    static let nudgeVerbHelp = "Opens Restructure on the first folder with this gap."

    static func nudgeDismissal(_ nudge: BacklogNudge) -> OverviewCardDismiss {
        OverviewCardDismiss(
            accessibilityLabel: "Dismiss this reminder until next year",
            help: "Dismisses it for this year. The same folders raise it again when a new year "
                + "arrives with the same gap.",
            run: nudge.dismiss)
    }

    /// The nudge riding its host card, in the same row shape the pass card gives its lenses.
    ///
    /// An accent bracket down the leading edge is how this page says "this belongs to the card
    /// above it", so the callout doesn't become a surface of its own. The verbs sit at the row's
    /// trailing edge, which, with the content slot inset on the leading side only, is the card's
    /// trailing padding, so `Set up…` lands on the same vertical line as the primary above it.
    ///
    /// Secondary, not primary: `Open Restructure` is this card's main verb, and two filled buttons
    /// on one card would break the page's one-primary rule.
    private func nudgeRow(_ nudge: BacklogNudge) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(accent.opacity(0.35))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            Image(systemName: "calendar.badge.plus")
                .scaledFont(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            Text(nudge.sentence)
                .scaledFont(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // The × ahead of the verb, for the reason ``OverviewCard`` gives at the header: after
            // it, `Set up…` would sit about 17pt inboard of the `Open Restructure` above.
            // `everyCardsPrimaryEndsOnTheSameLine` measures this row as a second band in the same
            // gutter.
            let dismissal = Self.nudgeDismissal(nudge)
            Button(action: dismissal.run) {
                Image(systemName: "xmark").scaledFont(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel(dismissal.accessibilityLabel)
            .help(dismissal.help)
            .chromeHover()
            .padding(.trailing, 4)
            // `.bordered`, where the standalone card's verb is `.borderedProminent`: inside a card
            // the main verb is `Open Restructure`, and a second filled button would break the
            // one-primary rule.
            Button(Self.nudgeVerbTitle, action: nudge.setUp)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .chromeHover()
                .fixedSize()
                .help(Self.nudgeVerbHelp)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    // MARK: The ledger

    /// The ledger as tiles: each fact its own quiet card, sized to its content.
    ///
    /// One builder and one height for all three: the meter is a slot inside the shared tile, and
    /// every tile is stretched to the tallest, so the only thing that varies between them is the
    /// width their content asks for and the bottom edges agree.
    private var ledgerStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            checksTile
            if let reclaimable = ledger.reclaimable {
                ledgerTile(value: Text(reclaimable)
                    .scaledFont(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent),
                           caption: "reclaimable",
                           label: "\(reclaimable) reclaimable") { EmptyView() }
            }
            if let folders = ledger.scopeFolders {
                let caption = folders == 1 ? "folder in scope" : "folders in scope"
                ledgerTile(value: Text(folders.formatted())
                    .scaledFont(.system(size: 17, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary),
                           caption: caption,
                           label: "\(folders.formatted()) \(caption)") { EmptyView() }
            }
            Spacer(minLength: 0)
        }
    }

    /// Meter segment geometry: shared with nothing, named so the render test can reason in it.
    static let meterSegmentSize = CGSize(width: 16, height: 4)

    /// The floor every ledger tile is stretched to.
    ///
    /// A floor rather than a fixed height, so a text-size change still grows them, and a floor at
    /// all so tiles whose contents differ in height still read as one row of cards. **Don't lower
    /// it below 60** without re-reading `theNudgeDoesNotTouchTheChecksLedger`, which asserts on the
    /// top 74pt of the render and needs the nudge to stay out of that band.
    static let ledgerTileMinHeight: CGFloat = 62

    /// One ledger tile: a value, an optional meter, a caption. Every tile on the strip is this.
    private func ledgerTile<Meter: View>(value: some View, caption: String, label: String,
                                         @ViewBuilder meter: () -> Meter) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            value
            meter()
            Spacer(minLength: 4)
            Text(caption)
                .scaledFont(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: Self.ledgerTileMinHeight, maxHeight: .infinity, alignment: .topLeading)
        .lensCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var checksTile: some View {
        let caption = Ledger.meterCaption(run: ledger.checksRun,
                                          reporting: ledger.checksReporting,
                                          clean: ledger.checksClean)
        return ledgerTile(
            value: (Text("\(ledger.checksRun) ").fontWeight(.bold)
                    + Text("of \(ledger.checksTotal)").foregroundStyle(.secondary))
                .scaledFont(.system(size: 17))
                .monospacedDigit(),
            caption: caption,
            label: "\(ledger.checksRun) of \(ledger.checksTotal) checks have run, \(caption)") {
            HStack(spacing: 3) {
                ForEach(0..<max(ledger.checksTotal, 0), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(meterColor(for: index))
                        .frame(width: Self.meterSegmentSize.width,
                               height: Self.meterSegmentSize.height)
                }
            }
            .padding(.top, 6)
            .accessibilityHidden(true)   // the caption + value say everything the meter draws
        }
    }

    /// Segment ink by position: reporting first, then clean, then not-run. The order carries no
    /// per-lens identity (a fraction, not a map): accent for "wants you", a quiet fill for "ran,
    /// nothing", near-ground for "never looked".
    private func meterColor(for index: Int) -> Color {
        if index < ledger.checksReporting { return accent }
        if index < ledger.checksRun { return Color.primary.opacity(0.30) }
        return Color.primary.opacity(0.10)
    }

    /// The offer's second line: the count when it is known, and the invitation alone when it is not.
    ///
    /// A value rather than a ternary in the body so the string can be pinned without rendering:
    /// an unknown count must never read as zero.
    static func inboxSubtitle(_ looseFileCount: Int?) -> String {
        guard let n = looseFileCount else { return "Organize just this folder" }
        return n == 1
            ? "1 loose file — organize just this folder"
            : "\(n) loose files — organize just this folder"
    }

    /// The inbox as a place to point Organize at, one press.
    ///
    /// After the findings and before the quiet footer: it is an offer about where to look next,
    /// not a finding, and above the sections it would give the inbox the prominence of a default.
    ///
    /// Offered the way the rest of the page makes offers: read the card, press the button. Not a
    /// check either (it names no lens and has no answer), but it has a name and a line under it,
    /// so it heads them the way the cards do.
    private func inboxOffer(_ shortcut: InboxShortcut) -> some View {
        OverviewCard(
            symbol: "tray",
            title: "Inbox (\(shortcut.name))",
            subtitle: Self.inboxSubtitle(shortcut.looseFileCount),
            accent: accent,
            actions: [OverviewCardAction(
                title: "Point Organize Here", rank: .primary,
                help: "Point Organize at the inbox. Every lens narrows to it, and it stays until "
                    + "you change it.",
                run: shortcut.apply)],
            accessibilityLabel: "Inbox \(shortcut.name), "
                + Self.inboxSubtitle(shortcut.looseFileCount)) { }
    }

    // MARK: A lens with findings

    @ViewBuilder
    private func sectionView(_ section: OrganizeOverviewSection) -> some View {
        if case .findings(let count, let headline, let examples) = section.state {
            findingsSection(section, count: count, headline: headline, examples: examples)
        }
    }

    /// The unit run of a "\(count) unit" headline ("folders" of "79 folders"), or nil when the
    /// headline doesn't lead with this count, in which case the pill draws the whole string. Every
    /// current headline leads with its count; the fallback keeps a future one from rendering
    /// "79 79 folders".
    nonisolated static func headlineUnit(count: Int, headline: String) -> String? {
        let prefix = "\(count) "
        guard headline.hasPrefix(prefix) else { return nil }
        return String(headline.dropFirst(prefix.count))
    }

    /// One reporting lens: what it is, how much of it there is, what it looks like, and the way in.
    ///
    /// No accent wash and no leading stripe: they would make one card in six look like it came
    /// from a different app, to carry a signal the accent glyph tile and the accent count pill
    /// already carry. A finding differs from an offer the way it does on the rail: ink on the glyph
    /// and a number in a pill.
    ///
    /// The verbs sit in the heading, beside every other card's verbs, so the same word (Refresh)
    /// lands in the same place on every card.
    private func findingsSection(_ section: OrganizeOverviewSection, count: Int,
                                 headline: String, examples: [String]) -> some View {
        OverviewCard(
            symbol: section.lens.symbol,
            title: section.lens.title,
            subtitle: section.blurb,
            tone: .reporting,
            accent: accent,
            // The number below is last scan's while a rescan is in flight, and its own lens's
            // readout is suppressed for the same reason (`OrganizeLens.goesStaleDuringFilingScan`).
            // Saying so beats redrawing a stale figure in confident bold.
            status: section.isScanning
                ? .working("rescanning")
                : Self.headlineUnit(count: count, headline: headline)
                    .map { .count(count, unit: $0) } ?? .text(headline),
            actions: actions(for: section),
            // The small print prices the verb, and a card with no priced verb has none. "Free — and
            // the slow one" sits under a pass card whose button hashes every file in scope; a
            // findings card that offers a Refresh makes the same kind of ask, so it says the same
            // kind of thing. One that offers only a way in asks for nothing and stops at the
            // heading.
            note: findingsNote(section),
            accessibilityLabel: "\(section.lens.title), \(headline)") {
            // The whole slot is conditional: an empty `VStack` is still a view, and `OverviewCard`
            // would give it the 7pt heading spacing, adding dead air to the bottom of every card
            // with nothing to put here (60pt against 53pt), so card heights would disagree.
            let nudged = backlogNudge != nil && nudgeHost?.lens == section.lens
            if nudged || !examples.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    // Above the examples, because it is the one finding here with a clock on it: the
                    // examples are a sample of the backlog, this row stops being actionable when the
                    // year turns.
                    if let backlogNudge, nudged {
                        nudgeRow(backlogNudge)
                    }
                    if !examples.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(examples.prefix(Self.exampleLimit), id: \.self) { example in
                                Text(example)
                                    .scaledFont(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Every verb a lens's card offers, in whatever state it is in: the one place the answer lives.
    ///
    /// A dispatcher rather than a builder per card body, because the rules worth asserting are
    /// across the states: at most one primary per card, and a stranded lens gets a card exactly
    /// when this returns something. A rule read off three call sites is one the next state forgets.
    ///
    /// While the work behind a card is running, the verb that starts that work is withdrawn and the
    /// verb that opens the lens stays. So a duplicate rescan (minutes of hashing) keeps `Open
    /// Duplicates` on screen, since you may want to read the answer while it is recomputed, and
    /// Storage's receipt swaps `Rescan` for a spinner like every other card rather than showing it
    /// disabled. The render tests that watch a scanning row can't catch a break here: any large
    /// change to the row satisfies them.
    func actions(for section: OrganizeOverviewSection) -> [OverviewCardAction] {
        switch section.state {
        case .findings(let count, _, _):
            // `findingsActions` withdraws only the rescan, through `offersRescan`, which already
            // asks `!isScanning`. The way in is not gated on anything.
            return findingsActions(section, count: count)
        case .receipt:
            return receiptActions(section)
        case .notScanned:
            // The run verb is the only verb here, so a scan in flight leaves nothing; the card
            // still draws, with its spinner. See ``canRunFromHere(_:)`` for why the partition
            // between a card and a footer line does not ask this question.
            return section.isScanning ? [] : strandedActions(section)
        case .clean:
            // A clean lens takes no card at all: it is one entry on the footer's quiet line.
            return []
        }
    }

    /// What re-asking costs, where this card offers to re-ask at all.
    ///
    /// Keyed on the static rule, not on `offersRescan`, which also asks whether a scan is in
    /// flight: a note that came and went with that would change the card's height mid-scan.
    /// ``OrganizePass/answersOneLens`` keeps this control from moving with the data, and its price
    /// tag has to hold still for the same reason.
    func findingsNote(_ section: OrganizeOverviewSection) -> OverviewCardNote? {
        guard let pass = OrganizePass(producing: section.lens),
              pass.answersOneLens, runnablePasses.contains(pass) else { return nil }
        return OverviewCardNote(pass.offerCost)
    }

    /// A finding's verbs: the way in, and, where the pass answers this lens alone, the way to ask
    /// again.
    ///
    /// The way in is the primary, because a card that has found something is a card whose point is
    /// that you go and look. Its title doesn't repeat the count: the pill already says it, and a
    /// count in the title would make the button's width move with the data.
    private func findingsActions(_ section: OrganizeOverviewSection, count: Int)
    -> [OverviewCardAction] {
        var actions = [OverviewCardAction(title: "Open \(section.lens.title)", rank: .primary,
                                          help: "Review what \(section.lens.title) found",
                                          accessibilityLabel: "Open \(section.lens.title), \(count) found",
                                          run: { onOpen(section.lens) })]
        if offersRescan(for: section), let pass = OrganizePass(producing: section.lens) {
            actions.append(OverviewCardAction(
                title: pass.rescanTitle,
                help: pass.offerCost,
                accessibilityLabel: pass.rescanAccessibilityLabel(for: section.lens),
                run: { onRun(pass) }))
        }
        return actions
    }

    // MARK: A lens with a report

    /// Storage's card: a receipt, not a to-do.
    ///
    /// No accent and no count pill: both are how this screen says "here is work", and a receipt
    /// that borrowed them would promise a backlog for a lens with no verb that touches a file, the
    /// misread the badge rule refuses on the rail. It is a card like every other, and quiet like
    /// every card that isn't reporting.
    ///
    /// The provenance goes under the rule, where the pass cards put their cost: "Analyzed Tuesday ·
    /// ~/Documents" is what a stale report most needs to say about itself, and it is small print
    /// rather than a headline.
    @ViewBuilder
    private func receiptCard(_ section: OrganizeOverviewSection) -> some View {
        if case .receipt(let headline, let detail) = section.state {
            OverviewCard(
                symbol: section.lens.symbol,
                title: section.lens.title,
                subtitle: headline,
                accent: accent,
                // The numbers above are the last analysis's while a new one runs, as a findings
                // card's count is, so it says so the same way rather than leaving a live-looking
                // headline over a report being rebuilt.
                status: section.isScanning ? .working("Analyzing…") : .none,
                actions: actions(for: section),
                note: OverviewCardNote(detail, symbol: "clock"),
                accessibilityLabel: "\(section.lens.title), \(detail), \(headline)") { }
        }
    }

    private func receiptActions(_ section: OrganizeOverviewSection) -> [OverviewCardAction] {
        // "Open Storage" without a count: a count belongs on a backlog you work through, and here
        // it would put the number where the badge rule keeps it out. Not withdrawn while the
        // analysis re-runs: reading the last report is what somebody waiting for the next wants.
        var actions = [OverviewCardAction(title: "Open \(section.lens.title)", rank: .primary,
                                          help: "Read the full \(section.lens.title) report",
                                          run: { onOpen(section.lens) })]
        // Withdrawn while it runs rather than drawn disabled: the spinner above already says the
        // work is in flight. The same swap the pass cards make.
        if section.lens == .storage, let onBuildStorage, !section.isScanning {
            // "Rescan", the word the Storage lens's own control carries (see its freshness
            // pill's tooltip), and the word the pass cards use for the same act.
            actions.append(OverviewCardAction(title: "Rescan",
                                              help: "Walks the tree again and rebuilds the report.",
                                              accessibilityLabel: "Rescan \(section.lens.title)",
                                              run: onBuildStorage))
        }
        return actions
    }

    // MARK: A pass that has not run

    /// The offer to run one scan.
    ///
    /// Its button scans; it doesn't just navigate to a lens and leave you at that lens's own scan
    /// button. The card names the pass, because the machinery has one walk where there may be
    /// several lenses, and lists the lenses it answers underneath as consequence rather than as
    /// options.
    @ViewBuilder
    private func passCard(_ pass: OrganizePass) -> some View {
        let isRunning = sections.contains { pass.lenses.contains($0.lens) && $0.isScanning }
        OverviewCard(
            symbol: pass.symbol,
            title: pass.offerTitle,
            subtitle: pass.offerLede,
            accent: accent,
            status: isRunning ? .working("Running…") : .none,
            actions: isRunning || !runnablePasses.contains(pass)
                ? []
                : [OverviewCardAction(title: pass.runTitle, rank: .primary, help: pass.offerCost,
                                      run: { onRun(pass) })],
            note: OverviewCardNote(pass.offerCost)) {
            // The lenses this one click answers. Drawn only when there is more than one, because
            // for a single-lens pass the row would restate the heading directly above it.
            if pass.lenses.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pass.lenses, id: \.self) { lens in
                        passLensRow(lens)
                    }
                }
            }
        }
    }

    /// One lens inside a pass card: what this share of the one walk gets you.
    ///
    /// The accent bracket on the leading edge says "these come together" without a sentence, and
    /// there is deliberately no button here: two buttons starting the identical pass would offer
    /// two choices where there is one.
    @ViewBuilder
    private func passLensRow(_ lens: OrganizeLens) -> some View {
        let blurb = sections.first { $0.lens == lens }?.blurb
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(accent.opacity(0.35))
                .frame(width: 2)
                .accessibilityHidden(true)
            PassLensGlyph(symbol: lens.symbol)
            VStack(alignment: .leading, spacing: 0) {
                Text(lens.title)
                    .scaledFont(.system(size: 11.5, weight: .semibold))
                if let blurb {
                    Text(blurb)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: A lens no pass speaks for

    /// The lenses that get a card before they have ever run, though no pass speaks for them:
    /// Storage, never analyzed, the state it spends most of its life in. It is a lens with a verb
    /// and a real answer to give, so it gets a card like every other lens in every state, not a
    /// footer footnote.
    ///
    /// Storage is in no ``OrganizePass``, so `pendingPasses` can't offer it a card and it lands in
    /// ``strandedUnscanned``. A stranded lens with a verb gets a card; one without stays a quiet
    /// line, since a card offering a scan this host can't start is worse than a line saying it
    /// hasn't run.
    var strandedCards: [OrganizeOverviewSection] {
        strandedUnscanned.filter(canRunFromHere)
    }

    /// Stranded lenses with nothing to offer: the quiet line.
    var strandedLines: [OrganizeOverviewSection] {
        strandedUnscanned.filter { !canRunFromHere($0) }
    }

    /// Whether a never-run lens has a verb on this screen at all: a fact about the host, not about
    /// this moment.
    ///
    /// Deliberately not "does it have actions right now": `actions(for:)` withdraws the run verb
    /// while the work is in flight, so pressing Analyze would demote the card to a footnote for the
    /// whole run. The standing fact decides the shape; the moment decides the buttons.
    private func canRunFromHere(_ section: OrganizeOverviewSection) -> Bool {
        if offersPassRun(for: section) { return true }
        return section.lens == .storage && onBuildStorage != nil
    }

    /// The verb a never-run lens can offer from here, if any.
    ///
    /// Two sources, mutually exclusive by construction: a pass this host can start
    /// (`offersPassRun` already de-dupes it to one row per pass), or, for the one lens in no pass,
    /// Storage's own analyzer.
    private func strandedActions(_ section: OrganizeOverviewSection) -> [OverviewCardAction] {
        if offersPassRun(for: section), let pass = OrganizePass(producing: section.lens) {
            return [OverviewCardAction(title: pass.runTitle, rank: .primary, help: pass.offerCost,
                                       run: { onRun(pass) })]
        }
        // No `Analyzing…` arm: `actions(for:)` withdraws every verb here while the work runs, so a
        // disabled button captioned with its own progress could never draw.
        if section.lens == .storage, let onBuildStorage {
            return [OverviewCardAction(title: "Analyze", rank: .primary,
                                       help: "Walks the tree and reports where the space goes.",
                                       run: onBuildStorage)]
        }
        return []
    }

    /// The small print under a stranded lens's card: what its scan costs, where a pass can price
    /// it, and what Storage's analysis is and is not where no pass can.
    private func strandedNote(_ section: OrganizeOverviewSection) -> OverviewCardNote? {
        if let pass = OrganizePass(producing: section.lens), runnablePasses.contains(pass) {
            return OverviewCardNote(pass.offerCost)
        }
        if section.lens == .storage {
            // The badge rule's sentence, said where somebody deciding whether to press is standing.
            return OverviewCardNote("Free, and on-device. A report — it never moves, deletes or "
                                    + "evicts a file.")
        }
        return nil
    }

    /// The heading over a check that hasn't run and has no pass card to say so.
    ///
    /// It names what didn't happen, in that check's own verb: Storage doesn't walk the tree, it
    /// analyses, and its button says Analyze. A heading and a button disagreeing about the verb
    /// teach the wrong word for what somebody is about to do.
    ///
    /// It is about the lens, never the pass's `offerTitle`. A lens reaches this card only when its
    /// pass has answered some of its other lenses and not this one, so "The file pass hasn’t run
    /// here" would contradict the answer a card above it. Unreachable today, since the one
    /// multi-lens pass publishes all its lenses from a single flag, but the sentence must be true
    /// whenever the branch runs.
    static func strandedTitle(_ lens: OrganizeLens) -> String {
        lens == .storage ? "Storage hasn’t been analyzed here" : "\(lens.title) hasn’t run here"
    }

    @ViewBuilder
    private func strandedCard(_ section: OrganizeOverviewSection) -> some View {
        OverviewCard(
            symbol: section.lens.symbol,
            title: Self.strandedTitle(section.lens),
            subtitle: section.blurb,
            accent: accent,
            status: section.isScanning ? .working("Running…") : .none,
            actions: actions(for: section),
            note: strandedNote(section),
            accessibilityLabel: "\(section.lens.title), not scanned here") { }
    }

    /// Everything reporting is empty and there is nothing left to run. Distinct from "nothing has
    /// run", which draws pass cards instead, so this is gated on both.
    private var allClearState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scopeLabel.map { "Nothing to do in \($0)." } ?? "Nothing to do here.")
                .scaledFont(.system(size: 12.5, weight: .semibold))
            Text("Every check that has run came back clean.")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// The quiet line: what ran and was clean, and any lens left unscanned that has no verb to
    /// offer from here, the two things on this screen that are genuinely footnotes. Text only: a
    /// lens with a button gets a card (``strandedCard(_:)``).
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            if !clean.isEmpty {
                // A tiny checkmark before each entry says "ran and clean" pre-attentively.
                // A tiny checkmark before each entry says "ran and clean" pre-attentively.
                // Tertiary like the words, deliberately not success-green: clean is quiet, so a
                // zero is never drawn, and neither is a celebration. FlowLayout, not an HStack:
                // five entries at extra-large text overrun a 600pt-floor window, and a row that
                // can't wrap clips its last claims.
                FlowLayout(spacing: 10, lineSpacing: 3) {
                    ForEach(clean) { section in
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle")
                                .scaledFont(.system(size: 9))
                            Text("\(section.lens.title.lowercased()) checked")
                                .scaledFont(.system(size: 11))
                        }
                        .fixedSize()
                    }
                }
                .foregroundStyle(.tertiary)
            }
            ForEach(strandedLines) { section in
                Text("\(section.lens.title) — not scanned")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Pass lens glyph

/// One lens's symbol in the column that keeps a pass card's rows aligned.
///
/// The column keeps titles aligned: ``OrganizeLens/symbol`` draws six shapes at six widths (`doc`
/// is narrow, `folder.badge.gearshape` is not), and without a frame the titles beside them would
/// start at different x positions, turning one bracketed group into a ragged edge. The same
/// argument ``CapsuleGlyph`` makes.
///
/// The width must scale with the text size. `.frame` doesn't clip, so a fixed 14pt column lets
/// the widest symbol draw 3–4pt past it at Large and Largest, into the 8pt gap it shares with the
/// title; Small and Default look fine, which hides it. Scaling through
/// ``Design/FontSize/scaledBox(_:basePoint:scale:)`` cuts the worst overhang to about 1.5pt and
/// keeps Default at exactly 14. Closing it fully would want ``boxSize`` at 17, moving every pass
/// card's titles 3pt at every text size to buy 1.5pt at one.
struct PassLensGlyph: View {

    let symbol: String

    @Environment(\.appFontScale) private var scale

    /// The glyph's own point size at the default text size.
    static let pointSize: CGFloat = 10
    /// The column drawn around it at the default text size.
    static let boxSize: CGFloat = 14

    /// The column at `scale`, in the same proportion to the glyph as `boxSize` is to `pointSize`.
    static func box(at scale: CGFloat) -> CGFloat {
        FontSize.scaledBox(boxSize, basePoint: pointSize, scale: scale)
    }

    var body: some View {
        Image(systemName: symbol)
            .scaledFont(.system(size: Self.pointSize, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: Self.box(at: scale))
    }
}
