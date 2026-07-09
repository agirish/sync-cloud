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
    @State private var selectedFilter: DifferenceFilter = .all
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

    public var body: some View {
        // Both are O(n) passes over the differences list; compute them once per render instead of
        // once per access (the header alone reads the counts several times, and this view re-renders
        // per file during bulk sync).
        let filteredDifferences = syncManager.differences.filter { selectedFilter.matches($0) }
        let summary = DifferencesSummary(differences: syncManager.differences, filter: selectedFilter)
        let copyToRightCount = summary.copyToRightCount
        let copyToLeftCount = summary.copyToLeftCount
        let anySyncing = summary.anySyncing
        let verifiableCount = summary.verifiableCount

        return VStack(alignment: .leading, spacing: 0) {
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
                    if selectedFilter != .all {
                        Text("\(filteredDifferences.count) of \(syncManager.differences.count) items")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if copyToRightCount > 0 || copyToLeftCount > 0 {
                        Button {
                            let isMove = modifierTracker.isMoveModifierPressed
                            Task { await syncManager.syncAll(direction: .copyToRight, isMove: isMove, subset: filteredDifferences) }
                        } label: {
                            Label(
                                modifierTracker.isMoveModifierPressed ? "Move \(copyToRightCount) to \(paneNames.right)" : "Copy \(copyToRightCount) to \(paneNames.right)",
                                systemImage: "arrow.right.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(copyToRightCount == 0 || anySyncing || isBulkSyncing)
                        Button {
                            let isMove = modifierTracker.isMoveModifierPressed
                            Task { await syncManager.syncAll(direction: .copyToLeft, isMove: isMove, subset: filteredDifferences) }
                        } label: {
                            Label(
                                modifierTracker.isMoveModifierPressed ? "Move \(copyToLeftCount) to \(paneNames.left)" : "Copy \(copyToLeftCount) to \(paneNames.left)",
                                systemImage: "arrow.left.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(copyToLeftCount == 0 || anySyncing || isBulkSyncing)
                    }
                    if verifiableCount > 0 {
                        Button {
                            Task { await syncManager.verifyAllWithChecksum() }
                        } label: {
                            Label("Verify All (\(verifiableCount))", systemImage: "checkmark.shield")
                        }
                        .buttonStyle(.bordered)
                        .disabled(anySyncing || isBulkSyncing || isVerifyAllInProgress)
                    }
                }
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
            
            ScrollView {
                LazyVStack(spacing: 10) {
                    if selectedFilter != .all && filteredDifferences.isEmpty {
                        Text("No items match the current filter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    ForEach(filteredDifferences, id: \.id) { difference in
                        DifferenceRow(
                            difference: difference,
                            syncManager: syncManager,
                            isMove: modifierTracker.isMoveModifierPressed,
                            glassIntensity: glassIntensity,
                            paneNames: paneNames,
                            onQuickLook: onQuickLook
                        ) { isMove in
                            Task {
                                await syncManager.syncFile(difference, isMove: isMove)
                            }
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                    }
                }
                .padding(16)
            }
            .background(.regularMaterial.opacity(0.5))
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
}

/// One row in the differences list: icon, path, description, sync button, and optional "Verify" (checksum) when same size.
struct DifferenceRow: View {
    let difference: FileDifference
    @ObservedObject var syncManager: FileSyncManager
    let isMove: Bool
    let glassIntensity: Double
    let paneNames: PaneProviderNames
    let onQuickLook: ((URL) -> Void)?
    let onSync: (Bool) -> Void

    private var isVerifying: Bool { syncManager.verifyingDifferenceId == difference.id }

    /// Folder entries carry their collapsed contents ("everything inside syncs with the folder"),
    /// so surface that count instead of listing each item as its own row.
    private var descriptionText: String {
        guard let count = difference.enclosedItemCount, count > 0 else { return difference.description }
        return "\(difference.description) — includes \(count) item\(count == 1 ? "" : "s")"
    }
    private var canVerify: Bool {
        DifferencesSummary.canVerify(
            difference,
            isRowVerifying: isVerifying,
            isVerifyAllInProgress: syncManager.verifyAllProgress != nil
        )
    }

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: DifferenceGlyph.symbol(for: difference.type, filled: true))
                .font(.system(size: 22))
                .foregroundStyle(DifferenceGlyph.color(for: difference.type))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 32)
            
            // File Info
            VStack(alignment: .leading, spacing: 4) {
                let parts = difference.relativePath.split(separator: "/")
                if parts.count > 1 {
                    Text(parts.dropLast().joined(separator: " / "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Text(parts.last ?? "")
                    .font(.body.weight(.medium))
                
                Text(descriptionText)
                    .font(.caption)
                    .foregroundStyle(DifferenceGlyph.color(for: difference.type))
            }
            
            Spacer()
            
            // Verify with checksum (when "newer" but same size)
            if canVerify {
                Button {
                    Task { _ = await syncManager.verifyWithChecksum(difference) }
                } label: {
                    if isVerifying {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 20, height: 20)
                    } else {
                        Label("Verify", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isVerifying)
            }
            
            // Sync Action
            Button(action: { onSync(isMove) }) {
                HStack {
                    if difference.isSyncing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        switch difference.action {
                        case .copyToRight:
                            Label(isMove ? "Move to \(paneNames.right)" : "Copy to \(paneNames.right)", systemImage: "arrow.right.circle.fill")
                        case .copyToLeft:
                            Label(isMove ? "Move to \(paneNames.left)" : "Copy to \(paneNames.left)", systemImage: "arrow.left.circle.fill")
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(difference.action == .copyToRight ? .blue : .purple)
            .disabled(difference.isSyncing)
        }
        .padding(14)
        .glassCardStyle(material: .regularMaterial, intensity: glassIntensity)
        .overlay(
            RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
        )
        // The HStack's Spacer gap is not hit-testable on its own, and on macOS 26 the
        // card background comes from glassEffect rather than a hit-testable material,
        // so without an explicit content shape right-clicks over most of the card land
        // on nothing (same convention as FileRowView's contentShape for the tree menus).
        .contentShape(Rectangle())
        // Context menu only — no tap/click gestures here; gesture modifiers have a
        // history of swallowing the row buttons' clicks.
        .contextMenu { contextMenuItems }
    }

    /// Right-click menu: per-side Reveal/Quick Look/Copy Path for the sides that exist,
    /// plus the same ignore toggle the tree panes offer.
    @ViewBuilder
    private var contextMenuItems: some View {
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
}
