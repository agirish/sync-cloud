import SwiftUI
import AppKit
import Events
import Sync
import Design

// MARK: - Lens / filter / match styling

/// The lenses shown in the right-hand slot. Public so the host can map its selected workspace
/// onto one; the choice itself is made by the window's workspace bar, not in here.
///
/// Still its own type rather than folded into `Workspace`: the per-lens search grammars, query
/// parking and expansion state in `TidyView` are all keyed by it, and they have no meaning for
/// Compare.
public enum TidyLens: String, CaseIterable, Identifiable {
    case duplicates = "Duplicates"
    /// The former Name Normalizer, its own lens again (was briefly folded into Organize) — finds and
    /// fixes cloud-hostile names. Shown as "Rename".
    case rename = "Rename"
    case filing = "Filing"
    case automations = "Automations"
    /// The former standalone Storage Lens tab, folded in as a read-only lens (treemap + largest /
    /// stale / reclaim lists). Sits last, after the action lenses.
    case storage = "Storage"
    public var id: String { rawValue }

    /// The lens's name, shown in the header card. Kept separate from `rawValue` so it can be
    /// reworded without breaking a stored id (Filing shows as "Organize").
    public var title: String {
        switch self {
        case .filing: return "Organize"
        default: return rawValue
        }
    }
}

/// Filter over the match type of duplicate groups.
enum TidyFilter: String, CaseIterable, Identifiable {
    case all, identical, overlapping, nameOnly, versions
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .identical: return "Identical"
        case .overlapping: return "Overlapping"
        case .nameOnly: return "Name only"
        case .versions: return "Versions"
        }
    }

    func matches(_ group: DuplicateGroup) -> Bool {
        switch self {
        case .all: return true
        case .identical: return group.matchType.kind == .identical
        case .overlapping: return group.matchType.kind == .overlapping
        case .nameOnly: return group.matchType.kind == .nameOnly
        case .versions: return group.matchType.kind == .versions
        }
    }
}

/// The symbol/color/label vocabulary for a match type — reuses SyncCloud's difference palette
/// (green seal = certain, orange = attention, yellow = name conflict, purple = versions).
enum TidyMatchStyle {
    static func symbol(_ type: DuplicateMatchType) -> String {
        switch type {
        case .identical: return "checkmark.seal.fill"
        case .overlapping: return "square.on.square"
        case .nameOnly: return "exclamationmark.triangle.fill"
        case .versions: return "clock.arrow.circlepath"
        }
    }
    static func color(_ type: DuplicateMatchType) -> Color {
        switch type {
        case .identical: return SemanticColor.success
        case .overlapping: return SemanticColor.warning
        case .nameOnly: return SemanticColor.caution
        case .versions: return .purple
        }
    }
    static func label(_ type: DuplicateMatchType) -> String {
        switch type {
        case .identical: return "Identical"
        case .overlapping(let f): return "Overlapping · \(Int((f * 100).rounded()))%"
        case .nameOnly: return "Name only"
        case .versions: return "Versions"
        }
    }
    static func filterColor(_ f: TidyFilter) -> Color {
        switch f {
        case .all: return .secondary
        case .identical: return SemanticColor.success
        case .overlapping: return SemanticColor.warning
        case .nameOnly: return SemanticColor.caution
        case .versions: return .purple
        }
    }
}

// MARK: - Scan-start session reset

/// Everything a fresh Duplicates scan retires, as one named list instead of loose assignments
/// inside `.onChange`.
///
/// The defect this exists to prevent was an OMISSION from that list: the reclaim tally and the
/// search query were cleared on scan start, but the type filter was not — so a "Versions" filter
/// picked against the previous results silently survived into the new scan. The lens then showed a
/// partial list with no visible cause, or the "Nothing matches" dead end, whose copy blames *the
/// search* and offers to clear it — advice that fixes nothing when no search is active. Both
/// narrowings are one narrowing to the user (the same empty state's button clears both), so both
/// belong to the results they were aimed at and neither may outlive them.
enum TidyScanReset {
    static func duplicatesScanStarted(filter: inout TidyFilter,
                                      searchQuery: inout String,
                                      reclaim: inout ReclaimTally) {
        filter = .all
        searchQuery = ""
        reclaim.reset()
    }
}

// MARK: - TidyView

/// A single-source lens workspace (Duplicates, Rename, Organize, Automations, or the read-only
/// Storage), rendered in the right-hand slot with the source rail docked beside it.
///
/// Which lens is showing is no longer decided here. It used to be: this view rendered the lens
/// tabs and wrote the host's binding. The workspace bar in the window toolbar owns that choice
/// now, and this view is handed the resolved lens.
public struct TidyView: View {
    @ObservedObject public var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    /// The recorded cloud spend both Organize surfaces read — the setup card's price and the
    /// spend row above the results.
    ///
    /// **Held in state, and BOTH of them, which is the half that was missed.** Each of
    /// `FilingSpendStore.last()` and `.totals()` is a `UserDefaults` read plus a `JSONDecoder`
    /// pass, and each was being re-read on every body evaluation. Caching only the setup card's
    /// copy fixed the state that has nothing to type in — the card shows when there are no results
    /// — and left `filingSpendRow`, which renders alongside the results and therefore on every
    /// keystroke in the Organize search field, decoding twice per render. One value, refreshed by
    /// ``refreshFilingSpend()`` at the three moments spend can change across: appearing, a scan
    /// finishing, and the history sheet closing (it can Clear).
    ///
    /// Same shape as `SettingsView`'s `spendTotals`/`spendLast`/`refreshSpend`, deliberately: the
    /// two surfaces read the same store and now keep it the same way.
    @State private var spendLast: FilingSpendEntry?
    @State private var spendTotals = FilingSpendTotals()
    // The model the refine button names. Read here rather than derived from the manager because
    // the button has to re-render the moment the Settings picker changes, and resolved through
    // `currentModel` at the point of use so a stored id from before a model refresh names the
    // model that will actually run.
    @AppStorage(FileSyncManager.cloudModelDefaultsKey)
    private var filingCloudModel: String = CloudFilingProtocol.defaultModel

    /// Honors Settings ▸ Accessibility ▸ Reduce motion: when true, the row-exit slides (H4) and the
    /// reclaim glow (H5) are dropped for today's instant swap. The numeric count-up is kept — it's an
    /// acceptable motion under Reduce motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The app's text size, for the provider name — a `Menu` label that must stay a `Text`.
    @Environment(\.appFontScale) private var appFontScale

    /// The active lens, resolved by the host from the selected workspace. A value, not a binding:
    /// nothing in here selects a lens any more — the workspace bar does — so a writable binding
    /// would be a write path with no writer.
    private let lens: TidyLens
    @State private var filter: TidyFilter = .all
    /// Each lens's live query, kept SEPARATELY rather than as one shared field.
    ///
    /// Not tidiness — correctness. The grammars are deliberately per-lens, so a query carried
    /// across a tab switch would change meaning silently: `kind:pdf >5mb` typed in Duplicates
    /// lands in Rename, which declares no size token, so `>5mb` degrades to free text and matches
    /// nothing. The user would see an empty Rename lens with no visible cause. Each lens keeps
    /// (and re-enters) its own query instead.
    @State private var searchQueries: [TidyLens: String] = [:]
    /// Which lenses currently have the field revealed — per-lens for the same reason.
    @State private var searchExpandedLenses: Set<TidyLens> = []
    @State private var expanded: Set<UUID> = []
    /// The group a "Find duplicates of this" handoff sent the user to, marked until they look
    /// somewhere else. A landing, not a scroll: without a mark, a reveal into a list of similar
    /// cards leaves the user to work out which one they were sent to.
    @State private var revealedGroupID: UUID?
    /// The named answer a handoff put on screen, with the query it describes — never a silently
    /// filtered-to-nothing list.
    ///
    /// It is not *cleared* by the paths that could invalidate it; it is *gated* on still applying,
    /// by `DuplicateReveal.namedAnswer`. Clearing rules need one at every write path (typing, the
    /// ✕, chip removal, a scan reset, the next handoff) and the chip-removal path was missed.
    @State private var revealLanding: DuplicateReveal.Landing?
    /// The reveal request this view has already acted on, so re-resolving on a groups change (or
    /// on any other re-render) does not re-clear a search the user has since typed.
    @State private var appliedRevealID: UUID?
    @State private var showSpendHistory = false
    /// H5 — bytes reclaimed so far this Duplicates session (view-level only; see ``ReclaimTally``).
    /// Drives the "… freed this session" count-up caption on the reclaim pill.
    @State private var reclaim = ReclaimTally()
    /// Bumped on every successful resolve to flash the reclaim pill's green glow once (H5). A token,
    /// not a Bool, so back-to-back resolves each retrigger the fade cleanly.
    @State private var reclaimFlashToken = 0
    /// True once the user has filed at least one loose file since the current Filing scan finished.
    /// Lets the empty-list state distinguish an earned "All filed" from "nothing was ever loose."
    /// Reset when a new scan starts (see `.onChange(of: isSuggestingFiles)`).
    @State private var filedThisSession = false
    /// True once the user has dismissed ("Not here") at least one suggestion this session without
    /// filing any. Lets the empty state say the scan's suggestions were cleared, rather than the
    /// misleading "Nothing loose to file" — which claims the scan found nothing when it actually did.
    /// Reset when a new scan starts.
    @State private var dismissedThisSession = false
    /// A just-made override the user can teach as a rule (G2): they filed a loose file into a folder
    /// other than the suggested home — the highest-value learning moment. Held (inline prompt shown)
    /// until they Remember it or dismiss it. Cleared when a new scan starts.
    @State private var pendingRememberPrompt: PendingRememberPrompt?
    /// A learn-by-example rule offered after the user files a loose file — turned into an editable
    /// Automation on Save. Deterministic complement to the AI backend. Held (inline prompt shown)
    /// until saved or dismissed; cleared when a new scan starts.
    @State private var pendingRuleOffer: RuleOffer?
    /// Which phrasing of the offered rule (narrower / balanced / broader) the user has selected.
    @State private var ruleVariantChoice: AutomationRuleProposer.Variant?
    /// The just-created rule ("Remember" or "Save rule"), opened in the editor right away for a
    /// review pass (Cancel keeps it as created; it stays editable under Automations). Also backs
    /// the header card's "New rule", so a blank rule and a taught one share one editor.
    @State private var reviewingAutomationRule: AutomationRule?
    /// The Automations lens's host-owned view state. It lives up here because the lens's controls
    /// now ride the shared header card: "Preview all" is rendered by this view and has to flip the
    /// lens into its results view.
    @StateObject private var automationsState = AutomationsLensState()

    private let providerName: String?
    /// The folder a rescan would target — the focused pane's current directory. Lets both lenses
    /// name the folder up front and offer to rescan when the user has navigated away from the
    /// folder the current results were scanned from.
    private let scanTargetFolder: String?
    private let onFindDuplicates: () -> Void
    private let onFindFilingSuggestions: () -> Void
    /// The same scan, but ignoring saved suggestions — see `rescanFilingButton`.
    private let onFindFilingSuggestionsFresh: () -> Void
    /// Re-derives the folder memory from the tree as it stands now — see `rescanFilingButton`.
    /// nil when this machine has no filing profile to update, which withholds the item rather than
    /// offering one that would do nothing.
    private let onUpdateFolderMemory: (() -> Void)?
    /// Opens Settings ▸ Organize, where the cloud backend is set up. Optional so the previews and
    /// the tests that mount this view without a host don't have to fake a Settings overlay; nil
    /// simply withholds the "Refine with Claude…" invitation, which is the honest outcome for a
    /// host that has no Settings to open.
    private let onConfigureCloudRefine: (() -> Void)?
    /// Kicks off a Name Normalizer scan of the focused folder (host owns the root/provider deriving).
    /// Applies the safe rename to the given risky names as one undoable batch.
    private let onNormalizeNames: ([RiskyName]) -> Void
    /// Applies whole folder rename plans. Takes the plans explicitly for the same reason
    /// `onNormalizeNames` does: the button's label counts what the action receives.
    private let onApplyRenames: ([RenamePlan]) -> Void
    /// Kicks off an Automations dry-run preview of the focused folder (host owns the root deriving).
    /// nil = all enabled rules; a rule id = just that rule.
    private let onPreviewAutomations: (UUID?) -> Void
    /// The provider root automation destinations resolve against — passed to the lens so its Browse…
    /// button anchors at the provider root (matching the preview), not the scanned subfolder.
    private let automationDestinationRoot: String?
    /// Presents a Quick Look preview for a file (routed to the same `quickLookPreview` binding the
    /// spacebar shortcut uses). nil disables the per-card Preview button.
    private let onQuickLook: ((URL) -> Void)?
    /// Builds (or rebuilds) the read-only storage picture for the focused folder — the Storage lens's
    /// analyze/re-analyze action. Host owns the root deriving.
    private let onBuildStorage: () -> Void
    /// Whether to show the source bar (provider dropdown + folder) above the lens. True only when the
    /// source rail is collapsed; when it's expanded, the rail header owns the provider dropdown, so
    /// showing it here too would name the provider twice.
    private let showSourcePicker: Bool
    /// The enabled providers the source can switch between, and the current one — the single
    /// provider choice Tidy needs (no Left/Right).
    private let providers: [CloudProvider]
    private let currentProviderId: String
    private let onSelectProvider: (String) -> Void
    private let onManageProviders: () -> Void
    /// Picks a folder and points Tidy at it as a source. nil hides "Choose Folder…".
    private let onChooseFolder: (() -> Void)?
    /// Raises the destination picker. Owned by the window rather than by this view: the Tidy rail
    /// asks for the same sheet, and two states bound to two sheets would be two pickers to keep in
    /// step. Defaults to a no-op so previews and tests can build a lens without a host.
    private let onRequestDestination: (PendingDestination) -> Void
    /// Opens two copies of a duplicate folder group in the Compare tab (keeper left, redundant right).
    private let onCompareCopies: (DuplicateCopy, DuplicateCopy) -> Void
    /// A "Find duplicates of this" handoff from a pane row: the file whose group to reveal. nil is
    /// the ordinary case — nobody has asked. See `DuplicateReveal`, which owns every decision this
    /// view makes about it.
    private let revealRequest: DuplicateRevealRequest?
    /// Called once a request has been ANSWERED (any non-waiting outcome), with its id, so the host
    /// can retire it.
    ///
    /// This is the cross-mount half of the applied-id guard, and without it the guard has a hole:
    /// `appliedRevealID` is `@State` and dies with this view, but the request lives at the app
    /// level so it survives the workspace switch that mounts the lens — the whole point — and
    /// therefore also survives every switch AFTER being answered. A round trip through Compare
    /// (which the revealed card's own "Compare copies" button takes you on) then remounts this
    /// view with the old request standing and no memory of having applied it, and the stale plan
    /// re-fires: filter reset, the user's parked query overwritten, the old group re-marked — on
    /// every return, for the rest of the session.
    private let onRevealHandled: ((UUID) -> Void)?
    /// "Find duplicates of `path`" — the same entry the pane row's context menu uses, for the
    /// `notScanned` empty state's recovery button. See `namedRevealState`.
    private let onFindDuplicatesOf: ((String) -> Void)?

