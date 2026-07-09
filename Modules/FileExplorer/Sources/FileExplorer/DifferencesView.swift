import Events
import SwiftUI
import Sync
import AppKit
import Design

/// Filter for the differences list (by type / side).
public enum DifferenceFilter: String, CaseIterable {
    case all = "All"
    case missingOnLeft = "Missing on left"
    case missingOnRight = "Missing on right"
    case changedCopyToRight = "Changed (left newer)"
    case changedCopyToLeft = "Changed (right newer)"

    /// User-facing label using the panes' provider names; rawValue stays the stable case identity.
    func displayName(leftName: String, rightName: String) -> String {
        switch self {
        case .all: return "All"
        case .missingOnLeft: return "Missing on \(leftName)"
        case .missingOnRight: return "Missing on \(rightName)"
        case .changedCopyToRight: return "Changed (\(leftName) newer)"
        case .changedCopyToLeft: return "Changed (\(rightName) newer)"
        }
    }

    func matches(_ diff: FileDifference) -> Bool {
        switch self {
        case .all: return true
        case .missingOnLeft: return diff.type == .missingOnLeft
        case .missingOnRight: return diff.type == .missingOnRight
        case .changedCopyToRight: return diff.type == .differentDates && diff.action == .copyToRight
        case .changedCopyToLeft: return diff.type == .differentDates && diff.action == .copyToLeft
        }
    }
}

/// Tracks Shift/Command so the differences list can offer “Move” instead of “Copy” when a modifier is held.
@MainActor
final class ModifierTracker: ObservableObject {
    @Published var isMoveModifierPressed: Bool = false
    nonisolated(unsafe) private var monitor: Any?
    
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateModifiers(event.modifierFlags)
            return event
        }
    }
    
    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        let isPressed = Self.isMoveModifier(flags)
        if isMoveModifierPressed != isPressed {
            isMoveModifierPressed = isPressed
        }
    }

    /// The app-wide "move instead of copy" modifier: Shift or Command.
    nonisolated static func isMoveModifier(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.shift) || flags.contains(.command)
    }

    /// One-shot read of the current keyboard state (e.g. at drop time), for callers that
    /// don't need the published stream.
    static var moveModifierHeld: Bool {
        isMoveModifier(NSEvent.modifierFlags)
    }
}

