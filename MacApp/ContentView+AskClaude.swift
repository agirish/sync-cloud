import SwiftUI
import Sync
import Settings
import Dashboard
import FileExplorer
import Design
import Events

/// Ask Claude’s wiring into the window: the panel, the screen it describes, and the window state
/// its tools read and move. An extension because the tools need ContentView’s own state: the
/// workspace, the Browse pane’s location, the overlays that make the window busy.
extension ContentView {

    var askClaudeChat: AskClaudeChat { askClaudeHolder.chat }

    /// Whether the panel is the window's column rather than a floating window: the pin is on,
    /// Info is closed (the two take turns on the right edge), and the window has the room.
    var askClaudePinnedShown: Bool { askClaudePinned && !showInspector && askClaudePinState.fits }

    /// Why a panel that is pinned is floating, if it is: Info is open, or the window is too narrow.
    var askClaudePinWaiting: AskClaudePanel.Waiting? {
        guard askClaudePinned, !askClaudePinnedShown else { return nil }
        return askClaudePinState.fits ? .info : .narrow
    }

    /// Whether the room rule folds a pane for the column on this workspace: Organize's folder pane,
    /// with its sidebar, or Edit's file list. Not stored anywhere.
    var askClaudePinFoldWanted: Bool {
        askClaudePinnedShown && askClaudePinState.folds && (selectedWorkspace == .filing || selectedWorkspace == .editor)
    }

    /// The pin is folding now: wanted, and not ended by the person opening the pane by hand.
    var askClaudePinFoldActive: Bool { askClaudePinFoldWanted && !askClaudePinFoldReleased }

    /// The person opened a pane the pin folded: ends the pin's fold. True when it did, so the act
    /// that asked (the spine's button, a Files button) leaves the stored fold alone.
    @discardableResult
    func askClaudeReleasePinFold() -> Bool {
        guard askClaudePinFoldActive else { return false }
        askClaudePinFoldReleased = true
        return true
    }

    /// The fold ended, or never began: the next one starts from the pin's own choice again.
    func askClaudePinFoldEnded() {
        askClaudePinFoldReleased = false
        askClaudePinSidebarShown = false
    }

    /// The workspace, as the room rule knows it.
    private var askClaudePinWorkspace: PaneLogic.PinWorkspace {
        switch selectedWorkspace {
        case .browse: .browse
        case .compare: .compare
        case .filing: .organize
        case .editor: .edit
        }
    }

    /// Everything the room rule reads, so a change in any of it runs the rule once.
    var askClaudePinInput: PaneLogic.PinRoomInput {
        let dragging = folderSidebarDragOrigin != nil || editorColumnDragOrigin != nil || paneDragFraction != nil
            || verticalDragFraction != nil || railDragFraction != nil || inspectorDragWidth != nil
            || askClaudePinnedDragWidth != nil || askClaudeWindowResizing
        return PaneLogic.PinRoomInput(
            workspace: askClaudePinWorkspace,
            rowWidth: askClaudeRowWidth,
            columnWidth: (askClaudePinnedDragWidth ?? askClaudePinnedWidth) + PaneLogic.sidebarSeamWidth,
            gutter: LiquidGlass.gutter(surfaceStyle),
            sidebarShown: folderSidebarPreference(for: selectedWorkspace) && selectedWorkspace.supportsFolderSidebar,
            sidebarStored: CGFloat(browseSidebarWidthRaw),
            // Nothing for the pin to fold where the person already has: Edit with the pane folded and
            // the list folded or put away too, Organize with its pane folded.
            foldedByHand: selectedWorkspace == .editor
                ? editorPaneIsFolded && (editorRailFolded || editorRailHidden) : panesStoredHiddenForCurrentTab,
            editColumn: CGFloat(editorColumnWidthRaw),
            dragging: dragging,
            canFold: true)
    }