    public init(
        syncManager: FileSyncManager,
        lens: TidyLens,
        providerName: String? = nil,
        scanTargetFolder: String? = nil,
        onFindDuplicates: @escaping () -> Void,
        onFindFilingSuggestions: @escaping () -> Void = {},
        onFindFilingSuggestionsFresh: @escaping () -> Void = {},
        onUpdateFolderMemory: (() -> Void)? = nil,
        onConfigureCloudRefine: (() -> Void)? = nil,
        onNormalizeNames: @escaping ([RiskyName]) -> Void = { _ in },
        onApplyRenames: @escaping ([RenamePlan]) -> Void = { _ in },
        onPreviewAutomations: @escaping (UUID?) -> Void = { _ in },
        automationDestinationRoot: String? = nil,
        onQuickLook: ((URL) -> Void)? = nil,
        onBuildStorage: @escaping () -> Void = {},
        showSourcePicker: Bool = false,
        providers: [CloudProvider] = [],
        currentProviderId: String = "",
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onManageProviders: @escaping () -> Void = {},
        onChooseFolder: (() -> Void)? = nil,
        onCompareCopies: @escaping (DuplicateCopy, DuplicateCopy) -> Void = { _, _ in },
        onRequestDestination: @escaping (PendingDestination) -> Void = { _ in },
        revealRequest: DuplicateRevealRequest? = nil,
        onRevealHandled: ((UUID) -> Void)? = nil,
        onFindDuplicatesOf: ((String) -> Void)? = nil
    ) {
        self.syncManager = syncManager
        self.lens = lens
        self.providerName = providerName
        self.scanTargetFolder = scanTargetFolder
        self.onFindDuplicates = onFindDuplicates
        self.onFindFilingSuggestions = onFindFilingSuggestions
        self.onFindFilingSuggestionsFresh = onFindFilingSuggestionsFresh
        self.onUpdateFolderMemory = onUpdateFolderMemory
        self.onConfigureCloudRefine = onConfigureCloudRefine
        self.onNormalizeNames = onNormalizeNames
        self.onApplyRenames = onApplyRenames
        self.onPreviewAutomations = onPreviewAutomations
        self.automationDestinationRoot = automationDestinationRoot
        self.onQuickLook = onQuickLook
        self.onBuildStorage = onBuildStorage
        self.showSourcePicker = showSourcePicker
        self.providers = providers
        self.currentProviderId = currentProviderId
        self.onSelectProvider = onSelectProvider
        self.onManageProviders = onManageProviders
        self.onChooseFolder = onChooseFolder
        self.onCompareCopies = onCompareCopies
        self.onRequestDestination = onRequestDestination
        self.revealRequest = revealRequest
        self.onRevealHandled = onRevealHandled
        self.onFindDuplicatesOf = onFindDuplicatesOf
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }

    /// Which of Organize's lists is on screen. Rename is no longer a place, so this is not a lens
    /// selection — see ``OrganizeFocus`` for why it is a selection rather than a Bool.
    @State private var organizeFocus: OrganizeFocus = .queue

    /// The focus actually on screen: `organizeFocus`, unless its list has emptied under it.
    private var effectiveOrganizeFocus: OrganizeFocus {
        OrganizeFocus.effective(organizeFocus, riskyNameCount: syncManager.riskyNames.count,
                                renamePlanCount: syncManager.renamePlans.count)
    }

    /// The lens whose grammar, pills, actions and content are on screen right now.
    ///
    /// `lens` is where you ARE; this is what you are LOOKING AT. They differ in exactly one case:
    /// Organize showing its risky names, which reuses `.rename`'s whole apparatus — its search
    /// grammar, its "N of M", its list — because that apparatus is still correct. What it does not
    /// reuse is the title: the header keeps saying Organize, because you have not gone anywhere.
    private var effectiveLens: TidyLens {
        (lens == .filing && effectiveOrganizeFocus == .names) ? .rename : lens
    }

    /// True when Organize is showing the rename backlog rather than the queue.
    ///
    /// Deliberately NOT a sixth `TidyLens`. The names focus borrows `.rename`'s apparatus because
    /// that apparatus already fits its rows; the rename backlog's rows are folder plans, which no
    /// existing lens describes — and a lens of its own would cost a bar segment for a finding that
    /// is absent most days. So it stays inside Organize and the content card branches on it.
    private var showingRenameBacklog: Bool {
        lens == .filing && effectiveOrganizeFocus == .renames
    }

    // MARK: Search state

    /// This lens's query. Written through to `searchQueries`, so switching tabs parks the query
    /// rather than carrying it into a grammar that would read it differently.
    private var searchText: Binding<String> {
        Binding(get: { searchQueries[effectiveLens] ?? "" }, set: { searchQueries[effectiveLens] = $0 })
    }

    private var isSearchExpanded: Binding<Bool> {
        Binding(
            get: { searchExpandedLenses.contains(effectiveLens) },
            set: { expanded in
                if expanded { searchExpandedLenses.insert(effectiveLens) } else { searchExpandedLenses.remove(effectiveLens) }
            }
        )
    }

    private var query: String { searchQueries[effectiveLens] ?? "" }
    /// True when this lens's list is narrowed by anything — the cue for the "N of M" readout.
    private var isFiltered: Bool {
        !query.isEmpty || (effectiveLens == .duplicates && filter != .all)
    }

    /// The parsed tokens of this lens's query, as chips. Each lens's own grammar answers, so a
    /// chip is only ever offered for a token that lens can actually bind.
    private var searchChips: [TokenChipsRow.Item] {
        func items<C: DimmableTokenChip>(_ chips: [C], label: (C) -> String, word: (C) -> String) -> [TokenChipsRow.Item] {
            chips.map { TokenChipsRow.Item(label: label($0), word: word($0), isActive: $0.isActive) }
        }
        switch effectiveLens {
        case .duplicates:
            return items(DuplicateSearch.chips(query), label: \.label, word: \.raw)
        case .rename:
            return items(RiskyNameSearch.chips(query), label: \.label, word: \.raw)
        case .filing where showingRenameBacklog:
            return []      // free text only — see `RenameBacklogSearch`
        case .filing:
            return items(FilingSearch.chips(query), label: \.label, word: \.raw)
        case .automations:
            return items(AutomationSearch.chips(query), label: \.label, word: \.raw)
        case .storage:
            return items(StorageSearch.chips(query), label: \.label, word: \.raw)
        }
    }

    /// A chip's ✕ edits its exact word back out of THIS lens's raw query.
    private func removeSearchChip(_ word: String) {
        searchQueries[lens] = TokenQuery.removing(query, word: word)
    }

    // MARK: Filtered rows

    /// One lens's rows after its own search, resolved ONCE per render in `body` and handed to both
    /// the header card and the content below.
    ///
    /// Two consumers, one value — and that is the safety property, not an optimization. The header
    /// counts these rows and labels a destructive button with the number ("Trash all 3"); the
    /// action iterates this same array. Recomputing either from an unfiltered source is what makes
    /// a button destroy items the user can't see.
    private struct FilteredRows {
        var duplicates: [DuplicateGroup] = []
        var risky: [RiskyName] = []
        var filing: [FilingSuggestion] = []
        var rules: [AutomationRule] = []
        var renames: [RenamePlan] = []
    }

    /// Resolves only the ACTIVE lens's rows — the other four aren't on screen, and each of these
    /// parses a query and walks a collection.
    private var filteredRows: FilteredRows {
        var rows = FilteredRows()
        switch effectiveLens {
        case .duplicates:
            let q = DuplicateSearch.parse(query)
            rows.duplicates = syncManager.duplicateGroups.filter { filter.matches($0) && q.matches($0) }
        case .rename:
            let q = RiskyNameSearch.parse(query)
            rows.risky = syncManager.riskyNames.filter { q.matches($0) }
        case .filing where showingRenameBacklog:
            rows.renames = syncManager.renamePlans.filter { RenameBacklogSearch.matches(query, $0) }
        case .filing:
            let q = FilingSearch.parse(query)
            // Filtered UPSTREAM of FilingSuggestionGrouping: the sections are derived from these
            // rows, so an emptied tier's header falls away with it instead of heading nothing.
            rows.filing = syncManager.filingSuggestions.filter { q.matches($0) }
        case .automations:
            let q = AutomationSearch.parse(query)
            rows.rules = syncManager.automationRules.filter { q.matches($0) }
        case .storage:
            break   // StorageLensView filters its own three lists from `storageQuery`
        }
        return rows
    }

    /// Storage's parsed query. Its report holds three ranked lists rather than one collection, and
    /// `StorageLensView` brings its own content card, so the query goes down and the lists are
    /// filtered there — see `StorageSearch` for why the treemap is deliberately left whole.
    private var storageQuery: StorageSearch.Query { StorageSearch.parse(query) }

    /// The counts behind Storage's "N of M": the three ranked lists, before and after the query.
    private var storageCounts: (filtered: Int, total: Int) {
        guard let report = syncManager.storageLensReport else { return (0, 0) }
        let lists = [report.largest, report.stale, report.reclaimCandidates]
        let q = storageQuery
        return (lists.reduce(0) { $0 + $1.filter { q.matches($0) }.count },
                lists.reduce(0) { $0 + $1.count })
    }

