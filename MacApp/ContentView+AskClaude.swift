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
                           onAsk: { askClaudeAsk($0) },
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
                           onPlace: onPlace)
    }

    /// The panel's host, built here rather than in `body`: the window's modifier chain is at the
    /// edge of what the type checker solves in time, and a generic closure there tipped it over.
    var askClaudeHost: AskClaudeHost {
        AskClaudeHost(visibility: askClaudeHolder.visibility, isBusy: askClaudeStateBusy != nil,
                      panel: { AnyView(askClaudeOverlay(in: $0, onPlace: $1)) }, toggle: askClaudeChordBinding)
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

    func askClaudeAsk(_ question: String, shown: String? = nil) {
        let tools = askClaudeTools()
        // TE241: a folder the pane hasn't loaded is read from disk first, so the screen is never
        // sent empty while the person is looking at files.
        let folder = AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)
        guard askClaudeItems(folder) == nil else {
            askClaudeChat.ask(question, shown: shown, screen: askClaudeScreen(), tools: tools)
            return
        }
        askClaudeChat.ask(question, shown: shown, preparing: {
            let fromDisk = await AskClaudeDisk.list(folder) ?? []
            return askClaudeScreen(fallbackRows: fromDisk)
        }, tools: tools)
    }

    /// TE246: puts the folder on screen on the Never show Claude list, or takes it off, and says so
    /// in the thread. Taken off by whichever entry covers it: the folder itself, or one above it.
    func askClaudeSetCurrentFolderHidden(_ hidden: Bool) {
        let folder = AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)
        let name = askClaudeFolder.isEmpty ? askClaudeSourceName : (askClaudeFolder as NSString).lastPathComponent
        if hidden {
            AskClaudePrivacy.hide(folder, in: .standard)
            askClaudeChat.addNote("Hid \(name) from Claude. Your next question starts a new chat, so nothing Claude saw of it stays.")
        } else {
            let covering = AskClaudePrivacy.hiddenFolders(in: .standard).filter { AskClaudePrivacy.isHidden(folder, by: [$0]) }
            covering.forEach { AskClaudePrivacy.unhide($0, in: .standard) }
            // Says what came off the list: a folder above this one shows everything in it again.
            // A source's own folder is called by the source's name.
            let names = covering.map { entry in
                AskClaudePaths.same(entry, askClaudeRoot) ? askClaudeSourceName : (entry as NSString).lastPathComponent
            }
            askClaudeChat.addNote(names.map { $0.lowercased() } == [name.lowercased()] || names.isEmpty
                ? "\(name) is no longer hidden from Claude."
                : "Removed \(names.joined(separator: ", ")) from the hidden list, so \(name) and everything else in it is shown to Claude again.")
        }
    }

    /// Go to This Folder (TE249): the folder Claude sees is always the one the source pane is at,
    /// so this only has work where the workspace has folded that pane away (Edit, Organize).
    func askClaudeShowFolderPane() {
        guard panesHiddenForCurrentTab else { return }
        togglePanesForCurrentTab()
    }

    // MARK: What Claude sees

    private var askClaudeInBrowse: Bool { selectedWorkspace == .browse }

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

    /// The folder Claude sees, for the panel's header and shield (TE249).
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
        if selectedWorkspace == .editor, let open = editorOpenPath, !hidden.isHidden(open) {
            screen.openFile = AskClaudeDisk.node(atPath: open).map(AskClaudeBrowseTools.row)
        }
        screen.view = (paneDrawsColumns(isLeft: true) ? "columns" : "list") + " · hidden files " + (syncManager.showHiddenFiles ? "shown" : "hidden")
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
        if target == scope { return syncManager.leftTree }
        guard let node = syncManager.leftNodes(for: [target]).first ?? syncManager.leftNodes(for: [absoluteFolder]).first,
              node.isDirectory, node.isUnexplored != true else { return nil }
        return node.children ?? []
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
            node: { syncManager.leftNodes(for: [AskClaudePaths.canonical($0)]).first ?? syncManager.leftNodes(for: [$0]).first },
            selection: syncManager.selectedLeftPaths,
            busyReason: askClaudeBusyReason,
            // Navigation by the root's own spelling, which is what the palette's route resolves,
            // and always the left pane: the palette's routes follow the focused pane, which in
            // Compare can be the right one.
            goTo: { movePane(isLeft: true, providerId: nil, absolutePath: AskClaudePaths.spelled($0, root: askClaudeRoot)) },
            select: { paths in
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

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) { AskClaudeOverlay(visibility: visibility, isBusy: isBusy, panel: panel) }
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
