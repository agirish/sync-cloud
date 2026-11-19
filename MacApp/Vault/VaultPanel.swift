import SwiftUI
import AppKit
import Design
import Sync

/// The Vault card's size: one size, held to what the window can show.
enum VaultCardSize {
    static let preferred = CGSize(width: 820, height: 540)
    /// Below this the list and the number beside it stop fitting. The card stops shrinking and
    /// overflows instead, as Settings does: legible beats collapsed.
    static let minimum = CGSize(width: 600, height: 400)
    /// Air kept between the card and the window's edge.
    static let margin: CGFloat = 48
    static let detailWidth: CGFloat = 300

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

    var body: some View {
        GeometryReader { proxy in
            let size = VaultCardSize.fitted(within: proxy.size)
            ZStack {
                OverlayScrim(level: glassLevel)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                VaultCard(model: model, people: people, glassHue: glassHue,
                          onClose: onClose, onOpenSettings: onOpenSettings)
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
            if let entry = model.entries.first(where: { $0.id == largeType }), model.canShow(entry) {
                VaultLargeType(entry: entry, owner: owner(of: entry), accent: glassHue.accentColor) {
                    largeType = nil
                }
            }
        }
        .task {
            readFolders = VaultReadFolders.folders()
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
                Button("Not This", role: .destructive) { model.setAside(find.id) }
            }
        } message: { removal in
            switch removal {
            case .entry(let entry):
                Text(entry.sourcePath == nil
                     ? "The number is removed for good."
                     : "The number is removed for good, and Read Documents won’t offer it again. The document it came from isn’t touched.")
            case .find:
                Text("It comes off To Confirm and isn’t offered again. Settings ▸ Vault can forget the numbers set aside.")
            }
        }
        .alert("Choose folders to read", isPresented: $askingForFolders) {
            Button("Choose Folders…") { addFolders() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Vault reads only the folders you choose, such as the one that holds your passport scans. You can change them later from this button’s arrow or in Settings ▸ Vault.")
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
            searchField
                .frame(width: 210)
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
                               caption: model.lastReading.map { "Read \(Self.documents($0.documents)); none held a number the Vault reads yet." },
                               primary: .init("Add a Number", systemImage: "plus") { startAdding() },
                               secondary: .init("Read Documents", systemImage: "doc.text.viewfinder") { readDocuments() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    filterRow
                    Divider()
                    HStack(spacing: 0) {
                        list
                        Divider()
                        side
                            .frame(width: VaultCardSize.detailWidth)
                    }
                }
            }
        }
    }

