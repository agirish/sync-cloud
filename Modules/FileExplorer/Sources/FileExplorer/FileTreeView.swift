import AppKit
import Design
import Events
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

    /// Paths ignored in the diff (user can toggle per path).
    public let ignoredPaths: Set<String>

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

    public init(tree: [FileNode], otherTree: [FileNode], isLoading: Bool, currentPath: String, selection: Binding<Set<String>>, otherSelection: Set<String>, isLeft: Bool, delegate: FileActionDelegate, ignoredPaths: Set<String>, diffIndex: DiffStatusIndex = .empty, otherPaneName: String? = nil, rootPathIsValid: Bool = true, providerIsEnabled: Bool = true, hasOnlyHiddenEntries: Bool = false, rootPath: String? = nil, onOpenSettings: (() -> Void)? = nil) {
        self.tree = tree
        self.otherTree = otherTree
        self.isLoading = isLoading
        self.currentPath = currentPath
        self._selection = selection
        self.otherSelection = otherSelection
        self.isLeft = isLeft
        self.delegate = delegate
        self.ignoredPaths = ignoredPaths
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
        .onDeleteCommand {
            let selectedNodes = tree.findNodes(at: selection)
            if !selectedNodes.isEmpty {
                delegate.handleDelete(selectedNodes)
            }
        }
        .contextMenu { emptyAreaContextMenu }
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

    /// One tree row: content, its context menu, draggable payload, and (for directories) a drop
    /// target. Single-click selection is left entirely to the List; drilling into a folder is
    /// via the Compare button / context menu.
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
                ignoredPaths: ignoredPaths,
                otherPaneName: otherPaneName
            )
        }
        .draggable(makeDragPayload(for: node))
        .modifier(PaneDropTarget(
            targetDirectoryPath: node.isDirectory ? node.id : nil,
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
        Button(action: { delegate.handleRefresh() }) {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        Divider()
        Button(action: { delegate.handleCreateFolder(at: currentPath) }) {
            Label("New Folder", systemImage: "folder.badge.plus")
        }
        Button(action: { delegate.handlePasteToPath(currentPath) }) {
            Label("Paste here", systemImage: "doc.on.clipboard")
        }
        Divider()
        Button(action: { delegate.handleGetInfo(for: currentPath) }) {
            Label("Get Info", systemImage: "info.circle")
        }
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

/// Makes a directory row accept cross-pane drags, highlighting it only while a valid drop
/// hovers. Rows without a `targetDirectoryPath` (files) pass through untouched, so drops on
/// them fall to the pane background (= into the pane's current folder), like Finder.
private struct PaneDropTarget: ViewModifier {
    /// Absolute path of the directory this row represents, or nil when the row is a file.
    let targetDirectoryPath: String?
    let paneIsLeft: Bool
    let delegate: FileActionDelegate

    @ObservedObject private var dragSession = PaneDragSession.shared
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if let targetDirectoryPath {
            content
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(isTargeted && dropAllowed(into: targetDirectoryPath) ? 0.25 : 0))
                }
                .dropDestination(for: PaneDragPayload.self) { payloads, _ in
                    guard let payload = payloads.first else { return false }
                    return FileTreeView.performPaneDrop(payload, toPath: targetDirectoryPath, targetIsLeft: paneIsLeft, delegate: delegate)
                } isTargeted: { targeting in
                    isTargeted = targeting
                }
        } else {
            content
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
    let ignoredPaths: Set<String>
    let otherPaneName: String

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
            Button(action: { delegate.handleRefresh() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Divider()
            if count == 1, let singleNode = selectedNodes.first {
                Button(action: { delegate.handleGetInfo(for: singleNode.id) }) {
                    Label("Get Info", systemImage: "info.circle")
                }
                Divider()
                Button(action: { delegate.handleRename(singleNode) }) {
                    Label("Rename", systemImage: "pencil")
                }
                
                if singleNode.isDirectory {
                    Button(action: { delegate.handleCreateFolder(at: singleNode.id) }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
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
            
            Button(action: { delegate.handlePaste(node) }) {
                Label("Paste here", systemImage: "doc.on.clipboard")
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

    /// Shared formatters: rows render lazily but scroll fast, so allocating a formatter
    /// per row body would still churn.
    @MainActor private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
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
        return Self.sizeFormatter.string(fromByteCount: Int64(size))
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
                // (colors match DifferenceRow in the Differences pane).
                Image(systemName: Self.badgeSymbol(for: diffStatus))
                    .font(.subheadline)
                    .foregroundStyle(Self.badgeColor(for: diffStatus))
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

    static func badgeSymbol(for type: FileDifference.DifferenceType) -> String {
        DifferenceGlyph.symbol(for: type, filled: false)
    }

    static func badgeColor(for type: FileDifference.DifferenceType) -> Color {
        DifferenceGlyph.color(for: type)
    }

    static func badgeHelp(for type: FileDifference.DifferenceType) -> String {
        switch type {
        case .missingOnRight: return "Missing on right"
        case .missingOnLeft: return "Missing on left"
        case .differentDates: return "Different dates or sizes"
        }
    }
}
