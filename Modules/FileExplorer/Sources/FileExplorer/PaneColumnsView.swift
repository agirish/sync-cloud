import AppKit
import Design
import Events
import SwiftUI
import Sync

/// The Columns presentation of one pane: Finder-style Miller columns over the pane's loaded tree.
///
/// Resting state is the whole trick. With an empty `browsePath` this renders exactly one column
/// spanning the pane, listing the same rows the tree view lists — which is why Columns can be the
/// default without rearranging anyone's pane on first launch. Columns appear only once a folder is
/// clicked.
///
/// Navigation here is deliberately *not* re-rooting. Drilling writes `browsePath` and nothing else:
/// no reload, no rescan, no change to the pane's comparison scope, so every difference badge stays
/// valid as you walk. `FileActionHandler.focusFolder` remains the separate, deliberate way to
/// narrow the comparison.
struct PaneColumnsView: View {
    let tree: PaneTree
    let otherTree: PaneTree
    /// Path → children for this pane's published tree, built once per publish (see
    /// `PaneChildrenIndex`). A column resolves its rows with a dictionary lookup; asking
    /// `PaneRow.children` per column per render is the recursive walk that froze the main thread.
    let childrenIndex: PaneChildrenIndex
    /// Absolute path of the pane's tree root — the folder the first column lists.
    let treeRoot: String
    @Binding var browsePath: PaneBrowsePath
    @Binding var selection: Set<String>
    let otherSelection: Set<String>
    let isLeft: Bool
    let delegate: FileActionDelegate
    let diffIndex: DiffStatusIndex
    let otherPaneName: String
    let isSingleSource: Bool
    let density: ListDensity
    let isActivePane: Bool
    /// Shared placement scratch space; column rows report their bottoms into it exactly as tree
    /// rows do, so the action bar keeps flipping edges. `nil` on surfaces with no action bar.
    let placement: PaneBarPlacement?
    let onBarEdgeFlip: (() -> Void)?
    /// Presents a Quick Look preview; owned by the hosting `FileTreeView`.
    let onQuickLook: (URL) -> Void

    /// One width shared by both panes, so the two sides stay symmetric while you read them against
    /// each other. Clamped on every write — see `PaneViewMode.clampColumnWidth`.
    @AppStorage(PaneViewMode.columnWidthDefaultsKey) private var storedColumnWidth: Double =
        Double(PaneViewMode.defaultColumnWidth)
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    /// Live width while a divider is being dragged, so the drag doesn't write defaults per frame.
    @State private var dragWidth: CGFloat?
    /// Pane width, measured — the push/stack decision is about painted width, not a guess.
    @State private var paneWidth: CGFloat = 0

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var columnWidth: CGFloat {
        PaneViewMode.clampColumnWidth(dragWidth ?? CGFloat(storedColumnWidth))
    }
    /// Below two minimum columns there is no room for a second one, so the pane shows a single
    /// column that replaces its contents as you drill and `‹` walks back out.
    private var usesPush: Bool { PaneViewMode.usesPushNavigation(paneWidth: paneWidth) }

    /// The directories each open column lists, root first.
    private var directories: [String] { browsePath.columnDirectories(treeRoot: treeRoot) }

    var body: some View {
        GeometryReader { geo in
            columnStack(paneWidth: geo.size.width)
                .onAppear { paneWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, width in paneWidth = width }
        }
    }

