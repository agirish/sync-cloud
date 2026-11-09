import SwiftUI
import AppKit
import Sync
import Dashboard
import FileExplorer
import Design

/// The window toolbar. An extension, not a separate View, because it reads ContentView's
/// selection, provider state and action handler directly; the members it touches are internal
/// rather than private so this file can live outside ContentView.swift.
extension ContentView {

    /// Which pane holds a selection, and nothing more. The fallback inside
    /// `PaneLogic.focusedPaneIsLeft`; read `focusedPane` for "which pane is the user working in".
    var activePane: PaneLogic.ActivePane? {
        PaneLogic.activePane(
            leftSelection: syncManager.selectedLeftPaths,
            rightSelection: syncManager.selectedRightPaths
        )
    }

    /// The pane the user is working in: what the action bar, the lens scans, the pane-scoped chords
    /// and the folder sidebar act on, and what the accent border draws.
    ///
    /// Never nil, unlike `activePane`: `focusedPaneIsLeft` floors at the left pane. That floor lets
    /// the border be a resting indicator; on a cold window the answer is "left", not "none".
    var focusedPane: PaneLogic.ActivePane {
        PaneLogic.focusedPaneIsLeft(isSingleSource: layoutMode == .singleSource,
                                    focusedSide: syncManager.focusedPaneSide,
                                    activePane: activePane) ? .left : .right
    }

    /// The selected nodes in whichever pane is active, resolved through the sync manager's cached
    /// path→node index, so O(selection) and cheap to read; no tree walk gates the action bar.
    var activeSelectionNodes: [FileNode] {
        switch focusedPane {
        case .left:
            return syncManager.leftNodes(for: syncManager.selectedLeftPaths)
        case .right:
            return syncManager.rightNodes(for: syncManager.selectedRightPaths)
        }
    }

    // MARK: - Contextual pane action bar

    /// Whether the selection-driven action bar could show on this pane: the compare layout, and the
    /// focused side. Only a coarse gate: the caller also requires a non-empty resolved selection
    /// (`barSelectionNodes`), so a stale path that no longer resolves keeps the bar hidden, and the
    /// bar's visibility and its "N selected" count come from one resolve. Only the comparison panes
    /// have an "other pane" to copy or move to, so it never shows on the single-source rail.
    func paneActionBarSideActive(isLeft: Bool) -> Bool {
        guard layoutMode == .compare else { return false }
        let side: PaneLogic.ActivePane = isLeft ? .left : .right
        // **The focused pane, not the pane holding the selection.** They agree after a row click (a
        // selection write moves focus and clears the other side), and differ only when a click moved
        // focus without changing a selection: a background click, or a press on the other pane's
        // chrome. The bar follows focus so the accent border and "Copy to …" never name two panes.
        return focusedPane == side
    }

    /// Whether this pane wears the full-strength accent: its selected rows, and the live chip in its
    /// tab strip. Both read `PaneSelectionWash` and must name the same pane, so the predicate is
    /// written once here.
    ///
    /// The single-source rail has no sibling, so it is always its own active pane;
    /// `paneActionBarSideActive` answers false for every layout but Compare.
    func paneWearsActiveAccent(isLeft: Bool) -> Bool {
        layoutMode == .singleSource || paneActionBarSideActive(isLeft: isLeft)
    }

    /// The nodes the action bar acts on, resolved once so `paneColumn` passes the same array to the
    /// bar's visibility gate and its contents. Empty when this side isn't the active pane, so the
    /// inactive column resolves nothing.
    func barSelectionNodes(isLeft: Bool) -> [FileNode] {
        paneActionBarSideActive(isLeft: isLeft) ? activeSelectionNodes : []
    }

