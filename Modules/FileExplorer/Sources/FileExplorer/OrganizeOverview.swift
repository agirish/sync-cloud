import SwiftUI
import Design

// MARK: - The rail item

/// What a rail item has to say about its lens, and therefore how it is dressed.
///
/// **The same three states ``OrganizeOverviewState`` models, deliberately.** The overview is
/// careful never to conflate *ran and found nothing* with *never looked* — a zero would be a claim
/// a lens that has not scanned cannot make — and the rail used to throw that distinction away,
/// drawing both as an item with no badge. Two surfaces describing one set of facts had two
/// vocabularies; now they have one, and `LensWorkspaceView` derives both from the same counts.
enum RailItemState: Equatable {
    /// This lens has findings here. The count is the whole scoped list, never the filtered view.
    case reporting(Int)
    /// It ran and found nothing. Says so by going quiet, not by drawing a `0`.
    case clean
    /// It has not run here at all. Never a zero — that would be a claim it cannot support.
    case notScanned
    /// **Not a finding at all** — neither `clean` nor `notScanned`, because those both describe a
    /// scan whose answer was a count.
    ///
    /// Two lenses wear it, and the name is the older of the two: Rules is configuration you keep,
    /// which never reports and never goes quiet. Storage joined it at the fold — its analyzer does
    /// run, but what it produces is a report with no verb, so a badge would promise work and a
    /// "nothing here" would be false. The shared meaning is **this item has no count that means
    /// something needs you**, which is exactly what `OrganizeLens.carriesBadge` decides.
    case configuration
}

/// One item on Organize's lens rail: glyph, name, and a badge **only when there is something to
/// report**.
///
/// The two halves of the chips' argument are split here on purpose. The *place* is unconditional —
/// it is what pointed invocation ("Organize this folder") lands on, and what a badge cannot be
/// because a badge does not exist before a scan. The *claim* is conditional: nothing to report
/// draws no number at all, not a greyed one and not a `0`.
///
/// **It wears a capsule because a capsule is a control.** That rule came out of this very row: it
/// once carried six tinted capsules of which only three were buttons, and the only way to learn
/// which half was live was to click. Every rail item IS a button, so dropping the capsule on the
/// quiet ones would recreate that ambiguity from the other side, with live controls dressed as
/// prose.
///
/// ## The tint says "has work", not "is clickable"
///
/// Every item used to wear the same `accent.opacity(0.14)` whether it had found 722 things or
/// nothing at all, so the only signal was a small badge at the item's tail and the row read as six
/// identical capsules. The capsule still carries the control claim; the *wash* now carries the
/// finding. A reporting item is accent-tinted with an accent glyph; a quiet one takes a neutral
/// wash and a secondary glyph. Both are plainly buttons, and which two of the six want you is
/// legible before you read a single number.
struct RailItemLabel: View {
    let title: String
    let systemImage: String
    let state: RailItemState
    let isSelected: Bool
    let accent: Color
    /// Whether the row can afford this item's label — see ``OrganizeRailMetrics``. At `.iconOnly`
    /// the name survives in the tooltip and the accessibility label, exactly as the workspace
    /// bar's segments do when they shed.
    var style: OrganizeRailStyle = .full

    /// Findings — the one state that colours the item.
    private var isReporting: Bool {
        if case .reporting = state { return true }
        return false
    }

    /// The badge's digits, abbreviated past three of them.
    ///
    /// `count.formatted()` puts the separator in, so the rename backlog's badge reads `1,192` and
    /// measures 40.9pt against 16.8 for a single digit. The rail is widest on the day every finding
    /// reports, which is the day it most needs to fit — and a four-digit badge also shouts over a
    /// `3` on Names that may matter far more, because a badge encodes list size and never urgency.
    /// Abbreviating buys back 7.5pt, which is small; the reason to do it is the shouting. The exact
    /// figure stays in the tooltip and in row 2's readout.
    /// `nonisolated` because ``OrganizeRailMetrics`` measures this string, and that model is a pure
    /// type the width arithmetic calls off the main actor. A `View`'s static members inherit
    /// `@MainActor`, so without this the one caller that must agree with the drawn text cannot
    /// reach it — and the tempting fix, restating the rule in the model, is exactly the divergence
    /// this whole type exists to prevent.
    nonisolated static func badgeText(_ count: Int) -> String {
        guard count >= 1000 else { return count.formatted() }
        let thousands = Double(count) / 1000
        return thousands >= 10
            ? "\(Int(thousands.rounded(.down)))k"
            : String(format: "%.1fk", (thousands * 10).rounded(.down) / 10)
    }

