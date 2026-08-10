import SwiftUI
import Design

// MARK: - The rail item

/// One item on Organize's lens rail: glyph, name, and a badge **only when there is something to
/// report**.
///
/// The two halves of the chips' argument are split here on purpose. The *place* is unconditional —
/// it is what pointed invocation ("Organize this folder") lands on, and what a badge cannot be
/// because a badge does not exist before a scan. The *claim* is conditional: `badge == nil` draws
/// no number at all, not a greyed one and not a `0`.
///
/// **It wears a capsule because a capsule is a control.** That rule came out of this very row: it
/// once carried six tinted capsules of which only three were buttons, and the only way to learn
/// which half was live was to click. Every rail item IS a button, and the readout still shares the
/// row with them after the divider — so dropping the capsule here would recreate the same
/// ambiguity from the other side, with live controls dressed as prose. The selected item deepens
/// its fill and adds the ring; the wash is what says "clickable" before you know which is current.
/// What a rail item has to say about its lens, and therefore how it is dressed.
///
/// **The same three states ``OrganizeOverviewState`` models, deliberately.** The overview is
/// careful never to conflate *ran and found nothing* with *never looked* — a zero would be a claim
/// a lens that has not scanned cannot make — and the rail used to throw that distinction away,
/// drawing both as an item with no badge. Two surfaces describing one set of facts had two
/// vocabularies; now they have one, and `TidyView` derives both from the same counts.
enum RailItemState: Equatable {
    /// This lens has findings here. The count is the whole scoped list, never the filtered view.
    case reporting(Int)
    /// It ran and found nothing. Says so by going quiet, not by drawing a `0`.
    case clean
    /// It has not run here at all. Never a zero — that would be a claim it cannot support.
    case notScanned
    /// Not a finding at all: Rules is configuration you keep. It never reports and never goes
    /// quiet, so it is neither `clean` nor `notScanned` — those both describe a scan.
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
/// **A view of its own rather than a `@ViewBuilder` inside `TidyView`, so it can be rendered and
/// read back.** That is not a stylistic preference: this row has already truncated its contents to
/// identical stubs once, and four tests compared those stubs and saw no difference — the header's
/// trailing controls clipped, nothing logged, and a probe that only asked whether the band was
/// *inked* saw nothing wrong. Ink presence is not label fidelity. Rendering this in isolation is
/// what lets `OrganizeScopeChipTests` assert the label really says what it claims.
///
/// It names the subtree **and its folder count**, because scope honesty was the original
/// requirement: "Legal" says which folder but not how much of the tree that is, and the count is
/// what makes a lens reporting zero legible as a real answer rather than a broken lens.
struct ScopeChipLabel: View {
    let name: String
    /// Folders inside the scope, or nil when there is no profile to count against.
    let folderCount: Int?
    let accent: Color
    let onClear: () -> Void

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
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .scaledFont(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help("Organize everything again")
            .accessibilityLabel("Clear scope")
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(accent.opacity(0.14)))
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
    /// (`TidyView.organizeOverviewRailItem`). A ledger is a wider surface than a badge but not a
    /// different kind of claim, so the same rule holds. What is here instead is three facts that
    /// are each true on their own terms and that no single lens can state.
    struct Ledger: Equatable {
        /// Lenses that have run here, over lenses that can run at all — Rules excluded, because it
        /// never scans. The one number that describes the *screen* rather than the tree.
        var checksRun = 0
        var checksTotal = 0
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
        /// A static function over the sections rather than arithmetic inside `TidyView`, so the two
        /// derivations that could go wrong can be asserted without mounting a view: that a lens is
        /// counted as *run* whenever it is not `notScanned` — `clean` is a completed check and the
        /// commonest way to undercount is to count only the reporting ones — and that the
        /// denominator is the lenses that can run at all.
        ///
        /// `reclaimable` and `scopeFolders` come in from the caller because both need `Sync`.
        static func derived(from sections: [OrganizeOverviewSection],
                            reclaimable: String?, scopeFolders: Int?) -> Self {
            Self(checksRun: sections.filter { $0.state != .notScanned }.count,
                 // **`carriesBadge`, not `allCases.count`.** Rules can never run, so a denominator
                 // of six would leave the ledger stuck at "5 of 6" with every check complete —
                 // a screen that permanently claims outstanding work.
                 checksTotal: OrganizeLens.allCases.filter(\.carriesBadge).count,
                 reclaimable: reclaimable,
                 scopeFolders: scopeFolders)
        }
    }

