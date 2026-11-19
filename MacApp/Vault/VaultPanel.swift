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

    static func fitted(within available: CGSize) -> CGSize {
        ResizableCardSize.clamped(preferred, minimum: minimum,
                                  within: CGSize(width: available.width - margin,
                                                 height: available.height - margin))
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

    var body: some View {
        GeometryReader { proxy in
            let size = VaultCardSize.fitted(within: proxy.size)
            ZStack {
                OverlayScrim(level: glassLevel)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VaultCard(model: model, people: people, glassHue: glassHue,
                          onClose: onClose, onOpenSettings: onOpenSettings,
                          onQuickLook: onQuickLook, onReveal: onReveal, onAddPerson: onAddPerson)
                    .frame(width: size.width, height: size.height)
                    // The card's own controls take the window's hue, not the Mac's accent.
                    .nativeControlAccent(glassHue)
                    .contentSurface(hue: glassHue, tint: surfaceTint)
                    .groundedGlassCard(level: glassLevel)
                    .overlayPanelShadow()
                    // Absorb clicks on the card so they don't fall through to the backdrop.
                    .contentShape(Rectangle())
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

    /// Read Documents, so closing the panel stops it.
    @State private var readTask: Task<Void, Never>?
    /// Read Documents was asked for with no folder chosen yet.
    @State private var askingForFolders = false
    /// The folders Read Documents looks in, read again as the panel appears and after a change.
    @State private var readFolders: [String] = []

    @State private var editing: Editing?
    @State private var draft = VaultModel.Draft()
    /// The entry Large Type is showing.
    @State private var largeType: UUID?
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
                VaultLargeType(title: row.title, value: row.value, owner: row.whose, accent: glassHue.accentColor) {
                    largeType = nil
                }
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
        // Access ran out (Lock Now, the idle limit, a number's thirty seconds): nothing that draws
        // a number in full stays up. The editor draws it in its field; Large Type draws it big.
        .onChange(of: model.now) { _, now in
            if let id = largeType, !model.lock.canShow(id, at: now) { largeType = nil }
            switch editing {
            case .existing(let id)?, .confirming(let id)?:
                if !model.lock.canShow(id, at: now) { editing = nil }
            default: break
            }
        }
        // Back to the search once the editor or Large Type closes, so the arrows, Return and
        // Space work again without a click.
        .onChange(of: editing) { _, now in if now == nil { searchFocused = true } }
        .onChange(of: largeType) { _, now in if now == nil { searchFocused = true } }
        .onDisappear {
            readTask?.cancel()
            model.closed()
        }
        // ⌘⌫ removes the chosen row, after asking. Not while the search has text, where it
        // deletes to the start of the line as usual, nor while the editor is open.
        .background {
            Button("Remove the Chosen Number") { askToRemoveChosen() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.query.isEmpty || editing != nil || model.isAsking)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil },
                                                               set: { if !$0 { removing = nil } }),
                            presenting: removing) { removal in
            switch removal {
            case .entry(let entry):
                Button("Remove", role: .destructive) { remove(entry.id) }
            case .find(let find):
                Button("Not a Real Number", role: .destructive) { model.setAside(find.id) }
            }
        } message: { removal in
            switch removal {
            case .entry(let entry):
                Text(entry.sourcePath == nil
                     ? "The number is removed for good."
                     : "The number is removed for good, and Read Documents won’t offer it again. The document it came from isn’t touched.")
            case .find:
                Text("A misread: it comes off the Vault and isn’t offered again. Settings ▸ Vault can forget the numbers set aside.")
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
            Button {
                startAdding()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add a number")
            .accessibilityLabel("Add a number")
            .disabled(model.contents != .loaded)
            readMenu
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .help("Vault settings")
            .accessibilityLabel("Vault settings")
            CloseButton(action: escape)
                .keyboardShortcut(.cancelAction)
                .shortcutKeycap("esc")
                .help(ShortcutHint.tooltip("Close Vault", "esc"))
                .accessibilityLabel("Close Vault")
        }
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
            Image(systemName: "doc.text.viewfinder")
        } primaryAction: {
            readDocuments()
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(model.reading == nil ? "Read Documents: find numbers in the folders you chose. The arrow lists the folders."
                                   : "Reading your documents…")
        .accessibilityLabel("Read Documents")
        .disabled(model.contents != .loaded || model.reading != nil)
    }

    @ViewBuilder
    private var statePill: some View {
        let settings = model.lock.settings
        if !settings.requiresAuthentication {
            Pill(.mini, tint: SemanticColor.warning, systemImage: "lock.open", text: "Lock is off")
        } else if settings.ask == .everyNumber {
            Pill(.mini, tint: .secondary, systemImage: "lock", text: "Asks for every number")
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
                Button("Lock Now") { model.lockNow() }
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

    /// Above the cards, and staying put as they scroll: the search that narrows them, and Collapse
    /// All, in words (Expand All once every card is folded).
    private var searchRow: some View {
        HStack(spacing: 10) {
            searchField
                .frame(maxWidth: 300)
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
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
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
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                // Space looks at the chosen number's document, while nothing is typed; once a
                // search is under way it is a space.
                .onKeyPress(.space) {
                    guard model.query.trimmingCharacters(in: .whitespaces).isEmpty, editing == nil,
                          let row = model.selectedRow else { return .ignored }
                    if let path = row.documents.first?.path { quickLook(path, for: row) }
                    return .handled
                }
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
                               message: "Keep the numbers you get asked for here: a passport number, a member ID, a loan number. Each is sealed on this Mac and shown only to you.",
                               caption: model.lastReading.map { "Read \(Self.documents($0.documents)); nothing new to confirm." },
                               primary: .init("Add a Number", systemImage: "plus") { startAdding() },
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

    /// Current, Archive and Other Finds; whose; and Cards or List.
    private var controlRow: some View {
        HStack(spacing: 10) {
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
            .help("Current: the number in use for each person and kind. Archive: older ones, kept for reference. A search looks in every tab.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    filterChip("Everyone", .everyone)
                    ForEach(people.filter { person in model.rows.contains { $0.personID == person.id } }) { person in
                        filterChip(person.displayName, .person(person.id))
                    }
                    if model.rows.contains(where: \.isHousehold) {
                        filterChip("Household", .household)
                    }
                }
            }
            Picker("View", selection: $showsList) {
                Image(systemName: "square.grid.2x2").tag(false).help("Cards")
                Image(systemName: "list.bullet").tag(true).help("List")
            }
            .pickerStyle(.segmented)
            .accentedSegments(glassHue)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Cards or list")
            .onChange(of: showsList) { _, list in model.showsList = list }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func filterChip(_ title: String, _ filter: VaultModel.PersonFilter) -> some View {
        let isSelected = model.personFilter == filter
        return Button {
            model.personFilter = filter
        } label: {
            Text(title)
                .scaledFont(.subheadline.weight(isSelected ? .semibold : .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(isSelected ? glassHue.accentColor.opacity(0.16) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The cards, two across where they fit, and a line naming the kinds with nothing yet.
    private var cardsView: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tabBanner
                    if model.cards.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: emptyTitle, message: emptyMessage, layout: .compact)
                            .padding(.top, 24)
                            .frame(maxWidth: .infinity)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)],
                              alignment: .leading, spacing: 12) {
                        ForEach(model.cards, id: \.category) { card in
                            categoryCard(card.category, card.rows)
                        }
                    }
                    if model.tab == .current, model.query.isEmpty, model.personFilter == .everyone,
                       !model.emptyCategories.isEmpty {
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
            Text("Older numbers: run out, replaced by a newer one, or filed in an Archive folder. Kept for reference; add one only if a form may ask for it.")
                .scaledFont(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if model.tab == .other {
            Text("Kinds the Vault can read but doesn’t show on the main view yet.")
                .scaledFont(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var emptyTitle: String { model.query.isEmpty ? "Nothing here" : "No numbers match" }
    private var emptyMessage: String {
        model.query.isEmpty ? "Numbers that belong here appear after Read Documents, or when you add one."
            : "Search looks at names, notes and kinds in every tab, never at the numbers themselves."
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
                    Text(rowTitle(row))
                        .scaledFont(.body.weight(.semibold))
                        .lineLimit(1)
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
            Button("Quick Look") { quickLook(path, for: row) }
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
            Button("Not a Real Number…", role: .destructive) { removing = .find(find) }
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
        case .usVisa: which = row.facts?.details.first { $0.label == "Visa class" }.map { $0.drawn(shown: true) } ?? "Visa"
        case .uscisCase: which = row.facts?.form ?? (whose == nil ? "USCIS case" : nil)
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
            EmptyStateView(icon: "number", title: "No number chosen", layout: .compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ row: VaultModel.Row) -> some View {
        let shown = model.lock.canShow(row.id, at: model.now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
                .help("Whose this number is. A choice here wins over the name on the document, and later reads keep it.")
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
                        ForEach(Array(facts.details.enumerated()), id: \.offset) { _, detail in
                            detailRow(detail, of: row, shown: shown)
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
                .accessibilityLabel(shown ? "The number" : "The number, hidden")
                .accessibilityValue(Self.spokenNumber(row.value, shown: shown))
            Spacer(minLength: 4)
            // Large Type beside the number, for reading it out on a call; behind Touch ID while
            // the number is hidden, as Show is.
            Button {
                showLargeType(row.id)
            } label: {
                Image(systemName: "textformat.size")
            }
            .help("Large Type: the number big, in groups of four, for reading it out")
            .accessibilityLabel("Large Type")
            if shown {
                Button {
                    copy(row.id)
                } label: {
                    Label(copied == row.id ? "Copied" : "Copy", systemImage: copied == row.id ? "checkmark" : "doc.on.doc")
                }
                .help("Copies the number. It clears from the clipboard after a minute.")
            } else {
                Button {
                    Task { await model.show(row.id) }
                } label: {
                    Label("Show", systemImage: "touchid")
                }
                .help("Shows the number after Touch ID or your password.")
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
                    Button("Not a Real Number…", role: .destructive) { removing = .find(find) }
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
    private func detailRow(_ detail: VaultDetail, of row: VaultModel.Row, shown: Bool) -> some View {
        GridRow {
            Text(detail.label)
                .foregroundStyle(.secondary)
            Text(detail.drawn(shown: shown))
                .fixedSize(horizontal: false, vertical: true)
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
            Text("Documents with this number")
                .scaledFont(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            let documents = Array(row.documents.enumerated())
            let listed = allDocumentsShown == row.id ? documents : Array(documents.prefix(Self.documentsShown))
            ForEach(listed, id: \.element.path) { index, source in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Pill(.mini, tint: index == 0 ? SemanticColor.success : .secondary,
                             text: index == 0 ? "Read from" : source.role)
                            .help(index == 0 ? source.role : "Names this number")
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
                model.tab = .archive
                model.selection = older.first?.id
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
                field("Number") {
                    TextField("Number", text: $draft.value)
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
        case .find(let find): return "Is “\(find.title)” not a real number?"
        case nil: return ""
        }
    }

    private var isConfirming: Bool {
        if case .confirming = editing { return true }
        return false
    }

    private var editorTitle: String {
        switch editing {
        case .new: return "New Number"
        case .confirming: return "Add a Read Number"
        default: return "Edit Number"
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

    /// The footer after a read: "Read 3 new or changed of 812 documents: 1 new number to confirm."
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
        case 1: return "1 new number to confirm"
        default: return "\(count.formatted()) new numbers to confirm"
        }
    }

    // MARK: Acts

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

    /// esc and the ✕ undo one thing at a time: Large Type, then the editor, then the panel.
    private func escape() {
        if largeType != nil {
            largeType = nil
        } else if editing != nil {
            editing = nil
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
        readTask = Task { await model.readDocuments(with: VaultFolderReader(folders: folders), again: again) }
    }

    /// Add Folder…: the same list as Settings ▸ Vault ▸ Folders to Read.
    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Read for Numbers"
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

    private func showLargeType(_ id: UUID) {
        Task { if await model.show(id) { largeType = id } }
    }

    /// A document shows the number in full, so while it is hidden, opening one takes the same
    /// proof as showing the number.
    private func whenShown(_ row: VaultModel.Row, _ act: @escaping () -> Void) {
        Task {
            guard await model.show(row.id) else { return }
            act()
        }
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

// MARK: - Large Type

/// A number drawn big, in fours, for reading out on a call. Letters take the accent so an O and a
/// zero, an I and a one, are told apart at a glance. A click anywhere puts it away.
struct VaultLargeType: View {
    let title: String
    let value: String
    let owner: String
    let accent: Color
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.35))
            VStack(spacing: 14) {
                digits
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                Text("\(title) · \(owner) · letters are in color")
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(.regularMaterial))
            .padding(24)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) in large type")
        .accessibilityAddTraits(.isButton)
    }

    /// One `Text`, so it scales down as a whole when the number is long.
    private var digits: Text {
        var text = Text("")
        for (index, group) in VaultMask.groups(value).enumerated() {
            if index > 0 { text = Text("\(text)  ") }
            for character in group {
                let glyph = Text(String(character)).foregroundStyle(character.isLetter ? accent : Color.primary)
                text = Text("\(text)\(glyph)")
            }
        }
        return text.font(.system(size: 54, weight: .semibold, design: .monospaced))
    }
}