    /// Runs the room rule. Called as its input changes.
    func askClaudePinInputChanged(_ input: PaneLogic.PinRoomInput) {
        let verdict = PaneLogic.pinRoom(input, previous: askClaudePinState)
        if verdict != askClaudePinState {
            withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) { askClaudePinState = verdict }
        }
    }

    /// The 📌: pins the panel to the window's right edge, or lets it go. Pinning closes Info, which
    /// would otherwise take the edge, but only when the window has the room for the column.
    func toggleAskClaudePin() {
        let turningOn = !askClaudePinned
        withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) {
            askClaudePinned = turningOn
            if turningOn, askClaudePinState.fits { showInspector = false }
        }
        askClaudeHolder.visibility.focusRequests += 1
    }

    /// The pin went on without the 📌 (Settings): the same as pinning from the panel, minus the
    /// keyboard, which Settings has.
    func askClaudePinnedOn() {
        guard showInspector, askClaudePinState.fits else { return }
        withDesignAnimation(.easeInOut(duration: 0.15), reduceMotion: reduceMotion) { showInspector = false }
    }

    /// How far in from the window's right edge a floating panel stays, so it never covers Info: Info's
    /// width while Info is why the pin is floating. The saved place does not change.
    var askClaudeInfoInset: CGFloat {
        askClaudePinned && showInspector ? CGFloat(inspectorDragWidth ?? inspectorWidth) + PaneLogic.sidebarSeamWidth : 0
    }

    /// The pinned column, after the Info inspector. Its own view observes whether the panel is open.
    var askClaudeColumn: some View {
        AskClaudeColumnSlot(
            visibility: askClaudeHolder.visibility, controller: askClaudeHolder.windowController,
            pinned: askClaudePinnedShown, width: askClaudePinnedDragWidth ?? askClaudePinnedWidth,
            surface: surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint,
            onDrag: { askClaudePinnedDragWidth = AskClaudePanel.pinnedDragWidth(base: askClaudePinnedWidth, translation: $0) },
            onCommit: {
                if let width = askClaudePinnedDragWidth { askClaudePinnedWidth = width }
                askClaudePinnedDragWidth = nil
            })
    }

    func toggleAskClaude() {
        // Pinned, it slides like Info does; floating, as it always has.
        withDesignAnimation(askClaudePinnedShown ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.12), reduceMotion: reduceMotion) {
            // Opening with the pin on is pinning: Info, which would take the edge, closes if the
            // window has the room for the column.
            if !askClaudeHolder.visibility.isOpen, askClaudePinned, showInspector, askClaudePinState.fits { showInspector = false }
            askClaudeHolder.visibility.isOpen.toggle()
        }
    }

    /// The panel, hanging from the toolbar over the content’s right edge.
    func askClaudeOverlay(in container: CGSize, onPlace: @escaping (CGRect) -> Void) -> some View {
        // Once: a question typed while Claude answers is sent from here when the answer ends,
        // with the panel open or not.
        if askClaudeChat.sendQueued == nil {
            askClaudeChat.sendQueued = { waiting in askClaudeSend(waiting.text, attached: waiting.attachments, spoken: waiting.spoken) }
        }
        // Retry: a question from the box goes as the box sends; any other as it went, minus any
        // chip hidden since.
        if askClaudeChat.askAgain == nil {
            askClaudeChat.askAgain = { asked, shown, spoken in
                if asked.editable {
                    askClaudeSend(asked.question, attached: asked.attachments, spoken: spoken)
                } else {
                    let attached = asked.attachments.filter { !askClaudeIsHidden($0.path) }
                    askClaudeAsk(asked.question, shown: shown, attached: attached, spoken: spoken)
                }
            }
        }
        return AskClaudePanel(chat: askClaudeChat,
                              place: askClaudePlace,
                              accent: glassHue.accentColor,
                              accentFill: glassHue.accentFillColor,
                              onAccent: glassHue.onAccentLabelColor,
                              hue: glassHue,
                              tint: surfaceTint,
                              level: glassLevel,
                              onAsk: { askClaudeSend($0) },
                              onClose: { toggleAskClaude() },
                              onOpenSettings: { openSettings(on: SettingsPlace($0)) },
                              container: CGSize(width: max(0, container.width - askClaudeInfoInset), height: container.height),
                              pinned: askClaudePinnedShown,
                              surface: surfaceStyle,
                              pinOn: askClaudePinned,
                              waiting: askClaudePinWaiting,
                              onTogglePin: { toggleAskClaudePin() },
                              focusToken: askClaudeHolder.visibility.focusRequests,
                              onTalkingChange: { askClaudeHolder.visibility.isTalking = $0 },
                              onSetAccess: { askClaudeSetCurrentFolderAccess($0) },
                              onGoToFolder: { askClaudeShowFolderPane() },
                              onReveal: { path in Task { await askClaudeTools().reveal(path: path) } },
                              onSendOffer: { id, part in
                                  let offer = switch part {
                                  case .names: askClaudeChat.takeFound(id)
                                  default: askClaudeChat.takeOffer(id, part)
                                  }
                                  guard let offer else { return }
                                  askClaudeAsk(offer.question, shown: offer.shown)
                              },
                              onFoundTick: { askClaudeChat.tickFound($0, $1) },
                              onDownloadCard: { askClaudeDownloadCard($0, $1) },
                              onFilingCard: { askClaudeFilingCard($0) },
                              onPlanCard: { askClaudePlanCard($0, $1) },
                              onChoice: { id, index in
                                  guard let choice = askClaudeChat.takeChoice(id, at: index) else { return }
                                  if let sends = choice.sends { askClaudeSend(sends) } else { askClaudeHolder.visibility.focusRequests += 1 }
                              },
                              onRuleCard: { askClaudeRuleCard($0, save: $1) },
                              settingsBridge: askClaudeSettingsBridge,
                              pdfBridge: askClaudePDFBridge,
                              refineBridge: askClaudeRefineBridge,
                              onPlace: onPlace,
                              onAskSpoken: { askClaudeSend($0, spoken: true) },
                              voiceHints: { askClaudeVoiceHints() })
    }

    /// The panel's host, built here rather than in `body`: the window's modifier chain is at the
    /// edge of what the type checker solves in time, and a generic closure there tipped it over.
    var askClaudeHost: AskClaudeHost {
        AskClaudeHost(visibility: askClaudeHolder.visibility, controller: askClaudeHolder.windowController,
                      isPinned: askClaudePinnedShown, pinInput: askClaudePinInput,
                      onPinInput: { askClaudePinInputChanged($0) }, onLiveResize: { askClaudeWindowResizing = $0 },
                      isPinOn: askClaudePinned, onPinnedOn: { askClaudePinnedOn() },
                      foldWanted: askClaudePinFoldWanted, onFoldEnded: { askClaudePinFoldEnded() },
                      pinToggle: askClaudePinBinding,
                      isBusy: askClaudeStateBusy != nil,
                      panel: { AnyView(askClaudeOverlay(in: $0, onPlace: $1)) }, toggle: askClaudeChordBinding,
                      onPrivacyChange: { askClaudePrivacyChanges += 1 })
    }

    /// ⌘J’s binding: nil while the window is busy (a destination pick, Settings, Help, setup, an
    /// error), as the toolbar button is disabled then.
    var askClaudeChordBinding: Binding<Bool>? {
        // Not under a sheet or overlay the panel would open beneath, out of sight, taking the keys.
        guard askClaudeStateBusy == nil else { return nil }
        let visibility = askClaudeHolder.visibility
        let pinned = askClaudePinnedShown
        return Binding(get: { visibility.isOpen }, set: { wanted in
            // Pinned, ⌘J closes only from inside the panel, and not while a question is spoken:
            // from anywhere else it takes you to the text box, as the toolbar button cannot.
            if !wanted, visibility.isOpen, pinned {
                if visibility.isTalking { return }
                if AskClaudeColumnView.holder(in: NSApp.keyWindow) == nil {
                    visibility.focusRequests += 1
                    return
                }
            }
            visibility.isOpen = wanted
        })
    }

    /// View ▸ Pin Ask Claude's binding: the pin, through the same action as the 📌.
    var askClaudePinBinding: Binding<Bool> {
        Binding(get: { askClaudePinned }, set: { _ in toggleAskClaudePin() })
    }

    func askClaudeTools() -> AskClaudeBrowseTools {
        AskClaudeBrowseTools(context: { askClaudeToolsContext() })
    }

    func askClaudeAsk(_ question: String, shown: String? = nil, attached: [AskClaudeChat.Attachment] = [], spoken: Bool = false,
                      editable: Bool = false) {
        // Kept for the at-limit card's Ask Again, which asks this same question again.
        askClaudeChat.lastAsked = (shown, attached)
        let tools = askClaudeTools()
        let attachedRows = askClaudeAttachedRows(attached)
        // A folder the pane hasn't loaded is read from disk first, so the screen is never sent
        // empty while the person is looking at files.
        let folder = AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)
        guard askClaudeItems(folder) == nil else {
            var screen = askClaudeScreen()
            screen.attached = attachedRows
            askClaudeChat.ask(question, shown: shown, spoken: spoken, attached: attached, editable: editable, screen: screen, tools: tools)
            return
        }
        askClaudeChat.ask(question, shown: shown, spoken: spoken, attached: attached, editable: editable, preparing: {
            let fromDisk = await AskClaudeDisk.list(folder) ?? []
            var screen = askClaudeScreen(fallbackRows: fromDisk)
            screen.attached = attachedRows
            return screen
        }, tools: tools)
    }

    /// The text box's Send: the question, about the chips above it. A chip hidden from Claude
    /// since it was attached is dropped, never sent.
    func askClaudeSend(_ question: String, spoken: Bool = false) {
        guard !askClaudeChat.isRunning else { return }
        askClaudeSend(question, attached: askClaudeChat.takeAttachments(), spoken: spoken)
    }

    /// A question with the chips it was asked about: the box's, or a queued question's own.
    func askClaudeSend(_ question: String, attached chips: [AskClaudeChat.Attachment], spoken: Bool) {
        guard !askClaudeChat.isRunning else { return }
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        let attached = chips.filter { !hidden.isHidden($0.path) }
        let shown = attached.isEmpty ? nil : question + "\nAbout " + attached.map(\.name).joined(separator: ", ")
        askClaudeAsk(question, shown: shown, attached: attached, spoken: spoken, editable: true)
    }

    /// The words a spoken question is listened for: from what the screen card would show Claude,
    /// and the chips it would send, so nothing hidden from Claude is ever one.
    func askClaudeVoiceHints() -> [String] {
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        let attached = askClaudeChat.attachments.filter { !hidden.isHidden($0.path) }.map { ($0.name, $0.isDirectory) }
        return AskClaudeVoiceHints.words(on: askClaudeScreen(), attached: attached)
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

    /// A row's Ask Claude About This: the panel opens, or comes forward, with these attached above
    /// its text box and the caret in it.
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

    /// Why a row's Ask Claude About This can't take these, for its tooltip, or nil.
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

    /// A download card's buttons. Download checks again at the click, waits, and then asks the
    /// question again (a read) or opens the file (an open), with no Claude round for that.
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

    /// A rule card's answer: Save stores the rule only now, on his click; Not Now stores nothing.
    /// Claude is told either way, with the next question.
    func askClaudeRuleCard(_ id: UUID, save: Bool) {
        guard !askClaudeChat.isRunning, let card = askClaudeChat.offeredRule(id) else { return }
        if save {
            syncManager.saveCorrectionRule(card.correction)
            SettingsChangeLog.shared.record(SettingsChange(setting: "organize.rules", name: "Rule “\(card.rule.name)”",
                                                           from: nil, to: nil, fromLabel: nil, toLabel: nil, how: .rule))
            askClaudeChat.answerRule(id, .saved)
            // A held card (one Claude wasn't told of) says no more when answered: its words
            // matched the file's first page, which is the very thing kept from Claude.
            askClaudeChat.tellClaude(card.held == true ? "They saved a rule from a card." : "They saved your rule “\(card.rule.name)”.")
        } else {
            askClaudeChat.answerRule(id, .declined)
            Logger.shared.info("Ask Claude rule card: Not Now on “\(card.rule.name)”")
            if card.held != true {
                askClaudeChat.tellClaude("They chose Not Now on your rule “\(card.rule.name)”; nothing was saved.")
            }
        }
    }

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
            guard askClaudeChat.plan(id)?.state == .proposed else { return }
            // Spelled as the panel gave it, which keeps a link's spelling (iCloud's Documents).
            let path = url.path
            guard !askClaudeIsHidden(path) else {
                askClaudeChat.addNote("\(url.lastPathComponent) is hidden from Claude, so it can’t be chosen here.")
                return
            }
            let label = AskClaudeBrowseTools.breadcrumb(path, sources: askClaudeSources, fallback: url.lastPathComponent)
            askClaudeChat.updatePlan(id) { $0.choose(AskClaudePlan.Choice(label: label, path: path), forRow: row) }
        case .apply:
            askClaudeApplyPlan(id)
        case .quickLook(let path):
            guard !askClaudeIsHidden(path), FileManager.default.fileExists(atPath: path) else {
                askClaudeChat.addNote("\((path as NSString).lastPathComponent) isn’t there to preview any more.")
                return
            }
            quickLookURL = URL(fileURLWithPath: path)
        case .goTo(let folder):
            Task { @MainActor in
                let outcome = await askClaudeTools().goToFolder(folder)
                if outcome.isError { askClaudeChat.addNote("Couldn’t go there: \(outcome.step).") }
            }
        case .next:
            guard let ask = askClaudeChat.plan(id)?.nextAsk else { return }
            askClaudeSend(ask)
        case .notNow:
            guard askClaudeChat.plan(id)?.state == .proposed else { return }
            askClaudeChat.updatePlan(id) { $0.state = .declined }
            if let title = askClaudeChat.plan(id)?.title {
                askClaudeChat.tellClaude("They chose Not Now on your card “\(title)”; nothing changed.")
            }
        case .undo:
            guard let plan = askClaudeChat.plan(id), let name = plan.undoName else { return }
            // Only while this card's own Apply is the step on top: cards share names, and an Undo
            // under something done since would take back that instead.
            let applied = plan.rows.filter { $0.applied == true }.map { (id: $0.id, change: $0.change) }
            guard let token = plan.undoToken, let undoing = syncManager.undoPlan(token, named: name, applied: applied) else {
                askClaudeChat.addNote("This card can’t be undone from here: something else was done or undone since. Edit ▸ Undo takes back the latest step first.")
                return
            }
            askClaudeChat.updatePlan(id) {
                $0.undoName = nil
                $0.undoToken = nil
            }
            // Said once it has run, as it ran: an item changed since stays where it is.
            Task { @MainActor in
                let notBack = await undoing.value
                askClaudeChat.updatePlan(id) { $0.recordUndo(notBack: notBack) }
                let missed = plan.rows.filter { notBack.contains($0.id) }.map(\.name)
                askClaudeChat.tellClaude(missed.isEmpty
                    ? "They undid your card “\(plan.title)”: everything it did is back where it was."
                    : "They undid your card “\(plan.title)”, but \(missed.count) didn’t go back: \(missed.prefix(10).joined(separator: "; ")).")
            }
        }
    }

    /// Apply on a plan card: its ticked rows, each checked again now, as one undo step.
    private func askClaudeApplyPlan(_ id: UUID) {
        guard !askClaudeChat.isRunning, let plan = askClaudeChat.plan(id), plan.state == .proposed else { return }
        let rows = plan.runnable.map { (id: $0.id, change: $0.change) }
        guard !rows.isEmpty else { return }
        if let blocker = syncManager.planApplyBlocker {
            askClaudeChat.addNote("Apply waits: \(blocker). Click it again once that’s done.")
            return
        }
        askClaudeChat.updatePlan(id) { $0.state = .applying }
        let protected = Set(askClaudeSources.map(\.root))
        Task { @MainActor in
            let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
            let outcome = await syncManager.applyPlan(rows, actionName: plan.title, isHidden: { hidden.isHidden($0) },
                                                      protected: protected)
            askClaudeChat.updatePlan(id) { $0.record(outcome) }
            if let applied = askClaudeChat.plan(id) { askClaudeChat.tellClaude(AskClaudeChat.applyReport(applied)) }
        }
    }

    /// Filing help's card buttons.
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
        case .moveHere(let item, let file, let folder, let label):
            // The card becomes a plan card with this one move, checked now.
            let change = AskClaudePlan.Change.move(from: file, toFolder: folder)
            let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
            let refusal = syncManager.planRefusal(change, isHidden: { hidden.isHidden($0) }, protected: Set(askClaudeSources.map(\.root)))
            let name = (file as NSString).lastPathComponent
            let landing = AskClaudeLooseFiles.landingName(for: name, in: folder)
            let row = AskClaudePlan.Row(id: 0, name: name, change: change, ticked: true,
                                        note: landing == name ? nil : "Kept as \(landing): the name is taken",
                                        folderLabel: label, refusal: refusal)
            askClaudeChat.replace(item, with: .plan(AskClaudePlan(title: "Move \(name)", subtitle: "", rows: [row])))
        }
    }

    /// Refine with Claude from filing help's card: Organize scans the file's folder, then a plan for
    /// this one file is a card in the chat. The answer is Organize's.
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
        // Organize scans the file's folder first; then the plan for this one file is a card here.
        Task { @MainActor in
            guard let suggestion = await syncManager.suggestionAfterScan(filePath: file) else {
                askClaudeChat.addNote("Refine couldn’t find \((file as NSString).lastPathComponent) in Organize’s results.")
                return
            }
            askClaudeRefine(scope: [suggestion])
        }
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

    /// The shield's choice for the folder Claude sees: ask each time, share without asking, or
    /// hide. Said in the thread.
    func askClaudeSetCurrentFolderAccess(_ access: AskClaudeFolderAccess) {
        let folder = AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)
        let name = askClaudeFolder.isEmpty ? askClaudeSourceName : (askClaudeFolder as NSString).lastPathComponent
        let wasHidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard)).isHidden(folder)
        switch access {
        case .hide:
            askClaudeSetHidden(folder, name: name, true)
        case .share:
            if wasHidden { askClaudeSetHidden(folder, name: name, false) }
            AskClaudePrivacy.shareWithoutAsking(folder, in: .standard)
            askClaudeChat.addNote("Claude gets answers, page text, search names and lookups from \(name) without asking now. Whole documents still ask.")
        case .ask:
            if wasHidden {
                askClaudeSetHidden(folder, name: name, false)
            } else {
                // Whichever entry covers it, itself or a folder above it, judged by where it
                // really is, as the tools judge it.
                let shared = AskClaudePrivacy.sharedFolders(in: .standard).filter { AskClaudePrivacy.Matcher([$0]).holds(folder) }
                shared.forEach { AskClaudePrivacy.stopSharing($0, in: .standard) }
                // A shared folder above it is taken off whole, so say which.
                let above = shared.filter { ($0 as NSString).standardizingPath != (folder as NSString).standardizingPath }
                    .map { ($0 as NSString).lastPathComponent }
                askClaudeChat.addNote(above.isEmpty ? "Claude asks before anything from \(name) goes again."
                    : "Stopped sharing \(above.joined(separator: ", ")) without asking, which holds \(name): Claude asks before anything from it goes again.")
            }
        }
    }

    /// Puts a folder or file on the Never show Claude list, or takes it off, and says so in the
    /// thread. Taken off by whichever entry covers it: itself, or a folder above it.
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
        AskClaudePrivacy.hiddenEntries(covering: path, in: .standard)
    }

    /// An entry as the thread and the row menu name it; a source's own folder by the source's name.
    private func askClaudeHiddenName(_ entry: String) -> String {
        AskClaudePaths.same(entry, askClaudeRoot) ? askClaudeSourceName : (entry as NSString).lastPathComponent
    }

    /// The folder above a row whose entry hides it, by name, or nil when only its own entry
    /// hides it, or none: Show to Claude on that row takes the whole folder off.
    func askClaudeHiddenCover(_ path: String) -> String? {
        let above = askClaudeHiddenEntries(covering: path).filter { !AskClaudePaths.same($0, path) }
        return above.isEmpty ? nil : above.map(askClaudeHiddenName).joined(separator: ", ")
    }

    /// Go to This Folder: the folder Claude sees is always the one the source pane is at, so this
    /// only has work where the workspace has folded that pane away (Edit, Organize).
    func askClaudeShowFolderPane() {
        guard panesHiddenForCurrentTab else { return }
        togglePanesForCurrentTab()
    }

    // MARK: What Claude sees

    private var askClaudeInBrowse: Bool { selectedWorkspace == .browse }

    /// The type filter, as Claude's view of the screen states it: the rows it is given are the
    /// whole folder, so it is told which of them the pane is showing ("these" means those).
    private var askClaudeTypeFilterNote: String {
        guard let filter = syncManager.leftTypeFilter else { return "" }
        let total = syncManager.leftTypeFilterFacts?.itemCountBeforeFilter ?? syncManager.leftItemCount
        return " · type filter on: the pane shows \(filter.showingPhrase)"
            + " (\(syncManager.leftItemCount.formatted()) of \(total.formatted()) items)"
    }

    private var askClaudeRoot: String {
        (settings.rootPath(for: leftProviderId) as NSString).expandingTildeInPath
    }

    private var askClaudeSourceName: String {
        settings.availableProviders.first { $0.id == leftProviderId }?.displayName ?? leftProviderId
    }

    /// A source's name as Claude is told it: a source whose own folder is hidden isn't named.
    private func askClaudeSpokenName(_ id: String) -> String {
        settings.availableProviders.first { $0.id == id }.map { AskClaudeBrowseTools.spokenName($0, isHidden: askClaudeIsHidden) } ?? id
    }

    /// The Browse pane’s folder, relative to its source: the one its header names.
    private var askClaudeFolder: String {
        syncManager.paneLocation(isLeft: true, drawsColumns: paneDrawsColumns(isLeft: true))
    }

    /// The folder Claude sees, for the panel's header and shield.
    var askClaudePlace: AskClaudePlace {
        let absolute = AskClaudeBrowseTools.absolute(askClaudeFolder, root: askClaudeRoot)
        let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
        // The file open in Edit only when Claude is told about it: one in a hidden folder isn't.
        let open = selectedWorkspace == .editor ? editorOpenPath.flatMap { hidden.isHidden($0) ? nil : ($0 as NSString).lastPathComponent } : nil
        let isHidden = hidden.isHidden(absolute)
        return AskClaudePlace(source: askClaudeSourceName, folder: askClaudeFolder,
                              itemCount: askClaudeItems(absolute)?.count,
                              isHidden: isHidden,
                              isShared: !isHidden && AskClaudePrivacy.Matcher(AskClaudePrivacy.sharedFolders(in: .standard)).holds(absolute),
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
        var screen = AskClaudeScreen(workspace: selectedWorkspace.title, source: askClaudeSpokenName(leftProviderId), folder: folder,
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

    /// The parent columns on screen, from the pane's scope down to the folder before the one on
    /// screen, at most three, each as the pane has it loaded.
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
            let name = askClaudeSpokenName(id)
            let root = (settings.rootPath(for: id) as NSString).expandingTildeInPath
            let folder = syncManager.paneLocation(isLeft: isLeft, drawsColumns: paneDrawsColumns(isLeft: isLeft))
            let shown = hidden.isHidden(AskClaudeBrowseTools.absolute(folder, root: root)) ? "(a folder hidden from Claude)"
                : folder.isEmpty ? "(top level)" : folder
            return "\(isLeft ? "left" : "right"): \(name) › \(shown)"
        }
    }

    /// Compare's two sides and how fresh their comparison is; nil without two sources.
    var askClaudeComparison: AskClaudeDifferences.Comparison? {
        guard !leftProviderId.isEmpty, !rightProviderId.isEmpty else { return nil }
        let left = askClaudeSpokenName(leftProviderId), right = askClaudeSpokenName(rightProviderId)
        func hidden(_ id: String, _ folder: String) -> Bool {
            askClaudeIsHidden(AskClaudeBrowseTools.absolute(folder, root: (settings.rootPath(for: id) as NSString).expandingTildeInPath))
        }
        var comparison = AskClaudeDifferences.Comparison(
            leftName: left, rightName: right,
            leftFolder: syncManager.leftRelativePath, rightFolder: syncManager.rightRelativePath,
            readAt: syncManager.lastScanReadAt ?? syncManager.lastScanDate,
            // The folders' reads count: the scan itself starts only once both are read.
            isScanning: syncManager.isScanning || syncManager.isRefreshing, hasScanned: syncManager.hasScanned,
            partial: syncManager.lastScanCoverage.message(leftName: left, rightName: right))
        comparison.leftFolderHidden = hidden(leftProviderId, syncManager.leftRelativePath)
        comparison.rightFolderHidden = hidden(rightProviderId, syncManager.rightRelativePath)
        return comparison
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
        // and answers "what's in Downloads?" from everything in it.
        if target == scope { return syncManager.leftTreeBeforeTypeFilter }
        guard let node = askClaudeNode(target) ?? askClaudeNode(absoluteFolder),
              node.isDirectory, node.isUnexplored != true else { return nil }
        return node.children ?? []
    }

    /// A node of the left pane's folder, filtered or not: the published index while the pane has
    /// no type filter, and the tree before the filter while it does.
    private func askClaudeNode(_ path: String) -> FileNode? {
        guard syncManager.leftTypeFilter != nil else { return syncManager.leftNodes(for: [path]).first }
        return syncManager.leftNodes(for: [path]).first
            ?? syncManager.leftTreeBeforeTypeFilter.findNodes(at: [path]).first
    }

    /// Why Claude can’t move the view right now: it never moves under a sheet, a destination
    /// pick, or a question the window is waiting on.
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
        // Pinned, the column is in the window these overlays cover, so it pauses under them; a
        // floating panel has always sat over them.
        if askClaudePinnedShown, compareDifferencePair != nil || compareFilePair != nil { return "a comparison is open" }
        return nil
    }

    /// The sources the Browse pane can switch to, with absolute roots.
    private var askClaudeSources: [AskClaudeBrowseTools.Source] {
        // The pane's own list: a source switched off in Settings is one no refresh walks.
        AskClaudeBrowseTools.spokenSources(settings.enabledProviders, isHidden: askClaudeIsHidden)
    }

    func askClaudeToolsContext() -> AskClaudeBrowseTools.Context {
        AskClaudeBrowseTools.Context(
            inBrowse: askClaudeInBrowse,
            sourceName: askClaudeSpokenName(leftProviderId),
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
                // Selecting a row the type filter hides clears the filter first, or the selection
                // prune would take it straight back off.
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
            openForFill: { await askClaudeOpenForFill($0) },
            hidden: AskClaudePrivacy.hiddenFolders(in: .standard),
            shared: AskClaudePrivacy.sharedFolders(in: .standard),
            sharesAnswers: askClaudeChat.sharesAnswers,
            sharesNames: askClaudeChat.sharesNames,
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
                // A person gather takes the list's slot, and a switch from another workspace
                // clears it only in the next update. Left open, the request would wait unseen for
                // whenever the list next mounts.
                clearPersonScope()
                differencesSession.show(filter, selecting: ids)
                return true
            },
            // A review takes the list's place until Done, so rows shown there would be selected
            // and scrolled to minutes later, unasked.
            differencesHeldBy: { reviewStore.isReviewing ? "a review is open in Compare" : nil },
            whereToFile: { path, place in
                // Page 1 read on this Mac by To File's reader, which leaves a cloud-only file
                // unread rather than fetch it (`FilingSurvey.isAvailable`), so that one is placed
                // by its name, as To File places it. A large one isn't even offered to it.
                let size = AskClaudeDisk.node(atPath: path)?.fileSize
                let fetches = MaterializationStatus.isCloudOnlyIfKnown(atPath: MaterializationStatus.linkTarget(of: path)) == true
                    && (size ?? .max) > AskClaudeBrowseTools.autoDownloadBytes
                let page = fetches ? nil : await syncManager.filingHelpPage(path)
                let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
                return await syncManager.whereToFile(path, snippet: page, preferring: place, isHidden: { hidden.isHidden($0) })
            },
            ruleFromCorrection: { path, folder, name, words, also, page in
                syncManager.ruleFromCorrection(path, into: folder, name: name, phrases: words, also: also, pageSample: page)
            },
            surveyFolder: { syncManager.filingSurveyFolder(named: $0) },
            surveyRoot: syncManager.filingFolderProfile?.recordedFolderPath,
            surveyRootFor: { syncManager.filingHelpSurveyRoot(for: $0) },
            planRefusal: { change, creating in
                let hidden = AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard))
                return syncManager.planRefusal(change, creating: creating, isHidden: { hidden.isHidden($0) },
                                               protected: Set(askClaudeSources.map(\.root)))
            },
            shownOnCards: Set(askClaudeChat.items.flatMap { item -> [String] in
                guard case .plan(let plan) = item.kind else { return [] }
                return plan.rows.map(\.change.path)
            }),
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
                    // A tab or page by name, or the page holding a named setting ("Monthly
                    // limit"), by Settings' own search index; Ask Claude when it's about this chat.
                    let wanted = tab?.lowercased()
                    let chosen = SettingsView.SettingsTab.allCases.first { $0.displayName.lowercased() == wanted || $0.rawValue == wanted }
                        .map { SettingsPlace($0) }
                        ?? SettingsSubTab.allCases.first { $0.displayName.lowercased() == wanted || $0.rawValue.lowercased() == wanted }
                        .map { SettingsPlace($0) }
                        ?? tab.flatMap(SettingsPlace.holding)
                        ?? (tab == nil ? SettingsPlace(.intelligence) : nil)
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
            },
            settingsLookup: askClaudeSettingsLookup,
            chatIsOpen: askClaudeHolder.visibility.isOpen,
            setSetting: { id, value, target in
                let before = SettingsCatalog.entry(id).flatMap { askClaudeSettingsLookup.currentValue($0, target: target) }
                let outcome = SettingsWriter(defaults: .standard, settings: settings).write(id, value, target: target)
                if outcome == .done, let entry = SettingsCatalog.entry(id) {
                    askClaudeRecordChange(entry, target: target, from: before, to: value, how: .claude)
                }
                return outcome
            })
    }

    /// Changed from Chat's line for a change made from the chat, written at once.
    func askClaudeRecordChange(_ entry: SettingEntry, target: String?, from: SettingValue?, to: SettingValue,
                               how: SettingsChange.How) {
        SettingsChangeLog.shared.record(SettingsChange(
            setting: entry.id, target: target, name: askClaudeSettingName(entry, target: target),
            from: from?.stored, to: to.stored, fromLabel: from.map { SettingsLookup.label($0, entry) },
            toLabel: SettingsLookup.label(to, entry), how: how))
    }

    /// "Theme", or "Show in Sidebar for Dropbox" for a setting that belongs to a source.
    /// These words reach Claude and the record: a source whose own folder is hidden from Claude
    /// isn't named.
    func askClaudeSettingName(_ entry: SettingEntry, target: String?) -> String {
        guard let target else { return entry.label }
        if settings.availableProviders.contains(where: { $0.id == target }) {
            return "\(entry.label) for \(askClaudeSpokenName(target))"
        }
        return "\(entry.label) for \(askClaudePeople.person(named: target)?.displayName ?? target)"
    }

    /// Whether `target` is a source whose own folder is hidden from Claude: neither its name nor
    /// a name or path set on it is told to Claude.
    func askClaudeSourceIsHidden(_ target: String?) -> Bool {
        guard let target, let provider = settings.availableProviders.first(where: { $0.id == target }) else { return false }
        return askClaudeIsHidden((provider.rootPath as NSString).expandingTildeInPath)
    }

    /// The settings tool's reads, over this window's SettingsManager.
    var askClaudeSettingsLookup: SettingsLookup {
        SettingsLookup(
            defaults: .standard, settings: settings,
            keyIsSaved: { AnthropicKeychain.isConfigured },
            hiddenCount: { AskClaudePrivacy.hiddenFolders(in: .standard).count },
            isHidden: { AskClaudePrivacy.Matcher(AskClaudePrivacy.hiddenFolders(in: .standard)).isHidden($0) },
            loginItemIsOn: {
                // macOS holds this one; read it fresh rather than trust a value nobody has read yet.
                await LoginItemController.shared.refresh().value
                return LoginItemController.shared.isOn
            },
            changesFromChat: {
                SettingsChangeLog.shared.visible(hiding: AskClaudePrivacy.hiddenFolders(in: .standard).map {
                    ($0 as NSString).lastPathComponent
                }, hidingTargets: { askClaudeSourceIsHidden($0) })
            }, people: { syncManager.filingPeopleStore?.people ?? [] })
    }

    /// What a settings card reads and does, and the chat's undo of it.
    var askClaudeSettingsBridge: AskClaudeSettingsBridge {
        let lookup = askClaudeSettingsLookup
        let undo = askClaudeChat.settingsUndo
        let chat = askClaudeChat
        let lists = askClaudeLists
        let people = askClaudePeople
        // A list's step is one item in or out: its target is the item. A person's is the whole
        // person, and the order's is every id in order.
        undo.read = { key in
            if key.id.hasPrefix("people.") { return people.value(key.id, target: key.target) }
            if SettingsLists.ids.contains(key.id) { return lists.contains(key.id, scoped: key.target ?? "").map(SettingValue.bool) }
            return SettingsCatalog.entry(key.id).flatMap { lookup.currentValue($0, target: key.target) }
        }
        undo.write = { key, value in
            if key.id.hasPrefix("people.") { return people.set(key.id, target: key.target, value) == .done }
            if SettingsLists.ids.contains(key.id) { return lists.set(key.id, scoped: key.target ?? "", present: value == .bool(true)) == .done }
            let done = SettingsWriter(defaults: .standard, settings: settings).write(key.id, value, target: key.target,
                                                                                     cause: .undo) == .done
            if done, SettingsWriter.appliedByDiscovery.contains(key.id) {
                Task { @MainActor in
                    await settings.discoverProviders()
                    undo.resettle(key)
                }
            }
            return done
        }
        undo.didStep = { step, undone in askClaudeSettingsStepped(step, undone: undone) }
        // An undo whose write was refused keeps its step and says so on its card.
        undo.didRefuse = { [weak chat] step in
            chat?.updateSettingCard(step.card) { card in
                for row in step.rows where card.rows.indices.contains(row) {
                    card.rows[row].refusal = "Couldn’t put it back: it can’t be set to that now."
                }
            }
        }
        AskClaudePanelWindow.settingsUndo = { [weak chat] in chat?.settingsUndo }
        return AskClaudeSettingsBridge(
            read: { lookup.currentValue($0, target: $1) },
            targetName: { id in settings.availableProviders.first { $0.id == id }?.displayName ?? people.person(named: id)?.displayName ?? id },
            change: { askClaudeSettingChange($0, $1, $2) },
            // The entry's own page, not a lookup by its label: "Model" names two pages' controls.
            openSettings: { openSettings(on: $0.place) },
            offersUndo: { undo.offersUndo($0, row: $1) },
            undo: { undo.undoCard($0, row: $1) },
            canAskAgain: { [weak chat] in
                guard let chat, !chat.isRunning else { return false }
                if case .overLimit = AskClaudeSpend.state(in: .standard) { return false }
                return true
            },
            askAgain: { id in askClaudeAskAgain(id) },
            // `isConfigured` asks whether a key is saved without reading it, so drawing the card
            // never raises the Keychain's password prompt.
            keyIsSaved: { AnthropicKeychain.isConfigured },
            saveKey: { id, row, key in askClaudeSaveKey(id, row, key) },
            hasCaughtKey: { [weak chat] id in chat?.caughtKey(id) != nil },
            saveCaughtKey: { [weak chat] id, row in
                guard let key = chat?.caughtKey(id) else { return }
                if askClaudeSaveKey(id, row, key) { chat?.forgetCaughtKey(id) }
            },
            editCaught: { [weak chat] id in chat?.editCaught(id) },
            saveSetupKey: { askClaudeSaveSetupKey($0) },
            listItems: { lists.items($0.id) },
            listContains: { entry, scoped in lists.contains(entry.id, scoped: scoped) },
            setListItem: { id, row, item, present in askClaudeListEdit(id, row, item, present: present) },
            putBack: { id, row, scoped in askClaudeListEdit(id, row, scoped, present: true, scoped: true) },
            chooseHidden: { id, row in askClaudeChooseHidden(id, row) },
            isHiddenItem: askClaudeNamesHidden,
            chooseFolder: { id, row in askClaudeChooseFolder(id, row) },
            resetOpenAt: { id, row in
                guard let target = askClaudeChat.settingCard(id)?.rows[row].target else { return }
                askClaudeSettingChange(id, row, nil) { settings.resetOpenAt(for: target); return .done }
            },
            peopleRefusal: { people.refusal },
            person: { people.person(named: $0) },
            savePerson: { id, row, person in askClaudePeopleEdit(id, row, key: .init(id: "people.edit", target: person.id), name: person.displayName) { people.update(person) } },
            movePerson: { id, row, up in
                guard let target = askClaudeChat.settingCard(id)?.rows[row].target, let person = people.person(named: target) else { return }
                askClaudePeopleEdit(id, row, key: .init(id: "people.edit", target: nil), name: person.displayName, moved: up) { people.move(person.id, up: up) }
            },
            addPerson: { id, row, person in askClaudeAddPerson(id, row, person) },
            actionPrompt: { entry, target in askClaudeActions.prompt(entry.id, target: target) },
            actionScope: { entry in askClaudeActions.scope(entry.id) },
            runAction: { id, row, scope in askClaudeRunAction(id, row, scope: scope) },
            changeConfirmed: { id, row, value in askClaudeSettingChange(id, row, value, confirmed: true) },
            refreshLoginItem: { await LoginItemController.shared.refresh().value })
    }

    /// The buttons a card presses, with the app's own flows for setup and the resets: the ones
    /// Settings' buttons call.
    var askClaudeActions: SettingsActions {
        var actions = SettingsActions(settings: settings, sync: syncManager, lookup: askClaudeSettingsLookup)
        actions.runSetup = {
            setupDismissedThisSession = false
            showSetup = true
        }
        actions.resetSetup = { resetSetupAction() }
        actions.resetAll = { resetAllSettingsAction() }
        return actions
    }

    /// A button pressed on a card, after the card's own question for one that asks twice. It
    /// can't be undone, so it says what it did, in the record and to Claude, and goes on no stack.
    func askClaudeRunAction(_ id: UUID, _ index: Int, scope: String? = nil) {
        guard let row = askClaudeChat.settingCard(id)?.rows, row.indices.contains(index),
              let entry = SettingsCatalog.entry(row[index].id) else { return }
        let target = row[index].target
        // Use Default Order is the one with an Undo: it changes the order, which a card can put back.
        if entry.id == "people.defaultOrder" {
            askClaudePeopleEdit(id, index, key: .init(id: "people.edit", target: nil), name: "People",
                                words: "put People in the default order") {
                syncManager.filingPeopleStore?.useDefaultOrder()
                return syncManager.filingPeopleStore == nil ? .refused("People can’t be changed until the folder survey has run.") : .done
            }
            return
        }
        // One press at a time: a second click while the first runs does nothing.
        let pressing = "\(id)-\(index)"
        guard !askClaudeChat.pressing.contains(pressing) else { return }
        askClaudeChat.pressing.insert(pressing)
        let actions = askClaudeActions
        Task { @MainActor in
            defer { askClaudeChat.pressing.remove(pressing) }
            let result = await actions.run(entry.id, target: target, scope: scope)
            let name = askClaudeSettingName(entry, target: target)
            switch result {
            case .done(let words):
                SettingsChangeLog.shared.record(SettingsChange(setting: entry.id, target: target, name: name, from: nil, to: nil,
                                                               fromLabel: nil, toLabel: words, how: .card))
                askClaudeChat.updateSettingCard(id) { card in
                    guard card.rows.indices.contains(index) else { return }
                    card.rows[index].refusal = nil
                    card.rows[index].outcome = words
                }
                let raises = entry.raises == .always ? " This raises Claude’s spending or access." : ""
                askClaudeChat.tellClaude("They pressed \(name) on your card: \(words)\(raises)")
            case .refused(let why):
                askClaudeChat.updateSettingCard(id) { card in
                    guard card.rows.indices.contains(index) else { return }
                    card.rows[index].refusal = why
                }
                askClaudeChat.tellClaude("They pressed \(name) on your card, and it didn’t run: \(why)")
            }
        }
    }

    /// A value in words for Claude: a folder setting's path is left out when it names something
    /// hidden from Claude, and so is any name or path set on a source whose own folder is hidden
    /// (renaming it would otherwise say what it was called).
    func askClaudeWords(_ value: SettingValue?, _ entry: SettingEntry, target: String?) -> String {
        guard let value else { return "unknown" }
        if case .string(let text) = value {
            if entry.privacy == .hiddenFiltered, askClaudeNamesHidden(text) || askClaudeSourceIsHidden(target) {
                return "a folder hidden from you"
            }
            if askClaudeSourceIsHidden(target) { return "a name hidden from you" }
        }
        return SettingsLookup.label(value, entry)
    }

    /// A folder setting's Choose…: the macOS panel, which doesn't move the chat. Claude never
    /// fills a path in; what the panel gives is written as Settings writes it.
    func askClaudeChooseFolder(_ id: UUID, _ index: Int) {
        guard let rows = askClaudeChat.settingCard(id)?.rows, rows.indices.contains(index),
              let entry = SettingsCatalog.entry(rows[index].id) else { return }
        let row = rows[index]
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        switch entry.id {
        case "sources.addFolder":
            panel.prompt = "Add Folder"
            panel.message = "A folder to add as a source"
        case "sources.openAt":
            panel.prompt = "Open Here"
            panel.message = "Where panes on this source open"
            if let target = row.target { panel.directoryURL = URL(fileURLWithPath: (settings.rootPath(for: target) as NSString).expandingTildeInPath) }
        default:
            panel.prompt = "Choose"
            if let target = row.target { panel.directoryURL = URL(fileURLWithPath: (settings.rootPath(for: target) as NSString).expandingTildeInPath) }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard entry.id == "sources.addFolder" else {
            askClaudeSettingChange(id, index, .string(url.path))
            return
        }
        let known = Set(settings.availableProviders.map(\.id))
        let source = settings.addFolderSource(path: url.path)
        let name = url.lastPathComponent
        let hidden = askClaudeIsHidden(url.path)
        if known.contains(source) {
            let existing = settings.availableProviders.first { $0.id == source }?.displayName ?? name
            askClaudeChat.updateSettingCard(id) { $0.rows[index].outcome = "Already a source: \(existing). Nothing was added." }
            return
        }
        askClaudeChat.updateSettingCard(id) { $0.rows[index].outcome = "Added \(name) as a source." }
        SettingsChangeLog.shared.record(SettingsChange(setting: entry.id, name: "Local folders", from: nil, to: nil,
                                                       fromLabel: nil, toLabel: hidden ? "added a folder hidden from Claude" : "added \(name)",
                                                       how: .card))
        askClaudeChat.tellClaude(hidden ? "They added a folder hidden from you as a source." : "They added \(name) as a folder source.")
    }

    /// People, through the store Settings edits.
    var askClaudePeople: SettingsPeople { SettingsPeople(store: syncManager.filingPeopleStore) }

    /// A person's fields saved, or a move, from a card: the step holds the person (or the order)
    /// before and after, so Undo puts back exactly that while nothing has changed it since.
    func askClaudePeopleEdit(_ id: UUID, _ index: Int, key: AskClaudeSettingsLedger.Key, name: String, moved up: Bool? = nil,
                             words given: String? = nil, _ write: () -> SettingsWriter.Outcome) {
        let people = askClaudePeople
        guard let before = people.value(key.id, target: key.target) else { return }
        let outcome = write()
        guard outcome == .done, let after = people.value(key.id, target: key.target), after != before else {
            if case .refused(let why) = outcome { askClaudeChat.updateSettingCard(id) { $0.rows[index].refusal = why } }
            return
        }
        let undo = askClaudeChat.settingsUndo
        undo.record(AskClaudeSettingsStep(card: id, rows: [index],
                                          changes: [.init(key: key, before: before, after: after, token: undo.token(key))],
                                          name: "People", cardOnly: false))
        let words: String
        if let given {
            words = given
        } else if let up {
            words = "moved \(name) \(up ? "up" : "down")"
        } else if case .string(let now) = after {
            words = "saved \(SettingsPeople.words(now))"
        } else {
            words = "changed \(name)"
        }
        askClaudeChat.updateSettingCard(id) { card in
            card.rows[index].refusal = nil
            card.rows[index].outcome = words.prefix(1).uppercased() + words.dropFirst() + "."
        }
        SettingsChangeLog.shared.record(SettingsChange(setting: "people.edit", target: key.target, name: "People",
                                                       from: before.stored, to: after.stored, fromLabel: nil, toLabel: words, how: .card))
        askClaudeChat.tellClaude("They \(words) in People on your card.")
    }

    /// Add Person, from the card's own fields.
    func askClaudeAddPerson(_ id: UUID, _ index: Int, _ person: Person) {
        let added = askClaudePeople.add(name: person.displayName, relationship: person.relationship,
                                        fullNames: person.fullNames, aliases: person.aliases)
        guard let new = added.person else {
            askClaudeChat.updateSettingCard(id) { $0.rows[index].refusal = added.refusal }
            return
        }
        let key = AskClaudeSettingsLedger.Key(id: "people.add", target: new.id)
        let undo = askClaudeChat.settingsUndo
        let now = SettingValue.string(SettingsPeople.encode(new))
        undo.record(AskClaudeSettingsStep(card: id, rows: [index], changes: [.init(key: key, before: .string(""), after: now, token: undo.token(key))],
                                          name: "Add Person", cardOnly: false))
        askClaudeChat.updateSettingCard(id) { card in
            card.rows[index].refusal = nil
            card.rows[index].outcome = "Added \(new.displayName)."
        }
        SettingsChangeLog.shared.record(SettingsChange(setting: "people.add", target: new.id, name: "People", from: "", to: now.stored,
                                                       fromLabel: nil, toLabel: "added \(SettingsPeople.words(now.stored))", how: .card))
        askClaudeChat.tellClaude("They added \(SettingsPeople.words(now.stored)) in People on your card.")
    }

    /// The four lists a card edits, through Settings' owners.
    var askClaudeLists: SettingsLists {
        SettingsLists(settings: settings, sync: syncManager, defaults: .standard)
    }

    /// Whether an ignored item or a kept name sits in, or is, a folder hidden from Claude: then it
    /// is never named to Claude, in the record, or on the card's status.
    var askClaudeNamesHidden: (String) -> Bool {
        let names = Set(AskClaudePrivacy.hiddenFolders(in: .standard).map { ($0 as NSString).lastPathComponent })
        return { item in item.split(separator: "/").contains { names.contains(String($0)) } }
    }

    /// One item put in a list or taken out from a card: written through its owner, remembered on
    /// the card, undoable, recorded, and told to Claude without a hidden name.
    func askClaudeListEdit(_ id: UUID, _ index: Int, _ item: String, present: Bool, scoped given: Bool = false) {
        guard let card = askClaudeChat.settingCard(id), card.rows.indices.contains(index),
              let entry = SettingsCatalog.entry(card.rows[index].id), SettingsLists.ids.contains(entry.id) else { return }
        let lists = askClaudeLists
        // A put-back names its item as it was edited, pair of sources and all, so it can't land in
        // whichever comparison is open now.
        let scoped = given ? item : lists.scoped(entry.id, item)
        let outcome = given ? lists.set(entry.id, scoped: scoped, present: present)
            : present ? lists.add(entry.id, item) : lists.remove(entry.id, item)
        guard outcome == .done else {
            if case .refused(let why) = outcome { askClaudeChat.updateSettingCard(id) { $0.rows[index].refusal = why } }
            return
        }
        askClaudeChat.updateSettingCard(id) { card in
            card.rows[index].refusal = nil
            card.rows[index].listEdits = (card.rows[index].listEdits ?? []) + [askClaudeListEditKept(entry.id, scoped, present: present)]
        }
        let undo = askClaudeChat.settingsUndo
        let key = AskClaudeSettingsLedger.Key(id: entry.id, target: scoped)
        var step = AskClaudeSettingsStep(
            card: id, rows: [index], changes: [.init(key: key, before: .bool(!present), after: .bool(present), token: undo.token(key))],
            name: entry.label, cardOnly: SettingsLists.raises(entry.id, present: !present))
        step.redoRaises = SettingsLists.raises(entry.id, present: present)
        undo.record(step)
        askClaudeRecordListEdit(entry, scoped: scoped, present: present, how: .card)
        let raises = SettingsLists.raises(entry.id, present: present) ? " This raises Claude’s spending or access." : ""
        let shown = SettingsLists.shown(entry.id, scoped)
        askClaudeChat.tellClaude("They \(SettingsLists.edit(entry.id, shown, present: present, isHidden: askClaudeNamesHidden)) in \(entry.label) on your card.\(raises)")
    }

    /// What a card keeps of a list edit in the chat's file: nothing that names Hidden from
    /// Claude's folders, or an item inside one.
    func askClaudeListEditKept(_ id: String, _ scoped: String, present: Bool) -> AskClaudeSettingCard.ListEdit {
        let hidden = id == "intelligence.hidden" || askClaudeNamesHidden(SettingsLists.shown(id, scoped))
        return .init(item: hidden ? nil : scoped, present: present)
    }

    /// Changed from Chat's line for a list edit: the item, never the list.
    func askClaudeRecordListEdit(_ entry: SettingEntry, scoped: String, present: Bool, how: SettingsChange.How) {
        let words = SettingsLists.edit(entry.id, SettingsLists.shown(entry.id, scoped), present: present, isHidden: askClaudeNamesHidden)
        SettingsChangeLog.shared.record(SettingsChange(
            setting: entry.id, target: scoped, name: entry.label, from: present ? "false" : "true", to: present ? "true" : "false",
            fromLabel: nil, toLabel: words, how: how))
    }

    /// Hidden from Claude ▸ Add… on a card: a folder from the chooser, never a path Claude names.
    func askClaudeChooseHidden(_ id: UUID, _ index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Hide"
        panel.message = "A folder to hide from Claude"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        askClaudeListEdit(id, index, url.path, present: true)
    }

    /// An API key from a card, to the Keychain as Settings saves it. The card, the record and
    /// Claude hear that it was saved, never what it is.
    /// - Returns: Whether it was saved.
    @discardableResult
    func askClaudeSaveKey(_ id: UUID, _ index: Int, _ key: String) -> Bool {
        let replacing = AnthropicKeychain.isConfigured
        if let why = askClaudeStoreKey(key, replacing: replacing) {
            askClaudeChat.updateSettingCard(id) { $0.rows[index].refusal = why }
            return false
        }
        askClaudeChat.updateSettingCard(id) { card in
            card.rows[index].refusal = nil
            card.rows[index].keySaved = true
        }
        askClaudeChat.tellClaude(replacing ? "They replaced the API key." : "They saved an API key.")
        Logger.shared.info("Ask Claude: an API key was saved from a card")
        return true
    }

    /// An API key from the empty panel's setup. No chat yet, so Claude isn't told.
    /// - Returns: Why it wasn't saved, or nil when it was.
    func askClaudeSaveSetupKey(_ key: String) -> String? {
        let why = askClaudeStoreKey(key, replacing: AnthropicKeychain.isConfigured)
        if why == nil { Logger.shared.info("Ask Claude: an API key was saved from the setup") }
        return why
    }

    /// The Keychain write both save, and its line in the record.
    private func askClaudeStoreKey(_ key: String, replacing: Bool) -> String? {
        guard let entry = SettingsCatalog.entry("intelligence.apiKey") else { return "This setting no longer exists." }
        if let why = APIKeySaving.save(key) { return why }
        SettingsChangeLog.shared.record(SettingsChange(
            setting: entry.id, name: entry.label, from: nil, to: nil, fromLabel: nil,
            toLabel: replacing ? "Replaced with a new key" : "A key saved", how: .card))
        return nil
    }

    /// The at-limit card's Ask Again: the question the limit stopped, once, now that the limit
    /// lets it through.
    func askClaudeAskAgain(_ id: UUID) {
        guard !askClaudeChat.isRunning, let question = askClaudeChat.settingCard(id)?.askAgain else { return }
        if case .overLimit = AskClaudeSpend.state(in: .standard) { return }
        askClaudeChat.updateSettingCard(id) { $0.askAgain = nil }
        // With what it was about, as it was first asked: a chip hidden since is dropped.
        let asked = askClaudeChat.askAgainContext(id)
        let attached = asked.attached.filter { !askClaudeIsHidden($0.path) }
        askClaudeAsk(question, shown: attached.count == asked.attached.count ? asked.shown : nil, attached: attached)
    }

    /// A settings step undone or redone, from a card or Edit ▸ Undo: told to Claude in the line
    /// the card's own change would have used.
    func askClaudeSettingsStepped(_ step: AskClaudeSettingsStep, undone: Bool) {
        for change in step.changes {
            guard let entry = SettingsCatalog.entry(change.key.id) else { continue }
            if entry.id.hasPrefix("people.") {
                // A person, or the order: in words, never as stored JSON.
                let now = undone ? change.before : change.after
                let words: String = {
                    guard case .string(let text) = now else { return "changed People" }
                    if change.key.target == nil { return undone ? "put People back in their earlier order" : "changed People’s order again" }
                    return text.isEmpty ? "removed the person they added" : "made it \(SettingsPeople.words(text))"
                }()
                SettingsChangeLog.shared.record(SettingsChange(setting: entry.id, target: change.key.target, name: "People",
                                                               from: (undone ? change.after : change.before).stored, to: now.stored,
                                                               fromLabel: nil, toLabel: words, how: undone ? .undo : .redo))
                askClaudeChat.tellClaude("With \(undone ? "Undo" : "Redo"), they \(words) in People.")
                continue
            }
            if SettingsLists.ids.contains(entry.id), let scoped = change.key.target {
                let present = (undone ? change.before : change.after) == .bool(true)
                askClaudeRecordListEdit(entry, scoped: scoped, present: present, how: undone ? .undo : .redo)
                // The card's status follows: Undo takes its edit off, Redo puts it back.
                let edit = askClaudeListEditKept(entry.id, scoped, present: change.after == .bool(true))
                askClaudeChat.updateSettingCard(step.card) { card in
                    for row in step.rows where card.rows.indices.contains(row) {
                        if undone {
                            if let at = card.rows[row].listEdits?.lastIndex(of: edit) { card.rows[row].listEdits?.remove(at: at) }
                        } else {
                            card.rows[row].listEdits = (card.rows[row].listEdits ?? []) + [edit]
                        }
                    }
                }
                let words = SettingsLists.edit(entry.id, SettingsLists.shown(entry.id, scoped), present: present, isHidden: askClaudeNamesHidden)
                let raises = SettingsLists.raises(entry.id, present: present) ? " This raises Claude’s spending or access." : ""
                askClaudeChat.tellClaude("With \(undone ? "Undo" : "Redo"), they \(words) in \(entry.label).\(raises)")
                continue
            }
            let name = askClaudeSettingName(entry, target: change.key.target)
            askClaudeRecordChange(entry, target: change.key.target, from: undone ? change.after : change.before,
                                  to: undone ? change.before : change.after, how: undone ? .undo : .redo)
            let now = askClaudeWords(undone ? change.before : change.after, entry, target: change.key.target)
            let raises = entry.raises(from: undone ? change.after : change.before, to: undone ? change.before : change.after)
                ? " This raises Claude’s spending or access." : ""
            askClaudeChat.tellClaude("They set \(name) back with \(undone ? "Undo" : "Redo"): now \(now).\(raises)",
                                     replacing: "They set \(name) ")
        }
    }

    /// A click on a settings card: written through the setting's owner, remembered on the card as
    /// "was", and told to Claude as one line per setting. `value` nil with a `write` of its own:
    /// an action that sets a value, such as Open at's Reset, whose result is read back.
    /// `confirmed`: the card's own question was answered yes (Column widths' All columns, which
    /// releases columns sized on their own).
    func askClaudeSettingChange(_ id: UUID, _ index: Int, _ value: SettingValue?, confirmed: Bool = false,
                                write: (() -> SettingsWriter.Outcome)? = nil) {
        guard let card = askClaudeChat.settingCard(id), card.rows.indices.contains(index),
              let entry = SettingsCatalog.entry(card.rows[index].id) else { return }
        let target = card.rows[index].target
        let before = askClaudeSettingsLookup.currentValue(entry, target: target)
        if let value { guard before != value else { return } }
        // Releasing columns sized on their own can't be undone, so it asks in the card first and
        // goes on no undo stack.
        let releases = entry.id == "readability.columnWidths" && value == .string(ColumnResizeMode.allColumns.rawValue)
            && askClaudeActions.prompt(entry.id, target: nil) != nil
        let outcome = write?() ?? value.map { askClaudeWriter(card: id, row: index, confirmed: confirmed).write(entry.id, $0, target: target) }
            ?? .refused("Nothing to change.")
        let finish = {
            askClaudeSettingChanged(id, index, entry, target: target, outcome: outcome, before: before, wrote: value, undoable: !releases)
        }
        // A source's name, path and Open at land when the sources are discovered again: the
        // card, its Undo and Claude's line wait for that, so each holds the value that landed.
        guard outcome == .done, SettingsWriter.appliedByDiscovery.contains(entry.id) else {
            finish()
            return
        }
        Task { @MainActor in
            await settings.discoverProviders()
            finish()
        }
    }

    /// The writer a card's change goes through: Column widths' question already answered in the
    /// card, and a notification permission macOS denies reported on the card and to Claude.
    func askClaudeWriter(card id: UUID, row index: Int, confirmed: Bool = false) -> SettingsWriter {
        SettingsWriter(defaults: .standard, settings: settings,
                       confirmReleasingColumnWidths: { _ in confirmed },
                       notificationsDenied: {
                           askClaudeChat.updateSettingCard(id) { card in
                               guard card.rows.indices.contains(index) else { return }
                               card.rows[index].refusal = "On, but macOS blocks SyncCloud’s notifications. Allow them in System Settings ▸ Notifications."
                           }
                           askClaudeChat.tellClaude("Notify when done in the background is on, but macOS blocks SyncCloud’s notifications, so none will show.")
                       })
    }

    /// What a card's write did, once it has landed: the record, then the card, its undo step and
    /// Claude's line. The record comes first: a New Chat while it landed takes the card, not the change.
    private func askClaudeSettingChanged(_ id: UUID, _ index: Int, _ entry: SettingEntry, target: String?,
                                         outcome: SettingsWriter.Outcome, before: SettingValue?, wrote: SettingValue?,
                                         undoable: Bool) {
        let name = askClaudeSettingName(entry, target: target)
        let label = { (v: SettingValue?) in askClaudeWords(v, entry, target: target) }
        let prefix = "They set \(name) "
        switch outcome {
        case .done:
            // Read back, so the step and the line hold what is there (a path as stored, say).
            guard let value = askClaudeSettingsLookup.currentValue(entry, target: target) ?? wrote, value != before else { return }
            askClaudeRecordChange(entry, target: target, from: before, to: value, how: .card)
            guard let card = askClaudeChat.settingCard(id), card.rows.indices.contains(index) else { return }
            askClaudeChat.updateSettingCard(id) { card in
                if card.rows[index].changedFrom == nil { card.rows[index].changedFrom = before?.stored }
                card.rows[index].refusal = nil
                card.rows[index].byClaude = nil
            }
            if let before, undoable {
                let undo = askClaudeChat.settingsUndo
                let key = AskClaudeSettingsLedger.Key(id: entry.id, target: target)
                var step = AskClaudeSettingsStep(
                    card: id, rows: [index],
                    changes: [.init(key: key, before: before, after: value, token: undo.token(key))],
                    name: entry.label, cardOnly: entry.raises(from: value, to: before))
                step.redoRaises = entry.raises(from: before, to: value)
                undo.record(step)
            }
            let first = askClaudeChat.settingCard(id)?.rows[index].changedFrom
                .flatMap { SettingsCatalog.value($0, for: entry) ?? AskClaudeSettingCardView.storedValue($0, like: value) } ?? before
            // The at-limit card is the panel's, not Claude's.
            let whose = card.notice == nil ? "your card" : "the panel’s limit card"
            if first == value {
                askClaudeChat.tellClaude(prefix + "back to \(label(value)) on \(whose).", replacing: prefix)
            } else {
                let raises = entry.raises(from: first, to: value) ? " This raises Claude’s spending or access." : ""
                askClaudeChat.tellClaude(prefix + "to \(label(value)) on \(whose) (was \(label(first))).\(raises)", replacing: prefix)
            }
        case .refused(let why):
            guard askClaudeChat.settingCard(id) != nil else { return }
            askClaudeChat.updateSettingCard(id) { card in
                guard card.rows.indices.contains(index) else { return }
                card.rows[index].refusal = why
            }
            askClaudeChat.tellClaude(prefix + "to \(label(wrote)) on your card, and it wasn’t changed: \(why)", replacing: prefix)
        }
    }
}