    /// What VoiceOver reads for one rail item: its name, then what it has to say.
    ///
    /// Pure and static so the composition can be asserted without an assistive client attached —
    /// this suite has no accessibility tree to read back, so a caption assertion made against the
    /// live view would pass vacuously whatever the label said.
    ///
    /// **The count is spoken in full**, not abbreviated: `1.2k` is a width compromise the row makes
    /// because six capsules share it, and a spoken label has no such constraint. "1,192" is what
    /// the list actually holds.
    nonisolated static func accessibilityLabel(title: String, state: RailItemState) -> String {
        switch state {
        case .reporting(let count):
            return "\(title), \(count.formatted())"
        case .clean:
            return "\(title), nothing found"
        case .notScanned:
            return "\(title), not scanned"
        case .configuration:
            // Rules and the overview item. Neither reports, so neither has a state to announce —
            // and appending "nothing found" to Rules would be the same lie the badge refuses to
            // tell by never drawing a zero there.
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
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    .fixedSize()
            case .notScanned:
                // Not a zero, and not nothing either: a lens that has never run here is a different
                // fact from one that ran and came back clean, and the row is the only place that
                // difference is visible without opening the lens. The tooltip says it in words.
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 4, height: 4)
            case .clean, .configuration:
                EmptyView()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        // **The state has to be spoken, because the state is carried in colour.** This said the
        // title and nothing else, which was survivable while every item looked alike and the only
        // extra information was a badge. It is not survivable now: a reporting item is told apart
        // from a quiet one by its *tint*, and an unscanned one from a clean one by a 4pt dot —
        // neither of which reaches VoiceOver, so all six items announced identically and the whole
        // point of the row was invisible. Colour alone must never be the only carrier of a state
        // (the same rule the scan-freshness pill follows, where `ScanFreshness` supplies a spoken
        // form saying "may be out of date" outright).
        .accessibilityLabel(Self.accessibilityLabel(title: title, state: state))
        // 0.14 is the `Pill` wash this row's other capsules use — matched deliberately, so a
        // reporting item reads as the same kind of thing rather than as a second, competing idiom.
        // The quiet rungs drop to a neutral fill of the same weight, which keeps the capsule (and
        // so the control claim) while spending no colour on a lens with nothing to say.
        .background {
            if isReporting || isSelected {
                Capsule().fill(accent.opacity(isSelected ? 0.22 : 0.14))
            } else {
                Capsule().fill(Color.secondary.opacity(0.10))
            }
        }
        .overlay {
            if isSelected { Capsule().strokeBorder(accent, lineWidth: 2) }
        }
        .contentShape(Capsule())
    }
}

// MARK: - The scope chip

/// The one chip naming what Organize is answering about.
///
/// **A view of its own rather than a `@ViewBuilder` inside `LensWorkspaceView`, so it can be rendered and
/// read back.** That is not a stylistic preference: this row has already truncated its contents to
/// identical stubs once, and four tests compared those stubs and saw no difference — the header's
/// trailing controls clipped, nothing logged, and a probe that only asked whether the band was
/// *inked* saw nothing wrong. Ink presence is not label fidelity. Rendering this in isolation is
/// what lets `OrganizeScopeChipTests` assert the label really says what it claims.
///
/// It names the subtree **and its folder count**, because scope honesty was the original
/// requirement: "Legal" says which folder but not how much of the tree that is, and the count is
/// what makes a lens reporting zero legible as a real answer rather than a broken lens.
///
/// ## The suspended state
///
/// One lens deliberately does not apply the scope — see ``OrganizeLens/isScoped`` — and the chip has
/// to say so rather than disappear. A chip that vanished would read as *the scope was cleared*, and
/// the honest reading is *parked, and it comes back*. So suspended draws the same words in the
/// secondary ink over a neutral capsule, with the ✕ withheld: there is nothing to clear here, and a
/// ✕ that threw away a scope this lens is not using would be the one-way trip stated backwards.
struct ScopeChipLabel: View {
    let name: String
    /// Folders inside the scope, or nil when there is no profile to count against.
    let folderCount: Int?
    let accent: Color
    /// True when a scope is set and the lens on screen is not applying it.
    var isSuspended: Bool = false
    /// Clears the scope. **nil withholds the ✕ entirely**, which is what suspended passes — an
    /// optional rather than a `Bool` beside a closure so the two cannot disagree about whether the
    /// button is there.
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
                // The suspension, said in the chip and not only in the tooltip: a chip that merely
                // went grey would be read as disabled chrome. "Paused" is the shortest word that
                // says the scope is standing rather than gone.
                Text("paused")
                    .scaledFont(.system(size: 9.5, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Scope paused on this lens")
            }
        }
        .foregroundStyle(isSuspended ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        // Neutral while suspended: the accent wash is what makes the chip read as *live narrowing*,
        // and keeping it under grey text would say two different things at once.
        .background(Capsule().fill(isSuspended ? AnyShapeStyle(.quaternary)
                                               : AnyShapeStyle(accent.opacity(0.14))))
        // `fixedSize` so the chip keeps its natural width rather than being compressed into an
        // ellipsis by whatever shares its row — a truncated scope name is a scope claim you cannot
        // read, which is worse than one that pushes the readout beside it.
        .fixedSize()
    }
}

// MARK: - The overview

