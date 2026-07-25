import AppKit
import Combine
import Design
import Events
import QuickLook
import SwiftUI
import Sync

extension Notification.Name {
    /// Posted after a cloud-only "Download" request is accepted, carrying the file's absolute path
    /// in `object`. The row displaying that file listens and re-checks its cloud badge while the
    /// content materializes — the context menu and the row are separate views with no shared state,
    /// and without this the badge lingered until the row was recycled.
    static let cloudDownloadRequested = Notification.Name("SyncCloudCloudDownloadRequested")
}

/// Recursive tree view for one comparison pane (left or right); context menu and actions go through the delegate.
public struct FileTreeView: View {
    /// File tree for this pane.
    public let tree: [FileNode]
    /// File tree for the opposite pane (e.g. for “copy to other pane”).
    public let otherTree: [FileNode]
    /// Whether this pane’s tree is currently loading.
    public let isLoading: Bool
    /// Absolute path of the current folder shown in this pane.
    public let currentPath: String

    @Binding public var selection: Set<String>
    /// Selected paths in the opposite pane (for mutual exclusivity and paste-from-other).
    public let otherSelection: Set<String>
    /// `true` if this view is for the left pane, `false` for the right.
    public let isLeft: Bool

    /// Handles copy, move, delete, rename, focus, and other file actions.
    public let delegate: FileActionDelegate

    /// Diff status per absolute node path for this pane (precomputed by the caller).
    public let diffIndex: DiffStatusIndex

    /// Display name of the opposite pane's provider, used as the copy/move target in menu labels.
    public let otherPaneName: String

    /// Whether the provider's ROOT path existed as a directory at Settings' last validity
    /// check (validity of a focused subfolder is not tracked — see `PaneEmptyState.classify`).
    public let rootPathIsValid: Bool
    /// Whether the pane's provider is enabled in Settings.
    public let providerIsEnabled: Bool
    /// True when the folder has entries but the hidden-files filter removed all of them.
    public let hasOnlyHiddenEntries: Bool
    /// The provider's root path, shown as the offending path in the invalid placeholder.
    public let rootPath: String
    /// Opens the Settings scene (preselected on the providers tab by the caller); nil hides
    /// the "Open Settings" buttons.
    public let onOpenSettings: (() -> Void)?

    /// True when this pane is the Tidy single-source rail rather than one of the two comparison
    /// panes. The rail has no "other pane" to compare or copy across, so its row menu drops the
    /// comparison-only items (Ignore, Copy/Move to the other provider) and renames "Compare only
    /// this folder" to a plain "Open".
    public let isSingleSource: Bool

    /// Shared placement scratch space, owned by the host (one per pane). This view fills its live
    /// geometry (`rowBottoms`/`viewportHeight`) from row/viewport probes; the host reads the edge
    /// straight from its own `body`. `nil` on the Tidy rail, which has no action bar.
    private let placement: PaneBarPlacement?
    /// Called when a SCROLL crossing flips the resolved edge — the host re-renders (with animation)
    /// so the bar cross-fades. Selection-driven placement needs no callback: changing the selection
    /// already re-renders the host, which recomputes the edge synchronously and instantly.
    private let onBarEdgeFlip: (() -> Void)?

    /// In-flight drag payload, observed so drop highlights only appear on valid targets.
    @ObservedObject private var dragSession = PaneDragSession.shared
    /// Whether a drag is hovering the pane background (drop = copy/move into `currentPath`).
    @State private var isBackgroundDropTargeted = false
    /// Item previewed via the row context menu's Quick Look. Presented by this pane's own
    /// `.quickLookPreview` — the host's presenter (spacebar) is not reachable through the
    /// delegate, and the shared QL panel only ever shows one preview at a time anyway.
    @State private var quickLookItem: URL?

