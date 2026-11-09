import SwiftUI
import Dashboard
import Design
import Events
import FileExplorer
import Sync

/// The Editor workspace's wiring: where its folder comes from, what its verbs do, and who pays for
/// the consequences.
///
/// `EditorWorkspaceView` is deliberately manager-free — every act leaves through a closure — and
/// this is where those closures are answered. It is also the only place that prompts: the
/// dirty-buffer question and the changed-on-disk question are asked here, once each, rather than
/// inside a view that several paths can reach.
extension ContentView {

    // MARK: - Where the editor is pointed

    /// The folder whose text files the rail lists: the left pane's folder, read through the view
    /// mode the drawn pane uses (`resolvedViewMode(isLeft: true)`), so the rail and the pane
    /// describe the same folder. In Columns it is the deepest open column, in Tree the pane's root.
    ///
    /// Always the LEFT pane, by decision: it is Edit's source pane and the one the folder sidebar
    /// re-roots, so ⌘N creates the file where the user is looking. That is also why
    /// ``handOffToEditor(_:)`` re-roots the left pane whichever pane the row was in.
    var editorFolder: String { leftPaneFolder(in: selectedWorkspace) }

    /// The folder the left pane shows in `workspace`: `editorFolder` for the workspace on screen,
    /// and for acts that move the pane on another workspace's behalf, the folder THAT workspace
    /// will show (a hand-off asks Edit's; see `EditorHandOffRun.run`'s `paneFolder`).
    func leftPaneFolder(in workspace: Workspace) -> String {
        Self.paneFolder(treeRoot: currentLeftPath, browsePath: syncManager.leftBrowsePath,
                        drawsColumns: viewMode(in: workspace, isLeft: true) == .columns)
    }

    /// In Columns the deepest open column, in Tree the pane's root, with `~` expanded. `/` stays
    /// `/`: `PaneBrowsePath.normalized` strips a root's trailing slash, which would leave the whole
    /// disk's root as `""` and the rail with "No folder selected".
    static func paneFolder(treeRoot: String, browsePath: PaneBrowsePath, drawsColumns: Bool) -> String {
        let target = drawsColumns ? browsePath.currentDirectory(treeRoot: treeRoot) : treeRoot
        if target.isEmpty, treeRoot.hasPrefix("/") { return "/" }
        return (target as NSString).expandingTildeInPath
    }

    /// The rail's rows and its empty-caption count, re-read when the folder changes and after the
    /// editor writes to it.
    ///
    /// Off the main actor: a directory read plus an `lstat` per row and a `stat` per link, any of
    /// which can block on an iCloud folder. A folder with no text files pays a second `lstat` per
    /// entry (``EditorRail/survey(in:showsHidden:fileManager:isCloudOnly:)``). `id:` covers the
    /// folder and the hidden-files preference, so flipping ⇧⌘. re-lists.
    func refreshEditorRail() async {
        let folder = editorFolder
        let showsHidden = syncManager.showHiddenFiles
        // Two refreshes can overlap (the `.task(id:)`, the rail coming back into view, an autosave);
        // an older survey finishing last must not undo a newer one.
        let ticket = editorRailRefreshes.take()
        let survey = await Task.detached(priority: .userInitiated) {
            await EditorRail.surveySuspending(in: folder, showsHidden: showsHidden)
        }.value
        // The folder can change while the walk is out; a late answer must not list another
        // folder's files under this one's heading.
        guard folder == editorFolder, editorRailRefreshes.admit(ticket) else { return }
        if editorRailSurveyFolder != folder { editorRailSurveyFolder = folder }
        // Only when the listing changed. This runs after every autosave, and any `@State` write
        // costs a full body pass. The rows carry each file's size and the survey is compared
        // whole, so a length change or a PDF landing in an empty folder still lands.
        guard survey != editorRailSurvey else { return }
        editorRailSurvey = survey
    }

    // MARK: - Expand (once "Just the text")

    /// Whether the file rail is on screen: the pane is collapsed, Expand is off, and the list is
    /// not folded into the strip.
    var editorRailIsDrawn: Bool {
        TopPaneVisibility.editorRailIsDrawn(paneHidden: panesHiddenForCurrentTab,
                                            railHidden: editorRailHidden,
                                            // The hand fold, or the one the docked Ask Claude column makes.
                                            railFolded: editorRailFolded || askClaudePinFoldActive)
    }

    /// Whether Expand is on: the rail bit set AND the source pane folded. Opening the pane by hand
    /// clears the bit, but a stored bit alone could still be set beside an open pane, lighting
    /// "Files" for a press that changes nothing. The header, the menu tick and the toggle read this.
    var editorIsExpanded: Bool {
        editorRailHidden && panesHiddenForCurrentTab
    }

    /// The Expand button's act, and Text ▸ Expand's; the strip's buttons have their own,
    /// `showEditorRail`, which leaves the pane folded. On: the text alone, with the rail, the pane
    /// and the sidebar put away. Off: each given back as it was when Expand began. `EditorExpand`
    /// is the rule; this writes it.
    ///
    /// Decided by ``editorIsExpanded``, not the bit: with the bit set and the pane open, a press
    /// expands, as the unlit button offers. Logged both ways, naming what moved, since nothing on
    /// screen records it.
    func toggleJustTheText() {
        let before = editorExpand
        var expand = before
        if editorIsExpanded {
            expand.leave()
            editorExpand = expand
            Logger.shared.info("[edit] Expand off — " + EditorExpand.moved(from: before, to: expand) + " back")
        } else {
            expand.enter(sidebarShowing: folderSidebarIsShowing)
            editorExpand = expand
            Logger.shared.info("[edit] Expand on — " + EditorExpand.moved(from: before, to: expand) + " put away")
        }
    }

    /// Where a fold or unfold of the list came from, named in its log line, since nothing on
    /// screen says which of the four doors was used.
    enum EditorRailDoor: String {
        case strip = "the strip"
        case menu = "View ▸ File List"
        case emptyPage = "the empty page"
        case statusLine = "the status line's heading menu"
    }

    /// The strip's pane button: lit while the pane shows, folded by a second click
    /// (`EditorRailFold.paneRungAct`). Opening it takes the list's place, folding the list too, so
    /// folding the pane again leaves nothing open, as the lit button promised. Through
    /// `togglePanesForCurrentTab`, which ends Expand when it opens the pane.
    func runEditorPaneRung() {
        // The pin has the list and the pane folded: either button brings them back, and the pin
        // stops folding. Nothing else changes, so nothing stored is overwritten.
        if askClaudeReleasePinFold() { return }
        switch EditorRailFold.paneRungAct(paneOpen: !editorPaneIsFolded) {
        case .openPane:
            if !editorRailFolded { editorRailFolded = true }
            togglePanesForCurrentTab()
            Logger.shared.info("[edit] File pane shown from the strip")
        case .foldPane:
            togglePanesForCurrentTab()
            Logger.shared.info("[edit] File pane folded from the strip")
        }
    }

    /// The Files list back on screen, on `tab`, from the strip, the menu or the empty page. Under
    /// Expand, `EditorExpand.textFilesShown` clears Expand's bit and spends its record but leaves
    /// the pane folded, since an open pane draws no list. Not `toggleJustTheText`, whose way out
    /// reopens a pane Expand folded.
    func showEditorRail(tab: EditorRailTab, from door: EditorRailDoor) {
        if askClaudeReleasePinFold() {
            if editorRailTab != tab { editorRailTab = tab }
            return
        }
        // The pane and the list are never on screen together, and the strip stays beside an open
        // pane: a list button pressed there folds the pane to show the list.
        if !editorPaneIsFolded {
            var expand = editorExpand
            expand.paneFolded = true
            editorExpand = expand
            Logger.shared.info("[edit] File pane folded for the list from \(door.rawValue)")
        }
        if editorRailHidden {
            let before = editorExpand
            var expand = before
            expand.textFilesShown()
            editorExpand = expand
            Logger.shared.info("[edit] Expand off from \(door.rawValue) — " + EditorExpand.moved(from: before, to: expand) + " back")
        }
        if editorRailTab != tab { editorRailTab = tab }
        if editorRailFolded {
            editorRailFolded = false
            Logger.shared.info("[edit] Files list shown from \(door.rawValue)")
        }
    }

    /// The Files list folded into the strip. Writes only the hand-folded bit; Expand's stays as it
    /// was, so the header does not light Files for a list folded by hand.
    func foldEditorRail(from door: EditorRailDoor) {
        guard !editorRailFolded else { return }
        editorRailFolded = true
        Logger.shared.info("[edit] Files list folded from \(door.rawValue)")
    }

    /// The rail tab as DRAWN: the stored one, unless that is Pages with no PDF open or Outline with
    /// nothing to outline (`EditorRailTab.resolved`). The strip reads this, not `editorRailTab`:
    /// the stored Pages survives a note opening, and would light no button while the rail shows Files.
    var editorRailShownTab: EditorRailTab {
        EditorRailTab.resolved(editorRailTab, pdfIsOpen: editorPDF.path != nil, pdfHasOutline: editorPDFHasOutline,
                               markdownIsOpen: EditorWorkspaceView.markdownIsOpen(editorDocument))
    }

    /// Whether the open PDF's bookmarks earn the Outline tab and its strip button: the rail's own
    /// rule, `EditorRailTab.pdfOutlineIsWorthATab`.
    var editorPDFHasOutline: Bool {
        EditorRailTab.pdfOutlineIsWorthATab(editorPDF.outline)
    }

    /// A strip button's click: `EditorRailFold.rungAct` decides between showing the list on that
    /// tab, folding it, and switching tabs.
    func runEditorRailRung(_ tab: EditorRailTab) {
        switch EditorRailFold.rungAct(for: tab, railDrawn: editorRailIsDrawn, currentTab: editorRailShownTab) {
        case .show(let tab): showEditorRail(tab: tab, from: .strip)
        case .fold: foldEditorRail(from: .strip)
        case .switchTo(let tab): editorRailTab = tab
        }
    }

    /// View ▸ File List ⌃⌘T: the list alone, ticked while it is on screen. Not Expand's "Files",
    /// which brings back the pane and sidebar too. `nil` (greyed) outside Edit. With the pane open,
    /// or under Expand, it is unticked, and ticking it folds the pane or ends Expand as the strip's
    /// buttons do.
    var shortcutEditorTextFiles: Binding<Bool>? {
        guard selectedWorkspace == .editor else { return nil }
        return Binding(
            get: { editorRailIsDrawn },
            set: { show in
                if show { showEditorRail(tab: editorRailTab, from: .menu) } else { foldEditorRail(from: .menu) }
            })
    }

    /// The pane's one-click open, as a rule: which path a selection change opens, or `nil`.
    ///
    /// Six guards, each a case in `EditorPaneClickTests`: Edit only; pane expanded (collapsed, the
    /// rail is the list); exactly one path; not a folder (`isDirectory` is `nil` for an
    /// unresolved selection, which refuses too); a kind Edit opens; and not a selection the app
    /// just wrote for the open document (`paidSelection`). That write is not a click: for a refused
    /// file it would reload and log a second refusal. Cloud-only and too-large files pass, so
    /// `openInEditor` refuses them in one place, with the rail's caption.
    static func paneSelectionOpens(workspace: Workspace, paneHidden: Bool,
                                   paths: Set<String>, isDirectory: Bool?,
                                   paidSelection: String? = nil) -> String? {
        guard workspace == .editor, !paneHidden,
              paths.count == 1, let path = paths.first,
              path != paidSelection,
              let isDirectory, !isDirectory,
              EditableText.opensInEdit(path: path) else { return nil }
        return path
    }

    /// In Edit the open pane IS the file list, so selecting a single file Edit opens (text, or a
    /// PDF read-only) opens it through `openInEditor`, as a rail row does: it guards the
    /// already-open case and settles a dirty buffer first. Not `handOffToEditor`, which re-roots
    /// the pane and switches workspace. Arrow keys move the selection as clicks do, so they open
    /// files too.
    ///
    /// `openInEditor` never writes the pane's selection, so this cannot fire itself. The row
    /// menu's hand-off and the Info inspector's Open in Edit end on the open document, which
    /// `openInEditor`'s first guard returns early for.
    func openSelectedPaneFileInEditor(_ paths: Set<String>) {
        // One-shot: the app's own write is the next selection change and nothing after it.
        let paid = editorPaneSelectionPaid
        editorPaneSelectionPaid = nil
        // The node walk is paid only once the cheap guards have passed: one path, in Edit, pane open.
        let node = (selectedWorkspace == .editor && paths.count == 1)
            ? paneSelectionNodes(isLeft: true).first : nil
        guard let path = Self.paneSelectionOpens(workspace: selectedWorkspace,
                                                 paneHidden: panesHiddenForCurrentTab,
                                                 paths: paths, isDirectory: node?.isDirectory,
                                                 paidSelection: paid)
        else { return }
        openInEditor(path: path)
    }

    // MARK: - Where the open document lives

