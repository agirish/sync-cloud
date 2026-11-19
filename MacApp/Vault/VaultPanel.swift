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
    }

    @State private var editing: Editing?
    @State private var draft = VaultModel.Draft()
    /// The entry Large Type is showing.
    @State private var largeType: UUID?
    /// The entry whose Copy just ran, for the button's two seconds of "Copied".
    @State private var copied: UUID?
    @State private var confirmingRemoval = false
    @FocusState private var searchFocused: Bool

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
        .onDisappear { model.closed() }
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
            if model.entries.isEmpty, editing == nil {
                EmptyStateView(icon: "lock.doc", title: "Nothing in the Vault yet",
                               message: "Keep the numbers you get asked for here: a passport number, a member ID, a loan number. Each is sealed on this Mac and shown only to you.",
                               primary: .init("Add a Number", systemImage: "plus") { startAdding() })
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
        return ScrollViewReader { scroller in
            ScrollView {
                if model.entries.isEmpty {
                    // The first number is being typed beside this: nothing to list, and nothing
                    // failed to match.
                    Color.clear.frame(height: 1)
                } else if visible.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "No numbers match",
                                   message: "Search looks at names and notes, never at the numbers themselves.",
                                   layout: .compact)
                        .padding(.top, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
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
        .accessibilityLabel("\(entry.title), \(owner(of: entry))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: The chosen number

    @ViewBuilder
    private var side: some View {
        if editing != nil {
            editor
        } else if let entry = model.selectedEntry {
            detail(entry)
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
                    fact("Kind", entry.kind.title)
                    if !entry.note.isEmpty { fact("Note", entry.note) }
                    fact("Added", entry.addedAt.formatted(date: .abbreviated, time: .omitted))
                    if let source = entry.sourcePath { fact("Found in", source) }
                }
                // A row of their own: beside Show and Copy, the third button's label was cut short.
                HStack(spacing: 6) {
                    Button {
                        showLargeType(entry.id)
                    } label: {
                        Label("Large Type", systemImage: "textformat.size")
                    }
                    Button("Edit…") { startEditing(entry) }
                }
                .disabled(model.isAsking)
                noticeText
            }
            .padding(14)
        }
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
                Text(editing == .new ? "New Number" : "Edit Number")
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
                HStack(spacing: 6) {
                    if case .existing = editing {
                        Button("Remove…", role: .destructive) { confirmingRemoval = true }
                    }
                    Spacer()
                    Button("Cancel") { editing = nil }
                    Button("Save") { save() }
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
        .confirmationDialog("Remove “\(draft.title)” from the Vault?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("The number is removed for good. The document it came from isn’t touched.")
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
            hint("esc", "Close")
            Spacer()
            Text("Sealed on this Mac. Never sent to Claude.")
                .foregroundStyle(.secondary)
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
        case nil:
            break
        }
    }

    private func remove() {
        guard case .existing(let id) = editing else { return }
        Task { if await model.delete(id) { editing = nil } }
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
