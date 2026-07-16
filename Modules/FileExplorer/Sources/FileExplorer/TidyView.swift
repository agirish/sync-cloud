import SwiftUI
import AppKit
import Sync
import Design

// MARK: - Lens / filter / match styling

/// The lenses of the Tidy workspace. Public so the host can hoist the lens picker into the
/// persistent tab strip and drive `TidyView.lens` as a binding.
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
        case .identical: return .green
        case .overlapping: return .orange
        case .nameOnly: return .yellow
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
        case .identical: return .green
        case .overlapping: return .orange
        case .nameOnly: return .yellow
        case .versions: return .purple
        }
    }
}

// MARK: - TidyView

/// The Tidy workspace: a single-source hub of lenses (Duplicates, Rename, Organize, Automations, and
/// the read-only Storage). The host owns the active `lens` (its picker lives in the persistent tab
/// strip) and docks the source rail beside this workspace.
public struct TidyView: View {
    @ObservedObject public var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    /// Honors Settings ▸ Accessibility ▸ Reduce motion: when true, the row-exit slides (H4) and the
    /// reclaim glow (H5) are dropped for today's instant swap. The numeric count-up is kept — it's an
    /// acceptable motion under Reduce motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The active lens, owned by the host so it lives in the persistent tab strip and survives
    /// tab switches (and relaunches, via the host's `@AppStorage`).
    @Binding private var lens: TidyLens
    @State private var filter: TidyFilter = .all
    /// Token search over the duplicate list (`kind:`, size, name); ANDed with `filter`.
    @State private var dupSearchText: String = ""
    /// Drives the one-tap suggestion row under the search field: shown only while it holds the caret.
    @FocusState private var dupSearchFocused: Bool
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
    /// The just-learned remembered rule, opened in the editor right after "Remember" so it can be
    /// reviewed and adjusted while it's fresh (Cancel keeps it as learned; it stays editable under
    /// Automations and Settings ▸ Filing).
    @State private var reviewingRememberedRule: FilingRule?
    /// The just-saved automation, opened in the editor right after "Save rule" for the same review
    /// pass (Cancel keeps it as saved; it stays editable under Automations).
    @State private var reviewingAutomationRule: AutomationRule?

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

    private var filteredGroups: [DuplicateGroup] {
        let query = DuplicateSearch.parse(dupSearchText)
        return syncManager.duplicateGroups.filter { filter.matches($0) && query.matches($0) }
    }
    private var hasResults: Bool { !syncManager.duplicateGroups.isEmpty }
    private var recommendedCount: Int {
        syncManager.duplicateGroups.filter { $0.isRecommendedForBatch }.count
    }

    /// Whether the toolbar card has anything to render for the current lens (a results summary,
    /// batch action, or the Filing spend row). Duplicates/Organize only earn it once they have
    /// results; Names/Automations render their own chrome, so their toolbar card is always empty.
    private var toolbarHasContent: Bool {
        switch lens {
        case .duplicates: return hasResults
        case .filing: return hasFilingResults || spendTotals.scans > 0
        case .rename, .automations, .storage: return false
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showSourcePicker { sourceBar }
            lensBody
        }
        .sheet(isPresented: $showSpendHistory) { FilingSpendHistoryView() }
        // Review-after-create: the rule just learned from "Remember" (or saved from "Save rule")
        // opens in its editor so it can be checked and adjusted immediately. Cancel keeps the rule
        // exactly as created — the review is an offer, not a gate.
        .sheet(item: $reviewingRememberedRule) { rule in
            FilingRuleEditorView(
                title: "Review remembered rule",
                original: rule,
                accent: glassHue.accentColor,
                onSave: { edited in
                    syncManager.replaceFilingRule(rule, with: edited)
                    reviewingRememberedRule = nil
                },
                onCancel: { reviewingRememberedRule = nil }
            )
        }
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
        // so the "All filed" terminal state is only earned by this scan's work.
        .onChange(of: syncManager.isSuggestingFiles) { _, isScanning in
            if isScanning {
                filedThisSession = false
                dismissedThisSession = false
                pendingRememberPrompt = nil   // a new scan retires any dangling teach prompt
                pendingRuleOffer = nil
            }
        }
        // A fresh Duplicates scan starts a fresh reclaim session, so "… freed this session" only ever
        // counts the current results' work (H5). The search resets too: a query typed against the
        // previous results silently pre-filtering (or hiding) the new scan's groups is a dead end.
        .onChange(of: syncManager.isFindingDuplicates) { _, isScanning in
            if isScanning {
                reclaim.reset()
                dupSearchText = ""
            }
        }
    }