    public init(tree: [FileNode], otherTree: [FileNode], isLoading: Bool, currentPath: String, selection: Binding<Set<String>>, otherSelection: Set<String>, isLeft: Bool, delegate: FileActionDelegate, diffIndex: DiffStatusIndex = .empty, otherPaneName: String? = nil, rootPathIsValid: Bool = true, providerIsEnabled: Bool = true, hasOnlyHiddenEntries: Bool = false, rootPath: String? = nil, onOpenSettings: (() -> Void)? = nil, isSingleSource: Bool = false, placement: PaneBarPlacement? = nil, onBarEdgeFlip: (() -> Void)? = nil) {
        self.tree = tree
        self.otherTree = otherTree
        self.isLoading = isLoading
        self.currentPath = currentPath
        self._selection = selection
        self.otherSelection = otherSelection
        self.isLeft = isLeft
        self.delegate = delegate
        self.diffIndex = diffIndex
        self.otherPaneName = otherPaneName ?? (isLeft ? "Right" : "Left")
        self.rootPathIsValid = rootPathIsValid
        self.providerIsEnabled = providerIsEnabled
        self.hasOnlyHiddenEntries = hasOnlyHiddenEntries
        self.rootPath = rootPath ?? currentPath
        self.onOpenSettings = onOpenSettings
        self.isSingleSource = isSingleSource
        self.placement = placement
        self.onBarEdgeFlip = onBarEdgeFlip
    }

