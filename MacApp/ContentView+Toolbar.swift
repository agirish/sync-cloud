import SwiftUI
import AppKit
import Sync
import Dashboard
import FileExplorer
import Design

/// The window toolbar, extracted from ContentView.swift for size. An extension (not a
/// separate View) because the toolbar reads ContentView's selection/provider state and
/// action handler directly; the members it touches are internal rather than private so
/// this file can live outside ContentView.swift.
extension ContentView {

    /// **Which pane holds a selection**, and nothing more. Once the fallback inside
    /// `PaneLogic.focusedPaneIsLeft`; read `focusedPane` for "which pane is the user working in".
    var activePane: PaneLogic.ActivePane? {
        PaneLogic.activePane(
            leftSelection: syncManager.selectedLeftPaths,
            rightSelection: syncManager.selectedRightPaths
        )
    }

    /// **The pane the user is working in**, which is what the action bar, the lens scans, the
    /// pane-scoped chords and the folder sidebar all act on — and what the accent border draws.
    ///
    /// Never nil, unlike `activePane`: `focusedPaneIsLeft` floors at the left pane, so there is
    /// always a pane to name. That floor is why the border can be a resting indicator rather than
    /// something that appears and disappears — on a cold window the answer is "left", not "none".
    var focusedPane: PaneLogic.ActivePane {
        PaneLogic.focusedPaneIsLeft(isSingleSource: layoutMode == .singleSource,
                                    focusedSide: syncManager.focusedPaneSide,
                                    activePane: activePane) ? .left : .right
    }

    /// The selected nodes in whichever pane is active. Resolves paths via the sync manager's cached
    /// path→node index (O(selection)), so — unlike the old per-render tree walk — it's cheap to read
    /// and no longer gates the action bar's appearance on a ~40k-node traversal.
    var activeSelectionNodes: [FileNode] {
        switch focusedPane {
        case .left:
            return syncManager.leftNodes(for: syncManager.selectedLeftPaths)
        case .right:
            return syncManager.rightNodes(for: syncManager.selectedRightPaths)
        }
    }

    // MARK: - Contextual pane action bar

    /// Whether the selection-driven action bar could show on this pane: this is the compare layout
    /// and this is the active (selected) side. This is only a coarse gate — the caller still
    /// requires a non-empty *resolved* selection (`barSelectionNodes`) before showing the bar, so a
    /// stale selected path that no longer resolves to a node keeps the bar hidden (matching the old
    /// `!activeSelectionNodes.isEmpty` check). Keeping the node walk out of here means the bar's
    /// visibility and its "N selected" count come from a single resolve, not two. Only the
    /// comparison panes have an "other pane" to copy/move to, so it never shows on the single-source rail.
    func paneActionBarSideActive(isLeft: Bool) -> Bool {
        guard layoutMode == .compare else { return false }
        let side: PaneLogic.ActivePane = isLeft ? .left : .right
        // **The FOCUSED pane, not the pane holding the selection.** Those agree after a row click —
        // a selection write moves focus, and the one-pane-selected invariant clears the other side
        // — and they part company only when a click changed focus without changing a selection: a
        // background click (which clears both), or a press on the other pane's chrome. There the
        // bar leaves with the focus, which is the point: the accent border and the "Copy to …"
        // button must never name two different panes.
        return focusedPane == side
    }

    /// **Whether this pane wears the FULL-strength accent** — its selected rows, and the live chip
    /// in its tab strip. Both read `PaneSelectionWash` and both must name the same pane, so the
    /// predicate is written once here rather than at the two call sites that would otherwise have
    /// to keep agreeing.
    ///
    /// The single-source rail has no sibling to be subordinate to, so it is always its own active
    /// pane; `paneActionBarSideActive` answers false for every layout but Compare.
    func paneWearsActiveAccent(isLeft: Bool) -> Bool {
        layoutMode == .singleSource || paneActionBarSideActive(isLeft: isLeft)
    }

    /// The nodes the action bar acts on: resolved once here (a tree walk) so `paneColumn` can pass
    /// the same array to both the bar's visibility gate and its contents. Empty when this side
    /// isn't the active pane, so the inactive column never walks its tree.
    func barSelectionNodes(isLeft: Bool) -> [FileNode] {
        paneActionBarSideActive(isLeft: isLeft) ? activeSelectionNodes : []
    }

