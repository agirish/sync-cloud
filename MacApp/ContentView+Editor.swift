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

    /// The rail's rows, re-read when the folder changes and after the editor writes to it.
    ///
    /// Off the main actor: this is a directory read plus one `lstat` per surviving row, and on an
    /// iCloud folder either can block. `id:` covers the folder *and* the hidden-files preference,
    /// so flipping ⇧⌘. re-lists rather than leaving a stale answer on screen.
    func refreshEditorRail() async {
        let folder = editorFolder
        let showsHidden = syncManager.showHiddenFiles
        let rows = await Task.detached(priority: .userInitiated) {
            EditorRail.entries(in: folder, showsHidden: showsHidden)
        }.value
        // The folder can change while the walk is out; a late answer for the wrong folder would
        // list somebody else's files under this one's heading.
        guard folder == editorFolder else { return }
        editorRailEntries = rows
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
    /// Clamped like `singleSourceLayout`, against the editor's own minimum rather than a lens
    /// panel's: the workspace half here is the file rail plus the document, which need
    /// `EditorLayoutMetrics.minWorkspaceWidth` between them.
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
                editorWorkspace
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            .frame(width: totalWidth, height: geo.size.height)
        } else {
            let splitWidth = totalWidth - sidebarSlot
            let lower = PaneLogic.minRailWidth / max(splitWidth, 1)
            let upper = 1 - EditorLayoutMetrics.minWorkspaceWidth / max(splitWidth, 1)
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
                editorWorkspace
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

    var editorWorkspace: some View {
        EditorWorkspaceView(
            document: editorDocument,
            folder: editorFolder,
            entries: editorRailEntries,
            accent: glassHue.accentColor,
            onAccent: glassHue.onAccentLabelColor,
            mode: $editorMode,
            splitFraction: $editorSplitFraction,
            isNaming: $editorIsNaming,
            typedName: $editorTypedName,
            namingFocus: editorNamingFocus,
            undoManager: editorUndoManager,
            // Both closures, so neither walks the folder until the naming row is actually open.
            prefilledName: { EditorFileStore.availableUntitledName(in: editorFolder) },
            refusal: { typed in EditorFileStore.refusal(forName: typed, in: editorFolder) },
            onOpen: { entry in openInEditor(path: entry.path) },
            onCreate: { name in createTextFile(named: name) },
            onRevealInBrowse: { path in revealInBrowse(path) })
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
        guard resolveUnsavedChanges() else { return }
        // Choosing a file is the answer to the question the naming row was asking, so the row goes
        // with it. Left open it sat above a document the user was by then editing, with no way to
        // dismiss it short of Esc and nothing on screen saying so.
        editorIsNaming = false
        loadIntoEditor(path: path)
    }

    /// Reads a file and puts it on screen. No prompt: callers have already dealt with the buffer.
    func loadIntoEditor(path: String) {
        // One call, not open-then-hand-over: the encoding a file was read in travels with the text
        // it produced, which is what stops a save transcoding it. See `EditorFileStore.load`.
        let result = EditorFileStore.load(path: path, into: editorDocument)
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

    /// Settles a dirty buffer before it is replaced.
    ///
    /// - Returns: `false` when the user cancelled, in which case the caller must do nothing at all.
    func resolveUnsavedChanges() -> Bool {
        guard editorDocument.isDirty else { return true }
        switch EditorAlerts.askAboutUnsavedChanges(name: editorDocument.name) {
        case .cancel: return false
        case .discard: return true
        case .save: return saveEditorDocument()
        }
    }

    /// **The hand-off: "Open in Edit" from any file row, anywhere in the app.**
    ///
    /// **The question comes first, and nothing moves until it is answered.** The unsaved-changes
    /// prompt used to run last, inside `openInEditor`, after the pane had been re-rooted and the
    /// workspace switched — so answering *Cancel* to "save your changes?" left the user in the
    /// Editor, the pane moved to a folder they had not asked for, and the old dirty document still
    /// on screen. Cancel has to mean nothing happened.
    ///
    /// Then: point the folder before switching workspace, so the rail lists the right folder on its
    /// first render rather than listing the previous one and re-listing a frame later. Open last,
    /// through `loadIntoEditor` — the buffer is already settled, so re-asking would be a second
    /// prompt to keep in step with the first.
    ///
    /// Editing always *happens* in the editor workspace. This is the ⌘5 move a user could make by
    /// hand, made for them: one writable surface, so dirty state, undo and the save circuit live in
    /// exactly one place.
    func handOffToEditor(_ path: String) {
        guard path != editorDocument.path || editorDocument.refusal != nil else {
            // Already open and readable: just go there. Nothing to settle, nothing to move.
            if selectedWorkspace != .editor { selectedWorkspace = .editor }
            return
        }
        guard resolveUnsavedChanges() else { return }
        let folder = (path as NSString).deletingLastPathComponent
        // **The LEFT pane, whichever pane the row was in.** It took the row's side for a while,
        // which sounds more careful and is not: `editorFolder` reads the left pane and only the
        // left pane, so handing off a row from the right pane re-rooted a pane the editor never
        // shows — resetting its column stack and pushing a history entry in the user's OTHER
        // source — while the rail went on listing the left pane's folder and ⌘N went on creating
        // files there. One pane is read, so one pane is moved. Nothing to do when it is already
        // there: `focusOn` is not free.
        if !folder.isEmpty, folder != editorFolder {
            focusPaneOnFolder(folder)
        }
        if selectedWorkspace != .editor { selectedWorkspace = .editor }
        loadIntoEditor(path: path)
    }

    /// Points the left pane at an absolute folder, the way the folder sidebar does.
    ///
    /// **`focusOn` takes a path RELATIVE to whatever root the pane is on**, which is the trap this
    /// exists to avoid: handing it an absolute path resolves it against the root and lands the pane
    /// somewhere real and wrong. A folder outside the pane's current root is refused rather than
    /// guessed at — the file is still opened, it is the rail that will be showing a different
    /// folder, and that is a smaller surprise than silently switching the user's source.
    ///
    /// - Returns: `false` when the folder is not under the pane's root.
    @discardableResult
    func focusPaneOnFolder(_ folder: String, isLeft: Bool = true) -> Bool {
        let root = (settings.rootPath(for: isLeft ? leftProviderId : rightProviderId) as NSString)
            .expandingTildeInPath
        guard !root.isEmpty else { return false }
        let relative = PaneLogic.relativePath(of: folder, under: root)
        guard let relative else {
            Logger.shared.info("Editor hand-off: \(folder) is outside the pane's root — leaving the pane where it is")
            return false
        }
        syncManager.focusOn(relativePath: relative, isLeft: isLeft)
        return true
    }

    /// The reverse hand-off: Browse, pointed at the open file's folder.
    ///
    /// Deliberately does NOT close the document — you are going to look at where it lives, not to
    /// put it away, and coming back with ⌘5 should find it exactly as you left it, unsaved edits
    /// and all.
    func revealInBrowse(_ path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty { focusPaneOnFolder(folder) }
        selectedWorkspace = .browse
    }

    // MARK: - Saving

    /// ⌘S. **Absent while the document is clean**, which is what greys out File ▸ Save.
    var shortcutSaveDocument: (() -> Void)? {
        guard editorDocument.canSave else { return nil }
        return { _ = saveEditorDocument() }
    }

    /// Writes the open document.
    ///
    /// - Returns: `false` when nothing was written — either the user cancelled the changed-on-disk
    ///   question, or the write failed. Callers that were about to drop the buffer must respect it.
    @discardableResult
    func saveEditorDocument() -> Bool {
        guard let path = editorDocument.path, let stamp = editorDocument.stamp,
              !editorDocument.isReadOnly else { return false }
        // Re-stat before writing. A file the user opened an hour ago may have been filed, renamed
        // or edited since — including by this same window's Organize run.
        if let divergence = EditorFileStore.divergence(atPath: path, from: stamp) {
            guard EditorAlerts.confirmSaveOverDivergence(name: editorDocument.name,
                                                         divergence: divergence) else { return false }
        }
        do {
            let written = try EditorFileStore.write(editorDocument)
            editorDocument.markSaved(stamp: written)
            Logger.shared.info("Editor saved \(path)")
            Task { await refreshEditorRail() }
            return true
        } catch {
            // **Banner, never log-only.** A save that silently failed is the one failure in this
            // app that can cost work the user believes is on disk.
            syncManager.banner = .error("Couldn't save “\(editorDocument.name)” — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Creating

    /// ⌘N, from every workspace.
    ///
    /// **Offered from every workspace, gated only on there being a folder to create in.** The left
    /// pane and the sidebar that re-roots it span every workspace, so the folder is nearly always
    /// answerable — but "nearly" is not "always": a pane with no source configured has no current
    /// path, and a ⌘N that switched to the editor and opened a naming row over an empty folder name
    /// would be offering to create a file nowhere. From anywhere else this makes the ⌘5 move first,
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
        guard resolveUnsavedChanges() else { return false }
        do {
            let path = try EditorFileStore.createEmptyFile(named: name, in: folder)
            Logger.shared.info("Editor created \(path)")
            loadIntoEditor(path: path)
            Task { await refreshEditorRail() }
            return true
        } catch {
            syncManager.banner = .error("Couldn't create the file — \(error.localizedDescription)")
            return false
        }
    }
}