/// What one lens has to say for the current scope.
///
/// Three states, and the middle one is the one every previous version of this got wrong:
/// **absence must never be ambiguous between *clean* and *cannot run*.** A lens that has never
/// scanned says so and offers to; a lens that scanned and found nothing says *that*, quietly; only
/// a lens with findings takes a section.
enum OrganizeOverviewState: Equatable {
    /// Findings, with the headline number and up to ``OrganizeOverview/exampleLimit`` examples.
    ///
    /// **Plural, and it was singular.** One monospaced line under a count of 722 is a sample of
    /// size one: it proves the list is non-empty and nothing else, and the pane it sits in has
    /// something like 800pt of unused column beneath it. Three lines cost nothing there and are
    /// the difference between "there are duplicates" and knowing whether they are the video you
    /// meant to keep two copies of.
    case findings(count: Int, headline: String, examples: [String])
    /// Ran, found nothing. Reported on the quiet trailing line rather than as a section.
    case clean
    /// Never ran here. Never rendered as a zero — a zero would be a claim this lens cannot make.
    case notScanned
    /// **An answer that is not a backlog** — Storage's report, and the reason this case exists
    /// rather than Storage borrowing ``findings``.
    ///
    /// `findings` renders count-forward: a number in a pill, examples beneath, and a way in
    /// captioned with the count. On Storage that reads as a to-do — "Open Storage — 62 ›" — for a
    /// lens with no verb that touches a file, which is the exact misread the badge rule exists to
    /// prevent. Shoehorning it in would have put the promise back on the one screen where the badge
    /// had been careful to withhold it.
    ///
    /// So a receipt: **when it ran, over what, and what it found**, rendered like `clean`'s quiet
    /// card with the numbers restored. `headline` is the standing fact ("214.6 GB"), `detail` the
    /// provenance ("Analyzed Tuesday · ~/Documents").
    ///
    /// It is deliberately NOT counted by ``Ledger`` — see `countedLenses`, which gates on
    /// `carriesBadge` and so excludes this lens without a line of ledger code.
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
/// **This is the rail's unselected state, not a seventh rail item.** That distinction is the whole
/// defence against the burial the chips were designed to avoid: a lens rail whose default landing
/// is one lens would leave the other five behind items you have to remember to visit. You land
/// here, so nothing has to be remembered — and clicking the selected rail item comes back.
///
/// Sections vanish at zero, exactly as the chips did. What replaces a vanished section is not
/// nothing: it is a line on the quiet footer saying the check ran, which is the difference between
/// "clean" and "never looked".
struct OrganizeOverview: View {
    let sections: [OrganizeOverviewSection]
    let scopeLabel: String?
    let accent: Color
    /// The loose-files inbox offered as a **visible scope shortcut**, or nil when there is no inbox
    /// folder (or it is already the scope).
    ///
    /// This is what replaced the hidden root-swap. `filingScanTargetFolder` used to retarget To
    /// File to the inbox silently whenever the pane happened to sit at the provider root — a
    /// browsing accident deciding the subject. Now it is a thing you can see and click, and because
    /// the scope is sticky across launches it is clicked once rather than re-implied every session.
    ///
    /// **Not the default scope.** Scoped to `TODO`, Renames falls from 126 folders to 0 and five of
    /// the six lenses go dark on launch: the inbox is the right subject for To File and the wrong
    /// one for everything else.
    var inboxShortcut: InboxShortcut?

    /// §5.6's nudge, when one is due (proposal O15): the sentence, the verb, and dismissal.
    ///
    /// **A line, not a card, and outside the ledger entirely.** The counted lenses' ratio has a
    /// documented can't-close invariant — a check that can never run must not sit in the
    /// denominator — and a nudge is not a check at all: nothing scans to produce it and nothing
    /// closes it but the user's own filing. So it renders above the sections and is counted
    /// nowhere.
    var backlogNudge: BacklogNudge?

    struct BacklogNudge {
        /// The sentence, from `RestructureNudge.sentence(for:)` — derived, never composed here.
        let sentence: String
        /// Opens the Restructure lens on the first due finding, through the same resolver route
        /// the Organize menu's verbs use.
        let setUp: () -> Void
        /// Records the year for every due finding, so the same gap is quiet until the next one.
        let dismiss: () -> Void
    }

    struct InboxShortcut {
        /// The inbox's leaf name — "TODO" unless the setting was changed.
        let name: String
        /// Loose files sitting in it, or **nil when the last scan did not cover the inbox** and the
        /// number is therefore unknown.
        ///
        /// Optional because the count comes from one scan's published queue: scoped elsewhere, or
        /// before any scan, nothing in that list is under the inbox and the offer claimed "0 loose
        /// files" while the inbox held fifty — talking the user out of the very click this control
        /// exists to offer. Absent beats a wrong zero, exactly as the rail badges have it.
        let looseFileCount: Int?
        let apply: () -> Void
    }

    /// The cross-lens facts, and the one place on this screen they belong.
    ///
    /// **There is deliberately no total.** The obvious headline — 722 duplicate groups plus 1
    /// structure finding is "723 things" — is arithmetic over incompatible units, and this app has
    /// already rejected it once: the "All" rail item carries no badge because "a number here would
    /// have to mean the sum of six different kinds of thing, which is not a quantity anyone wants"
    /// (`LensWorkspaceView.organizeOverviewRailItem`). A ledger is a wider surface than a badge but not a
    /// different kind of claim, so the same rule holds. What is here instead is three facts that
    /// are each true on their own terms and that no single lens can state.
    struct Ledger: Equatable {
        /// Lenses that have run here, over lenses that can run at all — Rules excluded, because it
        /// never scans. The one number that describes the *screen* rather than the tree.
        var checksRun = 0
        var checksTotal = 0
        /// Of `checksRun`, the lenses with findings. The meter tints this many segments accent;
        /// the remainder of the run segments fill quiet — clean is a completed check, not a blank.
        var checksReporting = 0
        /// Ran and found nothing.
        var checksClean: Int { checksRun - checksReporting }
        /// Reclaimable bytes, **pre-formatted by the caller**, or nil when Duplicates has not run
        /// or has nothing to reclaim.
        ///
        /// A string rather than an `Int` so this file stays free of `Sync` — `formatBytes` lives on
        /// `FileSyncManager`, and importing the manager into a view that renders six lenses' words
        /// is how a presentation type acquires a dependency on the engine.
        var reclaimable: String?
        /// Folders inside the current scope, or nil when there is no profile to count against —
        /// the same honest-absence rule ``ScopeChipLabel`` follows.
        var scopeFolders: Int?