/// A compact count chip for the differences header: a colored dot (or SF Symbol), the count,
/// and a short label. `emphasized` tints the whole capsule and colors the text — used for the
/// differences count so the actionable number stands out from the Left/Right reference counts.
struct StatPill: View {
    let count: Int
    let label: String
    let color: Color
    var systemImage: String? = nil
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(count.formatted())
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(emphasized ? color : Color.primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(emphasized ? color : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(emphasized ? color.opacity(0.14) : Color.secondary.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(emphasized ? color.opacity(0.45) : Color.secondary.opacity(0.22), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// List of all differences between the two panes with actions to copy or move each item left or right.
public struct DifferencesView: View {
    @ObservedObject public var syncManager: FileSyncManager
    @StateObject private var modifierTracker = ModifierTracker()
    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.framed.rawValue
    @State private var selectedFilter: DifferenceFilter = .all
    @State private var searchText = ""
    @State private var selection = Set<FileDifference.ID>()
    @State private var sortOrder: [KeyPathComparator<FileDifference>] = [KeyPathComparator(\.fileName, comparator: .localizedStandard, order: .forward)]
    private let paneNames: PaneProviderNames
    private let onQuickLook: ((URL) -> Void)?
    /// - Parameter onQuickLook: Presents a Quick Look preview for the given file. The app
    ///   routes this to the same `quickLookPreview` binding the spacebar shortcut uses, so
    ///   there is a single presenter; `nil` hides the Quick Look menu items.
    public init(syncManager: FileSyncManager, paneNames: PaneProviderNames = .leftRight, onQuickLook: ((URL) -> Void)? = nil) {
        self.syncManager = syncManager
        self.paneNames = paneNames
        self.onQuickLook = onQuickLook
    }

    private var isBulkSyncing: Bool {
        syncManager.bulkSyncProgress != nil
    }
    private var isVerifyAllInProgress: Bool {
        syncManager.verifyAllProgress != nil
    }
    private var verifiedIdenticalCount: Int {
        syncManager.verifiedIdenticalForCopy?.count ?? 0
    }
    private var surfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .framed
    }

    public var body: some View {
        // Derive everything once per render: the header reads the target counts several times and
        // this view re-renders per file during bulk sync. One O(n) filter+search pass, then an
        // O(n log n) sort over the (much smaller, filtered) result to match the Table's sortOrder.
        let filtered = DifferencesQuery.filtered(syncManager.differences, filter: selectedFilter, searchText: searchText)
        let sorted = filtered.sorted(using: sortOrder)
        let targets = DifferenceActionTargets(filtered: filtered, selection: selection)
        let anySyncing = syncManager.differences.contains { $0.isSyncing }

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 8) {
                        StatPill(count: syncManager.leftItemCount, label: "Left", color: .blue)
                        StatPill(count: syncManager.differences.count, label: "Differences", color: .orange, systemImage: "exclamationmark.triangle", emphasized: true)
                        StatPill(count: syncManager.rightItemCount, label: "Right", color: .purple)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(DifferenceFilter.allCases, id: \.self) { filter in
                                Button {
                                    selectedFilter = filter
                                } label: {
                                    let name = filter.displayName(leftName: paneNames.left, rightName: paneNames.right)
                                    if selectedFilter == filter {
                                        Label(name, systemImage: "checkmark")
                                    } else {
                                        Text(name)
                                    }
                                }
                            }
                        } label: {
                            Label(
                                selectedFilter.displayName(leftName: paneNames.left, rightName: paneNames.right),
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        if targets.copyToRightCount > 0 {
                            Button {
                                copy(direction: .copyToRight, targets: targets)
                            } label: {
                                Label(actionLabel(count: targets.copyToRightCount, to: paneNames.right), systemImage: "arrow.right.circle")
                            }
                            .buttonStyle(.bordered)
                            .disabled(anySyncing || isBulkSyncing || isVerifyAllInProgress)
                        }
                        if targets.copyToLeftCount > 0 {
                            Button {
                                copy(direction: .copyToLeft, targets: targets)
                            } label: {
                                Label(actionLabel(count: targets.copyToLeftCount, to: paneNames.left), systemImage: "arrow.left.circle")
                            }
                            .buttonStyle(.bordered)
                            .disabled(anySyncing || isBulkSyncing || isVerifyAllInProgress)
                        }
                        if targets.verifiableCount > 0 {
                            Button {
                                verify(targets: targets)
                            } label: {
                                Label("Verify \(targets.verifiableCount)", systemImage: "checkmark.shield")
                            }
                            .buttonStyle(.bordered)
                            .disabled(anySyncing || isBulkSyncing || isVerifyAllInProgress)
                        }
                    }
                }
                searchField(filteredCount: filtered.count)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .glassBarStyle(intensity: glassIntensity)

            if let progress = syncManager.verifyAllProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Verifying \(progress.completed) of \(progress.total)...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let activeProgress = syncManager.activeProgress, activeProgress.isCancellable {
                            Button("Cancel") {
                                activeProgress.cancel()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            if let progress = syncManager.bulkSyncProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Syncing \(progress.completed) of \(progress.total)...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let activeProgress = syncManager.activeProgress, activeProgress.isCancellable {
                            Button("Cancel") {
                                activeProgress.cancel()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            Divider()
                .opacity(0.6)
            
            Table(sorted, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.fileName, comparator: .localizedStandard) { DifferenceNameCell(difference: $0) }
                TableColumn("Change", value: \.changeSortRank) { DifferenceChangeCell(difference: $0) }
                TableColumn("Size", value: \.displaySizeSort) { DifferenceSizeCell(difference: $0) }
                    .width(min: 70, ideal: 90)
                TableColumn("Copy to", value: \.copyToSortRank) { DifferenceDirectionCell(difference: $0, paneNames: paneNames) }
                    .width(min: 96, ideal: 140)
            }
            // Let the surface fill below show through: the Table would otherwise paint its own
            // opaque scroll background over it, defeating the translucent styles.
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: FileDifference.ID.self) { ids in
                differenceContextMenu(for: ids, in: sorted)
            }
            .overlay {
                if sorted.isEmpty {
                    emptyState
                }
            }
            .contentSurface(surfaceStyle, intensity: glassIntensity)
        }
        .confirmationDialog("Copy to Match Dates", isPresented: Binding(
            get: { syncManager.verifiedIdenticalForCopy != nil },
            // Deferred cleanup: SwiftUI writes false here on ANY dismissal, including confirm,
            // and may run this setter before the button action. A synchronous cleanup here would
            // destroy the list before the confirm button can claim it (making Copy a no-op).
            set: { if !$0 { syncManager.verifiedCopyDialogDismissed() } }
        )) {
            Button("Copy \(paneNames.left) to \(paneNames.right)") {
                syncManager.confirmVerifiedCopy()
            }
            Button("Cancel", role: .cancel) {
                syncManager.dismissVerifiedCopyDialogWithoutCopy()
            }
        } message: {
            Text("\(verifiedIdenticalCount) files verified identical. One permission — copies all from \(paneNames.left) to \(paneNames.right) to match dates. No per-file confirmation.")
        }
    }

    // MARK: Header

    /// Inline search field (second header row): a magnifier, the query, a clear button, and a
    /// live "N of M" match count when a filter or search narrows the list.
    private func searchField(filteredCount: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by name or path", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
            if selectedFilter != .all || !searchText.isEmpty {
                Text("\(filteredCount) of \(syncManager.differences.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
    }

    /// The Copy/Move button label, reflecting the target count and the held move modifier.
    private func actionLabel(count: Int, to name: String) -> String {
        "\(modifierTracker.isMoveModifierPressed ? "Move" : "Copy") \(count) to \(name)"
    }

    // MARK: Header actions

    /// Fires a header Copy/Move on the current action targets (selection when any, else the
    /// filtered set). `syncAll` filters the subset to the requested direction internally.
    private func copy(direction: FileDifference.SyncAction, targets: DifferenceActionTargets) {
        let isMove = modifierTracker.isMoveModifierPressed
        let count = direction == .copyToRight ? targets.copyToRightCount : targets.copyToLeftCount
        Logger.shared.debug(
            "Bulk \(isMove ? "move" : "copy") \(direction == .copyToRight ? "to right" : "to left"): "
            + "\(count) item(s) (\(targets.isSelectionScoped ? "selection" : "filtered set"))")
        Task { await syncManager.syncAll(direction: direction, isMove: isMove, subset: targets.targets) }
    }

    /// Fires Verify on the current action targets; `verifyAllWithChecksum` keeps only the
    /// verifiable (date-only, same-size) differences from the subset.
    private func verify(targets: DifferenceActionTargets) {
        Logger.shared.debug(
            "Bulk verify: \(targets.verifiableCount) item(s) "
            + "(\(targets.isSelectionScoped ? "selection" : "filtered set"))")
        Task { await syncManager.verifyAllWithChecksum(subset: targets.targets) }
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(emptyStateMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyStateMessage: String {
        if !searchText.isEmpty {
            return "No differences match “\(searchText)”."
        }
        if selectedFilter != .all {
            return "No items match the current filter."
        }
        return "No differences."
    }

    // MARK: Context menu

    /// Right-click menu for the table selection: the full per-row menu (#14) when a single row
    /// is targeted, or bulk Copy/Move/Ignore for a multi-row selection. `visible` is the sorted,
    /// filtered list the ids index into.
    @ViewBuilder
    private func differenceContextMenu(for ids: Set<FileDifference.ID>, in visible: [FileDifference]) -> some View {
        if ids.count == 1, let id = ids.first, let difference = visible.first(where: { $0.id == id }) {
            singleRowMenu(for: difference)
        } else if ids.count > 1 {
            bulkMenu(for: visible.filter { ids.contains($0.id) })
        }
    }

    /// Per-row menu (#14): per-side Reveal/Quick Look/Copy Path for the sides that exist,
    /// plus the same ignore toggle the tree panes offer.
    @ViewBuilder
    private func singleRowMenu(for difference: FileDifference) -> some View {
        let sides = DifferenceRowMenu.existingSides(for: difference, paneNames: paneNames)
        ForEach(sides, id: \.paneName) { side in
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: side.path)])
            } label: {
                Label("Reveal in Finder (\(side.paneName))", systemImage: "magnifyingglass")
            }
        }
        if let onQuickLook {
            Divider()
            ForEach(sides, id: \.paneName) { side in
                Button {
                    onQuickLook(URL(fileURLWithPath: side.path))
                } label: {
                    Label("Quick Look (\(side.paneName))", systemImage: "eye")
                }
            }
        }
        Divider()
        ForEach(sides, id: \.paneName) { side in
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(side.path, forType: .string)
            } label: {
                Label("Copy Path (\(side.paneName))", systemImage: "doc.on.clipboard")
            }
        }
        Divider()
        let isIgnored = DifferenceRowMenu.isIgnored(difference, ignoredPaths: syncManager.ignoredPaths)
        Button {
            syncManager.ignoredPaths = DifferenceRowMenu.toggledIgnoredPaths(
                for: difference,
                ignoredPaths: syncManager.ignoredPaths
            )
        } label: {
            Label(
                isIgnored ? "Include in comparison" : "Ignore in comparison",
                systemImage: isIgnored ? "eye" : "eye.slash"
            )
        }
    }

    /// Bulk menu for a multi-row selection: Copy/Move the selected rows in each direction
    /// (respecting the move modifier) and ignore them all.
    @ViewBuilder
    private func bulkMenu(for selected: [FileDifference]) -> some View {
        let toRight = selected.filter { $0.action == .copyToRight }
        let toLeft = selected.filter { $0.action == .copyToLeft }
        let isMove = modifierTracker.isMoveModifierPressed
        if !toRight.isEmpty {
            Button {
                Logger.shared.debug("Bulk \(isMove ? "move" : "copy") to right: \(toRight.count) item(s) (selection)")
                Task { await syncManager.syncAll(direction: .copyToRight, isMove: isMove, subset: toRight) }
            } label: {
                Label("\(isMove ? "Move" : "Copy") \(toRight.count) to \(paneNames.right)", systemImage: "arrow.right.circle")
            }
        }
        if !toLeft.isEmpty {
            Button {
                Logger.shared.debug("Bulk \(isMove ? "move" : "copy") to left: \(toLeft.count) item(s) (selection)")
                Task { await syncManager.syncAll(direction: .copyToLeft, isMove: isMove, subset: toLeft) }
            } label: {
                Label("\(isMove ? "Move" : "Copy") \(toLeft.count) to \(paneNames.left)", systemImage: "arrow.left.circle")
            }
        }
        Divider()
        Button {
            syncManager.ignoredPaths = DifferencesQuery.ignoringAll(selected, in: syncManager.ignoredPaths)
        } label: {
            Label("Ignore \(selected.count) in comparison", systemImage: "eye.slash")
        }
    }
}

// MARK: - Table cells
//
// Each column's content is its own small view so the `Table` builder stays simple enough for
// the type-checker (a single big Table literal with inline cell closures times out).

/// Name column: type glyph, dimmed parent path, then the filename — single line, middle-truncated.
private struct DifferenceNameCell: View {
    let difference: FileDifference

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: DifferenceGlyph.symbol(for: difference.type, filled: true))
                .foregroundStyle(DifferenceGlyph.color(for: difference.type))
                .symbolRenderingMode(.hierarchical)
            if !difference.parentPath.isEmpty {
                Text(difference.parentPath + "/")
                    .foregroundStyle(.secondary)
            }
            Text(difference.fileName)
                .fontWeight(.medium)
                .layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .help(difference.relativePath)
    }
}

/// Change column: the description with the folder roll-up ("… — includes N items").
private struct DifferenceChangeCell: View {
    let difference: FileDifference

    var body: some View {
        Text(difference.rolledUpDescription)
            .foregroundStyle(DifferenceGlyph.color(for: difference.type))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(difference.rolledUpDescription)
    }
}

/// Size column: the source side's byte size (right-aligned, monospaced), or "—" for folders/unknown.
private struct DifferenceSizeCell: View {
    let difference: FileDifference

    /// One cached formatter for the whole column — `ByteCountFormatter` carries internal state, so
    /// allocating one per row body would churn (same reason FileTreeView caches its `sizeFormatter`).
    @MainActor private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        Text(difference.displaySize.map { Self.formatter.string(fromByteCount: Int64($0)) } ?? "—")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Copy-to column: a small tinted direction chip (blue → right, purple → left) naming the destination pane.
private struct DifferenceDirectionCell: View {
    let difference: FileDifference
    let paneNames: PaneProviderNames

    var body: some View {
        let toRight = difference.action == .copyToRight
        let tint: Color = toRight ? .blue : .purple
        HStack(spacing: 4) {
            Image(systemName: toRight ? "arrow.right" : "arrow.left")
                .font(.caption2.weight(.bold))
            Text(toRight ? paneNames.right : paneNames.left)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.15)))
    }
}