    /// Preference carrying every visible row's bottom edge (GLOBAL space — see the viewport probe),
    /// keyed by node id, up to the list. The reduce merges each row's single-entry contribution.
    private struct RowBottomsKey: PreferenceKey {
        static let defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { existing, _ in existing }
        }
    }
    /// The list viewport's global frame (height + window-space top edge).
    private struct ViewportFrameKey: PreferenceKey {
        static let defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    /// After a scroll/layout update to the row positions, re-resolve the edge (the resolve commits
    /// its own anchor); if it flipped, ask the host to re-render (animated cross-fade). Selection
    /// changes are NOT handled here — they re-render the host anyway, which recomputes the edge
    /// synchronously and instantly.
    private func flipEdgeIfScrolledAcross() {
        guard let placement, let onBarEdgeFlip else { return }
        let wasAtTop = placement.atTop
        guard placement.resolveAtTop(selection: selection) != wasAtTop else { return }
        onBarEdgeFlip()
    }
    
    private func isPathIgnored(_ node: FileNode) -> Bool {
        return delegate.isNodeIgnored(node, currentPath: currentPath)
    }
    
    /// The placeholder to show when the tree has no rows (see `PaneEmptyState.classify`).
    var emptyState: PaneEmptyState {
        PaneEmptyState.classify(
            treeIsEmpty: tree.isEmpty,
            isLoading: isLoading,
            providerIsEnabled: providerIsEnabled,
            rootIsValid: rootPathIsValid,
            hasOnlyHiddenEntries: hasOnlyHiddenEntries
        )
    }

    // No surface style here: the pane's shape is decided by its container (`paneCardIfNeeded` /
    // `panesRegionFrame`), and its material by the glass level. This view only paints the tint.
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    /// List-density setting (H7), read ONCE here and injected into every row — a per-row
    /// @AppStorage would register a defaults observer per visible row.
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    private var density: ListDensity {
        ListDensity(rawValue: listDensityRaw) ?? .comfortable
    }
    private var glassHue: LiquidGlassHue {
        LiquidGlassHue(rawValue: glassHueRaw) ?? .blue
    }

    public var body: some View {
        ZStack {
            paneList

            switch emptyState {
            case .none:
                EmptyView()
            case .loading:
                ProgressView("Scanning Directory...")
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous))
                    .shadow(
                        color: LiquidGlass.subtleShadow.color,
                        radius: LiquidGlass.subtleShadow.radius,
                        x: LiquidGlass.subtleShadow.x,
                        y: LiquidGlass.subtleShadow.y
                    )
            case .providerDisabled:
                settingsProblemPlaceholder(
                    icon: "externaldrive.badge.xmark",
                    title: "Provider is disabled",
                    detail: "Enable it in Settings to browse its files."
                )
            case .invalidRoot:
                settingsProblemPlaceholder(
                    icon: "exclamationmark.triangle",
                    title: "Folder not found",
                    detail: "The configured folder is missing or not a directory.",
                    path: rootPath
                )
            case .emptyFolder(let hasOnlyHiddenEntries):
                EmptyStateView(
                    icon: "folder",
                    title: "Folder is empty",
                    caption: hasOnlyHiddenEntries
                        ? "It only contains hidden items — use the Hidden toggle to show them."
                        : nil,
                    layout: .compact
                )
                // Hug the content so clicks around the placeholder still reach the pane
                // list underneath (empty-area context menu, background drop target).
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !tree.isEmpty && isLoading {
                // Subtle corner overlay when refreshing non-empty tree; display-only, so it
                // must never intercept clicks meant for the rows underneath it.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .padding(12)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(20)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Placeholder for states the user fixes in Settings (missing root, disabled provider):
    /// warning icon, explanation, optionally the offending path, and an Open Settings button.
    @ViewBuilder
    private func settingsProblemPlaceholder(icon: String, title: String, detail: String, path: String? = nil) -> some View {
        EmptyStateView(
            icon: icon,
            tint: SemanticColor.warning,
            title: title,
            message: detail,
            path: path,
            secondary: onOpenSettings.map { .init("Open Settings", handler: $0) },
            layout: .compact
        )
        // Hug the content so clicks around the placeholder still reach the pane list
        // underneath (empty-area context menu, background drop target).
        .frame(maxWidth: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The pane's List plus its list-level chrome: empty-area context menu, background drop
    /// target (drop into the pane's current folder), and the drop highlight.
    @ViewBuilder
    private var paneList: some View {
        List(selection: $selection) {
            OutlineGroup(tree, children: \.children) { node in
                treeRow(for: node)
            }
        }
        .listStyle(SidebarListStyle())
        // Tint disclosure chevrons etc. with the app accent (the OS accent otherwise). The selected
        // ROW highlight ignores this — macOS paints it from selectedContentBackgroundColor (gray on
        // a Graphite accent) — so the styler below disables that highlight and each row draws its own
        // accent background via `.listRowBackground`.
        .tint(glassHue.accentColor)
        .background(PaneListSelectionStyler())
        // Drop the sidebar list's own vibrant background so the pane picks up the selected
        // content surface, matching the bottom workspace.
        .scrollContentBackground(.hidden)
        .contentSurface(hue: glassHue, tint: surfaceTint)
        // The viewport's GLOBAL frame — height plus its top edge in window coordinates. Rows report
        // their positions in global space too (a named space can't be resolved from inside a List
        // row — each row is its own AppKit-hosted subtree — and silently fell back to global,
        // inflating every row by this very offset and flipping the bar a quarter-viewport early);
        // the placement math subtracts the two, so the frame of reference finally agrees.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ViewportFrameKey.self, value: geo.frame(in: .global))
            }
        )
        // The row/frame preferences fire every frame while scrolling, but they only mutate the
        // shared placement (no view invalidation) and ask the host to re-render solely on a genuine
        // edge flip — so scrolling stays free of per-frame List re-renders.
        .onPreferenceChange(ViewportFrameKey.self) { frame in
            placement?.viewportHeight = frame.height
            placement?.viewportGlobalMinY = frame.minY
            flipEdgeIfScrolledAcross()
        }
        .onPreferenceChange(RowBottomsKey.self) { bottoms in
            placement?.rowBottoms = bottoms
            flipEdgeIfScrolledAcross()
        }
        // No .onChange(of: selection) committer here: the selection change re-renders the host,
        // whose body resolve is the ONE place the edge (and its hysteresis anchor) commits. A second
        // committer racing it from this side was part of the old flip-flop.
        .onDeleteCommand {
            let selectedNodes = tree.findNodes(at: selection)
            if !selectedNodes.isEmpty {
                delegate.handleDelete(selectedNodes)
            }
        }
        .contextMenu { emptyAreaContextMenu }
        .quickLookPreview($quickLookItem)
        .dropDestination(for: PaneDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            return Self.performPaneDrop(payload, toPath: currentPath, targetIsLeft: isLeft, delegate: delegate)
        } isTargeted: { targeting in
            isBackgroundDropTargeted = targeting
        }
        .overlay {
            if isBackgroundDropTargeted && backgroundDropAllowed {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(glassHue.accentColor, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// One tree row: content, its context menu, draggable payload, and a drop target
    /// (directories accept into themselves, files into their enclosing folder). Single-click
    /// selection is left entirely to the List; drilling into a folder is via the Compare
    /// button / context menu.
    @ViewBuilder
    private func treeRow(for node: FileNode) -> some View {
        FileRowView(
            node: node,
            isIgnored: isPathIgnored(node),
            diffStatus: diffIndex.status(forNodeId: node.id),
            containedDiffCount: node.isDirectory ? diffIndex.containedDiffCount(forNodeId: node.id) : 0,
            density: density
        )
        .tag(node.id)
        .contextMenu {
            FileContextMenu(
                node: node,
                selection: selection,
                tree: tree,
                otherTree: otherTree,
                otherSelection: otherSelection,
                isLeft: isLeft,
                currentPath: currentPath,
                delegate: delegate,
                otherPaneName: otherPaneName,
                isSingleSource: isSingleSource,
                onQuickLook: { quickLookItem = $0 }
            )
        }
        .draggable(makeDragPayload(for: node))
        .modifier(PaneDropTarget(
            rowPath: node.id,
            rowIsDirectory: node.isDirectory,
            paneIsLeft: isLeft,
            delegate: delegate
        ))
        // Every visible row reports its bottom edge so the clicked row's position is already known
        // the instant it becomes selected (placement can then resolve synchronously). Only visible
        // rows lay out, and the reports mutate the reference probe rather than any @State, so this
        // adds no re-render cost during scroll.
        .background(rowPositionProbe(for: node))
        // Our own selection highlight (the system one is disabled by PaneListSelectionStyler): an
        // accent-tinted capsule so the selected row follows the app's chosen hue, not the OS gray.
        .listRowBackground(rowSelectionBackground(for: node))
    }

    /// The accent-tinted background for a selected row; nothing for an unselected one. Keyed on the
    /// SwiftUI selection binding, so it stays correct regardless of window focus.
    @ViewBuilder
    private func rowSelectionBackground(for node: FileNode) -> some View {
        if selection.contains(node.id) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(glassHue.accentColor.opacity(0.22))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }

    /// Reports a row's bottom edge in GLOBAL space, keyed by its id, so the list always knows where
    /// every visible row sits. Global, not a named space: List rows live in their own AppKit-hosted
    /// subtrees where a named space can't be resolved (the lookup silently degraded to global
    /// anyway, while the viewport half measured locally — the mismatched frames of reference were
    /// the premature flip). The placement math subtracts the viewport's global origin.
    /// Withheld on the Tidy rail (no action bar to place).
    @ViewBuilder
    private func rowPositionProbe(for node: FileNode) -> some View {
        if placement != nil {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: RowBottomsKey.self,
                    value: [node.id: proxy.frame(in: .global).maxY]
                )
            }
        }
    }

    /// Built lazily when a drag actually starts (`.draggable` takes an autoclosure); also
    /// records the payload in the shared session so drop targets can validate while hovering.
    private func makeDragPayload(for node: FileNode) -> PaneDragPayload {
        let payload = PaneDragPayload(
            sourceIsLeft: isLeft,
            nodes: PaneDropLogic.dragNodes(for: node, selection: selection, tree: tree)
        )
        PaneDragSession.shared.active = payload
        return payload
    }

    /// Whether the drag currently in flight may be dropped on this pane's background
    /// (i.e. into the pane's current folder).
    private var backgroundDropAllowed: Bool {
        guard let payload = dragSession.active else { return false }
        return PaneDropLogic.canDrop(
            draggedIds: payload.nodes.map(\.id),
            sourceIsLeft: payload.sourceIsLeft,
            targetIsLeft: isLeft,
            targetDirectoryPath: currentPath
        )
    }

    /// Validates and routes a performed drop; shared by row and background targets.
    static func performPaneDrop(_ payload: PaneDragPayload, toPath path: String, targetIsLeft: Bool, delegate: FileActionDelegate) -> Bool {
        defer { PaneDragSession.shared.active = nil }
        let allowed = PaneDropLogic.canDrop(
            draggedIds: payload.nodes.map(\.id),
            sourceIsLeft: payload.sourceIsLeft,
            targetIsLeft: targetIsLeft,
            targetDirectoryPath: path
        )
        Logger.shared.debug("Pane drop received: \(payload.nodes.count) node(s) onto \(path) (allowed: \(allowed))")
        guard allowed else { return false }
        delegate.handleDrop(payload.nodes, toPath: path, isMove: ModifierTracker.moveModifierHeld)
        return true
    }

    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        SharedFileMenuItems.refresh(delegate: delegate)
        Divider()
        SharedFileMenuItems.newFolder(at: currentPath, delegate: delegate)
        SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
            delegate.handlePasteToPath(currentPath)
        }
        Divider()
        SharedFileMenuItems.getInfo(for: currentPath, delegate: delegate)
        Divider()
        Menu("Sort By") {
            Button("Name") { delegate.handleSort(.name) }
            Button("Kind") { delegate.handleSort(.kind) }
            Button("Date Modified") { delegate.handleSort(.dateModified) }
            Button("Size") { delegate.handleSort(.size) }
            Button("Tags") { delegate.handleSort(.tags) }
        }
    }
}

/// Menu items shared verbatim between the pane's empty-area menu and the row menu
/// (FileContextMenu), so their labels, icons, and enabled states can't drift. Row-only
/// items (Reveal, Quick Look, Rename, …) stay in FileContextMenu. The two menus target
/// different paths, so each item takes its target explicitly.
enum SharedFileMenuItems {
    static func refresh(delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleRefresh() }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
    }

    static func newFolder(at path: String, delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleCreateFolder(at: path) }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
    }

    static func getInfo(for path: String, delegate: FileActionDelegate) -> some View {
        Button(action: { delegate.handleGetInfo(for: path) }) {
            Label("Get Info", systemImage: "info.circle")
        }
    }

    /// The empty-area menu pastes into the current folder (handlePasteToPath) while the
    /// row menu pastes relative to the clicked node (handlePaste), so the action comes
    /// from the caller; the label and the clipboard gating stay shared.
    static func pasteHere(clipboardHasItems: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Paste here", systemImage: "doc.on.clipboard")
        }
        .disabled(!clipboardHasItems)
    }
}

