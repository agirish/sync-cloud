import SwiftUI
import Sync
import Settings
import Dashboard
import FileExplorer
import Design
import Events

/// Ask Claude’s wiring into the window (RD69, v7.0): the panel, the screen it describes, and the
/// window state its tools read and move. An extension because the tools need ContentView’s own
/// state — the workspace, the Browse pane’s location, the overlays that make the window busy.
extension ContentView {

    var askClaudeChat: AskClaudeChat { askClaudeHolder.chat }

    func toggleAskClaude() {
        withDesignAnimation(.easeOut(duration: 0.12), reduceMotion: reduceMotion) {
            askClaudeHolder.visibility.isOpen.toggle()
        }
    }

    /// The panel, hanging from the toolbar over the content’s right edge.
    func askClaudeOverlay(in container: CGSize, onPlace: @escaping (CGRect) -> Void) -> some View {
            AskClaudePanel(chat: askClaudeChat,
                           place: askClaudePlace,
                           accent: glassHue.accentColor,
                           accentFill: glassHue.accentFillColor,
                           onAccent: glassHue.onAccentLabelColor,
                           onAsk: { askClaudeSend($0) },
                           onClose: { toggleAskClaude() },
                           onOpenSettings: { openSettings(on: .intelligence) },
                           container: container,
                           onSetHidden: { askClaudeSetCurrentFolderHidden($0) },
                           onGoToFolder: { askClaudeShowFolderPane() },
                           onReveal: { path in Task { await askClaudeTools().reveal(path: path) } },
                           onSendOffer: { id in
                               guard let offer = askClaudeChat.takeOffer(id) else { return }
                               askClaudeAsk(offer.question, shown: offer.shown)
                           },
                           onDownloadCard: { askClaudeDownloadCard($0, $1) },
                           onFilingCard: { askClaudeFilingCard($0) },
                           onPlanCard: { askClaudePlanCard($0, $1) },
                           onChoice: { id, index in
                               guard let choice = askClaudeChat.takeChoice(id, at: index) else { return }
                               if let sends = choice.sends { askClaudeSend(sends) } else { askClaudeHolder.visibility.focusRequests += 1 }
                           },
                           onPlace: onPlace)
    }

    /// The panel's host, built here rather than in `body`: the window's modifier chain is at the
    /// edge of what the type checker solves in time, and a generic closure there tipped it over.
    var askClaudeHost: AskClaudeHost {
        AskClaudeHost(visibility: askClaudeHolder.visibility, isBusy: askClaudeStateBusy != nil,
                      panel: { AnyView(askClaudeOverlay(in: $0, onPlace: $1)) }, toggle: askClaudeChordBinding,
                      onPrivacyChange: { askClaudePrivacyChanges += 1 })
    }

    /// ⌘J’s binding: nil while a destination pick is up, as the toolbar button is disabled then.
    var askClaudeChordBinding: Binding<Bool>? {
        // Not under a sheet or overlay the panel would open beneath, out of sight, taking the keys.
        guard askClaudeStateBusy == nil else { return nil }
        let visibility = askClaudeHolder.visibility
        return Binding(get: { visibility.isOpen }, set: { visibility.isOpen = $0 })
    }

    func askClaudeTools() -> AskClaudeBrowseTools {
        AskClaudeBrowseTools(context: { askClaudeToolsContext() })
    }

