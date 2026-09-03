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
        // **Only when the listing actually changed.** This runs after every autosave — twice a
        // sentence, for a typist — and writing `@State` unconditionally is a change as far as
        // SwiftUI is concerned, so an identical list of rows still bought a full body pass. The
        // rows carry the file's size, so a write that changed the length does still land.
        guard rows != editorRailEntries else { return }
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
            autosavePolicy: editorAutosavePolicy,
            folder: editorFolder,
            entries: editorRailEntries,
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
            // Both closures, so neither walks the folder until the naming row is actually open.
            prefilledName: { EditorFileStore.availableUntitledName(in: editorFolder) },
            refusal: { typed in EditorFileStore.refusal(forName: typed, in: editorFolder) },
            onOpen: { entry in openInEditor(path: entry.path) },
            onCreate: { name in createTextFile(named: name) },
            onRevealInBrowse: { path in revealInBrowse(path) },
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
            if let path = editorDocument.path { editorUndoStore.forget(path) }
            return true
        case .save:
            // "Save" here means "overwrite what is on disk", which is the choice the divergence
            // alert puts. Routed through it rather than written directly, so the destructive answer
            // keeps the confirmation it has everywhere else.
            return saveEditorDocument()
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
    /// Editing always *happens* in the editor workspace. This is the ⌘4 move a user could make by
    /// hand, made for them: one writable surface, so dirty state, undo and the save circuit live in
    /// exactly one place.
    func handOffToEditor(_ path: String) {
        guard path != editorDocument.path || editorDocument.refusal != nil else {
            // Already open and readable: just go there. Nothing to settle, nothing to move.
            if selectedWorkspace != .editor { selectedWorkspace = .editor }
            return
        }
        guard settleEditorDocument() else { return }
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
    /// put it away, and coming back with ⌘4 should find it exactly as you left it, unsaved edits
    /// and all.
    func revealInBrowse(_ path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty { focusPaneOnFolder(folder) }
        selectedWorkspace = .browse
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
            switch EditorAlerts.askAboutDivergence(name: editorDocument.name,
                                                   divergence: divergence) {
            case .saveAnyway:
                break
            case .reloadFromDisk:
                return reloadOverTheBuffer(path: path)
            case .cancel:
                // Declining leaves autosave stopped, and says so on the header rather than going
                // quiet: the document is now in the one state where typing is not reaching disk.
                editorAutosaveStop = .diverged(divergence)
                return false
            }
        }
        return writeEditorDocument(explicit: true)
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
            // declining leaves the document visibly stopped instead of asking again.
            switch EditorAlerts.askAboutDivergence(name: editorDocument.name,
                                                   divergence: divergence) {
            case .saveAnyway: _ = writeEditorDocument(explicit: false)
            case .reloadFromDisk: _ = reloadOverTheBuffer(path: editorDocument.path ?? "")
            case .cancel: break   // the latch above is already set
            }
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
            Task { await refreshEditorRail() }
            return true
        } catch {
            syncManager.banner = .error("Couldn't create the file — \(error.localizedDescription)")
            return false
        }
    }
}