/// Makes every tree row accept cross-pane drags. Directory rows target themselves and
/// highlight while a valid drop hovers; file rows route the drop to their enclosing folder,
/// like Finder, and never highlight — a highlight on the file row itself would misread as
/// dropping "into" the file.
private struct PaneDropTarget: ViewModifier {
    /// Absolute path of the node this row represents.
    let rowPath: String
    let rowIsDirectory: Bool
    let paneIsLeft: Bool
    let delegate: FileActionDelegate

    @ObservedObject private var dragSession = PaneDragSession.shared
    @State private var isTargeted = false
    // Drop highlight reads the user-selected glass hue, like the rest of the main window (C7).
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    func body(content: Content) -> some View {
        let targetDirectoryPath = PaneDropLogic.dropTargetDirectory(forRowId: rowPath, isDirectory: rowIsDirectory)
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hueAccent.opacity(rowIsDirectory && isTargeted && dropAllowed(into: targetDirectoryPath) ? 0.25 : 0))
            }
            .dropDestination(for: PaneDragPayload.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return FileTreeView.performPaneDrop(payload, toPath: targetDirectoryPath, targetIsLeft: paneIsLeft, delegate: delegate)
            } isTargeted: { targeting in
                isTargeted = targeting
            }
    }

    private func dropAllowed(into directoryPath: String) -> Bool {
        guard let payload = dragSession.active else { return false }
        return PaneDropLogic.canDrop(
            draggedIds: payload.nodes.map(\.id),
            sourceIsLeft: payload.sourceIsLeft,
            targetIsLeft: paneIsLeft,
            targetDirectoryPath: directoryPath
        )
    }
}