    /// What THIS pane has selected, whether or not it is the active one.
    ///
    /// **Not `barSelectionNodes(isLeft:)`, and the difference is not a nuance.** That one runs
    /// through `paneActionBarSideActive`, which opens `guard layoutMode == .compare` — so it is
    /// empty for the inactive side of Compare and empty for *every* pane in every single-source
    /// workspace. A per-pane control fed from it would be permanently dead in Browse and on the
    /// Organize rail, and on Compare's inactive side it would report the OTHER pane's selection as
    /// its own the moment focus moved. Both are the ambiguity a control living inside a pane's own
    /// header exists to avoid.
    ///
    /// Resolving both is cheap: `leftNodes(for:)`/`rightNodes(for:)` look paths up in a cached
    /// path→node index rebuilt only when the published tree version changes, so this is
    /// O(selection), not the per-render tree walk the comment above remembers.
    func paneSelectionNodes(isLeft: Bool) -> [FileNode] {
        isLeft ? syncManager.leftNodes(for: syncManager.selectedLeftPaths)
               : syncManager.rightNodes(for: syncManager.selectedRightPaths)
    }

    /// The selection-driven file-action bar, docked at the bottom of the active pane. These are the
    /// actions that used to sit in the titlebar (Compare / Copy / Move / Delete), now scoped to —
    /// and naming — the pane whose selection they act on. `selectionNodes` is resolved by the caller
    /// (once) rather than re-read here, so the tree isn't walked twice per render.
    ///
    /// The bar itself lives in `FileExplorer` so its layout can be rendered and asserted; this
    /// supplies the strings and the handlers, which are the only parts that need the app's state.
    @ViewBuilder
    func paneActionBar(isLeft: Bool, selectionNodes: [FileNode]) -> some View {
        let copyTarget = PaneLogic.copyTargetName(activePane: focusedPane, paneNames: paneNames)
        let actionSymbols = PaneLogic.actionBarSymbols(activePane: focusedPane)
        PaneActionBar(
            summaryText: SelectionSummary.text(for: selectionNodes),
            showsCompare: selectionNodes.count == 1 && selectionNodes[0].isDirectory,
            copyTitle: copyTarget.map { "Copy to \($0)" } ?? "Copy",
            moveTitle: copyTarget.map { "Move to \($0)" } ?? "Move",
            copySymbol: actionSymbols.copy,
            moveSymbol: actionSymbols.move,
            // The titles name a side, which is true of every folder over there. The rule that
            // decides WHICH folder — each item's own path, re-rooted — appears nowhere else in
            // the window, and not knowing it is what makes a transfer into an already-matching
            // location look like a dead click.
            transferHelp: copyTarget.map {
                "Puts each item where its counterpart belongs in \($0), creating folders as needed"
            },
            onCompare: {
                guard let folder = selectionNodes.first else { return }
                // The comparison toolbar's "Compare this folder": both panes ARE visible here, so
                // the link toggle means what it says and is honored.
                actionHandler?.focusFolder(folder, isLeft: isLeft,
                                           leftProviderId: leftProviderId, rightProviderId: rightProviderId,
                                           suppressLinkedNavigation: false)
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

    /// The workspace bar — one flat row of every workspace, riding the toolbar's leading region,
    /// which `.hiddenTitleBar` leaves empty save for the traffic lights, so it costs no content
    /// height at all.
    ///
    /// This replaces the two-level `Compare | Tidy` picker plus the lens tabs that used to head
    /// what is now Organize. The old arrangement kept the lens tabs *out* of here deliberately —
    /// their ~300pt would have overflowed the window's `minWidth` (600 then, 760 now) and macOS would have
    /// folded them behind a chevron. Flattening does not repeal that constraint, it inherits it,
    /// which is what ``WorkspaceBarMetrics`` is for: below the width where six labels fit, every
    /// segment sheds its label at once and the glyphs carry the bar.
    var workspaceBar: some View {
        // Custom buttons rather than `Picker(.segmented)`: the native control renders neutral
        // inside a macOS 26 glass toolbar group and ignores `.tint`, so the selected segment could
        // never carry the app accent. These draw their own accent fill, which the group leaves
        // alone. The binding's setter still runs (it opens the source rail).
        let selection = workspaceSelection
        // The DEEPENED accent, which is what makes the white label legible: filled with the raw
        // accent this pill stranded white text at ~2.1–2.7:1 on Amber/Cyan/Green.
        let accentFill = glassHue.accentFillColor
        let onAccent = glassHue.onAccentLabelColor
        let style = toolbarStyles.workspace
        return HStack(spacing: WorkspaceBarMetrics.segmentGap) {
            ForEach(Array(Workspace.allCases.enumerated()), id: \.element) { index, workspace in
                // Browse and Compare look at trees; Organize and Storage act on or account for
                // one. The rule says so — it is the one real grouping in the bar.
                //
                // A hardcoded index, and it has to move whenever the bar's order does: it read
                // `index == 1` when Compare led the bar, which with Browse in front would draw the
                // rule between Browse and Compare — the wrong grouping, and invisible to
                // `WorkspaceBarMetrics`, which is only ever told HOW MANY separators there are.
                // `WorkspaceBarMetricsTests.theRuleSeparatesTheLookersFromTheActors` pins the pair
                // it sits between rather than the number.
                if index == Self.workspaceRuleIndex {
                    Divider().frame(height: 14).padding(.horizontal, 4)
                }
                workspaceSegment(workspace, ordinal: index + 1, selection: selection, style: style,
                                 accentFill: accentFill, onAccent: onAccent)
            }
        }
        // The travel itself. `matchedGeometryEffect` only says the two frames are the same view —
        // without an animation around the change it still arrives instantly. Scoped by `value:` to
        // the selection, so resizing the bar (which re-runs the style ladder and can change every
        // segment's width at once) is not animated as a slide.
        //
        // Reduce Motion takes the destination and skips the travel: the accent fill still marks the
        // selected segment, it just appears there. Same bargain `HoverAffordanceMetrics` strikes —
        // drop what moves, keep what colors.
        .designAnimation(.easeOut(duration: 0.22), value: selection.wrappedValue)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
        // Inset the segments inside an outer container capsule so the selected pill floats within
        // it with a gap on every side, instead of filling the control edge-to-edge.
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
        .fixedSize()
        // **The destination picker owns the window while it is up, and the toolbar is not under
        // it.** The picker is a content overlay and this is a titlebar accessory, so every segment
        // here stays visible and clickable over it — which is the same hole ⌘K had: clicking a
        // workspace switched it *under* a pending pick. `toggleCommandPalette` guards the palette;
        // this guards the bar.
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
        // The chord is the segment's 1-based POSITION, the same enumeration `WorkspaceCommands`
        // binds its chords from — both count `Workspace.allCases`, so the badge and the key
        // equivalent cannot disagree.
        // Empty past nine, which reads as "no badge" everywhere this is shown — the same answer
        // the menu gives. See `AppChord.workspace(_:)`.
        let chord = AppChord.workspace(ordinal)?.display ?? ""
        Button {
            selection.wrappedValue = workspace
        } label: {
            HStack(spacing: 6) {
                Image(systemName: workspace.symbol)
                    .font(.system(size: 12, weight: .medium))
                    // **Framed, so a segment's size stops depending on which symbol is in it.**
                    // The four glyphs render at four different sizes — see
                    // `WorkspaceBarMetrics.glyphSide` for the measurements and for the three
                    // separate defects that followed from not doing this. Same idiom as
                    // `PaneTabStripLadder.markSide`, which frames a chip's provider mark for the
                    // same reason.
                    .frame(width: WorkspaceBarMetrics.glyphSide,
                           height: WorkspaceBarMetrics.glyphSide)
                if style == .full {
                    Text(workspace.title)
                        .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .medium))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(onAccent) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, style == .full ? 12 : 10)
            .padding(.vertical, 4)
            // **One capsule that moves, not one per segment that blinks.** Drawn only under the
            // selected segment and tagged into `workspaceMarker`, so when the selection changes
            // SwiftUI treats the outgoing and incoming fills as the SAME view and interpolates
            // between their frames — the pill slides along the bar. Written as a conditional
            // `.background` rather than the `in: Capsule()` shorthand because a shape style has
            // no geometry to match; the effect needs a real view to attach to.
            .background {
                if isSelected {
                    Capsule()
                        .fill(accentFill)
                        .matchedGeometryEffect(id: Self.workspaceMarkerID, in: workspaceMarker)
                }
            }
            .contentShape(Capsule())
        }
        // The selected segment already carries the accent fill, so it takes the ring; the
        // unselected ones wash the capsule they would fill if you clicked them.
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .segment, tint: accentFill))
        .shortcutKeycap(chord)
        // Once the label is shed the glyph is the only thing naming this workspace, so the name
        // has to survive somewhere reachable — the tooltip for a mouse, the a11y label otherwise.
        .help(ShortcutHint.tooltip(workspace.title, chord))
        .accessibilityLabel(workspace.title)
        // These Buttons stand in for a `Picker(.segmented)` (which renders neutral in a macOS 26
        // glass toolbar group), so they restate the selected-state semantics the Picker gave
        // VoiceOver for free.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The `matchedGeometryEffect` id for the selected segment's accent capsule. One marker, so
    /// one id — a per-segment id would give each its own identity and defeat the whole effect.
    static let workspaceMarkerID = "workspace.selection.marker"

    /// Which segment the group rule is drawn BEFORE, as an index into `Workspace.allCases`.
    ///
    /// Named rather than written inline so a test can assert what it separates instead of
    /// restating the literal — a test that reads `2` and finds `2` would have passed just as
    /// happily when `2` was the wrong answer.
    static let workspaceRuleIndex = 2

    /// Each segment's rendered label width, at the app's current text scale.
    ///
    /// Measured, not tabulated: a constant would be right at exactly one Settings ▸ Text size and
    /// would silently overflow at the larger ones — and overflow here does not truncate, it hides
    /// the whole control behind macOS's overflow chevron. Semibold because that is the selected
    /// segment's weight, and the widest; sizing on `.medium` would under-measure the one segment
    /// that is always bold.
    static func workspaceLabelWidths(scale: CGFloat) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 12 * scale, weight: .semibold)
        return Workspace.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
    }

    /// Closed or open, from the pair the row resolved. The open case takes its width from
    /// `styles(...)`, never from the field itself — the field is spending the same row width the
    /// workspace bar is.
    var goToFieldMode: GoToFieldBar.Mode {
        if showCommandPalette, let layout = toolbarStyles.field { return .open(layout) }
        return .closed(toolbarStyles.search)
    }

    /// The window toolbar — the window-level controls, and only those: which workspace you're in,
    /// and the three utilities (Settings, Logs, Info). Everything else lives where it acts: Scan is
    /// in each pane header, Find Duplicates in the Duplicates lens, and the file actions are
    /// the panes' contextual action bar.
    @ToolbarContentBuilder
    var mainToolbar: some ToolbarContent {
        // **The sidebar toggle, mirrored from the Info toggle at the far end of the bar.** Same
        // shape, opposite edge: `sidebar.left` against `sidebar.right`, ⌃⌘S against ⌘I, the accent
        // tint on the label while open in both, the keycap on the LABEL rather than the item (a
        // toolbar item's own bounds are AppKit's), and the same silence during a destination pick.
        //
        // **The one asymmetry is deliberate: Info is available unconditionally, this is not**
        // (`FolderSidebarModel.appliesTo` — a workspace that carries no column, or panes collapsed
        // behind a destination pick). Disabled rather than hidden: a toolbar that reflowed as you
        // switched workspace is unsettling, and a button that vanished would leave nothing to
        // explain itself.
        //
        // The tooltip says WHY it is greyed, because that is the question someone reaching for a
        // disabled switch is actually asking — and there are two answers with different remedies.
        // See `FolderSidebarModel.unavailableReason`.
        ToolbarItem(placement: .navigation) {
            let available = FolderSidebarModel.appliesTo(
                workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar,
                panesCollapsed: panesHiddenForCurrentTab)
            let showing = available && browseSidebarVisible
            Button {
                withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
                    browseSidebarVisible.toggle()
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
                  // No chord on this one: naming a keystroke that cannot fire here is the same
                  // failure as publishing a chord for a column that cannot appear.
                  : (FolderSidebarModel.unavailableReason(
                        workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar,
                        panesCollapsed: panesHiddenForCurrentTab) ?? ""))
            .accessibilityLabel(showing ? "Hide sidebar" : "Show sidebar")
            // **Both halves of one control agree**, the rule the Info button below states at
            // length: the menu item is `nil`-disabled wherever the column cannot be drawn and
            // silenced by the publisher during a pick, so the button must be too, or a mouse user
            // could reach what a keyboard user could not.
            .disabled(!available || pendingDestination != nil)
        }

        // `.navigation` puts the bar immediately after the traffic lights. There's no window title
        // competing for the space — the window is `.hiddenTitleBar`.
        ToolbarItem(placement: .navigation) {
            workspaceBar
        }

        // A leading flexible spacer keeps the utility pill trailing (macOS 26's grouped toolbar no
        // longer trails `.primaryAction` on its own).
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }

        // ⌘K, wearing its own key. Trailing rather than centred, which is where every Mac app puts
        // a toolbar search (Finder, Mail, Notes, Xcode), and its own item rather than a fourth
        // member of the utility group: those three are glyph buttons and this is a field-shaped
        // resting surface — dropping it in among them would read as a button that had grown.
        ToolbarItem(placement: .primaryAction) {
            GoToFieldBar(
                mode: goToFieldMode,
                query: $goToQuery,
                chord: AppChord.commandPalette.display,
                focusToken: goToFocusToken,
                accent: glassHue.accentColor,
                onOpen: { toggleCommandPalette() },
                onMove: { palettePanel.move(by: $0) },
                onSubmit: { palettePanel.runSelection() },
                onCancel: { palettePanel.dismiss() })
            // `toggleCommandPalette` refuses while a pick is pending, and a control that silently
            // does nothing is its own bug: the menu item dims itself for the same reason, and this
            // is the path a mouse user actually takes.
            .disabled(pendingDestination != nil)
            // 120ms, and on the width rather than on a transition: the pill grows into the field
            // and back, so the row reads as one control changing size rather than two controls
            // swapping places.
            .designAnimation(.easeOut(duration: 0.12), value: showCommandPalette)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { showSettings = true }) {
                Label("Settings", systemImage: "gear")
                    // On the LABEL, not the Button: a toolbar item's own bounds are AppKit's, and
                    // an overlay hung outside the SwiftUI content is the one that gets clipped.
                    // Centred for the same reason as the pane magnifier — the keycap is wider
                    // than the gear.
                    .shortcutKeycap(AppChord.settings.display)
            }
            .help(ShortcutHint.tooltip("Settings", AppChord.settings.display))
            // Disabled during a destination pick, like the bar and the ⌘K pill. ⌘, is registered
            // in the App scene and cannot be suspended from this window, so the parity that makes
            // this correct is not the button's: `ContentView`'s `onChange(of: showSettings)`
            // refuses the latch itself, for every caller. With the act already refused, an enabled
            // button would be a control that silently does nothing — which the ⌘K pill above calls
            // its own bug — and the toolbar is the one surface the picker's scrim does not cover.
            .disabled(pendingDestination != nil)

            Button(action: { openWindow(id: "activity-log") }) {
                Label("Logs", systemImage: "list.bullet.rectangle")
                    .shortcutKeycap(AppChord.activityLog.display)
            }
            .help(ShortcutHint.tooltip("Activity log", AppChord.activityLog.display))

            // Info inspector toggle — available on every workspace (Compare shows both-sides
            // status; a lens shows the single source), so opening Info never yanks the rail over
            // to Compare.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() }
            } label: {
                Label("Info", systemImage: "sidebar.right")
                    // Accent-tinted when the inspector is open, so the toggle reads as a state and
                    // not just an action. Closed, it renders as a normal enabled toolbar button.
                    .foregroundStyle(showInspector ? AnyShapeStyle(glassHue.accentColor) : AnyShapeStyle(.primary))
                    // On the LABEL, like Settings above — a toolbar item's own bounds are AppKit's.
                    .shortcutKeycap(AppChord.infoInspector.display)
            }
            .help(ShortcutHint.tooltip(
                showInspector ? "Hide the Info inspector" : "Show details for the selected item",
                AppChord.infoInspector.display))
            .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
            // **The two halves of one control agree.** ⌘I is silenced during a destination pick
            // (`ShortcutValuePublisher.suspended`), while this button — which the picker's scrim
            // deliberately blocks the mouse from reaching everywhere else — stayed live in the
            // toolbar, so a mouse user could toggle the inspector under the overlay and a keyboard
            // user could not. Same rule for both, like the workspace bar and the ⌘K pill above.
            .disabled(pendingDestination != nil)
        }
    }
}