    var ledger = Ledger()

    /// The passes this host can actually start.
    ///
    /// **Not every pass is always runnable, and the missing one is not a bug.** Folder memory is
    /// driven by an optional handler — `TidyView.onUpdateFolderMemory` is `(() -> Void)?`, and the
    /// CLI-driven and preview hosts pass nothing — so its card must be able to explain the state
    /// without offering a button that would do nothing. A `Set` rather than a closure so a test can
    /// state the host's capabilities as a value.
    var runnablePasses: Set<OrganizePass> = Set(OrganizePass.allCases)

    let onOpen: (OrganizeLens) -> Void
    /// Starts a pass. **This is the change the whole screen was rebuilt around.** Its predecessor
    /// took an `OrganizeLens` and every call site was `{ railLens = item }` — a control captioned
    /// "Scan…" that navigated to a lens and left you to find that lens's own scan button. It scans.
    let onRun: (OrganizePass) -> Void

    private var reporting: [OrganizeOverviewSection] {
        sections.filter { if case .findings = $0.state { return true } else { return false } }
    }

    private var clean: [OrganizeOverviewSection] {
        sections.filter { $0.state == .clean }
    }

    /// The passes with nothing to show here: every lens they answer is `.notScanned`.
    ///
    /// **All of them, not any** — a pass is offered only when running it would change every lens
    /// behind the offer. The distinction cannot arise for the file pass today (one flag publishes
    /// its three) and is the correct rule regardless: a card headed "hasn't run here" over a lens
    /// that already has an answer would be false about the lens it names.
    var pendingPasses: [OrganizePass] {
        OrganizePass.allCases.filter { pass in
            let mine = sections.filter { pass.lenses.contains($0.lens) }
            return !mine.isEmpty && mine.allSatisfy { $0.state == .notScanned }
        }
    }

    /// Lenses that have not run and whose pass is **not** on offer above — so the invitation is
    /// never dropped for a lens a pass card does not already speak for.
    ///
    /// Empty today, and kept because emptiness here is a consequence of how the flags happen to be
    /// wired rather than a guarantee. If a future pass ever publishes its lenses separately, this
    /// is what keeps those lenses from silently losing the only offer to scan them.
    private var strandedUnscanned: [OrganizeOverviewSection] {
        let offered = Set(pendingPasses.flatMap(\.lenses))
        return sections.filter { $0.state == .notScanned && !offered.contains($0.lens) }
    }