/// Dynamically generated context menu for file operations bounding the selected node and the overarching selection
/// Adapts its available buttons depending on whether a single file, a batch of files, or a folder was right-clicked.
struct FileContextMenu: View {
    let node: FileNode
    let selection: Set<String>
    let tree: [FileNode]
    let otherTree: [FileNode]
    let otherSelection: Set<String>
    let isLeft: Bool
    let currentPath: String
    let delegate: FileActionDelegate
    let otherPaneName: String
    /// True on the Tidy single-source rail: no opposite pane exists, so the comparison-only items
    /// (Ignore, Copy/Move to the other provider, Copy from the other pane) are dropped and the
    /// folder-focus item reads as a plain "Open" rather than "Compare only this folder".
    let isSingleSource: Bool
    /// Presents a Quick Look preview for the given item (parity with the Differences
    /// table's row menu); provided by the owning pane's `FileTreeView`.
    let onQuickLook: (URL) -> Void

    static func resolvedSelection(node: FileNode, selection: Set<String>, tree: [FileNode]) -> [FileNode] {
        let effectiveSelection: Set<String>
        if selection.isEmpty {
            effectiveSelection = [node.id]
        } else if selection.contains(node.id) {
            effectiveSelection = selection
        } else {
            effectiveSelection = [node.id]
        }
        // Prune nested nodes (a folder and its descendant never travel together) exactly as the
        // drag path does, so a context-menu Copy/Move/Delete on a selection spanning a folder AND an
        // item inside it can't pass the superset to a handler — matching PaneDropLogic.dragNodes and
        // the downstream copy/move prune, and keeping the two entry points from drifting apart.
        return tree.findNodes(at: effectiveSelection).pruneNestedNodes()
    }