    /// What this pane has selected, whether or not it is the active one.
    ///
    /// **Not `barSelectionNodes(isLeft:)`.** That one goes through `paneActionBarSideActive`, which
    /// is empty on Compare's inactive side and for every pane in a single-source workspace. A
    /// per-pane control fed from it would be dead in Browse and on the Organize rail, and on
    /// Compare's inactive side would report the other pane's selection as its own once focus moved.
    ///
    /// Cheap: `leftNodes(for:)`/`rightNodes(for:)` look paths up in a cached path→node index rebuilt
    /// only when the published tree version changes, so this is O(selection).
    func paneSelectionNodes(isLeft: Bool) -> [FileNode] {
        isLeft ? syncManager.leftNodes(for: syncManager.selectedLeftPaths)
               : syncManager.rightNodes(for: syncManager.selectedRightPaths)
    }

    /// The selection-driven file-action bar, docked at the foot of the active pane: Compare, Copy,
    /// Move and Delete, scoped to and naming the pane whose selection they act on. The caller
    /// resolves `selectionNodes` once, so the tree isn't walked twice per render.
    ///
    /// The bar lives in `FileExplorer` so its layout can be rendered and asserted; this supplies the
    /// strings and handlers, the only parts that need the app's state.
    @ViewBuilder
    func paneActionBar(isLeft: Bool, selectionNodes: [FileNode]) -> some View {
        let copyTarget = PaneLogic.copyTargetName(activePane: focusedPane, paneNames: paneNames)
        let actionSymbols = PaneLogic.actionBarSymbols(activePane: focusedPane)
        // Asked once: the button's presence and its action are the same question, and the handler
        // acts on this value rather than re-reading the selection.
        let compareOffer = PaneLogic.compareOffer(for: selectionNodes)
        PaneActionBar(
            summaryText: SelectionSummary.text(for: selectionNodes),
            showsCompare: compareOffer != nil,
            compareTitle: compareOffer?.buttonTitle ?? "Compare",
            copyTitle: copyTarget.map { "Copy to \($0)" } ?? "Copy",
            moveTitle: copyTarget.map { "Move to \($0)" } ?? "Move",
            copySymbol: actionSymbols.copy,
            moveSymbol: actionSymbols.move,
            // The titles name a side. The rule for which folder (each item's own path, re-rooted)
            // appears nowhere else in the window, and without it a transfer into an
            // already-matching location looks like a dead click.
            transferHelp: copyTarget.map {
                "Puts each item where its counterpart belongs in \($0), creating folders as needed"
            },
            onCompare: {
                switch compareOffer {
                case .folderScan(let folder):
                    // The comparison toolbar's "Compare this folder": both panes are visible here,
                    // so the link toggle means what it says and is honored.
                    actionHandler?.focusFolder(folder, isLeft: isLeft,
                                               leftProviderId: leftProviderId, rightProviderId: rightProviderId,
                                               suppressLinkedNavigation: false)
                case .armPick(let file):
                    // One file: arm it and let the next click name the counterpart, the only route
                    // to the other pane, since a selection there would clear this one.
                    armComparePick(file, isLeft: isLeft)
                case .filePair(let first, let second):
                    // Same pane, so the pair leads with the first file. `PaneComparePairMenu.pair`
                    // owns that ordering and gets the same two arguments the row menu passes.
                    compareFilePairAction(first, second,
                                          secondIsInOtherPane: false, clickedPaneIsLeft: isLeft)
                case nil:
                    break
                }
            },
            onCopy: {
                actionHandler?.copyItems(selectionNodes, fromLeft: isLeft,
                                         leftProviderId: leftProviderId, rightProviderId: rightProviderId)
            },
            onMove: {
                Task {
                    _ = await actionHandler?.moveItems(selectionNodes, fromLeft: isLeft,
                                                       leftProviderId: leftProviderId, rightProviderId: rightProviderId)
                }
            },
            onDelete: { actionHandler?.confirmDelete(selectionNodes) },
            onClear: { clearSelection(isLeft: isLeft) }
        )
    }