    /// How many examples a finding row draws. Three, measured against the room: the row's other
    /// tenants are two 14pt lines and a button, and the pane it lives in is a full window column.
    static let exampleLimit = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !ledger.isEmpty { ledgerStrip }
                ForEach(reporting) { section in
                    sectionView(section)
                }
                ForEach(pendingPasses) { pass in
                    passCard(pass)
                }
                if reporting.isEmpty && pendingPasses.isEmpty {
                    allClearState
                }
                if let inboxShortcut { inboxOffer(inboxShortcut) }
                if !strandedUnscanned.isEmpty || !clean.isEmpty {
                    footer
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: The ledger

    /// "2 of 5 · checks have run   4.2 GB · reclaimable   3,013 · folders in scope".
    private var ledgerStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            ledgerStat("\(ledger.checksRun) of \(ledger.checksTotal)", "checks have run",
                       emphasised: false)
            if let reclaimable = ledger.reclaimable {
                ledgerStat(reclaimable, "reclaimable", emphasised: true)
            }
            if let folders = ledger.scopeFolders {
                ledgerStat(folders.formatted(),
                           folders == 1 ? "folder in scope" : "folders in scope",
                           emphasised: false)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
    }

    private func ledgerStat(_ value: String, _ caption: String, emphasised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .scaledFont(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(emphasised ? accent : Color.primary)
            Text(caption)
                .scaledFont(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(caption)")
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

    /// "Inbox (TODO) — N loose files", one click to scope there.
    ///
    /// Placed after the findings and before the quiet footer: it is an offer about where to look
    /// next, not a finding, and putting it above the sections would give the inbox the prominence
    /// the old hidden default gave it — which is the thing being undone.
    private func inboxOffer(_ shortcut: InboxShortcut) -> some View {
        Button(action: shortcut.apply) {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 21, height: 21)
                    .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Inbox (\(shortcut.name))")
                        .scaledFont(.system(size: 12.5, weight: .semibold))
                    Text(Self.inboxSubtitle(shortcut.looseFileCount))
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .chromeHover()
        .help("Point Organize at the inbox. Every lens narrows to it, and it stays until you "
              + "change it.")
    }

    // MARK: A lens with findings

    @ViewBuilder
    private func sectionView(_ section: OrganizeOverviewSection) -> some View {
        if case .findings(let count, let headline, let examples) = section.state {
            findingsSection(section, count: count, headline: headline, examples: examples)
        }
    }

    /// One reporting lens: what it is, how much of it there is, what it looks like, and the way in.
    ///
    /// The accent stripe down the leading edge is the only thing distinguishing this from a pass
    /// card at a glance, and it is doing real work: findings and offers are both full-width cards
    /// on this screen, and the difference between "here is an answer" and "here is something you
    /// could run" should not rest on reading the heading.
    private func findingsSection(_ section: OrganizeOverviewSection, count: Int,
                                 headline: String, examples: [String]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Image(systemName: section.lens.symbol)
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 21, height: 21)
                        .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.lens.title)
                            .scaledFont(.system(size: 12.5, weight: .semibold))
                        Text(section.blurb)
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if section.isScanning {
                        // The number below is last scan's, and its own lens's readout is suppressed
                        // for exactly this reason — see `OrganizeLens.goesStaleDuringFilingScan`.
                        // Saying so beats redrawing a stale figure in confident bold.
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("rescanning")
                                .scaledFont(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    } else {
                        Text(headline)
                            .scaledFont(.system(size: 13, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                            .fixedSize()
                    }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30)
                }
                Button("Open \(section.lens.title) — \(count) ›") { onOpen(section.lens) }
                    .buttonStyle(.plain)
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .chromeHover()
                    .padding(.leading, 30)
            }
            .padding(.leading, 10)
            .padding(.vertical, 10)
            .padding(.trailing, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(accent.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // MARK: A pass that has not run

    /// The offer to run one scan — **and the whole reason this screen was rebuilt.**
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: pass.symbol)
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 21, height: 21)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(pass.offerTitle)
                        .scaledFont(.system(size: 12.5, weight: .semibold))
                    Text(pass.offerLede)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isRunning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Running…")
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                } else if runnablePasses.contains(pass) {
                    Button(pass.runTitle) { onRun(pass) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .chromeHover()
                        .fixedSize()
                        .help(pass.offerCost)
                }
            }
            .padding(11)

            // The lenses this one click answers. Drawn only when there is more than one, because
            // for a single-lens pass the row would restate the heading directly above it.
            if pass.lenses.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(pass.lenses, id: \.self) { lens in
                        passLensRow(lens)
                    }
                }
            }

            Divider()
            // `.secondary`, not `.tertiary`. This is the one line on the card stating what the
            // click costs, and rendering it read back as barely legible grey — the weight the
            // footer's "names checked" gloss deserves, not the weight a cost disclosure does.
            Text(pass.offerCost)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    /// One lens inside a pass card: what this share of the one walk gets you.
    ///
    /// The accent bracket on the leading edge is what says *these come together* without a
    /// sentence explaining it — and there is deliberately no button here. Three buttons all
    /// starting the identical pass would be the old footer's claim in new clothes.
    @ViewBuilder
    private func passLensRow(_ lens: OrganizeLens) -> some View {
        let blurb = sections.first { $0.lens == lens }?.blurb
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(accent.opacity(0.35))
                .frame(width: 2)
                .accessibilityHidden(true)
            Image(systemName: lens.symbol)
                .scaledFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
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
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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

    /// The quiet line: what ran and was clean, and any lens left unscanned that no pass card above
    /// already speaks for.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            if !clean.isEmpty {
                Text(clean.map { "\($0.lens.title.lowercased()) checked" }
                        .joined(separator: " · "))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(strandedUnscanned) { section in
                HStack(spacing: 6) {
                    Text("\(section.lens.title) — not scanned")
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    // Runs the pass, like every other scan control on this screen. `nil` only for
                    // Rules, which has no pass and never reaches here — it takes no section at all.
                    if let pass = OrganizePass(producing: section.lens),
                       runnablePasses.contains(pass) {
                        Button(pass.runTitle) { onRun(pass) }
                            .buttonStyle(.plain)
                            .scaledFont(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent)
                            .chromeHover()
                    }
                }
            }
        }
    }
}
