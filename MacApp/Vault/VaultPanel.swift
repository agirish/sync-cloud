import SwiftUI
import AppKit
import Design
import Quartz
import Settings
import Sync

/// The Vault card's size: one size, held to what the window can show.
enum VaultCardSize {
    /// Wide enough for two cards across beside the chosen number.
    static let preferred = CGSize(width: 1000, height: 620)
    /// Below this the cards and the number beside them stop fitting. The card stops shrinking and
    /// overflows instead, as Settings does: legible beats collapsed.
    static let minimum = CGSize(width: 720, height: 440)
    /// Air kept between the card and the window's edge.
    static let margin: CGFloat = 48
    static let detailWidth: CGFloat = 330
    static let detailPadding: CGFloat = 14
    /// What the detail pane's content has across, inside its padding.
    static let detailContentWidth: CGFloat = detailWidth - 2 * detailPadding

    /// The remembered size, as Compare and Help keep theirs: two keys, `0` for never resized.
    static let widthDefaultsKey = "vaultOverlayWidth"
    static let heightDefaultsKey = "vaultOverlayHeight"

    /// What the window leaves for the card.
    static func available(in window: CGSize) -> CGSize {
        CGSize(width: window.width - margin, height: window.height - margin)
    }

    /// The size to draw at: the remembered one when there is one, else the preferred; always held
    /// to the floor and to what the window can show, on every draw, since the window can shrink
    /// between sessions.
    static func fitted(within window: CGSize, stored: CGSize? = nil) -> CGSize {
        let wanted = stored.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? preferred
        return ResizableCardSize.clamped(wanted, minimum: minimum, within: available(in: window))
    }
}

// MARK: - Overlay

/// The in-window Vault (⌘U, or the lock in the toolbar): a dimmed backdrop behind a centred card,
/// like Settings and Help. Click outside, esc or the ✕ close it, and closing locks it unless the
/// setting says otherwise.
struct VaultOverlay: View {
    @ObservedObject var model: VaultModel
    let glassHue: LiquidGlassHue
    let glassLevel: GlassLevel
    let surfaceTint: Double
    let onClose: () -> Void
    /// Opens Settings ▸ Vault on a page, or on the page last shown there when nil.
    let onOpenSettings: (SettingsSubTab?) -> Void
    /// Quick Look over the window, for a document behind a number.
    let onQuickLook: (String) -> Void
    /// Browse at a document's folder, the file selected.
    let onReveal: (String) -> Void
    /// Adds a person to People (Settings ▸ Organize), the list filing uses too: their name to show,
    /// and the full name a document prints. Nil when People isn't available.
    let onAddPerson: (_ displayName: String, _ fullName: String) -> Person?
    /// The document Quick Look shows for the Vault, nil while it shows none.
    let quickLookPath: String?
    let onCloseQuickLook: () -> Void

    @AppStorage(VaultCardSize.widthDefaultsKey) private var storedWidth: Double = 0
    @AppStorage(VaultCardSize.heightDefaultsKey) private var storedHeight: Double = 0
    /// The live size while a grip is held, committed to defaults once, on release.
    @State private var dragging: CGSize?