    /// The workspace bar: one flat row of every workspace in the toolbar's leading region, which
    /// `.hiddenTitleBar` leaves empty save for the traffic lights, so it costs no content height.
    ///
    /// Its width has to fit the window's `minWidth`, or macOS folds the bar behind an overflow
    /// chevron. ``WorkspaceBarMetrics`` handles that: below the width where every label fits, all
    /// segments shed their labels at once and the glyphs carry the bar.
    var workspaceBar: some View {
        // Custom buttons rather than `Picker(.segmented)`: the native control renders neutral
        // inside a macOS 26 glass toolbar group and ignores `.tint`, so the selected segment could
        // never carry the app accent. These draw their own accent fill. The binding's setter
        // still runs (it opens the source rail).
        let selection = workspaceSelection
        // The deepened accent, which keeps the white label legible: the raw accent leaves white
        // text at about 2.1–2.7:1 on Amber, Cyan and Green.
        let accentFill = glassHue.accentFillColor
        let onAccent = glassHue.onAccentLabelColor
        let style = toolbarStyles.workspace
        return HStack(spacing: WorkspaceBarMetrics.segmentGap) {
            // No group rule between segments. `WorkspaceBarMetrics` charges nothing for a
            // separator, so one drawn here would be 13pt the width arithmetic can't see, and
            // under-measuring folds the toolbar behind the overflow chevron.
            ForEach(Array(Workspace.allCases.enumerated()), id: \.element) { index, workspace in
                workspaceSegment(workspace, ordinal: index + 1, selection: selection, style: style,
                                 accentFill: accentFill, onAccent: onAccent)
            }
        }
        // Frosted and Clear: one glass lens for the bar, stretching between segments. Here, inside
        // the padding, so it sits on the bar's ground rather than under it. Solid draws the sliding
        // capsule below.
        .selectionLensHost(Self.workspaceLensChannel, selected: selection.wrappedValue,
                           style: .fill(.capsule, color: accentFill))
        // The travel itself. `matchedGeometryEffect` only says the two frames are the same view;
        // without an animation the change still arrives instantly. Scoped by `value:` to the
        // selection, so resizing the bar (which can change every segment's width) doesn't slide.
        //
        // Reduce Motion skips the travel: the accent fill still marks the selected segment, it
        // just appears there. Drop what moves, keep what colours, as `HoverAffordanceMetrics` does.
        .designAnimation(.easeOut(duration: 0.22), value: selection.wrappedValue)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
        // Inset the segments in an outer capsule so the selected pill floats with a gap on every
        // side instead of filling the control edge to edge.
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .fixedSize()
        // **The destination picker owns the window while it is up, but not the toolbar.** The
        // picker is a content overlay and this is a titlebar accessory, so without this a click
        // here would switch workspace under a pending pick. `toggleCommandPalette` guards the
        // palette; this guards the bar.
        .disabled(pendingDestination != nil)
    }