        /// Whether the strip has anything worth the row. Nothing has run and no profile exists on
        /// a first launch, and a strip reading "0 of 5" over an empty pane is chrome.
        var isEmpty: Bool { checksRun == 0 && reclaimable == nil && scopeFolders == nil }

        /// The ledger for a set of sections.
        ///
        /// A static function over the sections rather than arithmetic inside `LensWorkspaceView`, so the two
        /// derivations that could go wrong can be asserted without mounting a view: that a lens is
        /// counted as *run* whenever it is not `notScanned` — `clean` is a completed check and the
        /// commonest way to undercount is to count only the reporting ones — and that the
        /// denominator is the lenses that can run at all.
        ///
        /// `reclaimable` and `scopeFolders` come in from the caller because both need `Sync`.
        ///
        /// `runnablePasses` narrows both halves of the ratio to the checks this host can actually
        /// run — see ``countedLenses(runnablePasses:)`` for why that is not the same as counting
        /// every lens that carries a badge.
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

        /// The lenses the ratio is over: those that can report **and** whose pass this host can
        /// start.
        ///
        /// Two exclusions, and the second was found by review. Rules never scans, so a denominator
        /// of six would leave the ledger stuck at "5 of 6" with every check complete. Restructure
        /// is subtler: its pass is the folder survey, `resurveyFilingMemory` returns early without
        /// an existing profile, and `ContentView` withholds the handler entirely in that state — so
        /// on a machine with no filing profile Restructure can *never* run, and counting it left
        /// the ledger reading "4 of 5" permanently. A ratio that cannot be closed is a standing
        /// claim of outstanding work against a button that does not exist.
        ///
        /// The same predicate governs whether the pass is offered a card at all, so the ledger, the
        /// cards and the footer cannot disagree about which checks are real here.
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
    /// **Not every pass is always runnable, and the missing one is not a bug.** Folder memory is
    /// driven by an optional handler — `LensWorkspaceView.onUpdateFolderMemory` is `(() -> Void)?`, and the
    /// CLI-driven and preview hosts pass nothing — so its card must be able to explain the state
    /// without offering a button that would do nothing. A `Set` rather than a closure so a test can
    /// state the host's capabilities as a value.
    var runnablePasses: Set<OrganizePass> = Set(OrganizePass.allCases)

    let onOpen: (OrganizeLens) -> Void
    /// Starts a pass. **This is the change the whole screen was rebuilt around.** Its predecessor
    /// took an `OrganizeLens` and every call site was `{ railLens = item }` — a control captioned
    /// "Scan…" that navigated to a lens and left you to find that lens's own scan button. It scans.
    let onRun: (OrganizePass) -> Void
    /// Runs Storage's analysis. **Its own handler, not `onRun`, and that is not an oversight.**
    /// `onRun` takes an `OrganizePass`, and Storage is in no pass — its report has a lifecycle of
    /// its own, restored across launches, which is exactly why it is not one of the checks the
    /// ledger counts. `rescanControl(for:)` mints its button from `OrganizePass(producing:)` and
    /// would have nothing to mint from here, so the receipt carries its own verb.
    ///
    /// Optional like `onUpdateFolderMemory`, and for the same reason: a host that cannot run it
    /// must get a card that states the position rather than a button that no-ops.
    var onBuildStorage: (() -> Void)?
    /// Whether Storage's analysis is running right now — the card's verb is withheld while it is,
    /// gated exactly as the header's own button is.
    var isBuildingStorage: Bool = false

    /// The document survey's card, or nil where there is nothing to say about one (RD11).
    ///
    /// **Nil on a machine with no folder profile, and nil once the corpus covers the tree** — in
    /// the second case the incremental *Refresh what’s learned* is the right pass and it is a click,
    /// so offering three hours beside it would be offering the worse of two answers.
    var documentSurvey: DocumentSurveyCardState?
    var onStartDocumentSurvey: (() -> Void)?
    var onResumeDocumentSurvey: (() -> Void)?
    var onPauseDocumentSurvey: (() -> Void)?
    var onStopDocumentSurvey: (() -> Void)?
    /// Opens Help at the topic the privacy line points to.
    var onOpenSurveyHelp: (() -> Void)?
    /// The settled receipt's verb — the incremental re-survey.
    var onUpdateDocumentSurvey: (() -> Void)?

    private var reporting: [OrganizeOverviewSection] {
        sections.filter { if case .findings = $0.state { return true } else { return false } }
    }

    private var clean: [OrganizeOverviewSection] {
        sections.filter { $0.state == .clean }
    }

    /// The sections that are reports rather than backlogs — Storage today, and anything else that
    /// concludes something about the tree without proposing work.
    private var receipts: [OrganizeOverviewSection] {
        sections.filter { if case .receipt = $0.state { return true } else { return false } }
    }