    func askClaudeAsk(_ question: String, shown: String? = nil, attached: [AskClaudeChat.Attachment] = []) {
        let tools = askClaudeTools()
        let attachedRows = askClaudeAttachedRows(attached)
        // TE241: a folder the pane hasn't loaded is read from disk first, so the screen is never
        // sent empty while the person is looking at files.
        let folder = AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)
        guard askClaudeItems(folder) == nil else {
            var screen = askClaudeScreen()
            screen.attached = attachedRows
            askClaudeChat.ask(question, shown: shown, screen: screen, tools: tools)
            return
        }
        askClaudeChat.ask(question, shown: shown, preparing: {
            let fromDisk = await AskClaudeDisk.list(folder) ?? []
            var screen = askClaudeScreen(fallbackRows: fromDisk)
            screen.attached = attachedRows
            return screen
        }, tools: tools)
    }

    /// The text box's Send: the question, about the chips above it (TE263). A chip hidden from
    /// Claude since it was attached is dropped, never sent.
    func askClaudeSend(_ question: String) {
        guard !askClaudeChat.isRunning else { return }
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        let attached = askClaudeChat.takeAttachments().filter { !hidden.isHidden($0.path) }
        let shown = attached.isEmpty ? nil : question + "\nAbout " + attached.map(\.name).joined(separator: ", ")
        askClaudeAsk(question, shown: shown, attached: attached)
    }

    /// Each attached item as the card lists it: its row, and where it lives by source and folder.
    private func askClaudeAttachedRows(_ attached: [AskClaudeChat.Attachment]) -> [AskClaudeScreen.Attached] {
        attached.map { item in
            let node = AskClaudeDisk.node(atPath: item.path)
                ?? FileNode(id: item.path, name: item.name, isDirectory: item.isDirectory)
            let parent = (item.path as NSString).deletingLastPathComponent
            var place = (parent as NSString).lastPathComponent
            if let source = AskClaudeBrowseTools.closestSource(containing: item.path, in: askClaudeSources) {
                let folder = AskClaudeBrowseTools.relativeIfInside(parent, root: source.root) ?? ""
                place = folder.isEmpty ? source.name : "\(source.name) › \(folder)"
            }
            return AskClaudeScreen.Attached(row: AskClaudeBrowseTools.row(node), place: place)
        }
    }

    /// A row's Ask Claude About This (TE263): the panel opens, or comes forward, with these attached
    /// above its text box and the caret in it.
    func askClaudeAttach(_ paths: [String]) {
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        let kept = paths.filter { !hidden.isHidden($0) }
        // A name two chips share (a Compare row's two sides) says which source each is.
        let names = (askClaudeChat.attachments.map(\.path) + kept).map { ($0 as NSString).lastPathComponent.lowercased() }
        let items = kept.map { path in
            var isFolder: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
            var name = (path as NSString).lastPathComponent
            if names.filter({ $0 == name.lowercased() }).count > 1,
               let source = AskClaudeBrowseTools.closestSource(containing: path, in: askClaudeSources) {
                name += " (\(source.name))"
            }
            return AskClaudeChat.Attachment(path: path, name: name, isDirectory: exists && isFolder.boolValue)
        }
        guard !items.isEmpty else { return }
        askClaudeChat.attach(items)
        Logger.shared.info("Ask Claude: attached \(items.count) item\(items.count == 1 ? "" : "s") from a row’s menu")
        askClaudeHolder.visibility.isOpen = true
        askClaudeHolder.visibility.focusRequests += 1
    }

    /// Why a row's Ask Claude About This can't take these, for its tooltip, or nil (TE263).
    func askClaudeRowRefusal(_ paths: [String]) -> String? {
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        let hiddenCount = paths.filter { hidden.isHidden($0) }.count
        guard hiddenCount > 0 else { return nil }
        return paths.count == 1 ? "It’s hidden from Claude. Show it to Claude first."
            : "\(hiddenCount) of these \(hiddenCount == 1 ? "is" : "are") hidden from Claude."
    }

    /// Whether a row is on the Never show Claude list, itself or through a folder above it.
    func askClaudeIsHidden(_ path: String) -> Bool {
        AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard)).isHidden(path)
    }

    /// A download card's buttons (TE258). Download checks again at the click, waits, and then
    /// asks the question again (a read) or opens the file (an open), with no Claude round for that.
    func askClaudeDownloadCard(_ id: UUID, _ action: AskClaudeDownloadAction) {
        let chat = askClaudeChat
        switch action {
        case .notNow: chat.declineDownload(id)
        case .stopWaiting: chat.stopWaiting(id)
        case .revealInFinder:
            guard case .download(let download, _)? = chat.items.first(where: { $0.id == id })?.kind else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: download.path)])
        case .download:
            chat.download(id, refusal: { download in
                let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
                return AskClaudeBrowseTools.downloadRefusal(download, isHidden: { hidden.isHidden($0) })
            }, fetch: { await AskClaudeBrowseTools.fetch($0) }, landed: { download in
                askClaudeDownloaded(download)
            })
        }
    }

    /// A card of changes (TE267): ticks, and a folder for a row from its menu or a folder picker.
    func askClaudePlanCard(_ id: UUID, _ action: AskClaudePlanAction) {
        switch action {
        case .tick(let row, let ticked):
            askClaudeChat.updatePlan(id) { $0.setTicked(ticked, row: row) }
        case .choose(let row, let choice):
            askClaudeChat.updatePlan(id) { $0.choose(choice, forRow: row) }
        case .chooseFolder(let row):
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.message = "Where this file goes"
            if let root = syncManager.filingFolderProfile?.recordedFolderPath {
                panel.directoryURL = URL(fileURLWithPath: root)
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // Spelled as the panel gave it, which keeps a link's spelling (iCloud's Documents).
            let path = url.path
            guard !askClaudeIsHidden(path) else {
                askClaudeChat.addNote("\(url.lastPathComponent) is hidden from Claude, so it can’t be chosen here.")
                return
            }
            let label = AskClaudeBrowseTools.breadcrumb(path, sources: askClaudeSources, fallback: url.lastPathComponent)
            askClaudeChat.updatePlan(id) { $0.choose(AskClaudePlan.Choice(label: label, path: path), forRow: row) }
        }
    }

    /// Filing help's card buttons (TE255).
    func askClaudeFilingCard(_ action: AskClaudeFilingAction) {
        switch action {
        case .goTo(let folder):
            Task { @MainActor in
                let outcome = await askClaudeTools().goToFolder(folder)
                Logger.shared.info("Ask Claude filing card: Go to Folder — \(outcome.step)" + (outcome.isError ? " (refused)" : ""))
                if outcome.isError { askClaudeChat.addNote("Couldn’t go there: \(outcome.step).") }
            }
        case .refine(let file):
            askClaudeRefineFiling(file)
        case .openSetup:
            if let busy = askClaudeStateBusy {
                askClaudeChat.addNote("Couldn’t open Setup: \(busy).")
                return
            }
            showSetup = true
        }
    }

    /// Refine with Claude from filing help's card (decision EY): Organize scans the file's folder,
    /// then refines this one file there, with its own price check first. The answer is Organize's.
    private func askClaudeRefineFiling(_ file: String) {
        if let busy = askClaudeStateBusy {
            askClaudeChat.addNote("Couldn’t open Organize: \(busy).")
            return
        }
        guard let source = AskClaudeBrowseTools.closestSource(containing: file, in: askClaudeSources) else {
            askClaudeChat.addNote("Couldn’t open Organize: \((file as NSString).lastPathComponent) isn’t in a source SyncCloud shows.")
            return
        }
        let folder = (file as NSString).deletingLastPathComponent
        Logger.shared.info("Ask Claude filing card: Refine with Claude for \((file as NSString).lastPathComponent), in Organize")
        organizeFolderAction(FileNode(id: folder, name: (folder as NSString).lastPathComponent, isDirectory: true),
                             providerRoot: providerRootExpanded(forProviderId: source.id),
                             providerAnchor: providerAnchorExpanded(forProviderId: source.id))
        Task { @MainActor in _ = await syncManager.refineAfterScan(filePath: file) }
    }

    private func askClaudeDownloaded(_ download: AskClaudeDownload) {
        let chat = askClaudeChat
        switch download.purpose {
        case .read:
            // A question running since: this one would be refused, so the thread says what to do.
            guard !chat.isRunning else {
                chat.addNote("Downloaded \(download.fileName). Ask again and Claude reads it.")
                return
            }
            // Hidden since the click: not attached, and not asked about.
            guard !askClaudeIsHidden(download.path) else {
                chat.addNote("Downloaded \(download.fileName), but it’s hidden from Claude now, so Claude doesn’t read it.")
                return
            }
            // Attached, so a chat started over since (an hour away, a folder hidden) still has it.
            let again = AskClaudeChat.reask(after: download)
            askClaudeAsk(again.question, shown: again.shown,
                         attached: [AskClaudeChat.Attachment(path: download.path, name: download.fileName, isDirectory: false)])
        case .open:
            Task { @MainActor in
                let outcome = await askClaudeTools().openDownloaded(download)
                Logger.shared.info("Ask Claude opened a downloaded file: \(outcome.step)" + (outcome.isError ? " (refused)" : ""))
                chat.addNote(outcome.isError ? "Downloaded \(download.fileName), but: \(outcome.step)." : "\(outcome.step).")
            }
        }
    }

    /// TE246: puts the folder on screen on the Never show Claude list, or takes it off, and says so
    /// in the thread. Taken off by whichever entry covers it: the folder itself, or one above it.
    func askClaudeSetCurrentFolderHidden(_ hidden: Bool) {
        let folder = AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)
        let name = askClaudeFolder.isEmpty ? askClaudeSourceName : (askClaudeFolder as NSString).lastPathComponent
        askClaudeSetHidden(folder, name: name, hidden)
    }

    /// Puts a folder or file on the Never show Claude list, or takes it off, and says so in the
    /// thread (TE246; files too, TE263). Taken off by whichever entry covers it: itself, or a
    /// folder above it.
    func askClaudeSetHidden(_ folder: String, name: String, _ hidden: Bool) {
        if hidden {
            AskClaudePrivacy.hide(folder, in: .standard)
            askClaudeChat.addNote("Hid \(name) from Claude. Your next question starts a new chat, so nothing Claude saw of it stays.")
        } else {
            let covering = askClaudeHiddenEntries(covering: folder)
            covering.forEach { AskClaudePrivacy.unhide($0, in: .standard) }
            // Says what came off the list: a folder above this one shows everything in it again.
            let names = covering.map(askClaudeHiddenName)
            askClaudeChat.addNote(names.map { $0.lowercased() } == [name.lowercased()] || names.isEmpty
                ? "\(name) is no longer hidden from Claude."
                : "Removed \(names.joined(separator: ", ")) from the hidden list, so \(name) and everything else in it is shown to Claude again.")
        }
    }

    /// The Never show Claude entries that hide `path`: its own, or a folder's above it.
    private func askClaudeHiddenEntries(covering path: String) -> [String] {
        AskClaudePrivacy.hiddenFolders(in: .standard).filter { AskClaudePrivacy.isHidden(path, by: [$0]) }
    }

    /// An entry as the thread and the row menu name it; a source's own folder by the source's name.
    private func askClaudeHiddenName(_ entry: String) -> String {
        AskClaudePaths.same(entry, askClaudeRoot) ? askClaudeSourceName : (entry as NSString).lastPathComponent
    }

    /// The folder above a row whose entry hides it, by name, or nil when only its own entry
    /// hides it, or none: Show to Claude on that row takes the whole folder off (TE263).
    func askClaudeHiddenCover(_ path: String) -> String? {
        let above = askClaudeHiddenEntries(covering: path).filter { !AskClaudePaths.same($0, path) }
        return above.isEmpty ? nil : above.map(askClaudeHiddenName).joined(separator: ", ")
    }

    /// Go to This Folder (TE260): the folder Claude sees is always the one the source pane is at,
    /// so this only has work where the workspace has folded that pane away (Edit, Organize).
    func askClaudeShowFolderPane() {
        guard panesHiddenForCurrentTab else { return }
        togglePanesForCurrentTab()
    }

    // MARK: What Claude sees

    private var askClaudeInBrowse: Bool { selectedWorkspace == .browse }

    /// The type filter, as Claude's view of the screen states it (FN): the rows it is given are the
    /// whole folder, so it is told which of them the pane is showing — "these" means those.
    private var askClaudeTypeFilterNote: String {
        guard let filter = syncManager.leftTypeFilter else { return "" }
        let total = syncManager.leftTypeFilterFacts?.itemCountBeforeFilter ?? syncManager.leftItemCount
        return " · type filter on: the pane shows only \(filter.summary)"
            + " (\(syncManager.leftItemCount.formatted()) of \(total.formatted()) items)"
    }

    private var askClaudeRoot: String {
        (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath
    }

    private var askClaudeSourceName: String {
        settings.availableProviders.first { $0.id == leftProviderId }?.displayName ?? leftProviderId
    }

    /// The Browse pane’s folder, relative to its source: the one its header names.
    private var askClaudeFolder: String {
        syncManager.paneLocation(isLeft: true, drawsColumns: paneDrawsColumns(isLeft: true))
    }

    /// The folder Claude sees, for the panel's header and shield (TE260).
    var askClaudePlace: AskClaudePlace {
        let absolute = AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        // The file open in Edit only when Claude is told about it: one in a hidden folder isn't.
        let open = selectedWorkspace == .editor ? editorOpenPath.flatMap { hidden.isHidden($0) ? nil : ($0 as NSString).lastPathComponent } : nil
        return AskClaudePlace(source: askClaudeSourceName, folder: askClaudeFolder,
                              itemCount: askClaudeItems(absolute)?.count,
                              isHidden: hidden.isHidden(absolute),
                              isOnScreen: !panesHiddenForCurrentTab || selectedWorkspace == .browse || selectedWorkspace == .compare,
                              workspace: selectedWorkspace.title, openFile: open)
    }

    func askClaudeScreen(fallbackRows: [FileNode]? = nil) -> AskClaudeScreen {
        let folder = askClaudeFolder
        // One matcher for the whole card: rows share their folder's resolved spelling.
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        let absolute = AskClaudeBrowseTools.absolute(folder, root: askClaudeRoot)
        let all = askClaudeItems(absolute) ?? fallbackRows ?? []
        let shown = hidden.isEmpty ? all : all.filter { !hidden.isHidden($0.id) }
        var screen = AskClaudeScreen(workspace: selectedWorkspace.title, source: askClaudeSourceName, folder: folder,
                                     sort: syncManager.sortOption.rawValue, rows: shown.map(AskClaudeBrowseTools.row),
                                     selection: syncManager.selectedLeftPaths, toolsAvailable: true,
                                     sources: askClaudeSources.map(\.name))
        screen.hiddenCount = all.count - shown.count
        screen.folderHidden = hidden.isHidden(absolute)
        screen.tabs = askClaudeTabs.map(\.title)
        screen.panes = askClaudePanes
        if selectedWorkspace == .compare, let comparison = askClaudeComparison {
            let visible = syncManager.differences.filter { !hidden.isHidden($0.leftItemPath) && !hidden.isHidden($0.rightItemPath) }
            screen.differences = AskClaudeDifferences.summaryLine(visible, hiddenCount: syncManager.differences.count - visible.count,
                                                                  comparison: comparison, now: Date())
        }
        if selectedWorkspace == .editor, let open = editorOpenPath, !hidden.isHidden(open) {
            screen.openFile = AskClaudeDisk.node(atPath: open).map(AskClaudeBrowseTools.row)
        }
        screen.view = (paneDrawsColumns(isLeft: true) ? "columns" : "list") + " · hidden files " + (syncManager.showHiddenFiles ? "shown" : "hidden")
            + askClaudeTypeFilterNote
        if paneDrawsColumns(isLeft: true) { screen.columns = askClaudeColumns(hidden: hidden) }
        return screen
    }

    /// TE241: the parent columns on screen, from the pane's scope down to the folder before the
    /// one on screen, at most three, each as the pane has it loaded.
    private func askClaudeColumns(hidden: AskClaudePrivacy.Matcher) -> [AskClaudeScreen.Column] {
        let scope = syncManager.leftRelativePath
        let location = askClaudeFolder
        // At a folder boundary: scope "Tax" is not above "Taxes/2024".
        guard location != scope, scope.isEmpty || location.hasPrefix(scope + "/") else { return [] }
        let below = location.dropFirst(scope.count).split(separator: "/").map(String.init)
        var folders: [String] = [scope]
        for part in below.dropLast() { folders.append(folders.last!.isEmpty ? part : folders.last! + "/" + part) }
        return folders.enumerated().suffix(3).compactMap { index, folder in
            guard let items = askClaudeItems(AskClaudeBrowseTools.absolute(folder, root: askClaudeRoot)) else { return nil }
            let rows = items.filter { !hidden.isHidden($0.id) }.map(AskClaudeBrowseTools.row)
            return AskClaudeScreen.Column(folder: folder, rows: rows, open: below[index])
        }
    }

    private var askClaudeTabs: [AskClaudeBrowseTools.Tab] {
        let items = paneTabItems(isLeft: true)
        let active = items.filter(\.isActive) + items.filter { !$0.isActive }
        // A tab is titled with its folder's name, so a tab at a hidden folder isn't named. Checked
        // against the chip's own full path, which in Columns includes the columns clicked into.
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        let isHidden = active.map { item in
            hidden.isHidden(item.fullPath)
                || (item.isActive && hidden.isHidden(AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)))
        }
        // The strip tells same-named tabs apart by their parent ("Private — Work"), which counts
        // hidden tabs too and so hints at a hidden folder's name: titles are worked out again
        // from the visible tabs alone.
        let names = active.map { $0.title.components(separatedBy: " — ").first ?? $0.title }
        let visibleNames = zip(names, isHidden).filter { !$0.1 }.map(\.0)
        return active.indices.map { index in
            let item = active[index]
            guard !isHidden[index] else {
                return AskClaudeBrowseTools.Tab(id: item.id, title: "(hidden)", isPinned: item.isPinned, isHidden: true)
            }
            // The chip's own qualified title only where a visible tab shares the name.
            let title = visibleNames.filter { $0 == names[index] }.count > 1 ? item.title : names[index]
            return AskClaudeBrowseTools.Tab(id: item.id, title: title, isPinned: item.isPinned)
        }
    }

    /// Compare's two sides, as Claude is told them: "left: Dropbox › Documents/Work".
    private var askClaudePanes: [String] {
        guard selectedWorkspace == .compare else { return [] }
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        return [true, false].map { isLeft in
            let id = isLeft ? leftProviderId : rightProviderId
            let name = settings.availableProviders.first { $0.id == id }?.displayName ?? id
            let root = (settings.rootPath(for: id) as NSString).expandingTildeInPath
            let folder = syncManager.paneLocation(isLeft: isLeft, drawsColumns: paneDrawsColumns(isLeft: isLeft))
            let shown = hidden.isHidden(AskClaudeBrowseTools.absolute(folder, root: root)) ? "(a folder hidden from Claude)"
                : folder.isEmpty ? "(top level)" : folder
            return "\(isLeft ? "left" : "right"): \(name) › \(shown)"
        }
    }

    /// Compare's two sides and how fresh their comparison is (TE261); nil without two sources.
    var askClaudeComparison: AskClaudeDifferences.Comparison? {
        func name(_ id: String) -> String { settings.availableProviders.first { $0.id == id }?.displayName ?? id }
        guard !leftProviderId.isEmpty, !rightProviderId.isEmpty else { return nil }
        let left = name(leftProviderId), right = name(rightProviderId)
        return AskClaudeDifferences.Comparison(
            leftName: left, rightName: right,
            leftFolder: syncManager.leftRelativePath, rightFolder: syncManager.rightRelativePath,
            readAt: syncManager.lastScanReadAt ?? syncManager.lastScanDate,
            // The folders' reads count: the scan itself starts only once both are read.
            isScanning: syncManager.isScanning || syncManager.isRefreshing, hasScanned: syncManager.hasScanned,
            partial: syncManager.lastScanCoverage.message(leftName: left, rightName: right))
    }

    /// One side's live source and folder, for go_to's pane moves.
    private func askClaudePane(isLeft: Bool) -> AskClaudeBrowseTools.Pane {
        let id = isLeft ? leftProviderId : rightProviderId
        return AskClaudeBrowseTools.Pane(sourceID: id, root: (settings.rootPath(for: id) as NSString).expandingTildeInPath,
                                         folder: syncManager.paneLocation(isLeft: isLeft, drawsColumns: paneDrawsColumns(isLeft: isLeft)))
    }

    /// A folder’s items as the Browse pane has them, or nil when the pane hasn’t loaded it.
    private func askClaudeItems(_ absoluteFolder: String) -> [FileNode]? {
        // Looked up by the real spelling, the one the pane's tree holds (AskClaudePaths).
        let target = AskClaudePaths.canonical(absoluteFolder)
        let scope = AskClaudePaths.canonical(AskClaudeBrowseTools.absolute(syncManager.leftRelativePath, root: askClaudeRoot))
        // The whole folder, past any type filter: Claude is told the filter is on (`screen.view`),
        // and answers "what's in Downloads?" from everything in it (FN).
        if target == scope { return syncManager.leftTreeBeforeTypeFilter }
        guard let node = askClaudeNode(target) ?? askClaudeNode(absoluteFolder),
              node.isDirectory, node.isUnexplored != true else { return nil }
        return node.children ?? []
    }

    /// A node of the left pane's folder, filtered or not — the published index while the pane has
    /// no type filter, and the tree before the filter while it does.
    private func askClaudeNode(_ path: String) -> FileNode? {
        guard syncManager.leftTypeFilter != nil else { return syncManager.leftNodes(for: [path]).first }
        return syncManager.leftNodes(for: [path]).first
            ?? syncManager.leftTreeBeforeTypeFilter.findNodes(at: [path]).first
    }

    /// Why Claude can’t move the view right now (decision EB): it never moves under a sheet, a
    /// destination pick, or a question the window is waiting on.
    var askClaudeBusyReason: String? {
        if let reason = askClaudeStateBusy { return reason }
        // A sheet on the main window (a PDF tool, a Save panel), read live when a tool runs.
        if NSApp.mainWindow?.attachedSheet != nil { return "a sheet is open" }
        return nil
    }

    /// The busy reasons the window's own state answers, which SwiftUI redraws for; sheets are
    /// read live instead (the panel's anchor watches them), since nothing redraws when one closes.
    var askClaudeStateBusy: String? {
        if pendingDestination != nil { return "they are picking a destination" }
        if editorDivergenceReview != nil { return "a question about an edited file is open" }
        if showSettings { return "Settings is open" }
        if showHelp { return "Help is open" }
        if showSetup || shouldAutoShowSetup { return "setup is open" }
        if syncManager.currentError != nil { return "an error message is open" }
        return nil
    }

    /// The sources the Browse pane can switch to, with absolute roots.
    private var askClaudeSources: [AskClaudeBrowseTools.Source] {
        // The pane's own list: a source switched off in Settings is one no refresh walks.
        settings.enabledProviders.map {
            AskClaudeBrowseTools.Source(id: $0.id, name: $0.displayName, root: ($0.rootPath as NSString).expandingTildeInPath)
        }
    }

    func askClaudeToolsContext() -> AskClaudeBrowseTools.Context {
        AskClaudeBrowseTools.Context(
            inBrowse: askClaudeInBrowse,
            sourceName: askClaudeSourceName,
            root: askClaudeRoot,
            folder: askClaudeFolder,
            sort: syncManager.sortOption,
            items: { askClaudeItems($0) },
            node: { askClaudeNode(AskClaudePaths.canonical($0)) ?? askClaudeNode($0) },
            selection: syncManager.selectedLeftPaths,
            busyReason: askClaudeBusyReason,
            // Navigation by the root's own spelling, which is what the palette's route resolves,
            // and always the left pane: the palette's routes follow the focused pane, which in
            // Compare can be the right one.
            goTo: { movePane(isLeft: true, providerId: nil, absolutePath: AskClaudePaths.spelled($0, root: askClaudeRoot)) },
            select: { paths in
                // Selecting a row the type filter hides clears the filter first (FM), or the
                // selection prune would take it straight back off.
                for path in paths { syncManager.clearTypeFilterHiding(path, isLeft: true) }
                syncManager.selectedLeftPaths = paths
                if !syncManager.selectedRightPaths.isEmpty { syncManager.selectedRightPaths = [] }
            },
            sourceID: leftProviderId,
            sources: askClaudeSources,
            // ⌘K's own routes, so a source switch lands where the palette's would.
            switchSource: { id, folder in
                let root = askClaudeSources.first { $0.id == id }?.root ?? askClaudeRoot
                movePane(isLeft: true, providerId: id, absolutePath: folder.map { AskClaudePaths.spelled($0, root: root) })
            },
            switchWorkspace: { name in
                guard let workspace = Workspace.allCases.first(where: { $0.title.compare(name, options: .caseInsensitive) == .orderedSame })
                else { return false }
                workspaceSelection.wrappedValue = workspace
                return true
            },
            openInEdit: { path in
                switch handOffToEditor(path) {
                case .cancelled: return .notNow
                // Edit loads a file it then refuses (a kind it can't show), and says so itself.
                case .opened, .alreadyOpen: return editorOpenPath.map { AskClaudePaths.same($0, path) } == true ? .opened : .refused
                }
            },
            hidden: AskClaudePrivacy.hiddenFolders(in: .standard),
            readsFiles: AskClaudePrivacy.readsFiles(in: .standard),
            tabs: askClaudeTabs,
            switchTab: { selectTab(id: $0, isLeft: true) },
            addTab: { openInNewTab(absolutePath: $0, isLeft: true) },
            closeTabs: { ids in
                // Each by the strip's own verb. The last tab is never among them: closing it
                // closes the window.
                Logger.shared.info("Ask Claude closing \(ids.count) left pane browse tab\(ids.count == 1 ? "" : "s")")
                for id in ids where syncManager.paneTabs(isLeft: true).tabs.count > 1 { closeTab(id: id, isLeft: true) }
            },
            pane: { askClaudePane(isLeft: $0) },
            movePane: { isLeft, sourceID, absolute in movePane(isLeft: isLeft, providerId: sourceID, absolutePath: absolute) },
            differences: { syncManager.differences },
            comparison: { askClaudeComparison },
            rescan: {
                guard askClaudeBusyReason == nil else { return false }
                // Scan Again's own two steps, so a refresh refused (a side's source switched off)
                // is reported, not waited for.
                Logger.shared.info("User requested a force refresh, through Ask Claude")
                syncManager.prepareForcedRescan()
                return refreshAction()
            },
            showDifferences: { kind, ids in
                // The list's own filters; "changed" picks a direction when every row shares one.
                let rows = syncManager.differences.filter { ids.contains($0.id) }
                let filter: DifferenceFilter
                switch kind {
                case .onlyLeft: filter = .missingOnRight
                case .onlyRight: filter = .missingOnLeft
                case .nameConflicts: filter = .nameConflicts
                case .changed where rows.allSatisfy({ $0.action == .copyToRight }): filter = .changedCopyToRight
                case .changed where rows.allSatisfy({ $0.action == .copyToLeft }): filter = .changedCopyToLeft
                default: filter = .all
                }
                Logger.shared.info("Ask Claude showed \(ids.count) difference\(ids.count == 1 ? "" : "s") in Compare’s list")
                differencesSession.show(filter, selecting: ids)
                return true
            },
            whereToFile: { path, place in
                // Page 1 read on this Mac (decision EW) by To File's reader, which leaves a file
                // only in the cloud unread rather than fetch it (`FilingSurvey.isAvailable`), so
                // that one is placed by its name, as To File places it. A large one isn't even
                // offered to it.
                let size = AskClaudeDisk.node(atPath: path)?.fileSize
                let fetches = MaterializationStatus.isCloudOnlyIfKnown(atPath: MaterializationStatus.linkTarget(of: path)) == true
                    && (size ?? .max) > AskClaudeBrowseTools.autoDownloadBytes
                let page = fetches ? nil : await syncManager.filingHelpPage(path)
                let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
                return await syncManager.whereToFile(path, snippet: page, preferring: place, isHidden: { hidden.isHidden($0) })
            },
            surveyFolder: { syncManager.filingSurveyFolder(named: $0) },
            surveyRoot: syncManager.filingFolderProfile?.recordedFolderPath,
            canRefineFiling: syncManager.filingHelpCanRefine,
            history: { forward in
                let columns = paneDrawsColumns(isLeft: true)
                guard forward ? syncManager.canGoForward(isLeft: true, drawsColumns: columns)
                              : syncManager.canGoBack(isLeft: true, drawsColumns: columns) else { return false }
                if forward { syncManager.goForward(isLeft: true, drawsColumns: columns) }
                else { syncManager.goBack(isLeft: true, drawsColumns: columns) }
                return true
            },
            preview: { quickLookURL = $0 },
            setSort: { name in
                let wanted = name.lowercased() == "date" ? "date modified" : name.lowercased()
                guard let option = SortOption.allCases.first(where: { $0.rawValue.lowercased() == wanted }) else { return false }
                syncManager.sortOption = option
                return true
            },
            setHiddenFiles: { syncManager.showHiddenFiles = $0 },
            setMode: { name in
                switch name.lowercased() {
                case "columns": browseViewModeBinding.wrappedValue = .columns
                case "list", "tree": browseViewModeBinding.wrappedValue = .tree
                default: return false
                }
                return true
            },
            showPlace: { place, tab, visible in
                switch place {
                case "settings":
                    // A tab by name, or the tab holding a named setting ("Ask Claude", "Monthly
                    // limit"), by Settings' own search index; Intelligence when it's about this chat.
                    let wanted = tab?.lowercased()
                    let chosen = SettingsView.SettingsTab.allCases.first { $0.displayName.lowercased() == wanted || $0.rawValue == wanted }
                        ?? tab.flatMap(SettingsView.SettingsTab.holding)
                        ?? (tab == nil ? .intelligence : nil)
                    guard let chosen else { return false }
                    openSettings(on: chosen)
                case "info", "inspector":
                    withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) { showInspector = visible }
                case "sidebar":
                    guard folderSidebarIsAvailable else { return false }
                    setFolderSidebarVisible(visible)
                case "activity", "log", "activity log":
                    openWindow(id: ActivityCenter.windowID)
                case "help":
                    showHelp = true
                case "trash":
                    // As the sidebar's own Trash row does: the Trash is Finder's to show.
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSHomeDirectory() + "/.Trash")
                default:
                    return false
                }
                return true
            })
    }
}

