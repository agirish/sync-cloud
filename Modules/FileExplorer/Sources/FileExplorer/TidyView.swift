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

    @State private var lens: TidyLens = .duplicates
    @State private var filter: TidyFilter = .all
    @State private var expanded: Set<UUID> = []

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
                    rescanFilingButton
                    if filingRecommendedCount > 0 { fileAllButton }
                }
            }
            if lens == .duplicates, hasResults {
                summaryRow
            } else if lens == .filing, hasFilingResults, !syncManager.isSuggestingFiles {
                // Gated on the scan being fully settled: the two-phase Filing scan publishes
                // phase-1 suggestions while phase 2 is still reading documents, and showing
                // provisional summary counts beside a "Reading N documents…" body reads as
                // contradictory — the numbers visibly shift when phase 2 lands.
                filingSummaryRow
            }
        }
        .padding(12)
        .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)
    }

    // MARK: Filing toolbar

    private var hasFilingResults: Bool { !syncManager.filingSuggestions.isEmpty }
    private var filingRecommendedCount: Int {
        syncManager.filingSuggestions.filter { $0.isBatchEligible }.count
    }

    private var fileAllButton: some View {
        Button(action: applyRecommendedFiling) {
            Label("File \(filingRecommendedCount) suggested", systemImage: "arrow.right.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(syncManager.isSuggestingFiles)
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
                     movedIcon: "folder.badge.gearshape", disabled: syncManager.isSuggestingFiles,
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
        return HStack(spacing: 8) {
            scannedFolderChip(syncManager.filingScanFolder)
            StatPill(count: s.fileCount, label: "loose files", color: .blue, systemImage: "doc")
            StatPill(count: s.withConfidentHome, label: "with a home", color: .green, systemImage: "checkmark.circle")
            if s.needNewFolders > 0 {
                StatPill(count: s.needNewFolders, label: "new folders", color: glassHue.accentColor, systemImage: "folder.badge.plus")
            }
            let unsure = s.fileCount - s.withConfidentHome
            if unsure > 0 {
                StatPill(count: unsure, label: "unsure", color: .yellow, systemImage: "questionmark.circle")
            }
            Spacer(minLength: 8)
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
            LazyVStack(spacing: 10) {
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
            .padding(12)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Empty / scanning states

    private var introState: some View {
        centeredState(
            symbol: "wand.and.stars",
            tint: glassHue.accentColor,
            title: "Find duplicates in \(providerName ?? "this provider")",
            message: "Scan this provider for folders and files that repeat across the tree — then collapse them into one. Nothing is removed without your confirmation, and everything is undoable."
        ) {
            Button(action: onFindDuplicates) {
                Label("Find Duplicates", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
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
        centeredState(
            symbol: "checkmark.seal.fill",
            tint: .green,
            title: "No duplicates found",
            message: "Nothing repeats across \(providerName ?? "this provider"). Scan again after adding files."
        ) {
            Button(action: onFindDuplicates) {
                Label("Scan again", systemImage: "arrow.clockwise")
            }
            .controlSize(.regular)
        }
    }

    // MARK: Filing content

    @ViewBuilder
    private var filingContent: some View {
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

    private var filingList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(syncManager.filingSuggestions) { suggestion in
                    FilingSuggestionCard(
                        suggestion: suggestion,
                        onFileHere: { dest in Task { await syncManager.applyFilingSuggestion(suggestion, to: dest) } },
                        onChooseFolder: { chooseFolder(for: suggestion) },
                        onReveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: suggestion.filePath)]) },
                        onNotHere: { syncManager.dismissFilingSuggestion(suggestion) },
                        onPreview: onQuickLook.map { ql in { ql(URL(fileURLWithPath: suggestion.filePath)) } },
                        onTryAnother: { Task { await syncManager.tryAnotherFolder(for: suggestion) } }
                    )
                }
            }
            .padding(12)
        }
        .scrollContentBackground(.hidden)
    }

    private var filingIntroState: some View {
        centeredState(
            symbol: "folder.badge.gearshape",
            tint: glassHue.accentColor,
            title: "File loose files in \(scanTargetName)",
            message: "Suggest a home for the files sitting in this folder — reusing the folders you already keep, and proposing new ones only when it's sure. Nothing moves without your say-so, and every move is undoable."
        ) {
            Button(action: onFindFilingSuggestions) {
                Label("Suggest homes", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
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

    private var filingCleanState: some View {
        centeredState(
            symbol: "checkmark.seal.fill",
            tint: .green,
            title: "Nothing loose to file",
            message: "No files in \(filingFolderName) need a home right now."
        ) {
            Button(action: onFindFilingSuggestions) {
                Label("Scan again", systemImage: "arrow.clockwise")
            }
            .controlSize(.regular)
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
        // Offer to remember the correction as a rule — but only when the filename has something
        // distinctive to key on (a nameless "scan0012.pdf" can't seed a rule).
        var rememberBox: NSButton?
        if FilingEngine.canRemember(fileName: suggestion.fileName) {
            let box = NSButton(checkboxWithTitle: "Remember: file files like this here from now on",
                               target: nil, action: nil)
            box.state = .off
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 36))
            box.frame = NSRect(x: 20, y: 9, width: 400, height: 18)
            container.addSubview(box)
            panel.accessoryView = container
            panel.isAccessoryViewDisclosed = true
            rememberBox = box
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let remember = rememberBox?.state == .on
        let dest = FilingDestination(path: url.path, confidence: .high, reasons: ["You chose this folder"], newSegments: [])
        Task { await syncManager.applyFilingSuggestion(suggestion, to: dest, remember: remember) }
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
        Task { await syncManager.applyRecommendedFiling() }
    }

    private func centeredState<Accessory: View>(
        symbol: String, tint: Color, title: String, message: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            accessory()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
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
