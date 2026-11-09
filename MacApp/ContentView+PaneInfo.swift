import SwiftUI
import Design
import Dashboard
import FileExplorer
import Sync

/// Each file pane's Info. The window has none of its own: the picture and details of what a pane has
/// selected sit in a column at the pane's right edge, or in a drawer over the pane when it is too
/// narrow for one (`PaneInfo`). Each pane remembers whether its Info is open.
extension ContentView {

    // MARK: Which switch

    /// The key this pane's remembered presentation is filed under.
    private func paneInfoMemoryKey(isLeft: Bool) -> String {
        layoutMode == .compare ? (isLeft ? "left" : "right") : "single"
    }

    /// Whether the pane on that side has its Info open. Compare has a switch per side, Browse its own,
    /// and every other single-source pane (Organize's folder pane, Edit's file pane) the rail's.
    func paneInfoIsOn(isLeft: Bool) -> Bool {
        if layoutMode == .compare { return isLeft ? paneInfoLeftOn : paneInfoRightOn }
        return selectedWorkspace == .browse ? paneInfoBrowseOn : paneInfoRailOn
    }

    /// Whether that pane's Info is drawn: on, and not held away by Ask Claude's fold of the pane.
    func paneInfoShows(isLeft: Bool) -> Bool {
        paneInfoIsOn(isLeft: isLeft) && !(isLeft && pinFoldHoldsInfo)
    }