/// Hosts the panel over the window’s content and publishes ⌘J’s binding. One modifier rather than
/// two calls, so the window’s long modifier chain stays within what the type checker can solve.
struct AskClaudeHost: ViewModifier {
    let visibility: AskClaudeVisibility
    let controller: AskClaudeWindowController
    /// Pinned: the panel is the window's column rather than a floating window.
    let isPinned: Bool
    /// What the room rule reads, and what to do when it changes.
    let pinInput: PaneLogic.PinRoomInput
    let onPinInput: (PaneLogic.PinRoomInput) -> Void
    let onLiveResize: (Bool) -> Void
    /// The pin's setting, and what to do when it is turned on from outside the panel.
    let isPinOn: Bool
    let onPinnedOn: () -> Void
    let foldWanted: Bool
    let onFoldEnded: () -> Void
    /// View ▸ Pin Ask Claude.
    let pinToggle: Binding<Bool>
    /// Settings, Help, setup, a destination pick or a question is up: the panel steps aside.
    let isBusy: Bool
    let panel: (CGSize, @escaping (CGRect) -> Void) -> AnyView
    let toggle: Binding<Bool>?
    /// The Never show Claude list changed; the row menus' labels follow it.
    var onPrivacyChange: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) { AskClaudeOverlay(visibility: visibility, controller: controller, isPinned: isPinned, isBusy: isBusy, panel: panel) }
            .onReceive(NotificationCenter.default.publisher(for: AskClaudePrivacy.didChange)) { _ in onPrivacyChange() }
            .focusedSceneValue(\.askClaude, toggle)
            .focusedSceneValue(\.askClaudePin, pinToggle)
            .onChange(of: pinInput, initial: true) { _, input in onPinInput(input) }
            // Turned on from Settings: Info, which would take the edge, closes if there is room.
            .onChange(of: isPinOn) { _, on in if on { onPinnedOn() } }
            // The pin's fold is over (the column went, floated, or the window has the room): the
            // next one starts afresh, with the sidebar away.
            .onChange(of: foldWanted) { _, wanted in if !wanted { onFoldEnded() } }
            // The window's own edge: nothing switches while it is dragged, and what it left is
            // decided the moment it is let go.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { _ in onLiveResize(true) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { _ in onLiveResize(false) }
            // The View menu's tick reads this, so it follows the panel without the window redrawing.
            .focusedSceneObject(visibility)
    }
}