/// Hosts the panel over the window’s content and publishes ⌘J’s binding. One modifier rather than
/// two calls, so the window’s long modifier chain stays within what the type checker can solve.
struct AskClaudeHost: ViewModifier {
    let visibility: AskClaudeVisibility
    /// Settings, Help, setup, a destination pick or a question is up: the panel steps aside.
    let isBusy: Bool
    let panel: (CGSize, @escaping (CGRect) -> Void) -> AnyView
    let toggle: Binding<Bool>?
    /// The Never show Claude list changed (TE263: the row menus' labels follow it).
    var onPrivacyChange: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) { AskClaudeOverlay(visibility: visibility, isBusy: isBusy, panel: panel) }
            .onReceive(NotificationCenter.default.publisher(for: AskClaudePrivacy.didChange)) { _ in onPrivacyChange() }
            .focusedSceneValue(\.askClaude, toggle)
            // The View menu's tick reads this, so it follows the panel without the window redrawing.
            .focusedSceneObject(visibility)
    }
}

/// The area the panel lives in, and the one view that watches whether it is open. The panel
/// itself is in a child window over this area (AskClaudeWindow.swift).
private struct AskClaudeOverlay: View {
    @ObservedObject var visibility: AskClaudeVisibility
    let isBusy: Bool
    let panel: (CGSize, @escaping (CGRect) -> Void) -> AnyView
    @State private var controller = AskClaudeWindowController()
    /// Bumped when the hidden list changes: the window doesn't redraw for that, and the panel's
    /// header and shield must (the panel is rebuilt from live state each time this body runs).
    @State private var privacyChanges = 0