    /// Whose numbers to show: everyone, then each person who has one, then the household's own.
    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                filterChip("Everyone", .everyone)
                ForEach(people.filter { model.count(for: .person($0.id)) > 0 }) { person in
                    filterChip(person.displayName, .person(person.id))
                }
                if model.count(for: .household) > 0 {
                    filterChip("Household", .household)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private func filterChip(_ title: String, _ filter: VaultModel.PersonFilter) -> some View {
        let isSelected = model.personFilter == filter
        return Button {
            model.personFilter = filter
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .scaledFont(.subheadline.weight(isSelected ? .semibold : .medium))
                Text(model.count(for: filter).formatted())
                    .scaledFont(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isSelected ? glassHue.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var list: some View {
        let visible = model.visibleEntries
        let finds = model.visibleFinds
        return ScrollViewReader { scroller in
            ScrollView {
                if model.entries.isEmpty, model.finds.isEmpty {
                    // The first number is being typed beside this: nothing to list, and nothing
                    // failed to match.
                    Color.clear.frame(height: 1)
                } else if visible.isEmpty, finds.isEmpty, model.olderFindCount == 0 {
                    EmptyStateView(icon: "magnifyingglass", title: "No numbers match",
                                   message: "Search looks at names and notes, never at the numbers themselves.",
                                   layout: .compact)
                        .padding(.top, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        // Read from documents and not yet added: first, since each is waiting on
                        // a decision.
                        if !finds.isEmpty || model.olderFindCount > 0 {
                            let current = finds.filter { !$0.isOlder }
                            HStack(spacing: 6) {
                                Text("To Confirm")
                                Text(current.count.formatted())
                                    .scaledFont(.caption.weight(.semibold).monospacedDigit())
                            }
                            .scaledFont(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            ForEach(current) { find in
                                findRow(find).id(find.id)
                            }
                            if model.olderFindCount > 0 {
                                olderToggle
                                ForEach(finds.filter(\.isOlder)) { find in
                                    findRow(find).id(find.id)
                                }
                            }
                        }
                        ForEach(VaultEntry.Kind.allCases, id: \.self) { kind in
                            let rows = visible.filter { $0.kind == kind }
                            if !rows.isEmpty {
                                Text(kind.title)
                                    .scaledFont(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                                ForEach(rows) { entry in
                                    row(entry).id(entry.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
            .onChange(of: model.selection) { _, id in
                if let id { scroller.scrollTo(id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: VaultEntry) -> some View {
        let isSelected = model.selection == entry.id
        return Button {
            model.selection = entry.id
            editing = nil
        } label: {
            HStack(spacing: 9) {
                Image(systemName: entry.kind.symbol)
                    .scaledFont(.callout)
                    .foregroundStyle(glassHue.accentColor)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: Radius.chip).fill(.quaternary.opacity(0.5)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .scaledFont(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle(of: entry))
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if entry.isOlder {
                    Pill(.mini, tint: .secondary, text: "Older")
                }
                // An ending, always. See the type's note.
                Text(VaultMask.masked(entry.value))
                    .scaledFont(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Radius.chip)
                .fill(isSelected ? glassHue.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy") { copy(entry.id) }
            Button("Edit…") { startEditing(entry) }
            Divider()
            Button("Remove…", role: .destructive) { removing = .entry(entry) }
        }
        .accessibilityLabel("\(entry.title), \(owner(of: entry))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Older numbers read from documents: a past passport, an earlier I-94. Folded away until
    /// asked for, since the current ones are what a form usually wants.
    private var olderToggle: some View {
        Button {
            model.showsOlderFinds.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .scaledFont(.caption.weight(.semibold))
                    .rotationEffect(.degrees(model.olderFindsShown ? 90 : 0))
                Text("Older")
                Text(model.olderFindCount.formatted())
                    .scaledFont(.caption.weight(.semibold).monospacedDigit())
                Spacer()
            }
            .scaledFont(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Numbers from older documents: expired or run out, replaced by a newer one for the same person, or filed in an Archive folder.")
        .accessibilityLabel(model.olderFindsShown ? "Hide older numbers" : "Show \(model.olderFindCount) older numbers")
    }

    /// "Apr 2026", the month and year a find or entry is dated, for its row.
    /// In UTC, the zone a document's date is read in, so a date never shows as the month before.
    private static func month(_ date: Date?) -> String? {
        date?.formatted(Date.FormatStyle(timeZone: .gmt).month(.abbreviated).year())
    }

    /// A number read from a document: its name, where it was read, and its ending.
    private func findRow(_ find: VaultFind) -> some View {
        let isSelected = model.selection == find.id
        return Button {
            model.selection = find.id
            editing = nil
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "doc.text.viewfinder")
                    .scaledFont(.callout)
                    .foregroundStyle(glassHue.accentColor)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: Radius.chip)
                        .strokeBorder(glassHue.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                VStack(alignment: .leading, spacing: 1) {
                    Text(find.title)
                        .scaledFont(.body.weight(.semibold))
                        .lineLimit(1)
                    Text([Self.month(find.dated), VaultMask.fileName(find.sourcePath)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if find.isOlder {
                    Pill(.mini, tint: .secondary, text: "Older")
                }
                Text(VaultMask.masked(find.value))
                    .scaledFont(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Radius.chip)
                .fill(isSelected ? glassHue.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Review and Add…") { startConfirming(find) }
            Button("Open Document") { NSWorkspace.shared.open(URL(fileURLWithPath: find.sourcePath)) }
            Divider()
            Button("Not This", role: .destructive) { model.setAside(find.id) }
        }
        .accessibilityLabel("\(find.title), \(find.isOlder ? "older, " : "")to confirm")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: The chosen number

    @ViewBuilder
    private var side: some View {
        if editing != nil {
            editor
        } else if let entry = model.selectedEntry {
            detail(entry)
        } else if let find = model.selectedFind {
            findDetail(find)
        } else {
            EmptyStateView(icon: "number", title: "No number chosen", layout: .compact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ entry: VaultEntry) -> some View {
        let shown = model.canShow(entry)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .scaledFont(.title3.weight(.semibold))
                    Text(subtitle(of: entry))
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(model.drawn(entry))
                    .scaledFont(.title2.monospaced().weight(.semibold))
                    .foregroundStyle(shown ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Radius.well)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.well).strokeBorder(.quaternary))
                    .accessibilityLabel(shown ? "The number" : "The number, hidden")
                HStack(spacing: 6) {
                    if !shown {
                        Button {
                            Task { await model.show(entry.id) }
                        } label: {
                            Label("Show", systemImage: "touchid")
                        }
                        .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                    }
                    Button {
                        copy(entry.id)
                    } label: {
                        Label(copied == entry.id ? "Copied" : "Copy",
                              systemImage: copied == entry.id ? "checkmark" : "doc.on.doc")
                    }
                }
                .disabled(model.isAsking)
                if copied == entry.id {
                    Text("Clears from the clipboard in a minute.")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    fact("Belongs to", owner(of: entry))
                    fact("Kind", entry.isOlder ? "\(entry.kind.title), older" : entry.kind.title)
                    if !entry.note.isEmpty { fact("Note", entry.note) }
                    if let dated = entry.dated {
                        fact("Dated", dated.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
                    }
                    fact("Added", entry.addedAt.formatted(date: .abbreviated, time: .omitted))
                    if let source = entry.sourcePath { fact("Found in", foundIn(source, shown: shown)) }
                }
                // A row of their own: beside Show and Copy, the third button's label was cut short.
                HStack(spacing: 6) {
                    Button {
                        showLargeType(entry.id)
                    } label: {
                        Label("Large Type", systemImage: "textformat.size")
                    }
                    Button("Edit…") { startEditing(entry) }
                    Button(role: .destructive) {
                        removing = .entry(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(ShortcutHint.tooltip("Remove…", "⌘⌫"))
                    .accessibilityLabel("Remove")
                }
                .disabled(model.isAsking)
                noticeText
            }
            .padding(14)
        }
    }

    /// A number read from a document, before it is added: check it against the page, then add it
    /// or set it aside.
    private func findDetail(_ find: VaultFind) -> some View {
        let shown = model.canShow(find)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(find.title)
                        .scaledFont(.title3.weight(.semibold))
                    Text(find.isOlder
                         ? "An older number: its document has run out, a newer one of its kind was read for the same person, or it’s in an Archive folder. Add it if a form may ask for a past number."
                         : "Read from a document. Check it against the page, then add it.")
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.drawn(find))
                    .scaledFont(.title2.monospaced().weight(.semibold))
                    .foregroundStyle(shown ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Radius.well)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.well)
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .accessibilityLabel(shown ? "The number" : "The number, hidden")
                HStack(spacing: 6) {
                    if !shown {
                        Button {
                            Task { await model.show(find.id) }
                        } label: {
                            Label("Show", systemImage: "touchid")
                        }
                    }
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: find.sourcePath))
                    } label: {
                        Label("Open Document", systemImage: "doc")
                    }
                }
                .disabled(model.isAsking)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    if !find.note.isEmpty { fact("Note", find.note) }
                    if let dated = find.dated {
                        fact("Dated", dated.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)))
                    }
                    fact("Found in", foundIn(find.sourcePath, shown: shown))
                }
                HStack(spacing: 6) {
                    Button("Review and Add…") { startConfirming(find) }
                        .buttonStyle(.borderedProminent).accentedProminent(glassHue)
                    Button("Not This") { model.setAside(find.id) }
                        .help("Takes it off To Confirm for good. Settings ▸ Vault can forget the numbers set aside.")
                }
                .disabled(model.isAsking)
                noticeText
            }
            .padding(14)
        }
    }

    /// Where a number was read: the whole path while it shows, the file's name with any number in
    /// it cut to its ending while it is hidden.
    private func foundIn(_ path: String, shown: Bool) -> String {
        shown ? (path as NSString).abbreviatingWithTildeInPath : VaultMask.fileName(path)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .scaledFont(.callout)
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
                    Picker("Belongs to", selection: $draft.personID) {
                        Text("Household").tag(String?.none)
                        ForEach(people) { person in
                            Text(person.displayName).tag(String?.some(person.id))
                        }
                    }
                }
                field("Kind") {
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(VaultEntry.Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                }
                field("Note") {
                    TextField("Note", text: $draft.note, prompt: Text("The issuer, or anything else"))
                }
                // The editor hides its controls' labels, as each field is titled above it; this
                // one's label is its own text beside the box.
                HStack(spacing: 6) {
                    Toggle("Older number, kept for reference", isOn: $draft.isOlder)
                        .toggleStyle(.checkbox)
                    Text("Older number, kept for reference")
                        .scaledFont(.callout)
                        .onTapGesture { draft.isOlder.toggle() }
                }
                .help("A past passport or I-94 a form may still ask for. Listed after the current numbers of its kind.")
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
        case .find(let find): return "Set “\(find.title)” aside?"
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
        if case .person(let id) = model.personFilter { blank.personID = id }
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
}

// MARK: - Large Type

/// A number drawn big, in fours, for reading out on a call. Letters take the accent so an O and a
/// zero, an I and a one, are told apart at a glance. A click anywhere puts it away.
struct VaultLargeType: View {
    let entry: VaultEntry
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
                Text("\(entry.title) · \(owner) · letters are in color")
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
        .accessibilityLabel("\(entry.title) in large type")
        .accessibilityAddTraits(.isButton)
    }

    /// One `Text`, so it scales down as a whole when the number is long.
    private var digits: Text {
        var text = Text("")
        for (index, group) in VaultMask.groups(entry.value).enumerated() {
            if index > 0 { text = Text("\(text)  ") }
            for character in group {
                let glyph = Text(String(character)).foregroundStyle(character.isLetter ? accent : Color.primary)
                text = Text("\(text)\(glyph)")
            }
        }
        return text.font(.system(size: 54, weight: .semibold, design: .monospaced))
    }
}