/// The area the panel lives in, and the one view that watches whether it is open. The panel
/// itself is in a child window over this area (AskClaudeWindow.swift).
private struct AskClaudeOverlay: View {
    @ObservedObject var visibility: AskClaudeVisibility
    let controller: AskClaudeWindowController
    let isPinned: Bool
    let isBusy: Bool
    let panel: (CGSize, @escaping (CGRect) -> Void) -> AnyView
    /// Bumped when the hidden list changes: the window doesn't redraw for that, and the panel's
    /// header and shield must (the panel is rebuilt from live state each time this body runs).
    @State private var privacyChanges = 0

    var body: some View {
        // The space the panel may move in.
        GeometryReader { geo in
            let controller = controller
            let _ = privacyChanges
            let visibility = visibility
            // Built only while open: every redraw of the window rebuilds it otherwise.
            AskClaudeWindowAnchor(controller: controller, isOpen: visibility.isOpen, isSuspended: isBusy, isPinned: isPinned,
                                  content: visibility.isOpen ? panel(geo.size) { controller.panelRect = $0 } : AnyView(EmptyView()),
                                  onClose: { visibility.isOpen = false })
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .onReceive(NotificationCenter.default.publisher(for: AskClaudePrivacy.didChange)) { _ in privacyChanges += 1 }
        // A row's Ask Claude About This brings an open panel's text box the keyboard.
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