    /// The passes offered a card: every lens they answer is `.notScanned`, **and this host can
    /// start them**.
    ///
    /// **All of them, not any** — a pass is offered only when running it would change every lens
    /// behind the offer. The distinction cannot arise for the file pass today (one flag publishes
    /// its three) and is the correct rule regardless: a card headed "hasn't run here" over a lens
    /// that already has an answer would be false about the lens it names.
    ///
    /// **And runnable, which review added.** Without it the commonest way to meet the folder-memory
    /// card was with no way to act on it: the card appears when there is no profile, `ContentView`
    /// withholds `onUpdateFolderMemory` in exactly that state, and `resurveyFilingMemory` returns
    /// early without a profile anyway — so on any machine that has never been surveyed, the landing
    /// screen carried a permanent card-sized slab offering a scan that could not be run. That is
    /// strictly worse than the one tertiary line it replaced, which is where such a lens now falls
    /// back to (``strandedUnscanned``).
    var pendingPasses: [OrganizePass] {
        OrganizePass.allCases.filter { pass in
            guard runnablePasses.contains(pass) else { return false }
            let mine = sections.filter { pass.lenses.contains($0.lens) }
            return !mine.isEmpty && mine.allSatisfy { $0.state == .notScanned }
        }
    }

    /// Lenses that have not run and whose pass is **not** on offer above — so the invitation is
    /// never dropped for a lens a pass card does not already speak for.
    ///
    /// Two ways in. A pass this host cannot start (folder memory with no profile) is reported here
    /// as a quiet line instead of a dead card; and a pass that has answered some of its lenses but
    /// not all would strand the rest, which the flags cannot produce today but which the shape of
    /// the rule allows.
    var strandedUnscanned: [OrganizeOverviewSection] {
        let offered = Set(pendingPasses.flatMap(\.lenses))
        return sections.filter { $0.state == .notScanned && !offered.contains($0.lens) }
    }

    /// The one stranded lens that carries a pass's offer — the first in rail order, so which row
    /// holds the button is stable rather than a function of iteration luck.
    /// Private again: the test that used to reach for it is what made this rule untestable, since
    /// asking a function that returns one optional how many rows match it can only ever answer 0
    /// or 1. ``offersPassRun(for:)`` is the seam now, and it is the footer's own condition.
    private func firstStrandedLens(of pass: OrganizePass) -> OrganizeLens? {
        strandedUnscanned.first { pass.lenses.contains($0.lens) }?.lens
    }

    /// Whether this footer row draws the run button for its pass — **the predicate the footer
    /// itself branches on**, not a restatement of it.
    ///
    /// Extracted after review found the test guarding this rule could not fail. It counted rows
    /// matching `firstStrandedLens(of:)`, which returns a single optional, so the count it asserted
    /// was `1` could only ever be 0 or 1 by construction — and it never touched the footer's own
    /// condition, so deleting the dedupe from the view left every test green. The rule and the
    /// thing under test have to be one expression, which is the same conclusion
    /// ``offersRescan(for:)`` reached one round earlier.
    func offersPassRun(for section: OrganizeOverviewSection) -> Bool {
        guard section.state == .notScanned,
              let pass = OrganizePass(producing: section.lens),
              runnablePasses.contains(pass) else { return false }
        return firstStrandedLens(of: pass) == section.lens
    }

    /// Whether a row that has already answered offers to re-run the scan behind it.
    ///
    /// Extracted from the view so the rule can be asserted directly rather than inferred from
    /// pixels — and because the pixel test alone could not express the property that matters most
    /// here, which is that the answer does **not** move with the data. See
    /// ``OrganizePass/answersOneLens``.
    func offersRescan(for section: OrganizeOverviewSection) -> Bool {
        guard case .findings = section.state, !section.isScanning,
              let pass = OrganizePass(producing: section.lens) else { return false }
        return pass.answersOneLens && runnablePasses.contains(pass)
    }