    var body: some View {
        GeometryReader { proxy in
            // A drag measures from the committed size, never the live one, which would compound
            // `ResizableCardSize.resized`'s doubling and run the card away from the pointer.
            let committed = VaultCardSize.fitted(within: proxy.size,
                                                 stored: CGSize(width: storedWidth, height: storedHeight))
            let size = dragging ?? committed
            ZStack {
                OverlayScrim(level: glassLevel)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VaultCard(model: model, glassHue: glassHue,
                          onClose: onClose, onOpenSettings: onOpenSettings,
                          onQuickLook: onQuickLook, onReveal: onReveal, onAddPerson: onAddPerson,
                          quickLookPath: quickLookPath, onCloseQuickLook: onCloseQuickLook)
                    .frame(width: size.width, height: size.height)
                    // The card's own controls take the window's hue, not the Mac's accent.
                    .nativeControlAccent(glassHue)
                    .contentSurface(hue: glassHue, tint: surfaceTint)
                    .groundedGlassCard(level: glassLevel)
                    .overlayPanelShadow()
                    // Absorb clicks on the card so they don't fall through to the backdrop.
                    .contentShape(Rectangle())
                    // Drag any edge or corner to resize; the size is remembered, as Compare's
                    // and Help's are.
                    .overlay {
                        ResizableCardGrips(
                            onDrag: { translation, grip in
                                dragging = ResizableCardSize.resized(
                                    from: committed, by: translation, grip: grip,
                                    minimum: VaultCardSize.minimum, within: VaultCardSize.available(in: proxy.size))
                            },
                            onCommit: {
                                if let dragging {
                                    storedWidth = dragging.width
                                    storedHeight = dragging.height
                                }
                                dragging = nil
                            })
                    }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .transition(.opacity)
    }
}

// MARK: - Card

/// The card's content: a header with search and the lock, the people filter, the list, and the
/// chosen number beside it.
///
/// The list never draws a number in full, open or locked: a row is a name and an ending. The full
/// number appears in one place, beside the list, for the row that was chosen.
struct VaultCard: View {
    @ObservedObject var model: VaultModel
    let glassHue: LiquidGlassHue
    let onClose: () -> Void
    /// Opens Settings ▸ Vault on a page, or on the page last shown there when nil.
    let onOpenSettings: (SettingsSubTab?) -> Void
    let onQuickLook: (String) -> Void
    let onReveal: (String) -> Void
    let onAddPerson: (_ displayName: String, _ fullName: String) -> Person?
    let quickLookPath: String?
    let onCloseQuickLook: () -> Void
    /// The household, for "Belongs to" and the filter: the model's, which the window's
    /// ``VaultHost`` keeps to Settings ▸ Organize ▸ People from launch.
    private var people: [Person] { model.people }

    /// The name a number being added was read with, when it matches nobody in People: the
    /// question whether to add them first.
    @State private var askingToAddPerson: String?

    /// Cards by kind (the default), one list, or sections by person: the model keeps the choice.
    private var layout: VaultLayout { model.layout }
    /// Folding a card animates only when the Mac allows motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// With Increase Contrast on, a card's color is its symbol alone, with no wash behind its title.
    @Environment(\.colorSchemeContrast) private var contrast
    /// Counts what the panel draws, for a test; nil in the app.
    @Environment(\.vaultDraws) private var draws
    /// The detail whose Copy just ran, for its two seconds of "Copied".
    @State private var copiedDetail: String?
    /// The number whose documents are all listed; the others show the first few.
    @State private var allDocumentsShown: UUID?
    /// A passport can be named on dozens of documents: the first few, then Show All.
    static let documentsShown = 5

    /// Whether the panel is drawing an ID in full somewhere: unlocked (the chosen ID's number,
    /// the editor, Large Type, a document's preview), one ID shown under "For every ID", or a
    /// date of birth in People, which is drawn in full once one of that person's IDs may be
    /// (VT73).
    /// Large Type too: it draws its own row's number, whatever is chosen since (the second review).
    private var exposesAnID: Bool { model.drawsAnIDInFull(layout: layout, editing: editing != nil) || largeType != nil }


    private enum Editing: Equatable {
        case new
        case existing(UUID)
        /// A number read from a document, being checked before it is added.
        case confirming(UUID)
    }
    /// Set It Aside and Start New was chosen for a Vault this Mac cannot open: asked about first.
    @State private var settingAside = false
    /// An ID was typed in while the panel showed only its lock: the lock says so, since the
    /// list that would show it is not drawn.
    @State private var addedWhileLocked = false
    /// The Color choice that is open, and where it hangs from.
    @State private var coloring: VaultColorAnchor?
    /// The People tile popover that is open: a fact's “+1 ›”, or the IDs it was read from.
    @State private var factPopover: String?
    /// The spelling whose roles the names popover shows, in place of the spellings.
    @State private var roleChoosing: String?
    /// The phone, email or address being typed in a tile's popover.
    @State private var contactEdit: ContactEdit?
    /// The Contact card row open in the details pane, by its id; nil while an ID is.
    @State private var contactChosen: String?
    /// The contact whose removal is being asked about.
    @State private var removingContact: VaultContactCard.Item?
    /// The group whose Color choice is open, from its heading's menu.
    @State private var groupColoring: VaultGroups.ID?
    /// The misreading just corrected, with an Undo, until another is.
    @State private var misreadNote: MisreadNote?
    struct MisreadNote: Equatable {
        let section: String
        let name: String
        let legal: String
        let count: Int
    }
    /// Read Documents was asked for with no folder chosen yet.
    @State private var askingForFolders = false
    /// The folders Read Documents looks in, read again as the panel appears and after a change.
    @State private var readFolders: [String] = []

    @State private var editing: Editing?
    /// The ID as read, for the editor's ID field tooltip, while one read is being added.
    @State private var readValue: String?
    /// The card the editor read for On this card, and what reading it gave: nil while it reads.
    @State private var cardReading: CardRead?
    @State private var allCardValuesShown = false
    /// Merge…'s sheet: the waiting ID it is for, the saved one chosen, and which number stays.
    @State private var mergingFrom: UUID?
    @State private var mergeInto: UUID?
    @State private var mergeKeepsReading = false
    /// More fields: the card read for the ID it is open on, and Add a Field…'s sheet.
    @State private var moreFieldsRead: CardRead?
    @State private var addingFieldTo: UUID?
    @State private var newFieldLabel = ""
    @State private var newFieldValue = ""
    @State private var newFieldHidden = false
    @FocusState private var valueFocused: Bool
    /// An ID just moved to another tab, said on the ID the selection moved on to.
    @State private var moved: MovedNote?
    struct MovedNote: Equatable {
        let id: UUID
        let title: String
        let tab: String
        let pin: VaultPin?
        let shownOn: UUID?
    }
    @State private var draft = VaultModel.Draft()
    /// The ID being edited as the editor opened it, or as it was when a save was refused (VT112).
    @State private var editedFrom: VaultEntry?
    /// The entry Large Type is showing, and its lit line (VT76).
    @State private var largeType: LargeTypeShown?
    @State private var activity = VaultActivityWatch()
    /// Where, Whose or Kinds, opened to choose again.
    @State private var choosing: Choosing?
    @State private var customizingGroups = false
    /// New Kind… was chosen for this ID: the name sheet is up.
    @State private var namingKindFor: UUID?
    @State private var newKindName = ""
    /// The entry whose Copy just ran, for the button's two seconds of "Copied".
    @State private var copied: UUID?
    /// What Remove… or ⌘⌫ is asking about, until the dialog is answered.
    @State private var removing: Removal?
    @FocusState private var searchFocused: Bool

    /// What Large Type shows: an ID, and its lit line, nil for the ID itself, else the index of
    /// one of its details.
    private struct LargeTypeShown: Equatable {
        let id: UUID
        var line: Int?
    }

    /// Remove… asks before anything goes: a number is removed for good, and a find set aside is
    /// not offered again.
    private enum Removal: Identifiable {
        case entry(VaultEntry)
        case find(VaultFind)

        var id: UUID {
            switch self {
            case .entry(let entry): return entry.id
            case .find(let find): return find.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Under macOS's Touch ID prompt, the IDs blur away: the prompt asks who
            // is at the Mac, and what it guards stays out of sight until they answer.
            content
                .blur(radius: model.isAsking ? 18 : 0)
                .allowsHitTesting(!model.isAsking)
                .accessibilityHidden(model.isAsking)
                .designAnimation(.easeOut(duration: 0.18), value: model.isAsking)
            // Its keys act on a Vault that is not used without Touch ID.
            if model.touchIDMissing == nil {
                Divider()
                footer
            }
        }
        .overlay {
            if let row = model.rows.first(where: { $0.id == largeType?.id }), model.lock.canShow(row.id, at: model.now) {
                VaultLargeType(heading: row.largeTypeHeading,
                               idLabel: row.idLabel, value: row.value, category: row.category,
                               lines: Self.largeTypeLines(row), lit: largeType?.line, accent: glassHue.accentColor,
                               onLight: { largeType?.line = $0 },
                               onStep: { stepLargeType(by: $0) },
                               onClose: { largeType = nil })
            }
        }
        .task {
            reloadReadFolders()
            await model.opened()
            searchFocused = true
            refreshByItself()
            model.backUpIfDue()
        }
        // The countdown, and a shown number's thirty seconds. A sleep loop on the view's own
        // task, so it stops when the panel closes.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.tick()
            }
        }
        // Unlocked later than it opened: the refresh waits for the numbers to be read, and what
        // was said on the lock is done with.
        .onChange(of: model.isSealedShut) { _, sealed in
            if !sealed {
                addedWhileLocked = false
                refreshByItself()
                // The weekly backup, once the IDs are in hand: it asks for nothing more.
                model.backUpIfDue()
            }
        }
        // Locked (Lock Now, idle): a number copied from the Vault leaves the clipboard with it,
        // unless something else was copied since (owner, 2026-11-23).
        .onChange(of: model.isOpen) { _, open in if !open { VaultPasteboard.clearPending() } }
        // Back to SyncCloud with the Vault up and locked: Touch ID is asked for at once, as when
        // it opened. Only on coming back, never the moment it relocks, so no prompt waits at a
        // Mac left alone; a cancelled prompt waits for the next return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Touch ID set up, or taken away, in System Settings meanwhile: asked again. Set up now,
            // the Vault opens as it does at an open; taken away, it locks and lets the numbers go.
            let waitingForTouchID = model.touchIDMissing != nil
            Task { await model.touchIDMayHaveChanged() }
            guard !waitingForTouchID else { return }
            let settings = model.lock.settings
            // The same rule as opening: only a Vault with something sealed asks at once.
            guard settings.ask == .whenOpened, model.isSealedShut, !model.isAsking else { return }
            Task { await model.unlock() }
        }
        // Access ran out (Lock Now, the idle limit, a number's thirty seconds): nothing that draws
        // a number in full stays up. The editor draws it in its field; Large Type draws it big.
        // Large Type also goes when its number does (removed, set aside), or its state would hold
        // the keys with nothing on screen.
        // Asked when the time moves (only when something drawn from it changes, VT9) and when the
        // rows do, so a number gone from the list takes Large Type with it at once.
        .onChange(of: model.now) { _, now in closeWhatCannotShow(at: now) }
        .onChange(of: model.rows.map(\.id)) { _, _ in closeWhatCannotShow(at: model.now) }
        // Back to the search once the editor or Large Type closes, so the arrows, Return and
        // Space work again without a click.
        .onChange(of: editing) { _, now in
            guard now == nil else { return }
            focusSearch()
            // A save's refusal is about the editor just left: it does not stay on the card.
            if model.notice == VaultModel.editedElsewhere || model.notice == VaultModel.message(for: .changedElsewhere) {
                model.notice = nil
            }
        }
        // Typing in the editor is use: neither the idle limit nor, under "every number", the
        // number's thirty seconds close it, and its edits, mid-note.
        .onChange(of: draft) { _, _ in if editing != nil { model.noteActivity() } }
        // Choosing a row, or starting a search, puts an open choice away. With Quick Look open,
        // it moves to the newly chosen number's document, or closes when that one is hidden.
        .onChange(of: model.selection) { _, now in
            choosing = nil
            // A move's note is for the ID the selection moved on to, not the next one chosen.
            if moved?.shownOn != now { moved = nil }
            if let corrected = model.lastCorrection, corrected.id != now { model.dismissCorrection() }
            followQuickLook()
            // A click on a row leaves no field focused: the keys come back to the search. Not
            // forced while it has them, which would select what is typed there.
            if editing == nil, largeType == nil, !searchFocused { focusSearch() }
        }
        // Quick Look's panel takes key while it is up and hands it back to whatever AppKit picks
        // when it closes; the Vault takes it back, so Space opens the chosen document again.
        .onChange(of: quickLookPath) { _, now in
            // Reading a scan in Quick Look is using the Vault: it does not lock mid-read. Its panel
            // is a window of its own, kept out of screen sharing while it shows a Vault document
            // (the scan carries the number), and sharing again after.
            activity.countsQuickLook = now != nil
            // Set now, not a moment later: on a first preview this creates the panel, so it is
            // already out of capture when it appears (VT73 b).
            VaultWindowPrivacy.quickLook(showsVaultDocument: now != nil)
            if now == nil, editing == nil, largeType == nil { focusSearch(again: true) }
        }
        .onChange(of: model.query) { _, _ in choosing = nil }
        .sheet(isPresented: Binding(get: { namingKindFor != nil }, set: { if !$0 { namingKindFor = nil } })) {
            VaultNewKindSheet(name: $newKindName, groups: model.groups,
                              takenBy: { VaultKinds.appKind(named: $0)?.title }) { group in
                if let id = namingKindFor, let card = model.addKind(named: newKindName, group: group) {
                    model.setKind(id, to: card)
                }
                namingKindFor = nil
            } onCancel: {
                namingKindFor = nil
            }
            .presentedNativeControlAccent()
        }
        .sheet(isPresented: Binding(get: { mergingFrom != nil }, set: { if !$0 { mergingFrom = nil } })) {
            if let id = mergingFrom { mergeSheet(id).presentedNativeControlAccent().keptFromCapture() }
        }
        .sheet(isPresented: Binding(get: { addingFieldTo != nil }, set: { if !$0 { addingFieldTo = nil } })) {
            addFieldSheet.presentedNativeControlAccent().keptFromCapture()
        }
        .sheet(isPresented: $customizingGroups) {
            VaultGroupsSheet(groups: model.groups, kinds: model.kinds, colors: model.colors,
                             showsHeadings: model.showsGroupHeadings, onDone: { groups, kinds, colors, headings in
                model.setGroups(groups)
                model.showsGroupHeadings = headings
                model.setKinds(kinds)
                // After the kinds: a removed kind's color goes with it.
                model.setColors(colors)
            })
                .presentedNativeControlAccent()
        }
        .onChange(of: largeType) { _, now in if now == nil { focusSearch() } }
        // Choosing an ID puts it in the details pane in place of a contact.
        .onChange(of: model.selection) { _, id in if id != nil { contactChosen = nil } }
        .onChange(of: contactChosen, initial: true) { _, id in model.showsAContact = id != nil }
        // A read in progress goes on: the model runs it, and lets the numbers go when it ends.
        .onDisappear {
            activity.stop()
            // The panel is gone, and with it every ID it drew: the window shares as usual, and a
            // panel that comes back starts from nothing drawn.
            activity.exposed = false
            VaultWindowPrivacy.apply(exposed: false, to: activity.window)
            // Its preview closes with it: Quick Look shares again for the next document (VT73 b).
            VaultWindowPrivacy.quickLook(showsVaultDocument: false)
            model.closed()
        }
        // Using the Vault keeps it open: the pointer moving over it, and any click, key or scroll
        // while it is up. It locks only after its idle time with none of these.
        .onContinuousHover { phase in
            if case .active = phase { model.panelActivity() }
        }
        .onAppear {
            activity.countsQuickLook = quickLookPath != nil
            activity.start { model.panelActivity() }
        }
        .background(VaultWindowReader(watch: activity))
        // While an ID is drawn in full, the window is kept out of screen sharing and recordings
        // (``VaultWindowPrivacy``); the moment none is, it shares again.
        .onChange(of: exposesAnID, initial: true) { _, exposed in
            // Kept on the watch too, so a window that arrives after this first runs is set as it
            // arrives (VT73).
            activity.exposed = exposed
            VaultWindowPrivacy.apply(exposed: exposed, to: activity.window)
        }
        // ⌘⌫ removes the chosen row, after asking. Not while the search has text, where it
        // deletes to the start of the line as usual, nor while the editor is open.
        .background {
            Button("Remove the Chosen ID") { askToRemoveChosen() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.query.isEmpty || editing != nil || largeType != nil || model.isAsking)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            // esc: the cancel action, ahead of the field, so it unwinds the panel a layer at a time.
            Button("Close") { escape(clearingSearch: true) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        // Space and the arrows, when the search field is not the one holding focus (it handles
        // them itself). Key presses, not bare key equivalents, which would take the key from
        // every field in the window; never in the editor, whose fields want them.
        // Return copies the chosen ID here too, as it does from the search, so a click elsewhere
        // in the panel does not leave it doing nothing.
        .onKeyPress(keys: [.space, .upArrow, .downArrow, .return]) { press in
            guard editing == nil else { return .ignored }
            switch press.key {
            case .space: return spaceKey()
            case .upArrow: arrow(-1); return .handled
            case .downArrow: arrow(1); return .handled
            default:
                if largeType == nil, copyChosenContact() { return .handled }
                guard largeType == nil, let id = model.selection else { return .ignored }
                copy(id)
                return .handled
            }
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil },
                                                               set: { if !$0 { removing = nil } }),
                            presenting: removing) { removal in
            switch removal {
            case .entry(let entry):
                Button("Remove", role: .destructive) { remove(entry.id) }
            case .find(let find):
                Button("Not an ID", role: .destructive) { model.setAside(find.id) }
            }
        } message: { removal in
            switch removal {
            case .entry(let entry):
                Text(entry.savedFrom == nil
                     ? "The ID is removed for good."
                     : "The ID is removed for good, and it won’t be offered again when documents are read. The document it came from isn’t touched.")
            case .find(let find):
                Text(Self.notAnIDMessage(printedForSubscriber: find.facts.printedForSubscriber == true))
            }
        }
        .alert("Add \(askingToAddPerson ?? "") to People?",
               isPresented: Binding(get: { askingToAddPerson != nil }, set: { if !$0 { askingToAddPerson = nil } })) {
            Button("Add to People") {
                if let holder = askingToAddPerson, let person = addPerson(named: holder) {
                    draft.personID = person.id
                }
                finishConfirming()
            }
            Button("Add Without a Person") { finishConfirming() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The document names someone who isn’t in People. Added, they get their own filter here, and Organize files their documents to them too. People is in Settings ▸ Organize.")
        }
        .alert("Choose folders to read", isPresented: $askingForFolders) {
            Button("Choose Folders…") { addFolders() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Vault reads only the folders you choose, such as the one that holds your passport scans. You can change them later from the arrow beside Discover More or in Settings ▸ Vault ▸ Read.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.doc")
                .foregroundStyle(.secondary)
            Text("Vault")
                .scaledFont(.headline)
            if model.touchIDMissing == nil {
                statePill
                Spacer(minLength: 12)
                lockButton
                // Every button here says what it does in words beside its symbol.
                Button {
                    startAdding()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add an ID")
                .disabled(contentsUnreadable)
                readMenu
            } else {
                // Without Touch ID nothing here can be used: no adding, no reading.
                Spacer(minLength: 12)
            }
            Button { onOpenSettings(nil) } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Vault settings")
            // ✕ closes, a layer at a time; esc, below, also clears a typed search first.
            CloseButton(action: { escape(clearingSearch: false) })
                .shortcutKeycap("esc")
                .help(ShortcutHint.tooltip("Close Vault", "esc"))
                .accessibilityLabel("Close Vault")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Reading documents, in one menu. A click is Discover More: it looks through the chosen
    /// folders for IDs the Vault does not have yet. The arrow has Refresh, which reads again only
    /// the document each ID is read from, Read Everything Again, and the folders.
    private var readMenu: some View {
        Menu {
            Button {
                read(.discover)
            } label: {
                Text("Discover More")
                Text(Self.discoverLine(folders: readFolders.count))
            }
            Button {
                read(.refresh())
            } label: {
                Text("Refresh")
                Text(Self.refreshLine(documents: model.refreshSources.count))
            }
            .disabled(model.refreshSources.isEmpty && !model.needsReadAgain)
            Divider()
            Button("Read Everything Again") { read(.everything) }
            Divider()
            if readFolders.isEmpty {
                Text("No folders chosen yet")
            } else {
                Section("Folders") {
                    ForEach(readFolders, id: \.self) { folder in
                        Menu((folder as NSString).lastPathComponent) {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                            }
                            Button("Stop Reading This Folder") {
                                model.removeReadFolder(folder)
                                reloadReadFolders()
                            }
                        }
                    }
                }
            }
            Button("Add Folder…") { addFolders() }
            Button("Folder Settings…") { onOpenSettings(.read) }
        } label: {
            Label("Discover More", systemImage: "doc.text.viewfinder")
        } primaryAction: {
            read(.discover)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(model.reading == nil
              ? "Discover More: look through the folders you chose for IDs that are not in the Vault yet. The arrow has Refresh and the folders."
              : model.reading?.scope.isRefresh == true ? "Refreshing your IDs from their documents…" : "Reading your documents…")
        .disabled(contentsUnreadable || model.reading != nil)
    }

    /// The sealed file could not be opened: nothing may be added to or read into it. A Vault
    /// that is only locked takes both; neither shows what is in it.
    private var contentsUnreadable: Bool {
        if case .unreadable = model.contents { return true }
        return false
    }

    @ViewBuilder
    private var statePill: some View {
        let settings = model.lock.settings
        if settings.ask == .everyNumber {
            Pill(.mini, tint: .secondary, systemImage: "lock", text: "Asks for every ID")
        } else if let left = model.secondsBeforeLock {
            // Counted down only in its last seconds, when a click would keep it open.
            Pill(.mini, tint: SemanticColor.warning, systemImage: "lock.open",
                 text: "Locks in 0:" + String(format: "%02d", left))
        } else if model.isOpen {
            Pill(.mini, tint: SemanticColor.success, systemImage: "lock.open", text: "Unlocked")
        } else {
            Pill(.mini, tint: .secondary, systemImage: "lock", text: "Locked")
        }
    }

    @ViewBuilder
    private var lockButton: some View {
        let settings = model.lock.settings
        if settings.ask == .whenOpened {
            if model.isOpen, model.contents == .loaded {
                Button {
                    model.lockNow()
                } label: {
                    Label("Lock Now", systemImage: "lock")
                }
            } else if model.isSealedShut {
                Button {
                    Task { await model.unlock() }
                } label: {
                    Label("Unlock", systemImage: "touchid")
                }
                .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                .disabled(model.isAsking)
            }
        }
    }

    /// What the list is showing: where, whose and which kinds, beside the tabs they narrow.
    private var showingChoices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Showing")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                // Where is offered once the numbers span two countries, or while one is chosen.
                if model.spansCountries || model.geoFilter != .all { wherePart }
                whosePart
                kindsPart
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    /// Above the cards, and staying put as they scroll: the search that narrows them, Collapse
    /// All in words (Expand All once every card is folded), and Cards or List. Collapse All, shown
    /// only with the cards, sits to the switch's left, so the switch stays put as it comes and goes.
    private var searchRow: some View {
        HStack(spacing: 10) {
            searchField
                .frame(minWidth: 160, maxWidth: 320)
            Spacer(minLength: 8)
            if layout == .cards, !model.cards.isEmpty {
                Button {
                    withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) { model.toggleFoldAll() }
                } label: {
                    Label(model.allFolded ? "Expand All" : "Collapse All",
                          systemImage: model.allFolded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(model.allFolded ? "Open every card" : "Fold every card to its header. ⌥-click a card’s header does the same.")
            }
            VaultViewSwitch(layout: $model.layout, hue: glassHue)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    // MARK: Showing: where, whose, which kinds

    /// Which choice is open for picking again; nil while each shows only what was chosen.
    private enum Choosing { case geo, person, kind }

    private var wherePart: some View {
        Group {
            if choosing == .geo {
                choiceGroup("Where") {
                    ForEach(VaultGeoFilter.allCases, id: \.self) { option in
                        optionChip(option == .all ? "All" : option.title, code: option.geo?.code,
                                   count: model.count(geo: option), isSelected: model.geoFilter == option) {
                            model.geoFilter = option
                        }
                    }
                }
            } else {
                choiceToken(model.geoFilter.title, code: model.geoFilter.geo?.code, isDefault: model.geoFilter == .all,
                            clearLabel: "Every Country", open: .geo) { model.geoFilter = .all }
            }
        }
    }

    private var whosePart: some View {
        Group {
            if choosing == .person {
                choiceGroup("Whose") {
                    optionChip("Everyone", count: model.count(person: .everyone), isSelected: model.personFilter == .everyone) {
                        model.personFilter = .everyone
                    }
                    ForEach(people.filter { person in model.rows.contains { $0.personID == person.id } }) { person in
                        optionChip(person.displayName, count: model.count(person: .person(person.id)),
                                   isSelected: model.personFilter == .person(person.id)) {
                            model.personFilter = .person(person.id)
                        }
                    }
                    if model.rows.contains(where: \.isHousehold) {
                        optionChip("Household", count: model.count(person: .household), isSelected: model.personFilter == .household) {
                            model.personFilter = .household
                        }
                    }
                }
            } else {
                choiceToken(personLabel, code: nil, isDefault: model.personFilter == .everyone,
                            clearLabel: "Everyone", open: .person) { model.personFilter = .everyone }
            }
        }
    }

    private var kindsPart: some View {
        Group {
            if choosing == .kind {
                choiceGroup("Kinds") {
                    optionChip("All Kinds", count: model.count(kind: .some(nil)), isSelected: model.kindFilter == nil) {
                        model.kindFilter = nil
                    }
                    ForEach(model.groups.order, id: \.self) { id in
                        optionChip(model.groups.name(id), dot: model.tab == .other ? nil : model.colors.tint(ofGroup: id)?.color,
                                   count: id == VaultGroups.contact ? model.contactCount : model.count(kind: .some(id)),
                                   isSelected: model.kindFilter == id) {
                            model.kindFilter = id
                        }
                    }
                    Button("Customize Groups…") {
                        choosing = nil
                        customizingGroups = true
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } else {
                choiceToken(model.kindFilter.map { model.groups.name($0) } ?? "All Kinds", code: nil,
                            isDefault: model.kindFilter == nil, clearLabel: "All Kinds", open: .kind) { model.kindFilter = nil }
            }
        }
    }

    private var personLabel: String {
        switch model.personFilter {
        case .everyone: return "Everyone"
        case .household: return "Household"
        case .person(let id): return people.first { $0.id == id }?.displayName ?? "Someone no longer in People"
        }
    }

    /// A choice made: what it is, a chevron to choose again, and, away from its default, an ×
    /// back to it.
    private func choiceToken(_ label: String, code: String?, isDefault: Bool, clearLabel: String,
                             open: Choosing, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button {
                withDesignAnimation(.snappy(duration: 0.15), reduceMotion: reduceMotion) { choosing = open }
            } label: {
                HStack(spacing: 5) {
                    if let code { countryCode(code).accessibilityHidden(true) }
                    Text(label)
                        .scaledFont(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .scaledFont(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
                .padding(.trailing, isDefault ? 10 : 4)
                .padding(.vertical, 3)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Choose again")
            .accessibilityLabel("\(Self.choiceName(open)): \(label)")
            .accessibilityHint("Choose again")
            if !isDefault {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .scaledFont(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                        .padding(.trailing, 9)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(clearLabel)
                .accessibilityLabel("Show \(clearLabel)")
            }
        }
        .background(Capsule().fill(isDefault ? Color.clear : glassHue.accentColor.opacity(0.16)))
        .overlay(Capsule().strokeBorder(isDefault ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.clear)))
    }

    /// A choice being made: its name, then each option; picking one closes it back to a token.
    private func choiceGroup<Content: View>(_ title: String, @ViewBuilder _ options: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            options()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }

    private func optionChip(_ title: String, code: String? = nil, dot: Color? = nil, count: Int, isSelected: Bool,
                            pick: @escaping () -> Void) -> some View {
        Button {
            pick()
            withDesignAnimation(.snappy(duration: 0.15), reduceMotion: reduceMotion) { choosing = nil }
        } label: {
            HStack(spacing: 4) {
                if let code { countryCode(code).accessibilityHidden(true) }
                // A group's color, as its cards carry it.
                if let dot { Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true) }
                Text(title)
                    .scaledFont(.subheadline.weight(isSelected ? .semibold : .medium))
                Text(count.formatted())
                    .scaledFont(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(isSelected ? glassHue.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func choiceName(_ choice: Choosing) -> String {
        switch choice {
        case .geo: return "Where"
        case .person: return "Whose"
        case .kind: return "Kinds"
        }
    }

    /// "US" or "IN", small, beside a country's name or a row's.
    private func countryCode(_ code: String) -> some View { VaultRowLabel.country(code) }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .scaledFont(.callout)
            TextField("Search the Vault", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                // The arrows walk the list from the field, so a search never has to be left to
                // act on its result; Return copies the chosen row.
                .onKeyPress(.downArrow) { arrow(1); return .handled }
                .onKeyPress(.upArrow) { arrow(-1); return .handled }
                .onKeyPress(.space) { spaceKey() }
                .onSubmit {
                    guard editing == nil else { return }
                    if copyChosenContact() { return }
                    if let id = model.selection { copy(id) }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .searchFieldSurface()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let why = model.touchIDMissing {
            // Not used at all without Touch ID: nothing was loaded, so nothing else is drawn.
            EmptyStateView(icon: "touchid", tint: SemanticColor.warning,
                           title: "Set up Touch ID to use the Vault",
                           message: why,
                           caption: "The Vault shows an ID only after Touch ID confirms it’s you.",
                           primary: .init("Open Touch ID Settings…", systemImage: "touchid") {
                               if let url = URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension") {
                                   NSWorkspace.shared.open(url)
                               }
                           })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unlockedOrLockedContent
        }
    }

    @ViewBuilder
    private var unlockedOrLockedContent: some View {
        switch model.contents {
        case .unreadable(let error):
            if case .keyUnreadable = error {
                // The Keychain is only refusing for now: nothing to replace, only to try again.
                EmptyStateView(icon: "lock.trianglebadge.exclamationmark", tint: SemanticColor.warning,
                               title: "This Vault can’t be opened here",
                               message: VaultModel.message(for: error),
                               caption: "The sealed file has been left as it is.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No proof opens it, so the panel offers the two ways on: a backup, or a new Vault
                // with this one kept aside.
                EmptyStateView(icon: "lock.trianglebadge.exclamationmark", tint: SemanticColor.warning,
                               title: "This Vault can’t be opened here",
                               message: VaultModel.message(for: error),
                               caption: "The sealed file has been left as it is. A backup is restored in Settings ▸ Vault ▸ Backup.",
                               primary: .init("Restore from a Backup…", systemImage: "arrow.counterclockwise") { onOpenSettings(.backup) },
                               secondary: .init("Set It Aside and Start New…", systemImage: "tray.and.arrow.down") { settingAside = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .confirmationDialog("Set this Vault aside and start a new one?", isPresented: $settingAside) {
                        Button("Set It Aside") { model.setAsideAndStartNew() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The sealed file is renamed and kept beside the new one; nothing is deleted. Without its key it can’t be opened, here or anywhere, so a new Vault starts empty.")
                    }
            }
        case .notLoaded, .loaded:
            if model.isSealedShut {
                // Locked means locked: nothing behind the lock is drawn, or was even read.
                HStack(spacing: 0) {
                    lockedView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Typing an ID in shows nothing that is in the Vault, so Add still works.
                    if editing == .new {
                        Divider()
                        editor
                            .frame(width: VaultCardSize.detailWidth)
                    }
                }
            } else if model.entries.isEmpty, model.finds.isEmpty, editing == nil {
                EmptyStateView(icon: "lock.doc", title: "Nothing in the Vault yet",
                               message: "Keep the IDs and account numbers you get asked for here: a passport number, a member ID, a loan number. Each is sealed on this Mac and shown only to you.",
                               caption: model.lastReading.map { "Read \(Self.documents($0.documents)); nothing new to confirm." },
                               primary: .init("Add an ID", systemImage: "plus") { startAdding() },
                               secondary: .init("Read Documents", systemImage: "doc.text.viewfinder") { readDocuments() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    controlRow
                    Divider()
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            searchRow
                            Group {
                                switch layout {
                                case .cards: cardsView
                                case .list: listView
                                case .people: peopleView
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        side
                            .frame(width: VaultCardSize.detailWidth)
                    }
                }
            }
        }
    }

    /// The locked panel: a lock, and the one way past it. No name, date or ending.
    private var lockedView: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .scaledFont(.title.weight(.semibold))
                .foregroundStyle(glassHue.accentColor)
                .frame(width: 54, height: 54)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(glassHue.accentColor.opacity(0.14)))
                .accessibilityHidden(true)
            Text("The Vault is locked")
                .scaledFont(.title3.weight(.semibold))
            Text("Nothing in it is shown until you prove it is you.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.unlock() }
            } label: {
                Label("Unlock", systemImage: "touchid")
            }
            .buttonStyle(.borderedProminent).accentedProminent(glassHue)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isAsking)
            if addedWhileLocked {
                Text("Added. Unlock to see it.")
                    .scaledFont(.callout)
                    .foregroundStyle(SemanticColor.success)
            } else {
                Text("Add and Discover More still work while it is locked.")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            noticeText
        }
        .padding(24)
        .frame(maxWidth: 380)
    }

    /// Current, Archive and Other Finds, and beside them what they are showing: where, whose and
    /// which kinds.
    private var controlRow: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $model.tab) {
                Text("Current \(model.count(in: .current))").tag(VaultStanding.Tab.current)
                Text("Archive \(model.count(in: .archive))").tag(VaultStanding.Tab.archive)
                if model.count(in: .other) > 0 {
                    Text("Other Finds \(model.count(in: .other))").tag(VaultStanding.Tab.other)
                }
            }
            .pickerStyle(.segmented)
            .accentedSegments(glassHue)
            .labelsHidden()
            .fixedSize()
            .help("Current: the ID in use for each person and kind. Archive: older ones, kept for reference. A search looks in every tab.")
            showingChoices
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// The cards, two across where they fit, and a line naming the kinds with nothing yet.
    private var cardsView: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    readAgainBanner
                    tabBanner
                    let drawn = model.cardGroups
                    if drawn.isEmpty { noIDsState }
                    // Group by group in the groups' order: under each group's heading while Show
                    // Group Headings is on, else one wall in the same order.
                    if showsGroupHeadings {
                        ForEach(drawn) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                cardGroupHeading(group)
                                cardMasonry(group.slots)
                            }
                        }
                    } else {
                        cardMasonry(drawn.flatMap(\.slots))
                    }
                    // Kinds that only another country has, which no card here can point to.
                    if let elsewhere = model.elsewhereKinds { moreElsewhere(elsewhere, inCard: false) }
                    if model.tab == .current, model.query.isEmpty, model.personFilter == .everyone,
                       model.geoFilter == .all, model.kindFilter == nil, !model.emptyCategories.isEmpty {
                        Text("Nothing yet for \(ListFormatter.localizedString(byJoining: model.emptyCategories.map(\.title))). Add one with +, and choose its kind.")
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.selection) { _, id in if let id { scroller.scrollTo(id) } }
            .onChange(of: contactChosen) { _, id in if let id { scroller.scrollTo(id) } }
        }
    }

    /// A card: its header folds and opens it (⌥-click: every card); folded, the header says what
    /// is inside in one line.
    private func categoryCard(_ card: VaultCardID, _ rows: [VaultModel.Row]) -> some View {
        let isFolded = model.isFolded(card)
        let title = model.kinds.title(of: card)
        // The whole card is in its color, but for Increase Contrast, where its symbol alone is.
        let washed = contrast != .increased && model.tint(of: card) != nil
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) {
                    model.toggleFold(card, all: NSEvent.modifierFlags.contains(.option))
                }
            } label: {
                VaultCardHeader(title: title, symbol: model.kinds.symbol(of: card), count: rows.count,
                                isFolded: isFolded, foldedSummary: VaultModel.Row.foldedSummary(rows),
                                tint: model.tint(of: card), accent: glassHue.accentColor,
                                washes: contrast != .increased)
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Expand. ⌥-click to expand every card. Right-click for its color."
                           : "Collapse. ⌥-click to collapse every card. Right-click for its color.")
            .accessibilityLabel("\(title), \(rows.count)")
            // Folded, what the eye reads under the title is said too.
            .accessibilityValue(isFolded ? "Collapsed, \(VaultModel.Row.foldedSummary(rows))" : "Expanded")
            // Nothing about color sits on the card itself: it is chosen from here, or beside Kind
            // in the chosen ID's details, or in Customize Groups.
            .contextMenu {
                VaultCardTitleMenu(isFolded: isFolded, allFolded: model.allFolded,
                                   headingsShown: model.showsGroupHeadings,
                                   toggleHeadings: model.tab == .other ? nil : { model.showsGroupHeadings.toggle() },
                                   toggle: { withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) { model.toggleFold(card) } },
                                   toggleAll: { withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) { model.toggleFoldAll() } },
                                   color: model.tab == .other ? nil : { coloring = .title(card) })
            }
            .popover(isPresented: isColoring(.title(card)), arrowEdge: .bottom) { colorPopover(for: card, at: .title(card)).presentedNativeControlAccent() }
            if !isFolded {
                // The rows keep the card's inset; the title bar above runs edge to edge. One stack,
                // so one wash lies under them all.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in rowView(row, onColor: washed).id(row.id) }
                    if let elsewhere = model.elsewhere(card) { moreElsewhere(elsewhere, inCard: true) }
                }
                .modifier(VaultCardBody(tint: washed ? model.tint(of: card) : nil))
            }
        }
        .modifier(VaultCardChrome())
    }

    /// "N More in …": what the chosen country hides, a click from showing. In a card it is a row,
    /// the width of the card in the caption's size; under the cards, a line of its own.
    private func moreElsewhere(_ elsewhere: (filter: VaultGeoFilter, count: Int), inCard: Bool) -> some View {
        Button {
            model.geoFilter = elsewhere.filter
        } label: {
            let text = Text("\(elsewhere.count) More in \(elsewhere.filter.title) →")
                .scaledFont(inCard ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .foregroundStyle(glassHue.accentColor)
            if inCard {
                text
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            } else {
                text
            }
        }
        .buttonStyle(.plain)
        .help("Show \(elsewhere.filter.title)")
    }

    // MARK: Cards by group

    /// Show Group Headings, as the panel draws it: never on Other Finds, whose kinds have no group yet.
    private var showsGroupHeadings: Bool {
        model.showsGroupHeadings && !(model.tab == .other && model.query.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// A group's cards packed into columns, each under the shortest (``VaultMasonry``): no gap
    /// under a short card beside a tall one.
    private func cardMasonry(_ slots: [VaultCardSlot]) -> some View {
        VaultMasonry(minColumnWidth: 270, spacing: 12) {
            ForEach(slots) { slot in
                Group {
                    switch slot {
                    case .ids(let card, let rows): categoryCard(card, rows)
                    case .contact(let card): contactCard(card)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Its column comes from its header and every row, folded or not: folding it
                // never moves a card to another column.
                .layoutValue(key: VaultMasonrySize.self, value: CGFloat(1 + slot.count))
            }
        }
    }

    private func slotTint(_ slot: VaultCardSlot) -> VaultTint? {
        switch slot {
        case .ids(let card, _): return model.tint(of: card)
        case .contact: return model.colors.tint(ofGroup: VaultGroups.contact)
        }
    }

    private func slotSymbol(_ slot: VaultCardSlot) -> String {
        switch slot {
        case .ids(let card, _): return model.kinds.symbol(of: card)
        case .contact(let card): return card.kind.symbol
        }
    }

    private func slotTitle(_ slot: VaultCardSlot) -> String {
        switch slot {
        case .ids(let card, _): return model.kinds.title(of: card)
        case .contact(let card): return card.kind.title
        }
    }

    /// A group's heading: its name, in its color, and how many rows it holds. A click folds its
    /// cards (⌥-click: every card); its menu folds, moves it, hides the headings, colors it.
    private func cardGroupHeading(_ group: VaultCardGroup, folds: Bool = true) -> some View {
        let folded = folds && model.isFolded(group: group.id)
        let tint = model.tab == .other ? nil : model.colors.tint(ofGroup: group.id)
        return Button {
            guard folds else { return }
            withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) {
                model.toggleFold(group: group.id, all: NSEvent.modifierFlags.contains(.option))
            }
        } label: {
            HStack(spacing: 7) {
                if folds {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .scaledFont(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                }
                Circle()
                    .fill(tint?.color ?? Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(group.name.uppercased())
                    .scaledFont(.caption.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Text(group.count.formatted())
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(!folds ? "Right-click to move it."
              : folded ? "Expand this group. ⌥-click to expand every card. Right-click to move it."
              : "Collapse this group. ⌥-click to collapse every card. Right-click to move it.")
        .accessibilityLabel("\(group.name), \(group.count)")
        .accessibilityValue(!folds ? "" : folded ? "Collapsed" : "Expanded")
        .contextMenu { cardGroupMenu(group, folded: folded, folds: folds) }
        .popover(isPresented: Self.isShown($groupColoring, at: group.id), arrowEdge: .bottom) {
            groupColorPopover(group)
                .presentedNativeControlAccent()
        }
    }

    @ViewBuilder
    private func cardGroupMenu(_ group: VaultCardGroup, folded: Bool, folds: Bool = true) -> some View {
        if folds {
            Button(folded ? "Expand Group" : "Collapse Group") {
                withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) { model.toggleFold(group: group.id) }
            }
        }
        if model.groups.order.contains(group.id) {
            Button("Move Up") { moveGroup(group.id, by: -1) }
                .disabled(!model.groups.canMove(group.id, by: -1))
            Button("Move Down") { moveGroup(group.id, by: 1) }
                .disabled(!model.groups.canMove(group.id, by: 1))
        }
        Divider()
        Button("Hide Group Headings") { model.showsGroupHeadings = false }
        Divider()
        if model.groups.order.contains(group.id), model.tab != .other {
            Button("Color…") { groupColoring = group.id }
        }
        Button("Customize Groups…") { customizingGroups = true }
    }

    private func moveGroup(_ id: VaultGroups.ID, by step: Int) {
        var groups = model.groups
        groups.move(id, by: step)
        withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) { model.setGroups(groups) }
    }

    /// A group's color, from its heading: the same swatches as everywhere else (VT75).
    private func groupColorPopover(_ group: VaultCardGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color of \(group.name)")
                .scaledFont(.callout.weight(.semibold))
            VaultSwatches(chosen: model.colors.color(ofGroup: group.id), of: "group \(group.name)") {
                model.setColor($0, ofGroup: group.id)
            }
            .disabled(!model.colors.isOn)
            .opacity(model.colors.isOn ? 1 : 0.4)
            if !model.colors.isOn {
                Text("Colors are off in Customize Groups.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: VaultColorPopover.width, alignment: .leading)
        .onDisappear { if groupColoring == group.id { groupColoring = nil } }
    }

    // MARK: The Contact group's cards

    /// A Contact card: Home Addresses, Phones or Emails, in the Contact group's color. Its rows act
    /// like People's tiles, not like IDs: a click opens them in the details pane, nothing is
    /// masked, and they are not counted beside the IDs.
    private func contactCard(_ card: VaultContactCard) -> some View {
        let tint = model.colors.tint(ofGroup: VaultGroups.contact)
        let washed = contrast != .increased && tint != nil
        let isFolded = model.isFolded(card.kind)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) {
                    model.toggleFold(card.kind, all: NSEvent.modifierFlags.contains(.option))
                }
            } label: {
                VaultCardHeader(title: card.kind.title, symbol: card.kind.symbol, count: card.items.count,
                                isFolded: isFolded, foldedSummary: Self.contactFoldedSummary(card, people: people),
                                tint: tint, accent: glassHue.accentColor, washes: contrast != .increased)
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Expand. ⌥-click to expand every card." : "Collapse. ⌥-click to collapse every card.")
            .accessibilityLabel("\(card.kind.title), \(card.items.count)")
            .accessibilityValue(isFolded ? ["Collapsed", Self.contactFoldedSummary(card, people: people)].filter { !$0.isEmpty }.joined(separator: ", ") : "Expanded")
            .contextMenu {
                VaultCardTitleMenu(isFolded: isFolded, allFolded: model.allFolded,
                                   headingsShown: model.showsGroupHeadings,
                                   toggleHeadings: { model.showsGroupHeadings.toggle() },
                                   toggle: { withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) { model.toggleFold(card.kind) } },
                                   toggleAll: { withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) { model.toggleFoldAll() } },
                                   color: nil)
            }
            if !isFolded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(card.items) { item in contactRow(item).id(item.id) }
                }
                .modifier(VaultCardBody(tint: washed ? tint : nil))
            }
        }
        .modifier(VaultCardChrome())
    }

    /// A folded Contact card's one line: whose, as an ID card's says ("Anna, Erik").
    static func contactFoldedSummary(_ card: VaultContactCard, people: [Person]) -> String {
        var seen: [String] = []
        for id in card.items.flatMap(\.people) where !seen.contains(id) { seen.append(id) }
        return seen.compactMap { id in people.first { $0.id == id }?.displayName }.joined(separator: ", ")
    }

    /// The people a contact row is theirs, by name, in People's order.
    private func contactNames(_ item: VaultContactCard.Item) -> [String] {
        item.people.map { id in people.first { $0.id == id }?.displayName ?? "Someone no longer in People" }
    }

    /// "Henrik, Sigrid · From 4 IDs · Oct 2026", or "Sigrid · Mobile · From you".
    static func contactSubtitle(_ item: VaultContactCard.Item, names: [String]) -> String {
        var parts = [names.joined(separator: ", ")]
        // A search shows past addresses on Current too: each says so.
        if item.past { parts.append("Past") }
        if let address = item.address {
            parts.append(VaultPersonText.sourceLine(address.rows, typed: address.typed, dated: address.dated))
        } else if let phone = item.phone {
            if let label = phone.label { parts.append(label) }
            parts.append(VaultPersonText.sourceLine(phone.rows, typed: phone.typed))
        } else {
            if let label = item.typed?.label { parts.append(label) }
            parts.append("From you")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One contact row: whose (their initials), the value, whose and where it comes from, and a
    /// copy icon. Choosing it opens it in the details pane.
    private func contactRow(_ item: VaultContactCard.Item) -> some View {
        let names = contactNames(item)
        let chosen = contactChosen == item.id
        let copyKey = "contact-\(item.id)"
        return HStack(spacing: 10) {
            Text(names.map { String($0.prefix(1)).uppercased() }.joined(separator: "·"))
                .scaledFont(names.count > 1 ? .caption2.weight(.bold) : .callout.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.value)
                    .scaledFont(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.contactSubtitle(item, names: names))
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if item.licenseDiffers {
                Text("License differs")
                    .scaledFont(.caption2.weight(.semibold))
                    .foregroundStyle(PillVariant.labelInk(for: SemanticColor.warning))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(SemanticColor.warning.opacity(0.18)))
                    .fixedSize()
                    .help("A driver’s license here still prints an earlier address")
            }
            copyIcon(copyKey, help: "Copy \(item.value)") { copyString(item.value, key: copyKey) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(chosen ? glassHue.accentColor.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { chooseContact(item) }
        .help(item.value)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .contextMenu { contactMenu(item) }
    }

    private func chooseContact(_ item: VaultContactCard.Item) {
        editing = nil
        model.selection = nil
        contactChosen = item.id
    }

    /// Copy it (an address also by part, as forms ask), correct it, or take it out.
    @ViewBuilder
    private func contactMenu(_ item: VaultContactCard.Item) -> some View {
        Button("Copy") { copyString(item.value) }
        if let a = item.address?.address {
            Button("Copy Street") { copyString(([a.street] + [a.unit].compactMap { $0 }).joined(separator: ", ")) }
            Button("Copy City") { copyString(a.city) }
            Button("Copy ZIP Code") { copyString(a.zip) }
        }
        Divider()
        if !item.past {
            Button("Edit…") { editContact(item) }
        }
        // Asked in its details first: what it takes away has no button to bring it back.
        Button(Self.contactRemoveTitle(item) + "…") {
            chooseContact(item)
            removingContact = item
        }
    }

    /// "Not Their Address" or "Not Their Phone" for one papers print, "Remove" for one only typed.
    static func contactRemoveTitle(_ item: VaultContactCard.Item) -> String {
        if let phone = item.phone { return phoneRemoveTitle(phone) }
        guard let address = item.address, !address.rows.isEmpty else { return "Remove" }
        return "Not Their Address"
    }

    /// The IDs whose papers print a contact: an address's or a phone's.
    static func contactRows(_ item: VaultContactCard.Item) -> [VaultModel.Row] {
        item.address?.rows ?? item.phone?.rows ?? []
    }

    private func removeContact(_ item: VaultContactCard.Item) {
        if contactChosen == item.id { contactChosen = nil }
        switch item.kind {
        case .addresses:
            guard let address = item.address else { return }
            let read = !address.rows.isEmpty
            let everyone = read && address.rows.allSatisfy(\.isHousehold)
            for person in item.people {
                model.removeAddress(address.address.key, for: person, read: read, everyone: everyone)
            }
        case .phones:
            if let person = item.people.first, let phone = item.phone { removePhone(phone, for: person) }
        case .emails:
            if let person = item.people.first, let index = item.index { model.removeEmail(at: index, for: person) }
        }
    }

    /// A person's section as typing a contact needs it: their name, phones and emails.
    private func contactSection(_ person: String) -> VaultPersonSection {
        VaultPersonSection(typingFor: person, title: people.first { $0.id == person }?.displayName ?? person,
                           contacts: model.contacts[person] ?? VaultContacts())
    }

    /// Edit… from a contact row or its details: an address for everyone who lives there.
    private func editContact(_ item: VaultContactCard.Item) {
        guard let person = item.people.first else { return }
        let section = contactSection(person)
        switch item.kind {
        case .addresses:
            startContactEdit(.address, section, address: item.address, alsoFor: Array(item.people.dropFirst()), anchor: Self.contactEditAnchor)
        case .phones: startContactEdit(.phone, section, phone: item.phone, anchor: Self.contactEditAnchor)
        case .emails: startContactEdit(.email, section, index: item.index, anchor: Self.contactEditAnchor)
        }
    }

    /// Where the editor opened from a contact hangs: Edit… in its details.
    static let contactEditAnchor = "edit-contact"

    /// The contact row chosen, as the cards draw it now.
    private var chosenContact: VaultContactCard.Item? {
        guard let id = contactChosen else { return nil }
        return model.contactItems.first { $0.id == id }
    }

    /// A contact in the details pane: its parts, each copyable, the IDs whose papers print it,
    /// and Edit… and Not Their Address….
    private func contactDetail(_ item: VaultContactCard.Item) -> some View {
        let names = contactNames(item)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.address?.address.street ?? item.value)
                        .scaledFont(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text([item.past ? "Past address" : item.kind == .addresses ? "Home address" : item.kind == .phones ? "Phone" : "Email",
                          ListFormatter.localizedString(byJoining: names)].joined(separator: " · "))
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(Self.contactParts(item), id: \.label) { part in
                        GridRow {
                            Text(part.label)
                                .scaledFont(.callout)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(part.value)
                                .scaledFont(.callout.weight(.semibold))
                                .textSelection(.enabled)
                            let key = "contact-\(item.id)-\(part.label)"
                            copyIcon(key, help: "Copy \(part.value)") { copyString(part.value, key: key) }
                        }
                    }
                }
                if !Self.contactRows(item).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PRINTED ON")
                            .scaledFont(.caption2.weight(.semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                        ForEach(Self.contactRows(item)) { row in
                            Button {
                                contactChosen = nil
                                openSource(row)
                            } label: {
                                Text([Self.sourceLine(row), row.whose].joined(separator: " · "))
                                    .scaledFont(.callout)
                                    .foregroundStyle(glassHue.accentColor)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help(Self.sourceHelp(row, shown: false))
                        }
                    }
                }
                if item.licenseDiffers {
                    Text("A driver’s license here still prints an earlier address. The DMV asks to be told of a move.")
                        .scaledFont(.caption)
                        .foregroundStyle(SemanticColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Copy") { copyString(item.value, key: "contact-\(item.id)") }
                    if !item.past {
                        Button("Edit…") { editContact(item) }
                            .popover(isPresented: editBinding(Self.contactEditAnchor), arrowEdge: .bottom) {
                                if let person = item.people.first {
                                    contactEditor(contactSection(person))
                                        .presentedNativeControlAccent()
                                }
                            }
                    }
                    Button(Self.contactRemoveTitle(item) + "…") { removingContact = item }
                }
                .controlSize(.small)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(removingContact.map { Self.contactRemoveQuestion($0, names: contactNames($0)) } ?? "",
                            isPresented: Binding(get: { removingContact != nil }, set: { if !$0 { removingContact = nil } })) {
            if let removing = removingContact {
                Button(Self.contactRemoveTitle(removing), role: .destructive) {
                    removeContact(removing)
                    removingContact = nil
                }
            }
        }
    }

    /// "2841 Larkspur Lane is not Henrik’s or Sigrid’s home?", and the like.
    static func contactRemoveQuestion(_ item: VaultContactCard.Item, names: [String]) -> String {
        if let phone = item.phone, !phone.rows.isEmpty {
            return "\(phone.shown) is not \(ListFormatter.localizedString(byJoining: names))’s phone? The papers stay; it is no longer shown as theirs."
        }
        guard let address = item.address else { return "Remove \(item.value)?" }
        if address.rows.isEmpty { return "Remove \(address.address.street)?" }
        return "\(address.address.street) is not \(ListFormatter.localizedString(byJoining: names))’s home? The papers stay; it is no longer shown as theirs."
    }

    /// The parts a form asks for: an address's street, unit, city, state and ZIP; a phone or
    /// an email and its label.
    static func contactParts(_ item: VaultContactCard.Item) -> [(label: String, value: String)] {
        if let a = item.address?.address {
            return [("Street", a.street)] + (a.unit.map { [("Apt", $0)] } ?? []) + [("City", a.city), ("State", a.state), ("ZIP", a.zip)]
        }
        let label = item.phone?.label ?? item.typed?.label
        return [(item.kind == .phones ? "Number" : "Address", item.value)] + (label.map { [("Label", $0)] } ?? [])
    }

    /// The Color choice for `card`: from its title's menu, and beside Kind in an ID's details.
    private func colorPopover(for card: VaultCardID, at anchor: VaultColorAnchor) -> some View {
        let choice = model.colorChoice(for: card)
        return VaultColorPopover(choice: choice, accent: glassHue.accentColor,
                                 pickCard: { model.setColor($0, of: card) },
                                 pickGroup: { color in if let group = choice.group { model.setColor(color, ofGroup: group) } },
                                 turnOn: {
                                     var colors = model.colors
                                     colors.isOn = true
                                     model.setColors(colors)
                                 })
            // Its title or its ID went (the Vault locked, another tab): it does not come back
            // open when they do.
            .onDisappear { if coloring == anchor { coloring = nil } }
    }

    /// Whether the Color choice is open at `anchor`; closing it from the popover clears it.
    private func isColoring(_ anchor: VaultColorAnchor) -> Binding<Bool> { Self.isShown($coloring, at: anchor) }

    /// Whether the popover `shown` names is the one at `key`: closing it there clears `shown`,
    /// and never one another popover has opened since (VT106).
    static func isShown<Key: Equatable>(_ shown: Binding<Key?>, at key: Key) -> Binding<Bool> {
        Binding(get: { shown.wrappedValue == key },
                set: { open in if !open, shown.wrappedValue == key { shown.wrappedValue = nil } })
    }

    /// The row's document's name: in full while its number may be shown, else with any number in
    /// it masked, as the documents list draws it (a scan is often named for its number).
    static func fileName(_ row: VaultModel.Row, shown: Bool) -> String? {
        documentName(row.facts?.primary?.path, shown: shown, keep: VaultMask.keep(for: row.category))
    }

    /// `keep`: none for a kind whose ending is itself a secret (VT34).
    static func documentName(_ path: String?, shown: Bool, keep: Int = 4) -> String? {
        path.map { shown ? ($0 as NSString).lastPathComponent : VaultMask.fileName($0, keep: keep) }
    }


    /// The same rows, one column, under each kind's name.
    private var listView: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    readAgainBanner
                    tabBanner
                    let drawn = model.cardGroups
                    if drawn.isEmpty { noIDsState }
                    ForEach(drawn) { group in
                        // Each group's name over its kinds' while Show Group Headings is on.
                        if showsGroupHeadings {
                            // The list folds nothing: its headings name groups, with no fold (the second review).
                            cardGroupHeading(group, folds: false)
                                .padding(.horizontal, 4)
                                .padding(.top, 10)
                        }
                        ForEach(group.slots) { slot in
                            HStack(spacing: 6) {
                                if let tint = slotTint(slot) {
                                    Image(systemName: slotSymbol(slot))
                                        .scaledFont(.caption.weight(.semibold))
                                        .foregroundStyle(tint.color)
                                        .accessibilityHidden(true)
                                }
                                Text(slotTitle(slot))
                                    .scaledFont(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            switch slot {
                            case .ids(_, let rows): ForEach(rows) { row in rowView(row).id(row.id) }
                            case .contact(let card): ForEach(card.items) { item in contactRow(item).id(item.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .onChange(of: model.selection) { _, id in if let id { scroller.scrollTo(id) } }
            .onChange(of: contactChosen) { _, id in if let id { scroller.scrollTo(id) } }
        }
    }

    /// The People view: a section per person, opening with their name as their documents print it
    /// and their date of birth, then their IDs with the kind on each row. The same rows, filters,
    /// search and keys as the cards; only the grouping differs.
    ///
    /// One lazy stack, down to each line of two rows: a person's card is the pieces it is drawn
    /// from (``personSection(_:isFirst:)``), each a child of this stack. Built at once, a section of
    /// 14 IDs took 40 ms, and People jumped at every person. A lazy stack of lines inside each
    /// person's item placed a chosen ID from estimated heights, and choosing the list's last ID
    /// left it blank, the row never laid out (2026-11-22).
    private var peopleView: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The stack's spacing between these, and after them when any is shown: the
                    // zero-high mark at the end takes the gap only once something is above it.
                    VStack(alignment: .leading, spacing: 12) {
                        readAgainBanner
                        tabBanner
                        Color.clear.frame(height: 0)
                    }
                    let sections = model.peopleSections
                    if sections.isEmpty { noIDsState }
                    ForEach(sections) { section in personSection(section, isFirst: section.id == sections.first?.id) }
                }
                .padding(12)
            }
            .onChange(of: model.selection) { _, id in
                guard let id else { return }
                // A row is found by its line, each line a child of the stack.
                let line = model.peopleSections.lazy.flatMap(\.groups).compactMap { group in
                    Self.lines(group.rows).first { $0.rows.contains { $0.id == id } }
                }.first
                scroller.scrollTo(line?.id ?? id)
            }
        }
    }

    /// A person's card, as pieces of the lazy stack: their heading, their names and dates of birth,
    /// then each kind's heading and its lines of rows. Each piece draws its own slice of the card,
    /// and the last takes the card's bottom: its corners reach higher than a gap would.
    @ViewBuilder
    private func personSection(_ section: VaultPersonSection, isFirst: Bool) -> some View {
        let showsBirth = model.canShowBirth(in: section)
        let slots = Self.factSlots(section, tab: model.tab)
        let hasFacts = !slots.isEmpty
        let kinds = section.groups.map { PersonKind(owner: section.id, group: $0) }
        if !isFirst { Color.clear.frame(height: 12) }
        // Its own view, skipped while these stay the same, as the rows are.
        VaultPersonHeader(owner: section.id, title: section.title,
                          subtitle: Self.personSubtitle(ids: section.rows.count, elsewhere: section.elsewhere, tab: model.tab),
                          isAsking: model.isAsking,
                          add: { id in startAdding(for: id) })
            .equatable()
            .modifier(VaultCardSlice(first: true, last: !hasFacts && kinds.isEmpty))
        if hasFacts {
            // Every tile three lines tall: one row when wide, two or three otherwise (VaultFactsLayout).
            VaultFactsLayout(spacing: 8) {
                ForEach(slots, id: \.self) { slot in
                    factTile(slot, section, showsBirth: showsBirth)
                        .factSlot(slot)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .modifier(VaultCardSlice(first: false, last: kinds.isEmpty))
        }
        // Keyed by person and kind: every piece is a child of the one stack, where a kind's name
        // alone repeats from person to person, and a repeated key draws its heading once.
        ForEach(kinds) { kind in
            let lines = VaultCard.lines(kind.group.rows)
            groupHeading(kind.group)
                .background { if let draws { VaultLaidOut(key: VaultDrawCount.kind(kind.owner, kind.group.name), draws: draws) } }
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .modifier(VaultCardSlice(first: false, last: false))
            // Two columns once each can hold a row's title and number side by side, so a
            // line is two rows; at a narrower width the two stack. Two columns at most: a
            // third would cut each title short.
            ForEach(lines) { line in
                VaultTwoUp(minColumnWidth: 300, spacing: 14, rowSpacing: 2) {
                    ForEach(line.rows) { row in rowView(row, underPerson: true).id(row.id) }
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .modifier(VaultCardSlice(first: false, last: kind.id == kinds.last?.id && line.id == lines.last?.id))
            }
        }
    }

    /// A kind's rows under one person, told apart from the same kind under another.
    struct PersonKind: Identifiable {
        /// By the group's id, not its name (VT103): a group the user names "Other" and the one for
        /// kinds in no group (nil) are two.
        struct ID: Hashable {
            var owner: VaultPersonSection.Owner
            var group: VaultGroups.ID?
        }

        var owner: VaultPersonSection.Owner
        var group: VaultPersonSection.KindGroup
        var id: ID { ID(owner: owner, group: group.id) }
    }

    /// A group's rows two at a time, in order: People's lines.
    struct Line: Identifiable {
        var rows: [VaultModel.Row]
        var id: UUID { rows[0].id }
    }

    static func lines(_ rows: [VaultModel.Row]) -> [Line] {
        stride(from: 0, to: rows.count, by: 2).map { Line(rows: Array(rows[$0..<min($0 + 2, rows.count)])) }
    }

    /// A group's name over its rows, with a dot in its color.
    private func groupHeading(_ group: VaultPersonSection.KindGroup) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(group.id.flatMap { model.colors.tint(ofGroup: $0) }?.color ?? Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(group.name.uppercased())
                .scaledFont(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(group.rows.count.formatted())
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: People's fact tiles

    /// The tiles a section draws. For someone in People on Current, all five, each kept when not
    /// known yet (with Add… for what can be typed), so every card has one shape; on Archive, their
    /// names, date of birth and past addresses. For the household and a name as read, only what
    /// was read.
    static func factSlots(_ section: VaultPersonSection, tab: VaultStanding.Tab) -> [VaultFactsLayout.Slot] {
        let isPerson = section.personID != nil
        var slots: [VaultFactsLayout.Slot] = []
        if section.id != .household {
            if !section.names.isEmpty || isPerson { slots.append(.name) }
            if !section.births.isEmpty || (isPerson && tab != .archive) { slots.append(.birth) }
        }
        if tab == .archive {
            if !section.pastAddresses.isEmpty { slots.append(.address) }
            return slots
        }
        if isPerson { return slots + [.address, .phone, .email] }
        if section.home != nil { slots.append(.address) }
        return slots
    }

    @ViewBuilder
    private func factTile(_ slot: VaultFactsLayout.Slot, _ section: VaultPersonSection, showsBirth: Bool) -> some View {
        switch slot {
        case .name: nameTile(section)
        case .birth: birthTile(section, showsBirth: showsBirth)
        case .address: addressTile(section)
        case .phone: phoneTile(section)
        case .email: typedTile(section, kind: .email)
        }
    }

    /// A fact's tile, three lines whatever it holds: what it is in small capitals, with “+1 ›”
    /// when there is more (which opens `more`); the value on one line; where it comes from on one
    /// line; and a copy icon at its edge. A warning tile is for facts that need a look.
    private func factShell<Value: View, Source: View, Trailing: View, More: View>(
        _ label: String, warn: Bool = false, more: String? = nil, moreWarns: Bool = false, moreKey: String = "",
        @ViewBuilder value: () -> Value, @ViewBuilder source: () -> Source, @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder more popover: @escaping () -> More
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                factLabel(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let more {
                    let tint = moreWarns ? SemanticColor.warning : glassHue.accentColor
                    Button { factPopover = moreKey } label: {
                        Text(more)
                            .scaledFont(.caption2.weight(.semibold))
                            .foregroundStyle(PillVariant.labelInk(for: tint))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tint.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    // The label gives way first: the chip is never cut.
                    .fixedSize()
                    .layoutPriority(1)
                    .help("Show the rest")
                    .accessibilityLabel("\(label): \(more.replacingOccurrences(of: " ›", with: ""))")
                    .popover(isPresented: popoverBinding(moreKey), arrowEdge: .bottom) {
                        popover()
                            .presentedNativeControlAccent()
                            .keptFromCapture()
                    }
                }
            }
            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    value()
                    source()
                }
                Spacer(minLength: 4)
                trailing()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card)
            .fill(warn ? SemanticColor.warning.opacity(0.08) : Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card)
            .strokeBorder(warn ? SemanticColor.warning.opacity(0.55) : Color.primary.opacity(0.09)))
    }

    private func popoverBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { factPopover == key }, set: { if !$0, factPopover == key { factPopover = nil; roleChoosing = nil } })
    }

    private func factLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    /// The value, on one line: cut at its end when it does not fit, and whole on hover.
    /// `secret`: a date of birth, which no tooltip carries (a tooltip is a window of its own,
    /// which screen sharing sees).
    private func factValue(_ text: String, muted: Bool = false, secret: Bool = false) -> some View {
        Text(text)
            .scaledFont(.body.weight(.semibold))
            .foregroundStyle(muted ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(secret ? "" : text)
    }

    /// An address on one line, cut in its street when it does not fit: the city, state and ZIP
    /// a form asks for stay whole.
    private func addressValue(_ address: VaultAddress) -> some View {
        let street = ([address.street] + [address.unit].compactMap { $0 }).joined(separator: ", ")
        return HStack(spacing: 0) {
            Text(street)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(", \(address.city), \(address.state) \(address.zip)")
                .lineLimit(1)
                .layoutPriority(1)
        }
        .scaledFont(.body.weight(.semibold))
        .help(address.oneLine)
        .accessibilityElement(children: .combine)
    }

    /// “Add Phone…” where a value not known yet would be.
    private func addValue(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .scaledFont(.body.weight(.semibold))
                .foregroundStyle(glassHue.accentColor)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    /// The source line, “From where · when”: a link that opens the one ID, or lists several in a
    /// popover; plain text when typed or not known.
    @ViewBuilder
    private func factSource(_ text: String, rows: [VaultModel.Row] = [], key: String = "", title: String = "") -> some View {
        if rows.isEmpty {
            Text(text)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(text)
        } else {
            Button {
                if rows.count == 1, let row = rows.first { openSource(row) } else { factPopover = key }
            } label: {
                Text(text)
                    .scaledFont(.caption)
                    .foregroundStyle(glassHue.accentColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(rows.count == 1 ? Self.sourceHelp(rows[0], shown: false) : "The IDs this was read from")
            .popover(isPresented: popoverBinding(key), arrowEdge: .bottom) {
                sourcesList(title, rows: rows)
                    .presentedNativeControlAccent()
                    .keptFromCapture()
            }
        }
    }

    /// The icon that copies a fact, a tick while it is on the clipboard.
    private func copyIcon(_ key: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: copiedDetail == key ? "checkmark" : "doc.on.doc")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private func copyString(_ text: String, key: String? = nil) {
        VaultPasteboard.copyPlain(text)
        if let key { flashCopied(key) }
    }

    // MARK: Names

    /// The name forms ask for, legal first; the other spellings, with their roles and the fix for
    /// one that looks misread, behind “+1 ›”.
    private func nameTile(_ section: VaultPersonSection) -> some View {
        let lead = section.names.first
        let others = max(0, section.names.count - 1)
        let misread = section.names.filter(\.looksMisread).count
        let key = "names-\(section.title)"
        // After Correct to Legal Name takes the last other spelling, the chip stays for its Undo.
        let noted = misreadNote?.section == section.title
        let more: String? = others == 0 ? (noted ? "Corrected ›" : nil) : misread > 0 ? "+\(others) · \(misread) misread ›" : "+\(others) ›"
        let name = lead?.name ?? section.title
        return factShell(section.names.count > 1 ? "Names" : "Name", more: more, moreWarns: misread > 0, moreKey: key) {
            factValue(name)
        } source: {
            if let lead {
                factSource(VaultPersonText.sourceLine(lead.rows), rows: lead.rows, key: key + "-source",
                           title: lead.alsoWritten.isEmpty ? "“\(lead.name)” is printed on \(lead.rows.count) IDs"
                               : "This name is printed on \(lead.rows.count) IDs")
                    .help(Self.printedHelp(lead))
            } else {
                factSource("From People")
            }
        } trailing: {
            let copyKey = "name-\(section.title)-\(name)"
            copyIcon(copyKey, help: "Copy “\(name)”") { copyString(name, key: copyKey) }
        } more: {
            namesPopover(section)
        }
    }

    /// Every spelling with its role and where it is printed; choosing a role swaps the popover to
    /// the four roles, with Back. One popover, never one opened from another.
    private func namesPopover(_ section: VaultPersonSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let choosing = roleChoosing, let person = section.personID,
               let name = section.names.first(where: { $0.name == choosing }) {
                Button { roleChoosing = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.link)
                    .scaledFont(.caption)
                roleChoices(section, name, person: person)
            } else {
                ForEach(Array(section.names.enumerated()), id: \.element.name) { index, name in
                    if index > 0 { Divider() }
                    nameLine(section, name, first: index == 0)
                }
                if let note = misreadNote, note.section == section.title {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(SemanticColor.success)
                        Text("“\(note.name)” was a misreading: \(note.count == 1 ? "1 ID" : "\(note.count) IDs") now read \(note.legal).")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Undo") {
                            model.undoMisread(note.name, for: section.personID)
                            misreadNote = nil
                        }
                        .buttonStyle(.link)
                    }
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
    }

    /// One spelling: the name, its role, where it is printed and a copy icon; one that looks
    /// misread offers to correct it or keep it.
    private func nameLine(_ section: VaultPersonSection, _ name: VaultPersonSection.PrintedName, first: Bool) -> some View {
        let person = section.personID
        let legal = section.names.first { $0.role == .legal }?.name
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name.name)
                        .scaledFont(first ? .body.weight(.semibold) : .callout.weight(.semibold))
                        .lineLimit(1)
                    if section.names.count > 1 { roleChip(section, name, person: person) }
                }
                Text(VaultPersonText.sourceLine(name.rows))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(Self.printedHelp(name))
                if name.looksMisread, let person, let legal {
                    HStack(spacing: 8) {
                        Button("Correct to Legal Name") {
                            let count = model.setRole(.misread, of: name.name, for: person)
                            misreadNote = .init(section: section.title, name: name.name, legal: legal, count: count)
                        }
                        .help("Every ID read with “\(name.name)” shows \(legal) instead. What was read stays in its details.")
                        Button("Not a Misreading") { model.setRole(.alsoUsed, of: name.name, for: person) }
                            .buttonStyle(.link)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            let copyKey = "name-\(section.title)-\(name.name)"
            copyIcon(copyKey, help: "Copy “\(name.name)”") { copyString(name.name, key: copyKey) }
        }
    }

    /// Where a name is printed, and how else its papers write it: one name, one chip (VT100).
    static func printedHelp(_ name: VaultPersonSection.PrintedName) -> String {
        let papers = ListFormatter.localizedString(byJoining: name.on)
        guard !name.alsoWritten.isEmpty else { return "Printed this way on \(papers)." }
        let others = ListFormatter.localizedString(byJoining: name.alsoWritten.map { "“\($0)”" })
        return "Printed on \(papers); some papers write it \(others)."
    }

    /// The spelling's role as a chip; for someone in People it swaps the popover to the roles.
    @ViewBuilder
    private func roleChip(_ section: VaultPersonSection, _ name: VaultPersonSection.PrintedName, person: String?) -> some View {
        let label = name.looksMisread ? "Looks misread" : name.role.title
        let tint: Color = name.looksMisread ? SemanticColor.warning
            : name.role == .legal ? glassHue.accentColor : name.role == .goesBy ? SemanticColor.success : .secondary
        let chip = HStack(spacing: 3) {
            Text(label)
            if person != nil { Image(systemName: "chevron.down").imageScale(.small) }
        }
        .scaledFont(.caption2.weight(.semibold))
        // The colour lives in the wash; the word is drawn in label ink, readable on any of them.
        .foregroundStyle(PillVariant.labelInk(for: tint))
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(Capsule().fill(tint.opacity(0.18)))
        if person != nil {
            Button { roleChoosing = name.name } label: { chip }
                .buttonStyle(.plain)
                .help("What this spelling is to \(section.title)")
                .accessibilityLabel("\(name.name): \(label). Change")
        } else {
            chip
        }
    }

    /// The four roles a spelling can have, each with what it means.
    private func roleChoices(_ section: VaultPersonSection, _ name: VaultPersonSection.PrintedName, person: String) -> some View {
        let legal = section.names.first { $0.role == .legal }?.name
        return VStack(alignment: .leading, spacing: 2) {
            Text(name.name)
                .scaledFont(.callout.weight(.semibold))
                .padding(.bottom, 4)
            ForEach(VaultNameRole.allCases, id: \.self) { role in
                let isMisread = role == .misread
                let disabled = isMisread && (legal == nil || name.role == .legal)
                Button {
                    roleChoosing = nil
                    let count = model.setRole(role, of: name.name, for: person)
                    if isMisread, let legal { misreadNote = .init(section: section.title, name: name.name, legal: legal, count: count) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: name.role == role && !name.looksMisread ? "checkmark" : "circle")
                            .opacity(name.role == role && !name.looksMisread ? 1 : 0)
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(isMisread ? "Misread…" : role.title)
                                .scaledFont(.callout.weight(.medium))
                            Text(Self.roleMeaning(role, legal: legal))
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
            }
        }
    }

    /// What a role means, as the choice of roles says it.
    static func roleMeaning(_ role: VaultNameRole, legal: String?) -> String {
        switch role {
        case .legal: return "The name forms ask for “as on your passport”. One per person."
        case .goesBy: return "The name they use day to day."
        case .alsoUsed: return "A real spelling some papers print. Kept, under the rest."
        case .misread: return "A scan got it wrong: every ID read with it shows \(legal ?? "the legal name") instead."
        }
    }

    // MARK: Date of birth

    /// The date most of their IDs give; a second date, and the warning, behind “+1 date ›”.
    private func birthTile(_ section: VaultPersonSection, showsBirth: Bool) -> some View {
        let key = "births-\(section.title)"
        let lead = section.births.first
        let others = max(0, section.births.count - 1)
        return factShell("Date of birth", warn: others > 0, more: others == 0 ? nil : "+\(others) \(others == 1 ? "date" : "dates") ›",
                         moreWarns: true, moreKey: key) {
            if let lead {
                factValue(showsBirth ? VaultReading.spelled(lead.date) : "•• ••••• ••••", muted: !showsBirth, secret: true)
            } else {
                factValue("Not known", muted: true)
            }
        } source: {
            if let lead {
                birthSource(section, lead, showsBirth: showsBirth)
            } else {
                factSource("Not on any ID yet")
            }
        } trailing: {
            if let lead { birthTrailing(section, lead, showsBirth: showsBirth) }
        } more: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(section.births.enumerated()), id: \.offset) { index, birth in
                    if index > 0 { Divider() }
                    HStack(alignment: .center, spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(showsBirth ? VaultReading.spelled(birth.date) : "•• ••••• ••••")
                                .scaledFont(index == 0 ? .body.weight(.semibold) : .callout.weight(.semibold))
                                .foregroundStyle(showsBirth ? .primary : .secondary)
                            birthSource(section, birth, showsBirth: showsBirth)
                        }
                        Spacer(minLength: 4)
                        birthTrailing(section, birth, showsBirth: showsBirth)
                    }
                }
                Text("Check which is right. Open the ID a wrong date came from to give it to whoever it belongs to, or to remove it.")
                    .scaledFont(.caption)
                    .foregroundStyle(SemanticColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 340, alignment: .leading)
        }
    }

    private func birthSource(_ section: VaultPersonSection, _ birth: VaultPersonSection.Birth, showsBirth: Bool) -> some View {
        factSource(VaultPersonText.sourceLine(birth.rows), rows: birth.rows,
                   key: "\(section.title)-\(birth.date.timeIntervalSince1970)",
                   title: showsBirth ? "\(VaultReading.spelled(birth.date)) was read from \(birth.rows.count) IDs"
                                     : "This date of birth was read from \(birth.rows.count) IDs")
    }

    /// Copy once it may be shown; until then the eye that asks for Touch ID.
    @ViewBuilder
    private func birthTrailing(_ section: VaultPersonSection, _ birth: VaultPersonSection.Birth, showsBirth: Bool) -> some View {
        let key = "born-\(section.title)-\(birth.date.timeIntervalSince1970)"
        if showsBirth {
            copyIcon(key, help: "Copy the date of birth, the way US forms ask for a date") {
                Task { if await model.copyBirth(birth.date, in: section) { flashCopied(key) } }
            }
        } else {
            Button {
                if let id = section.rows.first?.id { Task { await model.show(id) } }
            } label: {
                Image(systemName: "eye").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Show it after Touch ID")
            .accessibilityLabel("Show the date of birth")
        }
    }

    // MARK: Home address

    /// Where they live now on Current; on Archive, the newest past address, the older ones behind
    /// “+1 ›”. A license still printing an address they have left says so on Current.
    private func addressTile(_ section: VaultPersonSection) -> some View {
        let archive = model.tab == .archive
        let shown = archive ? section.pastAddresses.first : section.home
        let older = archive ? Array(section.pastAddresses.dropFirst()) : []
        let differs = archive ? nil : section.licenseDiffers
        let key = "address-\(section.title)"
        let more: String? = differs != nil ? "License differs ›" : older.isEmpty ? nil : "+\(older.count) ›"
        return factShell(archive ? "Past address" : "Home address", more: more, moreWarns: differs != nil, moreKey: key) {
            if let shown {
                addressValue(shown.address)
            } else {
                addValue("Add Address…") { startContactEdit(.address, section) }
            }
        } source: {
            if let shown {
                factSource(VaultPersonText.sourceLine(shown.rows, typed: shown.typed, dated: shown.dated), rows: shown.rows,
                           key: key + "-source", title: "\(shown.address.oneLine) is printed on \(shown.rows.count) IDs")
            } else {
                factSource("Not on any ID yet")
            }
        } trailing: {
            if let shown {
                let copyKey = "address-\(section.title)-\(shown.address.key)"
                copyIcon(copyKey, help: "Copy the address on one line") { copyString(shown.address.oneLine, key: copyKey) }
            }
        } more: {
            if let differs, let home = section.home {
                licensePopover(differs, home: home)
            } else {
                addressesPopover(older, section)
            }
        }
        .contextMenu {
            if let shown { addressMenu(shown, section, past: archive) }
        }
        .popover(isPresented: editBinding("edit-\(section.title)-address"), arrowEdge: .bottom) {
            contactEditor(section)
                .presentedNativeControlAccent()
        }
    }

    /// Copy all or a part (forms ask for street, city and ZIP apart), see the IDs, correct it, or
    /// say it is not theirs.
    @ViewBuilder
    private func addressMenu(_ shown: VaultPersonSection.Address, _ section: VaultPersonSection, past: Bool) -> some View {
        let a = shown.address
        Button("Copy Address") { copyString(a.oneLine) }
        Button("Copy Street") { copyString(([a.street] + [a.unit].compactMap { $0 }).joined(separator: ", ")) }
        Button("Copy City") { copyString(a.city) }
        Button("Copy ZIP Code") { copyString(a.zip) }
        Divider()
        if shown.rows.count == 1, let row = shown.rows.first {
            Button("Show the ID") { openSource(row) }
        } else if shown.rows.count > 1 {
            Button("Show the IDs") { factPopover = "address-\(section.title)-source" }
        }
        if let person = section.personID {
            if !past { Button("Edit…") { startContactEdit(.address, section, address: shown) } }
            Button(shown.rows.isEmpty ? "Remove" : "Not Their Address") {
                model.removeAddress(shown.address.key, for: person, read: !shown.rows.isEmpty,
                                    everyone: !shown.rows.isEmpty && shown.rows.allSatisfy(\.isHousehold))
            }
        }
    }

    /// The license, and the address it still prints.
    private func licensePopover(_ old: VaultPersonSection.Address, home: VaultPersonSection.Address) -> some View {
        let license = old.rows.first { $0.category == .driversLicense }
        return VStack(alignment: .leading, spacing: 8) {
            Text("The driver’s license prints an earlier address")
                .scaledFont(.callout.weight(.semibold))
            Text(old.address.oneLine)
                .scaledFont(.callout)
                .textSelection(.enabled)
            Text("Newer papers print \(home.address.oneLine). The DMV asks to be told of a move.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let license {
                Button("Show the License") {
                    factPopover = nil
                    openSource(license)
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    /// Older past addresses, newest first, each with where it was printed.
    private func addressesPopover(_ older: [VaultPersonSection.Address], _ section: VaultPersonSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(older.enumerated()), id: \.element.address.key) { index, address in
                if index > 0 { Divider() }
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(address.address.oneLine)
                            .scaledFont(.callout.weight(.semibold))
                            .lineLimit(1)
                            .help(address.address.oneLine)
                        factSource(VaultPersonText.sourceLine(address.rows, typed: address.typed, dated: address.dated),
                                   rows: address.rows, key: "address-\(section.title)-\(address.address.key)-source",
                                   title: "\(address.address.oneLine) is printed on \(address.rows.count) IDs")
                    }
                    Spacer(minLength: 4)
                    let copyKey = "address-\(section.title)-\(address.address.key)"
                    copyIcon(copyKey, help: "Copy the address on one line") { copyString(address.address.oneLine, key: copyKey) }
                }
            }
        }
        .padding(12)
        .frame(width: 360, alignment: .leading)
    }

    // MARK: Phone and email

    /// The phone that leads, typed or read; the rest behind “+1 ›”; Add… when none.
    private func phoneTile(_ section: VaultPersonSection) -> some View {
        let lead = section.phones.first
        let key = "phone-\(section.title)"
        return factShell(lead?.label.map { "Phone · \($0)" } ?? "Phone",
                         more: section.phones.count > 1 ? "+\(section.phones.count - 1) ›" : nil, moreKey: key) {
            if let lead {
                factValue(lead.shown)
            } else {
                addValue("Add Phone…") { startContactEdit(.phone, section) }
            }
        } source: {
            if let lead {
                factSource(VaultPersonText.sourceLine(lead.rows, typed: lead.typed), rows: lead.rows, key: key + "-source",
                           title: "\(lead.shown) is printed on \(lead.rows.count) IDs")
            } else {
                factSource("Not on any ID yet")
            }
        } trailing: {
            if let lead {
                let copyKey = "\(key)-\(lead.key)"
                copyIcon(copyKey, help: "Copy \(lead.shown)") { copyString(lead.shown, key: copyKey) }
            }
        } more: {
            phonesPopover(section)
        }
        .contextMenu {
            if let lead { phoneMenu(lead, section) }
        }
        .popover(isPresented: editBinding("edit-\(section.title)-phone"), arrowEdge: .bottom) {
            contactEditor(section)
                .presentedNativeControlAccent()
        }
    }

    /// Copy it, see the IDs that print it, correct it, add another, or take it out.
    @ViewBuilder
    private func phoneMenu(_ phone: VaultPersonSection.Phone, _ section: VaultPersonSection) -> some View {
        Button("Copy") { copyString(phone.shown) }
        if phone.rows.count == 1, let row = phone.rows.first {
            Divider()
            Button("Show the ID") { openSource(row) }
        } else if phone.rows.count > 1 {
            Divider()
            Button("Show the IDs") { factPopover = "phone-\(section.title)-source" }
        }
        if let person = section.personID {
            Divider()
            Button("Edit…") { startContactEdit(.phone, section, phone: phone) }
            Button("Add Another…") { startContactEdit(.phone, section) }
            Button(Self.phoneRemoveTitle(phone)) { removePhone(phone, for: person) }
        }
    }

    /// "Not Their Phone" for one papers print, "Remove" for one only typed.
    static func phoneRemoveTitle(_ phone: VaultPersonSection.Phone) -> String {
        phone.rows.isEmpty ? "Remove" : "Not Their Phone"
    }

    private func removePhone(_ phone: VaultPersonSection.Phone, for person: String) {
        model.removePhone(at: phone.typedIndex, read: phone.rows.isEmpty ? nil : phone.key, for: person)
    }

    /// Every phone, each with its label, where it is from, copy, Edit and Remove.
    private func phonesPopover(_ section: VaultPersonSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(section.phones.enumerated()), id: \.element.key) { index, phone in
                if index > 0 { Divider() }
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phone.shown)
                            .scaledFont(index == 0 ? .body.weight(.semibold) : .callout.weight(.semibold))
                            .lineLimit(1)
                        Text([phone.label, VaultPersonText.sourceLine(phone.rows, typed: phone.typed)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("Edit…") { startContactEdit(.phone, section, phone: phone) }
                        .buttonStyle(.link)
                    Button(Self.phoneRemoveTitle(phone)) {
                        guard let person = section.personID else { return }
                        removePhone(phone, for: person)
                    }
                    .buttonStyle(.link)
                    let copyKey = "phone-\(section.title)-\(phone.key)"
                    copyIcon(copyKey, help: "Copy \(phone.shown)") { copyString(phone.shown, key: copyKey) }
                }
            }
            Divider()
            Button("Add Another Phone…") { startContactEdit(.phone, section) }
                .buttonStyle(.link)
        }
        .scaledFont(.caption)
        .padding(12)
        .frame(width: 400, alignment: .leading)
    }

    /// The first email typed for them; the rest behind “+1 ›”; Add… when none.
    private func typedTile(_ section: VaultPersonSection, kind: ContactEdit.Kind) -> some View {
        let values = section.emails
        let noun = kind == .phone ? "Phone" : "Email"
        let lead = values.first
        let shown = lead.map { Self.typedShown($0, kind: kind) }
        let key = "\(kind.rawValue)-\(section.title)"
        return factShell(lead?.label.map { "\(noun) · \($0)" } ?? noun, more: values.count > 1 ? "+\(values.count - 1) ›" : nil,
                         moreKey: key) {
            if let shown {
                factValue(shown)
            } else {
                addValue("Add \(noun)…") { startContactEdit(kind, section) }
            }
        } source: {
            factSource(lead == nil ? "Typed once, kept in the Vault" : VaultPersonText.sourceLine([], typed: true))
        } trailing: {
            if let shown {
                let copyKey = "\(key)-0"
                copyIcon(copyKey, help: "Copy \(shown)") { copyString(shown, key: copyKey) }
            }
        } more: {
            typedPopover(section, kind: kind)
        }
        .contextMenu {
            if let shown, let person = section.personID {
                Button("Copy") { copyString(shown) }
                Divider()
                Button("Edit…") { startContactEdit(kind, section, index: 0) }
                Button("Add Another…") { startContactEdit(kind, section) }
                Button("Remove") {
                    model.removeEmail(at: 0, for: person)
                }
            }
        }
        .popover(isPresented: editBinding("edit-\(section.title)-\(kind.rawValue)"), arrowEdge: .bottom) {
            contactEditor(section)
                .presentedNativeControlAccent()
        }
    }

    static func typedShown(_ typed: VaultContacts.Typed, kind: ContactEdit.Kind) -> String {
        kind == .phone ? VaultContacts.phoneShown(typed.value) : typed.value
    }

    /// Every email typed for them, each with its label, copy, Edit and Remove.
    private func typedPopover(_ section: VaultPersonSection, kind: ContactEdit.Kind) -> some View {
        let values = section.emails
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, typed in
                if index > 0 { Divider() }
                HStack(alignment: .center, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.typedShown(typed, kind: kind))
                            .scaledFont(index == 0 ? .body.weight(.semibold) : .callout.weight(.semibold))
                            .lineLimit(1)
                        Text([typed.label, "From you"].compactMap { $0 }.joined(separator: " · "))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Edit…") { startContactEdit(kind, section, index: index) }
                        .buttonStyle(.link)
                    Button("Remove") {
                        guard let person = section.personID else { return }
                        model.removeEmail(at: index, for: person)
                    }
                    .buttonStyle(.link)
                    let copyKey = "\(kind.rawValue)-\(section.title)-\(index)"
                    copyIcon(copyKey, help: "Copy \(Self.typedShown(typed, kind: kind))") {
                        copyString(Self.typedShown(typed, kind: kind), key: copyKey)
                    }
                }
            }
            Divider()
            Button(kind == .phone ? "Add Another Phone…" : "Add Another Email…") { startContactEdit(kind, section) }
                .buttonStyle(.link)
        }
        .scaledFont(.caption)
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }

    // MARK: Typing a contact

    /// A phone, email or address being typed, in a popover on its tile.
    struct ContactEdit: Equatable {
        enum Kind: String { case phone, email, address }
        var kind: Kind
        var section: String
        var person: String
        /// The phone or email being edited; nil adds one.
        var index: Int?
        /// The address being corrected (its key); nil adds one.
        var replacing: String?
        /// A phone papers print, being corrected (its key): set aside unless kept as it is.
        var correcting: String?
        var value = ""
        var label = ""
        var street = "", unit = "", city = "", state = "", zip = ""
        /// Everyone else the new address is also for (“Same for”).
        var alsoFor: Set<String> = []
        /// Where the editor hangs when not on its tile: Edit… in a contact's details.
        var place: String?
        var anchor: String { place ?? "edit-\(section)-\(kind.rawValue)" }

        var address: VaultAddress { VaultAddress(street: street, unit: unit, city: city, state: state, zip: zip).trimmed }

        var canSave: Bool {
            switch kind {
            case .phone: return VaultContacts.looksLikePhone(value)
            case .email: return VaultContacts.looksLikeEmail(value)
            case .address: return address.isComplete
            }
        }
    }

    private func startContactEdit(_ kind: ContactEdit.Kind, _ section: VaultPersonSection, index: Int? = nil,
                                  phone: VaultPersonSection.Phone? = nil,
                                  address: VaultPersonSection.Address? = nil, alsoFor: [String] = [], anchor: String? = nil) {
        guard let person = section.personID else { return }
        var edit = ContactEdit(kind: kind, section: section.title, person: person, index: index)
        edit.place = anchor
        switch kind {
        case .phone:
            if let phone {
                edit.index = phone.typedIndex
                edit.value = phone.typed ? phone.value : phone.shown
                edit.label = phone.label ?? VaultContacts.phoneLabels[0]
                // Papers print it: a different number typed in its place sets theirs aside.
                edit.correcting = phone.rows.isEmpty ? nil : phone.key
            } else {
                edit.label = VaultContacts.phoneLabels[0]
            }
        case .email:
            if let index, section.emails.indices.contains(index) {
                edit.value = section.emails[index].value
                edit.label = section.emails[index].label ?? ""
            } else {
                edit.label = VaultContacts.emailLabels[0]
            }
        case .address:
            if let a = address?.address {
                (edit.street, edit.unit, edit.city, edit.state, edit.zip) = (a.street, a.unit ?? "", a.city, a.state, a.zip)
                edit.replacing = a.key
                // A shared address is put right for everyone who lives there.
                edit.alsoFor = Set(alsoFor)
            } else {
                // Offered for everyone else in People, each ticked (PY).
                edit.alsoFor = Set(model.people.map(\.id).filter { $0 != person })
            }
        }
        // Opened from a “+1 ›” popover, the editor waits for it to close: macOS shows no popover
        // asked for while another is still closing.
        guard factPopover != nil else { contactEdit = edit; return }
        factPopover = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            contactEdit = edit
        }
    }

    private func editBinding(_ anchor: String) -> Binding<Bool> {
        Binding(get: { contactEdit?.anchor == anchor }, set: { if !$0, contactEdit?.anchor == anchor { contactEdit = nil } })
    }

    private func editField(_ path: WritableKeyPath<ContactEdit, String>) -> Binding<String> {
        Binding(get: { contactEdit?[keyPath: path] ?? "" }, set: { contactEdit?[keyPath: path] = $0 })
    }

    @ViewBuilder
    private func contactEditor(_ section: VaultPersonSection) -> some View {
        if let edit = contactEdit {
            let noun = edit.kind == .phone ? "Phone" : edit.kind == .email ? "Email" : "Home address"
            VStack(alignment: .leading, spacing: 8) {
                Text("\(noun) for \(section.title)")
                    .scaledFont(.callout.weight(.semibold))
                switch edit.kind {
                case .phone, .email:
                    TextField(edit.kind == .phone ? "(408) 555-0142" : "name@example.com", text: editField(\.value))
                    Picker("Label", selection: editField(\.label)) {
                        ForEach(edit.kind == .phone ? VaultContacts.phoneLabels : VaultContacts.emailLabels, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accentedSegments(glassHue)
                case .address:
                    TextField("Street", text: editField(\.street))
                    TextField("Apt, suite (optional)", text: editField(\.unit))
                    HStack(spacing: 6) {
                        TextField("City", text: editField(\.city))
                        TextField("State", text: editField(\.state)).frame(width: 52)
                        TextField("ZIP", text: editField(\.zip)).frame(width: 70)
                    }
                    let others = model.people.filter { $0.id != edit.person }
                    if edit.replacing == nil, !others.isEmpty {
                        HStack(spacing: 10) {
                            Text("Same for:")
                                .foregroundStyle(.secondary)
                            ForEach(others) { other in
                                Toggle(other.displayName, isOn: Binding(
                                    get: { contactEdit?.alsoFor.contains(other.id) ?? false },
                                    set: { on in if on { contactEdit?.alsoFor.insert(other.id) } else { contactEdit?.alsoFor.remove(other.id) } }))
                            }
                        }
                        .scaledFont(.caption)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { contactEdit = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { saveContactEdit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!edit.canSave)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(12)
            .frame(width: 340, alignment: .leading)
        }
    }

    private func saveContactEdit() {
        guard let edit = contactEdit, edit.canSave else { return }
        switch edit.kind {
        case .phone:
            model.setPhone(edit.value, label: edit.label, for: edit.person, replacing: edit.index, correcting: edit.correcting)
        case .email: model.setEmail(edit.value, label: edit.label, for: edit.person, replacing: edit.index)
        case .address:
            model.setAddress(edit.address, for: edit.person, alsoFor: Array(edit.alsoFor).sorted(), replacing: edit.replacing)
        }
        contactEdit = nil
    }

    /// The IDs a fact was read from, each with its document; choosing one opens it.
    private func sourcesList(_ title: String, rows: [VaultModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .scaledFont(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        Button {
                            factPopover = nil
                            openSource(row)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.sourceLine(row))
                                    .foregroundStyle(glassHue.accentColor)
                                Spacer(minLength: 8)
                                Text(Self.fileName(row, shown: model.canShow(row: row)) ?? "")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .scaledFont(.callout)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
            Text("Choose one to see its document.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }

    /// "4 IDs · 2 in Archive"; on Archive, "2 IDs · 4 current".
    static func personSubtitle(ids: Int, elsewhere: Int, tab: VaultStanding.Tab) -> String {
        var parts = [ids == 1 ? "1 ID" : "\(ids.formatted()) IDs"]
        if elsewhere > 0 {
            parts.append(tab == .archive ? "\(elsewhere.formatted()) current" : "\(elsewhere.formatted()) in Archive")
        }
        return parts.joined(separator: " · ")
    }

    /// What Cards, List and People show when the tab draws no ID: the choices hiding them all,
    /// with the way back, or nothing here or matching the search (VT75: one for every layout).
    @ViewBuilder
    private var noIDsState: some View {
        if hiddenByChoices {
            hiddenByChoicesState
        } else {
            EmptyStateView(icon: "magnifyingglass", title: emptyTitle, message: emptyMessage, layout: .compact)
                .padding(.top, 24)
                .frame(maxWidth: .infinity)
        }
    }

    /// The empty state when the tab has IDs but the choices hide them all.
    private var hiddenByChoicesState: some View {
        EmptyStateView(icon: "line.3.horizontal.decrease.circle", title: "Nothing here for these choices",
                       message: "IDs on this tab belong to another country, person or kind.",
                       primary: .init("Show Everything", systemImage: "arrow.uturn.backward") {
                           model.resetFilters()
                       }, layout: .compact)
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
    }

    /// "Copied" on a detail's or a fact's Copy for two seconds.
    private func flashCopied(_ key: String) {
        Self.flash(key, in: $copiedDetail)
    }

    /// `value` in `state` for two seconds, for a button's "Copied": then nil, unless another copy
    /// has put its own there since.
    private static func flash<Value: Equatable>(_ value: Value, in state: Binding<Value?>) {
        state.wrappedValue = value
        Task {
            try? await Task.sleep(for: .seconds(2))
            if state.wrappedValue == value { state.wrappedValue = nil }
        }
    }

    @ViewBuilder
    private var tabBanner: some View {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if model.tab == .other {
            Text("Kinds the Vault can read but doesn’t show on the main view yet.")
                .scaledFont(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// After a build that reads documents differently: what was read before was let go, so the
    /// tabs hold only what was saved until the folders are read again.
    @ViewBuilder
    private var readAgainBanner: some View {
        if model.needsReadAgain, let reading = model.reading, reading.scope.isRefresh {
            // Refresh runs by itself after an update: nothing to click, only to stop.
            readingBanner("This version reads documents better. Updating the \(Self.documents(reading.total)) your IDs are read from: \(reading.done.formatted()) done.") {
                Button("Stop") { model.stopReading() }
                    .controlSize(.small)
            }
        } else if model.needsReadAgain, model.reading == nil {
            readingBanner("This version reads documents better. Refresh reads again the \(Self.documents(model.refreshSources.count)) your IDs are read from; your choices are kept.") {
                Button {
                    read(.refresh())
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                .controlSize(.small)
            }
        } else if model.needsDiscover, model.reading == nil {
            readingBanner(Self.discoverBanner(copiesChanged: model.copiesChanged)) {
                Button {
                    read(.discover)
                } label: {
                    Label("Discover More", systemImage: "doc.text.viewfinder")
                }
                .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                .controlSize(.small)
                Button("Not Now") { model.dismissDiscover() }
                    .controlSize(.small)
            }
        }
    }

    private func readingBanner(_ text: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(glassHue.accentColor)
            Text(text)
                .scaledFont(.subheadline)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(glassHue.accentColor.opacity(0.1)))
    }

    /// Whether this tab has numbers the three choices hide.
    private var hiddenByChoices: Bool {
        model.query.isEmpty && model.count(in: model.tab) == 0 && model.rows.contains { $0.standing.tab == model.tab }
    }

    private var emptyTitle: String { model.query.isEmpty ? "Nothing here" : "No IDs match" }
    private var emptyMessage: String {
        model.query.isEmpty ? "IDs that belong here appear after Discover More, or when you add one."
            : "Search looks at names, notes and kinds in every tab, never at the IDs themselves."
    }

    /// One number: whose, what it is, its ending, and badges for what needs noticing.
    private func rowView(_ row: VaultModel.Row, underPerson: Bool = false, onColor: Bool = false) -> some View {
        let isSelected = model.selection == row.id
        let title = underPerson ? row.kindTitle : row.listTitle
        // Worked out here, drawn by a label that is skipped while these stay the same.
        let lead: VaultRowLabel.Lead = underPerson
            ? .kind(symbol: model.kinds.symbol(of: row.card), ink: model.tint(of: row.card)?.color ?? glassHue.accentColor)
            : .initials(initials(row))
        let label = VaultRowLabel(lead: lead, title: title,
                                  countryCode: model.geoFilter == .all && model.spansCountries ? row.geo.code : nil,
                                  subtitle: row.listSubtitle(now: model.now), masked: model.masked(row),
                                  badges: badges(row), isChosen: isSelected, onColor: onColor)
        // The badges the eye sees that the row's own words leave out: news from a refresh, and
        // how soon it runs out.
        let heard = label.badges.map(\.text).filter { $0 == "Updated" || $0.hasPrefix("Expires") }
        return VaultRow(row: row, label: label, spoken: row.spoken(title: title, also: heard), people: people, model: model,
                        select: { model.selection = row.id; editing = nil },
                        menu: { rowMenu($0) })
            .equatable()
    }

    /// Chooses the ID a fact was read from, on whichever tab it is and past any filter or search.
    private func openSource(_ row: VaultModel.Row) {
        model.query = ""
        model.reveal(row.id)
        editing = nil
    }

    /// "From Passport", or "From 18 IDs": one line, as every fact's source is. The document's
    /// name, which tells two IDs of one kind apart, is in the link's tip (``sourceHelp(_:)``).
    static func sourceLabel(_ rows: [VaultModel.Row]) -> String {
        VaultPersonText.sourceLine(rows)
    }

    /// One ID in the list of several: what it is, and that it is on the other tab when it is.
    static func sourceLine(_ row: VaultModel.Row) -> String {
        row.standing.tab == .archive ? "\(row.kindTitle) (Archive)" : row.kindTitle
    }

    /// The link's tip: the document by name, and what choosing the ID is for.
    static func sourceHelp(_ row: VaultModel.Row, shown: Bool) -> String {
        let file = fileName(row, shown: shown)
        return "\(file.map { "Read from “\($0)”. " } ?? "")Choose this ID to see its document, give it to someone else with Belongs to, or remove it."
    }


    private func badges(_ row: VaultModel.Row) -> [VaultRowLabel.Badge] {
        var badges: [VaultRowLabel.Badge] = []
        // What the last refresh did to it, while that is news.
        if model.changes[row.id] != nil { badges.append(.init(text: "Updated", tint: glassHue.accentColor)) }
        if row.documentMissing { badges.append(.init(text: "File not found", tint: .secondary)) }
        if row.standing.inUse { badges.append(.init(text: "In use", tint: SemanticColor.info)) }
        if row.standing.expired {
            badges.append(.init(text: "Expired", tint: SemanticColor.error))
        } else if row.standing.tab == .current, let soon = Self.expiresSoon(row.facts?.validUntil, now: model.now) {
            badges.append(.init(text: soon, tint: SemanticColor.warning))
        }
        if row.standing.pending { badges.append(.init(text: "Pending", tint: glassHue.accentColor)) }
        // Marks are for what needs noticing: a saved ID is the usual case and carries none.
        if !row.isSaved, row.standing.tab != .archive {
            badges.append(.init(text: "To confirm", tint: glassHue.accentColor))
        }
        return badges
    }

    /// How soon a document runs out, while that is within half a year: many countries want a
    /// passport good for six months past a trip, and a renewal takes weeks. Nil further off, or
    /// once it has run out (Expired says that).
    static func expiresSoon(_ until: Date?, now: Date) -> String? {
        guard let until else { return nil }
        let days = VaultReading.daysLeft(until, now: now)
        guard days >= 0, days <= 182 else { return nil }
        switch days {
        case 0: return "Expires today"
        case 1: return "Expires tomorrow"
        default: return "Expires in \(days) days"
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: VaultModel.Row) -> some View {
        Button("Copy") { copy(row.id) }
        if let path = row.documents.first?.path {
            // Chosen first: the preview follows, and closes with, the chosen row.
            Button("Quick Look") {
                model.selection = row.id
                quickLook(path, for: row)
            }
            Button("Reveal in Browse") { reveal(path, for: row) }
        }
        Divider()
        belongsToMenu(row)
        if VaultKinds.canChange(from: row.readAs) { kindMenu(row) }
        Divider()
        // The pane's answers, flat: a submenu would hide them again.
        if row.isSaved {
            if let entry = model.entry(id: row.id) {
                Button("Edit…") { model.selection = row.id; startEditing(entry) }
            }
        } else if let find = model.find(id: row.id) {
            Button("Add to Vault…") { model.selection = row.id; startConfirming(find) }
            Button("Correct the ID…") { model.selection = row.id; startConfirming(find, correcting: true) }
            if model.mergeSuggestion(for: row.id) != nil {
                Button("Merge…") { model.selection = row.id; startMerging(row.id) }
            }
        }
        // A menu is verbs: the tab to move it to. The pane's Tab row shows where it is instead.
        if row.standing.tab != .other {
            Divider()
            if row.standing.tab == .archive {
                Button("Move to Current") { move(row, to: .current) }
            } else {
                Button("Move to Archive") { move(row, to: .archive) }
            }
            if row.pin != nil { Button("Let the Vault Choose") { move(row, to: nil) } }
        }
        Divider()
        if row.isSaved {
            if let entry = model.entry(id: row.id) {
                Button("Remove…", role: .destructive) { removing = .entry(entry) }
            }
        } else if let find = model.find(id: row.id) {
            Button("Not an ID…", role: .destructive) { removing = .find(find) }
        }
    }

    /// Belongs To: a person in the household, the household itself, or back to the document's
    /// name. A tick marks the current choice.
    private func belongsToMenu(_ row: VaultModel.Row) -> some View {
        // The document's name, when it names someone and no one is chosen, and how many in People
        // it could be.
        let named: (holder: String, matches: Int)? = {
            guard !row.isHousehold, row.personID == nil, let holder = row.facts?.holder else { return nil }
            return (holder, PersonRegistry(people: people).detect(in: holder).count)
        }()
        return Menu {
            ForEach(people) { person in
                Button {
                    model.assign(row.id, to: .person(person.id))
                } label: {
                    if row.personID == person.id && !row.isHousehold {
                        Label(person.displayName, systemImage: "checkmark")
                    } else {
                        Text(person.displayName)
                    }
                }
            }
            Divider()
            Button {
                model.assign(row.id, to: .household)
            } label: {
                if row.isHousehold { Label("Household", systemImage: "checkmark") } else { Text("Household") }
            }
            if let named, named.matches == 0 {
                Divider()
                Button("Add “\(named.holder)” to People") {
                    if let person = addPerson(named: named.holder) { model.assign(row.id, to: .person(person.id)) }
                }
            }
            if row.assignment != nil, row.facts?.holder != nil {
                Divider()
                Button("As the Document Says") { model.assign(row.id, to: nil) }
            }
        } label: {
            // A name read from the document that matches nobody in People says so, rather than
            // passing for a person of the household.
            if let named {
                Text(named.matches > 1 ? "\(named.holder) · Choose Who" : "\(named.holder) · Not in People")
            } else {
                Text(row.isHousehold ? "Household" : row.whose)
            }
        }
    }

    /// Kind: the card an account goes on. The app's account kinds, the household's own, and New
    /// Kind…; As Read puts it back, and a folder's lesson can be forgotten here. Never offered for
    /// a passport, a visa or another ID its reader checked (``VaultKinds/changeable``).
    private func kindMenu(_ row: VaultModel.Row) -> some View {
        Menu {
            ForEach(model.kinds.targets, id: \.key) { card in
                Button {
                    model.setKind(row.id, to: card)
                } label: {
                    if row.card == card {
                        Label(model.kinds.title(of: card), systemImage: "checkmark")
                    } else {
                        Text(model.kinds.title(of: card))
                    }
                }
            }
            Divider()
            Button("New Kind…") {
                newKindName = ""
                namingKindFor = row.id
            }
            if row.card != .builtIn(row.readAs) {
                Divider()
                Button("\(row.isTypedIn ? "As Typed" : "As Read"): \(row.readAs.title)") { model.setKind(row.id, to: nil) }
            }
            if let folder = row.learnedFrom {
                // Masked even while shown: a menu is a window of its own, which screen sharing sees.
                Button("Forget What “\(row.lessonFolderName(folder, shown: false))” Taught") {
                    model.forgetLesson(folder)
                }
            }
        } label: {
            Text(model.kinds.title(of: row.card))
        }
    }

    /// A label in the details' first column: Belongs to, Kind, Used in, Tab.
    private func fieldLabel(_ text: String, help: String) -> some View {
        Text(text)
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
            .help(help)
    }

    /// The detail's Kind: the card it is on, and how it got there when not as read. Before the
    /// kind's name, a dot in its card's color, which opens the card's Color choice.
    private func kindRow(_ row: VaultModel.Row) -> some View {
        let help = VaultKinds.canChange(from: row.readAs)
            ? "The card this ID is on. Moving one read from an account’s folder moves that folder’s other IDs too, now and on later reads."
            : row.isTypedIn ? "Its kind was chosen when it was typed in; Edit changes it."
            : "Its kind was checked when it was read: it stays on its card."
        return GridRow {
            fieldLabel("Kind", help: help)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // Not on Other Finds, whose kinds have no card on the main view.
                    if row.standing.tab != .other { cardColorDot(row.card) }
                    Group {
                        if VaultKinds.canChange(from: row.readAs) {
                            kindMenu(row)
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                        } else {
                            Text(row.readAs.title)
                                .scaledFont(.callout)
                        }
                    }
                    .help(help)
                }
                if let note = row.kindNote(shown: model.lock.canShow(row.id, at: model.now)) {
                    Text(note)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The card's color as a dot, as a Finder tag shows one; an empty ring for a card with none.
    /// A shape, not a swatch image, so it follows a change of appearance (VT78).
    private func cardColorDot(_ card: VaultCardID) -> some View {
        let tint = model.tint(of: card)
        let title = model.kinds.title(of: card)
        return Button {
            coloring = .detail(card)
        } label: {
            Group {
                if let tint {
                    Circle().fill(tint.color)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                } else {
                    Circle().strokeBorder(.tertiary, lineWidth: 1)
                }
            }
            .frame(width: 10, height: 10)
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: isColoring(.detail(card)), arrowEdge: .bottom) { colorPopover(for: card, at: .detail(card)).presentedNativeControlAccent() }
        .help("The color of the \(title) card, and of its group. Click to change it.")
        .accessibilityLabel("Color of the \(title) card")
        .accessibilityValue(tint?.title ?? "No Color")
    }


    /// Used In: where the number is used, and how that is known. A choice wins over the document,
    /// and later reads keep it.
    private func usedIn(_ row: VaultModel.Row) -> some View {
        let help = "Where this ID is used. Every Country shows it in each country’s view, as a passport is."
        return GridRow {
            fieldLabel("Used in", help: help)
            VStack(alignment: .leading, spacing: 1) {
                Menu {
                    ForEach(VaultGeo.allCases, id: \.self) { geo in
                        Button {
                            model.setGeo(row.id, to: geo)
                        } label: {
                            if row.geo == geo { Label(geo.title, systemImage: "checkmark") } else { Text(geo.title) }
                        }
                    }
                    if row.chosenGeo != nil {
                        Divider()
                        Button(row.isTypedIn ? "Every Country Again" : "As the Document Says") { model.setGeo(row.id, to: nil) }
                    }
                } label: {
                    Text(row.geo.title)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text(row.geoReason)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(help)
        }
    }

    /// Tab: Current or Archive, as a fact about the ID beside whose it is and where it is used,
    /// with the reason the Vault already writes, or You moved it here for a choice either way.
    /// Let the Vault Choose comes back only after a choice. Other Finds is not chosen: plain text.
    private func tabRow(_ row: VaultModel.Row) -> some View {
        let help = row.standing.tab == .other
            ? "Other Finds holds kinds that have no card on the main view yet."
            : "Current shows the newest ID of each kind for each person; Archive keeps the older ones. A choice here wins, and later reads keep it."
        return GridRow {
            fieldLabel("Tab", help: help)
            Group {
                if row.standing.tab == .other {
                    Text("Other Finds")
                        .scaledFont(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Menu {
                            ForEach([VaultStanding.Tab.current, .archive], id: \.self) { tab in
                                Button {
                                    if row.standing.tab != tab { move(row, to: tab) }
                                } label: {
                                    if row.standing.tab == tab { Label(Self.tabTitle(tab), systemImage: "checkmark") } else { Text(Self.tabTitle(tab)) }
                                }
                            }
                            if row.pin != nil {
                                Divider()
                                Button("Let the Vault Choose") { move(row, to: nil) }
                            }
                        } label: {
                            Text(Self.tabTitle(row.standing.tab))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        if let reason = Self.tabReason(row.standing) {
                            Text(reason)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .help(help)
        }
    }

    static func tabTitle(_ tab: VaultStanding.Tab) -> String {
        switch tab {
        case .current: return "Current"
        case .archive: return "Archive"
        case .other: return "Other Finds"
        }
    }

    /// Why an ID is in its tab: the Vault's reason, never one for Current by its own choice.
    static func tabReason(_ standing: VaultStanding) -> String? {
        standing.reason ?? (standing.tab == .archive ? "Older, kept for reference" : nil)
    }

    /// Moves an ID to `tab`, or back to the Vault's choice with nil. When that takes it out of the
    /// list, the selection moves on (``VaultModel/pin(_:_:)``) and the next ID says where it went.
    private func move(_ row: VaultModel.Row, to tab: VaultStanding.Tab?) {
        let was = row.pin
        model.pin(row.id, tab.map { $0 == .archive ? VaultPin.older : .current })
        guard let now = model.rows.first(where: { $0.id == row.id }), model.selection != row.id else {
            moved = nil
            return
        }
        moved = MovedNote(id: row.id, title: row.title, tab: Self.tabTitle(now.standing.tab), pin: was,
                          shownOn: model.selection)
    }

    /// Adds the person a document names to People: shown by their first name, matched by the full
    /// name as printed. The Vault knows them at once; the window's list follows.
    private func addPerson(named holder: String) -> Person? {
        let first = holder.split(separator: " ").first.map(String.init) ?? holder
        guard let person = onAddPerson(first, holder) else { return nil }
        model.people = model.people + [person]
        return person
    }

    /// Add to Vault, once the question about People is answered.
    private func finishConfirming() {
        guard case .confirming(let id) = editing else { return }
        if model.confirm(id, as: draft) != nil { editing = nil }
    }

    /// The editor's Kind. Typed in, an app kind is what the number is. Read from a document, an
    /// account moved to another account kind keeps what it was read as and goes on that card, as
    /// the Kind menu does; a checked ID's kind is as before. A household kind is offered only for
    /// an account (the picker leaves it out otherwise), and is a card it goes on.
    private var draftCard: Binding<VaultCardID> {
        Binding(get: { draft.card.flatMap { model.kinds.canHold($0) ? $0 : nil } ?? .builtIn(draft.category) },
                set: { card in
                    switch card {
                    case .builtIn(let category):
                        if draft.facts != nil, VaultKinds.canChange(from: draft.category), VaultKinds.canChange(from: category) {
                            draft.card = category == draft.category ? nil : card
                        } else {
                            draft.category = category
                            draft.card = nil
                        }
                    case .custom:
                        guard VaultKinds.canChange(from: draft.category) else { return }
                        draft.card = card
                    }
                })
    }


    private var draftBelongsTo: Binding<String> {
        Binding(get: { VaultAssignment.tag(draft.assignment) }, set: { tag in
            if tag == "household" {
                draft.personID = nil
                draft.isHousehold = true
            } else if tag.hasPrefix("person:") {
                draft.personID = String(tag.dropFirst("person:".count))
                draft.isHousehold = false
            } else {
                draft.personID = nil
                draft.isHousehold = false
            }
        })
    }

    private func initials(_ row: VaultModel.Row) -> String {
        if row.isHousehold { return "⌂" }
        return String(row.whose.prefix(1)).uppercased()
    }



    // MARK: The chosen number

    @ViewBuilder
    private var side: some View {
        if editing != nil {
            editor
        } else if let item = chosenContact {
            contactDetail(item)
        } else if let row = model.selectedRow {
            detail(row)
        } else {
            EmptyStateView(icon: "number", title: "No ID chosen", layout: .compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ row: VaultModel.Row) -> some View {
        let shown = model.lock.canShow(row.id, at: model.now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // The document the number was read from, at a glance. A typed-in number has none.
                if let path = row.documents.first?.path {
                    VaultDocumentPreview(path: path, shown: shown, keep: VaultMask.keep(for: row.category)) {
                        if shown { toggleQuickLook() } else { Task { await model.show(row.id) } }
                    }
                    // A fresh preview for each number, so nothing of one number's scan is drawn
                    // under another's name.
                    .id(row.id)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.kindTitle)
                        .scaledFont(.title3.weight(.semibold))
                    Text(row.detailLede)
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // A name corrected with Edit: what the document was read as stays in sight.
                    if let read = row.readHolder {
                        Text("Read as “\(read)”")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Whose it is, its kind, where it is used and its tab: labels in one column and
                // values in the next, so the values start at one edge.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 12) {
                    GridRow {
                        let help = "Whose this ID is. A choice here wins over the name on the document, and later reads keep it."
                        fieldLabel("Belongs to", help: help)
                        belongsToMenu(row)
                            .menuStyle(.borderlessButton)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240, alignment: .leading)
                            .help(help)
                    }
                    kindRow(row)
                    usedIn(row)
                    tabRow(row)
                }
                if row.standing.inUse {
                    callout("Still in use: a visa that is still good is in this passport, so carry it with the new one.",
                            tint: SemanticColor.info)
                } else if row.standing.expired, row.standing.tab == .current, model.reading == nil {
                    callout("Expired, and the newest of its kind read for \(row.whose). It stays here until a newer one is read.",
                            tint: SemanticColor.warning)
                }
                if let note = row.zoneNote { callout(note, tint: SemanticColor.warning) }
                refreshNotes(row, shown: shown)
                numberBox(row, shown: shown)
                actionBar(row)
                mergeLine(for: row)
                movedNote(for: row)
                correctionNote(for: row)
                if let facts = row.facts, !facts.details.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        ForEach(Array(facts.details.enumerated()), id: \.offset) { index, detail in
                            detailRow(detail, at: index, of: row, shown: shown)
                        }
                    }
                } else if row.isTypedIn {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        if !row.note.isEmpty { factRow("Note", row.note) }
                    }
                }
                if row.isSaved, !row.isTypedIn { moreFields(row, shown: shown) }
                if row.isTypedIn {
                    Text("Typed in by hand.")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    documentsList(row, shown: shown)
                }
                olderLink(row)
                noticeText
            }
            .padding(VaultCardSize.detailPadding)
        }
    }

    /// Another ID on the card, locked: as its row hides it, so a Social Security number shows no
    /// ending (VT34).
    static func lockedOnCard(_ value: String, as category: VaultCategory?) -> String {
        category.map { VaultMask.described(value, as: $0) } ?? VaultMask.masked(value)
    }

    /// What a refresh read for a saved ID that differs from it. Hidden as the saved ID's row hides
    /// it: a Social Security number, saved or read as one, shows no ending (VT34).
    static func readsDifferently(_ value: String, saved: VaultCategory, read: VaultCategory) -> String {
        let shown = VaultMask.described(value, as: saved.hidesEnding ? saved : read)
        return "Its document reads differently now: \(shown). Your saved ID has not been changed."
    }

    /// What the last refresh found about this ID: what reads differently now, a document that
    /// reads as another number (asked about, never taken), and a document that is not where it was.
    @ViewBuilder
    private func refreshNotes(_ row: VaultModel.Row, shown: Bool) -> some View {
        if let changed = model.changes[row.id] {
            VStack(alignment: .leading, spacing: 3) {
                Text("Changed by Refresh")
                    .scaledFont(.callout.weight(.semibold))
                ForEach(Array(changed.enumerated()), id: \.offset) { _, change in
                    Text(Self.changeLine(change, shown: shown))
                        .scaledFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(glassHue.accentColor.opacity(0.12)))
        }
        if row.isSaved, let other = model.rereads[row.id], let find = model.find(id: other) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.readsDifferently(find.value, saved: row.category, read: find.category))
                    .scaledFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Keep Mine") { model.keepSaved(row.id) }
                        .help("Sets the other reading aside; it is not offered again.")
                    Button("Use the New Reading") { Task { await model.useReread(row.id) } }
                        .help("Changes the saved ID to the number its document reads now, after Touch ID.")
                }
                .controlSize(.small)
                .disabled(model.isAsking)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(SemanticColor.warning.opacity(0.14)))
        }
        if row.documentMissing {
            callout("Its document is not where it was. The ID is kept, and Discover More finds a moved document again.",
                    tint: Color.secondary)
        }
    }

    /// "Valid until: 14 Mar 2027 → 14 Mar 2031", or for a detail read for the first time
    /// "Issued: 12 Nov 2026 (new)". A number in it shows only its ending unless the ID is shown.
    static func changeLine(_ change: VaultChange, shown: Bool) -> String {
        guard let was = change.was else { return "\(change.label): \(change.now.drawn(shown: shown)) (new)" }
        return "\(change.label): \(was.drawn(shown: shown)) → \(change.now.drawn(shown: shown))"
    }


    private func callout(_ text: String, tint: Color) -> some View {
        Text(text)
            .scaledFont(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(tint.opacity(0.14)))
    }

    /// The number, with its own Copy once it may be shown; while locked, the way to show it.
    private func numberBox(_ row: VaultModel.Row, shown: Bool) -> some View {
        HStack(spacing: 8) {
            Text(shown ? row.value : model.masked(row))
                .scaledFont(.title2.monospaced().weight(.semibold))
                .foregroundStyle(shown ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Not selectable: ⌘C on selected text would put the number on the clipboard
                // plainly, never concealed nor cleared. Copy and Large Type are the ways out.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(shown ? "The ID" : "The ID, hidden")
                .accessibilityValue(VaultMask.spoken(row.value, shown: shown, hidesEnding: row.category.hidesEnding))
            Spacer(minLength: 4)
            // Large Type beside the number, for reading it out on a call; behind Touch ID while
            // the number is hidden, as Show is.
            Button {
                showLargeType(row.id)
            } label: {
                Image(systemName: "textformat.size")
            }
            .help("Large Type: the ID big, grouped as its document prints it, with its details, for reading it out")
            .accessibilityLabel("Large Type")
            if shown {
                Button {
                    copy(row.id)
                } label: {
                    Label(copied == row.id ? "Copied" : "Copy", systemImage: copied == row.id ? "checkmark" : "doc.on.doc")
                }
                .help("Copies the ID. \(Self.clipboardClears)")
            } else {
                Button {
                    Task { await model.show(row.id) }
                } label: {
                    Label("Show", systemImage: "touchid")
                }
                .help("Shows the ID after Touch ID.")
            }
        }
        .disabled(model.isAsking)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.well).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: Radius.well).strokeBorder(.quaternary))
    }

    /// An ID To confirm has its answers to "is this right?" (`VaultAnswers`). A saved ID has Edit…
    /// alone; Remove… is in the editor, and the tab is the Tab row.
    private func actionBar(_ row: VaultModel.Row) -> some View {
        HStack(spacing: 6) {
            if row.isSaved {
                if let entry = model.entry(id: row.id) {
                    Button("Edit…") { startEditing(entry) }
                }
            } else if let find = model.find(id: row.id) {
                VaultAnswers(hue: glassHue,
                             add: { startConfirming(find) },
                             correct: { startConfirming(find, correcting: true) },
                             notAnID: { removing = .find(find) })
            }
        }
        .disabled(model.isAsking)
    }

    /// Where the ID just moved went, with Undo, on the ID the selection moved on to.
    @ViewBuilder
    private func movedNote(for row: VaultModel.Row) -> some View {
        if let note = moved, note.shownOn == row.id {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SemanticColor.success)
                // Its ending as it may be drawn now, not when it moved: a hidden ending (an SSN's)
                // shown for its thirty seconds is hidden again once they end.
                let ending = model.rows.first { $0.id == note.id }.map(model.masked) ?? ""
                Text("\(note.title) \(ending) moved to \(note.tab).")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Undo") {
                    model.pin(note.id, note.pin)
                    model.reveal(note.id)
                    moved = nil
                }
                .buttonStyle(.link)
            }
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// "Corrected one character of what Aetna card.pdf reads." with Undo, under the ID just fixed.
    @ViewBuilder
    private func correctionNote(for row: VaultModel.Row) -> some View {
        if let corrected = model.lastCorrection, corrected.id == row.id, editing == nil {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SemanticColor.success)
                Text(Self.correctionLine(corrected, keep: VaultMask.keep(for: row.category)))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Undo") { model.undoCorrection() }
                    .buttonStyle(.link)
                    .help("Puts the ID back as it was read")
            }
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// The document is named as the documents list names it while hidden: the note stays up after
    /// the number hides again, so a number in the file's name never shows in it.
    static func correctionLine(_ corrected: VaultModel.Correction, keep: Int = 4) -> String {
        let corrected = VaultModel.Correction(id: corrected.id, file: corrected.file.map { VaultMask.fileName($0, keep: keep) },
                                              changed: corrected.changed, merged: corrected.merged)
        if corrected.merged {
            return corrected.file.map { "Merged the reading from \($0) into this ID." } ?? "Merged a reading into this ID."
        }
        guard let file = corrected.file else { return "Corrected the ID as it was read." }
        switch corrected.changed {
        case 1?: return "Corrected one character of what \(file) reads."
        case let count? where count > 1: return "Corrected \(count) characters of what \(file) reads."
        default: return "Corrected what \(file) reads."
        }
    }

    /// What Not an ID… asks. A card printing the number as its subscriber's is most likely the
    /// subscriber's real ID: setting it aside would hide it from every file.
    static func notAnIDMessage(printedForSubscriber: Bool) -> String {
        let aside = "It comes off the Vault and isn’t offered again, from any file. Settings ▸ Vault ▸ Read can forget the IDs set aside."
        guard printedForSubscriber else { return aside }
        return "The card prints this as the subscriber’s ID, so it is most likely the subscriber’s real ID. "
            + "Belongs to gives it to them, and Correct the ID… fixes a misreading. " + aside
    }

    /// More fields on the card a saved ID is read from: folded until opened, which reads the card;
    /// each value its details don't show yet with Add and an X that dismisses it for good (Show
    /// N Dismissed brings them back), and Add a Field… for one typed in.
    @ViewBuilder
    private func moreFields(_ row: VaultModel.Row, shown: Bool) -> some View {
        let open = moreFieldsRead?.id == row.id
        let file = row.documents.first.map { ($0.path as NSString).lastPathComponent }
        // Masked as the documents list masks it while hidden (VT34).
        let named = file.map { shown ? $0 : VaultMask.fileName($0, keep: VaultMask.keep(for: row.category)) }
        VStack(alignment: .leading, spacing: 6) {
            if let named {
                Button {
                    if open { moreFieldsRead = nil } else { readMoreFields(row) }
                } label: {
                    Label("More Fields on \(named)",
                          systemImage: open ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if open, let read = moreFieldsRead {
                switch read.result {
                case nil:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the card…")
                    }
                    .foregroundStyle(.secondary)
                case .notFound?:
                    Text("The card isn’t where the Vault last saw it. Discover More finds a card that moved.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .unreadable?:
                    Text("Nothing could be read from the card.")
                        .foregroundStyle(.secondary)
                case .read(let values)?:
                    let offered = model.moreFields(values, for: row.id)
                    let dismissed = model.dismissedFields(values, for: row.id)
                    if offered.isEmpty {
                        Text(dismissed > 0 ? "Nothing else on this card to add." : "Every field on this card is in the details.")
                            .foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                            ForEach(offered, id: \.self) { value in
                                GridRow {
                                    Text(value.label).foregroundStyle(.secondary)
                                    Text(VaultDetail(value.label, VaultModel.fieldValue(label: value.label, value: value.value))
                                        .drawn(shown: shown))
                                    Button("Add") { Task { await model.addField(row.id, label: value.label, value: value.value) } }
                                        .buttonStyle(.link)
                                        .help("Adds this field to the ID’s details")
                                    Button {
                                        model.dismissField(row.id, value: value.value)
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("Not a field: it isn’t offered again for this ID")
                                    .accessibilityLabel("Not a Field")
                                }
                            }
                        }
                    }
                    if dismissed > 0 {
                        Button(Self.showDismissedTitle(dismissed)) { model.restoreDismissedFields(row.id) }
                            .buttonStyle(.link)
                            .help("Offers again the values you said aren’t fields")
                    }
                }
                Button("Add a Field…") {
                    newFieldLabel = ""
                    newFieldValue = ""
                    newFieldHidden = false
                    // The sheet says why its own save was refused, never an earlier action's.
                    model.notice = nil
                    addingFieldTo = row.id
                }
                .buttonStyle(.link)
            }
        }
        .scaledFont(.callout)
    }

    /// The link that offers dismissed values again: "Show 1 Dismissed", "Show 2 Dismissed".
    static func showDismissedTitle(_ count: Int) -> String { "Show \(count) Dismissed" }

    private func readMoreFields(_ row: VaultModel.Row) {
        guard let path = row.documents.first?.path else { return }
        moreFieldsRead = CardRead(path: path, id: row.id, result: nil)
        Task {
            let result = await model.readCard(path, with: VaultFolderReader(folders: model.readFolders))
            guard moreFieldsRead?.id == row.id, moreFieldsRead?.path == path else { return }
            moreFieldsRead?.result = result
        }
    }

    /// Add a Field…: a label and a value typed in, hidden like an ID when ticked.
    private var addFieldSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Field")
                .scaledFont(.headline)
            TextField("Label", text: $newFieldLabel, prompt: Text("Payer ID"))
            TextField("Value", text: $newFieldValue, prompt: Text("60054"))
                .fontDesign(.monospaced)
                .autocorrectionDisabled()
            Toggle("Hide It Like an ID", isOn: $newFieldHidden)
                .toggleStyle(.checkbox)
            // A refused save stays open: why is said here, not behind the sheet.
            noticeText
            HStack {
                Spacer()
                Button("Cancel") { addingFieldTo = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let id = addingFieldTo else { return }
                    let (label, value, hidden) = (newFieldLabel, newFieldValue, newFieldHidden)
                    Task { if await model.addField(id, label: label, value: value, hidden: hidden) { addingFieldTo = nil } }
                }
                .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                .keyboardShortcut(.defaultAction)
                .disabled(newFieldLabel.trimmingCharacters(in: .whitespaces).isEmpty
                          || newFieldValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 360)
    }

    /// "Close to Anna’s saved Dental · Member ID ●●●●2401: 2 characters differ." with Merge…,
    /// under a waiting ID that may be another reading of a saved one.
    @ViewBuilder
    private func mergeLine(for row: VaultModel.Row) -> some View {
        if !row.isSaved, let best = model.mergeSuggestion(for: row.id),
           let saved = model.rows.first(where: { $0.id == best.id }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.mergeLine(title: saved.title, whose: Self.owner(of: saved), ending: model.masked(saved),
                                    differ: best.differ))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Merge…") { startMerging(row.id) }
                    .buttonStyle(.link)
                    .help("Fold this reading into the ID you already have")
            }
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
        }
    }

    static func mergeLine(title: String, whose: String?, ending: String, differ: Int) -> String {
        let owner = whose.map { "\($0)’s saved" } ?? "the saved"
        let apart = differ == 1 ? "one character differs" : "\(differ) characters differ"
        return "Close to \(owner) \(title) \(ending): \(apart)."
    }

    /// Merge…: one proof for every ID the sheet shows in full, then the sheet.
    private func startMerging(_ id: UUID) {
        let candidates = model.mergeCandidates(for: id)
        guard let first = candidates.first, let row = model.rows.first(where: { $0.id == id }) else { return }
        Task {
            guard await model.showTogether([id] + candidates.map(\.id), reason: "merge \(row.title)") else { return }
            mergeInto = first.id
            mergeKeepsReading = false
            model.notice = nil
            mergingFrom = id
        }
    }

    /// The saved IDs a reading could be, closest first, and which number stays.
    private func mergeSheet(_ findID: UUID) -> some View {
        let find = model.rows.first { $0.id == findID }
        let candidates = model.mergeCandidates(for: findID)
        let into = candidates.first { $0.id == mergeInto }.flatMap { c in model.rows.first { $0.id == c.id } }
        let file = find?.documents.first.map { ($0.path as NSString).lastPathComponent } ?? "its document"
        let shown = ([findID] + candidates.map(\.id)).allSatisfy { id in model.rows.first { $0.id == id }.map { model.canShow(row: $0) } ?? false }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(find?.title ?? "") \(find?.value ?? "")")
                .scaledFont(.headline)
            Text("With \(into.flatMap(Self.owner(of:)).map { "\($0)’s" } ?? "the") saved IDs of this kind, closest first")
                .foregroundStyle(.secondary)
            Picker("Into", selection: $mergeInto) {
                ForEach(candidates) { candidate in
                    if let saved = model.rows.first(where: { $0.id == candidate.id }) {
                        Text("\(saved.value)  \(saved.title) · \(candidate.differ == 1 ? "1 differs" : "\(candidate.differ) differ")")
                            .tag(Optional(candidate.id))
                    }
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Keep which ID?")
                .scaledFont(.headline)
            Picker("Keep", selection: $mergeKeepsReading) {
                Text("\(into?.value ?? "")  The saved one").tag(false)
                Text("\(find?.value ?? "")  This reading, from \(file)").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("The reading’s files join the saved ID, which keeps its own Read from file. The number not kept is remembered for the files that print it, and nothing is set aside.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            noticeText
            HStack {
                Spacer()
                Button("Cancel") { mergingFrom = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    if let into = mergeInto, model.merge(findID, into: into, keepingReading: mergeKeepsReading) {
                        mergingFrom = nil
                    }
                }
                .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                .keyboardShortcut(.defaultAction)
                .disabled(mergeInto == nil)
            }
        }
        .fontDesign(.default)
        .padding(20)
        .frame(width: 460)
        // Shown in full only while the lock allows: a lock, or the thirty seconds running out,
        // closes it with nothing changed.
        .onChange(of: shown) { _, now in if !now { mergingFrom = nil } }
    }

    /// "This is Henrik’s Aetna · Member ID, already in the Vault. It can’t be added as Sigrid’s
    /// too.": an ID the editor will not add again. `whose` is the saved one's person, `other`
    /// the editor's when that is someone else.
    static func alreadySavedLine(title: String, whose: String?, as other: String?) -> String {
        let owner = whose.map { "\($0)’s \(title)" } ?? title
        guard let other else { return "This ID is already in the Vault: \(owner)." }
        return "This is \(owner), already in the Vault. It can’t be added as \(other)’s too."
    }

    /// A detail with its own Copy. A date copies as MM/DD/YYYY; a detail that is a number copies
    /// as the number does, after Touch ID, cleared from the clipboard after a minute.
    private func detailRow(_ detail: VaultDetail, at index: Int, of row: VaultModel.Row, shown: Bool) -> some View {
        GridRow {
            Text(detail.label)
                .foregroundStyle(.secondary)
            Text(detail.drawn(shown: shown))
                .fixedSize(horizontal: false, vertical: true)
            // Large Type with this detail lit, the ID above it; drawn quietly, so the details are
            // not a column of icons.
            Button {
                showLargeType(row.id, line: index)
            } label: {
                Image(systemName: "textformat.size")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .controlSize(.small)
            .disabled(model.isAsking)
            .help("Large Type: \(detail.label) big, with the ID above it")
            .accessibilityLabel("Large Type for \(detail.label)")
            Button(copiedDetail == "\(row.id)\(detail.label)" ? "Copied" : "Copy") {
                copyDetail(detail, of: row)
            }
            .controlSize(.small)
            .help(detail.isNumber ? "Copies it in full, after Touch ID. \(Self.clipboardClears)"
                  : detail.copied == detail.drawn(shown: true) ? "Copies “\(detail.copied)”."
                  : "Copies \(detail.copied), the way US forms ask for a date.")
        }
        .scaledFont(.callout)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .scaledFont(.callout)
    }

    /// Every document carrying the number, the one it was read from first: its part, its name
    /// (Quick Look) and its folder, with Reveal in Browse. While hidden, names and folders have
    /// any number in them cut to its ending.
    private func documentsList(_ row: VaultModel.Row, shown: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Documents with this ID")
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Refresh") { read(.refresh(only: row.id)) }
                    .buttonStyle(.link)
                    .scaledFont(.subheadline)
                    .disabled(model.reading != nil)
                    .help("Reads this ID’s documents again")
            }
            let documents = Array(row.documents.enumerated())
            let listed = allDocumentsShown == row.id ? documents : Array(documents.prefix(Self.documentsShown))
            ForEach(listed, id: \.element.path) { index, source in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Another person's card names the ID and never speaks for it: say whose it is.
                        let otherHolder = index == 0 ? nil : model.otherHolder(of: source.path, for: row)
                        Pill(.mini, tint: index == 0 ? SemanticColor.success : .secondary,
                             text: index == 0 ? (row.chosenSource == nil ? "Read from" : "Read from · Your Choice")
                                : otherHolder.map { "\($0)’s card · names this ID" } ?? source.role)
                            .help(index == 0 ? source.role
                                  : otherHolder.map { "\(source.role), made out to \($0): it names this ID, and its name and dates aren’t this ID’s" }
                                  ?? "Names this ID")
                        Button {
                            quickLook(source.path, for: row)
                        } label: {
                            Text(shown ? (source.path as NSString).lastPathComponent
                                 : VaultMask.fileName(source.path, keep: VaultMask.keep(for: row.category)))
                                .scaledFont(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("Quick Look")
                        let folder = (source.path as NSString).deletingLastPathComponent
                        Text(Self.shortFolder(shown ? folder : VaultMask.folder(folder, keep: VaultMask.keep(for: row.category))))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            // Masked in its tip even while shown: a tooltip is a window screen sharing sees.
                            .help((VaultMask.folder(folder, keep: VaultMask.keep(for: row.category)) as NSString).abbreviatingWithTildeInPath)
                        if index == 0, row.chosenSource != nil {
                            Button("Let the Vault Choose") { model.readFrom(row.id, copy: nil) }
                                .buttonStyle(.link)
                                .scaledFont(.caption)
                                .help("Reads this ID from the copy the Vault would choose")
                        } else if index > 0, row.sourceChoices.contains(source.path) {
                            Button("Read from This Copy") { model.readFrom(row.id, copy: source.path) }
                                .buttonStyle(.link)
                                .scaledFont(.caption)
                                .help("Another copy of the same document: its name and details are shown, and it opens. The dates stay the same.")
                        } else if index > 0, row.isSaved {
                            Button("Not for This ID") {
                                Task { if await model.notForThisID(row.id, path: source.path) { read(.discover) } }
                            }
                            .buttonStyle(.link)
                            .scaledFont(.caption)
                            .disabled(model.reading != nil)
                            .help("Takes this file off the ID, even after it moves, and reads it again without it: an ID of its own can come up To Confirm")
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        reveal(source.path, for: row)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Browse: its folder opens with the file selected")
                    .accessibilityLabel("Reveal in Browse")
                }
            }
            if documents.count > Self.documentsShown {
                Button(allDocumentsShown == row.id ? "Show Fewer"
                       : "Show All \(documents.count) Documents") {
                    allDocumentsShown = allDocumentsShown == row.id ? nil : row.id
                }
                .buttonStyle(.link)
                .scaledFont(.callout)
            }
        }
    }

    /// "Passport › Anna › Archive": the last three folders, the full path in the tooltip.
    static func shortFolder(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath.split(separator: "/").suffix(3).joined(separator: " › ")
    }

    @ViewBuilder
    private func olderLink(_ row: VaultModel.Row) -> some View {
        let older = model.rows.filter {
            $0.standing.tab == .archive && $0.category == row.category && $0.whose == row.whose && $0.id != row.id
        }
        if row.standing.tab == .current, !older.isEmpty {
            Button("\(older.count) Older in Archive") {
                if let id = older.first?.id { model.reveal(id) }
            }
            .buttonStyle(.link)
            .scaledFont(.callout)
        }
    }

    @ViewBuilder
    private var noticeText: some View {
        if let notice = model.notice {
            Text(notice)
                .scaledFont(.callout)
                .foregroundStyle(SemanticColor.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Editor

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(editorTitle)
                    .scaledFont(.headline)
                field("What it is") {
                    TextField("What it is", text: $draft.title, prompt: Text("Mortgage loan number"))
                }
                field("ID or Account Number") {
                    TextField("ID or Account Number", text: $draft.value)
                        .fontDesign(.monospaced)
                        .autocorrectionDisabled()
                        .focused($valueFocused)
                        // Copy and Cut here go through the Vault's concealed, cleared copy.
                        .onChange(of: valueFocused, initial: true) { _, focused in VaultPasteboard.editingNumber = focused }
                        .onDisappear { VaultPasteboard.editingNumber = false }
                        // No number in it: a tooltip is a window of its own, which screen sharing sees.
                        .help(readValue.map { VaultReading.normalized($0) != VaultReading.normalized(draft.value) } == true
                              ? "The document reads this a little differently. Scans often mix up Z and 2, O and 0, I and 1, B and 8." : "")
                }
                // What its documents were noted to read for it, when its number was corrected.
                if case .existing(let id) = editing, case let readings = model.readings(of: id), !readings.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.readingsLine(readings))
                            .scaledFont(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Forget") { Task { await model.forgetReadings(of: id) } }
                            .buttonStyle(.link)
                            .scaledFont(.callout)
                            .help("The document’s next read offers what it reads To Confirm again")
                    }
                }
                if let saved = alreadySaved {
                    Text(Self.alreadySavedLine(title: saved.title, whose: Self.owner(of: saved),
                                               as: otherPerson(than: saved)))
                        .scaledFont(.callout)
                        .foregroundStyle(SemanticColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let card = cardReading, card.id == editingID {
                    field("On this card") { onThisCard(card) }
                }
                if let read = draft.facts?.holder {
                    field("Name on the Document") {
                        TextField("Name on the Document", text: draftName, prompt: Text(read))
                    }
                    // Shown whenever a correction is in play: one made everywhere, or one typed now.
                    if let id = editingID, draft.correctEverywhere || draftNameChanged(from: read) {
                        let others = model.otherIDs(readAs: read, excluding: id)
                        let label = "Every ID read as “\(read)”" + (others == 0 ? "" : others == 1 ? " (1 more)" : " (\(others) more)")
                            + ", and later reads"
                        // The editor hides its controls' labels, so the words sit beside the box.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Toggle(label, isOn: $draft.correctEverywhere)
                                .toggleStyle(.checkbox)
                            Text(label)
                                .scaledFont(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .onTapGesture { draft.correctEverywhere.toggle() }
                                .accessibilityHidden(true)
                        }
                    }
                }
                field("Belongs to") {
                    Picker("Belongs to", selection: draftBelongsTo) {
                        ForEach(people) { person in
                            Text(person.displayName).tag(VaultAssignment.tag(.person(person.id)))
                        }
                        Divider()
                        Text("Household").tag(VaultAssignment.tag(.household))
                        // A read number may also go by the name on its document.
                        if let holder = draftHolder {
                            Text("As the Document Says (\(holder))").tag(VaultAssignment.tag(nil))
                        }
                    }
                }
                field("Kind") {
                    // The cards: a number typed in goes on its own kind's card.
                    Picker("Kind", selection: draftCard) {
                        ForEach(VaultCategory.typedIn, id: \.self) { category in
                            Text(category.singular).tag(VaultCardID.builtIn(category))
                        }
                        if VaultKinds.canChange(from: draft.category), !model.kinds.custom.isEmpty {
                            Divider()
                            ForEach(model.kinds.custom) { kind in
                                Text(kind.name).tag(VaultCardID.custom(kind.id))
                            }
                        }
                    }
                }
                if case .existing(let id) = editing, let added = model.entry(id: id)?.fields,
                   !added.isEmpty {
                    field("Added Fields") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(added.enumerated()), id: \.offset) { index, detail in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(detail.label).foregroundStyle(.secondary)
                                    Text(detail.drawn(shown: true))
                                    Spacer(minLength: 4)
                                    Button("Remove") { Task { await model.removeField(id, at: index) } }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                        .scaledFont(.callout)
                    }
                }
                field("Note") {
                    TextField("Note", text: $draft.note, prompt: Text("The issuer, or anything else"))
                }
                HStack(spacing: 6) {
                    if case .existing(let id) = editing, let entry = model.entry(id: id) {
                        Button("Remove…", role: .destructive) { removing = .entry(entry) }
                    }
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button(isConfirming ? "Add to Vault" : "Save") { save() }
                        .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.isComplete || model.isAsking || alreadySaved != nil)
                }
                .padding(.top, 4)
                noticeText
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .padding(14)
        }
    }

    private var removalTitle: String {
        switch removing {
        case .entry(let entry): return "Remove “\(entry.title)” from the Vault?"
        case .find(let find): return "Is “\(find.title)” not an ID?"
        case nil: return ""
        }
    }

    /// "Its document reads WZ88319122 for this ID.": what a corrected ID's documents read.
    static func readingsLine(_ readings: [String]) -> String {
        guard let last = readings.last else { return "" }
        if readings.count == 1 { return "Its document reads \(last) for this ID." }
        return "Its documents read \(readings.dropLast().joined(separator: ", ")) and \(last) for this ID."
    }

    /// What reading the editor's card came to, for the ID it is open for.
    struct CardRead: Equatable {
        let path: String
        let id: UUID
        var result: VaultModel.CardReading?
    }

    /// Reads the card `id` was read from, for On this card: kept by the model for the file's size
    /// and date, so opening the editor again reads nothing.
    private func readCardForEditor(_ id: UUID) {
        allCardValuesShown = false
        guard let path = model.rows.first(where: { $0.id == id })?.documents.first?.path else {
            cardReading = nil
            return
        }
        cardReading = CardRead(path: path, id: id, result: nil)
        Task {
            let result = await model.readCard(path, with: VaultFolderReader(folders: model.readFolders))
            guard editingID == id, cardReading?.path == path else { return }
            cardReading?.result = result
        }
    }

    /// The other IDs a card prints, at most ``documentsShown`` until Show All, each with Use.
    @ViewBuilder
    private func onThisCard(_ card: CardRead) -> some View {
        switch card.result {
        case nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading the card…")
            }
            .scaledFont(.callout)
            .foregroundStyle(.secondary)
        case .notFound?:
            Text("The card isn’t where the Vault last saw it. Discover More finds a card that moved.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unreadable?:
            Text("Nothing could be read from the card.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
        case .read(let values)?:
            let others = Self.otherValues(values, excluding: cardExclusions)
            if others.isEmpty {
                Text("No other IDs on this card.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let listed = allCardValuesShown ? others : Array(others.prefix(Self.documentsShown))
                let locked = listed.compactMap { model.lockedRow(holding: $0.value) }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(listed, id: \.self) { value in
                        let lockedID = model.lockedRow(holding: value.value)
                        let hidden = lockedID != nil
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(hidden ? Self.lockedOnCard(value.value, as: model.rows.first { $0.id == lockedID }?.category)
                                 : value.value)
                                .fontDesign(.monospaced)
                            Text("Next to \(value.label)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button("Use") {
                                draft.value = value.value
                                valueFocused = true
                            }
                            .disabled(hidden)
                            .help("Puts this ID in the field above")
                        }
                    }
                    HStack(spacing: 12) {
                        if !locked.isEmpty, let id = editingID {
                            Button("Show") {
                                Task { await model.showTogether([id] + locked, reason: "show the IDs on this card") }
                            }
                            .buttonStyle(.link)
                        }
                        if others.count > Self.documentsShown {
                            Button(allCardValuesShown ? "Show Fewer" : "Show All \(others.count)") {
                                allCardValuesShown.toggle()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .scaledFont(.callout)
            }
        }
    }

    /// The values `values` holds that are none of `excluding`, compared as numbers.
    static func otherValues(_ values: [VaultCardValue], excluding: [String]) -> [VaultCardValue] {
        let left = Set(excluding.map(VaultReading.normalized))
        return values.filter { !left.contains(VaultReading.normalized($0.value)) }
    }

    /// What On this card leaves out: the ID in the field, what was read for it, and for a saved ID
    /// its number and what its documents were noted to read.
    private var cardExclusions: [String] {
        var out = [draft.value]
        if let readValue { out.append(readValue) }
        if case .existing(let id) = editing {
            if let entry = model.entry(id: id) { out.append(entry.value) }
            out += model.readings(of: id)
        }
        return out
    }

    /// The saved ID, other than the one being edited, that already holds the number in the field.
    private var alreadySaved: VaultModel.Row? {
        guard editing != nil else { return nil }
        var own: UUID?
        if case .existing(let id) = editing { own = id }
        return model.savedRow(holding: draft.value, excluding: own)
    }

    /// Whose a saved row is, for a sentence: a person's name, "the household", or nil when unknown.
    static func owner(of row: VaultModel.Row) -> String? {
        if row.isHousehold { return "the household" }
        return row.whose.isEmpty ? nil : row.whose
    }

    /// The editor's person, by name, when it is not `saved`'s.
    private func otherPerson(than saved: VaultModel.Row) -> String? {
        if draft.isHousehold { return saved.isHousehold ? nil : "the household" }
        guard let person = draft.personID, person != saved.personID else { return nil }
        return people.first { $0.id == person }?.displayName
    }

    /// The ID the editor is open for: one saved, or one read and waiting.
    private var editingID: UUID? {
        switch editing {
        case .existing(let id), .confirming(let id): return id
        default: return nil
        }
    }

    /// Edit's Name, as typed: it may be emptied to type afresh. Saved empty, or as read, it goes
    /// by the document again (``VaultModel/prepared(_:)`` opens it with the correction in force).
    private var draftName: Binding<String> {
        Binding(get: { draft.holderName ?? draft.facts?.holder ?? "" }, set: { draft.holderName = $0 })
    }

    /// Whether Name holds something other than what was read: a change of case counts.
    private func draftNameChanged(from read: String) -> Bool {
        guard let typed = draft.holderName?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty else { return false }
        return typed != read
    }

    /// The name the ID goes by once saved: Name as typed, else as read.
    private var draftHolder: String? {
        let typed = draft.holderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.flatMap { $0.isEmpty ? nil : $0 } ?? draft.facts?.holder
    }

    private var isConfirming: Bool {
        if case .confirming = editing { return true }
        return false
    }

    private var editorTitle: String {
        switch editing {
        case .new: return "New ID"
        case .confirming: return "Add a Read ID"
        default: return "Edit ID"
        }
    }

    private func field(_ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .scaledFont(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            control()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Move")
            hint("↩", "Copy")
            hint("Space", "Quick Look")
            hint("⌘⌫", "Remove")
            hint("esc", "Close")
            Spacer()
            if let reading = model.reading {
                ProgressView()
                    .controlSize(.mini)
                Text(Self.progress(reading))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let last = model.lastReading {
                Text(Self.summary(last))
                    .foregroundStyle(.secondary)
            } else if let runs = Self.lastRuns(refreshed: model.lastRefreshed, discovered: model.lastDiscovered, now: model.now) {
                Text(runs)
                    .foregroundStyle(.secondary)
            } else {
                Text("Sealed on this Mac. Never sent to Claude.")
                    .foregroundStyle(.secondary)
            }
        }
        .scaledFont(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .scaledFont(.subheadline.monospaced().weight(.semibold))
            Text(what)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Words

    static func documents(_ count: Int) -> String {
        count == 1 ? "1 document" : "\(count.formatted()) documents"
    }

    /// The footer while a read runs.
    static func progress(_ reading: VaultModel.ReadingProgress) -> String {
        if reading.scope.isRefresh {
            return reading.total == 0 ? "Checking your documents…"
                : "Refreshing \(reading.done.formatted()) of \(documents(reading.total))…"
        }
        return reading.total == 0 ? "Finding documents…" : "Reading \(reading.done.formatted()) of \(documents(reading.total))…"
    }

    /// "It clears from the clipboard after 1 minute.", by the setting.
    static var clipboardClears: String { clipboardClears(in: .standard) }
    static func clipboardClears(in defaults: UserDefaults) -> String {
        "It clears from the clipboard after \(VaultSharingSettings.label(seconds: VaultSharingSettings.clipboardSeconds(in: defaults)))."
    }

    /// The line under Discover More in its menu: where it looks.
    static func discoverLine(folders count: Int) -> String {
        count == 0 ? "No folders chosen yet" : "New and changed files in \(folders(count))"
    }

    /// The line under Refresh in its menu: how many documents it reads again.
    static func refreshLine(documents count: Int) -> String {
        count == 0 ? "No ID has been read from a document yet" : "The \(documents(count)) your IDs are read from"
    }

    /// The banner offering Discover More: after a change of rules, or for other documents IDs
    /// were also read from that changed since, which Refresh leaves to it (VT107).
    static func discoverBanner(copiesChanged: Bool) -> String {
        copiesChanged
            ? "Other documents your IDs were also read from have changed. Discover More looks through them, and goes on if you close the Vault."
            : "Your IDs are up to date. The other files in your folders have not been read with this version: Discover More looks through them, and goes on if you close the Vault."
    }

    static func folders(_ count: Int) -> String { count == 1 ? "1 folder" : "\(count.formatted()) folders" }

    /// The footer after a refresh: "Refreshed 212 documents: 2 IDs updated, 1 file not found."
    static func refreshSummary(_ last: VaultModel.ReadingSummary) -> String {
        var parts: [String] = []
        if last.updated > 0 { parts.append(last.updated == 1 ? "1 ID updated" : "\(last.updated.formatted()) IDs updated") }
        if last.newNumbers > 0 { parts.append(newNumbers(last.newNumbers)) }
        if last.gone > 0 { parts.append(last.gone == 1 ? "1 waiting ID no longer read" : "\(last.gone.formatted()) waiting IDs no longer read") }
        if last.missing > 0 { parts.append(last.missing == 1 ? "1 file not found" : "\(last.missing.formatted()) files not found") }
        return "Refreshed \(documents(last.documents)): \(parts.isEmpty ? "nothing changed" : parts.joined(separator: ", "))."
    }

    /// The footer at rest: "Refreshed 5 minutes ago · Discovered 3 days ago". Nil before either.
    static func lastRuns(refreshed: Date?, discovered: Date?, now: Date) -> String? {
        let parts = [refreshed.map { "Refreshed \(ago($0, now: now))" }, discovered.map { "Discovered \(ago($0, now: now))" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How long ago, in words a glance takes in: "just now", "5 minutes ago", "3 hours ago",
    /// "yesterday", "12 days ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) minutes ago" }
        if seconds < 5400 { return "1 hour ago" }
        if seconds < 86_400 { return "\(Int((seconds / 3600).rounded())) hours ago" }
        if seconds < 172_800 { return "yesterday" }
        return "\(Int(seconds / 86_400)) days ago"
    }

    /// The footer after a read: "Read 3 new or changed of 812 documents: 1 new ID to confirm."
    static func summary(_ last: VaultModel.ReadingSummary) -> String {
        if last.scope.isRefresh { return refreshSummary(last) }
        if last.opened == last.documents {
            return "Read \(documents(last.documents)): \(newNumbers(last.newNumbers))."
        }
        if last.opened == 0 {
            return "No new or changed documents among \(last.documents.formatted())."
        }
        return "Read \(last.opened.formatted()) new or changed of \(documents(last.documents)): \(newNumbers(last.newNumbers))."
    }

    static func newNumbers(_ count: Int) -> String {
        switch count {
        case 0: return "nothing new"
        case 1: return "1 new ID to confirm"
        default: return "\(count.formatted()) new IDs to confirm"
        }
    }

    // MARK: Acts




    /// esc and the ✕ undo one thing at a time: an open choice, Large Type, the editor, then the
    /// panel. esc (`clearingSearch`) also clears a typed search before closing; the ✕ says
    /// Close Vault, and does.
    private func escape(clearingSearch: Bool) {
        if choosing != nil {
            choosing = nil
        } else if largeType != nil {
            largeType = nil
        } else if editing != nil {
            editing = nil
        } else if clearingSearch, !model.query.isEmpty {
            model.query = ""
        } else {
            onClose()
        }
    }

    private func startAdding(for person: String? = nil) {
        var blank = VaultModel.Draft()
        // A new number starts with the person it was asked for, or the one the list is filtered to.
        if let person {
            blank.personID = person
        } else if case .person(let id) = model.personFilter { blank.personID = id } else { blank.isHousehold = true }
        draft = blank
        readValue = nil
        cardReading = nil
        editing = .new
    }

    private func startEditing(_ entry: VaultEntry) {
        Task {
            // The editor draws the number in full, so it opens only once that is allowed.
            guard await model.show(entry.id) else { return }
            // As it is now, after the proof: the draft and what a save checks it against are one
            // reading of it (VT112).
            let now = model.entry(id: entry.id) ?? entry
            draft = model.prepared(VaultModel.Draft(now), for: entry.id)
            readValue = nil
            editedFrom = now
            editing = .existing(entry.id)
            if entry.facts != nil { readCardForEditor(entry.id) } else { cardReading = nil }
        }
    }

    private func save() {
        switch editing {
        case .new:
            let sealed = model.isSealedShut
            // With the Vault locked, the key behind Touch ID asks for one touch first (VT31).
            Task {
                guard await model.keyReady("add an ID to the Vault") else { return }
                if model.add(draft) != nil {
                    editing = nil
                    addedWhileLocked = sealed
                }
            }
        case .existing(let id):
            Task {
                if await model.update(id, to: draft, editedFrom: editedFrom) {
                    editing = nil
                } else if model.notice == VaultModel.editedElsewhere {
                    // Told once: a second Save replaces the other copy's change on purpose.
                    editedFrom = model.entry(id: id)
                }
            }
        case .confirming(let id):
            // A name nobody in People answers to: ask whether to add them first, so the number
            // has a person, a filter chip, and Organize knows them too.
            // By the name as corrected, so a misread name is never offered to People.
            if draft.personID == nil, !draft.isHousehold, let holder = draftHolder {
                if let person = VaultModel.person(named: holder, among: people) {
                    draft.personID = person
                } else {
                    askingToAddPerson = holder
                    return
                }
            }
            if model.confirm(id, as: draft) != nil { editing = nil }
        case nil:
            break
        }
    }

    /// The editor, filled from what was read. It draws the number in full, so it opens only once
    /// that is allowed, as Edit does.
    /// `correcting`, for Correct the ID…, puts the cursor in the ID field.
    private func startConfirming(_ find: VaultFind, correcting: Bool = false) {
        Task {
            guard await model.show(find.id) else { return }
            draft = model.confirmationDraft(find)
            readValue = find.value
            editing = .confirming(find.id)
            readCardForEditor(find.id)
            if correcting { DispatchQueue.main.async { valueFocused = true } }
        }
    }

    /// Read Documents, over the folders chosen here or in Settings ▸ Vault: the new and changed
    /// files.
    private func readDocuments() { read(.discover) }

    /// Refresh runs by itself once the Vault has been read (Settings ▸ Vault can turn that off):
    /// it opens only documents IDs were already read from, and of those only the ones that
    /// changed. Never behind the lock: a locked panel has read nothing to refresh.
    private func refreshByItself() {
        guard model.contents == .loaded, !model.isSealedShut else { return }
        model.refreshIfWanted(with: VaultFolderReader(folders: readFolders))
    }

    /// Starts a read of `scope`: the folders (Discover More, Read Everything Again), or only the
    /// document each ID is read from (Refresh).
    private func read(_ scope: VaultReadScope) {
        guard model.reading == nil else { return }
        let folders = reloadReadFolders()
        // Looking for more needs somewhere to look; a refresh reads documents it already knows.
        guard scope.isRefresh || !folders.isEmpty else {
            askingForFolders = true
            return
        }
        // The model runs it, so it carries on when the panel closes.
        model.startReading(with: VaultFolderReader(folders: folders), scope: scope)
    }

    /// Add Folder…: the same list as Settings ▸ Vault ▸ Read.
    private func addFolders() {
        guard let chosen = VaultReadFoldersPanel.choose(message: "Choose the folders that hold your passport scans, I-94s and USCIS notices.")
        else { return }
        model.addReadFolders(chosen)
        reloadReadFolders()
    }

    /// Settings ▸ Vault ▸ Read, read again into the panel's copy: as it opens, before a
    /// read, and after a folder is added or let go here. Settings changes it only with the Vault
    /// closed, since opening Settings puts the Vault away.
    @discardableResult
    private func reloadReadFolders() -> [String] {
        let folders = model.readFolders
        readFolders = folders
        return folders
    }

    /// ⌘⌫: asks about the chosen row, a number or a find.
    private func askToRemoveChosen() {
        if let entry = model.selectedEntry {
            removing = .entry(entry)
        } else if let find = model.selectedFind {
            removing = .find(find)
        }
    }

    /// Removes an entry, from the detail, the editor or a row's menu. The proof, when one is owed,
    /// is the model's.
    private func remove(_ id: UUID) {
        Task {
            guard await model.delete(id) else { return }
            if editing == .existing(id) { editing = nil }
        }
    }

    private func copy(_ id: UUID) {
        Task {
            guard await model.copy(id) else { return }
            Self.flash(id, in: $copied)
        }
    }

    /// Large Type for the ID, with `line` lit: nil for the ID itself, else a detail's index.
    private func showLargeType(_ id: UUID, line: Int? = nil) {
        Task {
            guard await model.show(id) else { return }
            largeType = LargeTypeShown(id: id, line: line)
        }
    }

    /// The details Large Type draws under the ID, in full: it only opens once the ID may be shown.
    static func largeTypeLines(_ row: VaultModel.Row) -> [VaultLargeType.Line] {
        (row.facts?.details ?? []).map {
            VaultLargeType.Line(label: $0.label, value: $0.drawn(shown: true), isNumber: $0.isNumber)
        }
    }

    /// Space opens Quick Look on the document in the right pane and closes it again, as in Finder.
    /// Not while a search is typed, where it is a space, nor during a proof. Over Large Type it
    /// does nothing, rather than type a space into the search hidden under it.
    private func spaceKey() -> KeyPress.Result {
        if largeType != nil { return .handled }
        guard model.query.trimmingCharacters(in: .whitespaces).isEmpty, editing == nil,
              !model.isAsking, model.selectedRow?.documents.first != nil else { return .ignored }
        toggleQuickLook()
        return .handled
    }

    /// Puts the keyboard back in the search, with the caret after what is typed there: a field
    /// that takes focus selects its text, and the next key would replace the query. With `again`,
    /// cleared first and set on the next turn: focus that already reads true is not re-applied,
    /// though AppKit may have moved key elsewhere (Quick Look's panel hands it back as it likes).
    private func focusSearch(again: Bool = false) {
        if again { searchFocused = false }
        DispatchQueue.main.async {
            searchFocused = true
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    /// The arrows: the next row, or in Large Type the next line.
    private func arrow(_ step: Int) {
        if largeType != nil { return stepLargeType(by: step) }
        // Among the IDs alone, the model walks as it always has.
        guard model.layout != .people, !model.contactItems.isEmpty else { return model.moveSelection(by: step) }
        let here: VaultWalkStop? = contactChosen.map { .contact($0) } ?? model.selection.map { .id($0) }
        switch Self.walk(from: here, by: step, stops: model.walkStops) {
        case .id(let id)?:
            contactChosen = nil
            model.selection = id
        case .contact(let id)?:
            editing = nil
            model.selection = nil
            contactChosen = id
        case nil:
            break
        }
    }

    /// The stop `step` rows from `here` among `stops`, the rows in the order drawn; at either end
    /// it stays. With nothing chosen, or a row no longer there, the first.
    static func walk(from here: VaultWalkStop?, by step: Int, stops: [VaultWalkStop]) -> VaultWalkStop? {
        guard !stops.isEmpty else { return nil }
        guard let here, let index = stops.firstIndex(of: here) else { return stops.first }
        return stops[min(max(index + step, 0), stops.count - 1)]
    }

    /// Return on a chosen contact: copies it, as Return copies a chosen ID.
    private func copyChosenContact() -> Bool {
        guard let item = chosenContact else { return false }
        copyString(item.value, key: "contact-\(item.id)")
        return true
    }

    /// Closes what draws a number in full once it may not be drawn: Large Type (or once its number
    /// is gone from the list), Quick Look of the chosen number's scan, which prints it in full, and
    /// the editor.
    private func closeWhatCannotShow(at now: Date) {
        if let id = largeType?.id, !model.lock.canShow(id, at: now) || !model.rows.contains(where: { $0.id == id }) {
            largeType = nil
        }
        if quickLookPath != nil, model.selectedRow.map({ !model.lock.canShow($0.id, at: now) }) ?? true {
            onCloseQuickLook()
        }
        switch editing {
        case .existing(let id)?, .confirming(let id)?:
            if !model.lock.canShow(id, at: now) { editing = nil }
        default: break
        }
    }

    /// Lights the line `step` away in Large Type, round from the last detail to the ID.
    private func stepLargeType(by step: Int) {
        guard let row = model.rows.first(where: { $0.id == largeType?.id }) else { return }
        let count = Self.largeTypeLines(row).count + 1
        let position = (largeType?.line.map { $0 + 1 } ?? 0) + step
        let next = ((position % count) + count) % count
        largeType?.line = next == 0 ? nil : next - 1
        // Reading an ID out line by line is use: the idle limit does not close it mid-call.
        model.noteActivity()
    }

    /// A document shows the number in full, so while it is hidden, opening one takes the same
    /// proof as showing the number.
    private func whenShown(_ row: VaultModel.Row, _ act: @escaping () -> Void) {
        Task {
            guard await model.show(row.id) else { return }
            act()
        }
    }

    /// Space, and a click on the shown preview: Quick Look on the chosen number's document, or
    /// closed if it already shows it.
    private func toggleQuickLook() {
        guard let row = model.selectedRow, let path = row.documents.first?.path else { return }
        if quickLookPath == path { onCloseQuickLook() } else { quickLook(path, for: row) }
    }

    /// Keeps an open Quick Look on the chosen number: its document if it may be shown, else none.
    private func followQuickLook() {
        guard let open = quickLookPath else { return }
        guard let row = model.selectedRow, let path = row.documents.first?.path,
              model.lock.canShow(row.id, at: model.now) else { return onCloseQuickLook() }
        if path != open { onQuickLook(path) }
    }

    private func quickLook(_ path: String, for row: VaultModel.Row) {
        whenShown(row) { onQuickLook(path) }
    }

    private func reveal(_ path: String, for row: VaultModel.Row) {
        whenShown(row) { onReveal(path) }
    }

    /// A detail's Copy: a number through the Vault's own Copy, after a proof and cleared later;
    /// a date or a word as it is.
    private func copyDetail(_ detail: VaultDetail, of row: VaultModel.Row) {
        let key = "\(row.id)\(detail.label)"
        Task {
            if detail.isNumber {
                guard await model.copy(detail.copied, for: row.id) else { return }
            } else {
                VaultPasteboard.copyPlain(detail.copied)
            }
            flashCopied(key)
        }
    }
}

// MARK: - Activity

/// Use of the app while the Vault is up, which covers the window: any click, key or scroll counts
/// as using the Vault, so it locks only once it has been left alone. The pointer moving over the
/// panel is the panel's own `onContinuousHover`.
@MainActor final class VaultActivityWatch {
    private var monitor: Any?
    /// The window the panel is in, set by ``VaultWindowReader``. Only events there, or in a sheet
    /// or child window of it, count: work in another window leaves this one's Vault idle. Set as
    /// it arrives, the window is kept out of screen sharing at once if an ID is already drawn
    /// in full: the panel's first look at that can come before the window does.
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            // A window the panel leaves shares again; the one it arrives in is set at once.
            VaultWindowPrivacy.apply(exposed: false, to: oldValue, defaults: defaults)
            VaultWindowPrivacy.apply(exposed: exposed, to: window, defaults: defaults)
        }
    }
    /// Whether the panel is drawing an ID in full (``VaultPanel``'s `exposesAnID`).
    var exposed = false
    /// A document of the Vault's is up in Quick Look, whose panel is the app's, not a child of the
    /// Vault's window: use there counts too.
    var countsQuickLook = false
    /// Where Settings ▸ Vault's "Hide from screen sharing" is read: the app's own, or a test's.
    var defaults: UserDefaults = .standard

    func start(_ onActivity: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard Self.belongs(event.window, to: self?.window)
                        || self?.countsQuickLook == true && Self.isQuickLook(event.window) else { return }
                onActivity()
            }
            return event
        }
    }

    /// Whether an event in `target` is use of the Vault in `window`: that window, or a sheet or
    /// child window of it. Never with no window on either side.
    static func belongs(_ target: NSWindow?, to window: NSWindow?) -> Bool {
        guard let window, let target else { return false }
        return target === window || target.sheetParent === window || target.parent === window
    }

    /// Whether `target` is Quick Look's panel.
    static func isQuickLook(_ target: NSWindow?) -> Bool {
        guard let target, QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return target === QLPreviewPanel.shared()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// A card's chrome, an ID card's or a contact card's: its ground, its corners, which the title
/// bar's wash follows, and its border.
struct VaultCardChrome: ViewModifier {
    /// The ground under a card, and under each slice of a person's card in People.
    static let ground = Color(nsColor: .controlBackgroundColor).opacity(0.55)

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Self.ground))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(.quaternary))
    }
}

/// A card's rows, inset from its edges and, on a washed card, under a lighter wash of its color
/// than the title's.
struct VaultCardBody: ViewModifier {
    let tint: VaultTint?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VaultCardBodyWash(tint: tint))
    }
}

/// A piece of a person's card in People: full width, over its slice of the card's ground and
/// border. Each slice draws the whole card's shape, reaching past the piece where the card goes
/// on, and keeps what falls on the piece, so the slices meet as the one shape did. The last piece
/// ends the card 10 points under what it holds.
struct VaultCardSlice: ViewModifier {
    let first: Bool
    let last: Bool

    /// Past the corners' radius, so a corner never shows at a piece's open edge.
    private static let reach: CGFloat = 4 * Radius.card

    func body(content: Content) -> some View {
        content
            .padding(.bottom, last ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Color.clear
                    .overlay {
                        ZStack {
                            RoundedRectangle(cornerRadius: Radius.card).fill(VaultCardChrome.ground)
                            RoundedRectangle(cornerRadius: Radius.card).strokeBorder(.quaternary)
                        }
                        .padding(.top, first ? 0 : -Self.reach)
                        .padding(.bottom, last ? 0 : -Self.reach)
                    }
                    .clipped()
            }
    }
}

/// Keeps a sheet's or popover's own window out of screen sharing, as the Vault's window is while an
/// ID is drawn in full: each is a window of its own, which the Vault's setting does not reach. Used
/// on those that draw a number, a date of birth or a document's name.
struct VaultCapturePrivacy: NSViewRepresentable {
    /// Where the setting is read: the app's own, or a test's.
    var defaults: UserDefaults = .standard

    final class Probe: NSView {
        var defaults: UserDefaults = .standard
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            VaultWindowPrivacy.apply(exposed: true, to: window, defaults: defaults)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.defaults = defaults
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.defaults = defaults
        VaultWindowPrivacy.apply(exposed: true, to: probe.window, defaults: defaults)
    }
}

extension View {
    /// Out of screen sharing while "Hide from screen sharing" is on (``VaultCapturePrivacy``).
    func keptFromCapture(defaults: UserDefaults = .standard) -> some View {
        background(VaultCapturePrivacy(defaults: defaults))
    }
}

/// Tells a ``VaultActivityWatch`` which window the panel is in.
struct VaultWindowReader: NSViewRepresentable {
    let watch: VaultActivityWatch

    final class Probe: NSView {
        weak var watch: VaultActivityWatch?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            watch?.window = window
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.watch = watch
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.watch = watch
        watch.window = probe.window
    }
}

// MARK: - Large Type

/// An ID drawn big for reading out on a call, with its details under it: whichever Large Type
/// was asked for, the ID is always there, and the line asked for is lit. The ID is grouped as its
/// document prints it, and letters take the accent so an O and a zero, an I and a one, are told
/// apart at a glance. A click on a line lights it; ↑ and ↓ light the next; a click outside the
/// card, or esc, puts it away.
struct VaultLargeType: View {
    /// A detail, as the pane draws it in full.
    struct Line {
        let label: String
        let value: String
        /// A number in its own right (the passport a visa is in): grouped and colored as the ID is.
        let isNumber: Bool
    }

    /// Whose it is and what: "Anna Eriksson · Driver’s license".
    let heading: String
    /// What the ID is called on its document: "Passport number", "License number", "PAN".
    let idLabel: String
    let value: String
    let category: VaultCategory
    let lines: [Line]
    /// The lit line: nil for the ID, else the index of a detail.
    let lit: Int?
    let accent: Color
    let onLight: (Int?) -> Void
    /// ↑ (-1) or ↓ (1): light the line that many away.
    let onStep: (Int) -> Void
    let onClose: () -> Void

    /// Large Type holds the keyboard while it is up, so ↑, ↓ and esc work however it was opened:
    /// a click on AA, or on one of its lines, leaves no field focused to hear them.
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.35))
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .accessibilityLabel("Close Large Type")
                .accessibilityAddTraits(.isButton)
            VStack(alignment: .leading, spacing: 8) {
                Text(heading)
                    .scaledFont(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                line(nil, label: idLabel, spoken: VaultMask.spoken(value, shown: true)) {
                    Self.grouped(VaultMask.printed(value, as: category), accent: accent)
                        .font(.system(size: 54, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                }
                if !lines.isEmpty {
                    Divider()
                    // In a small window the details scroll under the ID rather than run off the card.
                    ViewThatFits(in: .vertical) {
                        details
                        // ↑ and ↓ bring the lit line into view.
                        ScrollViewReader { proxy in
                            ScrollView { details }
                                .onChange(of: lit) { _, now in
                                    guard let now else { return }
                                    withDesignAnimation(.easeOut(duration: 0.15), reduceMotion: reduceMotion) {
                                        proxy.scrollTo(now)
                                    }
                                }
                        }
                    }
                }
                Divider()
                HStack {
                    Text("Letters are in color. Hidden again when the Vault locks.")
                    Spacer(minLength: 12)
                    Text(lines.isEmpty ? "esc to close" : "↑ ↓ for another line, esc to close")
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .frame(maxWidth: 720)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(.regularMaterial))
            .padding(24)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(keys: [.upArrow, .downArrow, .escape, .space]) { press in
            switch press.key {
            case .upArrow: onStep(-1)
            case .downArrow: onStep(1)
            case .escape: onClose()
            default: break   // Space: nothing, rather than reach the search under the card.
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(heading), in large type")
    }

    /// The details under the ID, one line each.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, detail in
                line(index, label: detail.label,
                     spoken: detail.isNumber ? VaultMask.spoken(detail.value, shown: true) : detail.value) {
                    (detail.isNumber ? Self.grouped(VaultMask.printed(detail.value, as: nil), accent: accent)
                                     : Text(detail.value))
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                }
                .id(index)
            }
        }
    }

    /// How wide the labels' column is: "Social Security number" on one line or two.
    private static let labelColumn: CGFloat = 170

    /// One line, lit when it is the one asked for: its label in the left column, its value beside
    /// it on the same baseline, so the ID and its details start at one edge.
    private func line(_ index: Int?, label: String, spoken: String,
                      @ViewBuilder value: () -> some View) -> some View {
        let isLit = lit == index
        return Button {
            onLight(index)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(label)
                    .scaledFont(.callout.weight(.semibold))
                    // The lit line's colour is its wash; its words stay ink, never accent on accent.
                    .foregroundStyle(isLit ? .primary : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: Self.labelColumn, alignment: .leading)
                value()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(isLit ? accent.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
        .accessibilityAddTraits(isLit ? .isSelected : [])
    }

    /// One `Text`, so it scales down as a whole when the ID is long. Groups one space apart: in a
    /// monospaced face a space is a whole character wide, which reads as a gap; two read as a break.
    static func grouped(_ groups: [String], accent: Color) -> Text {
        var text = Text("")
        for (index, group) in groups.enumerated() {
            if index > 0 { text = Text("\(text) ") }
            for character in group {
                let glyph = Text(String(character)).foregroundStyle(character.isLetter ? accent : Color.primary)
                text = Text("\(text)\(glyph)")
            }
        }
        return text
    }
}

// MARK: - Customize Groups

/// The Kinds choice's groups: rename one, or move a kind to another. Starts from the app's. The
/// household's own kinds are here too: renamed, moved to a group, or removed, which puts their
/// IDs back on the cards they were read as.
struct VaultGroupsSheet: View {
    @State var groups: VaultGroups
    @State var kinds: VaultKinds
    @State var colors: VaultColors
    @State var showsHeadings: Bool
    let onDone: (VaultGroups, VaultKinds, VaultColors, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The kinds as the sheet opened, for a name emptied and left blank.
    private let original: VaultKinds

    init(groups: VaultGroups, kinds: VaultKinds, colors: VaultColors, showsHeadings: Bool,
         onDone: @escaping (VaultGroups, VaultKinds, VaultColors, Bool) -> Void) {
        _groups = State(initialValue: groups)
        _kinds = State(initialValue: kinds)
        _colors = State(initialValue: colors)
        _showsHeadings = State(initialValue: showsHeadings)
        self.onDone = onDone
        original = kinds
    }

    /// A group's color, as its swatch's choice.
    private func groupColor(_ id: VaultGroups.ID) -> Binding<VaultCardColor?> {
        Binding(get: { colors.color(ofGroup: id) },
                set: { colors.groups[id] = $0 })
    }

    /// A card's own color as its swatch's choice; nil, its group's.
    private func cardColor(_ card: VaultCardID) -> Binding<VaultCardColor?> {
        Binding(get: { colors.own(card) },
                set: { colors.cards[card.key] = $0 })
    }

    private func edit(_ id: VaultCustomKind.ID, _ change: (inout VaultCustomKind) -> Void) {
        guard let index = kinds.custom.firstIndex(where: { $0.id == id }) else { return }
        change(&kinds.custom[index])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Customize Groups")
                .scaledFont(.title3.weight(.semibold))
            Text("The Vault starts with these. Rename a group, give it a color, move it up or down, or move a kind to another one. The cards, the Kinds choice and People follow the order.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Section {
                    Toggle("Color the cards", isOn: $colors.isOn)
                } footer: {
                    Text("A card takes its group’s color unless it has one of its own. A card’s own color is also in the menu on its title (right-click) and beside Kind once an ID is chosen.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(groups.order, id: \.self) { id in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                                .help("Drag to move the group")
                                .accessibilityHidden(true)
                            TextField("Name", text: Binding(get: { groups.name(id) },
                                                            set: { groups.names[id] = $0 }))
                                .labelsHidden()
                                .accessibilityLabel("Name of the group \(groups.name(id))")
                            VaultColorWell(color: groupColor(id), label: "Color of the group \(groups.name(id))",
                                           what: "group \(groups.name(id))")
                                .disabled(!colors.isOn)
                            ControlGroup {
                                Button { groups.move(id, by: -1) } label: { Image(systemName: "chevron.up") }
                                    .disabled(!groups.canMove(id, by: -1))
                                    .help("Move Up")
                                    .accessibilityLabel("Move \(groups.name(id)) up")
                                Button { groups.move(id, by: 1) } label: { Image(systemName: "chevron.down") }
                                    .disabled(!groups.canMove(id, by: 1))
                                    .help("Move Down")
                                    .accessibilityLabel("Move \(groups.name(id)) down")
                            }
                            .fixedSize()
                        }
                    }
                    .onMove { groups.move(fromOffsets: $0, toOffset: $1) }
                    Toggle("Show a heading over each group, in Cards and List", isOn: $showsHeadings)
                } header: {
                    Text("Groups")
                } footer: {
                    Text("The cards follow the groups’ order, with or without the headings.")
                        .foregroundStyle(.secondary)
                }
                Section("Kinds") {
                    ForEach(VaultCategory.mainView, id: \.self) { category in
                        LabeledContent(category.title) {
                            HStack(spacing: 8) {
                                Picker("Group of \(category.title)", selection: Binding(get: { groups.group(of: category) ?? "" },
                                                                                        set: { groups.groupOf[category] = $0 })) {
                                    ForEach(groups.idGroups, id: \.self) { id in Text(groups.name(id)).tag(id) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                VaultColorWell(color: cardColor(.builtIn(category)),
                                               follows: groups.group(of: category).map { colors.color(ofGroup: $0) },
                                               label: "Color of \(category.title)", what: "\(category.title) card")
                                    .disabled(!colors.isOn)
                            }
                        }
                    }
                }
                Section {
                    if kinds.custom.isEmpty {
                        Text("None yet. Choose New Kind… from an account’s Kind menu.")
                            .foregroundStyle(.secondary)
                    }
                    // By id, never by position: a row removed while its name is being typed in
                    // must not write into the row that takes its place.
                    ForEach(kinds.custom) { kind in
                        HStack(spacing: 8) {
                            TextField("Name", text: Binding(get: { kinds.kind(kind.id)?.name ?? kind.name },
                                                            set: { name in edit(kind.id) { $0.name = name } }))
                                .labelsHidden()
                                .accessibilityLabel("Name of the kind \(kind.name)")
                            Picker("Group", selection: Binding(get: { kinds.kind(kind.id)?.group ?? kind.group },
                                                               set: { group in edit(kind.id) { $0.group = group } })) {
                                ForEach(groups.idGroups, id: \.self) { id in Text(groups.name(id)).tag(id) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            VaultColorWell(color: cardColor(.custom(kind.id)),
                                           follows: colors.color(ofGroup: kinds.kind(kind.id)?.group ?? kind.group),
                                           label: "Color of the kind \(kind.name)", what: "\(kind.name) card")
                                .disabled(!colors.isOn)
                            Button("Remove") { kinds.custom.removeAll { $0.id == kind.id } }
                                .controlSize(.small)
                                .help("Its IDs go back where they were before it.")
                                .accessibilityLabel("Remove the kind \(kind.name)")
                        }
                    }
                } header: {
                    Text("Your Kinds")
                } footer: {
                    Text("Removing one puts its IDs back where they were before it.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Use the App’s Groups") {
                    groups = .default
                    // The app's groups come with the app's colors; a card's own color is kept.
                    colors.groups = [:]
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    // An emptied name goes back to the app's, rather than leaving a blank choice.
                    for id in groups.order where groups.names[id]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                        groups.names[id] = VaultGroups.default.names[id]
                    }
                    // So does an emptied kind's: the kind is kept, never removed by a blank name.
                    for index in kinds.custom.indices {
                        let name = kinds.custom[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
                        kinds.custom[index].name = name.isEmpty ? (original.kind(kinds.custom[index].id)?.name ?? name) : name
                    }
                    onDone(groups, kinds, colors, showsHeadings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 680)
    }
}

/// New Kind…: a name, and the group the Kinds choice lists it under (Other's to start).
struct VaultNewKindSheet: View {
    @Binding var name: String
    let groups: VaultGroups
    /// The app kind a name already belongs to, if one does.
    let takenBy: (String) -> String?
    let onCreate: (VaultGroups.ID) -> Void
    let onCancel: () -> Void
    @State private var group: VaultGroups.ID = ""
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Kind")
                .scaledFont(.title3.weight(.semibold))
            Text("A card of your own for accounts, such as Memberships. Other IDs read from the same account’s folder follow.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("Memberships"))
                    .focused($nameFocused)
                Picker("Group", selection: $group) {
                    ForEach(groups.idGroups, id: \.self) { id in Text(groups.name(id)).tag(id) }
                }
            }
            .formStyle(.grouped)
            if let taken = takenBy(trimmed) {
                Text("\(taken) is already one of the Vault’s kinds.")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { onCreate(group) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || takenBy(trimmed) != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            group = groups.group(of: .other) ?? groups.order.first ?? ""
            nameFocused = true
        }
    }
}

/// The answers to "is this right?" for an ID waiting To confirm: Add to Vault…, Correct the ID…,
/// which opens the same editor with the cursor in the ID, and Not an ID….
///
/// On one line: at the regular size where the pane is wide enough, else at the small size, which
/// fits the detail pane at the standard text size. Only a pane narrower still, or a larger text
/// size, puts Not an ID… under the other two. Never a truncated name.
struct VaultAnswers: View {
    let hue: LiquidGlassHue
    let add: () -> Void
    let correct: () -> Void
    let notAnID: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            oneLine.controlSize(.regular)
            oneLine.controlSize(.small)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { addButton; correctButton }
                notAnIDButton
            }
        }
    }

    /// All three side by side, at whatever size the caller sets.
    var oneLine: some View {
        HStack(spacing: 6) { addButton; correctButton; notAnIDButton }
    }

    private var addButton: some View {
        Button("Add to Vault…", action: add)
            .buttonStyle(.borderedProminent).accentedProminent(hue)
            .fixedSize()
    }

    private var correctButton: some View {
        Button("Correct the ID…", action: correct)
            .help("The document is right, but the ID taken from it isn’t: fix it before adding it")
            .fixedSize()
    }

    private var notAnIDButton: some View {
        Button("Not an ID…", action: notAnID)
            .help("This isn’t anyone’s ID: it isn’t offered again, from any file")
            .fixedSize()
    }
}
