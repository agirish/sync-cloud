import AppKit
import Design
import Events
import QuickLook
import SwiftUI
import Sync

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

    /// In-flight drag payload, observed so drop highlights only appear on valid targets.
    @ObservedObject private var dragSession = PaneDragSession.shared
    /// Whether a drag is hovering the pane background (drop = copy/move into `currentPath`).
    @State private var isBackgroundDropTargeted = false
    /// Item previewed via the row context menu's Quick Look. Presented by this pane's own
    /// `.quickLookPreview` — the host's presenter (spacebar) is not reachable through the
    /// delegate, and the shared QL panel only ever shows one preview at a time anyway.
    @State private var quickLookItem: URL?

    public init(tree: [FileNode], otherTree: [FileNode], isLoading: Bool, currentPath: String, selection: Binding<Set<String>>, otherSelection: Set<String>, isLeft: Bool, delegate: FileActionDelegate, diffIndex: DiffStatusIndex = .empty, otherPaneName: String? = nil, rootPathIsValid: Bool = true, providerIsEnabled: Bool = true, hasOnlyHiddenEntries: Bool = false, rootPath: String? = nil, onOpenSettings: (() -> Void)? = nil) {
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

    @AppStorage(LiquidGlass.intensityKey) private var glassIntensity: Double = 0.65
    @AppStorage(LiquidGlass.surfaceStyleKey) private var surfaceStyleRaw: String = SurfaceStyle.unified.rawValue
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var surfaceTint: Double = 0
    private var surfaceStyle: SurfaceStyle {
        SurfaceStyle(rawValue: surfaceStyleRaw) ?? .unified
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
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Folder is empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if hasOnlyHiddenEntries {
                        Text("It only contains hidden items — use the Hidden toggle to show them.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
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
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            if let path {
                Text(path)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let onOpenSettings {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 24)
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
        // Drop the sidebar list's own vibrant background so the pane picks up the selected
        // content surface, matching the bottom workspace.
        .scrollContentBackground(.hidden)
        .contentSurface(surfaceStyle, intensity: glassIntensity, hue: glassHue, tint: surfaceTint)
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
                    .strokeBorder(Color.accentColor, lineWidth: 2)
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
            containedDiffCount: node.isDirectory ? diffIndex.containedDiffCount(forNodeId: node.id) : 0
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

    func body(content: Content) -> some View {
        let targetDirectoryPath = PaneDropLogic.dropTargetDirectory(forRowId: rowPath, isDirectory: rowIsDirectory)
        content
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(rowIsDirectory && isTargeted && dropAllowed(into: targetDirectoryPath) ? 0.25 : 0))
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
        return tree.findNodes(at: effectiveSelection)
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
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                Button(action: { onQuickLook(URL(fileURLWithPath: singleNode.id)) }) {
                    Label("Quick Look", systemImage: "eye")
                }
                Divider()
                Button(action: { delegate.handleRename(singleNode) }) {
                    Label("Rename", systemImage: "pencil")
                }
                
                if singleNode.isDirectory {
                    SharedFileMenuItems.newFolder(at: singleNode.id, delegate: delegate)
                    Divider()
                    Button(action: { delegate.handleFocus(singleNode) }) {
                        // Better clarifies the function which isolates a specific folder mapping
                        Label("Compare only this folder", systemImage: "scope")
                    }
                }
            }
            
            let allIgnored = selectedNodes.allSatisfy { n in 
                delegate.isNodeIgnored(n, currentPath: currentPath)
            }
            Button(action: { delegate.handleIgnore(selectedNodes) }) {
                Label(allIgnored ? "Include in comparison" : "Ignore in comparison", systemImage: allIgnored ? "eye" : "eye.slash")
            }
            Divider()
            
            Button(action: { delegate.handleCopy(selectedNodes) }) {
                Label(count > 1 ? "Copy \(count) items to \(otherPaneName)" : "Copy to \(otherPaneName)", systemImage: "arrow.right.doc.on.clipboard")
            }

            Button(action: { delegate.handleMove(selectedNodes) }) {
                Label(count > 1 ? "Move \(count) items to \(otherPaneName)" : "Move to \(otherPaneName)", systemImage: "arrow.right.square")
            }
            
            Divider()
            
            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: true) }) {
                Label(count > 1 ? "Cut \(count) items" : "Cut", systemImage: "scissors")
            }
            
            Button(action: { delegate.handleCopyToClipboard(selectedNodes, isCut: false) }) {
                Label(count > 1 ? "Copy \(count) items" : "Copy", systemImage: "doc.on.doc")
            }
            
            SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
                delegate.handlePaste(node)
            }

            if !otherSelection.isEmpty {
                let otherSelectedNodes = otherTree.findNodes(at: otherSelection)
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
        HStack(spacing: 10) {
            Image(nsImage: FileIconCache.icon(name: node.name, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: 17, height: 17)
            Text(node.name)
                .font(.system(.body, design: .rounded))
                .strikethrough(isIgnored, color: .secondary)
                .foregroundStyle(isIgnored ? .secondary : .primary)
            Spacer()
            if let secondaryText {
                Text(secondaryText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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
                    .accessibilityLabel("\(containedDiffCount) differences inside")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    static func badgeHelp(for type: FileDifference.DifferenceType) -> String {
        switch type {
        case .missingOnRight: return "Missing on right"
        case .missingOnLeft: return "Missing on left"
        case .differentDates: return "Different dates or sizes"
        }
    }
}
