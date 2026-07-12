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
    private let leadingHeader: AnyView?
    private let onFindDuplicates: () -> Void

    public init(
        syncManager: FileSyncManager,
        providerName: String? = nil,
        leadingHeader: AnyView? = nil,
        onFindDuplicates: @escaping () -> Void
    ) {
        self.syncManager = syncManager
        self.providerName = providerName
        self.leadingHeader = leadingHeader
        self.onFindDuplicates = onFindDuplicates
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
                if lens == .duplicates, hasResults, recommendedCount > 0 {
                    applyAllButton
                }
            }
            if lens == .duplicates, hasResults {
                summaryRow
            }
        }
        .padding(12)
        .bottomSectionCard(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)
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
            case .filing: filingPlaceholder
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
                        onChooseKeeper: { syncManager.setKeeper(for: group.id, to: $0) }
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
            ProgressView()
                .controlSize(.large)
            Text(syncManager.duplicateScanStatus ?? "Analyzing…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
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

    private var filingPlaceholder: some View {
        centeredState(
            symbol: "folder.badge.gearshape",
            tint: glassHue.accentColor,
            title: "Filing is coming next",
            message: "Filing will suggest where loose files belong — a Tesla insurance PDF into Documents › Vehicles › Tesla › Insurance — reusing the folders you already keep. Duplicates ships first."
        ) { EmptyView() }
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

    private func reveal(_ group: DuplicateGroup) {
        let urls = group.copies.map { URL(fileURLWithPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