    func setPaneInfo(isLeft: Bool, _ on: Bool) {
        withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
            // Asked for while Ask Claude's column folds Organize's or Edit's pane: the pane opens,
            // as it does for its own button, and Info shows in it.
            if on, isLeft, pinFoldHoldsInfo { askClaudeReleasePinFold() }
            if layoutMode == .compare {
                if isLeft { paneInfoLeftOn = on } else { paneInfoRightOn = on }
            } else if selectedWorkspace == .browse {
                paneInfoBrowseOn = on
            } else {
                paneInfoRailOn = on
            }
        }
    }

    func paneInfoBinding(isLeft: Bool) -> Binding<Bool> {
        Binding(get: { paneInfoShows(isLeft: isLeft) }, set: { setPaneInfo(isLeft: isLeft, $0) })
    }

    /// Whether the pane on that side is on screen: not when the workspace's panes are folded away
    /// (Edit starts so), nor the right pane outside Compare.
    func paneIsOnScreen(isLeft: Bool) -> Bool {
        guard contentLayout.drawsAPaneList, !panesHiddenForCurrentTab else { return false }
        return isLeft || layoutMode == .compare
    }

    /// Organize's folder pane is folded to its spine by hand (the stored fold). Its Info is still
    /// reachable, as a drawer from the spine over the lens, so ⌘I and Get Info keep working there.
    /// Not for the fold Ask Claude's column makes: a drawer then would cover the To File it folded
    /// the pane to make room for.
    var organizeSpineHoldsInfo: Bool {
        selectedWorkspace == .filing && layoutMode == .singleSource && panesStoredHiddenForCurrentTab
    }

    /// Organize's folder pane or Edit's file pane is folded only for Ask Claude's column (computed,
    /// never stored). Asking for its Info opens the pane, which ends that fold, and Info shows in it
    /// (`setPaneInfo`).
    var pinFoldHoldsInfo: Bool {
        Self.pinFoldHoldsInfo(workspace: selectedWorkspace, drawnHidden: panesHiddenForCurrentTab,
                              storedHidden: panesStoredHiddenForCurrentTab)
    }

    /// The rule: Organize or Edit, with the pane drawn folded though the person left it open. Edit's
    /// pane folded by hand stays as it is, and its Info unavailable, as without the column.
    static func pinFoldHoldsInfo(workspace: Workspace, drawnHidden: Bool, storedHidden: Bool) -> Bool {
        (workspace == .filing || workspace == .editor) && drawnHidden && !storedHidden
    }

    /// Whether Info can be shown for the pane on that side right now.
    func paneInfoAvailable(isLeft: Bool) -> Bool {
        paneIsOnScreen(isLeft: isLeft) || (isLeft && (organizeSpineHoldsInfo || pinFoldHoldsInfo))
    }

    /// What a pane header needs to draw its Info button; nil where the pane has none (Edit with its
    /// file pane hidden, a folded Organize pane, which has the spine's button instead).
    func paneInfoControl(isLeft: Bool) -> PaneInfoControl? {
        guard paneIsOnScreen(isLeft: isLeft) else { return nil }
        return PaneInfoControl(isOn: paneInfoIsOn(isLeft: isLeft), toggle: { setPaneInfo(isLeft: isLeft, !paneInfoIsOn(isLeft: isLeft)) })
    }

    /// ⌘I's binding: the pane you last used, nil when no pane can show Info.
    var shortcutPaneInfo: Binding<Bool>? {
        let isLeft = shortcutTabTargetIsLeft
        guard paneInfoAvailable(isLeft: isLeft) else { return nil }
        return paneInfoBinding(isLeft: isLeft)
    }

    /// Why no pane can show Info, as Ask Claude tells Claude when it asks for it. Edit with its file
    /// pane hidden is the one workspace that gets here in practice.
    var paneInfoUnavailableSentence: String {
        selectedWorkspace == .editor
            ? "Info isn’t available here: Edit’s file pane is hidden."
            : "Info isn’t available here: no file pane is on screen."
    }

    // MARK: Get Info

    /// Which pane holds `path`: the left, unless Compare's right pane's tree has it, or it lies under
    /// the right pane's root. `inspectorPreview`'s rule, so the picture and the pane agree.
    func paneInfoTargetIsLeft(for path: String) -> Bool {
        guard layoutMode == .compare else { return true }
        if !syncManager.leftNodes(for: [path]).isEmpty { return true }
        if !syncManager.rightNodes(for: [path]).isEmpty { return false }
        let root = currentRightPath
        let underRight = !root.isEmpty && (path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/"))
        return !underRight
    }

    /// Opens Info in the pane that holds `path`, for a Get Info on a row (a differences row too: it
    /// opens the pane on its side). Nothing opens where the pane is not on screen, as in Edit with
    /// its file pane hidden, whose Text Files rows have no Get Info.
    func openPaneInfo(for path: String) {
        let isLeft = paneInfoTargetIsLeft(for: path)
        guard paneInfoAvailable(isLeft: isLeft) else { return }
        setPaneInfo(isLeft: isLeft, true)
    }

    /// This pane's Get Info target, while the pane still holds it.
    private func paneInfoOverridePath(isLeft: Bool) -> String? {
        guard let path = infoTargets.path(isLeft: isLeft), paneInfoTargetIsLeft(for: path) == isLeft else { return nil }
        return path
    }

    /// The one file this pane's Info previews: a Get Info target first, else the one file selected in
    /// this pane. Never the document Edit has open beside it.
    private func paneInfoPreviewTarget(isLeft: Bool) -> (node: FileNode, isLeft: Bool)? {
        guard let target = Self.inspectorPreview(
            infoPath: paneInfoOverridePath(isLeft: isLeft), infoNode: infoTargets.node(isLeft: isLeft), followsLeft: isLeft,
            selectedLeft: syncManager.selectedLeftPaths, selectedRight: syncManager.selectedRightPaths,
            leftNodes: { syncManager.leftNodes(for: $0) }, rightNodes: { syncManager.rightNodes(for: $0) },
            rightRoot: currentRightPath)
        else { return nil }
        if selectedWorkspace == .editor, target.node.id == editorOpenPath { return nil }
        return target
    }

    // MARK: The panel

    enum PaneInfoKind { case slot, drawer, spineDrawer }

    /// The Info panel for one pane: a header with a close button, then the preview over the details,
    /// scoped to that pane alone (`DetailsSidebar.ownPaneOnly`).
    func paneInfoPanel(isLeft: Bool, kind: PaneInfoKind) -> some View {
        let previewTarget = paneInfoPreviewTarget(isLeft: isLeft)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Info").scaledFont(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                CloseButton { setPaneInfo(isLeft: isLeft, false) }
                    .help("Hide Info")
                    .accessibilityLabel("Hide Info")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            DetailsSidebar(
                syncManager: syncManager, leftPath: currentLeftPath, rightPath: currentRightPath,
                overridePath: paneInfoOverridePath(isLeft: isLeft),
                singleSource: layoutMode == .singleSource, cloudCoverage: settings.cloudCoverage,
                // The app answers what the editor opens: `EditableText.opensInEdit` is the row
                // menu's own gate, so Info cannot disagree with the menu about a file.
                editorHandOff: EditorHandOff(isOffered: { EditableText.opensInEdit(path: $0) },
                                             open: { handOffToEditor($0) }),
                // The picture over the details, at the height last dragged to.
                previewFraction: $inspectorPreviewFraction,
                preview: previewTarget.map { target in
                    AnyView(InspectorFilePreview(
                        node: target.node,
                        paneToken: PaneToken(isLeft: target.isLeft, isSingleSource: layoutMode == .singleSource),
                        // The panel is in the pane, so the pane is on screen to watch a download.
                        paneWatches: true,
                        downloads: inspectorDownloads))
                },
                previewPath: previewTarget?.node.id,
                followsRight: !isLeft,
                ownPaneOnly: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Info")
        .modifier(PaneInfoKindFrame(kind: kind))
    }

    /// The panel's frame by kind: a column's fixed width, or a drawer's in the pane that holds it.
    private struct PaneInfoKindFrame: ViewModifier {
        let kind: PaneInfoKind
        func body(content: Content) -> some View {
            switch kind {
            case .slot: content.frame(width: PaneInfo.slotWidth)
            case .drawer, .spineDrawer: content
            }
        }
    }

    // MARK: Where it sits

    /// Wraps a pane's file list (the whole chain, key handlers and action bar included) so Info sits
    /// beside it as a column, or over it as a drawer. The list stays where it is in the tree whether
    /// Info is open or not, so opening Info never rebuilds it.
    ///
    /// The slot is a sibling of the chain, not inside it: Space's Quick Look and the action bar's
    /// centring belong to the list alone, so a Space typed in Info is not Quick Look and the bar does
    /// not sit over Info. The pane's width is read here, synchronously, by `GeometryReader`, as the
    /// pane's columns read theirs.
    @ViewBuilder
    func paneInfoHost<Content: View>(isLeft: Bool, @ViewBuilder content: () -> Content) -> some View {
        let list = content()
        return GeometryReader { geo in
            let key = paneInfoMemoryKey(isLeft: isLeft)
            let on = paneIsOnScreen(isLeft: isLeft) && paneInfoIsOn(isLeft: isLeft)
            let mode = PaneInfo.presentation(isOn: on, paneWidth: geo.size.width, previous: paneInfoMemory[key])
            HStack(spacing: 0) {
                list
                if mode == .slot {
                    paneInfoPanel(isLeft: isLeft, kind: .slot)
                        .paneCardIfNeeded(surfaceStyle, level: glassLevel, accentBorder: paneCardAccent(isLeft: isLeft))
                        .unifiedSeam(surfaceStyle, edge: .leading)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .trailing) {
                if mode == .drawer {
                    paneInfoDrawer(isLeft: isLeft, width: PaneInfo.drawerWidth(paneWidth: geo.size.width), edge: .trailing)
                }
            }
            .onChange(of: mode, initial: true) { _, new in paneInfoMemory[key] = new }
        }
    }

    /// The drawer: the panel on a card over the pane's edge, with a shadow and a close button. The
    /// pane under it stays live. Esc closes it when the keyboard is inside, and VoiceOver treats it
    /// as modal, so the covered list is not read.
    func paneInfoDrawer(isLeft: Bool, width: CGFloat, edge: Edge) -> some View {
        paneInfoPanel(isLeft: isLeft, kind: edge == .trailing ? .drawer : .spineDrawer)
            .frame(width: width)
            .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
            .shadow(color: .black.opacity(0.22), radius: 14, x: edge == .trailing ? -4 : 4, y: 0)
            .accessibilityAddTraits(.isModal)
            .onExitCommand { setPaneInfo(isLeft: isLeft, false) }
            .transition(.move(edge: edge).combined(with: .opacity))
    }

    /// Organize's folded folder pane has no pane to hold Info, so its drawer comes out of the spine
    /// over the lens's leading edge.
    @ViewBuilder
    var organizeSpineInfoDrawer: some View {
        if organizeSpineHoldsInfo && paneInfoRailOn {
            paneInfoDrawer(isLeft: true, width: PaneInfo.slotWidth, edge: .leading)
        }
    }
}

/// Get Info's targets, one per pane. A Get Info on a row aims the Info of the pane that holds the row,
/// and only that pane's selection or source (or a workspace switch) retires it, so a click in the
/// other pane never takes it away.
struct PaneInfoTargets {
    struct Target {
        let path: String
        /// The target as a node of its own, read off the disk after Get Info, for a path no pane's
        /// tree holds.
        var node: FileNode?
    }

    private(set) var left: Target?
    private(set) var right: Target?

    func path(isLeft: Bool) -> String? { (isLeft ? left : right)?.path }
    func node(isLeft: Bool) -> FileNode? { (isLeft ? left : right)?.node }

    /// Get Info on `path`, in that pane.
    mutating func aim(_ path: String, isLeft: Bool) { put(Target(path: path), isLeft: isLeft) }

    /// The node read for `path`, kept only while `path` is still that pane's target.
    mutating func found(_ node: FileNode?, for path: String, isLeft: Bool) {
        guard self.path(isLeft: isLeft) == path else { return }
        put(Target(path: path, node: node), isLeft: isLeft)
    }

    mutating func clear(isLeft: Bool) { put(nil, isLeft: isLeft) }

    mutating func clearAll() {
        left = nil
        right = nil
    }

    private mutating func put(_ target: Target?, isLeft: Bool) {
        if isLeft { left = target } else { right = target }
    }
}