    /// Per-filter group counts for the filter menu's badges, in ONE pass over the groups (the menu
    /// used to run a full filter per TidyFilter case on every render).
    private static func filterCounts(_ groups: [DuplicateGroup]) -> [TidyFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: TidyFilter.allCases.map { ($0, 0) })
        for group in groups {
            for f in TidyFilter.allCases where f.matches(group) { counts[f, default: 0] += 1 }
        }
        return counts
    }
    private var hasResults: Bool { !syncManager.duplicateGroups.isEmpty }

    public var body: some View {
        // Resolve this lens's rows ONCE and hand the same value to the header and the content —
        // see `FilteredRows`.
        let rows = filteredRows
        return VStack(spacing: 0) {
            // The header card heads the workspace in EVERY lens and EVERY state, so its bottom
            // edge lands on 83.5 — the file pane's header/list boundary — no matter what's been
            // scanned. The `sourceBar` sits below it (and only ever appears when the source rail
            // is collapsed, i.e. when there's no pane left to line up with anyway).
            lensHeaderCard(rows: rows)
            if showSourcePicker { sourceBar }
            lensBody(rows: rows)
        }
        // `onDismiss`, because the history sheet can Clear History. Without it the setup card went
        // on quoting "last run ~$0.18" from a record the user had just erased through this very
        // sheet — the one invalidation the cached spend needed and did not have. `SettingsView`
        // presents the same sheet the same way.
        .sheet(isPresented: $showSpendHistory, onDismiss: refreshFilingSpend) { FilingSpendHistoryView() }
        // Review-after-create: the rule just learned from "Remember" (or saved from "Save rule")
        // opens in its editor so it can be checked and adjusted immediately. Cancel keeps the rule
        // exactly as created — the review is an offer, not a gate.
        .sheet(item: $reviewingAutomationRule) { rule in
            AutomationRuleEditor(
                rule: rule,
                accent: glassHue.accentColor,
                browseRoot: automationDestinationRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
                onSave: { saved in
                    syncManager.upsertAutomationRule(saved)
                    reviewingAutomationRule = nil
                },
                onCancel: { reviewingAutomationRule = nil }
            )
        }
        // A fresh scan starts a fresh session: forget any files filed against the previous results,
        // so the "All filed" terminal state is only earned by this scan's work. The search resets
        // here too — the same rule the other lenses apply just below — rather than from a SECOND
        // `isSuggestingFiles` handler further down: two handlers on one value both fired, so the
        // behaviour was right, but an editor changing "the" Organize scan-start handler would find
        // only one of them.
        .onAppear(perform: refreshFilingSpend)
        // The store's own change signal, which covers writers this view cannot enumerate — the
        // same history view presented from the SETTINGS window can Clear History, and this lens's
        // own three refresh moments (appear, scan finish, its own sheet closing) could not see it.
        // `receive(on:)` because `record` posts from off the main actor.
        .onReceive(NotificationCenter.default.publisher(for: FilingSpendStore.didChange)
            .receive(on: DispatchQueue.main)) { _ in refreshFilingSpend() }
        .onChange(of: syncManager.isSuggestingFiles) { _, isScanning in
            if isScanning {
                filedThisSession = false
                dismissedThisSession = false
                pendingRememberPrompt = nil   // a new scan retires any dangling teach prompt
                pendingRuleOffer = nil
                searchQueries[.filing] = ""
                // The finding belongs to the scan that produced it. Staying on the names list
                // across a rescan would show the previous scan's answer under the new scan's
                // header, and its query would survive into a list it no longer describes.
                organizeFocus = .queue
                searchQueries[.rename] = ""
            } else {
                // Finished: a cloud call may have recorded spend, and both the spend row and the
                // setup card quote it. Deliberately this handler's `else` rather than a second
                // `.onChange` on the same value — see the note above.
                refreshFilingSpend()
            }
        }
        // A fresh Duplicates scan starts a fresh reclaim session, so "… freed this session" only ever
        // counts the current results' work (H5). The search and the type filter reset too: either one
        // typed against the previous results silently pre-filtering (or hiding) the new scan's groups
        // is a dead end. The list lives in ``TidyScanReset`` so it can be tested — the defect was an
        // omission from it.
        .onChange(of: syncManager.isFindingDuplicates) { _, isScanning in
            if isScanning {
                TidyScanReset.duplicatesScanStarted(filter: &filter,
                                                    searchQuery: &searchQueries[.duplicates, default: ""],
                                                    reclaim: &reclaim)
                // A landing belongs to the results it landed in. Both of these name a group or a
                // file from the PREVIOUS scan, so they retire with it rather than marking a card
                // in the new results that nobody was sent to, or claiming "no duplicates of X"
                // about an answer that is being recomputed.
                revealedGroupID = nil
                revealLanding = nil
            }
        }
        // The handoff from a pane row's "Find duplicates of this".
        //
        // `.task(id:)` and not `.onChange`: this view is MOUNTED by the switch into the Duplicates
        // workspace, so for the request that caused the switch there is no change to observe — an
        // `.onChange` here would fire for every later reveal and never for the first one.
        //
        // The key carries the scan state as well as the request, which is what lets a request made
        // while a scan is running resolve when the results land (`DuplicateReveal.outcome` answers
        // `.waiting` until then). `groupCount` and `scanRoot` stand in for the results themselves:
        // mapping every group's id on each render to build a key is work per render for a signal
        // that only ever moves when a scan completes or a group resolves — and re-resolving on
        // either is harmless, because `appliedRevealID` makes applying a plan idempotent.
        .task(id: revealKey) { applyRevealRequest() }
        // Storage keeps its own reset for the same reason. Names do NOT have one here: they are
        // produced by the Filing scan now, so `isScanningNames` never flips on this path and the
        // reset rides `isSuggestingFiles` above, alongside the rest of that scan's session state.
        .onChange(of: syncManager.isBuildingStorageLens) { _, isBuilding in
            if isBuilding { searchQueries[.storage] = "" }
        }
    }

    // MARK: Header card

    /// The one header of this workspace: lens tabs and this lens's controls on row 1, what the
    /// lens found on row 2, and the search below — 81pt at rest, in every lens and every state.
    ///
    /// **This reverses `fd63c8b`'s reasoning, deliberately.** The tabs were kept off the old
    /// toolbar card precisely because that card was results-gated and would shift them down the
    /// moment a scan landed. Ungating the card is this change's premise, so that objection no
    /// longer applies: the card is here in the intro, scanning, empty and clean states too, which
    /// is exactly what lets the tabs ride it without ever moving.
    private func lensHeaderCard(rows: FilteredRows) -> some View {
        LensHeaderCard(
            searchText: searchText,
            isSearchExpanded: isSearchExpanded,
            // The backlog borrows `.filing`'s lens but not its grammar, so it cannot borrow its
            // placeholder either — that one advertises `confidence:` and `to:` tokens this list
            // does not bind, on a field that would then silently do nothing with them.
            searchPlaceholder: showingRenameBacklog
                ? "Search folders and names — PG&E, 2021…"
                : TidyLensSearch.placeholder(for: effectiveLens),
            searchHelp: showingRenameBacklog
                ? "Search the rename backlog by folder or by file name"
                : TidyLensSearch.help(for: effectiveLens),
            chips: searchChips,
            onRemoveChip: removeSearchChip,
            accent: glassHue.accentColor,
            surfaceStyle: surfaceStyle,
            level: glassLevel,
            hue: glassHue,
            tint: surfaceTint,
            title: { lensTitle },
            actions: { lensActions(rows: rows) },
            summary: { lensSummary(rows: rows) },
            trailing: { lensTrailing(rows: rows) }
        )
    }

    /// The lens's name — row 1 of the header card.
    ///
    /// This replaces the lens tabs, which moved to the window's workspace bar. Removing them
    /// would have left the column with no statement of what it is showing: the counts beneath say
    /// how many, never of what. So the row keeps its height and says the name instead.
    private var lensTitle: some View {
        // `lens`, deliberately, NOT `effectiveLens`: Organize showing its risky names is still
        // Organize. A title that flipped to "Rename" would re-announce the place this change
        // removed, and would make a filter look like a navigation.
        HStack(spacing: 4) {
            Text(lens.title)
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)
            // The lens's explanation and safety contract, one click away in EVERY state — not just
            // before the first scan, which is the only moment the empty state exists. On the
            // LEADING side because row 1's trailing half is already spoken for by the lens actions
            // and the search toggle.
            if let intro = currentLensIntro {
                LensIntroButton(intro: intro, tint: glassHue.accentColor)
            }
        }
    }

    /// The explanation for whichever lens is showing, or nil for the ones that do not have a
    /// pre-scan intro of their own (Automations authors rules rather than scanning; Rename is a
    /// facet of Organize's scan and shares its contract).
    private var currentLensIntro: LensIntro? {
        switch lens {
        case .duplicates: return LensIntros.duplicates(providerName: providerName)
        case .filing:     return LensIntros.organize(scanTargetName: scanTargetName)
        case .storage:    return LensIntros.storage(providerName: providerName)
        case .rename, .automations: return nil
        }
    }

    /// The source bar shown above the lens while the rail is collapsed: the provider dropdown (the
    /// one provider choice Tidy needs) and the folder being tidied.
    private var sourceBar: some View {
        let provider = providers.first(where: { $0.id == currentProviderId })
        return HStack(spacing: 8) {
            Text("Source")
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                // Logo outside the Menu label (a resizable image inside one balloons under fixedSize).
                if let provider {
                    ProviderLogo(provider.imageName, size: 16)
                }
                ProviderMenu(providers: providers, currentId: currentProviderId,
                             onSelect: onSelectProvider, onManage: onManageProviders,
                             onChooseFolder: onChooseFolder) {
                    Text(provider?.displayName ?? "Provider")
                        // `Text.scaledFont(_:scale:)`, not the View modifier: a `Menu` label is
                        // drawn by AppKit, which reads a Text's own font but ignores the
                        // environment one a modifier would set. See `PaneHeader.providerCapsule`.
                        .scaledFont(.system(size: 12, weight: .semibold), scale: appFontScale)
                        .contentShape(Rectangle())
                }
                .help("Switch which cloud you're tidying")
            }
            .pillSurface(.mini, tint: .secondary)
            if let folder = scanTargetFolder, !folder.isEmpty {
                Image(systemName: "chevron.right").scaledFont(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text((folder as NSString).lastPathComponent)
                    .scaledFont(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // Line this strip up with the card content below it: a card sits `cardInset` in from the
        // region edge and pads its own contents by 12, so matching both puts the text on the same
        // vertical rule. Tracks `cardInset`, not `cardGutter` — the card's offset is the inset.
        .padding(.horizontal, LiquidGlass.cardInset + 12)
        .padding(.top, LiquidGlass.cardInset)
        // Half a gutter, like everything else: the card below insets by the other half, so the
        // strip-to-card gap comes to exactly `cardGutter` (a hard-coded 2 left it at 4.5).
        .padding(.bottom, LiquidGlass.cardInset)
    }

    /// Row 1's trailing controls: this lens's actions, in the order the deck draws them (the
    /// search toggle is appended by `LensHeaderCard` itself, always last).
    ///
    /// Each lens's controls are gated on having something to act on, but the CARD is not — an
    /// empty row 1 keeps the tabs and the height exactly where they are.
    @ViewBuilder
    private func lensActions(rows: FilteredRows) -> some View {
        switch effectiveLens {
        case .duplicates:
            if hasResults, !syncManager.isFindingDuplicates {
                filterMenu
                rescanDuplicatesButton
                applyAllButton(rows.duplicates)
            }
        // Both of Organize's states, through one path — see `lensSummary` for why `.rename` reaches
        // here only as an EFFECTIVE lens.
        case .rename, .filing:
            if !syncManager.isSuggestingFiles {
                // **Rescan belongs to the SCAN, not to any one of its answers.** It used to be
                // nested inside each focus's apply gate, and so went missing in the state that
                // wants it most: file everything in the queue and Organize is left showing
                // "0 to file · 3 risky names · 126 folders to rename" with an empty row 1 — no
                // Rescan, no way to look again without leaving the lens. (Not *no* way: the
                // "All filed" empty state offers Scan again, which is why this survived. Pick the
                // names focus and even that is gone, because its list is not empty.)
                //
                // Gated on the filing scan having FINISHED once rather than on any list being
                // non-empty, which is exactly the condition under which rescanning means anything —
                // and it covers all three focuses, because all three lists are that one scan's
                // output. Before the first scan the intro state owns the invitation and this stays
                // away: a "Rescan" with nothing to re-scan is a button describing something that
                // never happened.
                if syncManager.hasSuggestedFiling {
                    folderMemoryStatus
                    rescanFilingButton
                }
                // The apply actions stay with their own list: each acts on the rows on screen, so
                // each is gated on there being some, and each is handed the FILTERED rows for the
                // reason `applyAllButton` spells out — the label counts what the action receives.
                switch effectiveOrganizeFocus {
                case .queue:
                    if hasFilingResults {
                        refineButton(rows.filing)
                        fileAllButton(rows.filing)
                    }
                case .names:
                    if !syncManager.riskyNames.isEmpty { fixAllButton(rows.risky) }
                case .renames:
                    // Gated on the backlog existing, handed what is showing: a query leaving 3 of
                    // 129 folders on screen must rename exactly those 3.
                    if !syncManager.renamePlans.isEmpty { renameAllButton(rows.renames) }
                }
            }
        case .automations:
            if !syncManager.automationRules.isEmpty {
                newRuleButton
                previewAllButton
            }
        case .storage:
            if hasStorageReport, !syncManager.isBuildingStorageLens {
                reanalyzeStorageButton
            }
        }
    }

    /// Row 2's leading content: the folder these results are for, then what this lens found.
    /// While a query is live that is the filter's READOUT — watching 12 groups → 3 and
    /// 2.1 GB → 840 MB as you type is most of the point, which is why the search field grows the
    /// card rather than swapping itself in over this row.
    ///
    /// Organize draws its readout as text rather than as pills (``SummaryRun``), because it is the
    /// one lens whose row also carries controls and the two had become indistinguishable. The other
    /// three have nothing clickable on this row, so a pill there claims nothing it cannot keep.
    @ViewBuilder
    private func lensSummary(rows: FilteredRows) -> some View {
        switch effectiveLens {
        case .duplicates:
            if hasResults { duplicatesSummary(rows.duplicates) }
        // Both of Organize's states, through one path. `.rename` reaches here only as an EFFECTIVE
        // lens, from Organize: no workspace claims it, which `WorkspaceTests` pins directly
        // (`Workspace.allCases.compactMap(\.lens)` excludes `.rename`), so `lens` is never `.rename`
        // to begin with. The other four sites in this file switch on `effectiveLens` on exactly that
        // understanding — a `lens == .filing` guard on this one alone would not make the invariant
        // any truer, it would just make this the one place that disagrees about who enforces it.
        case .rename, .filing:
            organizeSummary(rows: rows)
        case .automations:
            if !syncManager.automationRules.isEmpty { automationsSummary(rows.rules) }
        case .storage:
            if let report = syncManager.storageLensReport { storageSummary(report) }
        }
    }

    /// Organize's whole summary row: the scope the focused list was scanned from, the focus chips,
    /// then the pills that describe whichever list is on screen.
    ///
    /// **Nothing here renders while a scan runs.** Both of Organize's lists are published on
    /// *completion* — `filingSuggestions`, `filingScanFolder` and `riskyNames` all still hold the
    /// previous scan's answer mid-scan, deliberately, so a cancelled rescan leaves the old results
    /// intact. A row drawn from them during a scan is therefore last scan's numbers over this
    /// scan's spinner: "24 to file" beside a list that is still counting. The old row hid the
    /// filing pills for exactly this reason and let the risky-names chip through anyway; both are
    /// covered now, because staleness is a property of the scan, not of one chip.
    ///
    /// The scopes genuinely differ — the queue is one folder, the names are the whole provider — so
    /// each focus names its own rather than one claiming the other's.
    @ViewBuilder
    private func organizeSummary(rows: FilteredRows) -> some View {
        let chips = OrganizeFocus.chips(queueCount: syncManager.filingSuggestions.count,
                                        riskyNameCount: syncManager.riskyNames.count,
                                        renamePlanCount: syncManager.renamePlans.count)
        // No second `chips.isEmpty` gate: with the scope chip moved inside the branches below,
        // "nothing to report" already renders nothing — an empty `chips` draws no capsules, and
        // both branches are gated on having a list to describe. A guard that cannot change the
        // output is the same kind of thing as a test that cannot fail.
        if !syncManager.isSuggestingFiles {
            ForEach(chips) { focus in
                // A lone chip is a statement, not a choice: with nothing to switch to it must not
                // look clickable, which is exactly what the un-gated "to file" pill always was.
                organizeFocusChip(focus, isInteractive: chips.count > 1)
            }
            // The scope belongs to the FOCUSED list, so it sits with that list's readout rather than
            // leading the row. Leading, it read as qualifying whatever came next — and what comes
            // next is the other focus's chip, which it does not scope: on the names focus the row
            // said "iCloud Drive · 24 to file", and those 24 are the queue's, scoped to one folder
            // inside it. Reading order is now navigation first, then "here is what you are looking
            // at, and where it came from".
            //
            // The divider ahead of it is where the row changes from controls to prose. See
            // ``SummaryRun`` for the rule it draws.
            switch effectiveOrganizeFocus {
            case .queue:
                if hasFilingResults {
                    SummaryZoneDivider()
                    scannedFolderChip(syncManager.filingScanFolder)
                    filingSummary(rows.filing)
                }
            case .names:
                if syncManager.hasScannedNames {
                    SummaryZoneDivider()
                    scannedFolderChip(syncManager.nameScanRoot?.path)
                    renameSummary(rows.risky)
                }
            case .renames:
                // Scoped to the whole provider, like the names finding and unlike the queue — the
                // planner reads the folder profile, which describes the tree rather than one folder.
                // Named from the FILING scan's own root rather than the name scan's: the plans come
                // off that walk, and the name scan's root is only set when a provider was passed in
                // for the names check, so borrowing it would leave this chip blank or, worse,
                // pointing at a previous scan.
                SummaryZoneDivider()
                scannedFolderChip(syncManager.filingLastProviderRoot)
                // The FILTERED plans, like the queue's readout beside it and unlike the chip that
                // got you here: a chip is a signpost and counts its whole list, a readout describes
                // the rows on screen. Typing `PG&E` should watch this fall from 1,192 renames to
                // the eleven it left showing.
                renameBacklogSummary(rows.renames)
            }
        }
    }

    /// One focus chip.
    ///
    /// **A finding, not a category.** The names chip carries its own count, wears caution rather
    /// than the accent — it reports a condition, it does not offer a filter — and at zero it is
    /// *absent*, not greyed and not showing "0". That absence is the whole argument for folding
    /// Rename in here rather than giving it a tab: cloud-hostile names are something you hit a few
    /// times a year, so a permanent tab spent bar width every day to serve a rare event, and —
    /// worse — a tab you have to remember to visit is a check nobody runs. Reporting beats asking.
    ///
    /// Selection is a **ring**, not a chevron. A chevron says "this expands and collapses", which is
    /// what one Bool did; these are peers, and exactly one is always on. The ring is the same
    /// affordance the focused pane's provider capsule wears, drawn the same way — an `.overlay`,
    /// which takes its size from the host and gives none back, so it cannot push this row out of the
    /// header's pinned height.
    @ViewBuilder
    private func organizeFocusChip(_ focus: OrganizeFocus, isInteractive: Bool) -> some View {
        let count = OrganizeFocus.count(focus,
                                        queueCount: syncManager.filingSuggestions.count,
                                        riskyNameCount: syncManager.riskyNames.count,
                                        renamePlanCount: syncManager.renamePlans.count)
        let isSelected = effectiveOrganizeFocus == focus
        let pill = StatPill(count: count,
                            label: focus.label(count: count),
                            color: focus == .queue ? SemanticColor.info : SemanticColor.caution,
                            systemImage: Self.focusSymbol(focus))
        if isInteractive {
            Button {
                // A radio member, so re-picking the one already on screen is a no-op — not an
                // animated transition from a list to itself, which is what an unconditional
                // assignment inside `withAnimation` schedules.
                guard effectiveOrganizeFocus != focus else { return }
                withAnimation(listSettle) { organizeFocus = focus }
            } label: {
                pill.overlay {
                    if isSelected { Capsule().strokeBorder(glassHue.accentColor, lineWidth: 2) }
                }
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help(focusHelp(focus, count: count))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        } else {
            // Alone, the chip is what it has always been: a plain count pill, no ring and no
            // hover, because there is nowhere else to go.
            pill
        }
    }

    /// The glyph each focus wears. A `switch` rather than a ternary because there are three of
    /// them now, and a ternary that reads "queue or not-queue" would give the rename backlog the
    /// names finding's I-beam.
    ///
    /// **The backlog's glyph is not `textformat.123`.** That symbol draws the literal digits `123`,
    /// so beside its own count the chip rendered as "123 126 folders to rename" and the first
    /// question it drew was which of the two numbers was real. A glyph next to a number may not be
    /// a number; `folder.badge.gearshape` says the same thing — a folder that needs work done to it
    /// — without competing with the count it sits beside.
    static func focusSymbol(_ focus: OrganizeFocus) -> String {
        switch focus {
        case .queue: return "doc"
        case .names: return "character.cursor.ibeam"
        case .renames: return "folder.badge.gearshape"
        }
    }

    /// Organize's readout while the rename backlog is on screen: what the listed plans would do,
    /// **in files**, since the chip beside it counts folders and nothing renames a folder.
    ///
    /// This is the answer to the one question "126 folders to rename" invites and cannot answer. A
    /// backlog that size is overwhelmingly zero-padding, and `1,192 renames · 1,134 to pad` says so
    /// at a glance where the chip alone reads as 126 unspecified changes.
    ///
    /// The headline is a `SummaryRun` and the kinds behind it are prose — see
    /// ``RenameBacklogTally/breakdown`` for why a breakdown of one total must not be four more
    /// badges beside it.
    @ViewBuilder
    private func renameBacklogSummary(_ plans: [RenamePlan]) -> some View {
        let tally = RenameBacklogTally(plans)
        SummaryRun(count: tally.renames, label: tally.renames == 1 ? "rename" : "renames",
                   color: SemanticColor.info, systemImage: "pencil")
            .help("Every file the listed folders would rename — one undoable change per folder.")
        if !tally.breakdown.isEmpty {
            Text(tally.breakdown)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .help("“To pad” only adds a leading zero — “4. Apr 2021.pdf” becomes "
                      + "“04. Apr 2021.pdf”. “To name” gives a raw name a slot it did not have. "
                      + "“To reshuffle” moves an already-correct name to make room for one of them, "
                      + "and is the only kind here that touches a file that was already right. "
                      + "“Left alone” is what the pass declined to rename; open a folder to read why.")
        }
    }

    /// What each chip promises. Written to read correctly whether or not it is the selected one —
    /// the selected state is carried by the ring and by `.isSelected`, not by swapping the words.
    private func focusHelp(_ focus: OrganizeFocus, count: Int) -> String {
        switch focus {
        case .queue:
            return "The filing queue — \(count) loose file\(count == 1 ? "" : "s") this scan found, "
                + "and where they belong."
        case .names:
            return "\(count) name\(count == 1 ? "" : "s") this provider will not accept, found on "
                + "the same scan. Shows the proposed fixes."
        case .renames:
            // Says "the files inside them" outright. The count is folders — the unit of review and
            // of apply — and read alone the label invites exactly one wrong reading, that the
            // folders themselves get renamed.
            return "\(count) folder\(count == 1 ? "" : "s") that drifted from its own naming "
                + "convention. Shows what renaming the files inside them would do — mostly padding "
                + "numbers out with a leading zero."
        }
    }

    /// Row 2's trailing edge: "N of M" whenever this lens's list is narrowed, so a shortened list
    /// always reads as a filtered view rather than as the whole result.
    @ViewBuilder
    private func lensTrailing(rows: FilteredRows) -> some View {
        if isFiltered {
            switch effectiveLens {
            case .duplicates: ofMLabel(rows.duplicates.count, syncManager.duplicateGroups.count)
            case .rename: ofMLabel(rows.risky.count, syncManager.riskyNames.count)
            case .filing where showingRenameBacklog:
                // The backlog's own numbers. Left as the queue's, this said "3 of 24" about a list
                // that is not on screen while the backlog sat under it unfiltered.
                ofMLabel(rows.renames.count, syncManager.renamePlans.count)
            case .filing: ofMLabel(rows.filing.count, syncManager.filingSuggestions.count)
            case .automations: ofMLabel(rows.rules.count, syncManager.automationRules.count)
            case .storage:
                let counts = storageCounts
                ofMLabel(counts.filtered, counts.total)
            }
        }
    }

    private func ofMLabel(_ shown: Int, _ total: Int) -> some View {
        Text("\(shown) of \(total)")
            .scaledFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel("Showing \(shown) of \(total)")
    }

    @ViewBuilder
    private func lensBody(rows: FilteredRows) -> some View {
        Group {
            if lens == .storage {
                // Storage, folded in as a read-only lens: it brings its own CONTENT card (its
                // toolbar card is gone — the shared header above replaced it), so it renders in
                // place of Tidy's content card.
                StorageLensView(
                    syncManager: syncManager,
                    providerName: providerName,
                    query: storageQuery,
                    onBuild: onBuildStorage,
                    onReveal: { path in
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    },
                    onQuickLook: onQuickLook.map { ql in { path in ql(URL(fileURLWithPath: path)) } }
                )
            } else {
                contentCard(rows: rows)
            }
        }
    }

    // MARK: Row-exit motion (H4)

    /// The removal transition for the card lists: rows slide out to the leading edge and fade, so a
    /// destructive or moving action reads as a thing that happened rather than a silent swap. Insertion
    /// stays `.identity` — freshly scanned cards should just be there, not animate in.
    private var cardRemoval: AnyTransition {
        .asymmetric(insertion: .identity,
                    removal: .opacity.combined(with: .move(edge: .leading)))
    }

    /// The animation that settles the list as a row leaves — nil under Reduce motion, which restores
    /// today's instant swap (the `.transition` only fires inside an animated transaction).
    private var listSettle: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    /// The membership token the card lists animate on.
    ///
    /// The lists want to animate exactly when their row IDENTITIES change — not when a keeper pick
    /// or an expand/collapse rewrites a row in place. Both call sites expressed that as
    /// `value: rows.map(\.id)`, which is correct and allocates a fresh array of every id on every
    /// render just to be compared and thrown away. This compares the same thing over the array the
    /// view is already holding: no allocation, and the count check settles the common case before
    /// a single id is looked at.
    struct RowIdentities<Row: Identifiable>: Equatable where Row.ID: Equatable {
        let rows: [Row]

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.rows.count == rhs.rows.count else { return false }
            for (a, b) in zip(lhs.rows, rhs.rows) where a.id != b.id { return false }
            return true
        }
    }

    // MARK: Filing toolbar

    private var hasFilingResults: Bool { !syncManager.filingSuggestions.isEmpty }

    /// Re-reads the recorded cloud spend. See ``spendLast`` for why it is read here rather than in
    /// `body`, and for the three moments this is called from.
    private func refreshFilingSpend() {
        spendLast = FilingSpendStore.last()
        spendTotals = FilingSpendStore.totals()
    }

    private var filingSpendRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud").scaledFont(.system(size: 10))
            if let last = spendLast {
                Text("Last cloud scan: \(FilingSpendFormat.model(last.model)) · \(last.fileCount) files · \(FilingSpendFormat.tokens(last.totalTokens)) · \(FilingSpendFormat.cost(last.estimatedCostUSD))")
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("Total \(FilingSpendFormat.cost(spendTotals.costUSD))")
            Button("History") { showSpendHistory = true }.controlSize(.mini)
        }
        .scaledFont(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    /// "File all N confident", scoped to the FILTERED rows.
    ///
    /// `batch` is derived from the rows on screen and used for BOTH the count in the label and the
    /// collection the action files — one value, passed to `applyRecommendedFiling`, which requires
    /// it. A query leaving 3 of 12 makes this read "File all 3 confident" and file exactly those.
    @ViewBuilder
    private func fileAllButton(_ filing: [FilingSuggestion]) -> some View {
        let batch = filing.filter { $0.isBatchEligible }
        if !batch.isEmpty {
            Button { applyRecommendedFiling(batch) } label: {
                Label("File all \(batch.count) confident", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .chromeHover()
            .controlSize(.small)
            .disabled(syncManager.isSuggestingFiles)
            .help("Files the \(batch.count) name-matched suggestion\(batch.count == 1 ? "" : "s") with a confident home"
                  + (isFiltered ? " among the \(filing.count) your search left showing" : "")
                  + ". Content- and AI-based picks stay for you to review; every move undoes with ⌘Z.")
        }
    }

    /// "Refine N with Opus" — Organize's opt-in second pass.
    ///
    /// The scan that produced these rows was free and on-device. This is the only control in the
    /// lens that can spend money, and it says so three ways before it does: it names the model it
    /// will use, it names how many files it will send, and the click itself raises the existing
    /// spend pre-flight with a real estimate. Nothing here quotes a price — the estimate needs the
    /// taxonomy and the token count, which the pre-flight has and a toolbar button does not, and a
    /// figure invented here would be the one the user remembered.
    ///
    /// `scope` is the FILTERED rows, and the count is derived from it, for the same reason
    /// `fileAllButton` does it: a paid action must send exactly what it counted. A query leaving
    /// 3 of 12 makes this read "Refine 3 with Opus" and send exactly those three.
    ///
    /// When cloud isn't set up the button becomes the invitation instead — same slot, same words
    /// up to the ellipsis, opening Settings ▸ Organize. Hiding it there would mean the better
    /// answer is only discoverable by someone who already knew to go looking in Settings.
    ///
    /// **The branch is `filingCloudRefineAvailable` — is a key stored, not the cloud toggle.**
    /// With cloud switched on and nothing stored, a toggle-based branch put "Refine 2 with Opus"
    /// on a button that would run the same on-device model the scan already ran. The invitation is
    /// the correct control for that state: it opens the Settings tab holding the missing key row.
    /// It is deliberately NOT the resolved route — that answer costs a Keychain decrypt, and this
    /// is read on every render including every keystroke in the search field.
    ///
    /// **Shown only when it could actually run** (`canRefineFilingSuggestions`), with the
    /// in-flight case as the one exception, since that property goes false while a pass runs.
    /// Without the check, switching off on-device AI left a permanently disabled button behind,
    /// wearing a tooltip that promised to re-ask Claude.
    @ViewBuilder
    private func refineButton(_ scope: [FilingSuggestion]) -> some View {
        let canRun = syncManager.canRefineFilingSuggestions || syncManager.isRefiningFilingSuggestions
        if syncManager.filingCloudRefineAvailable, canRun {
            let batch = syncManager.filingSuggestionsEligibleForRefine(scope)
            if !batch.isEmpty || syncManager.isRefiningFilingSuggestions {
                Button { refineFilingSuggestions(batch) } label: {
                    if syncManager.isRefiningFilingSuggestions {
                        Label("Refining…", systemImage: "sparkles")
                    } else {
                        Label("Refine \(batch.count) with \(FilingSpendFormat.model(refineModelName))",
                              systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .chromeHover()
                .controlSize(.small)
                // `canRefineFilingSuggestions` is false while a pass runs — it reads the same
                // in-flight token — so this is the whole condition, not half of it.
                .disabled(!syncManager.canRefineFilingSuggestions)
                .help(refineButtonHelp(count: batch.count))
            }
        } else if syncManager.canRefineFilingSuggestions, let configure = onConfigureCloudRefine {
            Button(action: configure) {
                Label("Refine with Claude…", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .chromeHover()
            .controlSize(.small)
            .help("These suggestions came from the free on-device pass. Set up Claude in "
                  + "Settings ▸ Organize to re-ask a stronger model about them — billed to your "
                  + "own API key, and never used by a scan.")
        }
    }

    /// The model id a refine pass would name — the Settings picker's value, resolved the same way
    /// `CloudFilingClassifier` resolves it so the button cannot name one model and send another.
    private var refineModelName: String {
        CloudFilingProtocol.currentModel(for: filingCloudModel)
    }

    /// Split out of the `.help` modifier, not for tidiness: inline, the interpolation plus the
    /// pluralization plus the `isFiltered` branch put the whole `Button` expression past what the
    /// type-checker will solve in reasonable time, and the build fails with no other diagnostic.
    private func refineButtonHelp(count: Int) -> String {
        let model = FilingSpendFormat.model(refineModelName)
        let files = count == 1 ? "1 suggestion" : "\(count) suggestions"
        let scope = isFiltered ? " — the ones your search left showing" : ""
        return "Re-asks Claude (\(model)) about \(files)\(scope). This one is billed to your API "
            + "key; you'll see an estimate first. Suggestions your own rules steered are left "
            + "alone, and files already answered by this model aren't sent again."
    }

    /// Runs the refine pass over `batch`. Unstructured on purpose: this is a user-initiated round
    /// trip that must survive the view re-rendering underneath it (the manager republishes the
    /// suggestions when it lands), and the manager's own in-flight token — not this Task — is what
    /// makes a second click a no-op.
    private func refineFilingSuggestions(_ batch: [FilingSuggestion]) {
        guard !batch.isEmpty else { return }
        Task {
            await syncManager.refineFilingSuggestions(batch)
            // The pass may have spent; the spend row above the list reads from a cached snapshot.
            refreshFilingSpend()
        }
    }

    /// The folder a rescan would walk (the focused pane's current directory), by leaf name.
    private var scanTargetName: String {
        guard let f = scanTargetFolder, !f.isEmpty else { return "this folder" }
        return (f as NSString).lastPathComponent
    }

    private func standardizedPath(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.path
    }

    /// True once the focused pane has moved to a different folder than the one `scannedRoot` was
    /// walked from — the cue to offer scanning the new folder.
    private func targetMoved(from scannedRoot: String?) -> Bool {
        guard let target = scanTargetFolder, !target.isEmpty, let scanned = scannedRoot else { return false }
        return standardizedPath(target) != standardizedPath(scanned)
    }

    /// A rescan button that becomes a prominent "Scan '<folder>'" once the user has navigated
    /// away, so navigate-then-rescan is one obvious click. Shared shape for both lenses.
    @ViewBuilder
    private func rescanButton(moved: Bool, movedIcon: String, disabled: Bool, action: @escaping () -> Void, movedHelp: String) -> some View {
        if moved {
            Button(action: action) { Label("Scan “\(scanTargetName)”", systemImage: movedIcon) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .chromeHover()
                .disabled(disabled).help(movedHelp)
        } else {
            Button(action: action) { Label("Rescan", systemImage: "arrow.clockwise") }
                .chromeButtonStyle(glassLevel).controlSize(.small)
                .chromeHover()
                .disabled(disabled).help("Scan this folder again")
        }
    }

    /// What the folder-memory re-survey is doing, or what it found.
    ///
    /// **The commonest outcome is that nothing changed, and that has to be visible.** A menu item
    /// that reads only a few folder mtimes and writes nothing looks broken otherwise — the user
    /// clicks it, the tree is already current, and there is no evidence it ran at all.
    @ViewBuilder
    private var folderMemoryStatus: some View {
        if let status = syncManager.filingSurveyLifecycle.status,
           syncManager.filingSurveyLifecycle.isRunning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(status)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let report = syncManager.filingSurveyReport {
            Text(report.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("\(report.foldersLearned) folders have learned content from the documents already filed in them.")
        }
    }

    /// Organize's rescan, with the ignore-saved-suggestions variant hung off it.
    ///
    /// A split control rather than a second button: rescanning is the common act and asking afresh
    /// is the exception, so the exception belongs one click deeper — and, on the cloud backend,
    /// it is the one that spends money, which is not something to put under an identical-looking
    /// button beside the free one. When the user has navigated away the control becomes the
    /// prominent "Scan '<folder>'" call to action instead, where a menu would only be in the way:
    /// there are no saved suggestions for a folder that has not been scanned yet.
    @ViewBuilder
    private var rescanFilingButton: some View {
        if targetMoved(from: syncManager.filingScanFolder) {
            rescanButton(moved: true, movedIcon: FilingGlyph.lens,
                         disabled: syncManager.isSuggestingFiles,
                         action: onFindFilingSuggestions,
                         movedHelp: "Suggest homes for “\(scanTargetName)” — the folder now focused above")
        } else {
            Menu {
                Button {
                    onFindFilingSuggestionsFresh()
                } label: {
                    Label("Ignore saved suggestions", systemImage: "arrow.clockwise.circle")
                }
                .help("Ask the model about every file again, even the ones that haven’t changed. With Claude selected this re-runs the paid classification for the whole folder.")
                if let onUpdateFolderMemory {
                    Divider()
                    Button {
                        onUpdateFolderMemory()
                    } label: {
                        Label("Update folder memory", systemImage: "brain")
                    }
                    .disabled(syncManager.filingSurveyLifecycle.isRunning)
                    .help("Learn what your folders have been given since the last survey, so folders "
                          + "you have added recently can be suggested. Reads only the documents that changed.")
                }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            } primaryAction: {
                onFindFilingSuggestions()
            }
            .menuStyle(.button)
            .chromeButtonStyle(glassLevel)
            .controlSize(.small)
            .chromeHover()
            .fixedSize()
            .disabled(syncManager.isSuggestingFiles)
            .help("Scan this folder again, reusing suggestions for files that haven’t changed")
        }
    }

    private var rescanDuplicatesButton: some View {
        rescanButton(moved: targetMoved(from: syncManager.duplicateScanRoot),
                     movedIcon: "wand.and.stars", disabled: syncManager.isFindingDuplicates,
                     action: onFindDuplicates,
                     movedHelp: "Find duplicates in “\(scanTargetName)” — the folder now focused above")
    }

    /// A leading chip naming the folder a lens's current results were scanned from.
    @ViewBuilder
    private func scannedFolderChip(_ root: String?) -> some View {
        if let root {
            let name = (root as NSString).lastPathComponent
            Label(name, systemImage: "folder")
                .scaledFont(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("These results are for “\(name)”")
        }
    }

    /// Organize's readout — the queue's breakdown, over the rows on screen. **This is the filter's
    /// readout**: watching 24 → 3 and `ready` fall away as you type is most of the point, which is
    /// why the search field grows the card rather than swapping itself in over this row.
    ///
    /// Drawn as `SummaryRun`s and not as pills, because none of them is clickable and every one of
    /// them used to look it. See ``SummaryRun``.
    ///
    /// The "to file" total and the folder chip both left this Group when the focus chips arrived:
    /// the total is the queue chip's number now (a signpost, so it counts the whole list rather than
    /// the filtered view — see ``OrganizeFocus/count(_:queueCount:riskyNameCount:)``), and the scope
    /// leads the row because Organize's two states scan different ones.
    private func filingSummary(_ filing: [FilingSuggestion]) -> some View {
        let ready = filing.filter { $0.hasConfidentHome }.count
        let newFolders = filing.filter { $0.best?.isNew == true }.count
        let unsure = filing.count - ready
        return Group {
            // "ready" = the showing files with a confident home now.
            SummaryRun(count: ready, label: "ready", color: SemanticColor.success, systemImage: "checkmark.circle")
            if newFolders > 0 {
                SummaryRun(count: newFolders, label: newFolders == 1 ? "new folder" : "new folders",
                           color: glassHue.accentColor, systemImage: "folder.badge.plus")
            }
            if unsure > 0 {
                SummaryRun(count: unsure, label: "unsure", color: SemanticColor.caution, systemImage: "questionmark.circle")
            }
            // A scan-level fact, like Duplicates' `need review` / `skipped` — deliberately NOT
            // recounted over the filtered rows. It describes what the scan cost, and narrowing the
            // search does not retroactively change how many files the model was asked about.
            if let reuse = syncManager.filingLastCacheReuse, reuse.reused > 0 {
                SummaryRun(count: reuse.reused, label: "reused", color: .secondary,
                           systemImage: "clock.arrow.circlepath")
                    .help(reuseHelp(reuse))
            }
            // Durable evidence that the paid pass ran, and what it bought. The banner says so once
            // and goes away; this stays with the rows it describes. Pass-level like `reused` and
            // for the same reason — narrowing the search does not change how many files were sent.
            if let refine = syncManager.filingLastRefine {
                SummaryRun(count: refine.changed, label: "refined", color: glassHue.accentColor,
                           systemImage: "sparkles")
                    .help(refineHelp(refine))
            }
        }
    }

    /// What the refine pass actually did, in the terms that matter: how many were sent (the part
    /// that was billed), how many came back free from the cache, and how many homes it moved. The
    /// pill counts `changed` rather than `asked` because that is the number the user is entitled
    /// to judge the spend by — "refined 40" with nothing moved would read as forty improvements.
    private func refineHelp(_ refine: FileSyncManager.FilingRefineSummary) -> String {
        let sent = refine.classified == 0
            ? "Nothing needed sending — every answer came from the cache."
            : (refine.classified == 1 ? "1 file was sent to Claude."
                                      : "\(refine.classified) files were sent to Claude.")
        let reused = refine.reused == 0 ? ""
            : " \(refine.reused) had already been answered by this model, so they cost nothing."
        let changed = refine.changed == 0
            ? "No suggestion changed — the free pass had already found the same homes."
            : (refine.changed == 1 ? "1 suggestion moved to a better home."
                                   : "\(refine.changed) suggestions moved to better homes.")
        return "Asked about \(refine.asked). \(sent)\(reused) \(changed)"
    }

    /// Spells out what "reused" bought, in the terms the user cares about — the model wasn't asked,
    /// so with Claude selected it wasn't billed. Kept out of the pill itself because the number is
    /// the glanceable part and this is the explanation you go looking for.
    private func reuseHelp(_ reuse: FileSyncManager.FilingCacheReuse) -> String {
        // Both halves of the first sentence agree in number — "1 file … its suggestion was",
        // "N files … their suggestions were". The verb used to stay singular for any N.
        let reused = reuse.reused == 1
            ? "1 file hadn’t changed since the last scan, so its suggestion was reused"
            : "\(reuse.reused) files hadn’t changed since the last scan, so their suggestions were reused"
        let classified = reuse.classified == 0
            ? "Nothing needed a fresh answer."
            : (reuse.classified == 1 ? "1 file was newly classified."
                                     : "\(reuse.classified) files were newly classified.")
        return "\(reused) instead of asking the "
            + "model again — with Claude selected, that part of the scan cost nothing. \(classified) "
            + "Use Rescan ▸ Ignore saved suggestions to ask afresh."
    }

    /// Duplicates' pills. `groups` / `redundant` / `reclaimable` recount over the FILTERED rows, so
    /// typing `kind:pdf` visibly rolls 12 groups → 3 and 2.1 GB → 840 MB. `need review` and
    /// `skipped` stay scan-level facts: they describe what the scan did, not what the query kept.
    private func duplicatesSummary(_ groups: [DuplicateGroup]) -> some View {
        let reclaimable = groups.filter { $0.isRecommendedForBatch }.reduce(0) { $0 + $1.reclaimableBytes }
        let redundant = groups.reduce(0) { $0 + $1.recommendedRemovalPaths.count }
        let needsReview = groups.filter { $0.matchType.kind == .nameOnly }.count
        return Group {
            scannedFolderChip(syncManager.duplicateScanRoot)
            StatPill(count: groups.count, label: "groups", color: SemanticColor.info, systemImage: "square.on.square")
            ReclaimPill(reclaimableBytes: reclaimable,
                        freedCaption: reclaim.freedCaption(FileSyncManager.formatBytes(reclaim.totalBytes)),
                        flashToken: reclaimFlashToken,
                        reduceMotion: reduceMotion)
            StatPill(count: redundant, label: "redundant", color: .secondary, systemImage: "doc.on.doc")
            if needsReview > 0 {
                StatPill(count: needsReview, label: "need review", color: SemanticColor.caution, systemImage: "exclamationmark.triangle")
            }
            // Scan-level counterpart to the per-group unverified note (TidyUnverifiedNote): files
            // the scan never content-verified at all, so identical copies among them are absent
            // from every group below — without this pill the scan is silently blind to them. Not
            // filtered: these files aren't rows, so no query can include or exclude them.
            if let skipNote = TidyScanSkipNote.text(syncManager.duplicateScanSkips) {
                StatPill(count: syncManager.duplicateScanSkips.total, label: "skipped",
                         color: SemanticColor.warning, systemImage: "eye.slash")
                    .help(skipNote)
                    .accessibilityLabel(skipNote)
            }
        }
    }

    /// The risky-names pills, over the rows on screen.
    ///
    /// No count pill: the names focus chip sits in this same row and carries it. Two capsules
    /// reading "17 risky names" side by side is what this row looked like the moment that chip
    /// arrived — and the chip has to be the one that stays, because it is also the control that
    /// gets you back to the queue. The scope chip ahead of the focus chips names the PROVIDER root
    /// rather than Organize's inbox, deliberately: the names come from the whole provider while the
    /// queue is one folder, and that difference is worth stating rather than hiding.
    private func renameSummary(_ risky: [RiskyName]) -> some View {
        let folders = risky.filter(\.isDirectory).count
        return Group {
            if folders > 0 {
                SummaryRun(count: folders, label: folders == 1 ? "folder" : "folders",
                           color: .secondary, systemImage: "folder")
            }
        }
    }

    /// Automations' pills, over the filtered rules. The folder chip names the focused folder — the
    /// one a preview would run over — since rules aren't scanned FROM anywhere.
    private func automationsSummary(_ rules: [AutomationRule]) -> some View {
        let enabled = rules.filter(\.enabled).count
        return Group {
            scannedFolderChip(scanTargetFolder)
            StatPill(count: rules.count, label: rules.count == 1 ? "automation" : "automations",
                     color: glassHue.accentColor, systemImage: AutomationsGlyph.lens)
            StatPill(count: enabled, label: "enabled", color: SemanticColor.success, systemImage: "checkmark.circle")
        }
    }

    /// Storage's pills. The total is the whole scanned tree's — a query filters the ranked lists,
    /// never the tree's size, so this figure must not move when you type.
    private func storageSummary(_ report: StorageLensReport) -> some View {
        Group {
            scannedFolderChip(syncManager.storageLensRoot?.path)
            Pill(.standard, tint: glassHue.accentColor, systemImage: "externaldrive",
                 text: "\(FileSyncManager.formatBytes(report.totalBytes)) total")
            StatPill(count: report.largest.count, label: "largest", color: SemanticColor.info, systemImage: "arrow.up.circle")
            if !report.reclaimCandidates.isEmpty {
                StatPill(count: report.reclaimCandidates.count, label: "to reclaim",
                         color: SemanticColor.success, systemImage: "internaldrive")
            }
            storageFreshnessPill
        }
    }

    /// How old the numbers are, shown only for a report that came off disk.
    ///
    /// Restoring Storage means the first thing you see after a launch is a set of figures produced
    /// at some earlier time, and every one of them — total size, largest files, reclaim candidates
    /// — may have moved since. Saying so is the condition on which restoring is honest at all.
    /// A report produced by a scan in this session needs no such marker: you watched it happen.
    ///
    /// `ScanFreshness` supplies the wording, the one-hour stale threshold, and — the part that
    /// matters most — the SPOKEN form, which says "may be out of date" outright. Colour alone
    /// carrying a staleness warning is exactly what the contrast work around this vocabulary
    /// exists to avoid.
    @ViewBuilder
    private var storageFreshnessPill: some View {
        if syncManager.storageLensLifecycle.isRestored,
           let completedAt = syncManager.storageLensLifecycle.completedAt {
            // Scoped tightly to the pill, following the differences bar: a `TimelineView` re-runs
            // the closure it wraps, so wrapping any more of the header than the run whose text
            // actually changes would re-render the whole row every 30 seconds for nothing.
            TimelineView(.periodic(from: completedAt, by: 30)) { context in
                freshnessPill(ScanFreshness.describe(scanDate: completedAt, now: context.date))
            }
        }
    }

    private func freshnessPill(_ freshness: ScanFreshness.Result) -> some View {
        Pill(.standard,
             tint: freshness.isStale ? SemanticColor.warning : .secondary,
             systemImage: "clock.arrow.circlepath",
             text: freshness.text)
            // "Rescan", because that is what the control beside this pill is labelled — this used
            // to say "Re-analyze", a verb no on-screen control carries.
            .help("These are the numbers from your last analysis of this folder, not a live reading. Rescan for current ones.")
            .accessibilityLabel("Saved report, \(freshness.spoken)")
    }

    /// Credits a completed resolve to the session tally and flashes the reclaim pill (H5). Called only
    /// on success, with the bytes actually reclaimed, so the count-up is honest.
    private func creditReclaim(_ bytes: Int) {
        guard bytes > 0 else { return }
        reclaim.credit(bytes)
        reclaimFlashToken &+= 1
    }

    private var filterMenu: some View {
        Menu {
            // NOTE: a Menu's content builder is NOT lazy — it's a non-escaping closure that
            // runs on every render — so this single pass over the groups executes per render,
            // including the ones a merge's progress publishes trigger. That's accepted: groups
            // number in the tens-to-hundreds and each check is a flag test, so the pass is
            // microseconds (unlike the Compare header's counts over up to ~40k differences,
            // which are memoized in DisplayRows for exactly this reason). Counts cover ALL
            // groups, not the search-narrowed `dupGroups`, so a badge never reads zero for a
            // filter that would reveal rows once picked.
            let counts = Self.filterCounts(syncManager.duplicateGroups)
            Picker("Filter", selection: $filter) {
                ForEach(TidyFilter.allCases) { f in
                    Text("\(f.label) (\(counts[f] ?? 0))").tag(f)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(filter.label, systemImage: "line.3.horizontal.decrease.circle")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// "Apply N recommended", scoped to the FILTERED groups.
    ///
    /// `batch` is one value: the label counts it and `applyRecommended` iterates it. This is the
    /// dangerous button — a query leaving 3 of 8 eligible groups must trash exactly those 3, and a
    /// label that said 3 while the action recomputed 8 from `duplicateGroups` would destroy 5
    /// copies the user never saw. `applyRecommendedDuplicates` requires the scope for that reason.
    @ViewBuilder
    private func applyAllButton(_ groups: [DuplicateGroup]) -> some View {
        let batch = groups.filter { $0.isRecommendedForBatch }
        if !batch.isEmpty {
            Button { applyRecommended(batch) } label: {
                Label("Apply \(batch.count) recommended", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .chromeHover()
            .controlSize(.small)
            .disabled(syncManager.isFindingDuplicates)
            .help("Moves the redundant copies of \(batch.count) byte-identical group\(batch.count == 1 ? "" : "s")"
                  + (isFiltered ? " — the ones your search left showing —" : "")
                  + " to the Trash. Undo with ⌘Z.")
        }
    }

    /// "Rename all N", over every planned folder.
    ///
    /// Unscoped by any query on purpose, and the label says **folders** rather than files: the unit
    /// of apply is the folder plan, and there is no rename-backlog search grammar for a filtered
    /// count to disagree with. `plans` is the same value the label counts and the action applies —
    /// the property `applyAllButton` above exists to preserve.
    @ViewBuilder
    private func renameAllButton(_ plans: [RenamePlan]) -> some View {
        let files = plans.reduce(0) { $0 + $1.steps.count }
        Button { onApplyRenames(plans) } label: {
            Label("Rename \(files) file\(files == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .chromeHover()
        .controlSize(.small)
        .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
        .help("Renames \(files) file\(files == 1 ? "" : "s") across \(plans.count) "
              + "folder\(plans.count == 1 ? "" : "s") to match each folder's own convention. "
              + "One undoable change — ⌘Z puts every name back.")
    }

    /// "Fix all N", scoped to the FILTERED risky names. `onNormalize` has always taken its rows
    /// explicitly, so this one was safe by construction — it just needs the filtered array.
    @ViewBuilder
    private func fixAllButton(_ risky: [RiskyName]) -> some View {
        if !risky.isEmpty {
            // Built as a value, not concatenated inside `.help`. A ternary carrying two string
            // interpolations, joined by `+` to two more literals, is the shape that blows the
            // type-checker's budget — it fit under the old deployment target and stopped fitting
            // under the new one, because availability changes the overload sets the solver walks.
            let scope = isFiltered
                ? "the \(risky.count) name\(risky.count == 1 ? "" : "s") your search left showing"
                : "every risky name above"
            let help = "Renames \(scope) to its cloud-safe form. Never overwrites an existing "
                + "file, and the whole pass undoes with a single ⌘Z."
            Button { onNormalizeNames(risky) } label: {
                Label("Fix all \(risky.count)", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .chromeHover()
            .controlSize(.small)
            .disabled(syncManager.isNormalizingNames)
            .help(help)
        }
    }

    private var hasStorageReport: Bool { syncManager.storageLensReport != nil }

    private var reanalyzeStorageButton: some View {
        rescanButton(moved: targetMoved(from: syncManager.storageLensRoot?.path),
                     movedIcon: "chart.pie.fill", disabled: syncManager.isBuildingStorageLens,
                     action: onBuildStorage,
                     movedHelp: "Analyze “\(scanTargetName)” — the folder now focused above")
    }

    private var newRuleButton: some View {
        // Reuses the host's existing rule-editor sheet (the one "Remember" opens a learned rule
        // in), so a blank rule and a taught rule are reviewed through exactly one editor.
        Button { reviewingAutomationRule = AutomationRule(name: "") } label: {
            Label("New rule", systemImage: AutomationsGlyph.newRule)
        }
        .chromeButtonStyle(glassLevel)
        .controlSize(.small)
        .chromeHover()
        .help("Write a plain-words rule for where loose files belong")
    }

    private var runnableRuleCount: Int {
        syncManager.automationRules.filter { $0.enabled && $0.isRunnable }.count
    }

    private var previewAllButton: some View {
        Button {
            automationsState.viewingResults = true
            onPreviewAutomations(nil)
        } label: {
            Label("Preview all", systemImage: AutomationsGlyph.preview)
        }
        .buttonStyle(.borderedProminent)
        .chromeHover()
        .controlSize(.small)
        .disabled(runnableRuleCount == 0 || automationDestinationRoot == nil)
        // Name the ACTUAL blocker: with no provider root there is nothing to preview over, and
        // telling the user to add conditions to already-complete rules is a dead end.
        .help(automationDestinationRoot == nil
              ? "Focus a provider folder first — the preview runs over the focused folder."
              : runnableRuleCount == 0
              ? "Add a rule with a condition and a destination to preview it."
              : "Dry-run the enabled rules over the focused folder. A preview — nothing moves until you confirm.")
    }

    // MARK: Content card

    @ViewBuilder
    private func contentCard(rows: FilteredRows) -> some View {
        VStack(spacing: 0) {
            switch effectiveLens {
            case .duplicates: duplicatesContent(dupGroups: rows.duplicates)
            case .rename: renameContent(risky: rows.risky)
            case .filing:
                if showingRenameBacklog, !syncManager.renamePlans.isEmpty, rows.renames.isEmpty {
                    noMatchesState(total: syncManager.renamePlans.count, noun: "folder")
                } else if showingRenameBacklog {
                    RenamePassLens(syncManager: syncManager, plans: rows.renames,
                                   accent: glassHue.accentColor,
                                   onApply: onApplyRenames,
                                   onReveal: { path in
                                       NSWorkspace.shared.activateFileViewerSelecting(
                                           [URL(fileURLWithPath: path)])
                                   })
                } else {
                    filingContent(filing: rows.filing)
                }
            case .automations: automationsContent(rules: rows.rules)
            case .storage: EmptyView()   // rendered by `body` as StorageLensView, never through here
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    @ViewBuilder
    private func duplicatesContent(dupGroups: [DuplicateGroup]) -> some View {
        if syncManager.isFindingDuplicates {
            scanningState
        } else if !syncManager.hasFoundDuplicates {
            introState
        // Ahead of `cleanState`, deliberately. A scan that turned up no groups AT ALL is still an
        // answer about the folder, and the user asked about a file — landing them on the folder's
        // all-clear leaves them to infer that it covered the thing they clicked. This branch is
        // reached only when the visible list is empty, so a name query that DOES surface other
        // groups still shows them.
        } else if let landing = revealLanding,
                  let answer = DuplicateReveal.namedAnswer(for: landing,
                                                           currentQuery: query,
                                                           listIsEmpty: dupGroups.isEmpty) {
            namedRevealState(answer, path: landing.path)
        } else if syncManager.duplicateGroups.isEmpty {
            cleanState
        } else if dupGroups.isEmpty {
            noMatchesState(total: syncManager.duplicateGroups.count, noun: "duplicate group")
        } else {
            groupList(dupGroups: dupGroups)
        }
    }

    /// The honest end of a "Find duplicates of this" — which of the two answers depends on
    /// whether the scan looked at the file at all.
    ///
    /// **The generic "Nothing matches" is not good enough here, which is the whole reason these
    /// exist.** A handoff writes the query itself, so without them the user arrives at a
    /// filtered-to-empty list captioned with a count — an answer about the *filter* where they
    /// asked about a *file*, and indistinguishable from having mistyped something.
    ///
    /// And the two answers are kept apart because they are different claims. "No other copy of
    /// this file" is a finding; "this file was not in the folder that was scanned" is the absence
    /// of one. Collapsing the second into the first is the false-confidence failure the whole
    /// feature is built to avoid — see `DuplicateReveal.outcome`.
    /// `path` rides in from the landing: the request that carried it has been consumed by the
    /// time these are on screen, and the `notScanned` recovery button needs a folder to scan.
    @ViewBuilder
    private func namedRevealState(_ answer: DuplicateReveal.NamedEmptyState, path: String) -> some View {
        switch answer {
        case .noDuplicates(let name):
            EmptyStateView(
                icon: "doc.on.doc",
                title: "No duplicates of “\(name)”",
                message: syncManager.duplicateScanRoot.map { root in
                    "Nothing else in “\((root as NSString).lastPathComponent)” has the same content as this file."
                } ?? "Nothing else in the scanned folder has the same content as this file.",
                caption: "Copies outside the folder that was scanned aren't detected.",
                primary: .init("Clear Search", systemImage: "xmark.circle") { clearRevealAnswer() }
            )
        case .notScanned(let name):
            // Deliberately claims nothing about the file. The last scan covered somewhere else (or
            // was cancelled), so the only true statement available is that it did not look here.
            EmptyStateView(
                icon: "questionmark.folder",
                title: "“\(name)” wasn't in the last scan",
                message: syncManager.duplicateScanRoot.map { root in
                    "These results were scanned from “\((root as NSString).lastPathComponent)”, which doesn't contain this file — so they say nothing about it either way."
                } ?? "No completed scan covers this file, so there is nothing to say about it yet.",
                caption: "Scan the folder this file is in to get an answer about it.",
                primary: .init("Find Duplicates", systemImage: "wand.and.stars") {
                    // Through the same door as the context menu, with the FILE's path — so the
                    // host scans a folder that actually contains it and hands back a fresh
                    // request, which re-fires the reveal naturally. `onFindDuplicates` here
                    // scanned the LENS's focused root, which for a handoff from the other pane is
                    // a root that still cannot contain the file: the scan ran, resolved
                    // `.outsideScan` again, and offered the same button — a loop dressed as a
                    // recovery, under a caption promising "the folder this file is in".
                    if let onFindDuplicatesOf {
                        onFindDuplicatesOf(path)
                    } else {
                        // No host wiring (previews, tests): the old behaviour, re-armed so the
                        // standing request resolves against whatever the scan finds.
                        appliedRevealID = nil
                        onFindDuplicates()
                    }
                }
            )
        }
    }

    /// Puts the lens back to showing everything, and retires the named answer with the query it
    /// described.
    private func clearRevealAnswer() {
        searchQueries[.duplicates] = ""
        searchExpandedLenses.remove(.duplicates)
        revealLanding = nil
        filter = .all
    }

    /// Filtered-to-empty dead end (mirrors the Activity Log's "No matching entries"): rows exist,
    /// but the search hides them all — name the cause and offer one click out, instead of a blank
    /// list that reads like the lens found nothing.
    private func noMatchesState(total: Int, noun: String) -> some View {
        EmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: "Nothing matches",
            message: "The current search hides all \(total) \(noun)\(total == 1 ? "" : "s"). Clear it to see the results again.",
            primary: .init("Clear Search", systemImage: "xmark.circle") {
                searchQueries[lens] = ""
                searchExpandedLenses.remove(lens)
                if lens == .duplicates { filter = .all }
            }
        )
    }
    private func groupList(dupGroups: [DuplicateGroup]) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: densityMetrics.cardListSpacing) {
                ForEach(dupGroups) { group in
                    TidyGroupCard(
                        group: group,
                        isExpanded: expanded.contains(group.id),
                        providerName: providerName,
                        scanRoot: syncManager.duplicateScanRoot,
                        densityMetrics: densityMetrics,
                        onToggle: { toggle(group.id) },
                        onApply: { apply(group) },
                        onReveal: { reveal(group) },
                        onKeepSeparate: { syncManager.keepDuplicateGroupSeparate(group) },
                        onChooseKeeper: { syncManager.setKeeper(for: group.id, to: $0) },
                        onMerge: { merge(group) },
                        onCompareCopies: { keep, delete in onCompareCopies(keep, delete) },
                        isMerging: syncManager.mergingGroupIDs.contains(group.id)
                    )
                    // The landing mark, drawn from OUTSIDE the card rather than threaded through
                    // it: the card renders a duplicate group, and "you were sent here" is a fact
                    // about this session's navigation, not about the group.
                    .overlay {
                        if revealedGroupID == group.id {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(glassHue.accentColor, lineWidth: 2)
                                .allowsHitTesting(false)
                                // The card announces the mark (below); the ring is its paint.
                                .accessibilityHidden(true)
                        }
                    }
                    // The spoken form of the ring. The mark exists because a reveal into a list of
                    // similar cards leaves the user to work out which one they were sent to — and a
                    // VoiceOver user has no ring, so without this the one card that answers their
                    // question sounds identical to its neighbours. `.isSelected` rather than words
                    // of our own: "selected" is how assistive tech already says "this one".
                    .accessibilityAddTraits(revealedGroupID == group.id ? .isSelected : [])
                    .transition(cardRemoval)
                }
            }
            .padding(densityMetrics.cardListPadding)
            // Animate the list settling when a resolved/merged group leaves the array (H4). Keyed on
            // the visible id list so only membership changes animate — expand/collapse and keeper
            // picks (which don't change the id set) stay instant.
            .animation(listSettle, value: RowIdentities(rows: dupGroups))
        }
        .scrollContentBackground(.hidden)
        // Scrolling is the LAST step of a landing, and the only one that can fail silently: the
        // card is already expanded and marked by the time this runs, so a scroll that does not
        // happen leaves a correct-but-offscreen answer. Keyed on the marked group and not on the
        // request, because a group only becomes scrollable once it is in `dupGroups` — which is
        // after the filter and query the plan cleared have actually taken effect.
        .onChange(of: revealedGroupID) { _, id in
            guard let id else { return }
            withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
        // The reveal that MOUNTS this list (the workspace switch) sets `revealedGroupID` before
        // there is a proxy to scroll with, so `onChange` never sees it move. This is that case.
        .onAppear {
            guard let id = revealedGroupID else { return }
            proxy.scrollTo(id, anchor: .top)
        }
        }
    }

    // MARK: Empty / scanning states

    private var introState: some View {
        // The L4 gold-standard template (EmptyStateView): provider named in the title, the job
        // in the message, the safety contract in the caption, one primary button. The words come
        // from `LensIntros` so the header's ⓘ shows the same explanation once results exist and
        // this state is gone.
        let intro = LensIntros.duplicates(providerName: providerName)
        return EmptyStateView(
            icon: intro.icon,
            tint: glassHue.accentColor,
            title: intro.title,
            message: intro.message,
            caption: intro.safety,
            primary: .init("Find Duplicates", systemImage: "wand.and.stars", handler: onFindDuplicates)
        )
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            // Determinate linear bar once the hashing phase knows exact counts (matches the
            // Differences syncProgressRow look); indeterminate spinner during the walk phase.
            if let progress = syncManager.duplicateScanProgress, progress.total > 0 {
                let completed = min(progress.completed, progress.total)
                ProgressView(value: Double(completed), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
                    .accessibilityValue("\(completed.formatted()) of \(progress.total.formatted())")
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(syncManager.duplicateScanStatus ?? "Analyzing…")
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { syncManager.cancelFindDuplicates() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var cleanState: some View {
        EmptyStateView(
            icon: "checkmark.seal.fill",
            tint: SemanticColor.success,
            title: "No duplicates found",
            message: "Nothing repeats across \(providerName ?? "this provider"). Scan again after adding files.",
            secondary: .init("Scan again", systemImage: "arrow.clockwise", handler: onFindDuplicates)
        )
    }

    // MARK: Filing content

    @ViewBuilder
    private func filingContent(filing: [FilingSuggestion]) -> some View {
        VStack(spacing: 0) {
            // The Cloud Filing spend row lives here now, at the top of the content, rather than as
            // a third row of the header: the header is a fixed two-row ladder (that's what makes it
            // 81pt in every lens), and this row is a footnote about what the last scan cost — not a
            // control. It kept its place above the list, and its History button, unchanged.
            if spendTotals.scans > 0 {
                filingSpendRow
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            // The teach prompt sits above every Filing state (not just the list) so it survives
            // filing the last loose file — the card that triggered it is already gone. The rule offer
            // (after a "File here") takes precedence over the legacy override "Remember" prompt.
            if let offer = pendingRuleOffer {
                RuleOfferPromptView(
                    offer: offer,
                    accent: glassHue.accentColor,
                    variantChoice: $ruleVariantChoice,
                    onSave: { saveProposedRule(offer) },
                    onNotNow: { pendingRuleOffer = nil }
                )
            } else if let prompt = pendingRememberPrompt {
                RememberOverridePromptView(
                    prompt: prompt,
                    accent: glassHue.accentColor,
                    onRemember: { rememberOverride(prompt) },
                    onNotNow: { pendingRememberPrompt = nil }
                )
            }
            Group {
                if syncManager.isSuggestingFiles {
                    filingScanningState
                } else if !syncManager.hasSuggestedFiling {
                    filingIntroState
                } else if syncManager.filingSuggestions.isEmpty {
                    filingCleanState
                } else if filing.isEmpty {
                    noMatchesState(total: syncManager.filingSuggestions.count, noun: "loose file")
                } else {
                    filingList(filing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: pendingRememberPrompt?.id)
        .animation(.easeInOut(duration: 0.2), value: pendingRuleOffer?.id)
    }

    /// The "Rename" lens (the un-folded Name Normalizer): finds and fixes cloud-hostile names.
    /// Its results header is gone — the shared card above carries its controls and counts now — so
    /// it takes the filtered rows and renders only its list and states.
    @ViewBuilder
    private func renameContent(risky: [RiskyName]) -> some View {
        if syncManager.hasScannedNames, !syncManager.isScanningNames,
           !syncManager.riskyNames.isEmpty, risky.isEmpty {
            noMatchesState(total: syncManager.riskyNames.count, noun: "risky name")
        } else {
            RenameLens(
                syncManager: syncManager,
                risky: risky,
                providerName: providerName,
                accent: glassHue.accentColor,
                densityMetrics: densityMetrics,

                onNormalize: onNormalizeNames,
                onReveal: { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
                onQuickLook: onQuickLook.map { ql in { path in ql(URL(fileURLWithPath: path)) } }
            )
        }
    }

    /// N2 — the Automations lens. Its rules header is gone (the shared card carries New rule /
    /// Preview all), so the host threads in the filtered rules and the shared `viewingResults`
    /// state the card's Preview button has to flip.
    @ViewBuilder
    private func automationsContent(rules: [AutomationRule]) -> some View {
        if !syncManager.automationRules.isEmpty, rules.isEmpty, !automationsState.viewingResults {
            noMatchesState(total: syncManager.automationRules.count, noun: "rule")
        } else {
            AutomationsLens(
                syncManager: syncManager,
                state: automationsState,
                rules: rules,
                providerName: providerName,
                destinationRoot: automationDestinationRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
                onQuickLook: onQuickLook.map { ql in { path in ql(URL(fileURLWithPath: path)) } },
                onReveal: { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
                onPreview: onPreviewAutomations
            )
        }
    }

    /// Learns the correction as an automation (a "mentions" rule), dismisses the prompt, and opens
    /// the learned rule for review so it can be adjusted while it's fresh. `rememberAutomationRule`
    /// is gated at the call site by `FilingEngine.canRemember`, so it should succeed; a rare no-op
    /// (returns nil) still just dismisses — no misleading "learned" banner, nothing to review.
    /// The silence is deliberate in the UI only: the no-op is logged, because otherwise a user
    /// reporting "I clicked Remember and no rule appeared" leaves no trace anywhere to diagnose.
    private func rememberOverride(_ prompt: PendingRememberPrompt) {
        if let rule = syncManager.rememberAutomationRule(fileName: prompt.fileName,
                                                         destinationPath: prompt.destinationPath) {
            let folderName = (prompt.destinationPath as NSString).lastPathComponent
            syncManager.banner = .success("Remembered — files like “\(prompt.fileName)” will go to \(folderName).")
            reviewingAutomationRule = rule
        } else {
            Logger.shared.warning(
                "Could not learn a rule from “\(prompt.fileName)” filed into \(prompt.destinationPath): "
                + "the name yields no distinctive words to key on. Prompt dismissed without remembering.")
        }
        pendingRememberPrompt = nil
    }

    // MARK: Learned rules (offered after a filing move)

    /// After the user files a loose file, propose an editable Automation rule for files like it —
    /// the deterministic, learn-by-example complement to the AI backend.
    ///
    /// Assembled by the manager, not here: the proposal keys on the page this scan already read and
    /// on the tree's own filing memory, and both live there (see `proposeAutomationRule`).
    private func offerRule(fileName: String, filePath: String, destinationPath: String,
                           modificationDate: Date?) {
        let rel = RuleOfferLogic.relativeToProviderRoot(destinationPath, providerRoot: automationDestinationRoot)
        // The file's own date is what lets a destination ending in a year generalise to `{year}`
        // rather than freezing the year the example happened to have.
        guard let proposal = syncManager.proposeAutomationRule(fileName: fileName,
                                                               filePath: filePath,
                                                               destinationRelativePath: rel,
                                                               modificationDate: modificationDate)
        else { return }
        pendingRememberPrompt = nil   // the new offer supersedes the legacy override prompt
        ruleVariantChoice = proposal.defaultVariant
        pendingRuleOffer = RuleOffer(fileName: fileName, proposal: proposal)
    }

    /// Saves the offered rule (with the chosen phrasing) as an Automation, dismisses the offer,
    /// and opens the saved rule for review so it can be adjusted while it's fresh.
    private func saveProposedRule(_ offer: RuleOffer) {
        var rule = offer.proposal.rule
        rule.conditions = (ruleVariantChoice ?? offer.proposal.defaultVariant).conditions
        syncManager.upsertAutomationRule(rule)
        syncManager.banner = .success("Rule saved — files matching “\(rule.name)” go to \(rule.destinationTemplate)")
        pendingRuleOffer = nil
        reviewingAutomationRule = rule
    }

    private func filingList(_ filing: [FilingSuggestion]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: densityMetrics.cardListSpacing) {
                // Grouped by confidence (High / Medium / Low) so the list reads as "these are sure,
                // these are maybes, these need you" rather than one undifferentiated wall of cards.
                // Sectioned from the FILTERED rows, so a tier the query empties loses its header
                // too rather than heading nothing.
                ForEach(FilingSuggestionGrouping.sections(filing)) { section in
                    filingSectionHeader(section)
                    ForEach(section.suggestions) { suggestion in
                        filingCard(suggestion)
                            .transition(cardRemoval)
                    }
                }
            }
            .padding(densityMetrics.cardListPadding)
            // Slide + fade a filed/dismissed card out and settle the list (H4). Keyed on the id list
            // so only a card leaving animates; an emptied tier's header falls away in the same pass.
            .animation(listSettle, value: RowIdentities(rows: filing))
        }
        .scrollContentBackground(.hidden)
    }

    private func filingSectionHeader(_ section: FilingSuggestionSection) -> some View {
        // The 3-bar meter replaces the old tint dot (G5) so the header reads as a scale, and the
        // tier's gloss doubles as the once-per-screen legend for what raises confidence — no
        // separate key line needed.
        HStack(spacing: 8) {
            ConfidenceMeter(tier: section.tier)
            Text(section.tier.title)
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(section.suggestions.count.formatted())
                .scaledFont(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text("· \(section.tier.gloss)")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2).padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(section.tier.title), \(section.suggestions.count) file\(section.suggestions.count == 1 ? "" : "s"). \(section.tier.gloss)")
    }

    private func filingCard(_ suggestion: FilingSuggestion) -> some View {
        FilingSuggestionCard(
            suggestion: suggestion,
            densityMetrics: densityMetrics,
            onFileHere: { dest in
                filedThisSession = true
                Task {
                    // Offer a rule only when the file actually MOVED — filing into the folder it
                    // already lives in (`.notNeeded`) is a no-op, and a rule keyed on where the file
                    // already sits is noise.
                    guard await syncManager.applyFilingSuggestion(suggestion, to: dest) == .moved else { return }
                    offerRule(fileName: suggestion.fileName, filePath: suggestion.filePath,
                              destinationPath: dest.path,
                              modificationDate: suggestion.modificationDate)
                }
            },
            onChooseFolder: { chooseFolder(for: suggestion) },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: suggestion.filePath)]) },
            onNotHere: {
                dismissedThisSession = true
                syncManager.dismissFilingSuggestion(suggestion)
            },
            onPreview: onQuickLook.map { ql in { ql(URL(fileURLWithPath: suggestion.filePath)) } },
            onTryAnother: { Task { await syncManager.tryAnotherFolder(for: suggestion) } },
            isTryAnotherBusy: syncManager.filingTryAnotherInFlight.keys.contains(suggestion.id),
            // Offered only for the files the scan read and got nothing from — see
            // `FileSyncManager.readScan(for:)` for why it is an offer and not a scan step.
            onReadScan: syncManager.filingUnreadableScans.contains(suggestion.filePath)
                ? { Task { await syncManager.readScan(for: suggestion) } }
                : nil,
            isReadScanBusy: syncManager.filingOCRInFlight.contains(suggestion.filePath)
        )
    }

    /// The pre-scan state. Not `EmptyStateView` like the other four: the template centres two
    /// sentences in a large panel, and this card shows three sample rows in the shape real
    /// suggestions take, which is what makes the first real result list legible. See
    /// ``FilingSetupCard``.
    ///
    /// **It no longer carries a price, because the scan no longer has one.** It used to quote the
    /// last recorded cloud run — a figure about a different folder, hedged into honesty by the
    /// word "last" — because the trigger beneath it could reach the paid backend. It cannot: the
    /// scan runs at ``FilingClassifierTier/free`` and money is spent only by the refine button on
    /// the results, which quotes a real estimate for a batch it has in hand.
    private var filingIntroState: some View {
        FilingSetupCard(
            intro: LensIntros.organize(scanTargetName: scanTargetName),
            accent: glassHue.accentColor,
            onStart: onFindFilingSuggestions
        )
    }

    private var filingScanningState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(syncManager.filingScanStatus ?? "Analyzing…")
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { syncManager.cancelFindFilingSuggestions() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    @ViewBuilder
    private var filingCleanState: some View {
        if filedThisSession {
            // Earned: the user just filed everything loose this session — a positive terminal state,
            // not a neutral empty one. Its own glyph (a full tray), never the duplicate finder's seal.
            EmptyStateView(
                icon: FilingGlyph.allFiled,
                tint: SemanticColor.success,
                title: "All filed",
                message: "Every loose file in \(filingFolderName) is in its home now. Undo any move with ⌘Z, or scan again after adding more.",
                secondary: .init("Scan again", systemImage: "arrow.clockwise", handler: onFindFilingSuggestions)
            )
        } else if dismissedThisSession {
            // Handled, but not by filing: the user cleared every suggestion with "Not here". Don't
            // claim the scan found nothing — it found these and the user set them aside.
            EmptyStateView(
                icon: FilingGlyph.nothingLoose,
                tint: .secondary,
                title: "Suggestions cleared",
                message: "You set aside every suggestion in \(filingFolderName). Scan again to look afresh, or add more files first.",
                secondary: .init("Scan again", systemImage: "arrow.clockwise", handler: onFindFilingSuggestions)
            )
        } else {
            // Neutral: the scan found nothing loose to begin with.
            EmptyStateView(
                icon: FilingGlyph.nothingLoose,
                tint: .secondary,
                title: "Nothing loose to file",
                message: "No files in \(filingFolderName) need a home right now.",
                secondary: .init("Scan again", systemImage: "arrow.clockwise", handler: onFindFilingSuggestions)
            )
        }
    }

    private var filingFolderName: String {
        guard let folder = syncManager.filingScanFolder else { return "this folder" }
        return (folder as NSString).lastPathComponent
    }

    /// Asks where this suggestion should go, then files it there.
    ///
    /// The question used to be an `NSOpenPanel`, which knows nothing about the provider, nothing
    /// about where you last filed, and opens on the scan folder — the one folder the file is
    /// certainly leaving. The picker browses the provider the rail is already showing. The panel
    /// survives as `Other…`, for a destination genuinely outside it.
    private func chooseFolder(for suggestion: FilingSuggestion) {
        // Both fallbacks have to test for EMPTY, not just nil. `automationDestinationRoot` is handed
        // down as a non-optional String that is "" for an unconfigured provider, so `??` alone never
        // reached the suggestion's own root — the chain read as three options and behaved as one.
        let root = [automationDestinationRoot, suggestion.providerRoot]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        let panel = { Self.runSystemFolderPanel(for: suggestion.fileName,
                                                startingAt: syncManager.filingScanFolder) }
        // Nothing to browse without a provider root: the card would draw a stack rooted at "/" whose
        // first column is permanently empty, because `subfolders` refuses an empty root. Fall back
        // to the panel this replaced rather than showing a picker that cannot pick.
        guard !root.isEmpty else {
            if let chosen = panel() { file(suggestion, into: chosen) }
            return
        }
        onRequestDestination(PendingDestination(
            request: DestinationRequest(
                sourcePaths: [suggestion.filePath],
                firstItemName: suggestion.fileName,
                isMove: true,
                providerRoot: root,
                providerName: (providerName?.isEmpty == false) ? providerName! : "this provider",
                // Opens where the rail is looking, not at the root — the folder you were just in is
                // the best guess available, and it is one click from the root either way.
                openAt: syncManager.filingScanFolder ?? root
            ),
            onCommit: { destination in file(suggestion, into: destination) },
            onOther: panel
        ))
    }

    /// Files `suggestion` into `destination`, and — when this overrode the suggested home and the
    /// filename has something distinctive to key on — offers to remember it (G2).
    ///
    /// Shared by the picker and the system panel so one path reaches the transfer no matter which
    /// surface answered the question.
    private func file(_ suggestion: FilingSuggestion, into destination: String) {
        let dest = FilingDestination(path: destination, confidence: .high,
                                     reasons: ["You chose this folder"], newSegments: [])
        filedThisSession = true
        let teachable = FilingOverride.isOverride(suggestion, chosenPath: destination)
            && FilingEngine.canRemember(fileName: suggestion.fileName)
        Task {
            // Only prompt to remember an override when the file actually MOVED — no point learning a
            // rule from filing a file into the folder it already sits in (`.notNeeded`).
            if await syncManager.applyFilingSuggestion(suggestion, to: dest) == .moved, teachable {
                pendingRuleOffer = nil   // a stale offer would otherwise hide the fresh teach prompt
                pendingRememberPrompt = PendingRememberPrompt(fileName: suggestion.fileName,
                                                              destinationPath: destination)
            }
        }
    }

    /// The escape hatch the picker's `Other…` opens: the system folder panel, for a destination
    /// outside the provider. Returns nil when cancelled.
    private static func runSystemFolderPanel(for fileName: String, startingAt folder: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "File Here"
        panel.message = "Choose a folder for “\(fileName)”"
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Files `batch` — the exact array `fileAllButton` counted. Never re-derived from
    /// `syncManager.filingSuggestions`: under a query that's a different, larger set, and the
    /// confirmation the user reads names this one.
    private func applyRecommendedFiling(_ batch: [FilingSuggestion]) {
        guard !batch.isEmpty else { return }
        let newFolders = batch.filter { $0.best?.isNew == true }.count
        let folderNote = newFolders > 0 ? " Creates \(newFolders) new folder\(newFolders == 1 ? "" : "s")." : ""
        let ok = NativeAlerts.confirmDestructive(
            messageText: "File \(batch.count) file\(batch.count == 1 ? "" : "s") into their suggested homes?",
            informativeText: "Moves each file into its suggested folder.\(folderNote) Unsure files stay put. Every move can be undone with ⌘Z.",
            confirmTitle: "File"
        )
        guard ok else { return }
        filedThisSession = true
        Task { await syncManager.applyRecommendedFiling(batch) }
    }

    // MARK: Actions

    // MARK: The "Find duplicates of this" landing

    /// The reveal task's key — see the `.task(id:)` it drives for why each field is in it.
    private struct RevealKey: Equatable {
        let requestID: UUID?
        let isScanning: Bool
        let groupCount: Int
        let scanRoot: String?
    }

    private var revealKey: RevealKey {
        RevealKey(requestID: revealRequest?.id,
                  isScanning: syncManager.isFindingDuplicates,
                  groupCount: syncManager.duplicateGroups.count,
                  scanRoot: syncManager.duplicateScanRoot)
    }

    /// Applies whatever `DuplicateReveal` decides about the current request.
    ///
    /// Every decision is over there, and deliberately: this function only writes state, so the
    /// handoff's behaviour — including the "no duplicates of X" answer, which must never degrade
    /// into a silently empty filtered list — is pinned by `DuplicateRevealTests` without mounting
    /// anything. `applyRevealPlan` is the seam a view test drives.
    ///
    /// **`appliedRevealID` is set only once an outcome ANSWERS the request.** A `.waiting` outcome
    /// leaves it alone, which is what lets the same request resolve again when the scan it is
    /// waiting for publishes its results. Once recorded, re-resolving is suppressed — otherwise a
    /// group resolving (which moves `groupCount`, and so the key) would re-clear a search the user
    /// had typed since landing.
    ///
    /// Every outcome, `.waiting` included, goes through the SAME apply. Waiting used to be a
    /// hand-written early return that cleared the mark and the landing itself — a duplicate of what
    /// applying `DuplicateReveal.plan(for: .waiting)` does, which left that branch unreachable and
    /// its documentation describing behaviour nothing ran. The only thing special about waiting now
    /// is that it is not recorded.
    func applyRevealRequest() {
        guard let request = revealRequest, request.id != appliedRevealID,
              let outcome = DuplicateReveal.outcome(for: request,
                                                    groups: syncManager.duplicateGroups,
                                                    isScanning: syncManager.isFindingDuplicates,
                                                    scannedRoot: syncManager.duplicateScanRoot)
        else { return }
        if outcome != .waiting {
            appliedRevealID = request.id
            // Retire the request at the HOST too. The applied-id above is @State and dies with
            // this view, and a request that outlives its answer replays it on the next remount —
            // see `onRevealHandled`.
            onRevealHandled?(request.id)
        }
        applyRevealPlan(DuplicateReveal.plan(for: outcome, path: request.path))
    }

    /// Writes one plan into this lens's state. Split from the resolve so a test can hand it a plan
    /// directly and read back what the lens does with it — the resolve is already pure, and what
    /// is left to get wrong is here.
    func applyRevealPlan(_ plan: DuplicateReveal.Plan) {
        if plan.clearsFilterAndQuery { filter = .all }
        if let query = plan.searchQuery {
            searchQueries[.duplicates] = query
            // The field is revealed only when there is something in it to see. A landing that
            // clears the query must also put the field away, or the user is left looking at an
            // empty search box they did not open.
            if query.isEmpty {
                searchExpandedLenses.remove(.duplicates)
            } else {
                searchExpandedLenses.insert(.duplicates)
            }
        }
        // An empty-query landing shows now or never — dropped rather than stored when the list has
        // rows, so it cannot sit latent and surface over a later all-clear. See `landingToStore`.
        revealLanding = DuplicateReveal.landingToStore(plan.landing,
                                                       listIsEmpty: syncManager.duplicateGroups.isEmpty)
        if let id = plan.expandsGroupID { expanded.insert(id) }
        revealedGroupID = plan.revealedGroupID
    }

    /// Test seam: what the lens is currently showing as a result of a handoff. A value rather than
    /// four separate internal reads, so a test asserts the LANDING (which group is open, which is
    /// marked, what the field says) rather than the container it happened in.
    struct RevealState: Equatable {
        var expandedGroupIDs: Set<UUID>
        var revealedGroupID: UUID?
        var landing: DuplicateReveal.Landing?
        var query: String
        var filter: TidyFilter
    }

    var revealState: RevealState {
        RevealState(expandedGroupIDs: expanded, revealedGroupID: revealedGroupID,
                    landing: revealLanding, query: searchQueries[.duplicates] ?? "",
                    filter: filter)
    }

    private func toggle(_ id: UUID) {
        // Touching ANY card by hand ends the landing: the mark says "this is the one you were
        // sent to", and once the user is working the list themselves it is describing history.
        // This used to clear only when the touched card WAS the marked one, so opening the
        // neighbours left the ring standing through a whole review session — the code quietly
        // narrower than this comment, which always said "any".
        revealedGroupID = nil
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func apply(_ group: DuplicateGroup) {
        let count = group.recommendedRemovalPaths.count
        guard count > 0 else { return }
        // Versions discard genuinely older, different content — say so rather than "redundant".
        let isVersions = group.matchType.kind == .versions
        let itemWord: String = isVersions
            ? (count == 1 ? "older version" : "older versions")
            : (count == 1 ? "redundant copy" : "redundant copies")
        let ok = NativeAlerts.confirmDestructive(
            messageText: "Move \(count) \(itemWord) of \"\(group.name)\" to the Trash?",
            informativeText: "Keeps \"\(group.keeper.name)\" at \(displayPath(group.keeper.path)). "
                + "Reclaims \(FileSyncManager.formatBytes(group.reclaimableBytes)). This can be undone with ⌘Z.",
            confirmTitle: "Move to Trash"
        )
        guard ok else { return }
        // Only identical (batch-eligible) groups feed `duplicateSummary.reclaimableBytes`, the
        // figure the ReclaimPill counts *down*. Credit the "freed this session" count-up only for
        // those, so the two numbers stay in lockstep — otherwise resolving a versions/overlap
        // group (never part of the reclaimable total) would bump "freed" while "reclaimable" sat
        // still. Those groups still go to the Trash and stay undoable; they just aren't headlined
        // in this batch-oriented pill.
        let reclaimable = group.isRecommendedForBatch ? group.reclaimableBytes : 0
        Task {
            if await syncManager.resolveDuplicateGroup(group) { creditReclaim(reclaimable) }
        }
    }

    /// Trashes the redundant copies of `groups` — the exact array `applyAllButton` counted. Never
    /// re-derived from `syncManager.duplicateGroups`: under a query that's a different, larger set,
    /// and this dialog's counts must describe what will actually happen.
    private func applyRecommended(_ groups: [DuplicateGroup]) {
        guard !groups.isEmpty else { return }
        let bytes = groups.reduce(0) { $0 + $1.reclaimableBytes }
        let copies = groups.reduce(0) { $0 + $1.recommendedRemovalPaths.count }
        let ok = NativeAlerts.confirmDestructive(
            messageText: "Tidy \(groups.count) groups in \(providerName ?? "this provider")?",
            informativeText: "Moves \(copies) redundant copies to the Trash, reclaiming about "
                + "\(FileSyncManager.formatBytes(bytes)). Name-only and overlapping groups are left untouched. "
                + "Everything can be undone with ⌘Z.",
            confirmTitle: "Tidy"
        )
        guard ok else { return }
        // Credit the batch by the reclaimable it actually erased (the drop in the still-reclaimable
        // figure), so a partial failure counts only what really landed — `applyRecommendedDuplicates`
        // returns Void, so we measure the delta rather than trust the dialog's promised total.
        //
        // That delta is a shared meter, though: a per-card `apply` finishing while this batch runs
        // lowers it too, and that path already credited the group itself — so the raw drop would
        // count those bytes twice. `netBatchCredit` nets out whatever the tally banked meanwhile,
        // which is exactly the concurrent per-card credits (see ``ReclaimTally``).
        let before = syncManager.duplicateSummary.reclaimableBytes
        let bankedAtStart = reclaim.totalBytes
        Task {
            await syncManager.applyRecommendedDuplicates(groups)
            let drop = before - syncManager.duplicateSummary.reclaimableBytes
            creditReclaim(reclaim.netBatchCredit(reclaimableDrop: drop, bankedAtStart: bankedAtStart))
        }
    }

    private func merge(_ group: DuplicateGroup) {
        // Belt over the manager's own re-entry guard: don't even raise the confirm dialog for a
        // group whose merge is already in flight (the button disables, but the state can flip
        // between the click and this handler).
        guard !syncManager.mergingGroupIDs.contains(group.id) else { return }
        let unique = group.redundantCopies.reduce(0) { $0 + $1.uniqueItemCount }
        let many = group.redundantCopies.count != 1
        // "About": this figure is the scan's distinct-content estimate, while the merge plans
        // its copies per relative path (re-hashing at merge time) — the two legitimately differ
        // in both directions (same content under two names copies twice; content present in the
        // keeper under another name at the same spot may skip). An exact promise here was
        // routinely off by a file or two; the safety statement — nothing is trashed until
        // everything landed — is the load-bearing part.
        let ok = NativeAlerts.confirmDestructive(
            messageText: "Merge \"\(group.name)\" into one folder?",
            informativeText: "Copies anything \"\(group.keeper.name)\" doesn't already have (about \(unique) item\(unique == 1 ? "" : "s")) into it, then moves the folded cop\(many ? "ies" : "y") to the Trash. Nothing is lost; undo with ⌘Z.",
            confirmTitle: "Merge"
        )
        guard ok else { return }
        Task { await syncManager.mergeDuplicateGroup(group) }
    }

    private func reveal(_ group: DuplicateGroup) {
        let urls = group.copies.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Reclaim pill (H5)

/// The Duplicates summary's reclaim figure, given the H5 payoff: the still-reclaimable number rolls
/// with `numericText` as groups resolve, an optional "… freed this session" caption counts *up*, and
/// a green glow flashes once per resolve and fades over ~1s — the one flourish the feature earns.
private struct ReclaimPill: View {
    /// Bytes still reclaimable across the remaining groups (counts *down* as you resolve).
    let reclaimableBytes: Int
    /// "… freed this session" — nil until something's been reclaimed, so it's hidden at zero.
    let freedCaption: String?
    /// Bumped once per successful resolve to retrigger the glow.
    let flashToken: Int
    let reduceMotion: Bool

    /// Glow strength, 1 at the instant of a resolve, eased to 0 over ~1s.
    @State private var glow: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .scaledFont(PillVariant.standard.iconFont)
                .symbolRenderingMode(.hierarchical)
            Text("\(FileSyncManager.formatBytes(reclaimableBytes)) reclaimable")
                .scaledFont(PillVariant.standard.numberFont)
                .monospacedDigit()
                // Numeric roll is kept even under Reduce motion (an acceptable content transition).
                .contentTransition(.numericText())
            if let freedCaption {
                Text("· \(freedCaption)")
                    .scaledFont(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(SemanticColor.success.opacity(0.85))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(SemanticColor.success)
        // The standard pill surface, inlined so the glow can ride on top of the shared base
        // values: at rest (glow == 0) this is exactly `pillSurface(.standard)`.
        .padding(.horizontal, PillVariant.standard.horizontalPadding)
        .padding(.vertical, PillVariant.standard.verticalPadding)
        .background(Capsule(style: .continuous)
            .fill(SemanticColor.success.opacity(PillVariant.fillOpacity + 0.30 * glow)))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(SemanticColor.success.opacity(PillVariant.strokeOpacity + 0.45 * glow),
                          lineWidth: PillVariant.strokeWidth + glow))
        .shadow(color: SemanticColor.success.opacity(0.55 * glow), radius: 7 * glow)
        .fixedSize()
        // Roll the numbers whenever they change (both the count-down and the count-up caption).
        .animation(.easeInOut(duration: 0.35), value: reclaimableBytes)
        .animation(.easeInOut(duration: 0.35), value: freedCaption)
        .onChange(of: flashToken) { _, _ in
            // The glow is pure decoration, so it's dropped under Reduce motion — the numeric roll above
            // still conveys the change.
            guard !reduceMotion else { return }
            glow = 1
            withAnimation(.easeOut(duration: 1.0)) { glow = 0 }
        }
    }
}