    var body: some View {
        // The space the panel may move in (TE248).
        GeometryReader { geo in
            let controller = controller
            let _ = privacyChanges
            let visibility = visibility
            // Built only while open: every redraw of the window rebuilds it otherwise.
            AskClaudeWindowAnchor(controller: controller, isOpen: visibility.isOpen, isSuspended: isBusy,
                                  content: visibility.isOpen ? panel(geo.size) { controller.panelRect = $0 } : AnyView(EmptyView()),
                                  onClose: { visibility.isOpen = false })
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .onReceive(NotificationCenter.default.publisher(for: AskClaudePrivacy.didChange)) { _ in privacyChanges += 1 }
        // A row's Ask Claude About This brings an open panel's text box the keyboard (TE263).
        .onChange(of: visibility.focusRequests) { controller.focus() }
    }
}

/// The toolbar's Ask Claude button, tinted while the panel is open. Its own view so that only it
/// redraws when the panel opens or closes.
struct AskClaudeToolbarButton: View {
    @ObservedObject var visibility: AskClaudeVisibility
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Ask Claude", systemImage: "bubble.left.and.text.bubble.right")
                .foregroundStyle(visibility.isOpen ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                .shortcutKeycap(AppChord.askClaude.display)
        }
        .help(ShortcutHint.tooltip("Ask Claude", AppChord.askClaude.display))
        .accessibilityLabel("Ask Claude")
        .accessibilityAddTraits(visibility.isOpen ? .isSelected : [])
    }
}