    /// How many examples a finding row draws. Three, measured against the room: the row's other
    /// tenants are two 14pt lines and a button, and the pane it lives in is a full window column.
    static let exampleLimit = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !ledger.isEmpty { ledgerStrip }
                if let backlogNudge { nudgeLine(backlogNudge) }
                ForEach(reporting) { section in
                    sectionView(section)
                }
                ForEach(pendingPasses) { pass in
                    passCard(pass)
                }
                // **A lens no pass speaks for, in the state it spends most of its life in.**
                // Storage before its first analysis used to be a line of tertiary text in the
                // footer with a button on it; it is a card here, on the same rung as the pass
                // offers, because it is the same kind of thing — a check that has not run and can
                // be run from this screen.
                ForEach(strandedCards) { section in
                    strandedCard(section)
                }
                // `documentSurvey` counts here too: an "everything is clear" panel above a card
                // offering three hours of reading is the screen contradicting itself.
                if reporting.isEmpty && pendingPasses.isEmpty && receipts.isEmpty
                    && strandedCards.isEmpty && documentSurvey == nil {
                    allClearState
                }
                // **After the findings and the offers, before the footer.** A receipt is not work,
                // so it must not sit above things that are; it is also not nothing, so it does not
                // belong on the quiet trailing line with the clean checks. Its own rung between
                // them is what says "this is an answer you asked for, and there is nothing to do
                // about it".
                // **Above the receipts and below the offers**, which is the rung its meaning
                // asks for: while it is offered or running it is closer to work than to an answer,
                // and when it has finished it is a receipt like Storage's. One position through
                // every state, because a card that moved as it progressed would make the same
                // feature look like three.
                if let documentSurvey {
                    DocumentSurveyCard(state: documentSurvey, accent: accent,
                                       onStart: onStartDocumentSurvey,
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

    /// §5.6's "say it the month it happens", outside the lens: one sentence, its verb, and a way
    /// to make it go away until next year.
    ///
    /// **A card, and its verb is a button.** It was a grey well with *Set up…* set as a bare blue
    /// link inline in the sentence — the one control on the page that had escaped the rule the
    /// whole redesign was about, and the first thing anybody noticed afterwards. It is still not a
    /// check — nothing scans to produce it and the ledger counts it nowhere — and it is not dressed
    /// as one: with no lede under it, its sentence is set as a sentence rather than as a heading.
    /// What being a notice no longer buys it is an exemption from how a verb looks.
    private func nudgeLine(_ nudge: BacklogNudge) -> some View {
        OverviewCard(
            symbol: "calendar.badge.plus",
            title: nudge.sentence,
            accent: accent,
            // The card's only verb, so it is the primary — the same rule the survey's lone Refresh
            // follows, and the reason it now lands on the same vertical line as every other one.
            actions: [OverviewCardAction(title: "Set up…", rank: .primary,
                                         help: "Opens Restructure on the first folder with this "
                                             + "gap.", run: nudge.setUp)],
            dismiss: OverviewCardDismiss(
                accessibilityLabel: "Dismiss this reminder until next year",
                help: "Dismisses it for this year. The same folders raise it again when a new "
                    + "year arrives with the same gap.",
                run: nudge.dismiss)) { }
    }

    // MARK: The ledger

    /// The ledger as tiles: each fact its own quiet card, sized to its content — the former
    /// full-width gray band left the numbers adrift on a metre of trailing emptiness.
    ///
    /// **One builder for all three, and one height for all three.** They were two builders before,
    /// and the checks tile's `.fixedSize()` let its meter push it a line taller than the tiles
    /// beside it — three cards in a row, none of them agreeing where their bottom edge was. Now the
    /// meter is a slot inside the shared tile and every tile is stretched to the tallest, so what
    /// varies between them is the width their content asks for and nothing else.
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

    /// Meter segment geometry — shared with nothing, named so the render test can reason in it.
    static let meterSegmentSize = CGSize(width: 16, height: 4)

    /// The floor every ledger tile is stretched to.
    ///
    /// A floor rather than a fixed height, so a text-size change still grows them; and a floor at
    /// all so that a run of tiles whose contents differ in height still reads as one row of cards.
    /// **Do not lower it below 60** without re-reading `theNudgeDoesNotTouchTheChecksLedger`, which
    /// asserts on the top 74pt of the render and needs the nudge to stay out of that band.
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
    /// per-lens identity — this is a fraction, not a map — accent for "wants you", a quiet fill
    /// for "ran, nothing", near-ground for "never looked".
    private func meterColor(for index: Int) -> Color {
        if index < ledger.checksReporting { return accent }
        if index < ledger.checksRun { return Color.primary.opacity(0.30) }
        return Color.primary.opacity(0.10)
    }

    /// The offer's second line: the count when it is known, and the invitation alone when it is not.
    ///
    /// A value rather than a ternary in the body so it can be asserted without rendering — the
    /// wrong-zero it replaces was a string, and strings are what this needs to pin.
    static func inboxSubtitle(_ looseFileCount: Int?) -> String {
        guard let n = looseFileCount else { return "Organize just this folder" }
        return n == 1
            ? "1 loose file — organize just this folder"
            : "\(n) loose files — organize just this folder"
    }

    /// The inbox as a place to point Organize at, one press.
    ///
    /// Placed after the findings and before the quiet footer: it is an offer about where to look
    /// next, not a finding, and putting it above the sections would give the inbox the prominence
    /// the old hidden default gave it — which is the thing being undone.
    ///
    /// **The whole row used to be the button, with a chevron for an affordance** — a fourth way of
    /// offering an action on a page where everything else is *read the card, press the button*, and
    /// the one control on it that gave no hint of its own hit area. The offer is the same; it is
    /// made the way the rest of the page makes offers.
    ///
    /// Not a check either — it names no lens and has no answer — but it does have a name and a
    /// line under it, so it heads them the way the cards do.
    private func inboxOffer(_ shortcut: InboxShortcut) -> some View {
        OverviewCard(
            symbol: "tray",
            title: "Inbox (\(shortcut.name))",
            subtitle: Self.inboxSubtitle(shortcut.looseFileCount),
            accent: accent,
            actions: [OverviewCardAction(
                title: "Point Organize here", rank: .primary,
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

    /// The unit run of a "\(count) unit" headline — "folders" of "79 folders" — or nil when the
    /// headline does not lead with this count, in which case the pill draws the whole string.
    /// Every current headline leads with its count; the fallback exists so a future headline
    /// that doesn't cannot render "79 79 folders".
    nonisolated static func headlineUnit(count: Int, headline: String) -> String? {
        let prefix = "\(count) "
        guard headline.hasPrefix(prefix) else { return nil }
        return String(headline.dropFirst(prefix.count))
    }

    /// One reporting lens: what it is, how much of it there is, what it looks like, and the way in.
    ///
    /// **The accent wash and the leading stripe are gone**, and their loss is the point of the
    /// redesign rather than a casualty of it. They made one card in six look like it came from a
    /// different app — a tinted slab with a coloured bar, among grey wells — to carry a signal that
    /// the accent glyph tile and the accent count pill already carry twice over. What distinguishes
    /// a finding from an offer now is the same thing that distinguishes it on the rail: ink on the
    /// glyph and a number in a pill.
    ///
    /// **And the verbs moved into the heading**, beside every other card's verbs. They used to sit
    /// under the examples, indented 30pt, which put this card's Refresh some 60pt below and 400pt
    /// left of the document survey's Refresh — the same word, the same kind of act, in two places
    /// that had nothing to do with each other.
    private func findingsSection(_ section: OrganizeOverviewSection, count: Int,
                                 headline: String, examples: [String]) -> some View {
        OverviewCard(
            symbol: section.lens.symbol,
            title: section.lens.title,
            subtitle: section.blurb,
            tone: .reporting,
            accent: accent,
            // The number below is last scan's while a rescan is in flight, and its own lens's
            // readout is suppressed for exactly this reason — see
            // `OrganizeLens.goesStaleDuringFilingScan`. Saying so beats redrawing a stale figure in
            // confident bold.
            status: section.isScanning
                ? .working("rescanning")
                : Self.headlineUnit(count: count, headline: headline)
                    .map { .count(count, unit: $0) } ?? .text(headline),
            actions: actions(for: section),
            // **The small print prices the verb, and a card with no priced verb has none.** That is
            // the rule the pass cards were already following without it being written down: "Free
            // — and the slow one" sits under a card whose button hashes every file in scope. A
            // findings card that offers a Refresh is making the same kind of ask, so it says the
            // same kind of thing; one that offers only a way in is asking for nothing and stops at
            // the heading rather than filling the slot for symmetry's sake.
            note: findingsNote(section),
            accessibilityLabel: "\(section.lens.title), \(headline)") {
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

    /// **Every verb a lens's card offers, in whatever state it is in — the one place the answer
    /// lives.**
    ///
    /// A dispatcher rather than three private builders the three card bodies each reach for
    /// separately, because the rules worth asserting are *across* the states: at most one primary
    /// per card, and a stranded lens gets a card exactly when this returns something. Both are
    /// properties of the whole set, and a rule that has to be read off three call sites is a rule
    /// the next state will forget.
    func actions(for section: OrganizeOverviewSection) -> [OverviewCardAction] {
        switch section.state {
        case .findings(let count, _, _):
            return section.isScanning ? [] : findingsActions(section, count: count)
        case .receipt:
            return receiptActions(section)
        case .notScanned:
            return section.isScanning ? [] : strandedActions(section)
        case .clean:
            // A clean lens takes no card at all — it is one entry on the footer's quiet line.
            return []
        }
    }

    /// What re-asking costs, where this card offers to re-ask at all.
    private func findingsNote(_ section: OrganizeOverviewSection) -> OverviewCardNote? {
        guard offersRescan(for: section),
              let pass = OrganizePass(producing: section.lens) else { return nil }
        return OverviewCardNote(pass.offerCost)
    }

    /// A finding's verbs: the way in, and — where the pass answers this lens alone — the way to
    /// ask again.
    ///
    /// **The way in is the primary**, because a card that has found something is a card whose point
    /// is that you go and look. The count is not repeated in its title any more: the pill three
    /// inches to its left already says 53, and "Open Restructure — 53 ›" said it twice while
    /// being the one button on the screen whose width moved with the data.
    private func findingsActions(_ section: OrganizeOverviewSection, count: Int)
    -> [OverviewCardAction] {
        var actions = [OverviewCardAction(title: "Open \(section.lens.title)", rank: .primary,
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
    /// **No accent and no count pill**, which is the whole visual argument and the one part of the
    /// old card worth keeping. Both are how this screen says "here is work"; a receipt that
    /// borrowed them would promise a backlog for a lens that has no verb touching a file — the
    /// misread the badge rule already refuses on the rail, arriving through the overview instead.
    /// It is a card like every other card now, and it is quiet like every other card that is not
    /// reporting; those two facts no longer have to be traded against each other.
    ///
    /// The provenance goes under the rule, where the pass cards put their cost: "Analyzed Tuesday ·
    /// ~/Documents" is the thing a stale report most needs to say about itself, and it is small
    /// print rather than a headline.
    @ViewBuilder
    private func receiptCard(_ section: OrganizeOverviewSection) -> some View {
        if case .receipt(let headline, let detail) = section.state {
            OverviewCard(
                symbol: section.lens.symbol,
                title: section.lens.title,
                subtitle: headline,
                accent: accent,
                actions: actions(for: section),
                note: OverviewCardNote(detail, symbol: "clock"),
                accessibilityLabel: "\(section.lens.title), \(detail), \(headline)") { }
        }
    }

    private func receiptActions(_ section: OrganizeOverviewSection) -> [OverviewCardAction] {
        // "Open Storage" without a count, unlike a finding's pill. The count belongs on a backlog
        // you are going to work through; here it would put the number in the one place the badge
        // rule was careful to keep it out of.
        var actions = [OverviewCardAction(title: "Open \(section.lens.title)", rank: .primary,
                                          run: { onOpen(section.lens) })]
        if section.lens == .storage, let onBuildStorage {
            actions.append(OverviewCardAction(title: isBuildingStorage ? "Analyzing…" : "Re-analyze",
                                              isDisabled: isBuildingStorage,
                                              run: onBuildStorage))
        }
        return actions
    }

    // MARK: A pass that has not run

    /// The offer to run one scan — **and the whole reason this screen was rebuilt** the round
    /// before this one.
    ///
    /// What it replaces was three tertiary lines reading "To File — not scanned  Scan…", one per
    /// lens, whose buttons did not scan: they set the rail selection and left you at that lens's
    /// intro to press its scan button instead. Two things were wrong and only one of them was the
    /// button. The other is that the three lines described three choices where the machinery has
    /// one — so the card names the *pass*, and lists the lenses it answers underneath as
    /// consequence rather than as options.
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
    /// The accent bracket on the leading edge is what says *these come together* without a
    /// sentence explaining it — and there is deliberately no button here. Two buttons both
    /// starting the identical pass would be the old footer's claim in new clothes.
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

    /// **Storage's card before it has ever been analyzed — and the hole this redesign was reported
    /// against.**
    ///
    /// Every other lens on this screen gets a card in every state: findings take one, a pass that
    /// has not run takes one, a report takes one. Storage in the state it spends most of its life
    /// in — never analyzed — took a line of tertiary grey text in the footer, below the fold,
    /// beside the "duplicates checked" glosses. It is a lens with a verb and a real answer to give,
    /// and it looked like a footnote about something that had already happened.
    ///
    /// The reason it fell there is real and is preserved: Storage is in no ``OrganizePass``, so
    /// `pendingPasses` cannot offer it a card and it lands in ``strandedUnscanned``. What changes is
    /// what a stranded lens *draws*. **A stranded lens with a verb gets a card; one without stays a
    /// quiet line**, which keeps the rule that produced the footer in the first place — a card
    /// offering a scan this host cannot start is worse than a line saying it has not run.
    var strandedCards: [OrganizeOverviewSection] {
        strandedUnscanned.filter { !actions(for: $0).isEmpty }
    }

    /// Stranded lenses with nothing to offer — the quiet line, still, and for the original reason.
    var strandedLines: [OrganizeOverviewSection] {
        strandedUnscanned.filter { actions(for: $0).isEmpty }
    }

    /// The verb a never-run lens can offer from here, if any.
    ///
    /// Two sources, and they are mutually exclusive by construction: a pass this host can start
    /// (`offersPassRun` already de-dupes it to one row per pass), or — for the one lens in no pass
    /// — Storage's own analyzer.
    private func strandedActions(_ section: OrganizeOverviewSection) -> [OverviewCardAction] {
        if offersPassRun(for: section), let pass = OrganizePass(producing: section.lens) {
            return [OverviewCardAction(title: pass.runTitle, rank: .primary, help: pass.offerCost,
                                       run: { onRun(pass) })]
        }
        if section.lens == .storage, let onBuildStorage {
            return [OverviewCardAction(title: isBuildingStorage ? "Analyzing…" : "Analyze",
                                       rank: .primary, isDisabled: isBuildingStorage,
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

    /// The heading over a check that has not run and has no pass card to say so.
    ///
    /// **It names what did not happen, in that check's own verb.** A generic "Storage hasn’t run
    /// here" is the shape of sentence a pass card makes about a walk of the tree, and Storage does
    /// not walk — it analyses, and its button says Analyze. A heading and a button disagreeing
    /// about the verb on one card is how a screen teaches somebody the wrong word for what they
    /// are about to do. Where a pass does own the lens, its own ``OrganizePass/offerTitle`` is
    /// already the right sentence and is quoted rather than restated.
    static func strandedTitle(_ lens: OrganizeLens) -> String {
        if let pass = OrganizePass(producing: lens) { return pass.offerTitle }
        return lens == .storage ? "Storage hasn’t been analyzed here"
                                : "\(lens.title) hasn’t run here"
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
    /// run" — that state draws pass cards instead, which is why this is gated on both.
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
    /// offer from here — the two things on this screen that are genuinely footnotes.
    ///
    /// **What left it is Storage's Analyze, and the run buttons beside the stranded rows.** A
    /// button on a footnote line was the tell that the line was carrying something it was not
    /// shaped for; those lenses have cards now (``strandedCard(_:)``), and what stays here is only
    /// text.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            if !clean.isEmpty {
                // A tiny checkmark before each entry says "ran and clean" pre-attentively.
                // Tertiary like the words, deliberately not success-green: clean is quiet
                // (the tier rule) — a zero is still never drawn, and neither is a celebration.
                // FlowLayout, not an HStack: five entries at extra-large text overrun a
                // 600pt-floor window, and a row that cannot wrap clips its last claims.
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
/// **The column is real and is kept.** ``OrganizeLens/symbol`` draws six shapes at six different
/// widths — `doc` is narrow, `folder.badge.gearshape` is not — and without a frame the titles
/// beside them would each start at a different x, turning a list that is meant to read as one
/// bracketed group into a ragged edge. That is the same argument ``CapsuleGlyph`` makes, and the
/// same one this got wrong in the same way.
///
/// **What was wrong was pinning the width alone.** The frame was `.frame(width: 14)` with no
/// height, so the box grew *down* with the text size and not *across*: measured 2026-08-31, the
/// glyph column was 14×12 at Small and 14×16 at Largest — one axis following the type ramp while
/// the other sat still. `.frame` does not clip, so the surplus drew straight out of the column,
/// and rendered back off a bitmap the widest lens symbol put ink **3.0pt past the column at Large
/// and 4.0pt past it at Largest**, into an 8pt gap it shares with the title beside it. Small and
/// Default were clean, which is why nothing saw it: the two sizes anybody develops at are the two
/// this never broke at.
///
/// Scaling the box through ``Design/FontSize/scaledBox(_:basePoint:scale:)`` takes that worst
/// overhang to **0.4 · 0.0 · 1.5 · 1.1pt** and leaves Default at exactly 14, so the shipped
/// rendering at 100% is unchanged. The residue is deliberate rather than overlooked: closing it
/// completely wants ``boxSize`` at 17, which would move every pass card's titles 3pt at *every*
/// text size to buy 1.5pt at one of them.
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
