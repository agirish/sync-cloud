import SwiftUI
import AppKit
import Sync
import Design

// MARK: - Lens / filter / match styling

/// The two lenses of the Tidy workspace.
enum TidyLens: String, CaseIterable, Identifiable {
    case duplicates = "Duplicates"
    case filing = "Filing"
    var id: String { rawValue }
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

/// The Tidy workspace: finds and resolves duplicate folders & files within one provider.
/// Mirrors `DifferencesView`'s inline-tabs card layout — the host injects the bottom-tab picker
/// as `leadingHeader` so the tabs merge into this view's single toolbar.
public struct TidyView: View {
    @ObservedObject public var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    @State private var lens: TidyLens = .duplicates
    @State private var filter: TidyFilter = .all
    @State private var expanded: Set<UUID> = []
    @State private var showSpendHistory = false
    /// True once the user has filed at least one loose file since the current Filing scan finished.
    /// Lets the empty-list state distinguish an earned "All filed" from "nothing was ever loose."
    /// Reset when a new scan starts (see `.onChange(of: isSuggestingFiles)`).
    @State private var filedThisSession = false
    /// A just-made override the user can teach as a rule (G2): they filed a loose file into a folder
    /// other than the suggested home — the highest-value learning moment. Held (inline prompt shown)
    /// until they Remember it or dismiss it. Cleared when a new scan starts.
    @State private var pendingRememberPrompt: PendingRememberPrompt?

    private let providerName: String?
    /// The folder a rescan would target — the focused pane's current directory. Lets both lenses
    /// name the folder up front and offer to rescan when the user has navigated away from the
    /// folder the current results were scanned from.
    private let scanTargetFolder: String?
    private let leadingHeader: AnyView?
    private let onFindDuplicates: () -> Void
    private let onFindFilingSuggestions: () -> Void
    /// Presents a Quick Look preview for a file (routed to the same `quickLookPreview` binding the
    /// spacebar shortcut uses). nil disables the per-card Preview button.
    private let onQuickLook: ((URL) -> Void)?

    public init(
        syncManager: FileSyncManager,
        providerName: String? = nil,
        scanTargetFolder: String? = nil,
        leadingHeader: AnyView? = nil,
        onFindDuplicates: @escaping () -> Void,
        onFindFilingSuggestions: @escaping () -> Void = {},
        onQuickLook: ((URL) -> Void)? = nil
    ) {
        self.syncManager = syncManager
        self.providerName = providerName
        self.scanTargetFolder = scanTargetFolder
        self.leadingHeader = leadingHeader
        self.onFindDuplicates = onFindDuplicates
        self.onFindFilingSuggestions = onFindFilingSuggestions
        self.onQuickLook = onQuickLook
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var surfaceStyle: SurfaceStyle { SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified }
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }

    private var filteredGroups: [DuplicateGroup] {
        syncManager.duplicateGroups.filter { filter.matches($0) }
    }
    private var hasResults: Bool { !syncManager.duplicateGroups.isEmpty }
    private var recommendedCount: Int {
        syncManager.duplicateGroups.filter { $0.isRecommendedForBatch }.count
    }

    public var body: some View {
        VStack(spacing: 8) {
            toolbarCard
            contentCard
        }
        .padding(LiquidGlass.cardGutter)
        .sheet(isPresented: $showSpendHistory) { FilingSpendHistoryView() }
        // A fresh scan starts a fresh session: forget any files filed against the previous results,
        // so the "All filed" terminal state is only earned by this scan's work.
        .onChange(of: syncManager.isSuggestingFiles) { _, isScanning in
            if isScanning {
                filedThisSession = false
                pendingRememberPrompt = nil   // a new scan retires any dangling teach prompt
            }
        }
    }

    // MARK: Toolbar card

    private var toolbarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let leadingHeader { leadingHeader }
                lensPicker
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

    private var lensPicker: some View {
        Picker("", selection: $lens) {
            ForEach(TidyLens.allCases) { l in Text(l.rawValue).tag(l) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
    }

    private var summaryRow: some View {
        let s = syncManager.duplicateSummary
        return HStack(spacing: 8) {
            scannedFolderChip(syncManager.duplicateScanRoot)
            StatPill(count: s.groupCount, label: "groups", color: .blue, systemImage: "square.on.square")
            reclaimPill(s.reclaimableBytes)
            StatPill(count: s.redundantCopyCount, label: "redundant", color: .secondary, systemImage: "doc.on.doc")
            if s.needsReviewCount > 0 {
                StatPill(count: s.needsReviewCount, label: "need review", color: .yellow, systemImage: "exclamationmark.triangle")
            }
            Spacer(minLength: 8)
            filterMenu
        }
    }

    private func reclaimPill(_ bytes: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 11, weight: .bold))
                .symbolRenderingMode(.hierarchical)
            Text("\(FileSyncManager.formatBytes(bytes)) reclaimable")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Color.green)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(Color.green.opacity(0.14)))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.green.opacity(0.45), lineWidth: 0.5))
        .fixedSize()
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
            case .filing: filingContent
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
        } else {
            groupList
        }
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
                        onMerge: { merge(group) }
                    )
                }
            }
            .padding(densityMetrics.cardListPadding)
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
            // G2: the teach prompt sits above every Filing state (not just the list) so it survives
            // filing the last loose file — the card that triggered it is already gone.
            if let prompt = pendingRememberPrompt {
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
                Text("File future matches into “\(folderName)” automatically — manage or undo this in Settings ▸ Filing.")
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

    /// Learns the correction as an F3 rule, then dismisses the prompt. `rememberFilingRule` is
    /// gated at the call site by `FilingEngine.canRemember`, so it should succeed; a rare no-op
    /// (returns false) still just dismisses — no misleading "learned" banner.
    private func rememberOverride(_ prompt: PendingRememberPrompt) {
        if syncManager.rememberFilingRule(fileName: prompt.fileName, destinationPath: prompt.destinationPath) {
            let folderName = (prompt.destinationPath as NSString).lastPathComponent
            syncManager.banner = .success("Remembered — files like “\(prompt.fileName)” will go to \(folderName).")
        }
        pendingRememberPrompt = nil
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
                    }
                }
            }
            .padding(densityMetrics.cardListPadding)
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
                Task { await syncManager.applyFilingSuggestion(suggestion, to: dest) }
            },
            onChooseFolder: { chooseFolder(for: suggestion) },
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: suggestion.filePath)]) },
            onNotHere: { syncManager.dismissFilingSuggestion(suggestion) },
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
            let filed = await syncManager.applyFilingSuggestion(suggestion, to: dest)
            if filed && teachable {
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
        Task { await syncManager.resolveDuplicateGroup(group) }
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
        Task { await syncManager.applyRecommendedDuplicates() }
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
