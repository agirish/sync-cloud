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

    /// The folder whose text files the rail lists.
    ///
    /// **The left pane's folder, read through the same view mode the pane on screen is drawing.**
    ///
    /// The folder sidebar re-roots the left pane on every workspace, so "the folder I am in" has
    /// one meaning in this window and the editor must not invent a second. Which folder that is
    /// depends on whether the pane is drawing columns: in Columns it is the deepest open column, in
    /// Tree it is the pane's root.
    ///
    /// **`resolvedViewMode(isLeft: true)`, which is the member the drawn pane itself asks.** This
    /// read Browse's key for a while, on the reasoning that "the editor draws neither surface" — and
    /// that reasoning was false the moment the source pane was added: `editorLayout` mounts
    /// `paneColumn(isLeft: true)` in its expanded arm, and that pane resolves its presentation
    /// through `resolvedViewMode`, which for a single-source workspace answers the RAIL's key. So
    /// the pane on screen drew a tree while the rail beside it listed the deepest open column, or
    /// the pane drew columns the reader could drill through while the rail never moved. Asking the
    /// one member both surfaces ask is what keeps them describing the same folder.
    ///
    /// **Always the LEFT pane, and that is a decision rather than an oversight.** Every other
    /// pane-scoped verb in the app honours `shortcutTargetIsLeft`; this one does not, because the
    /// editor's own source pane is the left one and the folder sidebar re-roots the left one on
    /// every workspace. A ⌘N that opened its naming row in the right pane's folder while the
    /// editor's rail listed the left pane's would be creating the file somewhere the user is not
    /// looking — which is also why ``handOffToEditor(_:)`` re-roots the left pane whichever pane
    /// the row was in.
    var editorFolder: String {
        let pane = paneContext(isLeft: true)
        let target = resolvedViewMode(isLeft: true) == .columns
            ? syncManager.leftBrowsePath.currentDirectory(treeRoot: pane.currentPath)
            : pane.currentPath
        return (target as NSString).expandingTildeInPath
    }

    /// The rail's rows and its empty-caption count, re-read when the folder changes and after the
    /// editor writes to it.
    ///
    /// Off the main actor: this is a directory read plus one `lstat` per surviving row, and on an
    /// iCloud folder either can block. A folder with no text files in it pays a second `lstat` per
    /// entry — see ``EditorRail/survey(in:showsHidden:fileManager:isCloudOnly:)``, which is where
    /// that cost is confined and why it is only spent there. `id:` covers the folder *and* the
    /// hidden-files preference, so flipping ⇧⌘. re-lists rather than leaving a stale answer on
    /// screen.
    func refreshEditorRail() async {
        let folder = editorFolder
        let showsHidden = syncManager.showHiddenFiles
        let survey = await Task.detached(priority: .userInitiated) {
            EditorRail.survey(in: folder, showsHidden: showsHidden)
        }.value
        // The folder can change while the walk is out; a late answer for the wrong folder would
        // list somebody else's files under this one's heading.
        guard folder == editorFolder else { return }
        // **Only when the listing actually changed.** This runs after every autosave — twice a
        // sentence, for a typist — and writing `@State` unconditionally is a change as far as
        // SwiftUI is concerned, so an identical survey still bought a full body pass. The rows
        // carry the file's size, so a write that changed the length does still land — and the
        // survey is compared whole, so a PDF landing in an empty folder moves the caption too.
        guard survey != editorRailSurvey else { return }
        editorRailSurvey = survey
    }

    // MARK: - Just the text

    /// Whether the file rail is on screen: the pane is collapsed and "Just the text" is off.
    var editorRailIsDrawn: Bool {
        TopPaneVisibility.editorRailIsDrawn(paneHidden: panesHiddenForCurrentTab,
                                            railHidden: editorRailHidden)
    }

    /// The header glyph's act. On: hide the rail and, if the pane is open, collapse it — the
    /// sidebar goes with it, since `FolderSidebarModel.appliesTo` refuses to draw one beside a
    /// collapsed pane. Off: show the rail. **The pane is NOT re-expanded on the way out**: leaving
    /// "just the text" is a request for the rail, not necessarily for the pane.
    func toggleJustTheText() {
        if editorRailHidden {
            editorRailHidden = false
        } else {
            editorRailHidden = true
            if !panesHiddenForCurrentTab { togglePanesForCurrentTab() }
        }
    }

    /// The pane's one-click open, as a rule: which path a selection change opens, or `nil`.
    ///
    /// **Five guards, each a case in `EditorPaneClickTests`.** Edit only; pane expanded (collapsed,
    /// the rail is the list and the pane has no rows on screen to click); exactly one path; not a
    /// folder — `isDirectory` is `nil` when the selection could not be resolved to a node, which
    /// refuses too; and a kind Edit opens. Cloud-only and too-large files pass, deliberately: they
    /// reach `openInEditor`, which refuses them with the caption the rail's rows would have — one
    /// refusal, in one place.
    static func paneSelectionOpens(workspace: Workspace, paneHidden: Bool,
                                   paths: Set<String>, isDirectory: Bool?) -> String? {
        guard workspace == .editor, !paneHidden,
              paths.count == 1, let path = paths.first,
              let isDirectory, !isDirectory,
              EditableText.isText(path: path) else { return nil }
        return path
    }

    /// In Edit, the open pane IS the file list, so selecting a single text file in it opens the
    /// file — the same route a rail row takes, `openInEditor`, which guards the already-open case
    /// and settles a dirty buffer first. **Not `handOffToEditor`**: that re-roots the pane and
    /// switches workspace, and here the pane is already the folder and the workspace is already
    /// Edit. Arrow keys move the selection exactly as clicks do, so they open files too.
    ///
    /// `openInEditor` never writes the pane's selection, so this cannot fire itself. The row menu's
    /// hand-off and the preview column's Edit button end in a selection that already names the
    /// open document, and `openInEditor`'s first guard returns early for it.
    func openSelectedPaneFileInEditor(_ paths: Set<String>) {
        // The node walk is paid only once the cheap guards have passed: one path, in Edit, pane open.
        let node = (selectedWorkspace == .editor && paths.count == 1)
            ? paneSelectionNodes(isLeft: true).first : nil
        guard let path = Self.paneSelectionOpens(workspace: selectedWorkspace,
                                                 paneHidden: panesHiddenForCurrentTab,
                                                 paths: paths, isDirectory: node?.isDirectory)
        else { return }
        openInEditor(path: path)
    }

    // MARK: - Where the open document lives

    /// The header's location for the open document (TE43): `in Finance` while the source pane is
    /// open, the whole crumb while it is collapsed — see `EditorDocumentLocation.Style`. With no
    /// document open, the same for `editorFolder`, where a new file would be made — the empty
    /// page's header names that instead.
    ///
    /// **The LEFT pane's source, for the reason `editorFolder` reads the left pane**: it is the one
    /// pane Edit shows and the one every door here moves. `leftProviderId` rather than
    /// `paneContext(isLeft:)`, which builds the whole pane's context to answer one id.
    var editorDocumentLocation: EditorDocumentLocation? {
        EditorHeaderLocation.location(
            documentPath: editorDocument.path,
            paneFolder: editorFolder,
            sourceRoot: (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath,
            providerName: settings.availableProviders.first { $0.id == leftProviderId }?.displayName,
            paneIsOpen: !panesHiddenForCurrentTab)
    }

    /// What a press on that location does — see `EditorLocationDoors`, which is handed neither the
    /// pane's visibility nor the document, so no door can expand the pane or touch the file.
    var editorLocationDoors: EditorLocationDoors {
        EditorLocationDoors(
            syncManager: syncManager,
            drawsColumns: resolvedViewMode(isLeft: true) == .columns,
            selectInPane: { paneSelectionBinding(isLeft: true).wrappedValue = $0 })
    }

    // MARK: - The layout arm


    /// Editor: the folder sidebar, a collapsible source pane, then the file rail and the open
    /// document.
    ///
    /// **The source pane is the same `paneColumn` Organize docks**, collapsing to the same
    /// `railSpine`, driven by the same stored override — so "show me the files" behaves identically
    /// in the two workspaces that offer it, and the collapse state is remembered per workspace.
    /// It exists because the sidebar answers "a folder I have kept or visited" and the editor's
    /// question is often "a folder I have not been to yet".
    ///
    /// **Collapsed by default** (`TopPaneVisibility.defaultPanesHidden`): the common session opens a
    /// file and writes in it, and three columns before the text would be three things to look past.
    ///
    /// **The two arms differ in one more thing than the collapse: whether the rail is drawn.** The
    /// pane and the rail list the same folder — the sidebar re-roots the pane and so does every
    /// hand-off into Edit — so with the pane open the rail is a second copy of the list beside it,
    /// and the expanded arm withholds it. The collapsed arm draws it unless "Just the text" is on
    /// (`editorRailIsDrawn`). Either way the document takes what the rail does not.
    ///
    /// Clamped like `singleSourceLayout`, against the editor's own minimum rather than a lens
    /// panel's — and against the rail-less minimum, `EditorLayoutMetrics.minDocumentOnlyWidth`,
    /// because in this arm the rail is not there to reserve room for.
    @ViewBuilder
    func editorLayout(collapsed: Bool, geo: GeometryProxy) -> some View {
        let totalWidth = geo.size.width
        let sidebarWidth = folderSidebarIsShowing
            ? PaneLogic.lensSidebarWidth(stored: browseSidebarWidth, totalWidth: totalWidth,
                                         minSidebar: FolderSidebarView.minWidth,
                                         gutter: LiquidGlass.cardGutter)
            : 0
        let sidebarSlot = folderSidebarIsShowing
            ? sidebarWidth + PaneLogic.sidebarOverhead(gutter: LiquidGlass.cardGutter) : 0
        if collapsed {
            HStack(spacing: 0) {
                if folderSidebarIsShowing {
                    folderSidebar(width: sidebarWidth)
                    folderSidebarResizeHandle(displayedWidth: sidebarWidth)
                }
                railSpine
                // **No region frame here.** The workspace draws its own two cards — the rail and
                // the document — and wrapping them in a third would put a card inside a card, which
                // `bottomSectionCard` stacks into a doubled inset and a squared-off corner.
                editorWorkspace(showsRail: editorRailIsDrawn)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            .frame(width: totalWidth, height: geo.size.height)
        } else {
            let splitWidth = totalWidth - sidebarSlot
            let lower = PaneLogic.minRailWidth / max(splitWidth, 1)
            let upper = 1 - EditorLayoutMetrics.minDocumentOnlyWidth / max(splitWidth, 1)
            // Both minimums cannot always be honoured — the same bind the lens row is in, and the
            // same answer: pin to the rail's minimum rather than letting the clamp invert.
            let fraction = (lower <= upper)
                ? PaneLogic.clampedFraction(railDragFraction ?? railFraction, lower: lower, upper: upper)
                : lower
            let row = PaneLogic.lensRow(totalWidth: totalWidth, sidebarWidth: sidebarWidth,
                                        showsSidebar: folderSidebarIsShowing,
                                        gutter: LiquidGlass.cardGutter, fraction: fraction)
            HStack(spacing: 0) {
                if folderSidebarIsShowing {
                    folderSidebar(width: sidebarWidth)
                    folderSidebarResizeHandle(displayedWidth: sidebarWidth)
                }
                paneColumn(isLeft: true)
                    .panesRegionFrame(surfaceStyle, level: glassLevel)
                    .frame(width: row.railWidth)
                // The pane is the file list here, so the rail is withheld whatever the bit says.
                editorWorkspace(showsRail: false)
                    .frame(width: row.workspaceWidth)
                    .clipped()
            }
            .frame(width: totalWidth, height: geo.size.height)
            .overlay(alignment: .leading) {
                railResizeHandle(splitWidth: row.splitWidth, sidebarSlot: row.sidebarSlot,
                                 lower: lower, upper: upper)
                    .offset(x: row.railHandleOffset)
            }
            .coordinateSpace(.named(Self.railRowSpace))
        }
    }

    /// - Parameter showsRail: whether the file rail is drawn — decided by the arm, see
    ///   ``editorLayout(collapsed:geo:)``. The survey `.task` below runs regardless: the ⌘N refusal
    ///   and the prefilled name read `editorFolder`, not the survey, but the survey is cheap and
    ///   the rail returns often.
    func editorWorkspace(showsRail: Bool) -> some View {
        EditorWorkspaceView(
            document: editorDocument,
            autosavePolicy: editorAutosavePolicy,
            folder: editorFolder,
            entries: editorRailSurvey.rows,
            otherFileCount: editorRailSurvey.otherFileCount,
            showsRail: showsRail,
            railIsHidden: editorRailHidden,
            accent: glassHue.accentColor,
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
            undoManager: editorUndoManager,
            stopped: editorAutosaveStop?.caption,
            // **The stop's words become a door, and only where there is something behind them.**
            // The alert is modal and its Cancel leaves the latch set, so the question would
            // otherwise be reachable only through ⌘S. Which stops have a second version to show is
            // `EditorAutosaveStop.offersDiff`'s rule — `nil` here leaves the header a plain word.
            onShowWhatChanged: (editorAutosaveStop?.offersDiff ?? false)
                ? { showEditorDivergenceDiff() } : nil,
            // Both closures, so neither walks the folder until the naming row is actually open.
            prefilledName: { EditorFileStore.availableUntitledName(in: editorFolder) },
            refusal: { typed in EditorFileStore.refusal(forName: typed, in: editorFolder) },
            onOpen: { entry in openInEditor(path: entry.path) },
            onCreate: { name in createTextFile(named: name) },
            onRevealInBrowse: { path in revealInBrowse(path) },
            location: editorDocumentLocation,
            // Read at press time, both of them: the closure is built during this render, and the
            // document or the pane can have moved by the time the word is clicked.
            onLocationDoor: { door in
                editorLocationDoors.open(door, documentPath: editorDocument.path,
                                         location: editorDocumentLocation)
            },
            // The rail row menu's two acts that need the window: the Info inspector, and the one
            // Quick Look panel every other surface shares. `followsPane: false` — a rail row is not
            // the pane's selection, so a pane click must not retarget a preview opened from here.
            onGetInfo: { path in showInfo(for: path) },
            onQuickLook: { path in toggleQuickLook(URL(fileURLWithPath: path), followsPane: false) },
            onToggleJustTheText: { toggleJustTheText() },
            // The header's ＋ IS ⌘N — the same closure, so it opens the row and bumps the focus
            // counter, and greys out on the same `nil` the menu item does.
            onNewTextFile: shortcutNewTextFile,
            onCloseDocument: { closeEditorDocument() },
            onAutosaveResumed: { runAutosave() })
        // The rail is re-listed on arrival and whenever the folder or the hidden-files preference
        // moves — `.task(id:)` restarts on either.
        .task(id: EditorRailKey(folder: editorFolder, showsHidden: syncManager.showHiddenFiles)) {
            await refreshEditorRail()
        }
    }

    /// What re-lists the rail, as one value — so a change to either half restarts the one task
    /// rather than needing a second `.task(id:)` that could answer from a different folder.
    struct EditorRailKey: Equatable {
        var folder: String
        var showsHidden: Bool
    }

    // MARK: - Opening

    /// Opens a file in the editor, asking about an unsaved buffer first.
    ///
    /// **The prompt is here and nowhere else.** Every route into the editor — a rail row, ⌘N's new
    /// file, and later a hand-off from another workspace — comes through this function, so there is
    /// exactly one place that can lose an edit and exactly one question guarding it.
    func openInEditor(path: String) {
        // Re-clicking the row that is already open does nothing — unless the last attempt was
        // refused. A cloud-only file downloaded in Finder, or one that was too large and has since
        // been trimmed, is a second click away from opening, and the early return used to swallow
        // it and leave the stale refusal on screen.
        guard path != editorDocument.path || editorDocument.refusal != nil else { return }
        guard settleEditorDocument() else { return }
        // Choosing a file is the answer to the question the naming row was asking, so the row goes
        // with it. Left open it sat above a document the user was by then editing, with no way to
        // dismiss it short of Esc and nothing on screen saying so.
        editorIsNaming = false
        loadIntoEditor(path: path)
    }

    /// Reads a file and puts it on screen. No prompt: callers have already dealt with the buffer.
    func loadIntoEditor(path: String) {
        // **The outgoing document's undo stack is put away BEFORE the buffer is replaced**, and
        // this is the only moment its registrations and the text they name are known to agree. See
        // `EditorUndoStore`.
        editorUndoStore.remember(text: editorDocument.text)
        editorUndoStore.forgetMissingFiles()
        // One call, not open-then-hand-over: the encoding a file was read in travels with the text
        // it produced, which is what stops a save transcoding it. See `EditorFileStore.load`.
        let result = EditorFileStore.load(path: path, into: editorDocument)
        // And the incoming one's is fetched against what was actually loaded — a stack that does
        // not fit the buffer is dropped rather than handed back.
        editorUndoStore.activate(path: editorDocument.path, text: editorDocument.text)
        // **The remembered mode is NOT narrowed here**, and that is the fix rather than the
        // omission. `EditorMode.resolved` is a display filter — `EditorWorkspaceView` already
        // applies it on the way into `surfaces(for:)`, so a `.txt` file cannot show a preview
        // whatever the stored mode says. Writing the narrowed value BACK, as this line used to,
        // made one non-Markdown file destroy the setting for the rest of the session: read three
        // notes in Preview, open a `.txt` in between, and the third note opens in Edit. The type
        // that owns the rule says the opposite in its own doc comment.
        switch result {
        case .refused(let reason):
            Logger.shared.info("Editor could not open \(path) — \(reason)")
        case .readOnly(let reason):
            Logger.shared.info("Editor opened \(path) read-only — \(reason)")
        case .opened:
            Logger.shared.info("Editor opened \(path)")
        }
    }

    /// Settles the buffer before it is replaced — by WRITING it, not by asking about it.
    ///
    /// **This used to be a three-button question at every route out of the document**, and autosave
    /// is what removed it: the ordinary case is now a flush that finishes in microseconds and says
    /// nothing, because there is no decision left to put to anybody. The name and the folder were
    /// settled when the file was created, so "save where?" never had an answer to ask for.
    ///
    /// **The question survives for exactly one case: a document autosave is BLOCKED on.** When the
    /// file has changed underneath the buffer, the flush cannot write and the work really would be
    /// lost — so that, and only that, still asks. Callers must honour a `false`.
    ///
    /// - Returns: `false` when the caller must do nothing at all.
    @discardableResult
    func settleEditorDocument() -> Bool {
        // **Two documents are asked about before the flush rather than flushed.** A blocked one,
        // because the flush would refuse again for the same reason and the alert is where the
        // choice lives. And one whose autosave switch is off, because flushing it on the way out is
        // exactly the write the switch exists to prevent — a switch that held only until you
        // changed file would not be a switch at all.
        let withheld = !editorAutosavePolicy.isOn(editorDocument.path)
        if editorAutosaveStop != nil || withheld, editorDocument.isDirty {
            return confirmLeavingAnUnwrittenDocument()
        }
        switch EditorAutosave.attempt(editorDocument) {
        case .nothingToDo, .wrote:
            noteAutosave()
            return true
        case .blocked(let divergence):
            // It diverged between the last attempt and this one. Same question, asked now.
            editorAutosaveStop = .diverged(divergence)
            return confirmLeavingAnUnwrittenDocument()
        case .failed(let message):
            editorAutosaveStop = .failed(message)
            syncManager.banner = .error("Couldn't save “\(editorDocument.name)” — \(message)")
            return confirmLeavingAnUnwrittenDocument()
        }
    }

    /// The unsaved-changes question, for a document autosave is not going to write.
    ///
    /// **Two reasons reach it now.** Autosave can be *blocked* — the file changed underneath the
    /// buffer — or it can be *switched off* for this file. The question is the same either way,
    /// because the choice is: write over what is there, keep the document open, or lose the typing.
    /// It was named for the first reason alone when that was the only one.
    private func confirmLeavingAnUnwrittenDocument() -> Bool {
        switch EditorAlerts.askAboutUnsavedChanges(name: editorDocument.name) {
        case .cancel: return false
        case .discard:
            editorAutosaveStop = nil
            // **The undo history goes with the discarded typing, and it has to.** The file on disk
            // now holds text from before those edits while the stack holds registrations made
            // against the text after them — the exact mismatch `EditorUndoStore` refuses, made
            // deliberately here rather than left for the fingerprint to catch.
            if let path = editorDocument.path {
                editorUndoStore.forget(path)
                // **And the caret with it, for the same reason.** The buffer is being thrown away
                // for the copy on disk, so an offset taken against the discarded text names a place
                // in a document that no longer exists — the same mismatch the stack is dropped for.
                // Clamping would stop it crashing; it would not stop it being the wrong place.
                editorDocument.caretAnchors.forget(path)
            }
            return true
        case .save:
            // "Save" here means "overwrite what is on disk", which is the choice the divergence
            // alert puts. Routed through it rather than written directly, so the destructive answer
            // keeps the confirmation it has everywhere else.
            return saveEditorDocument()
        }
    }

    /// **The hand-off: "Open in Edit" from any file row, anywhere in the app.** The act and its
    /// order — settle first, Cancel means nothing happened, then the pane, the workspace, the load,
    /// one log line whichever way it ends — are `EditorHandOffRun.run`'s; this supplies the window's
    /// pieces.
    ///
    /// - Parameter pane: what happens to the left pane. `.followsTheFile` for every door but one;
    ///   Compare's list of differences passes `.staysPut`, because there the left pane is half of
    ///   the comparison the list is showing — see `EditorHandOffRun.Pane`.
    func handOffToEditor(_ path: String, pane: EditorHandOffRun.Pane = .followsTheFile) {
        EditorHandOffRun.run(
            path, pane: pane,
            syncManager: syncManager,
            paneRoot: (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath,
            openDocument: editorDocument.path, isRefused: editorDocument.refusal != nil,
            paneFolder: { editorFolder },
            settle: { settleEditorDocument() },
            showEdit: { if selectedWorkspace != .editor { selectedWorkspace = .editor } },
            load: { loadIntoEditor(path: $0) },
            log: { Logger.shared.info($0) })
    }

    /// Points the left pane at an absolute folder, the way the folder sidebar does — see
    /// `EditorHandOffRun.focusPane(on:root:syncManager:isLeft:)`, which this hands the pane's root.
    ///
    /// - Returns: `false` when the folder is not under the pane's root.
    @discardableResult
    func focusPaneOnFolder(_ folder: String, isLeft: Bool = true) -> Bool {
        let root = (settings.rootPath(for: isLeft ? leftProviderId : rightProviderId) as NSString)
            .expandingTildeInPath
        return EditorHandOffRun.focusPane(on: folder, root: root, syncManager: syncManager, isLeft: isLeft)
    }

    // MARK: - Closing

    /// File ▸ Close Document's action, or `nil` — which greys the item — unless Edit is on screen
    /// with a document open. See ``EditorDocumentClose/isOffered(workspace:hasDocument:)``.
    var shortcutCloseDocument: (() -> Void)? {
        guard EditorDocumentClose.isOffered(workspace: selectedWorkspace,
                                            hasDocument: editorDocument.path != nil) else { return nil }
        return { closeEditorDocument() }
    }

    /// The header's × and File ▸ Close Document: settle, unload to the empty state, and clear the
    /// pane selection that named the file so clicking its row opens it again. The act itself is
    /// ``EditorDocumentClose/run(document:undoStore:settle:paneSelection:setPaneSelection:log:)``;
    /// this supplies the window's own pieces and clears what was ABOUT the closed document — a
    /// stop, or a diff overlay, left standing over the empty editor would describe nothing.
    func closeEditorDocument() {
        guard EditorDocumentClose.run(
            document: editorDocument, undoStore: editorUndoStore,
            settle: { settleEditorDocument() },
            paneSelection: { syncManager.selectedLeftPaths },
            setPaneSelection: { syncManager.selectedLeftPaths = $0 },
            log: { Logger.shared.info($0) }) else { return }
        editorAutosaveStop = nil
        editorDivergenceReview = nil
    }

    /// The reverse hand-off: Browse, pointed at the open file's folder.
    ///
    /// Deliberately does NOT close the document — you are going to look at where it lives, not to
    /// put it away, and coming back with ⌘4 should find it exactly as you left it, unsaved edits
    /// and all.
    func revealInBrowse(_ path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty { focusPaneOnFolder(folder) }
        selectedWorkspace = .browse
    }

    // MARK: - The Text and Markup menus

    /// What Text ▸ and Markup ▸ may do to the open document — `nil` unless Edit is on screen with a
    /// document in it, which greys both menus at once.
    ///
    /// **Edit must be the WORKSPACE, not merely the owner of a document.** The document outlives a
    /// workspace switch (it is held by the app), so a test on `editorDocument.path` alone would
    /// leave Markup ▸ Bold live from Browse, aimed at text that is not on screen. Compare's items
    /// follow a comparison the same way.
    var shortcutEditorVerbs: EditorVerbs? {
        guard let path = editorDocument.path,
              EditorVerbs.isOffered(workspace: selectedWorkspace, hasDocument: true,
                                    isRefused: editorDocument.refusal != nil) else { return nil }
        let isMarkdown = editorDocument.isMarkdown
        // The mode being drawn, so the tick agrees with the capsule on a plain-text file — and so
        // the verbs that need a text view are withheld in Preview, where none is on screen.
        let drawn = EditorMode.resolved(editorMode, isMarkdown: isMarkdown)
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
            // The header's switch and this item are one setting with two doors — same policy,
            // same toggle, and switching back on writes what is already pending (see
            // `EditorWorkspaceView.autosaveSwitch`).
            autosave: showsSwitch
                ? EditorVerbs.AutosaveSwitch(isOn: editorAutosavePolicy.isOn(path)) {
                    if editorAutosavePolicy.toggle(path) { runAutosave() }
                }
                : nil,
            canMarkUp: !editorDocument.isReadOnly && EditorVerbs.hasTextView(in: drawn),
            canFind: EditorVerbs.hasTextView(in: drawn))
    }

    // MARK: - Saving

    /// ⌘S. **Present even when the document is clean**, unlike before autosave.
    ///
    /// It used to be absent while clean, which greyed out File ▸ Save and was exactly right when
    /// ⌘S was the only thing that ever wrote. Now the ordinary document is already on disk, so a
    /// greyed-out Save would be the menu's answer to "did my work make it?" — and the one moment
    /// somebody reaches for it is the moment autosave has STOPPED and the document is not clean at
    /// all. It stays live whenever there is a document, and means "write it now, and settle
    /// whatever is blocking that".
    var shortcutSaveDocument: (() -> Void)? {
        guard editorDocument.path != nil, !editorDocument.isReadOnly else { return nil }
        return { _ = saveEditorDocument() }
    }

    /// ⌘S: write the document now, asking about a divergence if there is one.
    ///
    /// - Returns: `false` when nothing was written.
    @discardableResult
    func saveEditorDocument() -> Bool {
        guard let path = editorDocument.path, let stamp = editorDocument.stamp,
              !editorDocument.isReadOnly else { return false }
        // Re-stat before writing. A file opened an hour ago may have been filed, renamed or edited
        // since — including by this same window's Organize run.
        if let divergence = EditorFileStore.divergence(atPath: path, from: stamp) {
            return applyDivergenceAnswer(
                EditorAlerts.askAboutDivergence(name: editorDocument.name, divergence: divergence),
                divergence: divergence, path: path, explicit: true)
        }
        return writeEditorDocument(explicit: true)
    }

    // MARK: - Which version wins

    /// A divergence question that has been detoured into the diff overlay.
    ///
    /// **Carried rather than recomputed, because the answer has to come back to the same path that
    /// asked.** `explicit` is what ⌘S and the header's door have in common and the autosave timer
    /// does not: a write the user asked for logs at INFO and one the debounce made logs at DEBUG,
    /// and the overlay's Save Anyway must land in the right one. See `writeEditorDocument`.
    struct EditorDivergenceReview: Equatable {
        var divergence: EditorFileStore.Divergence
        var explicit: Bool
        /// **The document the diff is ABOUT.**
        ///
        /// The overlay leads the window's overlay chain and its scrim absorbs clicks, but the menu
        /// bar is still live — File ▸ Open and ⌘N can hand the editor another file while two
        /// versions of this one are on screen. Without this, the foot's Save Anyway would write
        /// whatever document happened to be open by then, on the strength of a diff of a different
        /// file. The answer is refused instead: see ``answerEditorDivergenceDiff(_:)``.
        var path: String
    }

    /// **The one place a divergence answer is acted on** — from the alert, from the overlay's foot,
    /// and from the header's door. One function, so a caller cannot answer one of the four cases
    /// differently from the others, and `.showWhatChanged` cannot be dropped on the floor by a
    /// `switch` that has run out of interesting cases.
    ///
    /// - Returns: whether anything was WRITTEN — so `false` for the detour, which resolves nothing.
    @discardableResult
    func applyDivergenceAnswer(_ answer: EditorAlerts.DivergenceAnswer,
                               divergence: EditorFileStore.Divergence,
                               path: String, explicit: Bool) -> Bool {
        switch answer {
        case .saveAnyway:
            return writeEditorDocument(explicit: explicit)
        case .reloadFromDisk:
            return reloadOverTheBuffer(path: path)
        case .showWhatChanged:
            // **The latch goes on BEFORE the overlay, not after it.** While two versions are on
            // screen the debounce must not quietly write one of them — and it makes dismissing the
            // overlay identical to Cancel, which is the property Escape has to have.
            editorAutosaveStop = .diverged(divergence)
            editorDivergenceReview = EditorDivergenceReview(divergence: divergence,
                                                            explicit: explicit, path: path)
            return false
        case .cancel:
            // Declining leaves autosave stopped, and says so on the header rather than going
            // quiet: the document is now in the one state where typing is not reaching disk.
            editorAutosaveStop = .diverged(divergence)
            return false
        }
    }

    /// The header's amber words, clicked. Re-reads the stop rather than trusting the caller: the
    /// closure is built while the header renders and the stop can have been settled since.
    func showEditorDivergenceDiff() {
        guard case .diverged(let divergence) = editorAutosaveStop, divergence == .changed,
              let path = editorDocument.path else { return }
        applyDivergenceAnswer(.showWhatChanged, divergence: divergence, path: path, explicit: true)
    }

    /// The overlay's foot, answered. **The same three answers travelling back**, through the same
    /// function the alert's answer goes through — never a second write path.
    func answerEditorDivergenceDiff(_ verdict: EditorDivergenceVerdict) {
        guard let review = editorDivergenceReview else { return }
        // Cleared FIRST. Every branch below either writes, reloads, or leaves the stop standing,
        // and all three want the overlay gone; clearing after would leave it up over a document
        // that has already been reloaded out from under it.
        editorDivergenceReview = nil
        // **The answer is about the file the diff showed, and only that one.** The menu bar stays
        // live behind the scrim, so another document can have been opened while the overlay was up
        // — and then Save Anyway would overwrite it on the strength of a comparison of something
        // else. Dropping the answer is the safe end: nothing is written, and the stop on whatever
        // is open now still says what it says.
        guard editorDocument.path == review.path else {
            Logger.shared.info(
                "Editor discarded a divergence answer for \(review.path) — the open document is now \(editorDocument.path ?? "none")")
            return
        }
        applyDivergenceAnswer(EditorAlerts.divergenceAnswer(for: verdict),
                              divergence: review.divergence,
                              path: review.path, explicit: review.explicit)
    }

    /// The write itself, with no questions in it — both ⌘S and autosave land here.
    ///
    /// **A successful write clears the stop**, whatever it was: the file on disk is now this
    /// buffer, so the reason autosave halted has gone with it.
    @discardableResult
    private func writeEditorDocument(explicit: Bool) -> Bool {
        do {
            editorDocument.markSaved(stamp: try EditorFileStore.write(editorDocument))
            editorAutosaveStop = nil
            // **⌘S is INFO and autosave is DEBUG, and that split is deliberate.** He audits this
            // log. One line per explicit save is a record; one line every two seconds of typing is
            // a flood that buries everything around it — including the failures below, which is the
            // half of this that has to be readable.
            let path = editorDocument.path ?? ""
            if explicit {
                Logger.shared.info("Editor saved \(path)")
            } else {
                Logger.shared.debug("Editor autosaved \(path)")
            }
            Task { await refreshEditorRail() }
            return true
        } catch {
            // **Banner, never log-only.** A save that silently failed is the one failure in this
            // app that can cost work the user believes is on disk.
            syncManager.banner = .error("Couldn't save “\(editorDocument.name)” — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Autosave

    /// One autosave attempt, from the debounce or from a flush.
    ///
    /// **The stop latch is checked first, and it is what keeps this from becoming a nag.** The
    /// alert below interrupts the moment a divergence is found, which is what was asked for — but
    /// an alert raised from a timer that restarts on every keystroke would come back two seconds
    /// after it was dismissed, and again, and again, for as long as the file stayed diverged. So a
    /// stop LATCHES: autosave does nothing further until a write succeeds or the user clears it,
    /// and ⌘S is the way to ask again deliberately.
    /// **The write itself happens off the main actor**, which is the whole of this change.
    ///
    /// The debounce fires two seconds after the typing pauses — which, for anybody writing in
    /// bursts, is the moment the typing resumes. What ran there was a `stat` with a symlink
    /// resolve, an `attributesOfItem`, an O(n) encode, a `Data.write`, an `F_FULLFSYNC` (tens of
    /// milliseconds on the internal SSD, considerably more on an external or iCloud volume), a
    /// `replaceItem`, a `removeItem` and a re-`stat`, all of it on the main actor with the caret
    /// blinking in the same run loop.
    ///
    /// **The durability is unchanged, deliberately.** `F_FULLFSYNC` stays on both paths. The reason
    /// to weaken it to a plain `fsync` would have been the main-actor stall it caused, and that
    /// reason has just been removed — a flush the user never waits for costs nothing to do
    /// properly, and these are real cloud folders where a half-written file syncs to every other
    /// machine.
    ///
    /// Everything the outcome leads to — the latch, the alert, the banner — is unchanged and still
    /// happens on the main actor. What the outcome is *about* changed: it describes the snapshot
    /// that was written, not the buffer as it stands now. See `EditorAutosave.Snapshot`.
    func runAutosave() {
        // **The switch is checked here rather than in the driver**, so the timer still runs and the
        // document is still asked the ordinary questions — only the write is withheld. Gating the
        // driver instead would mean a file switched back ON mid-edit waited for the next keystroke
        // before anything reached disk.
        guard editorAutosavePolicy.isOn(editorDocument.path) else { return }
        guard editorAutosaveStop == nil else { return }
        // One background write at a time. Two overlapping ones would both spin up an `F_FULLFSYNC`
        // against the same file to no purpose; the store's write order makes them *safe*, and this
        // makes them not happen.
        guard !editorIsWritingInBackground else { return }
        guard let snapshot = EditorAutosave.snapshot(of: editorDocument) else { return }
        editorIsWritingInBackground = true
        // **An unstructured `Task`, not the driver's.** The driver's task is cancelled by the next
        // keystroke — that cancellation IS the debounce — and a write that has already been
        // dispatched must finish and commit whatever the typist does next.
        Task { @MainActor in
            let outcome = await EditorAutosave.write(snapshot, into: editorDocument)
            editorIsWritingInBackground = false
            applyAutosaveOutcome(outcome)
        }
    }

    /// What an autosave attempt leads to on screen — identical for the synchronous and the
    /// background path, which is why it is one function rather than two copies.
    private func applyAutosaveOutcome(_ outcome: EditorAutosave.Outcome) {
        switch outcome {
        case .nothingToDo:
            break
        case .wrote:
            _ = writeEditorDocumentDidWrite()
        case .blocked(let divergence):
            editorAutosaveStop = .diverged(divergence)
            // Interrupt now rather than wait to be noticed. The latch above is already set, so
            // declining leaves the document visibly stopped instead of asking again — and so does
            // asking to see the diff, which is why both go through the one function below rather
            // than being re-decided here.
            applyDivergenceAnswer(
                EditorAlerts.askAboutDivergence(name: editorDocument.name, divergence: divergence),
                divergence: divergence, path: editorDocument.path ?? "", explicit: false)
        case .failed(let message):
            // Latched for the same reason: a full disk or a read-only volume fails identically
            // every two seconds, and a banner per attempt is not a report, it is noise.
            editorAutosaveStop = .failed(message)
            syncManager.banner = .error("Couldn't save “\(editorDocument.name)” — \(message)")
        }
    }

    /// `EditorAutosave.attempt` has already written and stamped the document; this is the host's
    /// half — the log line, the rail, and clearing any stop.
    private func writeEditorDocumentDidWrite() -> Bool {
        editorAutosaveStop = nil
        Logger.shared.debug("Editor autosaved \(editorDocument.path ?? "")")
        Task { await refreshEditorRail() }
        return true
    }

    /// Called after a flush that wrote or had nothing to do.
    func noteAutosave() { editorAutosaveStop = nil }

    /// "Reload from Disk": throw the buffer away and re-read the file.
    ///
    /// **The only route in this app that discards typing on purpose**, which is why it is a named
    /// function rather than a call to `loadIntoEditor` at two call sites: the thing worth stating
    /// is that the buffer is gone deliberately and the undo stack goes with it, since the text view
    /// is handed a document whose identity has not changed and would otherwise keep registrations
    /// made against the text being discarded.
    ///
    /// - Returns: `false` always — nothing was written, and callers whose contract is "did the save
    ///   happen" must not be told it did.
    @discardableResult
    private func reloadOverTheBuffer(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        Logger.shared.info("Editor reloaded \(path) from disk, discarding the buffer")
        // Clear the stop BEFORE the load: `loadIntoEditor` re-stamps the document, so the reason
        // autosave halted is gone by the time it returns, and leaving the latch set would stop the
        // next keystroke reaching disk for no reason anybody could see.
        editorAutosaveStop = nil
        // **Forgotten before the load, not cleared after it.** `loadIntoEditor` will ask the store
        // for this path's stack; dropping it here is what makes that ask return a fresh one.
        editorUndoStore.forget(path)
        // Beside it, and for the reason given at the discard site: the file on disk is not the text
        // this anchor was measured against.
        editorDocument.caretAnchors.forget(path)
        loadIntoEditor(path: path)
        return false
    }

    // MARK: - Creating

    /// ⌘N, from every workspace.
    ///
    /// **Offered from every workspace, gated only on there being a folder to create in.** The left
    /// pane and the sidebar that re-roots it span every workspace, so the folder is nearly always
    /// answerable — but "nearly" is not "always": a pane with no source configured has no current
    /// path, and a ⌘N that switched to the editor and opened a naming row over an empty folder name
    /// would be offering to create a file nowhere. From anywhere else this makes the ⌘4 move first,
    /// so the file is created in the folder the user was already looking at.
    var shortcutNewTextFile: (() -> Void)? {
        guard !editorFolder.isEmpty else { return nil }
        return {
            if selectedWorkspace != .editor { selectedWorkspace = .editor }
            editorIsNaming = true
            // **Bumped every time, including when the row is already open.** Setting `isNaming`
            // true when it is already true is not a change, so the rail's `onChange` does not fire
            // and focus stays wherever it was — a second ⌘N looked like it did nothing.
            editorNamingFocus &+= 1
        }
    }

    /// Creates the named file and opens it, clean.
    ///
    /// - Returns: `false` when nothing was created, so the naming row can stay open with the typed
    ///   name still in it. Cancelling a question about the *previous* document must not also throw
    ///   away the name typed for this one.
    @discardableResult
    func createTextFile(named name: String) -> Bool {
        let folder = editorFolder
        guard !folder.isEmpty else { return false }
        guard settleEditorDocument() else { return false }
        do {
            let path = try EditorFileStore.createEmptyFile(named: name, in: folder)
            Logger.shared.info("Editor created \(path)")
            loadIntoEditor(path: path)
            // Both lists, whichever is on screen: the rail for the collapsed arm, the pane for the
            // expanded one — and the pane is re-read even while collapsed, so it is current when
            // it is next opened.
            Task { await refreshEditorRail() }
            showCreatedFileInPane(path)
            return true
        } catch {
            syncManager.banner = .error("Couldn't create the file — \(error.localizedDescription)")
            return false
        }
    }

    /// Makes the left pane list a file ⌘N just created, and select it once it does.
    ///
    /// **Since TE36 the open pane IS Edit's file list**, and the rail beside it is withheld — so
    /// `refreshEditorRail()` alone, which is all ⌘N used to do, refreshed a list nobody could see.
    /// The file was on disk and open, and the column it was created in went on listing the folder
    /// as it was, with nothing on screen saying where the document lived (TE44, 2026-09-25).
    ///
    /// **The selection is owed, not written now.** The node does not exist until the re-read
    /// publishes, and a selection naming a row the list does not hold is at the mercy of the
    /// `List` and of `pruneSelection`. So it is recorded here and written by
    /// ``settleOwedPaneSelection()`` on the tree publish that lists it — including a column's
    /// graft, which arrives on its own publish after the walk.
    func showCreatedFileInPane(_ path: String) {
        editorPaneSelectionOwed = path
        rereadPanesAfterEditorWrite()
    }

    /// The re-read every file operation already gets, for a file Edit put on disk itself.
    ///
    /// **Not a second refresh path.** `enqueueFileOperation` ends each write by dropping the
    /// prefetch cache, bumping the scan-config epoch and sending `.both` down `refreshSubject`,
    /// which `ContentView` turns into the reload. `prepareForcedRescan()` is the public spelling of
    /// the first two, and neither is optional: without the drop a pane that has finished a deep
    /// walk is served that walk — the one taken before the file existed (measured,
    /// `OutOfQueueWriteRereadTests`) — and without the epoch a same-target refresh already in
    /// flight swallows this one as a duplicate. `.both`, as for any file operation: the right pane
    /// can be standing in the same folder, and Compare would show it stale.
    ///
    /// Edit's writes do not go through the queue itself, deliberately — a new note must not wait
    /// behind a long copy. **For writes that ADD a file only** (⌘N, Export as PDF): an autosave
    /// rewrites a file the pane already lists, and a two-pane walk twice a sentence would be the
    /// cost the rail's own "only when the listing changed" guard exists to avoid.
    func rereadPanesAfterEditorWrite() {
        syncManager.prepareForcedRescan()
        syncManager.refreshSubject.send(.both)
    }

    /// What to do with an owed pane selection, as a rule — see ``owedPaneSelection(owed:openDocument:paneFolder:isListed:)``.
    enum OwedPaneSelection: Equatable {
        /// Nothing is owed.
        case nothing
        /// Not listed yet: keep it owed and ask again on the next publish.
        case wait
        /// Listed: select it, and the debt is paid.
        case select(String)
        /// No longer wanted: forget it without selecting anything.
        case drop
    }

    /// **Selecting the created file is right only while it is still the open document in the
    /// folder the pane shows**, and each guard is a case in `EditorNewFilePaneTests`.
    ///
    /// - The open document moved on: dropped. In Edit a single selected text file OPENS
    ///   (`paneSelectionOpens`), so selecting the new file after the user had opened another one
    ///   would drag them back to it — the one outcome worse than the bug.
    /// - The pane moved to another folder: dropped. Selecting a row the pane is not showing would
    ///   select something invisible, and the pane's own navigation already cleared its selection.
    /// - Not listed yet: wait. The reload has not published, or published a shallow first paint.
    ///
    /// Selecting the open document cannot open it a second time: `openInEditor`'s first guard
    /// returns for the path that is already open, so the pane's one-click open is a no-op here.
    static func owedPaneSelection(owed: String?, openDocument: String?, paneFolder: String,
                                  isListed: Bool) -> OwedPaneSelection {
        guard let owed else { return .nothing }
        guard owed == openDocument,
              PaneBrowsePath.normalized((owed as NSString).deletingLastPathComponent)
                == PaneBrowsePath.normalized(paneFolder)
        else { return .drop }
        return isListed ? .select(owed) : .wait
    }

    /// Pays an owed pane selection once the pane lists the file — called on every left-tree
    /// publish, and a single `nil` test when nothing is owed.
    ///
    /// **Through `paneSelectionBinding`, the setter a click goes through**, so the one-pane
    /// invariant and the focused-pane move are the ones a click gets, not a copy of them.
    func settleOwedPaneSelection() {
        guard let owed = editorPaneSelectionOwed else { return }
        let decision = Self.owedPaneSelection(
            owed: owed, openDocument: editorDocument.path, paneFolder: editorFolder,
            isListed: !syncManager.leftNodes(for: [owed]).isEmpty)
        switch decision {
        case .nothing, .wait:
            return
        case .drop:
            editorPaneSelectionOwed = nil
        case .select(let path):
            editorPaneSelectionOwed = nil
            if syncManager.selectedLeftPaths != [path] {
                paneSelectionBinding(isLeft: true).wrappedValue = [path]
            }
        }
    }
}