    @ViewBuilder
    private func workspaceSegment(
        _ workspace: Workspace,
        ordinal: Int,
        selection: Binding<Workspace>,
        style: WorkspaceBarStyle,
        accentFill: Color,
        onAccent: Color
    ) -> some View {
        let isSelected = selection.wrappedValue == workspace
        // The chord is the segment's 1-based position, the same enumeration `WorkspaceCommands`
        // binds its chords from, so the badge and the key equivalent can't disagree. Empty past
        // nine, which reads as "no badge", as in the menu. See `AppChord.workspace(_:)`.
        let chord = AppChord.workspace(ordinal)?.display ?? ""
        Button {
            selection.wrappedValue = workspace
        } label: {
            HStack(spacing: 6) {
                Image(systemName: workspace.symbol)
                    .font(.system(size: 12, weight: .medium))
                    // Framed, so a segment's size doesn't depend on which symbol is in it: the
                    // glyphs render at different sizes (see `WorkspaceBarMetrics.glyphSide`). Same
                    // idiom as `PaneTabStripLadder.markSide`.
                    .frame(width: WorkspaceBarMetrics.glyphSide,
                           height: WorkspaceBarMetrics.glyphSide)
                if style == .full {
                    Text(workspace.title)
                        .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .medium))
                }
            }
            // White on Solid's fill and on dark glass; black on light glass (`selectionLensLabelInk`).
            .selectionLensLabelInk(isSelected: isSelected, onFill: onAccent, unselected: Color.secondary)
            .padding(.horizontal, style == .full ? 12 : 10)
            .padding(.vertical, 4)
            // One capsule that moves, not one per segment that blinks. Drawn only under the
            // selected segment and tagged into `workspaceMarker`, so SwiftUI treats the outgoing
            // and incoming fills as the same view and the pill slides along the bar. A conditional
            // `.background`, not `in: Capsule()`, because a shape style has no geometry to match.
            .background {
                if isSelected {
                    SelectionLensTodayMarker {
                        Capsule()
                            .fill(accentFill)
                            .matchedGeometryEffect(id: Self.workspaceMarkerID, in: workspaceMarker)
                    }
                }
            }
            .selectionLensStop(Self.workspaceLensChannel, id: workspace)
            .contentShape(Capsule())
        }
        // The selected segment already carries the accent fill, so it takes the ring; unselected
        // ones wash the capsule they would fill if clicked. `.filled` for the chosen segment at
        // Solid; under the lens, `.segment` (`SelectionLens`).
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: accentFill)
        .shortcutKeycap(chord)
        // Once the label is shed the glyph alone names this workspace, so the name survives in the
        // tooltip for a mouse and the accessibility label otherwise.
        .help(ShortcutHint.tooltip(workspace.title, chord))
        .accessibilityLabel(workspace.title)
        // These Buttons stand in for a `Picker(.segmented)`, so they restate the selected-state
        // semantics the Picker gave VoiceOver for free.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The `matchedGeometryEffect` id for the selected segment's accent capsule. One marker, one id:
    /// a per-segment id would give each its own identity and defeat the effect.
    static let workspaceMarkerID = "workspace.selection.marker"

    /// The bar's selection lens in Frosted and Clear — see `SelectionLens`.
    static let workspaceLensChannel = SelectionLensChannel("workspace.bar")

    /// Each segment's rendered label width, at the app's current text scale.
    ///
    /// Measured, not tabulated: a constant would be right at only one Settings ▸ Text size, and
    /// overflow here doesn't truncate, it hides the whole control behind macOS's overflow chevron.
    /// Semibold because that is the selected segment's weight, and the widest.
    static func workspaceLabelWidths(scale: CGFloat) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        return Workspace.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// Closed or open, from the pair the row resolved. The open case takes its width from
    /// `styles(...)`, never from the field itself, because the field spends the same row width the
    /// workspace bar does.
    var goToFieldMode: GoToFieldBar.Mode {
        if showCommandPalette, let layout = toolbarStyles.field { return .open(layout) }
        return .closed(toolbarStyles.search)
    }

    /// The window toolbar: the window-level controls only. The sidebar toggle, the workspace bar, a
    /// long run's capsule, ⌘K, Ask Claude and the utilities (Settings, Activity, Info). Everything
    /// else lives where it acts: Scan in each pane header, Find Duplicates in its lens, and the file
    /// actions in the panes' action bar.
    @ToolbarContentBuilder
    var mainToolbar: some ToolbarContent {
        // The sidebar toggle, mirroring the Info toggle at the far end: `sidebar.left` against
        // `sidebar.right`, ⌃⌘S against ⌘I, the accent tint while open, the keycap on the label
        // (a toolbar item's own bounds are AppKit's), and the same silence during a pick.
        //
        // Unlike Info it is not always available (`FolderSidebarModel.appliesTo`: a workspace with
        // no column, or panes collapsed behind a pick). Disabled rather than hidden, so the toolbar
        // doesn't reflow as you switch workspace. The tooltip says why it is greyed, since the two
        // reasons have different remedies (`FolderSidebarModel.unavailableReason`).
        ToolbarItem(placement: .navigation) {
            let available = folderSidebarIsAvailable
            let showing = folderSidebarIsShowing
            Button {
                withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
                    setFolderSidebarVisible(!showing)
                }
            } label: {
                Label("Sidebar", systemImage: "sidebar.left")
                    .foregroundStyle(showing ? AnyShapeStyle(glassHue.accentColor)
                                             : AnyShapeStyle(.primary))
                    .shortcutKeycap(AppChord.folderSidebar.display)
            }
            .help(available
                  ? ShortcutHint.tooltip(showing ? "Hide the sidebar" : "Show the sidebar",
                                         AppChord.folderSidebar.display)
                  // No chord here: naming a keystroke that can't fire is the same failure as
                  // publishing a chord for a column that can't appear.
                  : (FolderSidebarModel.unavailableReason(
                        workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar,
                        panesCollapsed: panesHiddenForCurrentTab,
                        outlivesCollapse: folderSidebarOutlivesCollapse) ?? ""))
            .accessibilityLabel(showing ? "Hide sidebar" : "Show sidebar")
            // Both halves of one control agree, as with Info below: the menu item is disabled
            // wherever the column can't be drawn and silenced during a pick, so the button is too,
            // or a mouse user could reach what a keyboard user can't.
            .disabled(!available || pendingDestination != nil)
        }

        // `.navigation` puts the bar right after the traffic lights. No window title competes for
        // the space; the window is `.hiddenTitleBar`.
        ToolbarItem(placement: .navigation) {
            workspaceBar
        }

        // A leading flexible spacer keeps the utility pill trailing; macOS 26's grouped toolbar
        // doesn't trail `.primaryAction` on its own.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        // A long run's progress, in the toolbar's middle: the file operation on `activeProgress`,
        // or a PDF tool or Save as PDF run from a pane. Present only while something runs, and
        // always seated: its rung (the full capsule, or the ring with its stop button) comes from
        // the same width ladder as the workspace bar and the ⌘K pill, which charges it first. An
        // item that overflowed would fold into the chevron, and a run nobody can see or stop is
        // what this must never become. Also shown while a run's ending is the capsule's (with no
        // run left it holds the message) and while Activity's popover hangs from it.
        if runCapsuleShowing || capsuleMessage != nil || activityPopoverStyles != nil {
            ToolbarItem(placement: .principal) {
                RunCapsuleHost(activeProgress: syncManager.activeProgress,
                               activeProgressStartedAt: syncManager.activeProgressStartedAt,
                               center: .shared, runWriteLock: runWriteLockReason,
                               scans: ActivityScanRows.rows(syncManager) { ActivityCenter.shared.doors.showScan($0) },
                               message: capsuleMessage,
                               style: toolbarStyles.run ?? .ring)
                    // Where a message's ring takes off for Activity (`retireResultMessage`).
                    .background(CapsuleFlightAnchor(end: .capsule))
            }
        }

        // ⌘K, wearing its own key. Trailing, where every Mac app puts a toolbar search, and its own
        // item rather than a member of the utility group: those are glyph buttons and this is a
        // field-shaped surface, which among them would read as a button that had grown.
        ToolbarItem(placement: .primaryAction) {
            GoToFieldHost(
                query: goToQuery,
                onQuery: { palettePanel.setQuery($0) },
                mode: goToFieldMode,
                chord: AppChord.commandPalette.display,
                focusToken: goToFocusToken,
                accent: glassHue.accentColor,
                onOpen: { toggleCommandPalette() },
                onMove: { palettePanel.move(by: $0) },
                onSubmit: { palettePanel.runSelection() },
                onCancel: { palettePanel.dismiss() })
            // `toggleCommandPalette` refuses while a pick is pending, so the pill is dimmed too
            // rather than silently doing nothing; the menu item dims itself for the same reason.
            .disabled(pendingDestination != nil)
            // 120ms, on the width rather than a transition: the pill grows into the field and back,
            // so the row reads as one control changing size, not two swapping places.
            .designAnimation(.easeOut(duration: 0.12), value: showCommandPalette)
        }

        // Ask Claude: its own glass circle between ⌘K and the utility pill, accent-tinted while
        // the panel is open, like Info. The fixed spacers make it its own capsule; otherwise
        // macOS 26 draws adjacent items in one shared glass group, inside the utility pill.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }
        ToolbarItem(placement: .primaryAction) {
            AskClaudeToolbarButton(visibility: askClaudeHolder.visibility, accent: glassHue.accentColor) { toggleAskClaude() }
                .disabled(askClaudeStateBusy != nil)
        }
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { showSettings = true }) {
                Label("Settings", systemImage: "gear")
                    // On the label, not the Button: a toolbar item's own bounds are AppKit's, and an
                    // overlay hung outside the SwiftUI content gets clipped. Centred because the
                    // keycap is wider than the gear.
                    .shortcutKeycap(AppChord.settings.display)
            }
            .help(ShortcutHint.tooltip("Settings", AppChord.settings.display))
            // Disabled during a destination pick, like the bar and the ⌘K pill. ⌘, is registered in
            // the App scene and can't be suspended from this window, so `ContentView`'s
            // `onChange(of: showSettings)` refuses the latch itself, for every caller. An enabled
            // button would then do nothing, and the toolbar is the one surface the picker's scrim
            // does not cover.
            .disabled(pendingDestination != nil)

            // Activity: Now, History and Log in one window. It wears a dot while an unseen problem
            // waits there, and then opens on Now.
            ActivityToolbarButton(center: .shared) {
                _ = ActivityCenter.shared.tabForOpening()
                ActivityCenter.shared.markSeen()
                openWindow(id: ActivityCenter.windowID)
            }
        }
    }
}