    /// The source bar shown above the lens while the rail is collapsed: the provider dropdown (the
    /// one provider choice Tidy needs) and the folder being tidied.
    private var sourceBar: some View {
        let provider = providers.first(where: { $0.id == currentProviderId })
        return HStack(spacing: 8) {
            Text("Source")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                // Logo outside the Menu label (a resizable image inside one balloons under fixedSize).
                if let provider {
                    Image(provider.imageName).resizable().scaledToFit().frame(width: 16, height: 16)
                }
                ProviderMenu(providers: providers, currentId: currentProviderId,
                             onSelect: onSelectProvider, onManage: onManageProviders) {
                    Text(provider?.displayName ?? "Provider")
                        .font(.system(size: 12, weight: .semibold))
                        .contentShape(Rectangle())
                }
                .help("Switch which cloud you're tidying")
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
            if let folder = scanTargetFolder, !folder.isEmpty {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text((folder as NSString).lastPathComponent)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LiquidGlass.cardGutter + 12)
        .padding(.top, LiquidGlass.cardGutter)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var lensBody: some View {
        Group {
            if lens == .storage {
                // Storage, folded in as a read-only lens: it brings its own toolbar + content cards
                // (and card gutter), so it renders in place of Tidy's own two cards. The lens picker
                // lives in the host's persistent tab strip, so switching away from Storage still works.
                StorageLensView(
                    syncManager: syncManager,
                    providerName: providerName,
                    onBuild: onBuildStorage,
                    onReveal: { path in
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    },
                    onQuickLook: onQuickLook.map { ql in { path in ql(URL(fileURLWithPath: path)) } }
                )
            } else {
                VStack(spacing: 8) {
                    // Only show the toolbar card when it actually has something (a results summary or
                    // batch action). In the intro / scanning / clean states it would otherwise render
                    // as an empty bar — the lens picker that used to fill it now lives in the top strip.
                    if toolbarHasContent { toolbarCard }
                    contentCard
                }
                .padding(LiquidGlass.cardGutter)
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

    // MARK: Toolbar card

    private var toolbarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if lens == .duplicates, hasResults, !syncManager.isFindingDuplicates {
                    rescanDuplicatesButton
                    if recommendedCount > 0 { applyAllButton }
                } else if lens == .filing, hasFilingResults, !syncManager.isSuggestingFiles {
                    // The batch action lives down in the summary row (next to the counts it acts on),
                    // not detached up here — so only the rescan control sits in the toolbar.
                    rescanFilingButton
                }
            }
            if lens == .duplicates, hasResults {
                summaryRow
                dupSearchAccessories
            } else if lens == .filing, hasFilingResults, !syncManager.isSuggestingFiles {
                // The Filing scan publishes its suggestions once, at the very end, so results are
                // empty (hasFilingResults == false) for the whole scan; the `!isSuggestingFiles`
                // guard is belt-and-suspenders. The running phase is surfaced in the scanning view
                // itself (filingScanStatus), not here.
                filingSummaryRow
            }
            if lens == .filing, spendTotals.scans > 0 { filingSpendRow }
        }
        .padding(12)
        .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)
    }

    // MARK: Filing toolbar

    private var hasFilingResults: Bool { !syncManager.filingSuggestions.isEmpty }

    // Cloud Filing spend (read fresh each render — cheap; only two small structs).
    private var spendTotals: FilingSpendTotals { FilingSpendStore.totals() }
    private var spendLast: FilingSpendEntry? { FilingSpendStore.last() }

    private var filingSpendRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud").font(.system(size: 10))
            if let last = spendLast {
                Text("Last cloud scan: \(FilingSpendFormat.model(last.model)) · \(last.fileCount) files · \(FilingSpendFormat.tokens(last.totalTokens)) · \(FilingSpendFormat.cost(last.estimatedCostUSD))")
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("Total \(FilingSpendFormat.cost(spendTotals.costUSD))")
            Button("History") { showSpendHistory = true }.controlSize(.mini)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    private var filingRecommendedCount: Int {
        syncManager.filingSuggestions.filter { $0.isBatchEligible }.count
    }

    private var fileAllButton: some View {
        let n = filingRecommendedCount
        return Button(action: applyRecommendedFiling) {
            Label("File all \(n) confident", systemImage: "arrow.right.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(syncManager.isSuggestingFiles)
        .help("Files the \(n) name-matched suggestion\(n == 1 ? "" : "s") with a confident home. "
              + "Content- and AI-based picks stay for you to review; every move undoes with ⌘Z.")
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
                .disabled(disabled).help(movedHelp)
        } else {
            Button(action: action) { Label("Rescan", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered).controlSize(.small)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("These results are for “\(name)”")
        }
    }

    private var filingSummaryRow: some View {
        let s = syncManager.filingSummary
        let unsure = s.fileCount - s.withConfidentHome
        return HStack(spacing: 8) {
            scannedFolderChip(syncManager.filingScanFolder)
            // "to file" = every loose file found; "ready" = the ones with a confident home now.
            StatPill(count: s.fileCount, label: "to file", color: .blue, systemImage: "doc")
            StatPill(count: s.withConfidentHome, label: "ready", color: .green, systemImage: "checkmark.circle")
            if s.needNewFolders > 0 {
                StatPill(count: s.needNewFolders, label: s.needNewFolders == 1 ? "new folder" : "new folders",
                         color: glassHue.accentColor, systemImage: "folder.badge.plus")
            }
            if unsure > 0 {
                StatPill(count: unsure, label: "unsure", color: .yellow, systemImage: "questionmark.circle")
            }
            Spacer(minLength: 8)
            // The batch action sits right beside the counts it acts on (G3), not detached in the
            // toolbar. Only shown when there's actually a confident, name-based batch to file.
            if filingRecommendedCount > 0 { fileAllButton }
        }
    }

    private var summaryRow: some View {
        let s = syncManager.duplicateSummary
        return HStack(spacing: 8) {
            scannedFolderChip(syncManager.duplicateScanRoot)
            StatPill(count: s.groupCount, label: "groups", color: .blue, systemImage: "square.on.square")
            ReclaimPill(reclaimableBytes: s.reclaimableBytes,
                        freedCaption: reclaim.freedCaption(FileSyncManager.formatBytes(reclaim.totalBytes)),
                        flashToken: reclaimFlashToken,
                        reduceMotion: reduceMotion)
            StatPill(count: s.redundantCopyCount, label: "redundant", color: .secondary, systemImage: "doc.on.doc")
            if s.needsReviewCount > 0 {
                StatPill(count: s.needsReviewCount, label: "need review", color: .yellow, systemImage: "exclamationmark.triangle")
            }
            Spacer(minLength: 8)
            // "N of M" whenever the search/filter narrows the list (same affordance as Compare's
            // search), so a shortened list is visibly a filtered view, not the whole result.
            if filter != .all || !dupSearchText.isEmpty {
                Text("\(filteredGroups.count) of \(syncManager.duplicateGroups.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            dupSearchField
            filterMenu
        }
    }

    /// Compact token search for the duplicate list — `kind:pdf`, `>5mb`, or a name substring —
    /// sharing the Compare grammar. Narrows `filteredGroups` on top of the match-type filter.
    private var dupSearchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("kind:pdf, >5mb…", text: $dupSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(maxWidth: 150)
                .focused($dupSearchFocused)
            if !dupSearchText.isEmpty {
                Button { dupSearchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.5)))
        .fixedSize()
    }

    /// The removable filter chips and one-tap suggestions for the duplicate search, shown as a second
    /// toolbar row beneath the summary so the compact field itself stays single-line. Right-aligned to
    /// sit under the field. Renders nothing until there's a chip or the field holds the caret.
    @ViewBuilder
    private var dupSearchAccessories: some View {
        let chips = DuplicateSearch.chips(dupSearchText)
        if !chips.isEmpty || dupSearchFocused {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    // A chip superseded by a later same-family word (parse is last-wins) renders
                    // dimmed, so the chips read as the query the filter actually runs.
                    let tint = chip.isActive ? glassHue.accentColor : Color.secondary
                    HStack(spacing: 4) {
                        Text(chip.label)
                            .font(.caption.monospaced())
                            .strikethrough(!chip.isActive)
                        Button {
                            dupSearchText = DuplicateSearch.removing(dupSearchText, word: chip.raw)
                        } label: {
                            // 8 pt glyph, padded hit target (negative padding restores the chip's
                            // visual size) — the bare glyph was a misclick magnet.
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(-6)
                        .accessibilityLabel("Remove filter \(chip.label)")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundStyle(tint)
                    .background(Capsule().fill(tint.opacity(chip.isActive ? 0.16 : 0.08)))
                    .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
                    .help(chip.isActive ? "Active filter" : "Overridden by a later filter of the same kind")
                }
                if dupSearchFocused {
                    dupSuggestions(active: chips)
                }
            }
        }
    }

    /// One-tap filter suggestions, appended to the field. Omits a family already active (kind and the
    /// size floor are each single-valued, so a second just replaces the first).
    @ViewBuilder
    private func dupSuggestions(active: [DuplicateSearch.Chip]) -> some View {
        let suggestions = dupSuggestionList(active: active)
        if !suggestions.isEmpty {
            Text("Add filter")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
            ForEach(suggestions, id: \.raw) { suggestion in
                Button {
                    // Trim first so appending never leaves a double space when the field already ends
                    // in whitespace.
                    let base = dupSearchText.trimmingCharacters(in: .whitespaces)
                    dupSearchText = base.isEmpty ? suggestion.raw : base + " " + suggestion.raw
                } label: {
                    Text(suggestion.label)
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary.opacity(0.6)))
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static let dupSuggestionCandidates: [(label: String, raw: String)] = [
        ("PDFs", "kind:pdf"),
        // `kind:image` is a class alias (see DuplicateSearch.kindClasses), so "Images" honestly
        // means images — the old `kind:jpg` silently excluded PNGs, HEICs, ….
        ("Images", "kind:image"),
        ("> 10 MB", ">10mb"),
    ]

    private func dupSuggestionList(active: [DuplicateSearch.Chip]) -> [(label: String, raw: String)] {
        let hasKind = active.contains { $0.raw.lowercased().hasPrefix("kind:") }
        let hasFloor = active.contains { $0.raw.hasPrefix(">") }
        return Self.dupSuggestionCandidates.filter { candidate in
            if candidate.raw.hasPrefix("kind:") { return !hasKind }
            if candidate.raw.hasPrefix(">") { return !hasFloor }
            return true
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
            Picker("Filter", selection: $filter) {
                ForEach(TidyFilter.allCases) { f in
                    Text("\(f.label) (\(count(for: f)))").tag(f)
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

    private func count(for f: TidyFilter) -> Int {
        syncManager.duplicateGroups.filter { f.matches($0) }.count
    }

    private var applyAllButton: some View {
        Button(action: applyRecommended) {
            Label("Apply \(recommendedCount) recommended", systemImage: "checkmark.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(syncManager.isFindingDuplicates)
    }

    // MARK: Content card

    @ViewBuilder
    private var contentCard: some View {
        VStack(spacing: 0) {
            switch lens {
            case .duplicates: duplicatesContent
            case .rename: renameContent
            case .filing: filingContent
            case .automations: automationsContent
            case .storage: EmptyView()   // rendered by `body` as StorageLensView, never through here
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)
    }

    @ViewBuilder
    private var duplicatesContent: some View {
        if syncManager.isFindingDuplicates {
            scanningState
        } else if !syncManager.hasFoundDuplicates {
            introState
        } else if syncManager.duplicateGroups.isEmpty {
            cleanState
        } else if filteredGroups.isEmpty {
            noMatchesState
        } else {
            groupList
        }
    }

    /// Filtered-to-empty dead end (mirrors the Activity Log's "No matching entries"): groups exist,
    /// but the search/filter hide them all — name the cause and offer one click out, instead of a
    /// blank list that reads like there are no duplicates.
    private var noMatchesState: some View {
        let total = syncManager.duplicateGroups.count
        return EmptyStateView(
            icon: "line.3.horizontal.decrease.circle",
            title: "No groups match",
            message: "The current search and filter hide all \(total) duplicate \(total == 1 ? "group" : "groups"). Clear them to see the results again.",
            primary: .init("Clear Filters", systemImage: "xmark.circle") {
                dupSearchText = ""
                filter = .all
            }
        )
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: densityMetrics.cardListSpacing) {
                ForEach(filteredGroups) { group in
                    TidyGroupCard(
                        group: group,
                        isExpanded: expanded.contains(group.id),
                        providerName: providerName,
                        scanRoot: syncManager.duplicateScanRoot,
                        onToggle: { toggle(group.id) },
                        onApply: { apply(group) },
                        onReveal: { reveal(group) },
                        onKeepSeparate: { syncManager.keepDuplicateGroupSeparate(group) },
                        onChooseKeeper: { syncManager.setKeeper(for: group.id, to: $0) },
                        onMerge: { merge(group) },
                        onCompareCopies: { keep, delete in onCompareCopies(keep, delete) }
                    )
                    .transition(cardRemoval)
                }
            }
            .padding(densityMetrics.cardListPadding)
            // Animate the list settling when a resolved/merged group leaves the array (H4). Keyed on
            // the visible id list so only membership changes animate — expand/collapse and keeper
            // picks (which don't change the id set) stay instant.
            .animation(listSettle, value: filteredGroups.map(\.id))
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
                .font(.system(size: 13, weight: .medium))
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
            tint: .green,
            title: "No duplicates found",
            message: "Nothing repeats across \(providerName ?? "this provider"). Scan again after adding files.",
            secondary: .init("Scan again", systemImage: "arrow.clockwise", handler: onFindDuplicates)
        )
    }

    // MARK: Filing content

    @ViewBuilder
    private var filingContent: some View {
        VStack(spacing: 0) {
            // The teach prompt sits above every Filing state (not just the list) so it survives
            // filing the last loose file — the card that triggered it is already gone. The rule offer
            // (after a "File here") takes precedence over the legacy override "Remember" prompt.
            if let offer = pendingRuleOffer {
                ruleOfferPrompt(offer)
            } else if let prompt = pendingRememberPrompt {
                rememberOverridePrompt(prompt)
            }
            Group {
                if syncManager.isSuggestingFiles {
                    filingScanningState
                } else if !syncManager.hasSuggestedFiling {
                    filingIntroState
                } else if syncManager.filingSuggestions.isEmpty {
                    filingCleanState
                } else {
                    filingList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: pendingRememberPrompt?.id)
        .animation(.easeInOut(duration: 0.2), value: pendingRuleOffer?.id)
    }

    /// The "Rename" lens (the un-folded Name Normalizer): finds and fixes cloud-hostile names.
    private var renameContent: some View {
        RenameLens(
            syncManager: syncManager,
            providerName: providerName,
            accent: glassHue.accentColor,
            densityMetrics: densityMetrics,
            onScan: onScanNames,
            onNormalize: onNormalizeNames,
            onReveal: { path in NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            onQuickLook: onQuickLook.map { ql in { path in ql(URL(fileURLWithPath: path)) } }
        )
    }

    /// N2 — the Automations lens (preview-only). Self-contained (its own rule-list / previewing /
    /// results states and rule editor live in ``AutomationsLens``), so the host only threads the
    /// dry-run trigger through — it owns the focused-folder root the preview scans.
    private var automationsContent: some View {
        AutomationsLens(
            syncManager: syncManager,
            providerName: providerName,
            destinationRoot: automationDestinationRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
            onPreview: onPreviewAutomations
        )
    }

    /// G2 — "Remember this for files like it?" The correction the user just made (filing into a
    /// folder that wasn't the suggestion) is the strongest training signal, so surface it as a
    /// visible, one-tap prompt rather than F3's easy-to-miss NSOpenPanel checkbox.
    private func rememberOverridePrompt(_ prompt: PendingRememberPrompt) -> some View {
        let folderName = (prompt.destinationPath as NSString).lastPathComponent
        return HStack(spacing: 10) {
            Image(systemName: "memories")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(glassHue.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember this for files like “\(prompt.fileName)”?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text("File future matches into “\(folderName)” automatically — you’ll review it next; manage it anytime under Automations.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Not now") { pendingRememberPrompt = nil }
                .controlSize(.small)
            Button("Remember") { rememberOverride(prompt) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(glassHue.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(glassHue.accentColor.opacity(0.28), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Learns the correction as an F3 rule, dismisses the prompt, and opens the learned rule for
    /// review so it can be adjusted while it's fresh. `rememberFilingRule` is gated at the call
    /// site by `FilingEngine.canRemember`, so it should succeed; a rare no-op (returns nil) still
    /// just dismisses — no misleading "learned" banner, nothing to review.
    private func rememberOverride(_ prompt: PendingRememberPrompt) {
        if let rule = syncManager.rememberFilingRule(fileName: prompt.fileName, destinationPath: prompt.destinationPath) {
            let folderName = (prompt.destinationPath as NSString).lastPathComponent
            syncManager.banner = .success("Remembered — files like “\(prompt.fileName)” will go to \(folderName).")
            reviewingRememberedRule = rule
        }
        pendingRememberPrompt = nil
    }

    // MARK: Learned rules (offered after a filing move)

    /// After the user files a loose file, propose an editable Automation rule for files like it —
    /// the deterministic, learn-by-example complement to the AI backend.
    private func offerRule(fileName: String, destinationPath: String) {
        let rel = relativeToProviderRoot(destinationPath)
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

    /// The destination folder as a path relative to the provider root (the rule's template is
    /// provider-relative).
    private func relativeToProviderRoot(_ absolutePath: String) -> String {
        guard let root = automationDestinationRoot, !root.isEmpty else {
            return (absolutePath as NSString).lastPathComponent
        }
        let r = (root as NSString).standardizingPath
        let p = (absolutePath as NSString).standardizingPath
        if p == r { return "" }
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        return (absolutePath as NSString).lastPathComponent
    }

    /// The inline "Save a rule?" offer after a filing move: the proposed match condition with a
    /// compact picker (name / content / kind) and the destination; Save creates an Automation.
    private func ruleOfferPrompt(_ offer: RuleOffer) -> some View {
        let conditions = [offer.proposal.defaultCondition] + offer.proposal.alternatives
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(glassHue.accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text("Filed “\(offer.fileName)” → \(offer.proposal.destinationTemplate). Save a rule?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("Match:").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(conditions, id: \.self) { condition in
                        let on = (ruleConditionChoice == condition)
                        Button { ruleConditionChoice = condition } label: {
                            Text(condition.summary)
                                .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(on ? glassHue.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                                .overlay(Capsule().strokeBorder(on ? glassHue.accentColor.opacity(0.5) : Color.clear, lineWidth: 0.5))
                                .foregroundStyle(on ? glassHue.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(spacing: 5) {
                Button("Save rule") { saveProposedRule(offer) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Not now") { pendingRuleOffer = nil }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(glassHue.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(glassHue.accentColor.opacity(0.28), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var filingList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: densityMetrics.cardListSpacing) {
                // Grouped by confidence (High / Medium / Low) so the list reads as "these are sure,
                // these are maybes, these need you" rather than one undifferentiated wall of cards.
                ForEach(FilingSuggestionGrouping.sections(syncManager.filingSuggestions)) { section in
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
            .animation(listSettle, value: syncManager.filingSuggestions.map(\.id))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(section.suggestions.count.formatted())
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text("· \(section.tier.gloss)")
                .font(.system(size: 11))
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
                .font(.system(size: 13, weight: .medium))
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
                tint: .green,
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
                pendingRememberPrompt = PendingRememberPrompt(fileName: suggestion.fileName,
                                                              destinationPath: url.path)
            }
        }
    }

    private func applyRecommendedFiling() {
        let batch = syncManager.filingSuggestions.filter { $0.isBatchEligible }
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
        Task { await syncManager.applyRecommendedFiling() }
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

    private func applyRecommended() {
        let groups = syncManager.duplicateGroups.filter { $0.isRecommendedForBatch }
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
        let before = syncManager.duplicateSummary.reclaimableBytes
        Task {
            await syncManager.applyRecommendedDuplicates()
            creditReclaim(before - syncManager.duplicateSummary.reclaimableBytes)
        }
    }

    private func merge(_ group: DuplicateGroup) {
        let unique = group.redundantCopies.reduce(0) { $0 + $1.uniqueItemCount }
        let many = group.redundantCopies.count != 1
        let ok = NativeAlerts.confirmDestructive(
            messageText: "Merge \"\(group.name)\" into one folder?",
            informativeText: "Copies \(unique) unique item\(unique == 1 ? "" : "s") into \"\(group.keeper.name)\", then moves the folded cop\(many ? "ies" : "y") to the Trash. Nothing is lost; undo with ⌘Z.",
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

/// One pending "remember this override?" prompt (G2) — the loose file just filed and the folder it
/// went into, enough to seed an F3 rule. Identifiable so the inline prompt can animate in and out.
private struct PendingRememberPrompt: Identifiable {
    let id = UUID()
    let fileName: String
    let destinationPath: String
}

/// One pending "save a rule?" offer — the file just filed and the proposed Automation for files like
/// it. Identifiable so the inline prompt animates in and out.
private struct RuleOffer: Identifiable {
    let id = UUID()
    let fileName: String
    let proposal: AutomationRuleProposer.Proposal
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
                .font(.system(size: 11, weight: .bold))
                .symbolRenderingMode(.hierarchical)
            Text("\(FileSyncManager.formatBytes(reclaimableBytes)) reclaimable")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                // Numeric roll is kept even under Reduce motion (an acceptable content transition).
                .contentTransition(.numericText())
            if let freedCaption {
                Text("· \(freedCaption)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.green.opacity(0.85))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(Color.green)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(Color.green.opacity(0.14 + 0.30 * glow)))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(Color.green.opacity(0.45 + 0.45 * glow), lineWidth: 0.5 + glow))
        .shadow(color: Color.green.opacity(0.55 * glow), radius: 7 * glow)
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
