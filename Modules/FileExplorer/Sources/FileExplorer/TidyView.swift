import SwiftUI
import AppKit
import Events
import Sync
import Design

// MARK: - Lens / filter / match styling

/// The lenses of the Tidy workspace. Public so the host can own the selection (persisting it) and
/// drive `TidyView.lens` as a binding; the tabs themselves render in TidyView.
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

    /// The label shown in the lens picker. Kept separate from `rawValue` so the display name can
    /// change without breaking the persisted `selectedTidyLens` id (Filing shows as "Organize").
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

/// The Tidy workspace: a single-source hub of lenses (Duplicates, Rename, Organize, Automations, and
/// the read-only Storage). The host owns the active `lens` binding, but its picker renders here —
/// `lensTabs` heads this workspace — and the host docks the source rail beside it.
public struct TidyView: View {
    @ObservedObject public var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    /// Honors Settings ▸ Accessibility ▸ Reduce motion: when true, the row-exit slides (H4) and the
    /// reclaim glow (H5) are dropped for today's instant swap. The numeric count-up is kept — it's an
    /// acceptable motion under Reduce motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The app's text size, for the provider name — a `Menu` label that must stay a `Text`.
    @Environment(\.appFontScale) private var appFontScale

    /// The active lens. `lensTabs` writes it directly; the host owns the storage so the choice
    /// survives tab switches (and relaunches, via the host's `@AppStorage`) and so writing it can
    /// carry the host's side effect — re-homing the source rail onto the new lens's folder.
    @Binding private var lens: TidyLens
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
    /// Which of the offered conditions (name / content / kind) the user has selected in the prompt.
    @State private var ruleConditionChoice: AutomationCondition?
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
    /// Kicks off a Name Normalizer scan of the focused folder (host owns the root/provider deriving).
    private let onScanNames: () -> Void
    /// Applies the safe rename to the given risky names as one undoable batch.
    private let onNormalizeNames: ([RiskyName]) -> Void
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
    /// Opens two copies of a duplicate folder group in the Compare tab (keeper left, redundant right).
    private let onCompareCopies: (DuplicateCopy, DuplicateCopy) -> Void

    public init(
        syncManager: FileSyncManager,
        lens: Binding<TidyLens>,
        providerName: String? = nil,
        scanTargetFolder: String? = nil,
        onFindDuplicates: @escaping () -> Void,
        onFindFilingSuggestions: @escaping () -> Void = {},
        onScanNames: @escaping () -> Void = {},
        onNormalizeNames: @escaping ([RiskyName]) -> Void = { _ in },
        onPreviewAutomations: @escaping (UUID?) -> Void = { _ in },
        automationDestinationRoot: String? = nil,
        onQuickLook: ((URL) -> Void)? = nil,
        onBuildStorage: @escaping () -> Void = {},
        showSourcePicker: Bool = false,
        providers: [CloudProvider] = [],
        currentProviderId: String = "",
        onSelectProvider: @escaping (String) -> Void = { _ in },
        onManageProviders: @escaping () -> Void = {},
        onCompareCopies: @escaping (DuplicateCopy, DuplicateCopy) -> Void = { _, _ in }
    ) {
        self.syncManager = syncManager
        self._lens = lens
        self.providerName = providerName
        self.scanTargetFolder = scanTargetFolder
        self.onFindDuplicates = onFindDuplicates
        self.onFindFilingSuggestions = onFindFilingSuggestions
        self.onScanNames = onScanNames
        self.onNormalizeNames = onNormalizeNames
        self.onPreviewAutomations = onPreviewAutomations
        self.automationDestinationRoot = automationDestinationRoot
        self.onQuickLook = onQuickLook
        self.onBuildStorage = onBuildStorage
        self.showSourcePicker = showSourcePicker
        self.providers = providers
        self.currentProviderId = currentProviderId
        self.onSelectProvider = onSelectProvider
        self.onManageProviders = onManageProviders
        self.onCompareCopies = onCompareCopies
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }

    // MARK: Search state

    /// This lens's query. Written through to `searchQueries`, so switching tabs parks the query
    /// rather than carrying it into a grammar that would read it differently.
    private var searchText: Binding<String> {
        Binding(get: { searchQueries[lens] ?? "" }, set: { searchQueries[lens] = $0 })
    }

    private var isSearchExpanded: Binding<Bool> {
        Binding(
            get: { searchExpandedLenses.contains(lens) },
            set: { expanded in
                if expanded { searchExpandedLenses.insert(lens) } else { searchExpandedLenses.remove(lens) }
            }
        )
    }

    private var query: String { searchQueries[lens] ?? "" }
    /// True when this lens's list is narrowed by anything — the cue for the "N of M" readout.
    private var isFiltered: Bool {
        !query.isEmpty || (lens == .duplicates && filter != .all)
    }

