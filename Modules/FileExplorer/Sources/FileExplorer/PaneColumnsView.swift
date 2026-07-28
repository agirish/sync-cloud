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
    /// Applies a new column stack for this pane. Routed through the host rather than written
    /// straight to the binding because the seam link makes this a two-pane decision, and only the
    /// host can see the other pane's tree to mirror into it.
    let onNavigate: (PaneBrowsePath) -> Void
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
    /// The column width the current divider drag started from. `DragGesture.translation` is
    /// cumulative, so the anchor must not move while the drag runs.
    @State private var dragAnchorWidth: CGFloat?

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var columnWidth: CGFloat {
        PaneViewMode.clampColumnWidth(dragWidth ?? CGFloat(storedColumnWidth))
    }
    /// The directories each open column lists, root first.
    private var directories: [String] { browsePath.columnDirectories(treeRoot: treeRoot) }

    var body: some View {
        // The measured width feeds the layout directly. It used to be mirrored into @State and read
        // back from there, which meant the first render of any pane decided push-vs-stack from a
        // width of 0 — a wide pane opened as one column and corrected itself a frame later.
        GeometryReader { geo in
            columnStack(paneWidth: geo.size.width)
        }
    }

    @ViewBuilder
    private func columnStack(paneWidth: CGFloat) -> some View {
        // Below two minimum columns there is no room for a second one, so the pane shows a single
        // column that replaces its contents as you drill and `‹` walks back out.
        let usesPush = PaneViewMode.usesPushNavigation(paneWidth: paneWidth)
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
            //
            // Deferred a runloop turn: `onChange` fires while SwiftUI is applying the update that
            // ADDS the new column, so scrolling to its id from here targets a column the stack has
            // not laid out yet — the scroll lands short and the freshly opened column sits
            // half-off the edge until something else moves it. A turn's delay costs nothing
            // visually; the scroll has its own 0.18s animation either way.
            .onChange(of: browsePath) { _, path in
                guard let deepest = path.columnDirectories(treeRoot: treeRoot).last else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(deepest, anchor: .trailing) }
                }
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
        List(selection: columnSelection(for: rows, depth: depth)) {
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
        // Single click opens a folder's column, per the decision — the one real change to the
        // pane's click contract, and what makes "columns appear when you click" work. A file click
        // closes any deeper columns without opening one of its own.
        //
        // `simultaneousGesture` rather than `onTapGesture`: the tap must not CONSUME the click, so
        // that ⌘- and ⇧-click still reach the List and extend or range-select there. That much is
        // unchanged from `dba5cd3`.
        //
        // What changed is that this handler commits a PLAIN click's selection itself again. Leaving
        // it entirely to the List looked right — it is what the tree presentation does — but it does
        // not survive this gesture: one instrumented session logged **42 column taps and only 8
        // selections**, i.e. this closure ran (the column navigated) while the row never highlighted
        // and the action bar never appeared. That is the dead click, and it is why `[click]` lines
        // were so much rarer than `[columns]` lines in the log.
        //
        // Only a plain click is taken. ⌘ and ⇧ return at the guard below without touching
        // `selection`, so the multi-select `dba5cd3` restored is untouched: the flattening it fixed
        // came from assigning on EVERY tap, modifiers included.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            // ⌘ and ⇧ clicks are the List's business — extend and range-select, no navigation.
            guard PaneViewMode.clickNavigates(modifiers: NSEvent.modifierFlags) else { return }
            Logger.shared.debug("[tap] \(isLeft ? "left" : "right") col\(depth) \(node.isDirectory ? "dir" : "file") \(node.name)")
            // Before navigating: a drill restructures the column stack, and the selection should be
            // committed against the stack the user clicked in, not the one they are about to get.
            if selection != [node.id] { selection = [node.id] }
            onNavigate(navigation(for: row, depth: depth))
            // The click's cost, measured from mouse-UP.
            //
            // `[click]`'s own timing is taken from the selection commit, which happens on mouse-DOWN
            // inside `NSTableView`'s tracking loop — so it spans however long the button was held,
            // and reports ~290ms for a click that cost the app nothing. Rebuilding the app with
            // optimisations changed those numbers not at all, which is what gave the lie away: real
            // computation would have moved. This stamp starts after the button is already up, so
            // whatever it measures is work.
            let released = CFAbsoluteTimeGetCurrent()
            DispatchQueue.main.async {
                let ms = (CFAbsoluteTimeGetCurrent() - released) * 1000
                Logger.shared.debug("[render] \(isLeft ? "left" : "right") pane re-rendered in \(String(format: "%.1fms", ms))")
            }
        })
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
    private func columnSelection(for rows: [PaneRow], depth: Int) -> Binding<Set<String>> {
        let ids = Set(rows.map(\.id))
        return Binding(
            get: { selection.intersection(ids) },
            set: { newValue in
                // Logged including the EMPTY writes, which are the interesting ones: an empty write
                // is silent everywhere else (it enforces nothing and takes no token in
                // `applySelectionWrite`), so a selection that lands and is then cleared would look
                // exactly like one that never landed at all.
                Logger.shared.debug("[sel] \(isLeft ? "left" : "right") list wrote \(newValue.count) item(s)")
                selection = newValue
                // The List committed this one, which means the tap gesture did NOT — the two never
                // both drive a single click, and the log showed `[sel]` lines with no `[tap]`
                // beside them. Those are the clicks that select a folder and leave its column
                // shut: `TapGesture` fails outright if the pointer drifts even slightly, because
                // the row is also `.draggable` and the drag claims the gesture, while
                // `NSTableView` selects on mouse-down regardless.
                //
                // So navigation cannot hang off the gesture alone. Whichever source commits the
                // selection navigates for it, and they agree by construction because both call
                // `navigation(for:depth:)`. A tap that DOES fire drills synchronously and this one
                // then computes the same path, which `setBrowsePath` discards as unchanged.
                guard PaneViewMode.clickNavigates(modifiers: NSEvent.modifierFlags),
                      newValue.count == 1,
                      let id = newValue.first,
                      let row = rows.first(where: { $0.id == id })
                else { return }
                let path = navigation(for: row, depth: depth)
                // Deferred a runloop turn: `browsePath` restructures the column stack, and writing
                // it from inside the List's own selection commit is the mid-commit sibling write
                // that drops clicks outright (`aa9d407`).
                DispatchQueue.main.async { onNavigate(path) }
            }
        )
    }

    /// Where a click on `row` in the column at `depth` should leave the stack: a folder opens its
    /// own column, a file closes any deeper ones without opening one.
    ///
    /// Shared by the tap gesture and the List's selection commit so the two can never disagree
    /// about what a click means.
    private func navigation(for row: PaneRow, depth: Int) -> PaneBrowsePath {
        var path = browsePath
        if row.node.isDirectory {
            path.drill(into: row.node.name, atDepth: depth)
        } else {
            path.truncate(toDepth: depth)
        }
        return path
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
                                // Capture the starting width once; `translation` is cumulative, so
                                // folding it into the live width compounds every frame.
                                let anchor = dragAnchorWidth ?? columnWidth
                                if dragAnchorWidth == nil { dragAnchorWidth = anchor }
                                dragWidth = PaneViewMode.draggedColumnWidth(anchor: anchor,
                                                                            translation: value.translation.width)
                            }
                            .onEnded { _ in
                                if let dragWidth { storedColumnWidth = Double(dragWidth) }
                                dragWidth = nil
                                dragAnchorWidth = nil
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