    var body: some View {
        let selectedNodes = Self.resolvedSelection(node: node, selection: selection, tree: tree)
        let count = selectedNodes.count
        
        Group {
            SharedFileMenuItems.refresh(delegate: delegate)
            Divider()
            if count == 1, let singleNode = selectedNodes.first {
                SharedFileMenuItems.getInfo(for: singleNode.id, delegate: delegate)
                // Same direct reveal the Differences row menu and the error alert use;
                // there is no FileActionHandler reveal to delegate to.
                Button(action: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: singleNode.id)]) }) {
                    Label("Reveal in Finder", systemImage: RevealGlyph.inFinder)
                }
                Button(action: { onQuickLook(URL(fileURLWithPath: singleNode.id)) }) {
                    Label("Quick Look", systemImage: "doc.viewfinder")
                }
                // Materialize a cloud-only placeholder. Works cleanly for iCloud (the one public,
                // non-blocking download API); for other File Provider providers it fails and we log
                // a pointer to Finder rather than pretend. Reveal in Finder (above) is the reliable
                // download path everywhere.
                if !singleNode.isDirectory, MaterializationStatus.isCloudOnly(atPath: singleNode.id) {
                    Button {
                        do {
                            try MaterializationStatus.download(atPath: singleNode.id)
                            Logger.shared.info("Requested download of cloud-only file: \(singleNode.id)")
                            // Tell the row to watch for the content landing so its cloud badge
                            // clears; on the failure path the badge (correctly) stays.
                            NotificationCenter.default.post(name: .cloudDownloadRequested, object: singleNode.id)
                        } catch {
                            Logger.shared.warning("Download unavailable for “\(singleNode.name)” — reveal it in Finder to download it (\(error.localizedDescription))")
                        }
                    } label: {
                        Label("Download", systemImage: "icloud.and.arrow.down")
                    }
                }
                Divider()
                Button(action: { delegate.handleRename(singleNode) }) {
                    Label("Rename", systemImage: "pencil")
                }
                
                if singleNode.isDirectory {
                    SharedFileMenuItems.newFolder(at: singleNode.id, delegate: delegate)
                    Divider()
                    Button(action: { delegate.handleFocus(singleNode) }) {
                        // On the comparison panes this isolates a specific folder mapping ("Compare
                        // only this folder"); on the single-source rail there's nothing to compare —
                        // it just drills the rail into the folder, so it reads as a plain "Open".
                        if isSingleSource {
                            Label("Open", systemImage: "arrow.forward")
                        } else {
                            Label("Compare only this folder", systemImage: "scope")
                        }
                    }
                }
            }

            // Comparison-only: Ignore and Copy/Move to the other provider are meaningless on the
            // single-source rail (there is no opposite pane), so they're dropped there.
            if !isSingleSource {
                let allIgnored = selectedNodes.allSatisfy { n in
                    delegate.isNodeIgnored(n, currentPath: currentPath)
                }
                Button(action: { delegate.handleIgnore(selectedNodes) }) {
                    Label(allIgnored ? "Include in comparison" : "Ignore in comparison", systemImage: allIgnored ? "eye" : "eye.slash")
                }
            }

            // Separator before the clipboard section. Skipped only when nothing sits between it and
            // the Refresh divider above (single-source multi-select drops the single-node block and
            // every comparison item), so two dividers never stack.
            if count == 1 || !isSingleSource {
                Divider()
            }

            if !isSingleSource {
                // Copy/Move to the other pane share the toolbar/header vocabulary (TransferGlyph).
                // Copy is non-directional (the target pane is named in the label); Move points its
                // box-arrow at the actual target pane, like the toolbar — right when this is the
                // left pane, left when it's the right pane.
                Button(action: { delegate.handleCopy(selectedNodes) }) {
                    Label(count > 1 ? "Copy \(count) items to \(otherPaneName)" : "Copy to \(otherPaneName)", systemImage: TransferGlyph.copy)
                }

                Button(action: { delegate.handleMove(selectedNodes) }) {
                    Label(count > 1 ? "Move \(count) items to \(otherPaneName)" : "Move to \(otherPaneName)", systemImage: TransferGlyph.move(toRight: isLeft))
                }

                Divider()
            }

            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: true) }) {
                Label(count > 1 ? "Cut \(count) items" : "Cut", systemImage: "scissors")
            }
            
            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: false) }) {
                Label(count > 1 ? "Copy \(count) items" : "Copy", systemImage: "doc.on.doc")
            }
            
            SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
                delegate.handlePaste(node)
            }

            if !isSingleSource, !otherSelection.isEmpty {
                // Pruned like every other entry point: the transfer prunes downstream anyway,
                // so an unpruned list here only mislabeled the count ("Copy 3 items" for a
                // folder plus two of its own children, which transfer as 1).
                let otherSelectedNodes = otherTree.findNodes(at: otherSelection).pruneNestedNodes()
                if !otherSelectedNodes.isEmpty {
                    Button(action: { delegate.handlePasteExplicit(node, nodes: otherSelectedNodes) }) {
                        if otherSelectedNodes.count > 1 {
                            Label("Copy \(otherSelectedNodes.count) items from \(otherPaneName)", systemImage: "arrow.right.to.line.compact")
                        } else if let first = otherSelectedNodes.first {
                            Label("Copy '\(first.name)' from \(otherPaneName)", systemImage: "arrow.right.to.line.compact")
                        }
                    }
                }
            }
            
            Divider()
            
            Button(role: .destructive, action: { delegate.handleDelete(selectedNodes) }) {
                Label(count > 1 ? "Delete \(count) items" : "Delete", systemImage: "trash")
            }
        }
    }
}

