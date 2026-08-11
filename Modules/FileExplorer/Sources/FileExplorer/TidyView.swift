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
    case all, identical, sameText, overlapping, nameOnly, versions
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .identical: return "Identical"
        case .sameText: return "Same text"
        case .overlapping: return "Overlapping"
        case .nameOnly: return "Name only"
        case .versions: return "Versions"
        }
    }

    func matches(_ group: DuplicateGroup) -> Bool {
        switch self {
        case .all: return true
        case .identical: return group.matchType.kind == .identical
        case .sameText: return group.matchType.kind == .sameText
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
        // A seal, like `identical`, but unfilled: the same claim made with less certainty behind
        // it. The glyph pair is the vocabulary — nothing here relies on the colour alone.
        case .sameText: return "checkmark.seal"
        case .overlapping: return "square.on.square"
        case .nameOnly: return "exclamationmark.triangle.fill"
        case .versions: return "clock.arrow.circlepath"
        }
    }
    static func color(_ type: DuplicateMatchType) -> Color {
        switch type {
        case .identical: return SemanticColor.success
        case .sameText: return SemanticColor.caution
        case .overlapping: return SemanticColor.warning
        case .nameOnly: return SemanticColor.caution
        case .versions: return .purple
        }
    }
    static func label(_ type: DuplicateMatchType) -> String {
        switch type {
        case .identical: return "Identical"
        case .sameText: return "Same text"
        case .overlapping(let f): return "Overlapping · \(Int((f * 100).rounded()))%"
        case .nameOnly: return "Name only"
        case .versions: return "Versions"
        }
    }
    static func filterColor(_ f: TidyFilter) -> Color {
        switch f {
        case .all: return .secondary
        case .identical: return SemanticColor.success
        case .sameText: return SemanticColor.caution
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
    /// The provider root everything in this workspace anchors at.
    ///
    /// Two consumers, one value, and they must not drift apart. Automations resolve destinations
    /// against it, so the Browse… button anchors where the preview does rather than at whatever
    /// subfolder happened to be scanned; and ``scope`` normalizes against it, which is what makes
    /// "pointing at the provider root clears the scope" a fact about this exact root rather than
    /// about some other notion of the top of the tree.
    ///
    /// Named for what it *is* rather than for one of its uses — it was `automationDestinationRoot`,
    /// and a second parameter carrying the identical value would have been two roots to keep in
    /// step. A pure rename: every call site already passed `tidyProviderRootExpanded`.
    private let providerRoot: String?
    /// The loose-files inbox's absolute path, when the folder exists — the offer on Organize's
    /// overview that replaced the hidden root-swap. nil hides the offer entirely rather than
    /// showing one that points nowhere.
    private let filingInboxFolder: String?
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
        providerRoot: String? = nil,
        filingInboxFolder: String? = nil,
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
        self.providerRoot = providerRoot
        self.filingInboxFolder = filingInboxFolder
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

    /// Which of Organize's lenses is on screen — `nil` for the overview.
    ///
    /// Persisted, because a rail item is a *place* and closing the app standing in Duplicates and
    /// reopening on the overview would lose a deliberate choice. See ``OrganizeLens`` for why the
    /// items are permanent while their badges are not, and why there is no longer an `effective`
    /// fallback bouncing you off a list that emptied.
    @AppStorage(OrganizeLens.defaultsKey) private var railLens: OrganizeLens?

    /// The scope's stored path — **empty is the global view**, and the global view is the default.
    ///
    /// Persisted for the same reason the rail lens is: scope is a place the user chose, and it is
    /// the thing the daily flow depends on. Scoping to the `TODO` inbox once and having it survive
    /// the next launch is what replaces the hidden root-swap that used to retarget To File whenever
    /// the pane happened to sit at the provider root.
    ///
    /// Stored as a bare path rather than as an encoded ``OrganizeScope`` because the provider root
    /// it must be validated against is not knowable at decode time — the pane can be on a different
    /// provider by the time this is read. ``scope`` re-resolves on every access, so a stale path
    /// from another provider degrades to the global view instead of filtering every lens to empty.
    @AppStorage(OrganizeScopeDefaults.pathKey) private var scopePathRaw: String = ""

    /// The subtree the user has pointed Organize at — **whether or not the lens on screen applies
    /// it.** Every writer and every readout of the chip goes through this; the lists go through
    /// ``scope``.
    ///
    /// Re-resolved rather than stored: `init?` rejects the provider root and anything outside it,
    /// so this is also where a scope left over from a provider that is no longer showing quietly
    /// becomes nil.
    private var storedScope: OrganizeScope? {
        guard let providerRoot, !providerRoot.isEmpty, !scopePathRaw.isEmpty else { return nil }
        return OrganizeScope(path: scopePathRaw, providerRoot: providerRoot)
    }

    /// The scope **one named lens** applies: the stored one, or nil where ``OrganizeLens/isScoped``
    /// says configuration is not narrowed by a folder.
    ///
    /// Per-lens rather than per-selection because the rail draws all six badges at once — see
    /// ``railCounts``, where asking the *selected* lens's question would have lifted the scope off
    /// the five that do use it. `nil` (the overview) is scoped: it summarises the five.
    ///
    /// The suspension is a read, not a write: `scopePathRaw` is untouched, so leaving Rules puts the
    /// scope back with no restore step for an exit path to forget.
    private func appliedScope(for item: OrganizeLens?) -> OrganizeScope? {
        (item?.isScoped ?? true) ? storedScope : nil
    }

    /// The subtree the lists on screen are narrowed by, or nil for the global view.
    private var scope: OrganizeScope? { appliedScope(for: organizeLens) }

    /// Whether a scope is set and the lens on screen is deliberately not applying it — the chip's
    /// suspended state.
    private var scopeIsSuspended: Bool { scope == nil && storedScope != nil }

    /// Points Organize at a folder, or clears the scope.
    ///
    /// **Normalizing lives here, at the one write.** Every entry point — the folder context menu,
    /// ⌘K, the "Scan '<folder>'" affordance, the inbox shortcut, the chip's ✕ — routes through
    /// this, so none of them can mint the second encoding of the global view that
    /// ``OrganizeScope/init(path:providerRoot:)`` exists to prevent.
    private func setScope(_ path: String?) {
        guard let path, let providerRoot,
              let resolved = OrganizeScope(path: path, providerRoot: providerRoot) else {
            scopePathRaw = ""
            return
        }
        scopePathRaw = resolved.path
    }

    /// The rail selection, but only while Organize is the workspace.
    ///
    /// Storage is still a workspace of its own, and its `@AppStorage` neighbour keeps whatever
    /// rail item Organize was last left on. Reading `railLens` unguarded would let that parked
    /// value pick Storage's apparatus — a lens selection leaking across a workspace boundary.
    private var organizeLens: OrganizeLens? {
        lens == .storage ? nil : railLens
    }

    /// Whether the rail can spell its items out at this width — see ``OrganizeRailMetrics``.
    ///
    /// Resolved in the geometry transform rather than stored as a width, so the state write only
    /// fires when the ANSWER flips rather than on every point of a live resize.
    @State private var railStyle: OrganizeRailStyle = .full

    /// Which of Storage's ranked lists the rail is showing, or **absent for all three**.
    ///
    /// Optional for the reason ``OrganizeLens/defaultsKey`` is: there is no value to write for "no
    /// section picked", and a fourth case meaning that would be one more thing to migrate.
    @AppStorage(StorageSection.defaultsKey) private var storageSection: StorageSection?


    /// Whether Organize is showing its overview: every lens's answer for the scope, one page.
    ///
    /// The rail's *unselected* state rather than a seventh rail item, so it has no name of its own
    /// and cannot be a tab you forget to visit — it is what you land on.
    private var showingOverview: Bool {
        lens != .storage && railLens == nil
    }

    /// The lens whose grammar, pills, actions and content are on screen right now.
    ///
    /// `lens` is where you ARE (which workspace); this is what you are LOOKING AT (which rail
    /// item). The rail is the vocabulary and `TidyLens` is the machinery — search grammars, parked
    /// queries, scroll state all key on the apparatus, and three rail items share `.filing`'s
    /// because their rows are filing rows. What none of them reuse is the title: the header keeps
    /// saying Organize, because you have not gone anywhere.
    private var effectiveLens: TidyLens {
        organizeLens?.searchLens ?? lens
    }

    /// True when Organize is showing the rename backlog rather than the queue.
    ///
    /// Still not a `TidyLens` of its own: the backlog's rows are folder plans, which no existing
    /// apparatus describes, so it borrows `.filing`'s query slot and the content card branches on
    /// it. It IS a rail item now, which is the part that changed.
    private var showingRenameBacklog: Bool {
        organizeLens == .renames
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
        /// Restructure's findings, split by how they relate to the scope.
        ///
        /// **`.restructure` did not route through here at all** — `restructureContent()` read
        /// `syncManager.structureFindings` straight off the manager, which is exactly why it was
        /// the one lens no filter could reach. Two arrays rather than one because its rows have
        /// two honest kinds and the second must not be silently dropped: see ``ScopeRelation``.
        var structure: [StructureFinding] = []
        var structureAboutAncestor: [StructureFinding] = []
    }

    /// Resolves only the ACTIVE lens's rows — the other four aren't on screen, and each of these
    /// parses a query and walks a collection.
    ///
    /// **The scope is applied here, ahead of the search**, so every consumer of these rows —
    /// header counts, destructive button labels, the action that iterates them — sees one
    /// consistently narrowed set. Applying it downstream in the content card instead would put the
    /// count and the list back out of step, which is the failure `FilteredRows` exists to prevent.
    private var filteredRows: FilteredRows {
        var rows = FilteredRows()
        let scope = scope
        // The overview reads none of these — it renders `overviewSections`, which does its own
        // per-lens tallying. Without this guard the overview still paid for a parsed query and a
        // scoped pass over the filing queue on every render, for a value nothing downstream reads.
        //
        // **`showingOverview` alone is the wrong test, and the reveal suite caught it doing real
        // damage.** It means *no rail item is selected*, which is not the same as *the overview is
        // what renders*: the overview is drawn only from `contentCard`'s `.filing` arm, so a view
        // whose apparatus is `.duplicates` with no rail selection still draws its group list and
        // still needs these rows. Guarding on `showingOverview` alone handed it an empty
        // `FilteredRows`, and `DuplicateRevealLandingTests` went from painting a revealed group to
        // painting nothing — two pixel comparisons that had been the suite's sharpest assertions
        // both fell to zero difference.
        //
        // So the condition mirrors the one the content card actually branches on. Cheap either way;
        // the point is that it is now the same question.
        guard !(showingOverview && effectiveLens == .filing) else { return rows }
        switch effectiveLens {
        case .duplicates:
            let q = DuplicateSearch.parse(query)
            rows.duplicates = syncManager.duplicateGroups.filter {
                OrganizeScopeFilter.matches($0, scope: scope) && filter.matches($0) && q.matches($0)
            }
        case .rename:
            let q = RiskyNameSearch.parse(query)
            rows.risky = syncManager.riskyNames.filter {
                OrganizeScopeFilter.matches($0, scope: scope) && q.matches($0)
            }
        case .filing where showingRenameBacklog:
            rows.renames = syncManager.renamePlans.filter {
                OrganizeScopeFilter.matches($0, scope: scope)
                    && RenameBacklogSearch.matches(query, $0)
            }
        case .filing where organizeLens == .restructure:
            // Restructure carries no search grammar of its own (it parks in `.filing`'s query
            // slot — see `OrganizeLens.searchLens`), so the scope is the only narrowing here.
            let root = syncManager.filingFolderProfile?.root ?? ""
            for finding in structureFindings {
                switch OrganizeScopeFilter.relation(of: finding, profileRoot: root, scope: scope) {
                case .inside: rows.structure.append(finding)
                case .aboutAncestor: rows.structureAboutAncestor.append(finding)
                case .outside: break
                }
            }
        case .filing:
            let q = FilingSearch.parse(query)
            // Filtered UPSTREAM of FilingSuggestionGrouping: the sections are derived from these
            // rows, so an emptied tier's header falls away with it instead of heading nothing.
            rows.filing = syncManager.filingSuggestions.filter {
                OrganizeScopeFilter.matches($0, scope: scope) && q.matches($0)
            }
        case .automations:
            let q = AutomationSearch.parse(query)
            // **The query narrows this list and the scope does not** — `scope` is already nil here,
            // because `OrganizeLens.isScoped` is false for Rules, so writing the scope test would
            // be an inert call that reads like a live rule. Rules are configuration, not findings.
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
    /// "N of M" for Storage — **over the lists the body is actually showing.**
    ///
    /// It summed all three ranked lists unconditionally, which was right while the page was always
    /// all three. The rail can narrow it to one now, and the unchanged sum described a page nobody
    /// was looking at: standing on Largest with a query showing 3 of its 50, the row read "3 of
    /// 164" — a denominator drawn from two lists that were not on screen. That is the same
    /// dishonesty the scope work removed from the Organize lenses, arriving here through the rail.
    ///
    /// The selection narrows *which lists*; the query narrows *within them*. Both are needed: N is
    /// the rows on screen and M is the list before the transient narrowing, and after the rail
    /// "this list" means the selected section.
    private var storageCounts: (filtered: Int, total: Int) {
        guard let report = syncManager.storageLensReport else { return (0, 0) }
        let q = storageQuery
        return StorageSection.counts(in: report, section: storageSection) { q.matches($0) }
    }

    /// Per-filter group counts for the filter menu's badges, in ONE pass over the groups (the menu
    /// used to run a full filter per TidyFilter case on every render).
    /// Per-filter group counts for the filter menu's badges, in ONE pass over the groups.
    ///
    /// **Counted within the scope**, and that is a different question from the one the search
    /// raises. Counting all groups rather than the *search-narrowed* ones is deliberate and stays —
    /// a badge must never read zero for a filter that would reveal rows once picked. But the scope
    /// is not a transient narrowing of a list you are looking at; it decides *which list this is*.
    /// Left global, the menu offered "Identical (620)" beside a lens holding 27, and picking it
    /// revealed nothing like 620.
    ///
    /// The scope test folds into the existing pass rather than pre-filtering into a second array —
    /// this builder is not lazy and runs on every render (see `filterMenu`), so the pass stays one
    /// pass.
    private static func filterCounts(_ groups: [DuplicateGroup],
                                     scope: OrganizeScope?) -> [TidyFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: TidyFilter.allCases.map { ($0, 0) })
        for group in groups where OrganizeScopeFilter.matches(group, scope: scope) {
            for f in TidyFilter.allCases where f.matches(group) { counts[f, default: 0] += 1 }
        }
        return counts
    }
    private var hasResults: Bool { !syncManager.duplicateGroups.isEmpty }

    public var body: some View {
        // Resolve this lens's rows ONCE and hand the same value to the header and the content —
        // see `FilteredRows`.
        let rows = filteredRows
        // The rail's six counts, resolved ONCE — see `RailCounts`. Both consumers read this same
        // value: the width arithmetic below (which badge each item is carrying) and each rail item's
        // own badge. They used to ask independently, which was twelve scoped passes per render.
        let counts = railCounts
        // Resolved here too rather than inside the chip, so the header's per-render cost is a
        // single walk of the profile's folder list instead of one on every redraw of row 2.
        let scopeFolders = scopeFolderCount
        // Measured ONCE per body: this reads type metrics, while the geometry transform below runs
        // on every width the card is handed. It is everything row 1's leading half must seat — the
        // rail alone today; anything put back beside it goes through `leadingWidth` too, which is
        // where an uncounted companion control cost the model 21pt once already.
        // Whichever rail this workspace draws — Storage has its own vocabulary and its own
        // widths, and the row it sits in is the same row with the same reserve.
        let railLeading = lens == .storage
            ? OrganizeRailMetrics.storageLeadingWidth(scale: appFontScale, state: storageRailState)
            : OrganizeRailMetrics.leadingWidth(scale: appFontScale, state: counts.state)
        return VStack(spacing: 0) {
            // The header card heads the workspace in EVERY lens and EVERY state, so its bottom
            // edge lands on 83.5 — the file pane's header/list boundary — no matter what's been
            // scanned. The `sourceBar` sits below it (and only ever appears when the source rail
            // is collapsed, i.e. when there's no pane left to line up with anyway).
            lensHeaderCard(rows: rows, counts: counts, scopeFolders: scopeFolders)
                // The STYLE, not the width — `.onGeometryChange` only calls its action when the
                // transformed value changes, so a live resize writes state twice (once each way)
                // rather than on every point. Same reason the workspace bar resolves its own
                // shedding inside the transform.
                .onGeometryChange(for: OrganizeRailStyle.self) { proxy in
                    OrganizeRailMetrics.style(contentWidth: proxy.size.width,
                                              leadingWidth: railLeading)
                } action: { railStyle = $0 }
            if showSourcePicker { sourceBar }
            lensBody(rows: rows, counts: counts, scopeFolders: scopeFolders)
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
                browseRoot: providerRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
                people: syncManager.filingPeopleStore?.people ?? [],
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
                // **The selection is NOT moved, and that is a deliberate reversal.** The chips
                // bounced you back to the queue here, because a finding chip could vanish under a
                // rescan and strand you on a list with no way back. A rail item cannot vanish, so
                // standing on Names while its scan re-runs is a legitimate place to be — the list
                // says it is scanning and then refills.
                //
                // Moving it was actively wrong: the auto-rescan fires as Organize appears, so a
                // launch that restored Names started a scan and immediately yanked the selection
                // to To File. Names and Renames could not survive a relaunch at all. Only the
                // parked query goes, because it described the previous scan's rows.
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
    private func lensHeaderCard(rows: FilteredRows, counts: RailCounts,
                                scopeFolders: Int?) -> some View {
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
            title: { lensTitle(counts) },
            // **Row 1's trailing half is empty now, and that is the point.** The lens's controls
            // moved to row 2 — see ``lensTrailing``. What is left up here is the search toggle,
            // which `LensHeaderCard` appends itself, so row 1 is the rail and one 30pt button.
            actions: { EmptyView() },
            summary: { lensSummary(rows: rows, counts: counts, scopeFolders: scopeFolders) },
            trailing: { lensTrailing(rows: rows, counts: counts) }
        )
    }

    /// Row 1 of the header card: **navigation, not a name.**
    ///
    /// It used to say the workspace's own title, because the lens tabs had just moved to the
    /// window's workspace bar and the column would otherwise have had no statement of what it was
    /// showing. The bar says it — the selected segment reads "Organize" or "Storage" three
    /// centimetres above this — so the card repeated it, and repetition is the one thing a fixed
    /// 81pt header cannot afford: it spent the most prominent row in the lens saying a word the
    /// chrome already said.
    ///
    /// So Organize gives the row to its rail, which names where you are *more* precisely than the
    /// title did (the ringed item is the lens, not just the workspace). **Storage has a rail of its
    /// own now** — All and its three ranked lists — which is what fills the leading half the intro
    /// button used to hold. Its per-list counts moved onto it; what stays on row 2 is what belongs
    /// to the whole report rather than to one list.
    @ViewBuilder
    private func lensTitle(_ counts: RailCounts) -> some View {
        HStack(spacing: 6) {
            // **Promoting Storage's readout here was tried and was worse**, and the rail below is
            // not that: the readout is prose whose width is a property of the data, so "Documents"
            // truncated to a bare folder glyph and row 2 went empty. A rail is four fixed-width
            // places that leave row 2 its folder, total and freshness. The failure is worth keeping
            // written down, because "put the storage readout on row 1" will look like a good idea
            // again.
            if lens == .storage {
                // **Storage's own rail, in the half the intro button used to hold.** Removing that
                // button gave Organize's rail 21pt; Storage had none, so it gave Storage an
                // empty row — a 27pt band with two controls floated right and nothing on its
                // leading two-thirds, on a card whose height is pinned whatever it holds.
                //
                // The page was already three ranked lists under a treemap. The rail turns each into
                // a place, counts all three (the header used to count two — `stale` had a full
                // section in the body and no pill above it), and gives Storage the same idiom
                // Organize has rather than a second one.
                storageRail
            } else {
                organizeRail(counts)
            }
        }
    }

    /// What each of Storage's sections has to say — the one accessor the rail and the width model
    /// both read, so the two cannot size and draw different rows.
    private var storageRailState: (StorageSection) -> RailItemState {
        let report = syncManager.storageLensReport
        return { section in
            guard let report else { return .notScanned }
            let n = section.entries(in: report).count
            return n > 0 ? .reporting(n) : .clean
        }
    }

    /// Storage's rail: All, then its three ranked lists.
    ///
    /// Measured at 417.8pt against a ~130pt trailing set, so it never sheds at any width this app
    /// is used at — but it takes ``railStyle`` anyway, because the one thing worse than a rail that
    /// sheds is two rails in one header that shed by different rules.
    @ViewBuilder
    private var storageRail: some View {
        let state = storageRailState
        storageRailItem(nil, state: .configuration)
        railSeparator
        ForEach(StorageSection.allCases) { section in
            storageRailItem(section, state: state(section))
        }
    }

    /// One item on Storage's rail. `nil` is All.
    ///
    /// **The count is absent before a report, not zero** — the same rule Organize's badge follows.
    /// A storage lens that has not run cannot claim there are no large files; it can only say it
    /// has not looked, which is what `.notScanned` draws.
    private func storageRailItem(_ section: StorageSection?, state: RailItemState) -> some View {
        let isSelected = storageSection == section
        return Button {
            withAnimation(listSettle) { storageSection = section }
        } label: {
            RailItemLabel(title: section?.railTitle ?? OrganizeRailMetrics.overviewTitle,
                          systemImage: section?.railSymbol ?? OrganizeRailMetrics.overviewSymbol,
                          state: state, isSelected: isSelected,
                          accent: glassHue.accentColor, style: railStyle)
        }
        .buttonStyle(.plain)
        .chromeHover()
        .help(section.map { "\($0.title) — \($0.subtitle)." }
              ?? "Every ranked list, under the treemap.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                //
                // The folder-memory status used to sit here, immediately before Rescan, and it is
                // on row 2 now — see ``folderMemoryStatus``. Row 1 is fixed-width controls only,
                // which is what lets ``OrganizeRailMetrics/searchToggleWidth`` be a number at
                // all.
                // Two buttons behind one name — see ``showsFilingControl`` for why Rescan's gate is
                // not the moved branch's, and where the moved branch stands down.
                if showsFilingControl {
                    rescanFilingButton
                }
                // The apply actions stay with their own list: each acts on the rows on screen, so
                // each is gated on there being some, and each is handed the FILTERED rows for the
                // reason `applyAllButton` spells out — the label counts what the action receives.
                switch organizeLens {
                case .toFile:
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
                // The overview offers no apply-all of its own, deliberately: an "apply" up here
                // would have to mean one of six different things, and the one it picked would be
                // the one nobody meant. Each section's own button is one click away.
                case .none, .duplicates, .restructure, .rules:
                    EmptyView()
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
    private func lensSummary(rows: FilteredRows, counts: RailCounts, scopeFolders: Int?) -> some View {
        // **The rail draws for EVERY Organize lens, which is why it cannot live inside one arm of
        // the switch below.** It did, briefly, inside `organizeSummary` — and that arm is reached
        // only on the filing apparatus, so standing on Duplicates or Rules rendered the lens's own
        // pills and no rail at all: the six places you navigate by, gone, on two of the six lenses
        // they navigate to. Caught by installing the build and looking at it, not by any test here.
        // **The rail lives on row 1 now** (see `lensTitle`) — it is not drawn here. It was, for
        // one build, and row 1 got a copy without row 2 losing its own: six capsules over six
        // identical capsules. Moving a slot means swapping it, not adding it.
        //
        // And no arm draws a leading divider any more: row 2 is purely the readout now, so a rule
        // at its head separates prose from the left edge of the card. `SummaryZoneDivider` marks
        // the boundary between controls and prose, and with the controls a row above there is no
        // boundary on this row to mark.
        //
        // **The scope chip draws for EVERY Organize lens, for the same reason the rail does** — and
        // it very nearly repeated the rail's exact bug. It was first written inside
        // `organizeSummary`, which is reached only from the `.rename`/`.filing` arms below, so
        // Duplicates and Rules would have shown no scope at all: two of the six lenses silently
        // claiming to answer about the whole tree while the other four named a subtree. One subject
        // for all six is the entire premise, so it is hoisted here, ahead of the switch.
        //
        // Storage is excluded because it is a workspace of its own, not a lens inside Organize.
        if lens != .storage { scopeChip(folderCount: scopeFolders) }
        switch effectiveLens {
        case .duplicates:
            if hasResults {
                duplicatesSummary(rows.duplicates)
            }
        // Both of Organize's states, through one path. `.rename` reaches here only as an EFFECTIVE
        // lens, from Organize: no workspace claims it, which `WorkspaceTests` pins directly
        // (`Workspace.allCases.compactMap(\.lens)` excludes `.rename`), so `lens` is never `.rename`
        // to begin with. The other four sites in this file switch on `effectiveLens` on exactly that
        // understanding — a `lens == .filing` guard on this one alone would not make the invariant
        // any truer, it would just make this the one place that disagrees about who enforces it.
        case .rename, .filing:
            organizeSummary(rows: rows, counts: counts)
        case .automations:
            if !syncManager.automationRules.isEmpty {
                automationsSummary(rows.rules)
            }
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
    private func organizeSummary(rows: FilteredRows, counts: RailCounts) -> some View {
        // Readout only — ``lensSummary`` draws the rail above every lens, and the divider that
        // separates navigation from prose with it. What is left here is the scope and the numbers,
        // which belong to the SELECTED lens: leading the row, the scope read as qualifying
        // whatever came next, and what comes next is another lens's item, which it does not scope.
        //
        // Nothing here renders mid-scan for the three lenses whose lists the filing scan
        // republishes — see ``OrganizeLens/goesStaleDuringFilingScan``.
        // The three `scannedFolderChip` roots that used to lead these arms — `filingScanFolder` for
        // the queue, `nameScanRoot` for names, `filingLastProviderRoot` for renames — are gone,
        // replaced by the ONE scope chip `lensSummary` draws above every lens. Three chips naming
        // three different territories is what made six rail items look like peers answering about
        // one subject when they answered about four.
        // **The overview is tested for on its own, not reached through the `else` of the guard
        // below.** Written as `if let organizeLens, !stale { … } else { overviewSummary }` it read
        // correctly and was wrong: the `else` catches *both* arms of a compound condition, so a
        // lens that had gone stale mid-scan — To File, Names or Renames, exactly the three the
        // guard exists for — fell through to the overview's readout and drew "1 reporting · 2
        // clean" under a selected lens while its own scan was running. Suppressing a stale readout
        // must leave the row empty, which is what the guard was for; it must not substitute a
        // different lens's answer.
        if organizeLens == nil {
            // **The overview's own readout.** Row 2 was blank here — the switch below is keyed on a
            // selected lens and the overview has none — which was tolerable while the overview was
            // a state you fell into, and is not now that "All" is a place you can point at. A
            // destination with an empty readout row looks like one that failed to load.
            //
            // It says what the rail says, in words: how many lenses have something, how many came
            // back clean, how many have not run. The third number is the one no other surface on
            // this row can state, and the reason `RailItemState` keeps clean and unscanned apart.
            overviewSummary(counts)
        } else if let organizeLens,
                  !(organizeLens.goesStaleDuringFilingScan && syncManager.isSuggestingFiles) {
            switch organizeLens {
            case .toFile:
                if hasFilingResults { filingSummary(rows.filing) }
            case .names:
                if syncManager.hasScannedNames { renameSummary(rows.risky) }
            case .renames:
                // The FILTERED plans, like the queue's readout beside it and unlike the rail badge
                // that got you here: a badge is a signpost and counts its whole list, a readout
                // describes the rows on screen. Typing `PG&E` should watch this fall from 1,192
                // renames to the eleven it left showing.
                renameBacklogSummary(rows.renames)
            // Duplicates and rules reach `lensSummary` through their own apparatus arms, so they
            // never arrive here; restructure has no readout of its own.
            case .duplicates, .restructure, .rules:
                EmptyView()
            }
        }
    }

    /// "3 reporting · 2 clean · 1 not scanned" — the rail, said in prose.
    ///
    /// Absent parts rather than zeroes, the same rule the badge follows: "0 not scanned" is noise,
    /// and a row of three zeroes says nothing at all.
    @ViewBuilder
    private func overviewSummary(_ counts: RailCounts) -> some View {
        let states = OrganizeLens.allCases.map(counts.state)
        let reporting = states.count { if case .reporting = $0 { return true } else { return false } }
        let clean = states.count { $0 == .clean }
        let unscanned = states.count { $0 == .notScanned }
        let parts = [
            reporting > 0 ? "\(reporting) reporting" : nil,
            clean > 0 ? "\(clean) clean" : nil,
            unscanned > 0 ? "\(unscanned) not scanned" : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .scaledFont(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    /// The one chip naming what Organize is answering about.
    ///
    /// **Absent in the global view.** Global is the absence of a scope, not a chip reading
    /// "Everything" — a chip that is always present would make the scoped and unscoped states look
    /// like two flavours of the same thing rather than a narrowing and its absence.
    ///
    /// It names the subtree **and its folder count**, because scope honesty was the original
    /// requirement: "Legal" alone says which folder but not how much of the tree that is, and the
    /// count is what makes "0 findings" legible as a real answer rather than a broken lens.
    ///
    /// The ✕ is the global view. There is no seventh rail place and no "Everything" item.
    ///
    /// **It draws from ``storedScope``, not from the applied ``scope``, and that is the whole
    /// reason Rules can suspend the scope safely.** A chip that vanished on Rules would say the
    /// scope had been *lost*, and the user's next move would be to set it again — which is the
    /// one-way trip stated the other way round. Suspended, the chip keeps naming the folder they
    /// chose and says, in its tooltip, that it comes back.
    @ViewBuilder
    private func scopeChip(folderCount: Int?) -> some View {
        if let storedScope {
            let suspended = scopeIsSuspended
            ScopeChipLabel(name: storedScope.name,
                           folderCount: folderCount,
                           accent: glassHue.accentColor,
                           isSuspended: suspended,
                           // No ✕ while suspended: there is nothing to clear *here*, and a ✕ that
                           // threw away a scope this lens is not even using would be the trip.
                           onClear: suspended ? nil : { withAnimation(listSettle) { setScope(nil) } })
                .help(suspended
                      ? "Rules are configuration, not findings, so they are not narrowed by a "
                        + "folder — they file into destinations all over the source. “"
                        + "\(storedScope.relativePath)” comes back when you leave Rules."
                      : "Every lens below is answering about “\(storedScope.relativePath)”. "
                        + "✕ goes back to the whole tree.")
        }
    }

    /// How many of the profile's folders sit inside the scope, or nil when there is no profile to
    /// count against.
    ///
    /// Counted from the folder profile rather than by walking the disk — the profile is already in
    /// memory, and a chip in a header must not touch the filesystem on every render.
    /// How many of the profile's folders sit inside the scope, or **nil when that is unknown**.
    ///
    /// Unknown covers two cases and neither may render as a number: there is no profile at all, and
    /// the scope is a folder the survey has never seen (created since, or outside what was
    /// surveyed).
    ///
    /// **Zero is the tell, and it can only mean unsurveyed.** A scope that the profile knows about
    /// always counts at least itself — `PathBoundary.contains(p, under: p)` is true — so a count of
    /// zero cannot mean "an empty subtree", only "not in the survey". Rendering it as "Legal · 0
    /// folders" would read as *empty*, which is the same zero-versus-absent confusion the rail's
    /// badge rule exists to prevent. `ScopeChipLabel` omits the count for nil, so the chip says
    /// "Legal" and claims nothing it cannot support.
    ///
    /// Counted from the profile rather than by walking the disk — the profile is already in memory,
    /// and a chip in a header must not touch the filesystem. Resolved once per render by `body`.
    ///
    /// Counted against ``storedScope``, like the chip it feeds: how big that subtree is stays true
    /// while Rules is not applying it, and a count that blinked out on one lens would read as the
    /// survey having lost the folder.
    private var scopeFolderCount: Int? {
        guard let scope = storedScope, let profile = syncManager.filingFolderProfile else { return nil }
        let root = (profile.root as NSString).expandingTildeInPath
        let inside = profile.folders.keys.count {
            let absolute = $0 == "." ? root : (root as NSString).appendingPathComponent($0)
            return scope.contains(absolute)
        }
        return inside > 0 ? inside : nil
    }

    /// Organize's lens rail: six permanent places, each carrying a badge only when it has
    /// something to report.
    ///
    /// **The rail is the chips row made persistent.** The chips were absent at zero on the
    /// argument that a rare finding should announce itself and cost nothing otherwise. That is
    /// still right about the *badge*, and ``OrganizeLens/badge(count:)`` keeps it. It is wrong
    /// about the *place*: "Organize this folder" has to land somewhere before any scan has run,
    /// and you cannot point at a chip that does not exist yet.
    ///
    /// Selection is a **ring**, the same affordance the focused pane's provider capsule wears —
    /// an `.overlay`, which takes its size from the host and gives none back, so it cannot push
    /// this row out of the header's pinned height. The overview is the state where no ring is
    /// drawn at all.
    @ViewBuilder
    private func organizeRail(_ counts: RailCounts) -> some View {
        // **"All" first, because the overview needs a place that exists at zero.** That is the
        // rail's own founding argument, turned on the one state it had not applied it to: the
        // overview is what you land on and what every lens's answer is summarised on, and the only
        // way back to it was clicking the selected item a second time — a gesture nothing on screen
        // describes. The item does not add a state; it names one that was already there.
        organizeOverviewRailItem(counts)
        railSeparator
        ForEach(OrganizeLens.allCases.filter(\.carriesBadge)) { item in
            organizeRailItem(item, counts)
        }
        // **Rules behind a second rule, because it is not a finding.** Five lenses report what a
        // scan turned up; this one is configuration you keep. It has always been the one item that
        // cannot wear a badge, and in a row of peers that read as "a lens that found nothing" —
        // the separator says *different kind of thing* structurally instead of leaving it to be
        // inferred from an absence.
        railSeparator
        ForEach(OrganizeLens.allCases.filter { !$0.carriesBadge }) { item in
            organizeRailItem(item, counts)
        }
    }

    /// The hairline between the rail's three groups.
    private var railSeparator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
            .accessibilityHidden(true)
    }

    /// The overview's own rail item.
    ///
    /// Selected exactly when no lens is — it *is* the unselected state, given somewhere to live —
    /// and it carries no count of its own: a number here would have to mean the sum of six
    /// different kinds of thing, which is not a quantity anyone wants.
    private func organizeOverviewRailItem(_ counts: RailCounts) -> some View {
        let isSelected = organizeLens == nil
        return Button {
            withAnimation(listSettle) { railLens = nil }
        } label: {
            RailItemLabel(title: OrganizeRailMetrics.overviewTitle,
                          systemImage: OrganizeRailMetrics.overviewSymbol,
                          state: .configuration, isSelected: isSelected,
                          accent: glassHue.accentColor, style: railStyle)
        }
        .buttonStyle(.plain)
        .chromeHover()
        .help("Every lens's answer for what Organize is pointed at, on one page.")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// One rail item.
    @ViewBuilder
    private func organizeRailItem(_ item: OrganizeLens, _ counts: RailCounts) -> some View {
        // `counts.badge(_:)`, not the rule restated — the same answer today, and deliberately the
        // same *call* the width model makes. The model measures the badge it is told this item
        // wears; if the two reach that answer down separate paths, a later rule (suppress a badge
        // past four digits, say) moves one and not the other, and the arithmetic starts sizing a
        // rail nobody draws. That divergence is this type's whole failure mode.
        let badge = counts.badge(item)
        let isSelected = organizeLens == item
        Button {
            // Clicking the selected item widens back out to the overview. That still works and is
            // still the quickest way back — "All" gives the same state a place you can point at
            // rather than replacing the gesture.
            withAnimation(listSettle) { railLens = isSelected ? nil : item }
        } label: {
            RailItemLabel(title: item.title, systemImage: item.symbol, state: counts.state(item),
                          isSelected: isSelected, accent: glassHue.accentColor, style: railStyle)
        }
        .buttonStyle(.plain)
        .chromeHover()
        .help(item.help(state: counts.state(item)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The number a rail item's badge would carry — **the whole list it names, never the filtered
    /// view of it.** A badge is a signpost and its number is that destination's size; one that
    /// renumbered as you typed would be a moving target, and the badge for the list you are *not*
    /// looking at would be filtered by a query you cannot see.
    /// ...and **counted within the scope**, which is the one narrowing a badge must respect.
    ///
    /// A badge is a claim about the list behind it, and under a scope that list is the scoped one.
    /// Leaving these global would put "126" on Renames next to a list showing three — the precise
    /// dishonesty this whole change exists to remove. It is not the same thing as filtering by the
    /// search query, which stays out (see above): a query is a transient view of a list you are
    /// already looking at, while the scope defines *which list this is*.
    ///
    /// ## Resolved ONCE per render, for the same reason `FilteredRows` is
    ///
    /// Scoping turned six `Array.count` reads — O(1) each — into six filtering passes with path
    /// math in the predicate, over lists that reach 722 duplicate groups and 1,192 rename plans on
    /// the real profile. And they were being run **twice over**: `railBadgeCount` asks all six so
    /// the width arithmetic knows how many badges to reserve for, then `organizeRailItem` asks
    /// again per item. Twelve full scans per render of a header that re-renders on every manager
    /// publish, every hover and every defaults change.
    ///
    /// That is the rule this file already states one screen up — `structureFindings` is cached on
    /// the manager precisely because *a view body must not run the detector* — arriving through a
    /// cheaper-looking door. Counting is not detecting, but twelve passes over 722 groups is not
    /// free either, and the fix is the one already in use for rows: resolve once, hand the same
    /// value to both consumers.
    struct RailCounts: Equatable {
        var toFile = 0, duplicates = 0, names = 0, renames = 0, restructure = 0, rules = 0
        /// Which lenses have actually run here. **A zero means two different things without this**
        /// — ran and found nothing, or never looked — and the rail used to draw both the same way
        /// while the overview was careful to keep them apart. Same facts, one vocabulary.
        var scanned: Set<OrganizeLens> = []

        subscript(item: OrganizeLens) -> Int {
            switch item {
            case .toFile: return toFile
            case .duplicates: return duplicates
            case .names: return names
            case .renames: return renames
            case .restructure: return restructure
            case .rules: return rules
            }
        }

        /// The badge an item is carrying, or nil — **the value, not merely the fact of one**, which
        /// is what `OrganizeRailMetrics` reserves width for.
        ///
        /// This replaces a `badged` *count*. The width arithmetic charged a flat two-digit figure
        /// per badge, and Duplicates wears `410` while Renames wears `126`; those cost ~8pt more
        /// apiece than the flat figure allowed, which is part of why row 1 truncated its actions
        /// while the model still reported room. ``OrganizeRailMetrics/badgeWidth(_:scale:)``
        /// measures the digits it is handed.
        func badge(_ item: OrganizeLens) -> Int? {
            item.badge(count: self[item])
        }

        /// What this item has to say, in the vocabulary ``RailItemState`` and
        /// ``OrganizeOverviewState`` share.
        ///
        /// Rules answers `.configuration` ahead of everything else: it is a set of rules you keep,
        /// so it neither reports nor goes quiet — both of those describe a scan it never runs.
        /// That is the same distinction ``OrganizeLens/carriesBadge`` already draws, said in the
        /// one place the item's whole dress is decided.
        func state(_ item: OrganizeLens) -> RailItemState {
            guard item.carriesBadge else { return .configuration }
            if let badge = badge(item) { return .reporting(badge) }
            return scanned.contains(item) ? .clean : .notScanned
        }
    }

    private var railCounts: RailCounts {
        // **The STORED scope, not the applied one, and this is the whole reason the two are
        // separate.** `scope` answers "what is the list on screen narrowed by", which is nil while
        // Rules is selected. The rail draws all six badges whatever is selected, so reading it here
        // would take Duplicates from 27 back to 620 the moment you clicked Rules — the scope
        // silently lifting off five lenses because a sixth does not use it. Each item is asked for
        // its own scope, through the same `isScoped` rule the content card obeys.
        // **`inside` only for restructure**: an ancestor finding is shown in the lens (labelled as
        // being about the folder above) but must not swell the badge, which promises work *here*.
        //
        // Restructure used to return a hard 0 behind a comment saying the detectors had not landed.
        // They had — `structureFindings` has been feeding the overview and the lens for some time —
        // so the one lens whose badge could have announced a finding never did.
        let profileRoot = syncManager.filingFolderProfile?.root ?? ""
        return RailCounts(
            toFile: syncManager.filingSuggestions.count {
                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .toFile)) },
            duplicates: syncManager.duplicateGroups.count {
                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .duplicates)) },
            names: syncManager.riskyNames.count {
                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .names)) },
            renames: syncManager.renamePlans.count {
                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .renames)) },
            restructure: structureFindings.count {
                OrganizeScopeFilter.relation(of: $0, profileRoot: profileRoot,
                                             scope: appliedScope(for: .restructure)) == .inside
            },
            // No scope test, because `appliedScope(for: .rules)` is always nil — a call written
            // here would read like a live narrowing and be one that can never fire.
            rules: syncManager.automationRules.count,
            // The same conditions ``overviewSections`` uses, so the rail and the overview cannot
            // disagree about whether a lens has run. Rules is absent because it never scans.
            scanned: {
                var ran: Set<OrganizeLens> = []
                if syncManager.hasSuggestedFiling { ran.insert(.toFile); ran.insert(.renames) }
                if syncManager.hasFoundDuplicates { ran.insert(.duplicates) }
                if syncManager.hasScannedNames { ran.insert(.names) }
                if syncManager.filingFolderProfile != nil { ran.insert(.restructure) }
                return ran
            }())
    }

    /// What each rail item promises. Written to read correctly whether or not it is the selected
    /// one — selection is carried by the ring and by `.isSelected`, not by swapping the words.
    ///
    /// **It takes the state, not the badge, because `badge ?? 0` was telling a lie the rest of this
    /// change exists to stop.** A nil badge means "no number to show", which is true of a lens that
    /// scanned and found nothing *and* of one that has never run — and this read the second as the
    /// first, so a never-scanned queue's tooltip said "0 loose files **this scan found**", asserting
    /// a scan that had not happened. The three states have three different sentences.
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


    /// Row 2's trailing edge: what the last folder-memory survey did, then "N of M" whenever this
    /// lens's list is narrowed, so a shortened list always reads as a filtered view rather than as
    /// the whole result.
    ///
    /// **The survey status is here rather than on row 1 because it is prose, and row 1 is
    /// controls.** That is the card's own division — `lensSummary` says it for the readout — and
    /// row 1 broke it: `folderMemoryStatus` sat between the rail and Rescan, so a sentence whose
    /// length is a property of the last survey was competing with the buttons for the row. See
    /// ``folderMemoryStatus`` for what that cost.
    ///
    /// **M is the SCOPED list, not the whole tree.**
    ///
    /// This read `syncManager.duplicateGroups.count` and friends — the global lists — so under a
    /// scope it said "3 of 722" about a lens holding 27. The denominator described a list the user
    /// was not looking at, which is the exact dishonesty the scope exists to remove, restated in
    /// the one readout whose whole job is to say how much the search is hiding.
    ///
    /// `counts` is the right denominator and costs nothing: it is the same scoped-but-unsearched
    /// tally the rail badges use, already resolved once for this render. The relationship is
    /// unchanged — N is the rows on screen, M is the list before the *transient* narrowing — only
    /// the definition of "this list" now matches what the header claims above it.
    ///
    /// Storage is untouched: it is a workspace of its own with no Organize scope.
    @ViewBuilder
    private func lensTrailing(rows: FilteredRows, counts: RailCounts) -> some View {
        // Same gate the control had on row 1: the filing apparatus, once a scan has finished, and
        // not while one is running. The status describes an action reachable only from the Rescan
        // menu, which is drawn under exactly this condition — so moving the readout must not
        // silently widen where it appears.
        if effectiveLens == .rename || effectiveLens == .filing,
           !syncManager.isSuggestingFiles, syncManager.hasSuggestedFiling {
            folderMemoryStatus
        }
        if isFiltered {
            switch effectiveLens {
            case .duplicates: ofMLabel(rows.duplicates.count, counts.duplicates)
            case .rename: ofMLabel(rows.risky.count, counts.names)
            case .filing where showingRenameBacklog:
                // The backlog's own numbers. Left as the queue's, this said "3 of 24" about a list
                // that is not on screen while the backlog sat under it unfiltered.
                ofMLabel(rows.renames.count, counts.renames)
            case .filing: ofMLabel(rows.filing.count, counts.toFile)
            case .automations: ofMLabel(rows.rules.count, counts.rules)
            case .storage:
                let storage = storageCounts
                ofMLabel(storage.filtered, storage.total)
            }
        }
        // **This lens's controls, at the end of row 2.** They were row 1's trailing half, opposite
        // the rail, and the two could not both have it: the rail spells out at 693pt and To File's
        // controls need 490, so row 1 wanted 1,183pt of card before it would show six names. Every
        // window narrower than that got the glyph-only rail instead — which is most of them.
        //
        // Down here they cost the row nothing that competes with navigation, because what they sit
        // beside is prose that can shorten (see ``folderMemoryStatus``) rather than six
        // destinations that cannot. Row 1's reserve collapses to the search toggle alone, and the
        // shed threshold with it — see ``OrganizeRailMetrics/searchToggleWidth``.
        //
        // The divider is what keeps the old objection answered. Controls were pulled OFF this row
        // once because the readout and the buttons had become indistinguishable; the rule that
        // settled it is prose on the leading side, controls on the trailing side, one hairline
        // between. That rule is intact — the boundary is just back on this row rather than being a
        // row break.
        if hasRowTwoActions {
            summaryZoneDivider
            lensActions(rows: rows)
        }
    }

    /// Whether this lens draws any control on row 2 — the gate on the divider, so a lens with no
    /// actions does not draw a rule against nothing.
    ///
    /// Deliberately mirrors ``lensActions``'s own gates rather than asking whether it produced a
    /// view: a `@ViewBuilder` cannot be asked whether it is empty, and a divider that appears
    /// beside an empty band is exactly the "rule separating prose from the card edge" this file
    /// already rejected once.
    private var hasRowTwoActions: Bool {
        switch effectiveLens {
        case .duplicates:
            return hasResults && !syncManager.isFindingDuplicates
        case .rename, .filing:
            guard !syncManager.isSuggestingFiles else { return false }
            // **The same member ``lensActions`` draws from, not a hand-copy of its condition.**
            // That is the whole point of ``showsFilingControl`` existing: this switch is otherwise
            // a transcription of `lensActions`'s gates, and a transcription of a compound condition
            // is how a divider comes to be drawn beside a control that is not there (or withheld
            // from one that is). On the overview this clause is the only one that can be true.
            if showsFilingControl { return true }
            switch organizeLens {
            case .toFile: return hasFilingResults
            case .names: return !syncManager.riskyNames.isEmpty
            case .renames: return !syncManager.renamePlans.isEmpty
            case .none, .duplicates, .restructure, .rules: return false
            }
        case .automations:
            return !syncManager.automationRules.isEmpty
        case .storage:
            return hasStorageReport && !syncManager.isBuildingStorageLens
        }
    }

    /// The hairline between row 2's prose and row 2's controls.
    ///
    /// Named for the type that used to do this job before the controls moved up to row 1 and it was
    /// deleted; it marks the same boundary for the same reason.
    private var summaryZoneDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
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
    private func lensBody(rows: FilteredRows, counts: RailCounts, scopeFolders: Int?) -> some View {
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
                    onQuickLook: onQuickLook.map { ql in { path in ql(URL(fileURLWithPath: path)) } },
                    section: storageSection
                )
            } else {
                contentCard(rows: rows, counts: counts, scopeFolders: scopeFolders)
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

    /// True once the focused pane has moved away from **the subject** — the cue to offer re-aiming
    /// at the new folder.
    ///
    /// Measured against the scope when there is one, and against the lens's own scanned root when
    /// there is not. That swap is the point: with a scope set, the scan root is an implementation
    /// detail of how the answer was computed, while the scope is what the answer is *about*, so
    /// "have you wandered off?" is a question about the scope.
    ///
    /// **Browsing never moves the scope on its own** — this only decides whether to *offer*. It is
    /// the offer that `targetMoved` always was; what changed is that accepting it now re-aims
    /// everything rather than quietly re-rooting one lens.
    /// Storage is excluded from the scope for the same reason it has no rail: it is a workspace of
    /// its own, and Organize's subject is not its subject. Reading `scope` unguarded here would let
    /// an Organize scope decide when Storage offers to re-analyze — the cross-workspace leak
    /// `organizeLens` already guards against on the lens selection. It passes no `rootFallback`
    /// either, and for the same reason: "everything" is a claim about Organize's subject, and
    /// Storage's re-analyze button moves no scope at all.
    ///
    /// `rootFallback` is the third rung of ``OrganizeAim/subject(scope:scannedRoot:providerRoot:)``
    /// — see there for why an unscoped, unscanned Organize is answering about the provider root
    /// rather than about nothing.
    private func targetMoved(from scannedRoot: String?, rootFallback: String? = nil) -> Bool {
        OrganizeAim.paneMovedAway(paneFolder: scanTargetFolder,
                                  scope: lens == .storage ? nil : scope,
                                  scannedRoot: scannedRoot,
                                  providerRoot: rootFallback)
    }

    /// A rescan button that becomes a prominent "Organize '<folder>'" once the user has navigated
    /// away, so navigate-then-re-aim is one obvious click. Shared shape for both lenses.
    ///
    /// **The two branches are different verbs now, and they take different actions.** Rescan
    /// re-runs the current subject's scan and must leave the scope exactly where it is. The moved
    /// branch is the user pointing somewhere new, so it goes through `reaim`, which sets the scope
    /// first. Sharing one action between them — which is how this started — meant a plain Rescan
    /// while scoped to `Legal` from a pane sitting elsewhere would silently drag the scope along.
    ///
    /// `movedTitle` overrides the moved branch's Organize wording — and with it the
    /// ``reaimClearsScope`` swap, whose label and help both describe *scope* semantics. Storage
    /// passes one because it participates in none of that: it is a workspace of its own, its
    /// `reaim` is a plain re-analyze, and the shared wording had it promising `Organize "X"` —
    /// or, at the provider root, "clears the scope" — for a click that touches no scope at all.
    /// The action was right and the words lied, and browsing (which now moves the target on every
    /// column click) surfaced that label constantly.
    @ViewBuilder
    private func rescanButton(moved: Bool, movedIcon: String, disabled: Bool,
                              action: @escaping () -> Void, reaim: @escaping () -> Void,
                              movedHelp: String, movedTitle: String? = nil) -> some View {
        if moved {
            Button(action: reaim) {
                if let movedTitle {
                    Label(movedTitle, systemImage: movedIcon)
                } else {
                    Label(reaimClearsScope ? "Organize everything" : "Organize “\(scanTargetName)”",
                          systemImage: reaimClearsScope ? "square.stack.3d.up.slash" : movedIcon)
                }
            }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .chromeHover()
                .disabled(disabled)
                .help(movedTitle == nil && reaimClearsScope
                      ? "The pane is at the top of the tree, so this clears the scope and answers "
                        + "about everything again."
                      : movedHelp)
        } else {
            Button(action: action) { Label("Rescan", systemImage: "arrow.clockwise") }
                .chromeButtonStyle(glassLevel).controlSize(.small)
                .chromeHover()
                .disabled(disabled).help("Scan this folder again")
        }
    }

    /// Whether re-aiming at the pane's folder would **clear** the scope rather than set one.
    ///
    /// True exactly when the pane sits at the provider root, because that is what
    /// ``OrganizeScope/init(path:providerRoot:)`` normalizes to the global view.
    ///
    /// **Found by installing the build and looking at it**, not by any test here. Scoped to `Legal`
    /// with the pane at the provider root, the button read `Organize "Documents"` and its tooltip
    /// promised "Every lens narrows to it" — while clicking it widens to the whole tree. The
    /// action was right and only the words were wrong, which is the kind of defect a green suite
    /// is least likely to notice: nothing misbehaves, the label just lies about which direction
    /// the click goes.
    private var reaimClearsScope: Bool {
        guard let target = scanTargetFolder, !target.isEmpty,
              let providerRoot, !providerRoot.isEmpty else { return false }
        return OrganizeScope(path: target, providerRoot: providerRoot) == nil
    }

    /// Re-aims Organize at the focused pane's folder: set the scope, then scan.
    ///
    /// Routed through ``setScope(_:)``, so pointing at the provider root clears the scope instead
    /// of setting one — navigating to the top of the tree and clicking is therefore also how you
    /// get back to the global view. ``reaimClearsScope`` is what makes the button say so.
    private func reaimAtScanTarget(then scan: @escaping () -> Void) {
        setScope(scanTargetFolder)
        scan()
    }

    /// What the folder-memory re-survey is doing, or what it found. **Row 2** — see
    /// ``lensTrailing(rows:)``.
    ///
    /// **The commonest outcome is that nothing changed, and that has to be visible.** A menu item
    /// that reads only a few folder mtimes and writes nothing looks broken otherwise — the user
    /// clicks it, the tree is already current, and there is no evidence it ran at all.
    ///
    /// ## Why it is bounded, and why it is not on row 1
    ///
    /// `FilingSurveyReport.summary` is prose whose length is a property of the last survey rather
    /// than of the layout — "12 folders changed, 340 documents read, 8 followed a move, 3 left the
    /// tree, 5 not downloaded yet." is 485pt of caption. Drawn unbounded on row 1 it did two
    /// things, both measured off the render:
    ///
    /// - **It took the actions' words.** With a refine offer beside it the trailing set came to
    ///   **921pt**, against 354 for Duplicates, and SwiftUI resolved the overrun the way it always
    ///   does — by truncating the flexible side. At a 1200pt card that is `Refine with…` and
    ///   `File all 24 co…`: two buttons that no longer say what they do, and one of them spends
    ///   money.
    /// - **It wrapped the row.** Row 1 is a fixed 27pt inside a fixed 81pt card
    ///   (``LensHeaderMetrics``), and a `Text` with no `lineLimit` takes a second line rather than
    ///   clipping. At 1400 it did, and two caption lines only just fit 27pt at the default text
    ///   size — at Large the card's opening has 0.4pt to give.
    ///
    /// No reserve fixes that, which is the point: sizing
    /// a trailing reserve sized for 921 would have stripped the rail's labels out to
    /// ~1316pt of card width, which is most real windows. So the prose moved to the row that is
    /// *for* prose, where there is genuine room beside the readout. Measured after the move, row
    /// 1's trailing set is 436.5pt with a report and 436.5 without — the report costs the row
    /// nothing — and the actions keep their words from 800pt of card width up, against a pre-move
    /// 600–925 and 1050–1225 where they did not.
    ///
    /// ## The two modifiers below are insurance, and today they are inert
    ///
    /// Both were added as backstops and **both were then mutation-tested and survived**, which is
    /// worth recording rather than leaving as an implied claim:
    ///
    /// - **`lineLimit(1)`/`truncationMode(.tail)`** — deleting them changes no pixel. Row 2 is a
    ///   fixed 22pt (``LensHeaderMetrics/summaryRow``), and a `Text` proposed that height has room
    ///   for one caption line, so it truncates whatever this says. On row 1 that was *not* true —
    ///   27pt seats two caption lines at the default text size, which is why the same string wrapped
    ///   there and only just fitted, with 0.4pt to spare at Large. So this is the modifier that
    ///   matters if the line ever moves back to a taller row, and it is cheap to keep saying.
    /// - **`layoutPriority(-1)`** — deleting it changes no pixel either. The row's other tenants are
    ///   the readout ("16 ready · 8 unsure · 340 reused") and the "N of M" filtered count, and both
    ///   are `.fixedSize()`, so this is already the only compressible thing on the row. It is the
    ///   right *statement* regardless — those two describe the list on screen and this describes a
    ///   menu action, so this is what should give way — and it is what keeps that true if either
    ///   sibling ever stops being fixed-size.
    ///
    /// `theSurveyReportIsWhatGivesWay` asserts the rendered outcome, which holds either way; no
    /// test pins the modifiers themselves, because the row as it stands cannot express their
    /// failure.
    @ViewBuilder
    private var folderMemoryStatus: some View {
        if let status = syncManager.filingSurveyLifecycle.status,
           syncManager.filingSurveyLifecycle.isRunning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(status).scaledFont(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .layoutPriority(-1)
        } else if let report = syncManager.filingSurveyReport {
            Text(report.summary)
                // **`scaledFont`, not `font`, and the move is what made it matter.** This was a
                // plain `.font(.caption)` on row 1, where it sat among AppKit controls that ignore
                // the app's text-size setting too, so nothing looked out of place. Row 2's tenants
                // all scale — `SummaryRun` and `ofMLabel` both take `scaledFont` — so an unscaled
                // caption beside them reads as a bug at `.extraLarge`: the numbers grow and the
                // sentence explaining them does not.
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                // The truncated tail has to be recoverable, so the tooltip carries the whole
                // sentence and not just the gloss it used to carry alone.
                .help("\(report.summary) \(report.foldersLearned) folders have learned content from the documents already filed in them.")
                .accessibilityLabel(report.summary)
        }
    }

    /// Whether the pane sits somewhere other than what Organize is answering about.
    ///
    /// One expression, read twice — by ``rescanFilingButton`` to pick its branch and by
    /// ``showsFilingControl`` to decide whether to draw the control at all. Split out because those
    /// two must agree: a gate that says "no control" while the button would have drawn its moved
    /// branch is exactly the state that was reported, and inlining the condition twice is how they
    /// drift back apart.
    private var filingTargetMoved: Bool {
        targetMoved(from: syncManager.filingScanFolder, rootFallback: providerRoot)
    }

    /// Whether To File's setup card is the thing on screen — the pre-scan state that carries its
    /// own folder-named invitation ("File loose files in Insurance", with a Start button).
    ///
    /// **Only To File has one.** `contentCard` routes the other three `.filing` rail items
    /// elsewhere: the overview to `organizeOverview`, Restructure to a lens whose empty state
    /// points at Settings rather than at a scan, and Renames to a `RenamePassLens` that renders an
    /// empty list. Names is `.rename` and deleted its intro states outright — see
    /// `NameNormalizeLens`, which is reachable only when it already has findings. So this is a
    /// question about one lens, not a general "is something else inviting you" predicate.
    private var filingIntroOwnsInvitation: Bool {
        organizeLens == .toFile && !syncManager.hasSuggestedFiling
    }

    /// Whether the filing control is drawn at all — **the one gate, read by both places that must
    /// agree about it** (``lensActions`` draws it, ``hasRowTwoActions`` decides whether row 2 gets
    /// its hairline).
    ///
    /// Two clauses, and they are two different buttons:
    ///
    /// - `hasSuggestedFiling` is *Rescan*'s condition and is exactly right for it: a rescan with
    ///   nothing to re-scan describes something that never happened.
    /// - `filingTargetMoved` is the *moved* branch's, which is not a rescan — it points Organize at
    ///   the folder you are browsing and then scans. Someone who has never scanned wants that, so
    ///   it cannot inherit Rescan's gate; sharing one meant the only way to aim Organize from its
    ///   own header was to have already aimed it.
    ///
    /// **And the moved branch stands down where the intro card is already asking.** Before the
    /// first scan To File shows a large "File loose files in Insurance" card naming the same folder
    /// — two invitations to the same place, one of which also moves the scope, is the
    /// words-nearly-agree-actions-differ shape this file keeps having to remove. The rule the old
    /// gate encoded ("before the first scan the intro state owns the invitation") was right about
    /// To File all along; it was wrong only about the **four** places that reach this gate with no
    /// intro to own it — the overview, Renames and Restructure through `.filing`, and Names through
    /// `.rename`. Duplicates and Rules never read this: their apparatus arms are their own.
    private var showsFilingControl: Bool {
        guard !syncManager.isSuggestingFiles else { return false }
        return syncManager.hasSuggestedFiling || (filingTargetMoved && !filingIntroOwnsInvitation)
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
        if filingTargetMoved {
            rescanButton(moved: true, movedIcon: FilingGlyph.lens,
                         disabled: syncManager.isSuggestingFiles,
                         action: onFindFilingSuggestions,
                         reaim: { reaimAtScanTarget(then: onFindFilingSuggestions) },
                         movedHelp: "Point Organize at “\(scanTargetName)” — the folder now focused "
                             + "above. Every lens narrows to it.")
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
        // This button re-aims the whole workspace too, so it takes the same third rung. It is inert
        // here in practice — the control is gated on `hasResults`, and groups are published with
        // `duplicateScanRoot` — so this buys consistency of the *rule*, not a behaviour change.
        //
        // It does NOT make the two Organize buttons agree about the subject, and cannot: this one's
        // second rung is `duplicateScanRoot` and filing's is `filingScanFolder`, so with only one
        // of the two scans run they genuinely answer about different folders. That is a property of
        // per-lens scan roots, which the scope exists to override; it is not something a fallback
        // rung can fix.
        rescanButton(moved: targetMoved(from: syncManager.duplicateScanRoot,
                                        rootFallback: providerRoot),
                     movedIcon: "wand.and.stars", disabled: syncManager.isFindingDuplicates,
                     action: onFindDuplicates,
                     reaim: { reaimAtScanTarget(then: onFindDuplicates) },
                     movedHelp: "Point Organize at “\(scanTargetName)” and hash it — the folder now "
                         + "focused above. Every lens narrows to it.")
    }

    /// A leading chip naming the folder a lens's current results were **scanned from**.
    ///
    /// Distinct from the scope chip and it must stay distinct: the scope is the subject the user
    /// chose, this is the root a particular scan actually walked. They coincide most of the time
    /// and the sites below draw this one only when they do not, or when it means something the
    /// scope cannot say. `help` is required rather than defaulted so no call site can leave two
    /// folder chips on one row explaining nothing.
    @ViewBuilder
    private func scannedFolderChip(_ root: String?, help: String) -> some View {
        if let root {
            let name = (root as NSString).lastPathComponent
            Label(name, systemImage: "folder")
                .scaledFont(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(help)
        }
    }

    /// Duplicates' scanned root, shown **only when it is not the scope**.
    ///
    /// Duplicates is the one lens whose answer needs a scan of its own, so its root can genuinely
    /// disagree with the subject: scoping to `Legal` after hashing `Documents` filters real results,
    /// while scoping to `Legal` after hashing only `Finance` means this lens has never looked where
    /// you are pointing. Saying so is the honest half; restating the scope when the two agree would
    /// just be two chips reading the same folder name.
    @ViewBuilder
    private var duplicateScanRootChip: some View {
        if let root = syncManager.duplicateScanRoot {
            let name = (root as NSString).lastPathComponent
            // No scope: the chip is the only thing naming what was hashed, so it always draws.
            // With a scope: only when the two genuinely differ.
            if let scope {
                if standardizedPath(root) != standardizedPath(scope.path) {
                    scannedFolderChip(root, help: "Scanned from “\(name)”, which is not the folder "
                        + "Organize is scoped to — these results may not cover all of “\(scope.name)”.")
                }
            } else {
                scannedFolderChip(root, help: "These duplicate results were scanned from “\(name)”")
            }
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
    /// the filtered view — see `railCount(_:)`), and the scope
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
            duplicateScanRootChip
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
    /// No count pill: the Names rail badge carries it. Two capsules reading "17 risky names" side
    /// by side is what this row looked like the moment that badge arrived.
    ///
    /// It no longer names a root of its own. It used to lead with `nameScanRoot` — the whole
    /// provider — on the argument that the names check and the queue genuinely covered different
    /// territories and the difference was worth stating. That difference is exactly what this
    /// change removed: all six lenses answer about the one scope now, and the scope chip above says
    /// so once instead of each lens saying something different.
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
            // NOT the scope: rules are the one genuine non-scoper, and this names the
            // folder a PREVIEW would run over.
            //
            // The chip beside it used to be described here as saying "which rules are listed",
            // and that stopped being true when Rules stopped being scoped at all: the scope chip
            // is *suspended* on this lens (`OrganizeLens.isScoped`) and says so. So the two say
            // different things on purpose — the chip names a folder that is standing by, this
            // names the folder a preview would actually walk.
            scannedFolderChip(scanTargetFolder,
                              help: "A preview would run these rules over “\(scanTargetName)”")
            StatPill(count: rules.count, label: rules.count == 1 ? "automation" : "automations",
                     color: glassHue.accentColor, systemImage: AutomationsGlyph.lens)
            StatPill(count: enabled, label: "enabled", color: SemanticColor.success, systemImage: "checkmark.circle")
        }
    }

    /// Storage's pills. The total is the whole scanned tree's — a query filters the ranked lists,
    /// never the tree's size, so this figure must not move when you type.
    ///
    /// **The per-section counts are not here any more — they are on the rail**, where each sits on
    /// the place it describes and clicking it goes there. This row could only ever say how many.
    ///
    /// The rule they left behind is the one worth keeping: *every section the body draws is
    /// counted somewhere the reader can see*. It was broken here — `StorageLensView` lists three
    /// ranked lists and this row had pills for two, so "Untouched for a long time" was a full
    /// section with its own list that nothing above it announced. `StorageSection.allCases` is what
    /// makes that unrepeatable now, and `everySectionIsOnTheRail` pins it.
    ///
    /// What remains belongs to the whole report rather than to one list: the folder it is about,
    /// the total, and how old the numbers are.
    private func storageSummary(_ report: StorageLensReport) -> some View {
        Group {
            scannedFolderChip(syncManager.storageLensRoot?.path,
                              help: "This storage picture is for “\(((syncManager.storageLensRoot?.path ?? "") as NSString).lastPathComponent)”")
            Pill(.standard, tint: glassHue.accentColor, systemImage: "externaldrive",
                 text: "\(FileSyncManager.formatBytes(report.totalBytes)) total")
            // **The three counts are on the rail now**, where each sits on the place it describes
            // and clicking it goes there. They were StatPills here, and the row could only ever say
            // how many — never take you to them. What stays is what belongs to the whole report
            // rather than to one list: the folder, the total, and how old the numbers are.
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
            // groups IN SCOPE, not the search-narrowed `dupGroups`, so a badge never reads zero
            // for a filter that would reveal rows once picked — see `filterCounts` for why the
            // scope is the one narrowing it does honour.
            let counts = Self.filterCounts(syncManager.duplicateGroups, scope: scope)
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

    /// "Rename N files", over the plans on screen.
    ///
    /// `plans` is the same value the label counts and the action applies — the property
    /// `applyAllButton` above exists to preserve.
    ///
    /// **Gated on there being some**, like `fixAllButton`, `fileAllButton` and `applyAllButton` —
    /// it was the one of the four without a guard, and its caller's gate reads the GLOBAL backlog
    /// while the rows it is handed are the narrowed ones. With a search that was a corner (the
    /// content card shows "nothing matches" beside it); with a scope it is ordinary, because any
    /// subtree with no drifted folders empties this list while the tree still holds 126. The button
    /// rendered as a prominent, enabled **"Rename 0 files"** that applies nothing.
    ///
    /// The gate counts **files, not plans**: a plan whose steps have all been applied is still a
    /// plan, so `!plans.isEmpty` would leave the same zero-labelled button standing.
    @ViewBuilder
    private func renameAllButton(_ plans: [RenamePlan]) -> some View {
        let files = plans.reduce(0) { $0 + $1.steps.count }
        if files > 0 {
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
        // `reaim` is the plain action here: Storage is a workspace of its own and sets no Organize
        // scope. Re-analyzing it must not re-aim the six lenses in the workspace next door — and
        // `movedTitle` keeps the words in step with that: the shared Organize wording (and its
        // clears-the-scope variant at the provider root) describes a scope this click never moves.
        rescanButton(moved: targetMoved(from: syncManager.storageLensRoot?.path),
                     movedIcon: "chart.pie.fill", disabled: syncManager.isBuildingStorageLens,
                     action: onBuildStorage,
                     reaim: onBuildStorage,
                     movedHelp: "Analyze “\(scanTargetName)” — the folder now focused above",
                     movedTitle: "Analyze “\(scanTargetName)”")
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
        .disabled(runnableRuleCount == 0 || providerRoot == nil)
        // Name the ACTUAL blocker: with no provider root there is nothing to preview over, and
        // telling the user to add conditions to already-complete rules is a dead end.
        .help(providerRoot == nil
              ? "Focus a provider folder first — the preview runs over the focused folder."
              : runnableRuleCount == 0
              ? "Add a rule with a condition and a destination to preview it."
              : "Dry-run the enabled rules over the focused folder. A preview — nothing moves until you confirm.")
    }

    // MARK: Content card

    @ViewBuilder
    private func contentCard(rows: FilteredRows, counts: RailCounts,
                             scopeFolders: Int?) -> some View {
        VStack(spacing: 0) {
            switch effectiveLens {
            case .duplicates: duplicatesContent(dupGroups: rows.duplicates, counts: counts)
            case .rename: renameContent(risky: rows.risky, counts: counts)
            // Four rail items share `.filing`'s apparatus, so this arm is where the rail actually
            // decides what you see. The overview leads, because it is what you land on.
            case .filing:
                if showingOverview {
                    organizeOverview(rows: rows, scopeFolders: scopeFolders)
                } else if organizeLens == .restructure {
                    restructureContent(rows: rows, scopeFolders: scopeFolders)
                } else if showingRenameBacklog, !syncManager.renamePlans.isEmpty, rows.renames.isEmpty {
                    noMatchesState(scopedTotal: counts.renames,
                                   globalTotal: syncManager.renamePlans.count, noun: "folder")
                } else if showingRenameBacklog {
                    RenamePassLens(syncManager: syncManager, plans: rows.renames,
                                   accent: glassHue.accentColor,
                                   onApply: onApplyRenames,
                                   onReveal: { path in
                                       NSWorkspace.shared.activateFileViewerSelecting(
                                           [URL(fileURLWithPath: path)])
                                   })
                } else {
                    filingContent(filing: rows.filing, counts: counts)
                }
            case .automations: automationsContent(rules: rows.rules, counts: counts)
            case .storage: EmptyView()   // rendered by `body` as StorageLensView, never through here
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    // MARK: Restructure

    /// Where the tree disagrees with its own habits. Cached on the manager — see
    /// ``FileSyncManager/structureFindings`` for why a view body must not run the detector.
    private var structureFindings: [StructureFinding] { syncManager.structureFindings }

    /// Restructure's rows — **from `FilteredRows` now, not straight off the manager.**
    ///
    /// This lens was the one that bypassed the shared filter entirely, reading
    /// `syncManager.structureFindings` directly, which is precisely why no narrowing could reach
    /// it. It routes through the same value as every other lens now, so its count and its list
    /// cannot disagree.
    @ViewBuilder
    private func restructureContent(rows: FilteredRows, scopeFolders: Int?) -> some View {
        RestructureLens(findings: rows.structure,
                        aboutAncestor: rows.structureAboutAncestor,
                        hasProfile: syncManager.filingFolderProfile != nil,
                        // The SCOPED count, not the whole survey — this lens's answer has been
                        // narrowed, and "Checked 3,013 folders" beside it was a claim about a tree
                        // it did not look at. nil when unknown; see `scopeFolderCount`.
                        folderCount: scope == nil
                            ? syncManager.filingFolderProfile?.folders.count
                            : scopeFolders,
                        isScoped: scope != nil,
                        accent: glassHue.accentColor,
                        onReveal: { relative in
                            guard let root = syncManager.filingFolderProfile?.root else { return }
                            let full = (root as NSString).appendingPathComponent(relative)
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
                        })
    }

    // MARK: Overview

    /// Organize's landing — every lens's answer for the current scope, and the scans that would
    /// produce the answers it does not have.
    ///
    /// **`onScan` became `onRun`, and that is the substantive change on this screen.** The old
    /// closure took a lens and every call site was `{ railLens = item }`: a control captioned
    /// "Scan…" that navigated. The comment defending it argued that the lens owns its intro state,
    /// "where that scan's cost is stated — one button up here could not honestly price five scans".
    /// The first half was true and the second was answering the wrong question: there are not five
    /// scans. ``OrganizePass`` is the three that exist, each card states its own cost, and the
    /// button runs it.
    @ViewBuilder
    private func organizeOverview(rows: FilteredRows, scopeFolders: Int?) -> some View {
        let model = overviewModel
        OrganizeOverview(
            sections: model.sections,
            // **The SCOPE, not the last scan's folder.** It read `filingScanFolder` before, which
            // is the root one lens happened to walk — so the overview's "Nothing to do in X" named
            // a folder that had nothing to do with the other five lenses' answers, and named
            // something even when no scope was set at all.
            scopeLabel: scope?.name,
            accent: glassHue.accentColor,
            inboxShortcut: inboxShortcut,
            ledger: overviewLedger(model, scopeFolders: scopeFolders),
            runnablePasses: runnablePasses,
            onOpen: { item in withAnimation(listSettle) { railLens = item } },
            onRun: runPass
        )
    }

    /// Starts a pass from the overview.
    ///
    /// **Deliberately the plain scan, not the re-aim.** `reaimAtScanTarget` sets the scope to the
    /// focused pane's folder before scanning, which is right for a button captioned
    /// `Organize “X”` and wrong for one captioned `Run the file pass`: this offer is about the
    /// subject the overview is already describing, and silently dragging the scope to wherever the
    /// pane happens to sit is the exact failure ``rescanButton``'s two branches exist to keep apart.
    private func runPass(_ pass: OrganizePass) {
        switch pass {
        case .file: onFindFilingSuggestions()
        case .duplicates: onFindDuplicates()
        // Optional at the host boundary, which is why `runnablePasses` exists rather than a card
        // that draws a button and then does nothing.
        case .folderMemory: onUpdateFolderMemory?()
        }
    }

    /// The passes this host can start. Folder memory is the only conditional one — its handler is
    /// `(() -> Void)?`, and a host that passes none must get a card that explains the state rather
    /// than a button that no-ops.
    ///
    /// **The other two are asserted rather than detected, because their handlers cannot be asked.**
    /// `onFindFilingSuggestions` and `onFindDuplicates` are non-optional with `= {}` defaults, so a
    /// host that omitted one would get a live button over a closure that does nothing, and nothing
    /// here could tell. Unreachable today — `ContentView` passes both, and Storage is the only
    /// other caller that omits them while never rendering this screen (`showingOverview` is false
    /// for `lens == .storage`) — but a new host wiring Organize is the shape that would break it,
    /// and the fix would be to make those handlers optional too rather than to add a flag here.
    private var runnablePasses: Set<OrganizePass> {
        var passes: Set<OrganizePass> = [.file, .duplicates]
        if onUpdateFolderMemory != nil { passes.insert(.folderMemory) }
        return passes
    }

    /// The overview's cross-lens facts. The counting lives on ``OrganizeOverview/Ledger`` where it
    /// can be asserted without a view; what this adds is the two figures that need `Sync`.
    private func overviewLedger(_ model: OverviewModel,
                                scopeFolders: Int?) -> OrganizeOverview.Ledger {
        .derived(
            from: model.sections,
            // The ratio is over the checks this host can start, not every lens that carries a
            // badge — see `Ledger.countedLenses`. Same predicate the pass cards use, so the two
            // cannot disagree about which checks are real on this machine.
            runnablePasses: runnablePasses,
            // Absent rather than "0 bytes" when there is nothing to reclaim. A zero here reads as a
            // measured claim about the tree, and before a duplicate scan it is not one — the same
            // rule the rail badges and `inboxSubtitle` follow.
            reclaimable: model.reclaimableBytes > 0
                ? FileSyncManager.formatBytes(model.reclaimableBytes) : nil,
            // The SCOPED count when scoped, the whole survey when not — matching
            // `restructureContent` exactly, so the two places that quote a folder count agree.
            scopeFolders: scope == nil
                ? syncManager.filingFolderProfile?.folders.count : scopeFolders)
    }

    /// The inbox offered as a scope, or nil when there is no inbox — or when it is already the
    /// scope, where the offer would be a button that changes nothing.
    private var inboxShortcut: OrganizeOverview.InboxShortcut? {
        guard let inbox = filingInboxFolder, !inbox.isEmpty else { return nil }
        if let scope, standardizedPath(scope.path) == standardizedPath(inbox) { return nil }

        // **The count is claimed only when the last scan actually covered the inbox.**
        //
        // It is drawn from `filingSuggestions`, which holds ONE scan's output — so scoped to
        // `Legal`, or having scanned any other folder, or on a launch where nothing has scanned
        // yet, nothing in that list is under `TODO` and the offer read "Inbox (TODO) — **0 loose
        // files**" while the inbox held fifty. That is the worst possible wording for this control:
        // it talks the user out of the one click the inbox was promoted from a hidden default to
        // make available.
        //
        // Counting from disk instead is not the fix — a header must not walk the filesystem on
        // every render. Not claiming is: `looseFileCount` is optional and the offer falls back to
        // naming the inbox, which is the same rule the rail badges follow. Absent beats a wrong
        // zero.
        let scanned = syncManager.filingScanFolder
        let covered = scanned.map { PathBoundary.contains(inbox, under: $0) } ?? false
        let loose = covered
            ? syncManager.filingSuggestions.count { PathBoundary.contains($0.filePath, under: inbox) }
            : nil
        return .init(name: (inbox as NSString).lastPathComponent,
                     looseFileCount: loose,
                     apply: { withAnimation(listSettle) { setScope(inbox) } })
    }

    /// What each lens has to say, in rail order.
    ///
    /// **The three states are the point** (ROADMAP 20): a lens that has never run says so, a lens
    /// that ran clean says *that*, and only a lens with findings takes a section. Absence must
    /// never be ambiguous between "clean" and "cannot run".
    /// Every lens's answer **for the current scope**.
    ///
    /// The three states stay exactly as they were and are now resolved per scope, which is the
    /// whole point: *"0 under Legal" must never render as "0 anywhere"*. `notScanned` still means
    /// the scan has not run at all — that is a fact about the provider-wide pass, not about the
    /// subtree — while `clean` under a scope means this subtree is clean, and `OrganizeOverview`
    /// names the scope in the words it wraps around them.
    ///
    /// ## Why this returns a struct now
    ///
    /// The ledger needs the **scoped** reclaimable total, and `FileSyncManager.duplicateSummary`
    /// computes the global one — so the overview would have had to filter 722 groups a second time,
    /// on every render, to reach a number this loop already has the list for. That is the same
    /// double-pass ``RailCounts`` was consolidated to avoid, arriving through a different door.
    /// One walk, both answers.
    struct OverviewModel {
        var sections: [OrganizeOverviewSection] = []
        /// Scoped, and **batch-eligible groups only** — mirroring `duplicateSummary` exactly, so
        /// the ledger's figure is the one "Apply recommended" would actually deliver. Overlapping
        /// and name-only groups never inflate it.
        var reclaimableBytes = 0
    }

    /// Internal, not private, so `OrganizeOverviewWiringTests` can assert what this actually hands
    /// the view. The per-lens `isScanning` flags were wrong in two of five arms and no test could
    /// see it: the render suite mounts ``OrganizeOverview`` directly and is handed its sections, so
    /// it validates what the view does with them and never what this produces.
    var overviewModel: OverviewModel {
        let scope = scope
        let profileRoot = syncManager.filingFolderProfile?.root ?? ""
        var model = OverviewModel()
        // **A count of zero under a scope the scan never covered is not "clean", it is "unasked".**
        // The overview said "Nothing to do in Legal. Every check that has run came back clean."
        // about a subtree nothing had looked at, and three doors reach that state without scanning:
        // the inbox shortcut, Open on a single-source row, and ⌘K. Absent beats a wrong zero; here
        // that means falling back to `notScanned`, which is also the state that puts the run offer
        // back on screen — the honest answer and the useful one are the same.
        //
        // **The two passes have different shapes, so they take different predicates**, and getting
        // this wrong in either direction is a defect of its own:
        //
        // - **To File** enumerates the direct files of ONE folder, so only that exact folder can be
        //   answered about. Ancestry would call a provider-root scan "covering" `Legal` and hand
        //   back the same false clean, one level up.
        // - **Duplicates** hashes a whole subtree, so any ancestor of the scope covers it.
        // - **Names and Renames are NOT gated at all**, and that is the correction to a first pass
        //   of this fix which gated them on To File's folder "because they ride the same walk".
        //   They ride the same walk but not the same root: `detectRiskyNames` and
        //   `detectRenamePlans` are both handed the provider-wide taxonomy (`root: providerRoot`,
        //   `maxDepth: nil`) while the loose-file enumeration is one folder deep. Their findings
        //   therefore cover every scope inside the provider, and gating them on the filing folder
        //   hid real findings under any scope the inbox scan did not sit in. If either detector is
        //   ever narrowed to a subtree, it needs a gate here against ITS OWN root.
        let filingCovers = OrganizeScopeFilter.looseFileScanCovers(
            scope: scope, scannedFolder: syncManager.filingScanFolder)
        let duplicatesCover = OrganizeScopeFilter.scanCovers(
            scope: scope, scannedRoot: syncManager.duplicateScanRoot)
        // Hoisted out of the loop below because the ledger needs it too. Filtering it a second time
        // for the reclaimable total would be a second pass over 722 groups per render — see the
        // type's note.
        let scopedDuplicates = syncManager.duplicateGroups.filter {
            OrganizeScopeFilter.matches($0, scope: scope)
        }
        model.reclaimableBytes = scopedDuplicates
            .filter(\.isRecommendedForBatch)
            .reduce(0) { $0 + $1.reclaimableBytes }
        model.sections = OrganizeLens.allCases.compactMap { item -> OrganizeOverviewSection? in
            switch item {
            case .toFile:
                let scoped = syncManager.filingSuggestions.filter {
                    OrganizeScopeFilter.matches($0, scope: scope)
                }
                let n = scoped.count
                let ready = scoped.filter(\.hasConfidentHome).count
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: n > 0
                        ? "Loose files and where they belong — \(ready) ready, \(n - ready) unsure."
                        : "Loose files and where they belong.",
                    state: !syncManager.hasSuggestedFiling || !filingCovers ? .notScanned
                        : n == 0 ? .clean
                        : .findings(count: n, headline: "\(n) file\(n == 1 ? "" : "s")",
                                    // `lazy` before `prefix`, so the limit bounds the SUGGESTIONS
                                    // examined and not merely the ones kept: a plain
                                    // `scoped.prefix(3).compactMap` over three homeless files
                                    // yields nothing at all while the fourth had a home to show.
                                    examples: Array(scoped.lazy.compactMap { s in
                                        s.best.map { "\(s.fileName) → \(($0.path as NSString).lastPathComponent)" }
                                    }.prefix(OrganizeOverview.exampleLimit))),
                    isScanning: syncManager.isSuggestingFiles)
            case .duplicates:
                let scoped = scopedDuplicates
                let n = scoped.count
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: "Identical content under different names or folders.",
                    state: !syncManager.hasFoundDuplicates || !duplicatesCover ? .notScanned
                        : n == 0 ? .clean
                        : .findings(count: n, headline: "\(n) group\(n == 1 ? "" : "s")",
                                    examples: scoped.prefix(OrganizeOverview.exampleLimit).map {
                                        "\($0.name) — \($0.copies.count) copies"
                                    }),
                    isScanning: syncManager.isFindingDuplicates)
            case .names:
                let scoped = syncManager.riskyNames.filter {
                    OrganizeScopeFilter.matches($0, scope: scope)
                }
                let n = scoped.count
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: "Names this provider will not accept.",
                    // Ungated on purpose — the name detector is handed the provider-wide taxonomy,
                    // so a zero here really is clean for any scope inside the provider. See the
                    // note where `filingCovers` is computed.
                    state: !syncManager.hasScannedNames ? .notScanned
                        : n == 0 ? .clean
                        : .findings(count: n, headline: "\(n) name\(n == 1 ? "" : "s")",
                                    examples: scoped.prefix(OrganizeOverview.exampleLimit)
                                        .map(\.currentName)),
                    // **`isSuggestingFiles` too, and it is the flag that matters.** Names rides the
                    // filing walk — `detectRiskyNames` republishes `riskyNames` from it — but that
                    // path calls `completeScan` only, never `beginScan`, so `isScanningNames` stays
                    // false for the whole pass; the lifecycle is begun solely by `scanNames`, which
                    // has no caller in the app. Alone, this row sat showing a stale count in
                    // confident bold beside To File and Renames saying "rescanning", during the one
                    // walk that was republishing all three. Invisible until this commit's
                    // predecessor made `isScanning` load-bearing: the field existed before and the
                    // view read it nowhere, so nothing ever checked that its value was true.
                    isScanning: syncManager.isSuggestingFiles || syncManager.isScanningNames)
            case .renames:
                let scoped = syncManager.renamePlans.filter {
                    OrganizeScopeFilter.matches($0, scope: scope)
                }
                let n = scoped.count
                // The tally is rebuilt from the SCOPED plans, not the whole backlog — its breakdown
                // is the section's example line, and quoting the global one under a narrow scope is
                // the same lie the badge used to tell.
                let tally = RenameBacklogTally(scoped)
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: "Folders that have drifted from their own numbering.",
                    // Ungated for the same reason Names is: `detectRenamePlans` reads the
                    // provider-wide taxonomy, not the enumerated folder.
                    state: !syncManager.hasSuggestedFiling ? .notScanned
                        : n == 0 ? .clean
                        // One line, and not three: the backlog's evidence is its *breakdown*
                        // ("8 month folders · 3 quarters"), which is a summary of the whole list
                        // rather than a sample from it. Padding it out with three folder names
                        // would put two different kinds of claim in one column.
                        : .findings(count: n, headline: "\(n) folder\(n == 1 ? "" : "s")",
                                    examples: tally.breakdown.isEmpty ? [] : [tally.breakdown]),
                    isScanning: syncManager.isSuggestingFiles)
            case .restructure:
                // `inside` only, matching the badge: a finding about the folder ABOVE the scope is
                // shown inside the lens and labelled there, but it is not work in this subtree and
                // must not be counted as though it were.
                let scoped = structureFindings.filter {
                    OrganizeScopeFilter.relation(of: $0, profileRoot: profileRoot,
                                                 scope: scope) == .inside
                }
                return OrganizeOverviewSection(
                    lens: item,
                    blurb: "Where the tree disagrees with its own habits.",
                    // No profile means the detectors have nothing to read — "cannot run", which is
                    // a different sentence from "clean" and must not borrow its words.
                    state: syncManager.filingFolderProfile == nil ? .notScanned
                        : scoped.isEmpty ? .clean
                        : .findings(count: scoped.count,
                                    headline: "\(scoped.count) finding\(scoped.count == 1 ? "" : "s")",
                                    examples: scoped.prefix(OrganizeOverview.exampleLimit)
                                        .map(\.headline)),
                    // **The folder survey, which is this lens's pass.** Hard-coded `false` was
                    // right while nothing read it — Restructure runs no walk of its own — and wrong
                    // the moment the row grew an "Update folder memory" button: that button stayed
                    // live and the count stayed bold for the whole survey it had just started,
                    // while the menu item running the identical action one row up is `.disabled`
                    // for exactly that period.
                    isScanning: syncManager.filingSurveyLifecycle.isRunning)
            // Configuration, not a result: it has nothing to report and no scan to run, so it
            // takes no section, no pass card and no footer line either.
            case .rules:
                return nil
            }
        }
        return model
    }

    @ViewBuilder
    private func duplicatesContent(dupGroups: [DuplicateGroup], counts: RailCounts) -> some View {
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
            noMatchesState(scopedTotal: counts.duplicates,
                           globalTotal: syncManager.duplicateGroups.count,
                           noun: "duplicate group")
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
    /// The list is empty because something is *hiding* rows — and which something matters.
    ///
    /// **Found by installing the build and looking at it.** Scoped to `Legal`, the Rules lens read
    /// "0 automations · 0 enabled" over a blank pane, and what little it did offer was
    /// `noMatchesState`: "The current search hides all 3 rules. Clear it to see the results again",
    /// with a **Clear Search** button — while no search was running. The message named the wrong
    /// cause and the button could not fix it, on a lens whose whole complaint is that "0 here"
    /// reads as "0 anywhere".
    ///
    /// So the cause is resolved before the words are chosen. A live query owns the emptiness (it is
    /// the thing the user just typed); otherwise, if a scope is set, the scope owns it.
    /// - Parameters:
    ///   - scopedTotal: how many this lens holds **within the scope** — the denominator a search
    ///     is hiding. It was the global list, so under a scope the message read "the current
    ///     search hides all 722 duplicate groups" about a lens that held 27.
    ///   - globalTotal: how many exist in the whole tree, for the scope's own message.
    @ViewBuilder
    private func noMatchesState(scopedTotal: Int, globalTotal: Int, noun: String) -> some View {
        if query.isEmpty, let scope {
            // Reached only when the scoped list is empty, so everything there is is elsewhere.
            scopeHidesAllState(total: globalTotal - scopedTotal, noun: noun, scope: scope)
        } else {
            searchHidesAllState(total: scopedTotal, noun: noun)
        }
    }

    private func searchHidesAllState(total: Int, noun: String) -> some View {
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

    /// Nothing here, but there is something **elsewhere** — the sentence a scoped zero owes the
    /// reader.
    ///
    /// It names the scope, states the total outside it, and offers the one action that changes the
    /// answer. Deliberately not phrased as "clean": a lens that found nothing under `Legal` has not
    /// established that the tree is tidy, and borrowing `cleanState`'s words would be the exact
    /// ambiguity between *clean* and *not looked here* that Organize's three states exist to avoid.
    private func scopeHidesAllState(total: Int, noun: String, scope: OrganizeScope) -> some View {
        EmptyStateView(
            icon: "scope",
            title: "Nothing in “\(scope.name)”",
            message: "Organize is scoped to “\(scope.relativePath)”. "
                + "\(total) \(noun)\(total == 1 ? "" : "s") elsewhere in the tree \(total == 1 ? "is" : "are") not shown.",
            primary: .init("Organize Everything", systemImage: "xmark.circle") {
                withAnimation(listSettle) { setScope(nil) }
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
        // from `LensIntros`, the one place each lens's explanation is written.
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
    private func filingContent(filing: [FilingSuggestion], counts: RailCounts) -> some View {
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
                    noMatchesState(scopedTotal: counts.toFile,
                                   globalTotal: syncManager.filingSuggestions.count,
                                   noun: "loose file")
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
    private func renameContent(risky: [RiskyName], counts: RailCounts) -> some View {
        if syncManager.hasScannedNames, !syncManager.isScanningNames,
           !syncManager.riskyNames.isEmpty, risky.isEmpty {
            noMatchesState(scopedTotal: counts.names,
                           globalTotal: syncManager.riskyNames.count, noun: "risky name")
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
    private func automationsContent(rules: [AutomationRule], counts: RailCounts) -> some View {
        if !syncManager.automationRules.isEmpty, rules.isEmpty, !automationsState.viewingResults {
            noMatchesState(scopedTotal: counts.rules,
                           globalTotal: syncManager.automationRules.count, noun: "rule")
        } else {
            AutomationsLens(
                syncManager: syncManager,
                state: automationsState,
                rules: rules,
                providerName: providerName,
                destinationRoot: providerRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
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
        let rel = RuleOfferLogic.relativeToProviderRoot(destinationPath, providerRoot: providerRoot)
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
        let variant = ruleVariantChoice ?? offer.proposal.defaultVariant
        rule.conditions = variant.conditions
        // A phrasing can redirect — the `{person}` fan-out files each person's copy into their own
        // folder rather than the one this example went to. Taking only the conditions would save a
        // rule that says "everyone's OCI card" and files all of them into Aditi's folder.
        rule.destinationTemplate = variant.destinationTemplate ?? offer.proposal.destinationTemplate
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
        // Both fallbacks have to test for EMPTY, not just nil. `providerRoot` is handed
        // down as a non-optional String that is "" for an unconfigured provider, so `??` alone never
        // reached the suggestion's own root — the chain read as three options and behaved as one.
        let root = [providerRoot, suggestion.providerRoot]
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
            // **A handoff names ONE file, and the scope must not be allowed to answer about a
            // different subject.** The outcome above is resolved against the WHOLE group list while
            // the rows on screen come through `filteredRows` — see
            // ``OrganizeScopeFilter/revealClearsScope(revealedPath:scope:)`` for why those two
            // disagreeing produces a silent "no other copies", and why clearing is the only honest
            // resolution of the three available.
            if OrganizeScopeFilter.revealClearsScope(revealedPath: request.path, scope: scope) {
                setScope(nil)
            }
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
        let itemWord = TidyRemovalPrompt.itemWord(for: group.matchType.kind, count: count)
        let ok = NativeAlerts.confirmDestructive(
            messageText: "Move \(count) \(itemWord) of \"\(group.name)\" to the Trash?",
            informativeText: TidyRemovalPrompt.informativeText(
                kind: group.matchType.kind,
                keeperName: group.keeper.name,
                keeperLocation: displayPath(group.keeper.path),
                reclaimText: FileSyncManager.formatBytes(group.reclaimableBytes)),
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