    /// The parsed tokens of this lens's query, as chips. Each lens's own grammar answers, so a
    /// chip is only ever offered for a token that lens can actually bind.
    private var searchChips: [TokenChipsRow.Item] {
        func items<C: DimmableTokenChip>(_ chips: [C], label: (C) -> String, word: (C) -> String) -> [TokenChipsRow.Item] {
            chips.map { TokenChipsRow.Item(label: label($0), word: word($0), isActive: $0.isActive) }
        }
        switch lens {
        case .duplicates:
            return items(DuplicateSearch.chips(query), label: \.label, word: \.raw)
        case .rename:
            return items(RiskyNameSearch.chips(query), label: \.label, word: \.raw)
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
    }

    /// Resolves only the ACTIVE lens's rows — the other four aren't on screen, and each of these
    /// parses a query and walks a collection.
    private var filteredRows: FilteredRows {
        var rows = FilteredRows()
        switch lens {
        case .duplicates:
            let q = DuplicateSearch.parse(query)
            rows.duplicates = syncManager.duplicateGroups.filter { filter.matches($0) && q.matches($0) }
        case .rename:
            let q = RiskyNameSearch.parse(query)
            rows.risky = syncManager.riskyNames.filter { q.matches($0) }
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
        .sheet(isPresented: $showSpendHistory) { FilingSpendHistoryView() }
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
        .onChange(of: syncManager.isSuggestingFiles) { _, isScanning in
            if isScanning {
                filedThisSession = false
                dismissedThisSession = false
                pendingRememberPrompt = nil   // a new scan retires any dangling teach prompt
                pendingRuleOffer = nil
                searchQueries[.filing] = ""
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
            }
        }
        // Same reasoning for the other scanning lenses: a query left over from the previous
        // results would silently pre-filter the new scan's rows.
        .onChange(of: syncManager.isScanningNames) { _, isScanning in
            if isScanning { searchQueries[.rename] = "" }
        }
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
            searchPlaceholder: TidyLensSearch.placeholder(for: lens),
            searchHelp: TidyLensSearch.help(for: lens),
            chips: searchChips,
            onRemoveChip: removeSearchChip,
            accent: glassHue.accentColor,
            surfaceStyle: surfaceStyle,
            level: glassLevel,
            hue: glassHue,
            tint: surfaceTint,
            tabs: { lensTabs },
            actions: { lensActions(rows: rows) },
            summary: { lensSummary(rows: rows) },
            trailing: { lensTrailing(rows: rows) }
        )
    }

    /// The lens tabs — row 1 of the header card, and the primary control of this workspace.
    private var lensTabs: some View {
        HStack(spacing: 2) {
            ForEach(TidyLens.allCases) { tab in
                let isActive = (lens == tab)
                Button { lens = tab } label: {
                    Text(tab.title)
                        .scaledFont(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        // An overlay, NOT a border or a stacked row: it adds ZERO height, which is
                        // what keeps the tab row at 27 and the card at 81.
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(isActive ? glassHue.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                // roundedRect, not the variant's capsule: these tabs are marked by a bottom rule,
                // and a capsule wash would round away from the very edge that indicates them.
                .buttonStyle(.hoverAffordance(.segment, tint: glassHue.accentColor,
                                              shape: .roundedRect(6)))
                .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            }
        }
        // Land the first tab's *text* on the card's own content rule: the card pads by 12 and each
        // tab already pads itself by 8, so pull back that 8 — otherwise the tabs sit 8pt right of
        // the stat pills directly beneath them.
        .padding(.leading, -8)
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
                             onSelect: onSelectProvider, onManage: onManageProviders) {
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
        switch lens {
        case .duplicates:
            if hasResults, !syncManager.isFindingDuplicates {
                filterMenu
                rescanDuplicatesButton
                applyAllButton(rows.duplicates)
            }
        case .rename:
            if syncManager.hasScannedNames, !syncManager.riskyNames.isEmpty, !syncManager.isScanningNames {
                rescanNamesButton
                fixAllButton(rows.risky)
            }
        case .filing:
            if hasFilingResults, !syncManager.isSuggestingFiles {
                rescanFilingButton
                fileAllButton(rows.filing)
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

    /// Row 2's leading content: the folder these results are for, then this lens's stat pills.
    /// While a query is live these pills are the filter's READOUT — watching 12 groups → 3 and
    /// 2.1 GB → 840 MB as you type is most of the point, which is why the search field grows the
    /// card rather than swapping itself in over this row.
    @ViewBuilder
    private func lensSummary(rows: FilteredRows) -> some View {
        switch lens {
        case .duplicates:
            if hasResults { duplicatesSummary(rows.duplicates) }
        case .rename:
            if syncManager.hasScannedNames, !syncManager.riskyNames.isEmpty { renameSummary(rows.risky) }
        case .filing:
            if hasFilingResults, !syncManager.isSuggestingFiles { filingSummary(rows.filing) }
        case .automations:
            if !syncManager.automationRules.isEmpty { automationsSummary(rows.rules) }
        case .storage:
            if let report = syncManager.storageLensReport { storageSummary(report) }
        }
    }

    /// Row 2's trailing edge: "N of M" whenever this lens's list is narrowed, so a shortened list
    /// always reads as a filtered view rather than as the whole result.
    @ViewBuilder
    private func lensTrailing(rows: FilteredRows) -> some View {
        if isFiltered {
            switch lens {
            case .duplicates: ofMLabel(rows.duplicates.count, syncManager.duplicateGroups.count)
            case .rename: ofMLabel(rows.risky.count, syncManager.riskyNames.count)
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

    // MARK: Filing toolbar

    private var hasFilingResults: Bool { !syncManager.filingSuggestions.isEmpty }

    // Cloud Filing spend (read fresh each render — cheap; only two small structs).
    private var spendTotals: FilingSpendTotals { FilingSpendStore.totals() }
    private var spendLast: FilingSpendEntry? { FilingSpendStore.last() }

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

    private var rescanFilingButton: some View {
        rescanButton(moved: targetMoved(from: syncManager.filingScanFolder),
                     movedIcon: FilingGlyph.lens, disabled: syncManager.isSuggestingFiles,
                     action: onFindFilingSuggestions,
                     movedHelp: "Suggest homes for “\(scanTargetName)” — the folder now focused above")
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

    /// Organize's pills. The counts come from the scan's summary when nothing is filtered, and
    /// from the rows on screen once a query narrows them — the pills ARE the filter's readout.
    private func filingSummary(_ filing: [FilingSuggestion]) -> some View {
        let ready = filing.filter { $0.hasConfidentHome }.count
        let newFolders = filing.filter { $0.best?.isNew == true }.count
        let unsure = filing.count - ready
        return Group {
            scannedFolderChip(syncManager.filingScanFolder)
            // "to file" = the loose files showing; "ready" = the ones with a confident home now.
            StatPill(count: filing.count, label: "to file", color: SemanticColor.info, systemImage: "doc")
            StatPill(count: ready, label: "ready", color: SemanticColor.success, systemImage: "checkmark.circle")
            if newFolders > 0 {
                StatPill(count: newFolders, label: newFolders == 1 ? "new folder" : "new folders",
                         color: glassHue.accentColor, systemImage: "folder.badge.plus")
            }
            if unsure > 0 {
                StatPill(count: unsure, label: "unsure", color: SemanticColor.caution, systemImage: "questionmark.circle")
            }
        }
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

    /// Rename's pills, over the filtered rows.
    private func renameSummary(_ risky: [RiskyName]) -> some View {
        let folders = risky.filter(\.isDirectory).count
        return Group {
            scannedFolderChip(syncManager.nameScanRoot?.path)
            StatPill(count: risky.count, label: risky.count == 1 ? "risky name" : "risky names",
                     color: SemanticColor.caution, systemImage: NameNormalizeGlyph.risky)
            if folders > 0 {
                StatPill(count: folders, label: folders == 1 ? "folder" : "folders",
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
        }
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

    /// "Fix all N", scoped to the FILTERED risky names. `onNormalize` has always taken its rows
    /// explicitly, so this one was safe by construction — it just needs the filtered array.
    @ViewBuilder
    private func fixAllButton(_ risky: [RiskyName]) -> some View {
        if !risky.isEmpty {
            Button { onNormalizeNames(risky) } label: {
                Label("Fix all \(risky.count)", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .chromeHover()
            .controlSize(.small)
            .disabled(syncManager.isNormalizingNames)
            .help("Renames "
                  + (isFiltered
                     ? "the \(risky.count) name\(risky.count == 1 ? "" : "s") your search left showing"
                     : "every risky name above")
                  + " to its cloud-safe form. Never overwrites an existing file, and the whole pass "
                  + "undoes with a single ⌘Z.")
        }
    }

    private var rescanNamesButton: some View {
        rescanButton(moved: targetMoved(from: syncManager.nameScanRoot?.path),
                     movedIcon: NameNormalizeGlyph.lens, disabled: syncManager.isScanningNames,
                     action: onScanNames,
                     movedHelp: "Scan “\(scanTargetName)” for risky names — the folder now focused above")
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
            switch lens {
            case .duplicates: duplicatesContent(dupGroups: rows.duplicates)
            case .rename: renameContent(risky: rows.risky)
            case .filing: filingContent(filing: rows.filing)
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
        } else if syncManager.duplicateGroups.isEmpty {
            cleanState
        } else if dupGroups.isEmpty {
            noMatchesState(total: syncManager.duplicateGroups.count, noun: "duplicate group")
        } else {
            groupList(dupGroups: dupGroups)
        }
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
                    .transition(cardRemoval)
                }
            }
            .padding(densityMetrics.cardListPadding)
            // Animate the list settling when a resolved/merged group leaves the array (H4). Keyed on
            // the visible id list so only membership changes animate — expand/collapse and keeper
            // picks (which don't change the id set) stay instant.
            .animation(listSettle, value: dupGroups.map(\.id))
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Empty / scanning states

    private var introState: some View {
        // The L4 gold-standard template (EmptyStateView): provider named in the title, the job
        // in the message, the safety contract in the caption, one primary button.
        EmptyStateView(
            icon: "wand.and.stars",
            tint: glassHue.accentColor,
            title: "Find duplicates in \(providerName ?? "this provider")",
            message: "Scan this provider for folders and files that repeat across the tree — then collapse them into one.",
            caption: "Nothing is removed without your confirmation, and everything is undoable.",
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
                    conditionChoice: $ruleConditionChoice,
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
                onScan: onScanNames,
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
    private func offerRule(fileName: String, destinationPath: String) {
        let rel = RuleOfferLogic.relativeToProviderRoot(destinationPath, providerRoot: automationDestinationRoot)
        guard let proposal = AutomationRuleProposer.propose(fileName: fileName, destinationRelativePath: rel) else { return }
        pendingRememberPrompt = nil   // the new offer supersedes the legacy override prompt
        ruleConditionChoice = proposal.defaultCondition
        pendingRuleOffer = RuleOffer(fileName: fileName, proposal: proposal)
    }

    /// Saves the offered rule (with the chosen condition) as an Automation, dismisses the offer,
    /// and opens the saved rule for review so it can be adjusted while it's fresh.
    private func saveProposedRule(_ offer: RuleOffer) {
        var rule = offer.proposal.rule
        if let condition = ruleConditionChoice { rule.conditions = [condition] }
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
            .animation(listSettle, value: filing.map(\.id))
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
                    offerRule(fileName: suggestion.fileName, destinationPath: dest.path)
                }
            },
            onChooseFolder: { chooseFolder(for: suggestion) },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: suggestion.filePath)]) },
            onNotHere: {
                dismissedThisSession = true
                syncManager.dismissFilingSuggestion(suggestion)
            },
            onPreview: onQuickLook.map { ql in { ql(URL(fileURLWithPath: suggestion.filePath)) } },
            onTryAnother: { Task { await syncManager.tryAnotherFolder(for: suggestion) } }
        )
    }

    private var filingIntroState: some View {
        // Brought up to the L4 template like the Duplicates intro: name the target, explain
        // the job, put the safety contract in the caption, one primary button.
        EmptyStateView(
            icon: FilingGlyph.lens,
            tint: glassHue.accentColor,
            title: "File loose files in \(scanTargetName)",
            message: "Suggest where the files sitting loose in this folder belong — reusing the folders you already keep, and proposing new ones only when it's sure.",
            caption: "Nothing moves without your say-so, and every move is undoable.",
            primary: .init("Suggest homes", systemImage: FilingGlyph.lens, handler: onFindFilingSuggestions)
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

    private func chooseFolder(for suggestion: FilingSuggestion) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "File Here"
        panel.message = "Choose a folder for “\(suggestion.fileName)”"
        if let scanFolder = syncManager.filingScanFolder {
            panel.directoryURL = URL(fileURLWithPath: scanFolder)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dest = FilingDestination(path: url.path, confidence: .high, reasons: ["You chose this folder"], newSegments: [])
        filedThisSession = true
        // File immediately (no friction), then — if this was an *override* of the suggested home and
        // the filename has something distinctive to key on — offer to remember it inline (G2). This
        // replaces F3's easy-to-miss NSOpenPanel "Remember" checkbox with a visible one-tap prompt,
        // so we no longer pass `remember:` here.
        let teachable = FilingOverride.isOverride(suggestion, chosenPath: url.path)
            && FilingEngine.canRemember(fileName: suggestion.fileName)
        Task {
            // Only prompt to remember an override when the file actually MOVED — no point learning a
            // rule from filing a file into the folder it already sits in (`.notNeeded`).
            if await syncManager.applyFilingSuggestion(suggestion, to: dest) == .moved, teachable {
                pendingRuleOffer = nil   // a stale offer would otherwise hide the fresh teach prompt
                pendingRememberPrompt = PendingRememberPrompt(fileName: suggestion.fileName,
                                                              destinationPath: url.path)
            }
        }
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

    private func toggle(_ id: UUID) {
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