/// Renders a single row representing a file or directory node with its associated system icon,
/// plus a trailing sync-status badge when the node (or, for folders, anything beneath it) differs.
struct FileRowView: View {
    let node: FileNode
    let isIgnored: Bool
    /// Diff status of the node itself, or nil when it is in sync.
    let diffStatus: FileDifference.DifferenceType?
    /// Number of differences beneath this node (directories only; 0 elsewhere).
    let containedDiffCount: Int
    /// Whether this file is a cloud-only placeholder (content not on disk). Detected lazily per row
    /// via one `lstat` — off the scan, so a big tree pays nothing until a row actually appears.
    @State private var isCloudOnly = false
    /// List-density setting (H7), injected by `FileTreeView` (which reads the @AppStorage once
    /// for the whole pane): comfortable renders exactly the pre-setting look; compact tightens
    /// the row and drops the secondary size/date detail.
    let density: ListDensity
    /// Bumped when a Download is requested for this file (see `.cloudDownloadRequested`), keying
    /// the short poll that clears the badge once the content lands.
    @State private var downloadWatchToken = 0

    private var densityMetrics: ListDensityMetrics { density.metrics }

    /// Shared formatter (sizes use FileSizeFormat.byteCount): rows render lazily but
    /// scroll fast, so allocating a formatter per row body would still churn.
    @MainActor private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Size for files, date modified for directories (a directory's fileSize is just the
    /// entry size, not its contents); nil when the scan didn't populate the metadata.
    private var secondaryText: String? {
        if node.isDirectory {
            guard let date = node.modificationDate else { return nil }
            return Self.modifiedFormatter.string(from: date)
        }
        guard let size = node.fileSize else { return nil }
        return FileSizeFormat.byteCount.string(fromByteCount: Int64(size))
    }

    var body: some View {
        HStack(spacing: density == .compact ? 8 : 10) {
            Image(nsImage: FileIconCache.icon(name: node.name, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: densityMetrics.treeIconSize, height: densityMetrics.treeIconSize)
            // Affix whitespace made visible ("Swimming " → "Swimming␣"): such a node can
            // have a pixel-identical sibling that is actually a different item.
            Text(NameDisplay.visibleName(node.name))
                .font(.system(.body, design: .rounded))
                .strikethrough(isIgnored, color: .secondary)
                .foregroundStyle(isIgnored ? .secondary : .primary)
            Spacer()
            if densityMetrics.showsSecondaryDetail, let secondaryText {
                Text(secondaryText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if isCloudOnly {
                // A dataless placeholder: on the cloud, not on this Mac. A generic cloud (not the
                // iCloud glyph) since it applies to any File Provider (Dropbox, Drive, OneDrive, Box).
                Image(systemName: "cloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Cloud-only — content isn't downloaded to this Mac")
                    .accessibilityLabel("Cloud-only, not downloaded")
            }
            if let diffStatus {
                // Shape encodes direction/kind so status is readable without color
                // (colors match the Differences table in the Differences pane).
                Image(systemName: DifferenceGlyph.symbol(for: diffStatus, filled: false))
                    .font(.subheadline)
                    .foregroundStyle(DifferenceGlyph.color(for: diffStatus))
                    .help(Self.badgeHelp(for: diffStatus))
                    .accessibilityLabel(Self.badgeHelp(for: diffStatus))
            } else if containedDiffCount > 0 {
                Text("\(containedDiffCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                    .help("\(containedDiffCount) difference\(containedDiffCount == 1 ? "" : "s") inside")
                    .accessibilityLabel("\(containedDiffCount) difference\(containedDiffCount == 1 ? "" : "s") inside")
            }
        }
        .padding(.vertical, densityMetrics.flatRowVerticalPadding)
        .contentShape(Rectangle())
        .task(id: node.id) {
            guard !node.isDirectory else { isCloudOnly = false; return }
            let path = node.id
            // lstat off the main actor; it's cheap but there's no reason to do syscalls on it.
            isCloudOnly = await Task.detached { MaterializationStatus.isCloudOnly(atPath: path) }.value
        }
        // After a Download request for THIS file, re-check the badge as the content arrives.
        .onReceive(NotificationCenter.default.publisher(for: .cloudDownloadRequested)) { note in
            guard note.object as? String == node.id else { return }
            downloadWatchToken &+= 1
        }
        // Polls the lstat once a second for ~10 s: materialization is asynchronous and has no
        // public completion callback, so a short bounded poll is the cheap honest option. The
        // badge clears the moment the check says the content is local; if it never does (the
        // download stalled or failed), the badge correctly stays. Cancel-safe: keyed .task is
        // cancelled when the row disappears, and Task.sleep throws on cancellation.
        .task(id: downloadWatchToken) {
            guard downloadWatchToken > 0, isCloudOnly, !node.isDirectory else { return }
            let path = node.id
            for _ in 0..<10 {
                guard (try? await Task.sleep(nanoseconds: 1_000_000_000)) != nil else { return }
                let stillCloudOnly = await Task.detached { MaterializationStatus.isCloudOnly(atPath: path) }.value
                if Task.isCancelled { return }
                if !stillCloudOnly {
                    isCloudOnly = false
                    return
                }
            }
        }
    }

    static func badgeHelp(for type: FileDifference.DifferenceType) -> String {
        switch type {
        case .missingOnRight: return "Missing on right"
        case .missingOnLeft: return "Missing on left"
        case .differentDates: return "Different dates or sizes"
        case .nameConflict: return "Name conflict (names differ only invisibly)"
        }
    }
}