    @ViewBuilder
    private func columnStack(paneWidth: CGFloat) -> some View {
        // Push mode shows only the deepest column; the rest of the stack is still in `browsePath`,
        // which is what lets `‹` walk back out and `›` walk back in.
        let visible = usesPush ? Array(directories.suffix(1)) : directories
        // At rest a single column spans the pane — this is the resting state that makes Columns
        // safe to default to. It is also what push mode renders at every depth.
        let isSingleColumn = visible.count == 1

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: !isSingleColumn) {
                HStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element) { offset, directory in
                        let depth = usesPush ? browsePath.depth : offset
                        column(directory: directory, depth: depth)
                            .frame(width: isSingleColumn ? paneWidth : columnWidth)
                            .id(directory)
                            .overlay(alignment: .trailing) {
                                if !isSingleColumn && offset < visible.count - 1 {
                                    divider
                                }
                            }
                    }
                }
            }
            .scrollDisabled(isSingleColumn)
            // Keep the deepest column in view as you drill, like Finder.
            .onChange(of: browsePath) { _, path in
                guard let deepest = path.columnDirectories(treeRoot: treeRoot).last else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(deepest, anchor: .trailing) }
            }
        }
    }

    /// One column: the rows of `directory`, or a placeholder when it has none.
    ///
    /// A `List` per column rather than a `LazyVStack`, so `onDeleteCommand`, the selection binding
    /// and `PaneListSelectionStyler` keep working instead of being reimplemented three times over.
    @ViewBuilder
    private func column(directory: String, depth: Int) -> some View {
        let rows = childrenIndex.children(atPath: directory) ?? []
        List(selection: columnSelection(for: rows)) {
            ForEach(rows) { row in
                columnRow(row, depth: depth)
            }
        }
        .listStyle(.sidebar)
        .tint(glassHue.accentColor)
        .background(PaneListSelectionStyler())
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, density.metrics.treeIconSize + 6)
        .onDeleteCommand {
            let selected = tree.selectedNodes(at: selection)
            if !selected.isEmpty { delegate.handleDelete(selected) }
        }
        .overlay {
            if rows.isEmpty {
                Text("Empty")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        // Dropping onto a column's empty space targets that column's own folder, matching the
        // tree pane's background drop.
        .dropDestination(for: PaneDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            return FileTreeView.performPaneDrop(payload, toPath: directory, targetIsLeft: isLeft, delegate: delegate)
        }
        .contextMenu {
            SharedFileMenuItems.refresh(delegate: delegate)
            Divider()
            SharedFileMenuItems.newFolder(at: directory, delegate: delegate)
            SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
                delegate.handlePasteToPath(directory)
            }
            Divider()
            SharedFileMenuItems.getInfo(for: directory, delegate: delegate)
        }
    }

    @ViewBuilder
    private func columnRow(_ row: PaneRow, depth: Int) -> some View {
        let node = row.node
        // The folder you drilled *through* stays marked even though the selection has moved on to a
        // deeper column — without it a three-column stack shows no trace of how you got there.
        let isOnPath = depth < browsePath.depth && browsePath.components[depth] == node.name

        ColumnRowView(
            row: row,
            isIgnored: delegate.isNodeIgnored(node, currentPath: treeRoot),
            diffStatus: diffIndex.status(forNodeId: node.id),
            containedDiffCount: node.isDirectory ? diffIndex.containedDiffCount(forNodeId: node.id) : 0,
            density: density,
            showsChevron: node.isDirectory
        )
        .tag(node.id)
        // Single click opens a folder's column, per the decision — this is the one real change to
        // the pane's click contract, and it is what makes "columns appear when you click" work.
        // A file click closes any deeper columns without opening one of its own.
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory {
                browsePath.drill(into: node.name, atDepth: depth)
            } else {
                browsePath.truncate(toDepth: depth)
            }
            selection = [node.id]
        }
        .contextMenu {
            FileContextMenu(
                row: row, selection: selection, tree: tree, otherTree: otherTree,
                otherSelection: otherSelection, isLeft: isLeft, currentPath: treeRoot,
                delegate: delegate, otherPaneName: otherPaneName, isSingleSource: isSingleSource,
                onQuickLook: onQuickLook
            )
        }
        .draggable(makeDragPayload(for: node))
        .modifier(PaneDropTarget(rowPath: node.id, rowIsDirectory: node.isDirectory,
                                 paneIsLeft: isLeft, delegate: delegate))
        .background(rowPositionProbe(for: node))
        .listRowBackground(rowBackground(for: node, isOnPath: isOnPath))
    }

    /// Selection is confined to one column (decision 5, matching Finder and the pane's flat
    /// `Set<String>`): each column reads the shared selection filtered to its own rows and writes
    /// it wholesale, so selecting here clears every other column by construction.
    private func columnSelection(for rows: [PaneRow]) -> Binding<Set<String>> {
        let ids = Set(rows.map(\.id))
        return Binding(
            get: { selection.intersection(ids) },
            set: { selection = $0 }
        )
    }

    @ViewBuilder
    private func rowBackground(for node: FileNode, isOnPath: Bool) -> some View {
        if selection.contains(node.id) {
            wash(opacity: PaneSelectionWash.opacity(isActivePane: isActivePane))
        } else if isOnPath {
            // Quieter than a selection: this row is the trail, not the target.
            wash(opacity: PaneSelectionWash.opacity(isActivePane: false) * 0.6)
        } else {
            Color.clear
        }
    }

    private func wash(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(glassHue.accentColor.opacity(opacity))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    /// Column rows report their bottom edges exactly as tree rows do, so `PaneBarPlacement` keeps
    /// resolving the action bar's edge. The math is purely vertical, so a horizontal stack of
    /// columns needs no change to it — only these probes.
    @ViewBuilder
    private func rowPositionProbe(for node: FileNode) -> some View {
        if placement != nil {
            GeometryReader { proxy in
                Color.clear.preference(key: PaneRowBottomsKey.self,
                                       value: [node.id: proxy.frame(in: .global).maxY])
            }
        }
    }

    private func makeDragPayload(for node: FileNode) -> PaneDragPayload {
        let payload = PaneDragPayload(
            sourceIsLeft: isLeft,
            nodes: PaneDropLogic.dragNodes(for: node, selection: selection, tree: tree.nodes)
        )
        PaneDragSession.shared.active = payload
        return payload
    }

    /// The draggable seam between two columns. Writes defaults only when the drag ends, so a drag
    /// doesn't churn UserDefaults every frame.
    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                dragWidth = PaneViewMode.clampColumnWidth(columnWidth + value.translation.width)
                            }
                            .onEnded { _ in
                                if let dragWidth { storedColumnWidth = Double(dragWidth) }
                                dragWidth = nil
                            }
                    )
            }
    }
}

/// Preference carrying every visible row's bottom edge in GLOBAL space, keyed by node id.
///
/// Shared by the tree and columns presentations so both feed one `PaneBarPlacement`. Global, not a
/// named space: List rows are hosted in their own AppKit subtrees where a named space silently
/// degrades to global, which is what once flipped the action bar a quarter-viewport early.
struct PaneRowBottomsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { existing, _ in existing }
    }
}

/// A column row: the tree row plus a trailing chevron on folders.
///
/// Wraps `FileRowView` rather than reimplementing it, so the icon, name, cloud badge, difference
/// badge and contained-count pill can't drift between the two presentations — they are the same
/// view, and the chevron is the only thing Columns adds.
struct ColumnRowView: View {
    let row: PaneRow
    let isIgnored: Bool
    let diffStatus: FileDifference.DifferenceType?
    let containedDiffCount: Int
    let density: ListDensity
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            FileRowView(node: row.info, isIgnored: isIgnored, diffStatus: diffStatus,
                        containedDiffCount: containedDiffCount, density: density)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .scaledFont(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