    /// The header's location for the open document: `in Finance` while the source pane is open,
    /// the whole crumb while it is collapsed (`EditorDocumentLocation.Style`). With no document
    /// open, the same for `editorFolder`, where a new file would be made.
    ///
    /// The LEFT pane's source, as `editorFolder` reads the left pane. `leftProviderId` rather than
    /// `paneContext(isLeft:)`, which builds the whole pane's context to answer one id.
    var editorDocumentLocation: EditorDocumentLocation? {
        EditorHeaderLocation.location(
            documentPath: editorOpenPath,
            paneFolder: editorFolder,
            sourceRoot: (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath,
            providerName: settings.availableProviders.first { $0.id == leftProviderId }?.displayName,
            paneIsOpen: !panesHiddenForCurrentTab,
            otherSources: editorOtherSources)
    }

    /// Every enabled source but the left pane's, as the location names them, so a document in
    /// another cloud reads "in Dropbox › Backup" rather than "in Backup".
    var editorOtherSources: [(name: String, root: String)] {
        settings.enabledProviders.filter { $0.id != leftProviderId }.map { provider in
            let root = (settings.rootPath(for: provider.id) as NSString).expandingTildeInPath
            return (name: BreadcrumbTrail.rootDisplayName(forRootPath: root,
                                                           providerName: provider.displayName),
                    root: root)
        }
    }

    /// What the ＋, the naming row and the rail call `editorFolder`: the pane breadcrumb's word,
    /// "iCloud" at the top of iCloud Drive rather than "com~apple~CloudDocs"
    /// (`EditorHeaderLocation.folderName`).
    var editorFolderDisplayName: String {
        EditorHeaderLocation.folderName(
            paneFolder: editorFolder,
            sourceRoot: (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath,
            providerName: settings.availableProviders.first { $0.id == leftProviderId }?.displayName,
            otherSources: editorOtherSources)
    }

    /// The rail's folder menu: up from `editorFolder` to the top of the left pane's source, and
    /// down into the folders the rail's survey found inside it (`EditorHeaderLocation.folderTrail`).
    var editorFolderTrail: EditorFolderTrail? {
        EditorHeaderLocation.folderTrail(
            paneFolder: editorFolder,
            sourceRoot: (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath,
            providerName: settings.availableProviders.first { $0.id == leftProviderId }?.displayName,
            subfolders: EditorHeaderLocation.subfolders(editorRailSurvey.folders,
                                                        surveyed: editorRailSurveyFolder, folder: editorFolder),
            otherSources: editorOtherSources)
    }

    /// What a press on that location does. `EditorLocationDoors` is handed neither the pane's
    /// visibility nor the document, so no door can expand the pane or touch the file.
    var editorLocationDoors: EditorLocationDoors {
        EditorLocationDoors(
            syncManager: syncManager,
            drawsColumns: resolvedViewMode(isLeft: true) == .columns,
            log: { Logger.shared.info($0) },
            selectInPane: { owePaneSelection($0) })
    }

    // MARK: - The layout arm


    /// Editor: the folder sidebar, a collapsible source pane, then the file rail and the open
    /// document.
    ///
    /// The source pane is the same `paneColumn` Organize docks, collapsing to the same `railSpine`
    /// on the same stored override, so the two behave alike and remember their collapse per
    /// workspace. It reaches folders the sidebar has never kept or visited. Collapsed by default
    /// (`TopPaneVisibility.defaultPanesHidden`), since most sessions open a file and write.
    ///
    /// With the pane open the rail is withheld, since both list the same folder; folded, the rail
    /// is drawn unless Expand is on (`editorRailIsDrawn`). The sidebar is drawn in both states
    /// (`Workspace.folderSidebarOutlivesPaneCollapse`), at `lensSidebarWidth`, which reserves more
    /// than the collapsed row needs (`theCollapsedEditRowFitsTheLensClamp`). The open pane is the
    /// rail's width, not a dragged split, and the document takes the rest.
    @ViewBuilder
    func editorLayout(collapsed: Bool, geo: GeometryProxy) -> some View {
        let totalWidth = geo.size.width
        let sidebarWidth = folderSidebarIsShowing
            ? PaneLogic.lensSidebarWidth(stored: browseSidebarWidth, totalWidth: totalWidth,
                                         minSidebar: FolderSidebarView.minWidth,
                                         gutter: LiquidGlass.gutter(surfaceStyle))
            : 0
        let sidebarSlot = folderSidebarIsShowing
            ? sidebarWidth + PaneLogic.sidebarOverhead(gutter: LiquidGlass.gutter(surfaceStyle)) : 0
        let column = editorColumnWidth(in: totalWidth - sidebarSlot)
        // **One row whether the pane is open or folded:** only the pane's slot comes and goes. Two
        // arms of an `if` would give the workspace a new identity on a fold, rebuilding and
        // re-parsing the text view around the whole buffer.
        //
        // The strip stays when the pane opens, and the pane takes the rail's slot (the column
        // plus its card's gutter in Cards), so the pane, Files, Pages and Outline share one width,
        // dragged at one edge. At the 232pt default the pane is under
        // `PaneViewMode.pushNavigationBelowWidth`, so Columns shows one column with ‹ to walk back.
        HStack(spacing: 0) {
            if folderSidebarIsShowing {
                folderSidebar(width: sidebarWidth)
                folderSidebarResizeHandle(displayedWidth: sidebarWidth)
            }
            railSpine
            CollapsibleRailRow {
                if !collapsed {
                    paneColumn(isLeft: true)
                        .panesRegionFrame(surfaceStyle, level: glassLevel)
                        .frame(width: Self.editorColumnSlot(column, style: surfaceStyle))
                        .unifiedSeam(surfaceStyle, edge: .trailing)
                }
            } workspace: {
                // No region frame: the workspace draws its own two cards in Cards, and a third
                // around them would double the inset and square the corner. In Unified the window's
                // region frames them. With the pane open, `editorRailIsDrawn` withholds the rail.
                editorWorkspace(showsRail: editorRailIsDrawn, railWidth: column)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    // The editor's result message: its saves, its PDF tools' notes.
                    .modifier(workspaceResultMessageHost)
                    // With the strip's own curve, so the header card moves with the strip. Keyed
                    // on the strip alone, not `sourcePaneShowsTabStrip`, which also flips on a fold
                    // and would re-wrap the whole text every frame of a fold that should snap.
                    .designAnimation(.easeOut(duration: 0.18), value: sourcePaneStripIgnoringFold)
            }
            // The handle sits at the pane's edge with the pane open and at the list's with it
            // folded: one handle, one width, whichever column shows — and none when neither does.
            .overlay(alignment: .leading) {
                if !collapsed || editorRailIsDrawn {
                    editorColumnResizeHandle(displayedWidth: column,
                                             slot: Self.editorColumnSlot(column, style: surfaceStyle))
                }
            }
        }
        .frame(width: totalWidth, height: geo.size.height)
    }

    /// A side column's slot in Edit: its width plus the gutter its card's insets add in Cards
    /// (nothing in Unified, where it sits flush), so the pane and the list draw at one width.
    static func editorColumnSlot(_ column: CGFloat, style: SurfaceStyle) -> CGFloat {
        column + LiquidGlass.gutter(style)
    }

    /// The side column's width as drawn: the stored one, inside
    /// `EditorLayoutMetrics.clampedRailWidth`, narrowed when the row cannot also hold the strip and
    /// the document's floor, but never below the rail's floor, which the tabs need. `rowWidth` is
    /// the row after the sidebar.
    func editorColumnWidth(in rowWidth: CGFloat) -> CGFloat {
        let stored = EditorLayoutMetrics.clampedRailWidth(CGFloat(editorColumnWidthRaw))
        let room = rowWidth - PaneLogic.railSpineWidth - LiquidGlass.gutter(surfaceStyle)
            - EditorLayoutMetrics.minDocumentOnlyWidth - LiquidGlass.gutter(surfaceStyle)
        return max(EditorLayoutMetrics.railWidth, min(stored, room))
    }

    /// The open column's edge, dragged: one handle for the pane and the list, writing the width
    /// they share. Laid over the boundary rather than in the row, so it costs the layout nothing.
    func editorColumnResizeHandle(displayedWidth: CGFloat, slot: CGFloat) -> some View {
        ResizeHandle(
            axis: .horizontal,
            thickness: 10,
            minimumDistance: 1,
            coordinateSpace: .global,
            onDrag: { value in
                // From the width at the start of the drag, as the sidebar's handle does: adding
                // each frame's translation to an already-moved width runs away from the pointer.
                let base = editorColumnDragOrigin ?? displayedWidth
                if editorColumnDragOrigin == nil { editorColumnDragOrigin = base }
                editorColumnWidthRaw = Double(EditorLayoutMetrics.clampedRailWidth(base + value.translation.width))
            },
            onCommit: { editorColumnDragOrigin = nil }
        )
        .frame(width: 10)
        .offset(x: slot - 5)
    }

    /// - Parameter showsRail: whether the file rail is drawn, decided by
    ///   ``editorLayout(collapsed:geo:)``. The survey `.task` below runs regardless: it is cheap,
    ///   and the rail returns often.
    func editorWorkspace(showsRail: Bool, railWidth: CGFloat = EditorLayoutMetrics.railWidth) -> some View {
        EditorWorkspaceView(
            document: editorDocument,
            autosavePolicy: editorAutosavePolicy,
            // Only while a PDF is open; the text document is empty then.
            pdf: editorPDF.path == nil ? nil : editorPDF,
            folder: editorFolder,
            entries: editorRailSurvey.rows,
            otherFileCount: editorRailSurvey.otherFileCount,
            showsRail: showsRail,
            railIsHidden: editorIsExpanded,
            accent: glassHue.accentColor,
            accentFill: glassHue.accentFillColor,
            onAccent: glassHue.onAccentLabelColor,
            mode: $editorMode,
            splitFraction: $editorSplitFraction,
            isNaming: $editorIsNaming,
            typedName: $editorTypedName,
            railFilter: $editorRailFilter,
            railFilterIsExpanded: $editorRailFilterIsExpanded,
            railTab: $editorRailTab,
            railOutlineAnchors: $editorOutlineAnchors,
            namingFocus: editorNamingFocus,
            goToLineRequest: editorGoToLineRequest,
            undoManager: editorUndoManager,
            stopped: editorAutosaveStop?.caption,
            // The reason behind those words, as their tooltip; the banner that said it fades.
            stoppedDetail: editorAutosaveStop?.detail,
            // The stop's words become a door where there is a second version to show
            // (`EditorAutosaveStop.offersDiff`); the alert's Cancel leaves the latch set, so
            // otherwise only ⌘S would reach the question. `nil` leaves the header a plain word.
            onShowWhatChanged: (editorAutosaveStop?.offersDiff ?? false)
                ? { showEditorDivergenceDiff() } : nil,
            // "unsaved — ⌘S" (no stop) and "couldn't write" save; "no longer on disk" is Save
            // Again. Which stops do is the stop's rule, as the door above is.
            onSaveNow: (editorAutosaveStop?.savesFromTheHeader ?? true) ? { _ = saveEditorDocument() } : nil,
            onSaveAgain: (editorAutosaveStop?.savesAgainFromTheHeader ?? false)
                ? { saveEditorDocumentAgain(explicit: true) } : nil,
            // A file that kept changing while it was read, read once more where it is.
            onTryAgain: { if let path = editorDocument.path, editorDocument.refusal != nil { loadIntoEditor(path: path, recordsRecent: false) } },
            // The question a change from elsewhere left standing, and what it did quietly.
            diskBanner: editorDiskWatch.banner,
            diskNotice: editorDiskWatch.notice?.text,
            onDiskBanner: { answerEditorDiskBanner($0) },
            // Closures, so neither walks the folder until the naming row is open. The folder is
            // where ⌘N's file will go: the pane's folder, or Notes (`newTextFileDestination`).
            prefilledName: { EditorFileStore.availableUntitledName(in: newTextFileDestination.folder) },
            refusal: { typed in EditorFileStore.refusal(forName: typed, in: newTextFileDestination.folder) },
            onOpen: { entry in openInEditor(path: entry.path, selectsInPane: true) },
            onCreate: { name in createTextFile(named: name) },
            onRevealInBrowse: { path in revealInBrowse(path, from: .header) },
            location: editorDocumentLocation,
            // Both read at press time: the document or the pane can move between this render and
            // the click.
            onLocationDoor: { door in
                editorLocationDoors.open(door, documentPath: editorOpenPath,
                                         location: editorDocumentLocation)
            },
            railRowActions: EditorRailRowActions(
                // The rail row menu's Reveal in Browse: the same act as the header's, told which
                // door it came through so the log can say so.
                revealInBrowse: { path in revealInBrowse(path, from: .railRow) },
                // Greyed where Browse cannot show the file: the reveal's own reach.
                revealInBrowseRefusal: { path in
                    EditorRevealInBrowse.refusal(
                        for: path, sourceRoot: (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath)
                },
                // The act that needs the window: the shared Quick Look panel. `followsPane: false`: a
                // rail row is not the pane's selection, so a pane click must not retarget a preview
                // opened from here. No Get Info: the rail is drawn only while the file pane is
                // hidden, and Info lives in the pane.
                quickLook: { path in toggleQuickLook(URL(fileURLWithPath: path), followsPane: false) },
                download: { path in downloadFromEdit(path) },
                // Browse's own Rename and Delete: its prompt, confirmation and undo, and the open
                // document answers them as it does from Browse.
                rename: { path in actionHandler?.beginRename(Self.editorRailNode(path)) },
                delete: { path in actionHandler?.confirmDelete([Self.editorRailNode(path)]) }),
            onToggleJustTheText: { toggleJustTheText() },
            // The header's ＋ IS ⌘N: the same closure, so it opens the row, bumps the focus counter,
            // and greys out on the same `nil` as the menu item.
            onNewTextFile: shortcutNewTextFile,
            onCloseDocument: { closeEditorDocument() },
            onAutosaveResumed: { runAutosave() },
            paneShowsTabStrip: sourcePaneShowsTabStrip,
            folderDisplayName: editorFolderDisplayName,
            newFileFolderName: editorNewFileFolderName,
            onImagesImported: { noteEditorImages($0) },
            onPreviewLengthHold: { hold in if editorPreviewLengthHold != hold { editorPreviewLengthHold = hold } },
            contentSearch: editorContentSearch,
            // The folder line's menu moves the LEFT pane, by the header crumbs' route; the rail
            // follows, since it lists that pane's folder.
            folderTrail: editorFolderTrail,
            onGoToFolder: { target in editorLocationDoors.goTo(target, from: "Edit rail folder menu") },
            // No `onFoldRail`: the strip is the one place the columns open and fold from. The empty
            // page's way to the list while it is folded or put away, offered only with the pane
            // folded, since an open pane IS the list.
            onShowTextFiles: (panesHiddenForCurrentTab && !showsRail)
                ? { showEditorRail(tab: .files, from: .emptyPage) } : nil,
            // The status line's heading menu: the list on its Outline, from any layout.
            onShowRailOutline: { showEditorRail(tab: .outline, from: .statusLine) },
            // The folder menu's Show All: the pane, already on the list's folder, as the strip's
            // pane button opens it.
            onOpenFilePane: { if editorPaneIsFolded { runEditorPaneRung() } },
            // The empty page's recent files. A row opens through the hand-off, as Open in Edit
            // does from any other list, so the pane follows the file there.
            recentFiles: EditorRecentFiles.shared,
            onOpenRecent: { path in handOffToEditor(path) },
            // A drop from Finder on the empty page is an open from outside the app: the same
            // queue and rules (the first file here, the rest in the pane, a folder named in a
            // banner, a cloud file fetched first).
            onDropFiles: { urls in
                Logger.shared.info(ExternalOpen.receiptLine(urls, droppedOnEdit: true))
                externalOpens.receive(urls)
            },
            railWidth: railWidth)
        // The PDF tools' door to the window: what a written copy re-lists, and the banner's Open
        // and Reveal in Browse. Set on every appearance, since the model outlives this view.
        .onAppear { editorPDF.tools.host = editorPDFToolHost }
        // A new folder starts unfiltered, on arrival too, for a folder changed in another
        // workspace while this view did not exist.
        .onChange(of: editorFolder, initial: true) { _, folder in noteEditorRailFolder(folder) }
        // The rail is re-listed on arrival and whenever the folder or the hidden-files preference
        // moves; `.task(id:)` restarts on either.
        .task(id: EditorRailKey(folder: editorFolder, showsHidden: syncManager.showHiddenFiles)) {
            await refreshEditorRail()
        }
        // …and whenever the rail comes back into view: a fold keeps this view, so the task above
        // does not restart, and a file changed while the rail was hidden needs this to show.
        .onChange(of: editorRailIsDrawn) { _, drawn in
            if drawn { Task { await refreshEditorRail() } }
        }
    }

    /// The rail's filter belongs to the folder it was typed in. Kept across a trip to another
    /// workspace and back, as `editorRailFilter`'s doc promises, but a different folder clears it
    /// and closes its field, since a leftover filter makes the folder look empty.
    func noteEditorRailFolder(_ folder: String) {
        if Self.railFilterClears(listedFolder: editorRailListedFolder, folder: folder) {
            editorRailFilter = ""
            editorRailFilterIsExpanded = false
        }
        editorRailListedFolder = folder
    }

    /// Whether the rail's filter goes on arriving at `folder`: any folder but the one it last
    /// listed. The first listing has nothing typed to clear, so `nil` clearing is harmless.
    static func railFilterClears(listedFolder: String?, folder: String) -> Bool {
        listedFolder != folder
    }

    /// What a PDF tool's copy does to the window, as Export as PDF's follow-up: the rail lists the
    /// folder the copy landed in, and a pane showing that folder is re-read. The copy is never
    /// opened for the reader; the banner's Open goes through the rail click's door, which asks
    /// about the open document first.
    var editorPDFToolHost: EditorPDFToolHost {
        EditorPDFToolHost(
            didWrite: { path in
                Task { await refreshEditorRail() }
                rereadPanesAfterEditorWrite(path)
            },
            open: { path in openInEditor(path: path, selectsInPane: true) },
            reveal: { path in revealInBrowse(path, from: .pdfToolBanner) },
            // A file only in the cloud now: Edit's own Download, for every provider.
            download: { path in downloadFromEdit(path) })
    }

    /// A PDF tool from a pane row's menu, in any workspace's file pane. The copies' follow-up is
    /// Edit's: the panes holding the folder re-read (and Edit's rail, when Edit is on screen); the
    /// banner's Open hands the copy to Edit through the pane's own door, and its Reveal in Browse
    /// is the reader's.
    func startPanePDFTool(_ request: PDFToolRequest, paths: [String]) {
        guard !refusedWhileRunLocked() else { return }
        let writer = "PDF Tools in \(selectedWorkspace.title)"
        // A request refused while a run goes leaves that run's origin and doors as they are: its
        // ending still goes where it was started, and its Reveal to its own files.
        guard !panePDFTools.isBusy else {
            panePDFTools.start(request, paths: paths, writer: writer)
            return
        }
        paneToolOrigin = selectedWorkspace
        panePDFTools.host = PanePDFToolHost(
            didWrite: { path in
                if selectedWorkspace == .editor { Task { await refreshEditorRail() } }
                rereadPanesAfterEditorWrite(path, writer: "\(writer) wrote")
            },
            open: { path in handOffToEditor(path) },
            // A batch's copies can sit in several folders, and the pane shows one: the first
            // copy's, selecting every copy there as companions. Reveal may replace the
            // multi-selection the batch was run on; one file's run replaces nothing.
            reveal: { copies in
                guard let first = copies.first else { return }
                revealInBrowse(first, with: EditorRevealInBrowse.companions(of: copies),
                               replacing: paths.count > 1 ? Set(paths) : [], from: .pdfToolBanner)
            },
            download: { path in downloadFromEdit(path) })
        panePDFTools.start(request, paths: paths, writer: writer)
    }

    /// Save as PDF from a pane row's menu or File ▸, each file's PDF beside it. The follow-up is
    /// the PDF tools': the panes holding the folder re-read, the banner's Open in Edit goes through
    /// the pane's own door, and its Reveal in Browse selects the PDFs. A folder that cannot be
    /// written to asks where, with a save panel.
    func startSaveAsPDF(_ paths: [String]) {
        guard !refusedWhileRunLocked() else { return }
        let writer = "Save as PDF in \(selectedWorkspace.title)"
        // Refused while a run goes: that run keeps its origin and doors (see `startPanePDFTool`).
        guard !paneSaveAsPDF.isRunning else {
            paneSaveAsPDF.start(paths: paths, writer: writer)
            return
        }
        saveAsPDFOrigin = selectedWorkspace
        paneSaveAsPDF.fontScale = appFontScale
        paneSaveAsPDF.accent = glassHue.accentColor
        paneSaveAsPDF.host = PaneSaveAsPDFHost(
            didWrite: { path in
                if selectedWorkspace == .editor { Task { await refreshEditorRail() } }
                rereadPanesAfterEditorWrite(path, writer: writer)
            },
            open: { path in handOffToEditor(path) },
            reveal: { copies in
                guard let first = copies.first else { return }
                revealInBrowse(first, with: EditorRevealInBrowse.companions(of: copies),
                               replacing: paths.count > 1 ? Set(paths) : [], from: .saveAsPDFBanner)
            },
            chooseDestination: { original, suggested in
                let panel = NSSavePanel()
                panel.nameFieldStringValue = suggested
                panel.allowedContentTypes = [.pdf]
                panel.canCreateDirectories = true
                let folder = ((original as NSString).deletingLastPathComponent as NSString).lastPathComponent
                panel.message = "“\(folder)” can’t be written to. Choose where to save “\(suggested)”."
                return panel.runModal() == .OK ? panel.url?.path : nil
            })
        paneSaveAsPDF.start(paths: paths, writer: writer)
    }

    /// What re-lists the rail, as one value, so a change to either half restarts the one task
    /// rather than needing a second `.task(id:)` that could answer from a different folder.
    struct EditorRailKey: Equatable {
        var folder: String
        var showsHidden: Bool
    }

    // MARK: - Opening

    /// Opens a file in the editor, asking about an unsaved buffer first. The rail's click and the
    /// pane's one-click open come through here; ⌘N's new file (`createTextFile`) and every hand-off
    /// (`EditorHandOffRun.run`) settle and load themselves. All ask `settleEditorDocument()` before
    /// the buffer is replaced, so one question guards every edit that could be lost.
    ///
    /// - Parameter selectsInPane: whether the left pane should then select the file and bring it
    ///   into view: the rail's click, with the pane folded behind the rail on the same folder. Not
    ///   the pane's own click (`openSelectedPaneFileInEditor`), where a reveal would scroll the row
    ///   out from under the pointer.
    func openInEditor(path: String, selectsInPane: Bool = false) {
        // Re-clicking the row that is already open does nothing, unless the last attempt was
        // refused (`EditorHandOffRun.opens`, the guard the hand-off asks too).
        guard EditorHandOffRun.opens(path, openDocument: editorOpenPath,
                                     isRefused: editorOpenIsRefused) else {
            if selectsInPane { owePaneSelection(path) }
            return
        }
        guard settleEditorDocument(thenRetry: { openInEditor(path: path, selectsInPane: selectsInPane) }) else { return }
        // Choosing a file answers the naming row's question, so the row goes; left open, it would
        // sit above the document being edited with only Esc to dismiss it.
        editorIsNaming = false
        loadIntoEditor(path: path)
        if selectsInPane { owePaneSelection(path) }
    }

    /// Reads a file and puts it on screen. No prompt: callers have already dealt with the buffer.
    ///
    /// - Parameter recordsRecent: whether the open goes on Edit's recent files: every route but
    ///   ``reloadOverTheBuffer(path:)``, which re-reads the file already open and opens nothing.
    func loadIntoEditor(path: String, recordsRecent: Bool = true) {
        // The ordering the undo stacks need is stated and tested in `EditorDocumentLoad`.
        //
        // **The remembered mode is NOT narrowed here.** `EditorMode.resolved` is a display filter
        // that `EditorWorkspaceView` applies on the way into `surfaces(for:)`; writing the narrowed
        // value back would let one `.txt` file switch every later note out of Preview.
        //
        // A PDF goes to its own model before any text read (`EditorOpenRoute`), which empties the
        // text document so no save path has anything to write while the PDF is on screen.
        let kind = EditorOpenRoute.load(path: path, document: editorDocument, undoStore: editorUndoStore,
                                        pdf: editorPDF, log: { Logger.shared.info($0) })
        // Every way into Edit ends here, so this one call records them all: once the load has
        // opened the file, and never for one it refused.
        if recordsRecent {
            EditorOpenRoute.recordOpen(kind: kind, document: editorDocument, pdf: editorPDF,
                                       in: EditorRecentFiles.shared)
        }
    }

    /// The open file, text or PDF (``EditorOpenRoute/openPath(document:pdf:)``).
    var editorOpenPath: String? { EditorOpenRoute.openPath(document: editorDocument, pdf: editorPDF) }

    /// Whether the open file was refused, text or PDF.
    var editorOpenIsRefused: Bool { EditorOpenRoute.isRefused(document: editorDocument, pdf: editorPDF) }

    /// Settles the buffer before it is replaced, by WRITING it rather than asking. The ordinary
    /// case is a silent flush: autosave leaves no decision, and the name and folder were settled
    /// when the file was created.
    ///
    /// It still asks when the flush cannot safely write: autosave blocked (the file changed
    /// underneath) or switched off, a failed or unchecked save, a deleted file whose text may be
    /// the only copy, or PDF work in progress. **Callers must honour a `false`.**
    ///
    /// - Returns: `false` when the caller must do nothing at all.
    /// - Parameter retry: the route itself, run again once Fill & Sign's Save Filled Copy (chosen
    ///   in the leave question) has written the copy, so the save goes on to leave.
    /// - Parameter asksAboutTheOnlyCopy: `false` for a window close, which the document outlives:
    ///   a deleted file's text is still on screen when the window comes back.
    @discardableResult
    func settleEditorDocument(asksAboutPDFWork: Bool = true, asksAboutTheOnlyCopy: Bool = true, thenRetry retry: (@MainActor () -> Void)? = nil) -> Bool {
        // What a PDF can lose: a pending reorder, or a tool still running. Only asked here: the
        // order and the run go when the PDF really closes, so a route that fails after the answer
        // keeps both. Not for a window close, which the PDF outlives.
        if asksAboutPDFWork { guard editorPDF.tools.mayLeave(thenRetry: retry) else { return false } }
        // A word being composed is committed first, so it is in the buffer for the question, the
        // flush and the history below.
        editorDocument.buffer.source.endComposition()
        // A save that couldn't be checked is checked now, so a file holding what it wrote counts
        // as saved rather than asked about.
        if editorDocument.uncheckedWrite != nil { editorDiskWatch.reconcile() }
        // A file deleted with nothing typed is asked about too: autosave has nothing to write, but
        // the text on screen may be the only copy left. The watch looks first, so a move is
        // followed; a file still in the Trash can be put back, so it doesn't ask.
        if asksAboutTheOnlyCopy, !editorDocument.isDirty, editorDiskWatch.isGone {
            editorDiskWatch.reconcile()
            if editorDiskWatch.mayBeTheOnlyCopy { return confirmLeavingTheOnlyCopy() }
        }
        // Two documents are asked about rather than flushed: a stopped one, since the flush would
        // refuse again; and one whose autosave switch is off, since flushing it on the way out is
        // exactly the write the switch prevents.
        let withheld = !editorAutosavePolicy.isOn(editorDocument.path)
        if editorAutosaveStop != nil || withheld, editorDocument.isDirty {
            return confirmLeavingAnUnwrittenDocument()
        }
        let flushed = EditorAutosave.attempt(editorDocument)
        switch flushed {
        case .nothingToDo, .wrote:
            if case .wrote = flushed { noteEditorWrote(editorDocument.path) }
            noteAutosave()
            return true
        case .wroteKeepingAside(let clause):
            // Saved and checked; the version it displaced is beside it, and the banner says where.
            noteEditorWrote(editorDocument.path)
            noteAutosave()
            syncManager.banner = EditorAutosaveStop.savedBut(name: editorDocument.name, clause: clause)
            return true
        case .blocked(let divergence):
            // A move is followed and a re-stamp taken before anything is asked, then the flush is
            // tried once more, at the path the file is really at.
            switch editorDiskWatch.reconcile() {
            case .followed, .restamped, .settled:
                if case .wrote = EditorAutosave.attempt(editorDocument) {
                    noteEditorWrote(editorDocument.path)
                    noteAutosave()
                    return true
                }
            default:
                break
            }
            // It diverged between the last attempt and this one. Same question, asked now.
            editorAutosaveStop = .diverged(divergence)
            return confirmLeavingAnUnwrittenDocument()
        case .failed(let message):
            editorAutosaveStop = .failed(message)
            syncManager.banner = editorAutosaveStop?.banner(name: editorDocument.name)
            return confirmLeavingAnUnwrittenDocument()
        case .savedUnchecked(let clause):
            // On disk, but unchecked and unstamped: asked about as an unwritten document, since
            // nothing can say the file holds this text.
            editorAutosaveStop = .unchecked(clause)
            syncManager.banner = editorAutosaveStop?.banner(name: editorDocument.name)
            return confirmLeavingAnUnwrittenDocument()
        }
    }

    /// The unsaved-changes question, for a document autosave is not going to write: blocked or
    /// failed, or switched off for this file. The choice is the same either way: write over what
    /// is there, keep the document open, or lose the typing.
    private func confirmLeavingAnUnwrittenDocument() -> Bool {
        let isGone = editorDiskWatch.isGone
        let cause = EditorAlerts.leaveCause(isGone: isGone, stop: editorAutosaveStop,
                                            autosaveOff: !editorAutosavePolicy.isOn(editorDocument.path))
        switch EditorAlerts.askAboutUnsavedChanges(name: editorDocument.name, cause: cause) {
        case .cancel: return false
        case .discard:
            editorAutosaveStop = nil
            // **The undo history goes with the discarded typing.** The file on disk holds text
            // from before those edits, while the stack's registrations were made against the text
            // after them: the mismatch `EditorUndoStore` refuses.
            if let path = editorDocument.path {
                editorUndoStore.forget(path)
                // And the caret, for the same reason: an offset into the discarded text names a
                // place that no longer exists. Clamping would stop a crash, not the wrong place.
                editorDocument.caretAnchors.forget(path)
            }
            return true
        case .save:
            // A file that is gone is written back as Save Again writes it (looking first, and
            // making its folder again) rather than asked about a second time.
            if isGone { return saveEditorDocumentAgain(explicit: true) }
            // "Save" here means "overwrite what is on disk". Routed through the divergence alert,
            // so the destructive answer keeps the confirmation it has everywhere else.
            return saveEditorDocument()
        }
    }

    /// The question for a file that is gone with nothing typed. Save is Save Again: if a file has
    /// turned up at the path meanwhile, nothing is written and the watch shows it, and if it can't
    /// be written, nothing closes. A read-only file can't be written back, so it only asks whether
    /// to leave.
    private func confirmLeavingTheOnlyCopy() -> Bool {
        let name = editorDocument.name, path = editorDocument.path ?? ""
        let answer = editorDocument.isReadOnly
            ? EditorAlerts.askAboutLeavingAGoneReadOnlyFile(name: name)
            : EditorAlerts.askAboutTheOnlyCopy(name: name)
        switch answer {
        case .cancel:
            Logger.shared.info("Editor kept \(path) open — it is no longer on disk, and its text may be the only copy")
            return false
        case .discard:
            Logger.shared.warning("Editor left \(path) without saving it again — it was no longer on disk")
            editorAutosaveStop = nil
            return true
        case .save:
            return saveEditorDocumentAgain(explicit: true)
        }
    }

    /// The hand-off: "Open in Edit" from any file row, anywhere in the app. The act and its order
    /// (settle first, Cancel means nothing happened, then the pane, the workspace, the load, one
    /// log line) are `EditorHandOffRun.run`'s; this supplies the window's pieces.
    ///
    /// - Parameter pane: what happens to the left pane: `nil` for the in-app doors, which take
    ///   ``EditorHandOffRun/pane(forDoorIn:isReviewing:)``'s answer for their workspace. Compare's
    ///   list of differences passes `.staysPut`, since its left pane is half the comparison; a file
    ///   from Finder passes `ExternalOpen.pane`'s.
    ///
    /// Unless the settle was cancelled, the pane then owes the file a selection: where it shows the
    /// file's folder (always, after a re-root), the document is selected and brought into view.
    @discardableResult
    func handOffToEditor(_ path: String, pane: EditorHandOffRun.Pane? = nil) -> EditorHandOffRun.Outcome {
        // Asked of the workspace the door is in, before `showEdit` leaves it.
        let pane = pane ?? EditorHandOffRun.pane(forDoorIn: selectedWorkspace, isReviewing: reviewStore.isReviewing)
        let outcome = EditorHandOffRun.run(
            path, pane: pane,
            syncManager: syncManager,
            paneRoot: (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath,
            openDocument: editorOpenPath, isRefused: editorOpenIsRefused,
            // The folder the pane will show IN EDIT, whichever workspace this is pressed from.
            paneFolder: { leftPaneFolder(in: .editor) },
            settle: { settleEditorDocument(thenRetry: { handOffToEditor(path, pane: pane) }) },
            endNaming: { editorIsNaming = false },
            showEdit: { if selectedWorkspace != .editor { selectedWorkspace = .editor } },
            load: { loadIntoEditor(path: $0) },
            log: { Logger.shared.info($0) },
            followFolder: { followFolderInTabs($0, keepsSource: pane == .followsOnItsSource) })
        if outcome != .cancelled { owePaneSelection(path) }
        return outcome
    }

    // MARK: - The pane follows the file, by tab

    /// The left pane's tabs as ``EditorTabFollow`` reads them: each one's root, tilde-expanded, and
    /// where it is under it. The active one comes from the LIVE pane, since its strip entry is a
    /// stale parked snapshot (`saveBrowseTabs`). A parked tab on a source the pane can no longer
    /// show is no candidate: switching to it would discard it (`tabAction`'s `.unavailable`).
    func leftPaneTabsForFollow() -> (active: EditorTabFollow.Tab, others: [EditorTabFollow.Tab]) {
        let list = syncManager.paneTabs(isLeft: true)
        func root(_ providerId: String) -> String {
            (settings.rootPath(for: providerId) as NSString).expandingTildeInPath
        }
        let current = paneProviderId(isLeft: true)
        let active = EditorTabFollow.Tab(id: list.active.id, root: root(current),
                                         location: syncManager.combinedRelativePath(isLeft: true), providerId: current)
        let others = list.tabs.filter { $0.id != list.active.id && paneCanShowSource($0.providerId) }.map {
            EditorTabFollow.Tab(id: $0.id, root: root($0.providerId), location: $0.combinedRelativePath,
                                providerId: $0.providerId)
        }
        return (active, others)
    }

    /// `folder` under `root`, both resolved first, as `sourceRoute` reads them, so "a tab is
    /// already here" and "this source owns it" agree about one folder reached two ways
    /// (`~/OneDrive/…` and `~/Library/CloudStorage/OneDrive-…/…`). iCloud Drive's linked Desktop
    /// and Documents are followed as `PaneLogic.relativePath` follows them.
    static func followRelative(_ folder: String, _ root: String) -> String? {
        // `resolved("")` is the process's working directory, not "no folder".
        guard !folder.isEmpty, !root.isEmpty else { return nil }
        return PaneLogic.relativePath(of: resolved(folder), under: resolved(root))
    }

    /// Which configured source owns `folder`, and where in it: the sidebar's rule
    /// (``ExternalOpen/route(toFolder:claims:roots:resolve:)``).
    func sourceRoute(toFolder folder: String) -> ExternalOpen.SourceRoute? {
        let providers = folderSidebarProviders
        let roots = Dictionary(providers.map { ($0.id, ($0.rootPath as NSString).expandingTildeInPath) },
                               uniquingKeysWith: { first, _ in first })
        return ExternalOpen.route(toFolder: folder,
                                  claims: Self.folderSidebarClaims(providers, links: PathBoundary.discoveredLinkedFolders),
                                  roots: roots, resolve: Self.resolved)
    }

    /// The hand-off's pane move: the tab showing the file's folder, or a new one
    /// (``EditorTabFollow`` holds the rule). Every write goes through the strip's own tab verbs,
    /// `selectTab` and `tabAction` around `openTab`, so a tab on another source adopts it as a chip
    /// click does, and the strip is saved.
    ///
    /// - Parameters:
    ///   - purpose: what the move is for, for the log: a file being opened, or the one ⌘N is
    ///     about to make.
    ///   - keepsSource: `EditorHandOffRun.Pane.followsOnItsSource`: from Compare or Organize the
    ///     pane follows only on the source it is on.
    func followFolderInTabs(_ folder: String, for purpose: String = "the file Edit is opening",
                            keepsSource: Bool = false) {
        // The tab verbs refuse while the sources are still being set up (`tabAction`); said here,
        // so the log does not claim a switch that never happened.
        guard !isBootstrappingProviders else {
            Logger.shared.info("[pane-follow] \(folder): the sources are still being set up — the pane stays where it is")
            return
        }
        let (active, others) = leftPaneTabsForFollow()
        let decision = EditorTabFollow.decide(
            folder: folder, active: active, others: others, keepsSource: keepsSource,
            relative: Self.followRelative, route: { sourceRoute(toFolder: $0) })
        switch decision {
        case .inPlace:
            break
        case .switchTo(let id):
            Logger.shared.info("[pane-follow] \(folder) is open in another tab — switching to it for \(purpose)")
            selectTab(id: id, isLeft: true)
        case .open(let route):
            openTabAtRoute(route, isLeft: true, log: "[pane-follow] Opened a tab at \(folder) for \(purpose)")
        case .nowhere:
            Logger.shared.info(keepsSource
                ? "[pane-follow] \(folder) is outside the left pane's source, which a move from Compare or Organize keeps — the pane stays where it is"
                : "[pane-follow] \(folder) is in no source SyncCloud has — the pane stays where it is")
            return
        }
        // After the move, against the tab now live: Tree lists its scope only.
        let root = (settings.rootPath(for: paneProviderId(isLeft: true)) as NSString).expandingTildeInPath
        if EditorTabFollow.needsRerootInPlace(folder: folder, editShows: leftPaneFolder(in: .editor), root: root,
                                              relative: Self.followRelative) {
            EditorHandOffRun.focusPane(on: folder, root: root, syncManager: syncManager)
        }
    }

    /// The files after the first, each waiting in the file pane: in the folder already on screen,
    /// in a tab already showing its folder, or in a new tab opened behind the live one with its
    /// files selected (`ExternalOpen.waitingFolders`). Asked of the pane as the hand-off left it.
    /// Returns the files whose folder is in no source.
    ///
    /// Never confined to the pane's source, even from Organize: a tab opened behind the live one
    /// changes nothing the pane holds until it is chosen.
    func openWaitingTabs(for files: [String]) -> [String] {
        var waiting: [PaneTab] = []
        var inOpenTabs: [String] = []
        var unplaced: [String] = []
        let (active, others) = leftPaneTabsForFollow()
        let current = paneProviderId(isLeft: true)
        for group in ExternalOpen.waitingFolders(files) {
            switch EditorTabFollow.decide(folder: group.folder, active: active, others: others,
                                          relative: Self.followRelative, route: { sourceRoute(toFolder: $0) }) {
            case .inPlace, .switchTo:
                inOpenTabs += group.files
            case .open(let route):
                waiting.append(Self.tabAtRoute(route, selecting: Set(group.files)))
            case .nowhere:
                unplaced += group.files
            }
        }
        if !waiting.isEmpty {
            syncManager.openTabsInBackground(waiting, isLeft: true, currentProviderId: current)
            saveBrowseTabs(isLeft: true)
            Logger.shared.info("[open] Opened \(waiting.count) tab(s) behind the open file, one per folder: "
                + waiting.flatMap(\.selection).sorted().joined(separator: ", "))
        }
        if !inOpenTabs.isEmpty {
            Logger.shared.info("[open] \(inOpenTabs.count) file(s) wait in a tab already showing their folder: "
                + inOpenTabs.joined(separator: ", "))
        }
        return unplaced
    }

    /// Files from Finder, the Dock or `open -a`, taken from the delegate's queue and opened through
    /// ``handOffToEditor(_:pane:)``, the door of every "Open in Edit", so a file from outside
    /// settles the open document, moves the pane and logs as ⌘O does. Called on every arrival and
    /// whenever a hold clears. The act itself is ``ExternalOpen/run(_:superseded:isFolder:handOff:placeRest:paneIsFolded:banner:setBanner:log:)``.
    func openExternalArrivals() {
        // An earlier arrival's hand-off is waiting on the unsaved-changes question; this one is
        // taken at the bottom of that call.
        guard !externalOpens.isOpening, !externalOpens.isEmpty else { return }
        if let hold = ExternalOpen.hold(launchIsFinished: launchBootstrap.isFinished,
                                        isPickingDestination: pendingDestination != nil,
                                        isAnsweringDivergence: editorDivergenceReview != nil) {
            Logger.shared.info("[open] A file from outside the app is \(hold.reason)")
            return
        }
        guard let (batch, superseded, atLaunch) = externalOpens.takeNewest() else { return }
        externalOpens.isOpening = true
        closeViewersForExternalOpen()
        let pane = ExternalOpen.pane(workspace: selectedWorkspace, isReviewing: reviewStore.isReviewing,
                                     atLaunch: atLaunch)
        let result = ExternalOpen.run(
            batch, superseded: superseded,
            isFolder: ExternalOpen.isFolder,
            handOff: { handOffToEditor($0, pane: pane) },
            placeRest: { openWaitingTabs(for: $0) },
            // Folded: a launch opens Edit wide (below), and Just the text already is.
            paneIsFolded: atLaunch || editorPaneIsFolded,
            banner: { syncManager.banner },
            setBanner: { syncManager.banner = $0 },
            log: { Logger.shared.info($0) })
        // A launch from Finder opens Edit wide: the document, and nothing beside it.
        if atLaunch, let outcome = result.outcome, outcome != .cancelled { openEditWideForLaunchFromFinder() }
        if let path = result.plan.opens, result.outcome == .opened { fetchExternalOpenFromCloud(path) }
        externalOpens.isOpening = false
        // Anything that arrived while the question was up.
        if !externalOpens.isEmpty { openExternalArrivals() }
    }

    /// What would stand between the user and the file they double-clicked, put away first:
    /// Settings and Help, which hold no work, and the two pair viewers, which their own door
    /// re-opens. The setup form stays (it can hold a half-answered questionnaire) and the file
    /// opens under it. A destination pick or the divergence diff is a question mid-answer, so the
    /// open waits for it instead (``ExternalOpen/Hold``).
    func closeViewersForExternalOpen() {
        var closed: [String] = []
        if showSettings { showSettings = false; closed.append("Settings") }
        if showHelp { showHelp = false; closed.append("Help") }
        if compareDifferencePair != nil { compareDifferencePair = nil; closed.append("the side-by-side comparison") }
        if compareFilePair != nil { compareFilePair = nil; closed.append("Compare Copies") }
        if !closed.isEmpty {
            Logger.shared.info("[open] Closed \(closed.joined(separator: ", ")) to show the file from outside the app")
        }
        if showSetup || shouldAutoShowSetup {
            Logger.shared.info("[open] The file from outside the app opens under the setup form, which stays")
        }
    }

    /// A rail row's file as the node Browse's Rename and Delete take — a file, by its path.
    static func editorRailNode(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false)
    }

    /// Download, from Edit: the Files list's row menu, the file name's menu and the Download
    /// button on a refused card. Browse's own verb first (`CloudDownloadRequest`), so the left
    /// pane's cloud badge clears as for Browse's Download; then the external open's fetch-then-open
    /// wait (`ExternalOpen.fetch`), whose one-byte read reaches a provider even where Browse's verb
    /// is refused (measured on iCloud and Google Drive, not Dropbox or OneDrive).
    ///
    /// The file opens on arrival only if Edit is still showing its refusal, as in
    /// ``fetchExternalOpenFromCloud(_:)``: a reader who has moved on is not moved back. Any other
    /// row is re-listed, so it stops being dim.
    static let editDownloadWait: Duration = .seconds(600)

    func downloadFromEdit(_ path: String) {
        let name = ExternalOpen.name(path)
        let opensOnArrival = editorOpenPath == path && editorOpenIsRefused
        Logger.shared.info("[edit] Download of \(path) from Edit\(opensOnArrival ? " — it opens when it arrives" : "")")
        // The pane Edit shows is the left one, in the window's layout: File ▸ Download's token.
        // A refusal does nothing here, not Browse's reveal in Finder: the fetch below reaches
        // every provider and opens the file in Edit, and Finder over Edit would contradict the note.
        CloudDownloadRequest.requestDownload(path: path, name: name,
                                             from: PaneToken(isLeft: true, isSingleSource: layoutMode == .singleSource),
                                             whenUnavailable: { _ in })
        let note = OperationBanner.warning(opensOnArrival ? "Downloading “\(name)” — it opens here when it arrives."
                                                          : "Downloading “\(name)”…", log: .info)
        syncManager.banner = note
        Task { @MainActor in
            // Ten minutes, not the external open's one: Download was asked for here, and a large
            // file on a slow link can take longer than a minute while still downloading.
            let landed = await ExternalOpen.fetch(path, timeout: Self.editDownloadWait)
            await refreshEditorRail()
            // Our own note goes; anything posted over it since is left alone.
            if syncManager.banner?.id == note.id { syncManager.banner = nil }
            guard landed else {
                Logger.shared.warning("[edit] \(path) did not arrive from the cloud within ten minutes")
                syncManager.banner = .error("Couldn’t download “\(name)”. Download it in Finder, then open it again.", log: .loggedAtSite)
                return
            }
            guard editorOpenPath == path, editorOpenIsRefused else {
                Logger.shared.info("[edit] \(path) arrived from the cloud")
                return
            }
            Logger.shared.info("[edit] \(path) arrived from the cloud — opening it")
            openInEditor(path: path)
        }
    }

    /// A file from Finder that is still in the cloud is fetched, then opened, where every in-app
    /// door shows "Not downloaded" and stops: a double-click asked for its contents.
    ///
    /// Only when the hand-off left exactly that refusal on screen. When the content lands, the
    /// file is opened again through ``openInEditor(path:selectsInPane:)``, which lets a refused
    /// document through, but only if it is still the refused document: a user who has moved on is
    /// not moved back.
    func fetchExternalOpenFromCloud(_ path: String) {
        guard editorOpenPath == path, editorOpenIsRefused,
              MaterializationStatus.isCloudOnly(atPath: MaterializationStatus.linkTarget(of: path)) else { return }
        let name = ExternalOpen.name(path)
        Logger.shared.info("[open] \(path) is still in the cloud — fetching it before Edit can read it")
        syncManager.banner = .warning("Downloading “\(name)” — it opens here when it arrives.", log: .info)
        Task { @MainActor in
            let landed = await ExternalOpen.fetch(path)
            guard editorOpenPath == path, editorOpenIsRefused else {
                Logger.shared.info("[open] \(path) \(landed ? "arrived" : "did not arrive"); Edit has moved on, so it is left")
                return
            }
            if landed {
                Logger.shared.info("[open] \(path) arrived from the cloud — opening it")
                openInEditor(path: path)
            } else {
                Logger.shared.warning("[open] \(path) did not arrive from the cloud within a minute")
                syncManager.banner = .error("Couldn’t download “\(name)”. Download it in Finder, then open it again.", log: .loggedAtSite)
            }
        }
    }

    // MARK: - Closing

    /// File ▸ Close Document's action, or `nil` (greying the item) unless Edit is on screen with a
    /// document open (``EditorDocumentClose/isOffered(workspace:hasDocument:)``).
    var shortcutCloseDocument: (() -> Void)? {
        guard EditorDocumentClose.isOffered(workspace: selectedWorkspace,
                                            hasDocument: editorOpenPath != nil) else { return nil }
        return { closeEditorDocument() }
    }

    /// The header's × and File ▸ Close Document: settle, unload to the empty state, and clear the
    /// pane selection that named the file so clicking its row opens it again. The act itself is
    /// ``EditorDocumentClose/run(document:undoStore:settle:paneSelection:setPaneSelection:log:)``;
    /// this supplies the window's pieces and clears what was about the closed document (a stop, a
    /// diff overlay).
    ///
    /// The pane's selection is written directly, the one exception to `paneSelectionBinding`: the
    /// close only EMPTIES a selection naming the closed file, and every rule the binding adds is
    /// about a pick.
    func closeEditorDocument() {
        // A PDF has nothing to settle but a pending reorder or a running tool; its own close
        // releases its pages.
        if editorPDF.path != nil {
            guard editorPDF.tools.mayLeave(thenRetry: { closeEditorDocument() }) else { return }
            EditorOpenRoute.closePDF(editorPDF,
                                     paneSelection: { syncManager.selectedLeftPaths },
                                     setPaneSelection: { syncManager.selectedLeftPaths = $0 },
                                     log: { Logger.shared.info($0) })
            return
        }
        guard EditorDocumentClose.run(
            document: editorDocument, undoStore: editorUndoStore,
            settle: { settleEditorDocument() },
            paneSelection: { syncManager.selectedLeftPaths },
            setPaneSelection: { syncManager.selectedLeftPaths = $0 },
            log: { Logger.shared.info($0) }) else { return }
        editorAutosaveStop = nil
        editorDivergenceReview = nil
    }

    /// The reverse hand-off: Browse, pointed at the folder of `path`: the open document from the
    /// header's name, any row from the rail row menu. It does NOT close the document, so coming
    /// back with ⌘4 finds it as you left it, unsaved edits and all.
    ///
    /// The pane moves as BROWSE draws it (`EditorRevealInBrowse.movePane`), then the workspace
    /// switches, then the selection is owed, after the switch, so Browse's pane takes it and a
    /// selection there opens nothing. The order lives, tested, in `EditorRevealInBrowse.reveal`.
    ///
    /// `companions` and `replaces` are a PDF batch's: its other copies beside `path`, and the set
    /// it was run on (``PaneSelectionDebt``). Every other door passes neither.
    func revealInBrowse(_ path: String, with companions: [String] = [], replacing replaces: Set<String> = [],
                        from door: EditorRevealInBrowse.Door) {
        EditorRevealInBrowse.reveal(
            path, from: door, syncManager: syncManager,
            sourceRoot: (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath,
            drawsColumns: viewMode(in: .browse, isLeft: true) == .columns,
            showBrowse: { selectedWorkspace = .browse },
            owe: { owePaneSelection($0, with: companions, replacing: replaces) },
            log: { Logger.shared.info($0) })
    }

    // MARK: - The Text and Markup menus

    /// What Text ▸ and Markup ▸ may do to the open document: `nil` unless Edit is on screen with a
    /// document in it, which greys both menus at once. Edit must be the WORKSPACE: the document
    /// outlives a workspace switch, and Markup ▸ Bold must not reach text that is not on screen.
    var shortcutEditorVerbs: EditorVerbs? {
        guard let path = editorDocument.path,
              EditorVerbs.isOffered(workspace: selectedWorkspace, hasDocument: true,
                                    isRefused: editorDocument.refusal != nil) else { return nil }
        let isMarkdown = editorDocument.isMarkdown
        // The mode being drawn, so the tick agrees with the capsule on a plain-text file, and the
        // verbs that need a text view are withheld in Preview, where none is on screen.
        let drawn = EditorMode.resolved(editorMode, isMarkdown: isMarkdown)
        // Preview editable: the workspace's own rule, on the 256 KB decision it holds
        // (`PreviewLengthHold`). The length is read only when no decision is held, and never
        // observed, so a keystroke re-renders nothing here.
        let previewEditing = EditorWorkspaceView.editsInPreview(
            preference: editsInPreviewSetting, hasDocument: true, isRefused: false, isMarkdown: isMarkdown,
            isReadOnly: editorDocument.isReadOnly, mode: drawn,
            isTooLong: PreviewLengthHold.isTooLong(
                editorPreviewLengthHold,
                key: PreviewLengthHold.Key(path: path, mode: drawn, editing: editsInPreviewSetting),
                length: { editorDocument.buffer.source.textStorage.length }))
        let showsSwitch = EditorWorkspaceView.showsAutosaveSwitch(
            hasPath: true, wasRefused: false, isReadOnly: editorDocument.isReadOnly)
        return EditorVerbs(
            mode: drawn,
            canPreview: isMarkdown,
            setMode: { mode in
                // Refused rather than narrowed: a Preview request on a `.txt` must not "succeed"
                // by showing Source. The item is disabled for it too; this is the rule under it.
                guard EditorModeSwitch.accepts(mode, isMarkdown: isMarkdown) else { return }
                editorMode = mode
            },
            // The header's switch and this item are one setting with two doors; switching back on
            // writes what is already pending (`EditorWorkspaceView.autosaveSwitch`).
            autosave: showsSwitch
                ? EditorVerbs.AutosaveSwitch(isOn: editorAutosavePolicy.isOn(path)) {
                    if editorAutosavePolicy.toggle(path) { runAutosave() }
                }
                : nil,
            canMarkUp: EditorVerbs.canMarkUp(isReadOnly: editorDocument.isReadOnly, isMarkdown: isMarkdown,
                                             hasTextView: EditorVerbs.hasTextView(in: drawn, previewEditing: previewEditing)),
            canFind: EditorVerbs.hasTextView(in: drawn, previewEditing: previewEditing),
            // Source and Split only, the status line's own rule, so the item and "Line, Col" are
            // live together. The counter opens the workspace's field.
            goToLine: EditorWorkspaceView.offersGoToLine(drawn) ? { editorGoToLineRequest &+= 1 } : nil)
    }

    /// ⌘F, ⌘G, ⇧⌘G and ⌘E over the open PDF: `nil` unless Edit is on screen with a PDF open in it
    /// (`PDFFindVerbs.isOffered`). ``shortcutEditorVerbs`` stays `nil` while a PDF is open, since
    /// the text document is empty then.
    ///
    /// Reads the facts, not the find's own state, so a match landing re-renders nothing here.
    var shortcutPDFFind: PDFFindVerbs? {
        guard PDFFindVerbs.isOffered(workspace: selectedWorkspace, hasPDF: editorPDF.path != nil,
                                     phase: editorPDF.phase) else { return nil }
        let pdf = editorPDF
        return PDFFindVerbs(isSearchable: pdf.facts?.hasText == true,
                            show: { pdf.find.show() },
                            step: { pdf.find.step(forward: $0) },
                            useSelection: { pdf.find.useSelection(pdf.view.selectedText()) })
    }

    /// ⌘+, ⌘− and ⌘0 on the open PDF's zoom: `nil` unless Edit is on screen with a PDF open in it
    /// AND its pages have the keyboard (`PDFZoomVerbs.isOffered`). Otherwise the same keys are
    /// View ▸ Text Size, as everywhere else.
    var shortcutPDFZoom: PDFZoomVerbs? {
        PDFZoomVerbs.resolve(workspace: selectedWorkspace, pdf: editorPDF, readerHasFocus: editorPDFReaderFocused)
    }

    /// File ▸ PDF Tools: the open PDF's tools, `nil` unless Edit is on screen with a PDF open or
    /// locked (`PDFToolsMenu.isOffered`), which is where the header draws its Tools menu.
    var shortcutPDFTools: EditorPDFTools? {
        guard PDFToolsMenu.isOffered(workspace: selectedWorkspace, hasPDF: editorPDF.path != nil,
                                     phase: editorPDF.phase) else { return nil }
        return editorPDF.tools
    }

    /// Text ▸ Fit Page / Fit Width / Actual Size, the zoom and Go to Page…: `nil` unless Edit is on
    /// screen with a PDF open (`PDFPageVerbs.isOffered`). Go to Page… only where the capsule draws
    /// its page field: a PDF with pages.
    var shortcutPDFPage: PDFPageVerbs? {
        guard PDFPageVerbs.isOffered(workspace: selectedWorkspace, hasPDF: editorPDF.path != nil,
                                     phase: editorPDF.phase) else { return nil }
        let view = editorPDF.view
        return PDFPageVerbs(view: view,
                            goToPage: (editorPDF.facts?.pageCount ?? 0) > 0 ? { view.requestPageField() } : nil)
    }

    /// File ▸ Fill & Sign and Save Filled Copy: the open PDF's own, `nil` unless Edit is on screen
    /// with a PDF open (`PDFFillSignVerbs.isOffered`), which is where the header draws the button.
    var shortcutPDFFill: PDFFillSignVerbs? {
        guard PDFFillSignVerbs.isOffered(workspace: selectedWorkspace, hasPDF: editorPDF.path != nil,
                                         phase: editorPDF.phase) else { return nil }
        return PDFFillSignVerbs(fill: editorPDF.fill, tools: editorPDF.tools)
    }

    /// Text ▸ Expand ⌃⌘E: the header button's bit and act, offered where the header draws the
    /// button (`EditorExpandSwitch.isOffered`). The act is the button's own `toggleJustTheText`, so
    /// the two cannot fold different things.
    var shortcutEditorExpand: EditorExpandSwitch? {
        guard EditorExpandSwitch.isOffered(workspace: selectedWorkspace,
                                           hasDocument: editorOpenPath != nil,
                                           isOn: editorIsExpanded) else { return nil }
        return EditorExpandSwitch(isOn: editorIsExpanded) { toggleJustTheText() }
    }

    // MARK: - Saving

    /// ⌘S, live whenever there is a writable document, even a clean one: it means "write it now,
    /// and settle whatever is blocking that", and people reach for it when autosave has stopped.
    var shortcutSaveDocument: (() -> Void)? {
        guard editorDocument.path != nil, !editorDocument.isReadOnly else { return nil }
        return { _ = saveEditorDocument() }
    }

    /// ⌘S: write the document now, asking about a divergence if there is one.
    ///
    /// - Returns: `false` when the file does not hold the document afterwards: nothing was written,
    ///   and something needed to be. A clean document with nothing stopped is `true` with no write.
    @discardableResult
    func saveEditorDocument() -> Bool {
        // The disk watch looks first when the file has moved under the stamp, so a move is
        // followed and a re-stamp over the same contents taken rather than asked about. A real
        // change raises its banner, and the question below is still asked, since ⌘S asked to write.
        if let path = editorDocument.path, let stamp = editorDocument.stamp,
           EditorFileStore.divergence(atPath: path, from: stamp) != nil {
            // Autosave's own write, landed and not yet committed, is not a change from elsewhere.
            // It is committed here with the host's half of a write, and the question below then
            // compares against the stamp it left.
            if EditorAutosave.settleLandedWrite(into: editorDocument) {
                _ = writeEditorDocumentDidWrite()
            } else {
                editorDiskWatch.reconcile()
            }
        }
        guard let path = editorDocument.path, let stamp = editorDocument.stamp,
              !editorDocument.isReadOnly else { return false }
        // Re-stat before writing: the file may have been filed, renamed or edited since it was
        // opened, even by this window's Organize run. The stamp is kept: it is the version the
        // question is about, and Keep Mine replaces that one and no later one.
        let seen = EditorFileStore.stamp(ofPath: path)
        if let divergence = EditorFileStore.divergence(of: seen, from: stamp) {
            return applyDivergenceAnswer(
                EditorAlerts.askAboutDivergence(name: editorDocument.name, divergence: divergence),
                divergence: divergence, path: path, explicit: true, seen: seen)
        }
        // Nothing changed, nothing written: a rewrite would only give the file a new date and a
        // sync client a reason to upload it. After the divergence check, so a changed file is still
        // asked about; only with no stop, so a stopped autosave's ⌘S still writes. Not in
        // `writeEditorDocument`, which Keep Mine and Save Again need to write whatever the buffer is.
        if Self.saveHasNothingToWrite(isDirty: editorDocument.isDirty, stop: editorAutosaveStop) {
            Logger.shared.debug("Editor saved nothing to \(path) — it already holds the document")
            return true
        }
        return writeEditorDocument(explicit: true)
    }

    /// Whether ⌘S has nothing to write: the buffer is the file's text and no stop stands. A stop
    /// (a failed or unchecked write, a divergence) is ⌘S's to settle, so it always writes.
    static func saveHasNothingToWrite(isDirty: Bool, stop: EditorAutosaveStop?) -> Bool {
        !isDirty && stop == nil
    }

    // MARK: - Which version wins

    /// A divergence question that has been detoured into the diff overlay, carried so the answer
    /// comes back to the path that asked. `explicit` separates ⌘S and the header's door (logged at
    /// INFO) from the autosave timer (DEBUG), so the overlay's Keep Mine… logs in the right one.
    struct EditorDivergenceReview: Equatable {
        var divergence: EditorFileStore.Divergence
        var explicit: Bool
        /// The document the diff is ABOUT. The overlay's scrim absorbs clicks but the menu bar
        /// stays live, so another file can be opened meanwhile; Keep Mine… must not write it. The
        /// answer is refused instead (``answerEditorDivergenceDiff(_:)``).
        var path: String
        /// The disk's stamp as the diff was opened: the right-hand version, which Keep Mine…
        /// agrees to replace. A version arriving while the diff is up is kept aside by the write,
        /// not deleted.
        var seen: EditorFileStore.Stamp?
    }

    /// The one place a divergence answer is acted on, from the alert, the overlay's foot and the
    /// header's door, so no caller can answer one of the four cases differently.
    ///
    /// - Parameter seen: the disk's stamp when the question was put. Keep Mine consents to
    ///   replacing that version only, so one that arrives while the question is up is kept aside
    ///   by the write, not deleted unseen.
    /// - Returns: whether anything was WRITTEN, so `false` for the detour, which resolves nothing.
    @discardableResult
    func applyDivergenceAnswer(_ answer: EditorAlerts.DivergenceAnswer,
                               divergence: EditorFileStore.Divergence,
                               path: String, explicit: Bool, seen: EditorFileStore.Stamp?) -> Bool {
        switch answer {
        case .saveAnyway:
            // A gone file's Save Again is the banner's: it looks before it writes, and makes the
            // folder again if that went too.
            if divergence == .missing { return saveEditorDocumentAgain(explicit: explicit) }
            // Keep Mine… asks before it writes, through every door (banner, ⌘S alert, the
            // comparison's foot), here in one place. Declining is Cancel: nothing written, and
            // autosave stays stopped.
            if EditorAlerts.keepMineAsks(for: divergence),
               !EditorAlerts.confirmKeepMine(name: editorDocument.name) {
                editorAutosaveStop = .diverged(divergence)
                return false
            }
            // The disk as it stood when they were ASKED, the version Keep Mine replaces on purpose.
            // Not a stat taken now: a sync landing while the consent alert was up would be "agreed
            // to" unseen.
            return writeEditorDocument(explicit: explicit, consentedTo: seen)
        case .reloadFromDisk:
            // With the disk-change banner up, the reload is "Use Disk Version": the same answer as
            // one step ⌘Z takes back, so the typing can still come back. Every door gets the safer one.
            if editorDiskWatch.banner == .changed {
                if editorDiskWatch.useDisksVersion() == .unreadable { reportDisksVersionUnreadable() }
                return false
            }
            return reloadOverTheBuffer(path: path)
        case .showWhatChanged:
            // **The latch goes on BEFORE the overlay:** while two versions are on screen the
            // debounce must not write one of them, and dismissing the overlay is then Cancel, as
            // Escape must be.
            editorAutosaveStop = .diverged(divergence)
            // Stamped as the diff opens, which is the version it reads for its right-hand side.
            editorDivergenceReview = EditorDivergenceReview(divergence: divergence,
                                                            explicit: explicit, path: path,
                                                            seen: EditorFileStore.stamp(ofPath: path))
            return false
        case .cancel:
            // Declining leaves autosave stopped, and the header says so: typing is not reaching
            // disk.
            editorAutosaveStop = .diverged(divergence)
            return false
        }
    }

    /// The header's amber words, clicked. Re-reads the stop rather than trusting the caller: the
    /// closure is built while the header renders and the stop can have been settled since.
    func showEditorDivergenceDiff() {
        guard case .diverged(let divergence) = editorAutosaveStop, divergence == .changed,
              let path = editorDocument.path else { return }
        applyDivergenceAnswer(.showWhatChanged, divergence: divergence, path: path, explicit: true, seen: nil)
    }

    /// The overlay's foot, answered: the same three answers, through the alert's function, never
    /// a second write path.
    func answerEditorDivergenceDiff(_ verdict: EditorDivergenceVerdict) {
        guard let review = editorDivergenceReview else { return }
        // Cleared FIRST: every branch below wants the overlay gone, and clearing after would leave
        // it over a document already reloaded out from under it.
        editorDivergenceReview = nil
        // **The answer is about the file the diff showed, and only that one.** Another document
        // can have been opened from the menu bar meanwhile, and Keep Mine… would overwrite it.
        // Dropping the answer writes nothing and leaves the open document's stop as it is.
        guard editorDocument.path == review.path else {
            Logger.shared.info(
                "Editor discarded a divergence answer for \(review.path) — the open document is now \(editorDocument.path ?? "none")")
            return
        }
        applyDivergenceAnswer(EditorAlerts.divergenceAnswer(for: verdict),
                              divergence: review.divergence,
                              path: review.path, explicit: review.explicit, seen: review.seen)
    }

    /// The write itself, with no questions in it; ⌘S, Keep Mine and Save Again land here. A
    /// successful write clears the stop, whatever it was: the file on disk is now this buffer.
    @discardableResult
    private func writeEditorDocument(explicit: Bool, consentedTo: EditorFileStore.Stamp? = nil) -> Bool {
        // A write that puts the file BACK (Save Again after it was deleted) is a new file in a
        // folder the panes have walked, and is shown there as ⌘N's is. A rewrite of a listed file is
        // not (`rereadPanesAfterEditorWrite`).
        let recreates = editorDocument.path.map { !FileManager.default.fileExists(atPath: $0) } ?? false
        // Saved and checked, with a displaced version kept beside it: the store has marked the
        // document saved, so this is a save with something to say, not a stop.
        var keptAside: String?
        do {
            do {
                editorDocument.markSaved(stamp: try EditorFileStore.write(editorDocument, consentedTo: consentedTo))
            } catch let failure as EditorFileStore.Failure where failure.landed != nil {
                keptAside = failure.savedBut
            }
            editorAutosaveStop = nil
            // The disk agrees with the document now, so a disk-change banner has nothing to ask.
            editorDiskWatch.reconcile()
            // An explicit save logs at INFO. An autosave logs its document's first at INFO and the
            // rest at DEBUG, counted into one closing line (`EditorAutosaveTally`): one every two
            // seconds of typing would bury the failures below.
            let path = editorDocument.path ?? ""
            noteEditorWrote(path)
            if explicit {
                Logger.shared.info("Editor saved \(path)")
            } else {
                logAutosave(path)
            }
            Task { await refreshEditorRail() }
            if recreates { showCreatedFileInPane(path) }
            if let keptAside {
                syncManager.banner = EditorAutosaveStop.savedBut(name: editorDocument.name, clause: keptAside)
            }
            return true
        } catch {
            // **Banner, never log-only:** a silently failed save costs work the user believes is
            // on disk. One that landed but could not be checked says so, and stops autosave, which
            // has no stamp to write by.
            let stop = EditorAutosaveStop(saveError: error)
            if case .unchecked = stop { editorAutosaveStop = stop }
            syncManager.banner = stop.banner(name: editorDocument.name)
            return false
        }
    }

    // MARK: - Autosave

    /// One autosave attempt: from the debounce, or when autosave resumes or is switched back on.
    ///
    /// The stop latch is checked first, so the divergence alert cannot come back two seconds after
    /// each dismissal: a stop LATCHES until a write succeeds or the user clears it, and ⌘S asks
    /// again deliberately.
    ///
    /// The write runs off the main actor, since it includes an `F_FULLFSYNC` that can take tens of
    /// milliseconds or more, and the debounce fires just as bursty typing resumes. `F_FULLFSYNC`
    /// stays: these are cloud folders, where a half-written file syncs to every other machine. The
    /// latch, alert and banner still happen on the main actor; the outcome describes the snapshot
    /// written, not the buffer as it stands now (`EditorAutosave.Snapshot`).
    func runAutosave() {
        // The switch is checked here, not in the driver, so the timer still runs and only the
        // write is withheld; a file switched back ON mid-edit then saves without another keystroke.
        guard editorAutosavePolicy.isOn(editorDocument.path) else { return }
        guard editorAutosaveStop == nil else { return }
        // One background write at a time: overlapping ones would be safe but wasteful. Typing
        // turned away here is not dropped: the write's commit moves the stamp the debounce is
        // keyed on, which starts the wait again.
        guard !editorIsWritingInBackground else { return }
        guard let snapshot = EditorAutosave.snapshot(of: editorDocument) else { return }
        editorIsWritingInBackground = true
        // **An unstructured `Task`, not the driver's:** the driver's task is cancelled by the next
        // keystroke (that IS the debounce), and a dispatched write must finish and commit.
        Task { @MainActor in
            let outcome = await EditorAutosave.write(snapshot, into: editorDocument)
            editorIsWritingInBackground = false
            applyAutosaveOutcome(outcome)
        }
    }

    /// What an autosave attempt leads to on screen.
    private func applyAutosaveOutcome(_ outcome: EditorAutosave.Outcome) {
        switch outcome {
        case .nothingToDo:
            break
        case .wrote:
            _ = writeEditorDocumentDidWrite()
        case .wroteKeepingAside(let clause):
            // A save, not a stop: written and checked, with the version it displaced kept beside
            // it, said in the banner, while the header goes back to saving.
            _ = writeEditorDocumentDidWrite()
            syncManager.banner = EditorAutosaveStop.savedBut(name: editorDocument.name, clause: clause)
        case .blocked(let divergence):
            // The disk watch answers this first, with its banner rather than a modal. A move it
            // follows is not a divergence, and the write is made again at the new path.
            switch editorDiskWatch.reconcile() {
            case .asked:
                // The stop is re-latched from the banner, which may have stood since before: a
                // settle that cleared the stop would otherwise leave the banner up, autosave free,
                // and Compare (which reads the stop) doing nothing.
                editorDiskBannerDidChange(editorDiskWatch.banner)
                return
            // Followed to its new path, or only re-stamped over the same contents: nothing to ask,
            // and the write is made again.
            case .followed, .restamped, .settled: runAutosave(); return
            default: break
            }
            editorAutosaveStop = .diverged(divergence)
            // Interrupt now. The latch is already set, so declining or asking for the diff leaves
            // the document visibly stopped instead of asking again. The version the alert is
            // about is stamped before it is put.
            let path = editorDocument.path ?? ""
            let seen = EditorFileStore.stamp(ofPath: path)
            applyDivergenceAnswer(
                EditorAlerts.askAboutDivergence(name: editorDocument.name, divergence: divergence),
                divergence: divergence, path: path, explicit: false, seen: seen)
        case .failed(let message):
            // Latched for the same reason: a full disk or a read-only volume fails identically
            // every two seconds, and a banner per attempt would be noise.
            editorAutosaveStop = .failed(message)
            syncManager.banner = editorAutosaveStop?.banner(name: editorDocument.name)
        case .savedUnchecked(let clause):
            // Latched too, and said as what it is: saved, but not checked.
            editorAutosaveStop = .unchecked(clause)
            syncManager.banner = editorAutosaveStop?.banner(name: editorDocument.name)
        }
    }

    /// The host's half of a write autosave has already made and stamped: the log line, the rail,
    /// and clearing any stop.
    private func writeEditorDocumentDidWrite() -> Bool {
        editorAutosaveStop = nil
        editorDiskWatch.reconcile()
        noteEditorWrote(editorDocument.path)
        logAutosave(editorDocument.path ?? "")
        Task { await refreshEditorRail() }
        return true
    }

    /// Both autosave sites' line: Info for the document's first, Debug for the rest.
    private func logAutosave(_ path: String) {
        if EditorAutosaveTally.note(path) == .info {
            Logger.shared.info("Editor autosaved \(path)")
        } else {
            Logger.shared.debug("Editor autosaved \(path)")
        }
    }

    /// Called after a flush that wrote or had nothing to do.
    func noteAutosave() { editorAutosaveStop = nil }

    /// Records a file the editor just wrote over, for Compare, whose list is the last scan's.
    /// Paid on arriving in Compare, or at once if Compare is on screen (`ContentView.OwedComparison`).
    /// A write under neither compared folder is not owed, but its cached walks are dropped here, so
    /// a pane moved to that folder later reads the file as written.
    func noteEditorWrote(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        guard owedComparison.recordWrite(path, leftFolder: currentLeftPath, rightFolder: currentRightPath,
                                         leftLinkTargets: syncManager.leftTreeLinkTargets,
                                         rightLinkTargets: syncManager.rightTreeLinkTargets) else {
            syncManager.prepareReread(afterWritingAt: path)
            return
        }
        if selectedWorkspace == .compare { payOwedComparisonIfNeeded() }
    }

    /// "Use Disk Version" without the banner: throw the buffer away and re-read the file. A named
    /// function because it discards typing on purpose, and the undo stack must go with it: the
    /// text view keeps the same document identity and would otherwise keep registrations made
    /// against the discarded text.
    ///
    /// - Returns: `false` always: nothing was written, and callers asking "did the save happen"
    ///   must not be told it did.
    @discardableResult
    func reloadOverTheBuffer(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        Logger.shared.info("Editor reloaded \(path) from disk, discarding the buffer")
        // Clear the stop BEFORE the load: `loadIntoEditor` re-stamps the document, and a latch
        // left set would silently keep the next keystroke from reaching disk.
        editorAutosaveStop = nil
        // **Forgotten before the load, not cleared after it:** `loadIntoEditor` asks the store for
        // this path's stack, and dropping it here makes that return a fresh one.
        editorUndoStore.forget(path)
        // The caret too, as at the discard site: the file on disk is not the text this anchor was
        // measured against.
        editorDocument.caretAnchors.forget(path)
        // Not a new open: the file was already open, and its place in the recent files stays.
        loadIntoEditor(path: path, recordsRecent: false)
        return false
    }

    // MARK: - Changes from elsewhere (TE59)

    /// Points the disk watch at the document and tells it what the window does about what it
    /// finds. Called on every appearance, since the closures are this view's; the attach itself
    /// happens once.
    func attachEditorDiskWatch() {
        editorDiskWatch.attach(document: editorDocument, undoStore: editorUndoStore)
        editorDiskWatch.onMoved = { old, new, byThisApp in editorDocumentDidMove(from: old, to: new, byThisApp: byThisApp) }
        editorDiskWatch.onBannerChange = { banner in editorDiskBannerDidChange(banner) }
        // The write was on disk as written after all, so there is nothing left to check.
        editorDiskWatch.onUncheckedWriteChecked = {
            if case .unchecked = editorAutosaveStop { editorAutosaveStop = nil }
        }
    }

    /// The open file moved and the document followed it, so the window's path-keyed state goes
    /// with it: the autosave switch, the outline's place, a diff question about it. Then the rail
    /// re-reads its folder, and the panes re-read where the file went and keep it selected.
    ///
    /// Not the lists after the app's own file operation (`byThisApp`): its epilogue has refreshed
    /// both panes and the rail (`refreshEditorAfterFileOperation`), and a second re-read would drop
    /// the walks that refresh is reading and log a write Edit never made.
    func editorDocumentDidMove(from old: String, to new: String, byThisApp: Bool) {
        editorAutosavePolicy.move(from: old, to: new)
        // The recent files list it where it went, by this app or by Finder.
        EditorRecentFiles.shared.move(from: old, to: new)
        EditorOutlineScroll.moveAnchor(in: &editorOutlineAnchors, from: old, to: new)
        if var review = editorDivergenceReview, review.path == old {
            review.path = new
            editorDivergenceReview = review
        }
        let wasSelected = syncManager.selectedLeftPaths == [old]
        if wasSelected { owePaneSelection(new) }
        guard !byThisApp else { return }
        Task { await refreshEditorRail() }
        syncManager.prepareReread(afterWritingAt: old)
        rereadPanesAfterEditorWrite(new, writer: "The open document was moved elsewhere to")
    }

    /// A banner stops autosave, and its going lets it resume: the header's latch, set from the
    /// banner so the two agree. While a change from elsewhere awaits an answer, nothing is written
    /// over either version. Cleared only when the disk agrees with the document again (a reload,
    /// Use Disk Version, Keep Mine, Save Again), not merely because the banner went.
    func editorDiskBannerDidChange(_ banner: EditorDiskBanner?) {
        let diskAgrees = editorDocument.path.flatMap { path in
            editorDocument.diskStamp.map { EditorFileStore.divergence(atPath: path, from: $0) == nil }
        } ?? false
        editorAutosaveStop = Self.autosaveStop(after: banner, current: editorAutosaveStop, diskAgrees: diskAgrees)
    }

    /// The stop a banner leaves (``editorDiskBannerDidChange(_:)``). A failed write's stop is not
    /// the banner's to clear: only a divergence is.
    static func autosaveStop(after banner: EditorDiskBanner?, current: EditorAutosaveStop?,
                             diskAgrees: Bool) -> EditorAutosaveStop? {
        switch banner {
        case .changed: return .diverged(.changed)
        case .deleted: return .diverged(.missing)
        case nil:
            guard case .diverged = current, diskAgrees else { return current }
            return nil
        }
    }

    /// A press on the banner.
    func answerEditorDiskBanner(_ action: EditorDiskBannerAction) {
        switch action {
        case .compare:
            // The diff reads the stop; latched from the banner first, so a stop cleared under a
            // standing banner cannot leave this button doing nothing.
            editorDiskBannerDidChange(editorDiskWatch.banner)
            showEditorDivergenceDiff()
        case .keepMine:
            // The same answer as the alert's and the sheet's Keep Mine…, so it asks the same
            // consent, with the destructive button off Return. Stamped at the click, before the
            // alert: the version on disk as they chose, not one that lands while the alert is up.
            guard let path = editorDocument.path else { return }
            applyDivergenceAnswer(.saveAnyway, divergence: .changed, path: path, explicit: true,
                                  seen: EditorFileStore.stamp(ofPath: path))
        case .useDisks:
            if editorDiskWatch.useDisksVersion() == .unreadable { reportDisksVersionUnreadable() }
        case .close:
            closeEditorDocument()
        case .saveAgain:
            saveEditorDocumentAgain(explicit: true)
        }
    }

    /// Save Again: the banner's, and the ⌘S alert's for a file that is gone. Only while the path is
    /// still empty (a file back there is looked at, not written over), and with its folder made
    /// again if that went too.
    ///
    /// - Returns: whether it wrote.
    @discardableResult
    func saveEditorDocumentAgain(explicit: Bool) -> Bool {
        switch editorDiskWatch.prepareSaveAgain() {
        case .write:
            return writeEditorDocument(explicit: explicit)
        case .notMissing:
            return false
        case .failed(let why):
            syncManager.banner = .error("Couldn’t save “\(editorDocument.name)” — \(why)", log: .error)
            return false
        }
    }

    /// "Use Disk Version" found nothing it could put in the buffer: the file is now unreadable, too
    /// large or not text. Nothing changed; the banner stays, and says so.
    private func reportDisksVersionUnreadable() {
        Logger.shared.warning("[edit] Could not take the version of \(editorDocument.path ?? "") on disk — it cannot be read as text now")
        syncManager.banner = .error("Couldn’t read the version of “\(editorDocument.name)” on disk — your text is unchanged.", log: .loggedAtSite)
    }

    /// After one of the app's own file operations (`refreshSubject`'s epilogue): Edit's rail
    /// re-reads its folder, and the disk watch looks at the open document now (a rename, a move, a
    /// delete, Organize filing it) without waiting for the file-system events to settle.
    ///
    /// The rail only while Edit is on screen; arriving in Edit re-reads it (`editorWorkspace`'s
    /// `.task(id:)`). The subject also fires when a pane moves, where both are cheap and find
    /// nothing new.
    func refreshEditorAfterFileOperation() {
        if Self.railRefreshesAfterFileOperation(workspace: selectedWorkspace) {
            Task { await refreshEditorRail() }
        }
        editorDiskWatch.reconcile(afterOwnFileOperation: true)
    }

    /// Whether a file operation's epilogue re-reads Edit's rail: only where the rail can be seen.
    static func railRefreshesAfterFileOperation(workspace: Workspace) -> Bool {
        workspace == .editor
    }

    // MARK: - Creating

    /// ⌘N, from every workspace, offered always. With no folder in the pane the file goes to Notes,
    /// as one in a system folder does (`EditorNewFileFolder`). From another workspace this makes the
    /// ⌘4 move first, so the file is created in the folder the user was looking at.
    var shortcutNewTextFile: () -> Void {
        {
            // A new file waits with the rest of the window's writes while a long run goes: the
            // empty page's and the rail's buttons reach here without a menu item to grey.
            guard !refusedWhileRunLocked() else { return }
            // Asked of the workspace being LEFT, before the switch below: from Compare the pane
            // is half of the comparison and stays; from Organize it keeps its source.
            editorNewFilePane = ExternalOpen.pane(workspace: selectedWorkspace,
                                                  isReviewing: reviewStore.isReviewing, atLaunch: false)
            // The tab first, so a rail this switch builds starts on Files rather than visibly
            // switching there in its first update. The rail's own `onChange` moves the tab for a
            // ⌘N made with the rail already on screen.
            editorRailTab = .files
            if selectedWorkspace != .editor { selectedWorkspace = .editor }
            // After the switch: `editorFolder` reads the workspace on screen.
            guard takePaneToNotesIfItIsNoPlaceForAFile() else { return }
            editorIsNaming = true
            // Bumped every time, even with the row already open: setting `isNaming` true again is
            // not a change, so `onChange` would not fire and a second ⌘N would not move focus.
            editorNamingFocus &+= 1
        }
    }

    /// Where ⌘N's file goes: the pane's folder, or Notes and why (`EditorNewFileFolder`). Reads the
    /// disk, so it is asked only when ⌘N is pressed, when the file is made, and by the open naming
    /// row. The ＋'s tooltip is drawn always, so it asks ``editorNewFileFolderName`` instead.
    var newTextFileDestination: (folder: String, refusal: EditorNewFileFolder.Refusal?) {
        EditorNewFileFolder.destination(paneFolder: editorFolder, home: NSHomeDirectory(),
                                        isWritable: { FileManager.default.isWritableFile(atPath: $0) },
                                        resolve: { Self.resolved($0) })
    }

    /// "Notes" when the ＋'s tooltip and the naming row must name it instead of the pane's folder:
    /// the path half of the rule only, since this is read on every body pass. A folder that can't
    /// be written to is still named until ⌘N finds out; the pane then goes to Notes.
    var editorNewFileFolderName: String? {
        EditorNewFileFolder.pathRefusal(of: editorFolder, home: NSHomeDirectory()) == nil
            ? nil : EditorNewFileFolder.notesName
    }

    /// ⌘N's first step when the pane's folder is no place for a file: make Notes, and take the pane
    /// there (a tab already showing it, or a new one), so the name is typed where it will land. As
    /// `editorNewFilePane` says, from Compare the pane stays put (the naming row says where the file
    /// goes) and from Organize it follows only on its own source. `false` when Notes could not be
    /// made; ⌘N then opens nothing.
    func takePaneToNotesIfItIsNoPlaceForAFile() -> Bool {
        let paneFolder = editorFolder
        let (folder, refusal) = newTextFileDestination
        guard let refusal else { return true }
        let notes = makeNotesFolder(folder)
        guard notes != .couldNotMake else { return false }
        switch editorNewFilePane {
        case .staysPut:
            Logger.shared.info("[new-file] \(refusal.why(paneFolder)) — ⌘N makes the file in \(folder), and leaves "
                + "the left pane where it is: it is half of the comparison")
        case .followsTheFile, .followsOnItsSource:
            Logger.shared.info("[new-file] \(refusal.why(paneFolder)) — ⌘N makes the file in \(folder)")
            followFolderInTabs(folder, for: "the file ⌘N is about to make",
                               keepsSource: editorNewFilePane == .followsOnItsSource)
        }
        // A folder made just now is in no walk yet, so a pane left on Documents or above would not
        // list it. The pane that holds Notes is re-read, as the move left it.
        if notes == .madeNow { rereadPanesAfterEditorWrite(folder) }
        return true
    }

    /// What ``makeNotesFolder(_:)`` found.
    enum NotesFolder { case alreadyThere, madeNow, couldNotMake }

    /// Makes `~/Documents/Notes` if it is not there. A new folder drops the cached walks that list
    /// its parent, so a pane showing Documents lists it.
    func makeNotesFolder(_ folder: String) -> NotesFolder {
        var isFolder: ObjCBool = false
        // A FILE named Notes falls through to `createDirectory`, which refuses it with a reason.
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue { return .alreadyThere }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            Logger.shared.info("[new-file] Made \(folder)")
            syncManager.prepareReread(afterWritingAt: folder)
            return .madeNow
        } catch {
            Logger.shared.error("[new-file] Couldn't make \(folder): \(error.localizedDescription)")
            syncManager.banner = .error("Couldn’t make the Notes folder — \(error.localizedDescription)", log: .loggedAtSite)
            return .couldNotMake
        }
    }

    /// Creates the named file and opens it, clean.
    ///
    /// - Returns: `false` when nothing was created, so the naming row stays open with the typed
    ///   name: cancelling a question about the previous document must not throw it away.
    @discardableResult
    func createTextFile(named name: String) -> Bool {
        let (folder, refusal) = newTextFileDestination
        // A retry after a filled copy was saved: the naming row is still open, so it closes here.
        guard settleEditorDocument(thenRetry: { if createTextFile(named: name) { editorIsNaming = false } }) else {
            return false
        }
        // Made at ⌘N already; again here for a Notes deleted while the name was being typed.
        if refusal != nil, makeNotesFolder(folder) == .couldNotMake { return false }
        do {
            let path = try EditorFileStore.createEmptyFile(named: name, in: folder)
            Logger.shared.info("Editor created \(path)")
            loadIntoEditor(path: path)
            // ⌘N took the pane to Notes; this is for a pane that could not go, or was moved off it
            // while the name was typed. The pane follows the file by ⌘N's rule (`editorNewFilePane`).
            if refusal != nil, editorNewFilePane != .staysPut {
                followFolderInTabs(folder, keepsSource: editorNewFilePane == .followsOnItsSource)
            }
            // Both lists, whichever is on screen; the pane is re-read even while collapsed, so it
            // is current when next opened.
            Task { await refreshEditorRail() }
            showCreatedFileInPane(path)
            return true
        } catch {
            syncManager.banner = .error("Couldn’t create the file — \(error.localizedDescription)", log: .error)
            return false
        }
    }

    /// What an image dropped on or pasted into the open note left on disk, or why nothing did. The
    /// text view has already linked what was written; this is the host's half.
    ///
    /// A new image is a new file in a walked folder, so it is re-read as ⌘N's file is
    /// (`rereadPanesAfterEditorWrite`), owing a comparison its rescan. A folder this import made is
    /// re-read through its parent, as ⌘N's Notes is. A refusal changed nothing on disk and says so
    /// in the banner.
    func noteEditorImages(_ report: EditorImageImport.Report) {
        switch report {
        case .refused(let reason):
            Logger.shared.warning("[edit] Image not added: \(reason)")
            syncManager.banner = .error(reason, log: .error)
        case .wrote(let files, let madeFolder, let linked, let failed):
            if linked.isEmpty {
                // Nothing linked, but a folder it made could not be taken away again.
                Logger.shared.warning("[edit] Image not added: \(failed ?? "nothing was saved"); left \(madeFolder ?? "nothing")")
            } else {
                Logger.shared.info("[edit] Image added: wrote \(files.count) file(s)"
                    + (madeFolder.map { " and made \($0)" } ?? "") + ", linked \(linked.joined(separator: ", "))"
                    + (failed.map { "; then stopped: \($0)" } ?? ""))
            }
            // Nothing written is past what Preview draws: an import over it is refused whole.
            if let failed { syncManager.banner = .error(failed, log: .error) }
            if let reread = madeFolder ?? files.first { rereadPanesAfterEditorWrite(reread) }
            // The rail lists the note's folder, and an image, or the folder it went in, is a new
            // entry there.
            if !files.isEmpty || madeFolder != nil { Task { await refreshEditorRail() } }
            // A few seconds in the status line: what was saved, and where.
            editorDiskWatch.noteImagesImported(report)
        }
    }

    /// Makes the left pane list a file ⌘N just created, and select it once it does. The open pane
    /// IS Edit's file list (the rail is withheld beside it), so refreshing the rail alone is not
    /// enough.
    ///
    /// The selection is owed, not written now (``owePaneSelection(_:)``): the node does not exist
    /// until the re-read publishes, and a selection naming a row the list lacks is at the mercy of
    /// the `List` and `pruneSelection`. ``settleOwedPaneSelection()`` writes it on the publish that
    /// lists it, including a column's graft, which arrives on its own publish after the walk.
    func showCreatedFileInPane(_ path: String) {
        owePaneSelection(path)
        rereadPanesAfterEditorWrite(path)
    }

    /// The re-read a file Edit put on disk itself needs: the pane that shows it, and nothing more.
    ///
    /// Two halves, neither optional. `prepareReread(afterWritingAt:)` drops the cached walks that
    /// list the file's folder, or a pane would be served a walk taken before the file existed
    /// (`OutOfQueueWriteRereadTests`); it also bumps the scan-config epoch, so a refresh already in
    /// flight cannot swallow this one as a duplicate. Then each pane whose folder holds the file
    /// (`panesHolding`) is reloaded, none when neither does.
    ///
    /// Targeted, unlike a file operation's epilogue, which empties the whole cache and re-compares
    /// both panes: one new file changes one folder. The comparison runs only in Compare; elsewhere
    /// it is owed (`owedComparison`) and made good when Compare is next shown.
    ///
    /// Edit's writes bypass the queue, so a new note never waits behind a long copy. For writes
    /// that ADD a file only (⌘N, Export as PDF): an autosave rewrites a listed file, and is owed to
    /// Compare instead (`noteEditorWrote`).
    ///
    /// - Parameters:
    ///   - writer: who put it there and how, for the log; the destination picker's New Folder and
    ///     a move followed from elsewhere come through here too.
    ///   - comparesInCompare: `false` where something else is about to compare: the picker's New
    ///     Folder, whose transfer compares both panes itself. The pane is re-read and the comparison
    ///     owed, so a declined transfer still lists the folder.
    func rereadPanesAfterEditorWrite(_ path: String, writer: String = "Edit wrote", comparesInCompare: Bool = true) {
        syncManager.prepareReread(afterWritingAt: path)
        guard let scope = Self.panesHolding(path, leftFolder: currentLeftPath, rightFolder: currentRightPath,
                                            leftLinkTargets: syncManager.leftTreeLinkTargets,
                                            rightLinkTargets: syncManager.rightTreeLinkTargets) else {
            Logger.shared.info("\(writer) \(path), which neither pane is showing; re-reading neither")
            return
        }
        if selectedWorkspace == .compare, comparesInCompare {
            // Paid at once, as every write in Compare is: the pane(s) holding it re-read and
            // compared.
            noteEditorWrote(path)
        } else {
            refreshAction(reloading: scope, comparing: false)
            // After the refresh, whose skipped comparison this names: the pane is re-read, so
            // Compare owes only the comparison, not a second walk.
            owedComparison.skipped = OwedComparison.editorWrote(path)
        }
    }

    /// Which panes a file written at `path` belongs in: each pane whose folder holds it (its walk
    /// is deep, so anywhere below counts), or `nil` for neither.
    ///
    /// `leftLinkTargets` / `rightLinkTargets` are where each pane's walk read through a folder
    /// symlink (`FileSyncManager.leftTreeLinkTargets`): a file below such a link is saved where it
    /// leads, under no prefix of the pane's folder. Empty by default for the rule's own tests.
    static func panesHolding(_ path: String, leftFolder: String, rightFolder: String,
                             leftLinkTargets: Set<String> = [], rightLinkTargets: Set<String> = [],
                             links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
    -> FileSyncManager.PaneReloadScope? {
        switch (FileSyncManager.folder(leftFolder, holds: path, links: links, linkTargets: leftLinkTargets),
                FileSyncManager.folder(rightFolder, holds: path, links: links, linkTargets: rightLinkTargets)) {
        case (true, true): return .both
        case (true, false): return .leftOnly
        case (false, true): return .rightOnly
        case (false, false): return nil
        }
    }

    // MARK: - The pane follows the open document (TE47)

    /// A selection the left pane owes: `path`, recorded while `document` was the open document
    /// and `workspace` was on screen.
    ///
    /// The document and workspace are recorded, not read at payment time, so the rule can tell
    /// "another file was opened since" from a debt for a file that is not the document (the rail
    /// menu's Reveal in Browse on another row). A debt is owed to the moment it was recorded in, and
    /// a workspace switch ends that moment.
    ///
    /// One row, except for a PDF batch's Reveal in Browse, which owes every copy in the first
    /// copy's folder: `path` is the row the pane scrolls to, `companions` the rest. It may replace
    /// the multi-selection the batch was run on (`replaces`). Both are empty for every other door.
    struct PaneSelectionDebt: Equatable {
        let path: String
        let document: String?
        let workspace: Workspace
        var companions: [String] = []
        var replaces: Set<String> = []

        /// Every row the payment selects.
        var rows: Set<String> { Set(companions).union([path]) }
    }

    /// What to do with an owed pane selection, as a rule: ``owedPaneSelection(owed:openDocument:workspace:paneFolder:paneIsCurrent:isListed:selection:selectingOpens:)``.
    enum OwedPaneSelection: Equatable {
        /// Nothing is owed.
        case nothing
        /// Not listed yet: keep it owed and ask again on the next publish.
        case wait
        /// Listed: select it, with those of its companions the pane lists, and the debt is paid.
        case select(String, with: [String] = [])
        /// No longer wanted: forget it without selecting anything, and say why in the log.
        case drop(DropReason)
    }

    /// Why an owed selection was dropped: each a guard of the rule, and the log's account of why
    /// the pane did NOT select the document, which would otherwise look like a bug.
    enum DropReason: Equatable {
        case anotherDocument
        case anotherWorkspace
        case anotherFolder
        case wouldOpenAnotherFile
        case multiSelection
        /// The user selected something else in the pane before the debt was paid.
        case userSelection

        var sentence: String {
            switch self {
            case .anotherDocument: return "another document was opened, or this one closed, since"
            case .anotherWorkspace: return "the window moved to another workspace before the pane listed it"
            case .anotherFolder: return "the pane shows another folder"
            case .wouldOpenAnotherFile: return "selecting it in Edit's pane would open it"
            case .multiSelection: return "the left pane holds a selection of several items, which is the user's"
            case .userSelection: return "the pane's selection moved to something else"
            }
        }
    }

    /// The one rule for "the pane selects the open document". Each guard is a case in
    /// `EditorPaneFollowsDocumentTests`.
    ///
    /// It applies at a MOMENT, never continuously: a debt is recorded only by
    /// ``owePaneSelection(_:)``'s callers (a rail open, a hand-off, ⌘N, Reveal in Browse, the
    /// header's "in <folder>"). Having a document open selects nothing, so switching workspaces or
    /// collapsing the pane leaves the user's selection as it was.
    ///
    /// - Another document has been opened since: dropped. In Edit a single selected text file
    ///   OPENS (`paneSelectionOpens`), so selecting the old one would drag the reader back to it.
    /// - Another workspace is on screen than the one the debt was recorded in: dropped. ⌘N's debt
    ///   waits for a re-read, and selecting in Compare would land over whatever the user did there.
    /// - The pane shows another folder than the file's: dropped. The row would be invisible, and a
    ///   pane navigated away is the user's. After a re-rooting hand-off the pane is ALREADY on the
    ///   folder: `focusOn` moves it synchronously; only its tree arrives later.
    /// - Selecting would open a file that is not the document: dropped. Only the rail menu's Reveal
    ///   in Browse owes such a file, and if Edit's pane is showing when it comes due, selecting
    ///   would open it.
    /// - The LEFT pane holds a multi-selection: dropped, as the user's. The rule replaces one row
    ///   or none, except the set a PDF batch was run on or its copies (`replaces`).
    /// - The RIGHT pane's selection does not enter into it. The payment clears it, as a click in
    ///   the left pane would: the app never keeps selections in both panes
    ///   (`PaneLogic.payOwedSelection`).
    /// - The pane's tree is not yet the folder it shows (`paneIsCurrent`), or does not list the
    ///   file yet: wait. A re-root publishes the new tree after the move, and the path can be
    ///   listed, nested, in the OLD tree meanwhile. A batch companion the pane does not list is
    ///   left out (`companionsListed`); the rest are selected.
    ///
    /// Selecting the open document cannot open it a second time: the write is marked as the app's
    /// own (`paidSelection`), and `openInEditor`'s guard returns for the document besides.
    static func owedPaneSelection(owed: PaneSelectionDebt?, openDocument: String?,
                                  workspace: Workspace,
                                  paneFolder: String, paneIsCurrent: Bool, isListed: Bool,
                                  companionsListed: Set<String> = [],
                                  selection: Set<String>,
                                  selectingOpens: Bool) -> OwedPaneSelection {
        guard let owed else { return .nothing }
        guard owed.document == openDocument else { return .drop(.anotherDocument) }
        guard owed.workspace == workspace else { return .drop(.anotherWorkspace) }
        guard PaneBrowsePath.normalized((owed.path as NSString).deletingLastPathComponent)
                == PaneBrowsePath.normalized(paneFolder) else { return .drop(.anotherFolder) }
        guard owed.path == openDocument || !selectingOpens else { return .drop(.wouldOpenAnotherFile) }
        guard selection.count <= 1 || selection.isSubset(of: owed.replaces.union(owed.rows))
        else { return .drop(.multiSelection) }
        guard paneIsCurrent && isListed else { return .wait }
        return .select(owed.path, with: owed.companions.filter { companionsListed.contains($0) })
    }

    /// The one door onto the rule: record that the left pane owes `path` a selection, and try to
    /// pay it now. Every entry point calls this: the rail's click, every hand-off, ⌘N, Reveal in
    /// Browse, the header's "in <folder>".
    ///
    /// The workspace recorded is the one on screen NOW, so a door that switches workspace must
    /// switch first (Reveal in Browse, every hand-off into Edit). `companions` and `replaces` are
    /// a PDF batch's (``PaneSelectionDebt``); every other door passes neither.
    func owePaneSelection(_ path: String, with companions: [String] = [], replacing replaces: Set<String> = []) {
        editorPaneSelectionOwed = PaneSelectionDebt(path: path, document: editorOpenPath,
                                                    workspace: selectedWorkspace,
                                                    companions: companions, replaces: replaces)
        settleOwedPaneSelection()
        if editorPaneSelectionOwed != nil {
            Logger.shared.debug("[pane-follow] \(path) is owed a selection; waiting for the left pane to list it")
        }
    }

    /// Pays an owed pane selection once the pane lists it: called when it is owed, on every
    /// left-tree publish after, and on a workspace switch (which drops it). A single `nil` test
    /// when nothing is owed.
    ///
    /// Not through `paneSelectionBinding`, the click's setter, whose consequences (a Compare-with
    /// pick, the selection surface, keyboard focus) the app's own write must not have.
    /// `PaneLogic.payOwedSelection` writes the selection and clears the right pane, each marked as
    /// the app's own (`editorPaneSelectionPaid`, `editorPaneRightClearPaid`) so neither the
    /// one-click open nor the Get Info target answers it as the user's. Then a fresh
    /// `PaneRowReveal`, which the pane scrolls to now, or when it next appears.
    ///
    /// One `.info` line either way, the selection or the drop and its reason, since the user sees
    /// the pane do it, or not.
    func settleOwedPaneSelection() {
        guard let owed = editorPaneSelectionOwed else { return }
        let decision = Self.owedPaneSelection(
            owed: owed, openDocument: editorOpenPath, workspace: selectedWorkspace,
            paneFolder: editorFolder,
            paneIsCurrent: paneTreeIsCurrent,
            isListed: !syncManager.leftNodes(for: [owed.path]).isEmpty,
            companionsListed: Set(syncManager.leftNodes(for: Set(owed.companions)).map(\.id)),
            selection: syncManager.selectedLeftPaths,
            selectingOpens: selectedWorkspace == .editor && !panesHiddenForCurrentTab)
        switch decision {
        case .nothing:
            return
        case .wait:
            // A row the type filter hides would leave this waiting forever: the file was asked for
            // by name, so the filter gives way and the republish pays the debt.
            syncManager.clearTypeFilterHiding(owed.path, isLeft: true)
            return
        case .drop(let reason):
            editorPaneSelectionOwed = nil
            Logger.shared.info("[pane-follow] Not selecting \(owed.path) in the left pane: \(reason.sentence)")
        case .select(let path, let companions):
            editorPaneSelectionOwed = nil
            PaneLogic.payOwedSelection(path, with: companions, state: syncManager,
                                       markPaid: { editorPaneSelectionPaid = $0 },
                                       markRightCleared: { editorPaneRightClearPaid = true })
            Logger.shared.info("[pane-follow] Selected \(path) in the left pane"
                               + (companions.isEmpty ? "" : ", with \(companions.count) more beside it"))
            paneRowRevealToken &+= 1
            paneRowReveal = PaneRowReveal(path: path, token: paneRowRevealToken,
                                          selection: Set(companions).union([path]))
        }
    }

    /// Whether the left pane's published tree was read at the folder the pane is on
    /// (`FileSyncManager.paneTreeFolder(isLeft:)`).
    var paneTreeIsCurrent: Bool {
        Self.treeIsCurrent(readAt: syncManager.paneTreeFolder(isLeft: true), paneFolder: currentLeftPath)
    }

    /// Whether a tree read at `readAt` is the tree of `paneFolder`; `false` for no tree at all.
    /// Compared with `~` expanded and a trailing slash dropped, since the pane's folder is built
    /// from the source's stored root and the walk from the URL it was handed.
    static func treeIsCurrent(readAt: String?, paneFolder: String) -> Bool {
        guard let readAt else { return false }
        return PaneBrowsePath.normalized((readAt as NSString).expandingTildeInPath)
            == PaneBrowsePath.normalized((paneFolder as NSString).expandingTildeInPath)
    }

    /// Never fight the user: once the pane's selection is something other than the owed or
    /// revealed row, both are retired. A selection emptied by navigation or a prune retires the
    /// reveal (there is no row to scroll to) but not the debt, whose own guards decide. Called on
    /// every change of the left pane's selection.
    func retirePaneSelectionDebts(after paths: Set<String>) {
        if let owed = editorPaneSelectionOwed, !Self.debtSurvives(owed, selection: paths) {
            editorPaneSelectionOwed = nil
            Logger.shared.info("[pane-follow] Not selecting \(owed.path) in the left pane: "
                               + DropReason.userSelection.sentence)
        }
        if let reveal = paneRowReveal, !Self.revealSurvives(reveal, selection: paths) {
            paneRowReveal = nil
        }
    }

    /// A reveal is answered once: the pane reports it has scrolled to the row, and the request is
    /// retired, since a pane answers a standing reveal whenever it appears and would jump back to
    /// the document after every trip away. A pane not on screen when it is issued answers it when
    /// it appears, and only then is it retired.
    ///
    /// On the next turn, not now: in Columns the column's scroll and the stack's are two answers to
    /// one request in one update, and the second must still see it.
    func retireAnsweredRowReveal(_ answered: PaneRowReveal) {
        DispatchQueue.main.async {
            paneRowReveal = Self.revealAfterAnswer(standing: paneRowReveal, answered: answered)
        }
    }

    /// The reveal left standing once the pane has answered `answered`: `nil` for that request, but
    /// a NEWER one (another open since, the same file again) stands, since its token differs.
    static func revealAfterAnswer(standing: PaneRowReveal?, answered: PaneRowReveal) -> PaneRowReveal? {
        standing == answered ? nil : standing
    }

    /// A debt survives a selection change that selects nothing (navigation and pruning are not
    /// the user choosing something else) or selects the owed rows themselves.
    static func debtSurvives(_ owed: PaneSelectionDebt, selection: Set<String>) -> Bool {
        selection.isEmpty || selection == owed.rows
    }

    /// A reveal survives only while its rows are the whole selection: the pane's own condition for
    /// acting on it (`FileTreeView.revealsRow`), so a remount never scrolls to a row nobody selected.
    static func revealSurvives(_ reveal: PaneRowReveal, selection: Set<String>) -> Bool {
        selection == reveal.selection
    }
}

/// Tickets for overlapping refreshes, held by a view without observing them (`editorRailRefreshes`).
///
/// A refresh may write if it is newer than the last applied, not only if it is the latest taken:
/// an autosave takes a ticket every couple of seconds, and on a folder whose survey is slower
/// (iCloud) requiring the latest would keep the rail from updating while the typing went on.
@MainActor
final class RefreshCounter {
    private(set) var count = 0
    private var applied = 0

    /// A ticket for a refresh about to start.
    func take() -> Int {
        count += 1
        return count
    }

    /// Whether the refresh holding `ticket` may write: no refresh started after it has written
    /// already. Admitting it marks it written.
    func admit(_ ticket: Int) -> Bool {
        guard ticket > applied else { return false }
        applied = ticket
        return true
    }
}
