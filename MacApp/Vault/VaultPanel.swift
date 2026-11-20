import SwiftUI
import AppKit
import Design
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
    /// The household, for "Belongs to" and the filter. Settings ▸ Organize ▸ People owns the list.
    let people: [Person]
    let glassHue: LiquidGlassHue
    let glassLevel: GlassLevel
    let surfaceTint: Double
    let onClose: () -> Void
    let onOpenSettings: () -> Void
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

                VaultCard(model: model, people: people, glassHue: glassHue,
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
    let people: [Person]
    let glassHue: LiquidGlassHue
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onQuickLook: (String) -> Void
    let onReveal: (String) -> Void
    let onAddPerson: (_ displayName: String, _ fullName: String) -> Person?
    let quickLookPath: String?
    let onCloseQuickLook: () -> Void

    /// The name a number being added was read with, when it matches nobody in People: the
    /// question whether to add them first.
    @State private var askingToAddPerson: String?

    /// Cards (the default) or one list.
    @AppStorage("vaultShowsList") private var showsList = false
    /// Folding a card animates only when the Mac allows motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The detail whose Copy just ran, for its two seconds of "Copied".
    @State private var copiedDetail: String?
    /// The number whose documents are all listed; the others show the first few.
    @State private var allDocumentsShown: UUID?
    /// A passport can be named on dozens of documents: the first few, then Show All.
    static let documentsShown = 5

    private enum Editing: Equatable {
        case new
        case existing(UUID)
        /// A number read from a document, being checked before it is added.
        case confirming(UUID)
    }
    /// Read Documents was asked for with no folder chosen yet.
    @State private var askingForFolders = false
    /// The folders Read Documents looks in, read again as the panel appears and after a change.
    @State private var readFolders: [String] = []

    @State private var editing: Editing?
    @State private var draft = VaultModel.Draft()
    /// The entry Large Type is showing.
    @State private var largeType: UUID?
    @State private var activity = VaultActivityWatch()
    /// Its lit line: nil for the ID, else the index of one of its details.
    @State private var largeTypeLine: Int?
    /// Where, Whose or Kinds, opened to choose again.
    @State private var choosing: Choosing?
    @State private var customizingGroups = false
    /// The entry whose Copy just ran, for the button's two seconds of "Copied".
    @State private var copied: UUID?
    /// What Remove… or ⌘⌫ is asking about, until the dialog is answered.
    @State private var removing: Removal?
    @FocusState private var searchFocused: Bool

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
            content
            Divider()
            footer
        }
        .overlay {
            if let row = model.rows.first(where: { $0.id == largeType }), model.lock.canShow(row.id, at: model.now) {
                VaultLargeType(heading: "\(row.isHousehold ? "Household" : (row.facts?.holder ?? row.whose)) · \(row.title)",
                               idLabel: Self.idLabel(row), value: row.value, category: row.category,
                               lines: Self.largeTypeLines(row), lit: largeTypeLine, accent: glassHue.accentColor,
                               onLight: { largeTypeLine = $0 },
                               onStep: { stepLargeType(by: $0) },
                               onClose: { largeType = nil })
            }
        }
        .task {
            readFolders = VaultReadFolders.folders()
            // Whose a read number is, and the filter's names, come from the household.
            model.people = people
            model.showsList = showsList
            await model.opened()
            searchFocused = true
        }
        // The countdown, and a shown number's thirty seconds. A sleep loop on the view's own
        // task, so it stops when the panel closes.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.tick()
            }
        }
        // People changed in Settings, or a person was added here: whose each number is follows.
        .onChange(of: people) { _, now in model.people = now }
        // Back to SyncCloud with the Vault up and locked: Touch ID is asked for at once, as when
        // it opened. Only on coming back, never the moment it relocks, so no prompt waits at a
        // Mac left alone; a cancelled prompt waits for the next return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let settings = model.lock.settings
            // The same rule as opening: only a Vault with something saved asks at once.
            guard model.contents == .loaded, settings.requiresAuthentication, settings.ask == .whenOpened,
                  !model.isOpen, !model.isAsking, !model.entries.isEmpty else { return }
            Task { await model.unlock() }
        }
        // Access ran out (Lock Now, the idle limit, a number's thirty seconds): nothing that draws
        // a number in full stays up. The editor draws it in its field; Large Type draws it big.
        // Large Type also goes when its number does (removed, set aside), or its state would hold
        // the keys with nothing on screen.
        .onChange(of: model.now) { _, now in
            if let id = largeType, !model.lock.canShow(id, at: now) || !model.rows.contains(where: { $0.id == id }) {
                largeType = nil
            }
            // Quick Look shows the chosen number's scan, which prints it in full.
            if quickLookPath != nil, model.selectedRow.map({ !model.lock.canShow($0.id, at: now) }) ?? true {
                onCloseQuickLook()
            }
            switch editing {
            case .existing(let id)?, .confirming(let id)?:
                if !model.lock.canShow(id, at: now) { editing = nil }
            default: break
            }
        }
        // Back to the search once the editor or Large Type closes, so the arrows, Return and
        // Space work again without a click.
        .onChange(of: editing) { _, now in if now == nil { focusSearch() } }
        // Typing in the editor is use: neither the idle limit nor, under "every number", the
        // number's thirty seconds close it, and its edits, mid-note.
        .onChange(of: draft) { _, _ in if editing != nil { model.noteActivity() } }
        // Choosing a row, or starting a search, puts an open choice away. With Quick Look open,
        // it moves to the newly chosen number's document, or closes when that one is hidden.
        .onChange(of: model.selection) { _, _ in
            choosing = nil
            followQuickLook()
            // A click on a row leaves no field focused: the keys come back to the search. Not
            // forced while it has them, which would select what is typed there.
            if editing == nil, largeType == nil, !searchFocused { focusSearch() }
        }
        // Quick Look's panel takes key while it is up and hands it back to whatever AppKit picks
        // when it closes; the Vault takes it back, so Space opens the chosen document again.
        .onChange(of: quickLookPath) { _, now in
            if now == nil, editing == nil, largeType == nil { focusSearch(again: true) }
        }
        .onChange(of: model.query) { _, _ in choosing = nil }
        .sheet(isPresented: $customizingGroups) {
            VaultGroupsSheet(groups: model.groups, onDone: { model.setGroups($0) })
                .presentedNativeControlAccent()
        }
        .onChange(of: largeType) { _, now in if now == nil { focusSearch() } }
        // A read in progress goes on: the model runs it, and lets the numbers go when it ends.
        .onDisappear {
            activity.stop()
            model.closed()
        }
        // Using the Vault keeps it open: the pointer moving over it, and any click, key or scroll
        // while it is up. It locks only after its idle time with none of these.
        .onContinuousHover { phase in
            if case .active = phase { model.panelActivity() }
        }
        .onAppear { activity.start { model.panelActivity() } }
        .background(VaultWindowReader(watch: activity))
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
                Button("Not a Real ID", role: .destructive) { model.setAside(find.id) }
            }
        } message: { removal in
            switch removal {
            case .entry(let entry):
                Text(entry.sourcePath == nil
                     ? "The ID is removed for good."
                     : "The ID is removed for good, and Read Documents won’t offer it again. The document it came from isn’t touched.")
            case .find:
                Text("A misread: it comes off the Vault and isn’t offered again. Settings ▸ Vault can forget the IDs set aside.")
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
            Text("The Vault reads only the folders you choose, such as the one that holds your passport scans. You can change them later from the arrow beside Read Documents or in Settings ▸ Vault.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.doc")
                .foregroundStyle(.secondary)
            Text("Vault")
                .scaledFont(.headline)
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
            .disabled(model.contents != .loaded)
            readMenu
            Button(action: onOpenSettings) {
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

    /// Read Documents, with its folders beside it: a click reads what is new or changed; the
    /// arrow lists the folders, adds one, or reads everything again.
    private var readMenu: some View {
        Menu {
            Button("Read New and Changed Documents") { readDocuments() }
            Button("Read Everything Again") { readDocuments(again: true) }
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
                                VaultReadFolders.remove(folder)
                                readFolders = VaultReadFolders.folders()
                            }
                        }
                    }
                }
            }
            Button("Add Folder…") { addFolders() }
            Button("Folder Settings…", action: onOpenSettings)
        } label: {
            Label("Read Documents", systemImage: "doc.text.viewfinder")
        } primaryAction: {
            readDocuments()
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(model.reading == nil ? "Read Documents: find IDs in the folders you chose. The arrow lists the folders."
                                   : "Reading your documents…")
        .disabled(model.contents != .loaded || model.reading != nil)
    }

    @ViewBuilder
    private var statePill: some View {
        let settings = model.lock.settings
        if !settings.requiresAuthentication {
            Pill(.mini, tint: SemanticColor.warning, systemImage: "lock.open", text: "Lock is off")
        } else if settings.ask == .everyNumber {
            Pill(.mini, tint: .secondary, systemImage: "lock", text: "Asks for every ID")
        } else if model.isOpen {
            Pill(.mini, tint: SemanticColor.success, systemImage: "lock.open", text: unlockedText)
        } else {
            Pill(.mini, tint: .secondary, systemImage: "lock", text: "Locked")
        }
    }

    private var unlockedText: String {
        guard let left = model.secondsLeft else { return "Unlocked" }
        return "Unlocked · \(left / 60):" + String(format: "%02d", left % 60)
    }

    @ViewBuilder
    private var lockButton: some View {
        let settings = model.lock.settings
        if settings.requiresAuthentication, settings.ask == .whenOpened, model.contents == .loaded {
            if model.isOpen {
                Button {
                    model.lockNow()
                } label: {
                    Label("Lock Now", systemImage: "lock")
                }
            } else if !model.entries.isEmpty {
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
            if !showsList, !model.cards.isEmpty {
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
            VaultViewSwitch(showsList: $showsList, hue: glassHue)
                .fixedSize()
                .onChange(of: showsList) { _, list in model.showsList = list }
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
                        optionChip(model.groups.name(id), count: model.count(kind: .some(id)), isSelected: model.kindFilter == id) {
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

    private func optionChip(_ title: String, code: String? = nil, count: Int, isSelected: Bool,
                            pick: @escaping () -> Void) -> some View {
        Button {
            pick()
            withDesignAnimation(.snappy(duration: 0.15), reduceMotion: reduceMotion) { choosing = nil }
        } label: {
            HStack(spacing: 4) {
                if let code { countryCode(code).accessibilityHidden(true) }
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
    private func countryCode(_ code: String) -> some View {
        Text(code)
            .scaledFont(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
            .accessibilityLabel(code == "US" ? "United States" : code == "IN" ? "India" : code)
    }

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
                .onSubmit { if let id = model.selection, editing == nil { copy(id) } }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .searchFieldSurface()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.contents {
        case .unreadable(let error):
            EmptyStateView(icon: "lock.trianglebadge.exclamationmark", tint: SemanticColor.warning,
                           title: "This Vault can’t be opened here",
                           message: VaultModel.message(for: error),
                           caption: "The sealed file has been left as it is.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notLoaded, .loaded:
            if model.entries.isEmpty, model.finds.isEmpty, editing == nil {
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
                                if showsList { listView } else { cardsView }
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
                    if model.cards.isEmpty {
                        if hiddenByChoices {
                            EmptyStateView(icon: "line.3.horizontal.decrease.circle", title: "Nothing here for these choices",
                                           message: "IDs on this tab belong to another country, person or kind.",
                                           primary: .init("Show Everything", systemImage: "arrow.uturn.backward") {
                                               model.resetFilters()
                                           }, layout: .compact)
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity)
                        } else {
                            EmptyStateView(icon: "magnifyingglass", title: emptyTitle, message: emptyMessage, layout: .compact)
                                .padding(.top, 24)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)],
                              alignment: .leading, spacing: 12) {
                        ForEach(model.cards, id: \.category) { card in
                            categoryCard(card.category, card.rows)
                        }
                    }
                    // Kinds that only the other country has, which no card here can point to.
                    if let elsewhere = model.elsewhereKinds {
                        Button {
                            model.geoFilter = elsewhere.filter
                        } label: {
                            Text("\(elsewhere.count) More in \(elsewhere.filter.title) →")
                                .scaledFont(.subheadline.weight(.medium))
                                .foregroundStyle(glassHue.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Show \(elsewhere.filter.title)")
                    }
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
        }
    }

    /// A card: its header folds and opens it (⌥-click: every card); folded, the header says what
    /// is inside in one line.
    private func categoryCard(_ category: VaultCategory, _ rows: [VaultModel.Row]) -> some View {
        let isFolded = model.folded.contains(category)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                withDesignAnimation(.snappy(duration: 0.2), reduceMotion: reduceMotion) {
                    model.toggleFold(category, all: NSEvent.modifierFlags.contains(.option))
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                        .frame(width: 10)
                    Image(systemName: category.symbol)
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(glassHue.accentColor)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(glassHue.accentColor.opacity(0.14)))
                    Text(category.title)
                        .scaledFont(.subheadline.weight(.semibold))
                    Text(rows.count.formatted())
                        .scaledFont(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if isFolded {
                        Text(Self.foldedSummary(rows))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Expand. ⌥-click to expand every card." : "Collapse. ⌥-click to collapse every card.")
            .accessibilityLabel("\(category.title), \(rows.count)")
            .accessibilityValue(isFolded ? "Collapsed" : "Expanded")
            if !isFolded {
                ForEach(rows) { row in rowView(row).id(row.id) }
                if let elsewhere = model.elsewhere(category) {
                    Button {
                        model.geoFilter = elsewhere.filter
                    } label: {
                        Text("\(elsewhere.count) More in \(elsewhere.filter.title) →")
                            .scaledFont(.caption.weight(.medium))
                            .foregroundStyle(glassHue.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show \(elsewhere.filter.title)")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(.quaternary))
    }

    /// A folded card's one line: "3 people · 1 expired · 2 to confirm".
    static func foldedSummary(_ rows: [VaultModel.Row]) -> String {
        let people = Set(rows.map { $0.personID ?? $0.whose }).count
        let expired = rows.filter(\.standing.expired).count
        let waiting = rows.filter { !$0.isSaved && $0.standing.tab != .archive }.count
        var parts = [people == 1 ? "1 person" : "\(people) people"]
        if expired > 0 { parts.append("\(expired) expired") }
        if waiting > 0 { parts.append("\(waiting) to confirm") }
        return parts.joined(separator: " · ")
    }

    /// The same rows, one column, under each kind's name.
    private var listView: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    tabBanner
                    if model.cards.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: emptyTitle, message: emptyMessage, layout: .compact)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(model.cards, id: \.category) { card in
                        Text(card.category.title)
                            .scaledFont(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                        ForEach(card.rows) { row in rowView(row).id(row.id) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .onChange(of: model.selection) { _, id in if let id { scroller.scrollTo(id) } }
        }
    }

    @ViewBuilder
    private var tabBanner: some View {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            EmptyView()
        } else if model.tab == .archive {
            Text("Older IDs: run out, replaced by a newer one, or filed in an Archive folder. Kept for reference; add one only if a form may ask for it.")
                .scaledFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if model.tab == .other {
            Text("Kinds the Vault can read but doesn’t show on the main view yet.")
                .scaledFont(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// After a build that reads documents differently: what was read before was let go, so the
    /// tabs hold only what was saved until the folders are read again.
    @ViewBuilder
    private var readAgainBanner: some View {
        if model.needsReadAgain, model.reading == nil {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(glassHue.accentColor)
                Text("This version reads documents better. Read them again to fill Current and Archive; your choices are kept.")
                    .scaledFont(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button {
                    readDocuments(again: true)
                } label: {
                    Label("Read Again", systemImage: "doc.text.viewfinder")
                }
                .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(glassHue.accentColor.opacity(0.1)))
        }
    }

    /// Whether this tab has numbers the three choices hide.
    private var hiddenByChoices: Bool {
        model.query.isEmpty && model.count(in: model.tab) == 0 && model.rows.contains { $0.standing.tab == model.tab }
    }

    private var emptyTitle: String { model.query.isEmpty ? "Nothing here" : "No IDs match" }
    private var emptyMessage: String {
        model.query.isEmpty ? "IDs that belong here appear after Read Documents, or when you add one."
            : "Search looks at names, notes and kinds in every tab, never at the IDs themselves."
    }

    /// One number: whose, what it is, its ending, and badges for what needs noticing.
    private func rowView(_ row: VaultModel.Row) -> some View {
        let isSelected = model.selection == row.id
        return Button {
            model.selection = row.id
            editing = nil
        } label: {
            HStack(spacing: 9) {
                Text(initials(row))
                    .scaledFont(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.quaternary))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(rowTitle(row))
                            .scaledFont(.body.weight(.semibold))
                            .lineLimit(1)
                        if model.geoFilter == .all, model.spansCountries, let code = row.geo.code { countryCode(code) }
                    }
                    Text(rowSubtitle(row))
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(VaultMask.masked(row.value))
                        .scaledFont(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 3) { badges(row) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Radius.chip)
                .fill(isSelected ? glassHue.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowMenu(row) }
        .accessibilityLabel(Self.rowSpoken(title: rowTitle(row), row: row))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func badges(_ row: VaultModel.Row) -> some View {
        if row.standing.inUse { Pill(.mini, tint: SemanticColor.info, text: "In use") }
        if row.standing.expired { Pill(.mini, tint: SemanticColor.warning, text: "Expired") }
        if row.standing.pending { Pill(.mini, tint: glassHue.accentColor, text: "Pending") }
        if row.isSaved {
            Pill(.mini, tint: SemanticColor.success, text: "In Vault")
        } else if row.standing.tab != .archive {
            Pill(.mini, tint: glassHue.accentColor, text: "To confirm")
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
        Divider()
        if row.standing.tab == .archive {
            Button("Make Current") { model.pin(row.id, .current) }
        } else {
            Button("Mark as Older") { model.pin(row.id, .older) }
        }
        if row.pin != nil { Button("Let the Vault Decide") { model.pin(row.id, nil) } }
        Divider()
        if row.isSaved {
            if let entry = model.entries.first(where: { $0.id == row.id }) {
                Button("Remove…", role: .destructive) { removing = .entry(entry) }
            }
        } else if let find = model.finds.first(where: { $0.id == row.id }) {
            Button("Not a Real ID…", role: .destructive) { removing = .find(find) }
        }
    }

    /// Belongs To: a person in the household, the household itself, or back to the document's
    /// name. A tick marks the current choice.
    private func belongsToMenu(_ row: VaultModel.Row) -> some View {
        Menu {
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
            if !row.isHousehold, row.personID == nil, let holder = row.facts?.holder,
               PersonRegistry(people: people).detect(in: holder).isEmpty {
                Divider()
                Button("Add “\(holder)” to People") {
                    if let person = addPerson(named: holder) { model.assign(row.id, to: .person(person.id)) }
                }
            }
            if row.assignment != nil, row.facts?.holder != nil {
                Divider()
                Button("As the Document Says") { model.assign(row.id, to: nil) }
            }
        } label: {
            // A name read from the document that matches nobody in People says so, rather than
            // passing for a person of the household.
            if !row.isHousehold, row.personID == nil, let holder = row.facts?.holder {
                Text(PersonRegistry(people: people).detect(in: holder).count > 1
                     ? "\(holder) · Choose Who" : "\(holder) · Not in People")
            } else {
                Text(row.isHousehold ? "Household" : row.whose)
            }
        }
    }

    /// Used In: where the number is used, and how that is known. A choice wins over the document,
    /// and later reads keep it.
    private func usedIn(_ row: VaultModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Used in")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
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
                        Button(row.isTypedIn ? "Anywhere Again" : "As the Document Says") { model.setGeo(row.id, to: nil) }
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
        }
        .help("Where this ID is used. Anywhere shows in every country; a passport is anywhere.")
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

    /// The editor's Belongs To, as one value for its picker.
    static func belongsTag(_ assignment: VaultAssignment?) -> String {
        switch assignment {
        case .person(let id)?: return "person:" + id
        case .household?: return "household"
        case nil: return "document"
        }
    }

    private var draftBelongsTo: Binding<String> {
        Binding(get: { Self.belongsTag(draft.assignment) }, set: { tag in
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

    /// Whose it is, and which one when a person has more than one of a kind.
    private func rowTitle(_ row: VaultModel.Row) -> String {
        if row.isTypedIn { return row.title }
        // Whose, when a name was read; then what tells this one apart from others of its kind.
        let whose = row.personID != nil || row.facts?.holder != nil ? row.whose : nil
        let which: String?
        switch row.category {
        case .passport: which = row.facts?.issuer
        case .usVisa:
            // An OCI card or an e-Visa by what it is ("OCI card", "India e-Visa"); a US visa by its class.
            which = row.facts?.form != nil ? row.title
                : row.facts?.details.first { $0.label == "Visa class" }.map { $0.drawn(shown: true) } ?? "US visa"
        case .uscisCase: which = row.facts?.form ?? (whose == nil ? "USCIS case" : nil)
        // An account read from a paper by who issued it and what the number is: "EBMUD · Account number".
        case .health, .utilities, .loans, .other: which = row.facts == nil ? nil : row.title
        default: which = nil
        }
        let parts = [whose, which].compactMap { $0 }
        return parts.isEmpty ? row.category.singular : parts.joined(separator: " · ")
    }

    /// What tells it apart at a glance: when it runs out or why it is in Archive, and its files.
    private func rowSubtitle(_ row: VaultModel.Row) -> String {
        var parts: [String] = []
        if row.isTypedIn {
            parts.append(row.whose)
            if !row.note.isEmpty { parts.append(row.note) }
            parts.append("Typed in")
            return parts.joined(separator: " · ")
        }
        if let reason = row.standing.reason, row.standing.tab == .archive {
            parts.append(reason)
        } else if let until = row.facts?.validUntil {
            let word = row.category == .i94 ? "Admitted until" : VaultReading.hasRunOut(until, now: model.now) ? "Expired" : "Valid to"
            parts.append("\(word) \(VaultReading.monthYear(until))")
        } else if let dated = row.facts?.dated {
            parts.append(VaultReading.monthYear(dated))
        }
        let files = row.documents.count
        if files > 1 { parts.append("\(files) files") }
        return parts.joined(separator: " · ")
    }

    // MARK: The chosen number

    @ViewBuilder
    private var side: some View {
        if editing != nil {
            editor
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
                    VaultDocumentPreview(path: path, shown: shown) {
                        if shown { toggleQuickLook() } else { Task { await model.show(row.id) } }
                    }
                    // A fresh preview for each number, so nothing of one number's scan is drawn
                    // under another's name.
                    .id(row.id)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.isTypedIn ? row.title : row.title.replacingOccurrences(of: " case", with: ""))
                        .scaledFont(.title3.weight(.semibold))
                    Text(detailLede(row))
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text("Belongs to")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                    belongsToMenu(row)
                        .menuStyle(.borderlessButton)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .leading)
                }
                .help("Whose this ID is. A choice here wins over the name on the document, and later reads keep it.")
                usedIn(row)
                if row.standing.inUse {
                    callout("Still in use: a visa that is still good is in this passport, so carry it with the new one.",
                            tint: SemanticColor.info)
                } else if row.standing.expired, row.standing.tab == .current, model.reading == nil {
                    callout("Expired, and the newest of its kind read for \(row.whose). It stays here until a newer one is read.",
                            tint: SemanticColor.warning)
                }
                numberBox(row, shown: shown)
                actionBar(row)
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
            .padding(14)
        }
    }

    private func detailLede(_ row: VaultModel.Row) -> String {
        var parts = [row.isHousehold ? "Household" : (row.facts?.holder ?? row.whose)]
        switch row.standing.tab {
        case .archive: parts.append(row.standing.reason ?? "Older, kept for reference")
        case .other: parts.append("Not on the main view yet")
        case .current: if !row.isSaved { parts.append("Read from a document; check it, then add it") }
        }
        return parts.joined(separator: " · ")
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
            Text(shown ? row.value : VaultMask.masked(row.value))
                .scaledFont(.title2.monospaced().weight(.semibold))
                .foregroundStyle(shown ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Not selectable: ⌘C on selected text would put the number on the clipboard
                // plainly, never concealed nor cleared. Copy and Large Type are the ways out.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(shown ? "The ID" : "The ID, hidden")
                .accessibilityValue(Self.spokenNumber(row.value, shown: shown))
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
                .help("Copies the ID. It clears from the clipboard after a minute.")
            } else {
                Button {
                    Task { await model.show(row.id) }
                } label: {
                    Label("Show", systemImage: "touchid")
                }
                .help("Shows the ID after Touch ID or your password.")
            }
        }
        .disabled(model.isAsking)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Radius.well).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: Radius.well).strokeBorder(.quaternary))
    }

    /// One main action, and the rarer ones in a menu.
    private func actionBar(_ row: VaultModel.Row) -> some View {
        HStack(spacing: 6) {
            if row.isSaved {
                if let entry = model.entries.first(where: { $0.id == row.id }) {
                    Button("Edit…") { startEditing(entry) }
                }
            } else if let find = model.finds.first(where: { $0.id == row.id }) {
                Button("Add to Vault…") { startConfirming(find) }
                    .buttonStyle(.borderedProminent).accentedProminent(glassHue)
            }
            Menu {
                if row.standing.tab == .archive {
                    Button("Make Current") { model.pin(row.id, .current) }
                } else {
                    Button("Mark as Older") { model.pin(row.id, .older) }
                }
                if row.pin != nil { Button("Let the Vault Decide") { model.pin(row.id, nil) } }
                Divider()
                if row.isSaved, let entry = model.entries.first(where: { $0.id == row.id }) {
                    Button("Remove from Vault…", role: .destructive) { removing = .entry(entry) }
                } else if let find = model.finds.first(where: { $0.id == row.id }) {
                    Button("Not a Real ID…", role: .destructive) { removing = .find(find) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: Mark as Older or Make Current, and Remove")
            .accessibilityLabel("More")
        }
        .disabled(model.isAsking)
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
            .help(detail.isNumber ? "Copies it in full, after Touch ID; it clears after a minute."
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
            Text("Documents with this ID")
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            let documents = Array(row.documents.enumerated())
            let listed = allDocumentsShown == row.id ? documents : Array(documents.prefix(Self.documentsShown))
            ForEach(listed, id: \.element.path) { index, source in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Pill(.mini, tint: index == 0 ? SemanticColor.success : .secondary,
                             text: index == 0 ? "Read from" : source.role)
                            .help(index == 0 ? source.role : "Names this ID")
                        Button {
                            quickLook(source.path, for: row)
                        } label: {
                            Text(shown ? (source.path as NSString).lastPathComponent : VaultMask.fileName(source.path))
                                .scaledFont(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                        .help("Quick Look")
                        let folder = (source.path as NSString).deletingLastPathComponent
                        Text(Self.shortFolder(shown ? folder : VaultMask.folder(folder)))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(((shown ? folder : VaultMask.folder(folder)) as NSString).abbreviatingWithTildeInPath)
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
                }
                field("Belongs to") {
                    Picker("Belongs to", selection: draftBelongsTo) {
                        ForEach(people) { person in
                            Text(person.displayName).tag(Self.belongsTag(.person(person.id)))
                        }
                        Divider()
                        Text("Household").tag(Self.belongsTag(.household))
                        // A read number may also go by the name on its document.
                        if let holder = draft.facts?.holder {
                            Text("As the Document Says (\(holder))").tag(Self.belongsTag(nil))
                        }
                    }
                }
                field("Kind") {
                    // The cards: a number typed in goes on its own kind's card.
                    Picker("Kind", selection: $draft.category) {
                        ForEach(VaultCategory.typedIn, id: \.self) { category in
                            Text(category.singular).tag(category)
                        }
                    }
                }
                field("Note") {
                    TextField("Note", text: $draft.note, prompt: Text("The issuer, or anything else"))
                }
                HStack(spacing: 6) {
                    if case .existing(let id) = editing, let entry = model.entries.first(where: { $0.id == id }) {
                        Button("Remove…", role: .destructive) { removing = .entry(entry) }
                    }
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button(isConfirming ? "Add to Vault" : "Save") { save() }
                        .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.isComplete || model.isAsking)
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
        case .find(let find): return "Is “\(find.title)” not a real ID?"
        case nil: return ""
        }
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
                Text(reading.total == 0 ? "Finding documents…"
                                        : "Reading \(reading.done.formatted()) of \(Self.documents(reading.total))…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if let last = model.lastReading {
                Text(Self.summary(last))
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

    /// Whose it is: the person's name, or "Household" for one nobody in particular owns. A person
    /// since removed from Settings keeps their numbers; the row says so rather than hiding them.
    private func owner(of entry: VaultEntry) -> String {
        guard let id = entry.personID else { return "Household" }
        return people.first { $0.id == id }?.displayName ?? "Someone no longer in People"
    }

    private func subtitle(of entry: VaultEntry) -> String {
        entry.note.isEmpty ? owner(of: entry) : "\(owner(of: entry)) · \(entry.note)"
    }

    static func documents(_ count: Int) -> String {
        count == 1 ? "1 document" : "\(count.formatted()) documents"
    }

    /// The footer after a read: "Read 3 new or changed of 812 documents: 1 new ID to confirm."
    static func summary(_ last: VaultModel.ReadingSummary) -> String {
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

    /// What the ID in Large Type is called, as its document calls it; the heading above already
    /// says what the document is, so this never repeats it ("Passport" over "Passport").
    static func idLabel(_ row: VaultModel.Row) -> String {
        let form = row.facts?.form
        switch row.category {
        case .passport: return "Passport number"
        case .usVisa:
            switch form {
            case "OCI"?: return "OCI number"
            case "e-Visa"?: return "Application number"
            case nil where row.facts == nil: return "Visa number"
            default: return "Control Number"
            }
        case .i94: return "Admission number"
        case .uscisCase: return "Receipt number"
        case .driversLicense: return row.title.hasPrefix("State ID") ? "ID number" : "License number"
        case .ssn: return form == "ITIN" ? "ITIN" : "Social Security number"
        case .pan: return "PAN"
        case .aadhaar: return "Aadhaar number"
        case .voterID: return "EPIC number"
        // A read account's number as its paper calls it: "Member ID", "Policy number", "Student ID".
        case .health: return form ?? "Member ID"
        case .utilities, .loans: return form ?? "Account number"
        case .other: return form ?? "Number"
        }
    }

    /// What VoiceOver says of the number: each character apart while shown, so it is spelled out
    /// rather than read as one large number; its last four while hidden.
    static func spokenNumber(_ value: String, shown: Bool) -> String {
        let plain = VaultReading.normalized(value)
        guard shown else { return plain.count > 4 ? "ending \(plain.suffix(4).map(String.init).joined(separator: " "))" : "" }
        return plain.map(String.init).joined(separator: " ")
    }

    /// A row as VoiceOver reads it: what it is, its ending, and the badges the eye sees.
    static func rowSpoken(title: String, row: VaultModel.Row) -> String {
        var parts = [title, row.category.singular, spokenNumber(row.value, shown: false)]
        if row.standing.inUse { parts.append("in use") }
        if row.standing.expired { parts.append("expired") }
        if row.standing.pending { parts.append("pending") }
        parts.append(row.isSaved ? "in Vault" : row.standing.tab == .archive ? "older" : "to confirm")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

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

    private func startAdding() {
        var blank = VaultModel.Draft()
        // A new number starts with the person the list is filtered to.
        if case .person(let id) = model.personFilter { blank.personID = id } else { blank.isHousehold = true }
        draft = blank
        editing = .new
    }

    private func startEditing(_ entry: VaultEntry) {
        Task {
            // The editor draws the number in full, so it opens only once that is allowed.
            guard await model.show(entry.id) else { return }
            draft = VaultModel.Draft(entry)
            editing = .existing(entry.id)
        }
    }

    private func save() {
        switch editing {
        case .new:
            if model.add(draft) != nil { editing = nil }
        case .existing(let id):
            Task { if await model.update(id, to: draft) { editing = nil } }
        case .confirming(let id):
            // A name nobody in People answers to: ask whether to add them first, so the number
            // has a person, a filter chip, and Organize knows them too.
            if draft.personID == nil, !draft.isHousehold, let holder = draft.facts?.holder,
               VaultModel.person(named: holder, among: people) == nil {
                askingToAddPerson = holder
                return
            }
            if model.confirm(id, as: draft) != nil { editing = nil }
        case nil:
            break
        }
    }

    /// The editor, filled from what was read. It draws the number in full, so it opens only once
    /// that is allowed, as Edit does.
    private func startConfirming(_ find: VaultFind) {
        Task {
            guard await model.show(find.id) else { return }
            draft = VaultModel.Draft(find, people: people)
            editing = .confirming(find.id)
        }
    }

    /// Read Documents, over the folders chosen here or in Settings ▸ Vault. `again` opens every
    /// file, not only the new and changed ones.
    private func readDocuments(again: Bool = false) {
        guard model.reading == nil else { return }
        let folders = VaultReadFolders.folders()
        readFolders = folders
        guard !folders.isEmpty else {
            askingForFolders = true
            return
        }
        // The model runs it, so it carries on when the panel closes.
        model.startReading(with: VaultFolderReader(folders: folders), again: again)
    }

    /// Add Folder…: the same list as Settings ▸ Vault ▸ Folders to Read.
    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Read for IDs"
        panel.message = "Choose the folders that hold your passport scans, I-94s and USCIS notices."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { VaultReadFolders.add(url.path) }
        readFolders = VaultReadFolders.folders()
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
            copied = id
            try? await Task.sleep(for: .seconds(2))
            if copied == id { copied = nil }
        }
    }

    /// Large Type for the ID, with `line` lit: nil for the ID itself, else a detail's index.
    private func showLargeType(_ id: UUID, line: Int? = nil) {
        Task {
            guard await model.show(id) else { return }
            largeTypeLine = line
            largeType = id
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
        if largeType != nil { stepLargeType(by: step) } else { model.moveSelection(by: step) }
    }

    /// Lights the line `step` away in Large Type, round from the last detail to the ID.
    private func stepLargeType(by step: Int) {
        guard let row = model.rows.first(where: { $0.id == largeType }) else { return }
        let count = Self.largeTypeLines(row).count + 1
        let position = (largeTypeLine.map { $0 + 1 } ?? 0) + step
        let next = ((position % count) + count) % count
        largeTypeLine = next == 0 ? nil : next - 1
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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(detail.copied, forType: .string)
            }
            copiedDetail = key
            try? await Task.sleep(for: .seconds(2))
            if copiedDetail == key { copiedDetail = nil }
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
    /// or child window of it, count: work in another window leaves this one's Vault idle, and
    /// every window has a Vault of its own.
    weak var window: NSWindow?

    func start(_ onActivity: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let window = self?.window, let target = event.window,
                      target === window || target.sheetParent === window || target.parent === window else { return }
                onActivity()
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
                line(nil, label: idLabel, spoken: VaultCard.spokenNumber(value, shown: true)) {
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
                     spoken: detail.isNumber ? VaultCard.spokenNumber(detail.value, shown: true) : detail.value) {
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

/// The Kinds choice's groups: rename one, or move a kind to another. Starts from the app's.
struct VaultGroupsSheet: View {
    @State var groups: VaultGroups
    let onDone: (VaultGroups) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Customize Groups")
                .scaledFont(.title3.weight(.semibold))
            Text("The Vault starts with these. Rename a group, or move a kind to another one; the Kinds choice follows.")
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Section("Groups") {
                    ForEach(groups.order, id: \.self) { id in
                        TextField("Name", text: Binding(get: { groups.name(id) },
                                                        set: { groups.names[id] = $0 }))
                            .accessibilityLabel("Name of the group \(groups.name(id))")
                    }
                }
                Section("Kinds") {
                    ForEach(VaultCategory.mainView, id: \.self) { category in
                        Picker(category.title, selection: Binding(get: { groups.group(of: category) ?? "" },
                                                                  set: { groups.groupOf[category] = $0 })) {
                            ForEach(groups.order, id: \.self) { id in Text(groups.name(id)).tag(id) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Use the App’s Groups") { groups = .default }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    // An emptied name goes back to the app's, rather than leaving a blank choice.
                    for id in groups.order where groups.names[id]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
                        groups.names[id] = VaultGroups.default.names[id]
                    }
                    onDone(groups)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 560)
    }
}