/// The toolbar's Activity button, with a dot while a problem waits unseen. Observes
/// ``ActivityCenter`` itself, so the window does not.
struct ActivityToolbarButton: View {
    @ObservedObject var center: ActivityCenter
    let action: () -> Void
    /// A capsule message arriving (`CapsuleFlight`): the button bumps and glows once.
    @ObservedObject private var landing = CapsuleFlightLanding.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    /// One landing: the bump, and a glow in the window's hue. Under Reduce Motion the glow alone,
    /// since it is a fade, not motion.
    struct Landing {
        var scale: CGFloat = 1
        var glow: Double = 0
    }

    var body: some View {
        Button(action: action) {
            Label("Activity", systemImage: "list.bullet.rectangle")
                .overlay(alignment: .topTrailing) {
                    // Shown as a capsule problem's ring lands, popping in with it.
                    if center.showsDot {
                        Circle()
                            .fill(SemanticColor.error)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -2)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                .designAnimation(.spring(response: 0.28, dampingFraction: 0.55), value: center.showsDot)
                .shortcutKeycap(AppChord.activityLog.display)
                .background(CapsuleFlightAnchor(end: .activity))
                .keyframeAnimator(initialValue: Landing(), trigger: landing.arrivals) { label, value in
                    label
                        .scaleEffect(reduceMotion ? 1 : value.scale)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control)
                                .fill((LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor.opacity(value.glow))
                                .padding(-5)
                        )
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1.18, duration: ProgressCapsuleFlight.landDuration * 0.35)
                        CubicKeyframe(0.97, duration: ProgressCapsuleFlight.landDuration * 0.35)
                        CubicKeyframe(1, duration: ProgressCapsuleFlight.landDuration * 0.3)
                    }
                    KeyframeTrack(\.glow) {
                        LinearKeyframe(0.24, duration: 0.16)
                        LinearKeyframe(0, duration: 0.5)
                    }
                }
        }
        .help(ShortcutHint.tooltip(center.showsDot ? "Activity — a problem you haven’t seen" : "Activity",
                                   AppChord.activityLog.display))
        .accessibilityLabel("Activity")
        .accessibilityValue(center.showsDot ? "A problem you haven’t seen" : "")
    }
}
