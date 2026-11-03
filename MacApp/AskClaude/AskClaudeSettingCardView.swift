import Combine
import Design
import Settings
import SwiftUI
import Sync

/// Redraws a settings card whenever a setting may have changed: a preference written anywhere in
/// the app (Settings, the View menu, the toolbar, the panel's shield, another card) or the login
/// item. The card reads its values afresh on each draw, so this only has to say when.
@MainActor
final class AskClaudeSettingsTicker: ObservableObject {
    private var subscriptions: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        // This instance's changes only: a test's scratch suite posts for its own object.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        LoginItemController.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }
}

/// What a settings card needs from the app: the live value of a row, and what a click does.
struct AskClaudeSettingsBridge {
    var read: @MainActor (_ entry: SettingEntry, _ target: String?) -> SettingValue? = { _, _ in nil }
    var targetName: @MainActor (_ target: String) -> String = { $0 }
    var change: @MainActor (_ item: UUID, _ row: Int, _ value: SettingValue) -> Void = { _, _, _ in }
    var openSettings: @MainActor (_ entry: SettingEntry) -> Void = { _ in }
    /// Whether this card's row made the latest change to its setting, so its Undo can't overwrite
    /// a newer one (TE290 step 4b).
    var offersUndo: @MainActor (_ item: UUID, _ row: Int) -> Bool = { _, _ in false }
    var undo: @MainActor (_ item: UUID, _ row: Int) -> Void = { _, _ in }
    /// The at-limit card's Ask Again (TE290 step 6): offered once the limit no longer stops a
    /// question, and sends the one it stopped.
    var canAskAgain: @MainActor () -> Bool = { false }
    var askAgain: @MainActor (_ item: UUID) -> Void = { _ in }
    /// The API key card (TE290 step 7). Whether a key is saved, asked without reading it; a key
    /// typed in the card's field, saved; and a caught message's key, still held, saved or put back.
    var keyIsSaved: @MainActor () -> Bool = { false }
    var saveKey: @MainActor (_ item: UUID, _ row: Int, _ key: String) -> Void = { _, _, _ in }
    var hasCaughtKey: @MainActor (_ item: UUID) -> Bool = { _ in false }
    var saveCaughtKey: @MainActor (_ item: UUID, _ row: Int) -> Void = { _, _ in }
    var editCaught: @MainActor (_ item: UUID) -> Void = { _ in }
    /// A list's rows (TE290 step 8): what is in it now, an item put in or taken out, Hidden from
    /// Claude's Add… (a folder chooser), and whether an item would be hidden from Claude.
    var listItems: @MainActor (_ entry: SettingEntry) -> [String]? = { _ in nil }
    var setListItem: @MainActor (_ item: UUID, _ row: Int, _ value: String, _ present: Bool) -> Void = { _, _, _, _ in }
    var chooseHidden: @MainActor (_ item: UUID, _ row: Int) -> Void = { _, _ in }
    var isHiddenItem: @MainActor (_ value: String) -> Bool = { _ in false }
    /// A folder setting's Choose… (TE290 step 9): the panel opens; Claude never fills a path in.
    var chooseFolder: @MainActor (_ item: UUID, _ row: Int) -> Void = { _, _ in }
    var resetOpenAt: @MainActor (_ item: UUID, _ row: Int) -> Void = { _, _ in }
    /// People (TE290 step 9, part 2): why they can't be changed, if they can't; a person by id; and
    /// a person's fields saved, moved, or added from the card.
    var peopleRefusal: @MainActor () -> String? = { nil }
    var person: @MainActor (_ id: String) -> Person? = { _ in nil }
    var savePerson: @MainActor (_ item: UUID, _ row: Int, _ person: Person) -> Void = { _, _, _ in }
    var movePerson: @MainActor (_ item: UUID, _ row: Int, _ up: Bool) -> Void = { _, _, _ in }
    var addPerson: @MainActor (_ item: UUID, _ row: Int, _ person: Person) -> Void = { _, _, _ in }
    /// A button (TE290 step 10): Settings' question, for one that asks twice, and the press.
    var actionPrompt: @MainActor (_ entry: SettingEntry, _ target: String?) -> RemovalPrompt? = { _, _ in nil }
    var runAction: @MainActor (_ item: UUID, _ row: Int) -> Void = { _, _ in }
}

/// What a change does beyond its value, shown beside it on a card (TE290 step 6): judged from the
/// old value to the new, so the same table badges a click, a suggestion and an Undo.
enum AskClaudeSettingBadge: String, CaseIterable {
    case raises = "↑ Raises"
    case lessSafe = "⚠ Less safe"
    case tightens = "↓ Tightens"
    case rescans = "Rescans"
    case nextLaunch = "Next launch"

    var help: String {
        switch self {
        case .raises: "Raises Claude’s spending or access"
        case .lessSafe: "Removes a safeguard"
        case .tightens: "Lowers Claude’s spending or access; Claude may make this change itself"
        case .rescans: "Both panes rescan once"
        case .nextLaunch: "Takes effect when SyncCloud next opens"
        }
    }

    var color: Color {
        switch self {
        case .raises: .orange
        case .lessSafe: .red
        case .tightens: .green
        case .rescans, .nextLaunch: .secondary
        }
    }

    /// The badges for changing `entry` from `old` to `new`, in the order a card shows them.
    @MainActor static func badges(_ entry: SettingEntry, from old: SettingValue?, to new: SettingValue) -> [Self] {
        guard old != new else { return [] }
        var badges: [Self] = []
        if entry.raises(from: old, to: new) { badges.append(.raises) }
        if entry.isLessSafe(from: old, to: new) { badges.append(.lessSafe) }
        if entry.tier == .directWhenTightening, entry.raises(from: new, to: old ?? new), !entry.raises(from: old, to: new) {
            badges.append(.tightens)
        }
        if entry.effects.contains(.rescans) { badges.append(.rescans) }
        if entry.effects.contains(.nextLaunch) { badges.append(.nextLaunch) }
        return badges
    }
}

/// A card of settings (TE290 step 4a): each row is the setting's real control at its live value,
/// and a click changes the setting. Designed for 240 pt: a switch or a stepper sits beside the
/// name, anything wider goes below it, and every line wraps. Accent color's swatches are
/// Settings' own discs in two rows of six (`AccentSwatchGrid`).
struct AskClaudeSettingCardView: View {
    let itemID: UUID
    let card: AskClaudeSettingCard
    let bridge: AskClaudeSettingsBridge
    let accent: Color
    let hue: LiquidGlassHue
    @StateObject private var ticker = AskClaudeSettingsTicker()
    /// What is typed in an API key field, by row: the view's alone, never the card's.
    @State private var typedKeys: [Int: String] = [:]
    /// A pattern being typed into a list's field, or text into a text field, by row.
    @State private var typedItems: [Int: String] = [:]
    /// The row whose text field has the caret, so leaving one saves it.
    @FocusState private var focusedField: Int?
    /// A person's fields as typed, by row and field, until they're saved.
    @State private var personDrafts: [Int: [PersonField: String]] = [:]
    @FocusState private var personFocus: PersonFocus?
    /// The rows whose question is open, and the hidden folder a list card is asking about. Never
    /// saved: a chat restored later comes back with every question closed.
    @State private var confirming: Set<Int> = []
    @State private var confirmingShow: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = card.title {
                Text(title).scaledFont(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
            }
            if let notice = card.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .scaledFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
            ForEach(Array(card.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.vertical, 8) }
                if let entry = SettingsCatalog.entry(row.id) {
                    rowView(index, row, entry)
                } else {
                    // A later build dropped this id.
                    Text("This setting no longer exists.").scaledFont(.callout).foregroundStyle(.secondary)
                }
            }
            if card.askAgain != nil, bridge.canAskAgain() {
                Button("Ask Again") { bridge.askAgain(itemID) }
                    .buttonStyle(.borderedProminent)
                    .accentedProminent(hue)
                    .controlSize(.small)
                    .help("Sends the question the limit stopped")
                    .padding(.top, 8)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title ?? card.rows.compactMap { SettingsCatalog.entry($0.id)?.label }.joined(separator: ", "))
    }

    @ViewBuilder
    private func rowView(_ index: Int, _ row: AskClaudeSettingCard.Row, _ entry: SettingEntry) -> some View {
        let current = bridge.read(entry, row.target)
        // A list's pick is an item to add, as Claude wrote it (a pattern), not one of its choices.
        let pick = entry.control == .list ? row.pick.map(SettingValue.string) : row.pick.flatMap { SettingsCatalog.value($0, for: entry) }
        let suggesting = pick != nil && pick != current
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name(entry, row)).scaledFont(.callout).bold()
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Settings ▸ \(entry.tabName)") { bridge.openSettings(entry) }
                        .buttonStyle(.link)
                        .scaledFont(.caption)
                        .help("Opens Settings at \(entry.label)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                besideControl(index, entry, current, pick, suggesting)
            }
            belowControl(index, entry, current, pick, suggesting)
            if let help = entry.help {
                Text(help).scaledFont(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            status(index, row, entry, current, pick)
        }
    }

    private func name(_ entry: SettingEntry, _ row: AskClaudeSettingCard.Row) -> String {
        guard let target = row.target else { return entry.label }
        return "\(entry.label) · \(bridge.targetName(target))"
    }

    // MARK: Controls

    @ViewBuilder
    private func besideControl(_ index: Int, _ entry: SettingEntry, _ current: SettingValue?, _ pick: SettingValue?,
                               _ suggesting: Bool) -> some View {
        switch entry.control {
        case .toggle:
            Toggle(entry.label, isOn: Binding(
                get: { current == .bool(true) },
                set: { bridge.change(itemID, index, .bool($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityHint(suggesting ? "Claude suggests \(pick.map { SettingsLookup.label($0, entry) } ?? "")" : "")
        case .stepper(let low, let high, let step):
            let percent: Int = { if case .int(let x)? = current { x } else { 100 } }()
            Stepper(value: Binding(get: { percent }, set: { bridge.change(itemID, index, .int(min(max($0, low), high))) }),
                    in: low...high, step: step) {
                Text("\(percent)%").monospacedDigit().scaledFont(.callout)
            }
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(entry.label)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func belowControl(_ index: Int, _ entry: SettingEntry, _ current: SettingValue?, _ pick: SettingValue?,
                              _ suggesting: Bool) -> some View {
        if entry.id == "people.edit" || entry.id == "people.add" {
            peopleControl(index, entry, pick)
        } else {
            controlBelow(index, entry, current, pick, suggesting)
        }
    }

    @ViewBuilder
    private func controlBelow(_ index: Int, _ entry: SettingEntry, _ current: SettingValue?, _ pick: SettingValue?,
                              _ suggesting: Bool) -> some View {
        switch entry.control {
        case .secret:
            keyControl(index)
        case .list:
            listControl(index, entry, pick)
        case .button(let title):
            actionControl(index, entry, title)
        case .text:
            textControl(index, entry, current, pick)
        case .folder:
            folderControl(index, entry, current)
        case .segmented(let choices):
            Picker(entry.label, selection: Binding(get: { current ?? choices[0].value },
                                                   set: { bridge.change(itemID, index, $0) })) {
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .accentedSegments(hue)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityHint(suggesting ? "Claude suggests \(pick.map { SettingsLookup.label($0, entry) } ?? "")" : "")
        case .swatches(let choices) where Self.hues(choices) != nil:
            AccentSwatchGrid(hues: Self.hues(choices) ?? [], selected: Self.hue(current), suggested: Self.hue(pick)) {
                bridge.change(itemID, index, .string($0.rawValue))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(entry.label)
        case .menu(let choices), .swatches(let choices):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { menu(index, entry, choices, current); useButton(index, entry, pick, suggesting) }
                VStack(alignment: .leading, spacing: 6) { menu(index, entry, choices, current); useButton(index, entry, pick, suggesting) }
            }
        case .slider(let low, let high):
            SettingsCardSlider(value: { if case .double(let x)? = current { x } else { low } }(), range: low...high) {
                bridge.change(itemID, index, .double($0))
            }
            .accessibilityLabel(entry.label)
        default:
            EmptyView()
        }
    }

    /// A pop-up of the setting's choices. Drawn as a menu button titled with the current choice's
    /// short name, not a picker: a picker's pop-up is as wide as its longest item, and Settings'
    /// model labels ("Opus 5.5 — strongest, about twice the cost") would not fit a card at 240 pt.
    /// The items still carry Settings' full labels, with a check on the current one.
    private func menu(_ index: Int, _ entry: SettingEntry, _ choices: [SettingChoice], _ current: SettingValue?) -> some View {
        let shown = current.map { SettingsLookup.label($0, entry) } ?? choices[0].label
        return Menu {
            ForEach(choices, id: \.value) { choice in
                Button { bridge.change(itemID, index, choice.value) } label: {
                    if choice.value == current { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                }
            }
        } label: {
            Text(Self.shortLabel(shown))
        }
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(entry.label)
        .accessibilityValue(shown)
    }

    /// The hues a swatch setting's choices name, in order; nil when any isn't a hue, so the row
    /// falls back to a menu rather than dropping a choice.
    static func hues(_ choices: [SettingChoice]) -> [LiquidGlassHue]? {
        let hues = choices.compactMap { Self.hue($0.value) }
        return hues.count == choices.count ? hues : nil
    }

    static func hue(_ value: SettingValue?) -> LiquidGlassHue? {
        if case .string(let raw)? = value { LiquidGlassHue(rawValue: raw) } else { nil }
    }

    /// A label up to its dash: "Opus 5.5 — strongest, about twice the cost" is "Opus 5.5".
    static func shortLabel(_ label: String) -> String {
        label.components(separatedBy: " — ").first ?? label
    }

    @ViewBuilder
    private func useButton(_ index: Int, _ entry: SettingEntry, _ pick: SettingValue?, _ suggesting: Bool) -> some View {
        if suggesting, let pick {
            let choice = Self.shortLabel(SettingsLookup.label(pick, entry))
            Button("Use \(choice)") { bridge.change(itemID, index, pick) }
                .controlSize(.small)
                .help("Claude’s suggestion")
        }
    }

    // MARK: Buttons

    /// A button (TE290 step 10). One that asks twice opens its question here, in Settings' words,
    /// with Cancel — which Escape presses — and only the red button runs it; nothing on the card
    /// can undo it. A button the card can't run opens Settings at it.
    @ViewBuilder
    private func actionControl(_ index: Int, _ entry: SettingEntry, _ title: String) -> some View {
        let row = card.rows[index]
        if !SettingsActions.ids.contains(entry.id) {
            Button("Open in Settings") { bridge.openSettings(entry) }
                .controlSize(.small)
                .help("\(title) is in Settings ▸ \(entry.tabName)")
        } else if confirming.contains(index), let prompt = bridge.actionPrompt(entry, row.target) {
            confirmation(prompt, cancel: { confirming.remove(index) }) {
                confirming.remove(index)
                bridge.runAction(itemID, index)
            }
        } else {
            Button(title) {
                if bridge.actionPrompt(entry, row.target) != nil { confirming.insert(index) } else { bridge.runAction(itemID, index) }
            }
            .controlSize(.small)
            if entry.tier == .asksTwice {
                Text("Asks once more. Can’t be undone.").scaledFont(.footnote).foregroundStyle(.secondary)
            }
            if entry.raises == .always || entry.lessSafe == .always {
                HStack(spacing: 6) {
                    if entry.raises == .always { Text(AskClaudeSettingBadge.raises.rawValue).foregroundStyle(AskClaudeSettingBadge.raises.color) }
                    if entry.lessSafe == .always { Text(AskClaudeSettingBadge.lessSafe.rawValue).foregroundStyle(AskClaudeSettingBadge.lessSafe.color) }
                }
                .scaledFont(.footnote)
            }
        }
        if let outcome = row.outcome {
            Label(outcome, systemImage: "checkmark.circle")
                .scaledFont(.footnote).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmation(_ prompt: RemovalPrompt, cancel: @escaping () -> Void, confirm: @escaping () -> Void) -> some View {
        AskClaudeSettingConfirmation(prompt: prompt, cancel: cancel, confirm: confirm)
    }

    // MARK: People

    enum PersonField: CaseIterable {
        case name, relationship, fullNames, aliases

        var title: String {
            switch self {
            case .name: "Name"
            case .relationship: "Relationship"
            case .fullNames: "Full names, comma-separated"
            case .aliases: "Also called, comma-separated"
            }
        }
    }

    struct PersonFocus: Hashable {
        let row: Int
        let field: PersonField
    }

    /// A person's fields, as Settings' editor has them, saved on Return or on leaving a field; or
    /// Add Person's, in the card rather than a sheet, so the chat stays where it is.
    @ViewBuilder
    private func peopleControl(_ index: Int, _ entry: SettingEntry, _ pick: SettingValue?) -> some View {
        let row = card.rows[index]
        if let refusal = bridge.peopleRefusal() {
            Label(refusal, systemImage: "lock").scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if entry.id == "people.add" {
            let suggested: String? = { if case .string(let x)? = pick { x } else { nil } }()
            let blank = Person(id: "", displayName: suggested ?? "")
            personFields(index, blank, commits: false)
            Button("Add Person") { bridge.addPerson(itemID, index, draftPerson(index, blank)); personDrafts[index] = nil }
                .controlSize(.small)
                .disabled(draftPerson(index, blank).displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        } else if let target = row.target, let person = bridge.person(target) {
            personFields(index, person, commits: true)
            HStack(spacing: 6) {
                Button("Move Up") { bridge.movePerson(itemID, index, true) }.controlSize(.small)
                Button("Move Down") { bridge.movePerson(itemID, index, false) }.controlSize(.small)
            }
        } else {
            Text("That person isn’t in the list any more.").scaledFont(.footnote).foregroundStyle(.secondary)
        }
        if let outcome = row.outcome {
            HStack(spacing: 4) {
                Label(outcome, systemImage: "checkmark.circle").foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if bridge.offersUndo(itemID, index) {
                    Button("Undo") { bridge.undo(itemID, index) }.controlSize(.small)
                }
            }
            .scaledFont(.footnote)
        }
    }

    @ViewBuilder
    private func personFields(_ index: Int, _ person: Person, commits: Bool) -> some View {
        ForEach(PersonField.allCases, id: \.self) { field in
            TextField(field.title, text: Binding(get: { personDrafts[index]?[field] ?? Self.text(field, of: person) },
                                                 set: { personDrafts[index, default: [:]][field] = $0 }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($personFocus, equals: PersonFocus(row: index, field: field))
                .onSubmit { if commits { commitPerson(index, person) } }
                .accessibilityLabel(field.title)
        }
        .onChange(of: personFocus) { was, now in
            if commits, was?.row == index, now?.row != index { commitPerson(index, person) }
        }
    }

    static func text(_ field: PersonField, of person: Person) -> String {
        switch field {
        case .name: person.displayName
        case .relationship: person.relationship ?? ""
        case .fullNames: person.fullNames.joined(separator: ", ")
        case .aliases: person.aliases.joined(separator: ", ")
        }
    }

    /// The person with what's typed in place of their fields.
    private func draftPerson(_ index: Int, _ person: Person) -> Person {
        let draft = personDrafts[index] ?? [:]
        let list = { (field: PersonField, now: [String]) in
            draft[field].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? now
        }
        return Person(id: person.id, displayName: draft[.name] ?? person.displayName,
                      relationship: draft[.relationship].map { $0.isEmpty ? nil : $0 } ?? person.relationship,
                      fullNames: list(.fullNames, person.fullNames), aliases: list(.aliases, person.aliases))
    }

    private func commitPerson(_ index: Int, _ person: Person) {
        guard personDrafts[index] != nil else { return }
        let edited = draftPerson(index, person)
        personDrafts[index] = nil
        if edited != person { bridge.savePerson(itemID, index, edited) }
    }

    // MARK: Text and folders

    /// A text setting (a source's name, the Loose-files inbox): saved on Return or on leaving the
    /// field, as Settings saves it. Claude's suggestion is a button beside it.
    @ViewBuilder
    private func textControl(_ index: Int, _ entry: SettingEntry, _ current: SettingValue?, _ pick: SettingValue?) -> some View {
        let shown: String = { if case .string(let x)? = current { x } else { "" } }()
        let commit = {
            guard let typed = typedItems[index], typed != shown else { return }
            bridge.change(itemID, index, .string(typed))
            typedItems[index] = nil
        }
        TextField(entry.label, text: Binding(get: { typedItems[index] ?? shown }, set: { typedItems[index] = $0 }))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .onSubmit(commit)
            .focused($focusedField, equals: index)
            .onChange(of: focusedField) { was, now in if was == index, now != index { commit() } }
            .accessibilityLabel(entry.label)
        if case .string(let suggested)? = pick, suggested != shown {
            useButton(index, entry, pick, true)
        }
    }

    /// A folder setting: where it is now, and Choose… — the macOS panel, which doesn't move the
    /// chat. Open at can also go back to the source's default.
    @ViewBuilder
    private func folderControl(_ index: Int, _ entry: SettingEntry, _ current: SettingValue?) -> some View {
        if case .string(let path)? = current {
            Text(path.isEmpty ? "The top of the source" : path)
                .scaledFont(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(path)
        }
        HStack(spacing: 6) {
            Button(entry.id == "sources.addFolder" ? "Add Folder…" : "Choose…") { bridge.chooseFolder(itemID, index) }
                .controlSize(.small)
            if entry.id == "sources.openAt" {
                Button("Reset") { bridge.resetOpenAt(itemID, index) }
                    .controlSize(.small)
                    .help("Opens at the source’s default folder again")
            }
        }
        if let outcome = card.rows[index].outcome {
            Label(outcome, systemImage: "checkmark.circle")
                .scaledFont(.footnote).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Lists

    /// How many of a list's items a card shows; the rest are in Settings.
    static let listShown = 8

    /// A list's rows (TE290 step 8): each item with its remove, an item this card took out struck
    /// through with a way back, Claude's suggested pattern as a switch, and a field to add one.
    /// Hidden from Claude adds only through Add…, a folder chooser.
    @ViewBuilder
    private func listControl(_ index: Int, _ entry: SettingEntry, _ pick: SettingValue?) -> some View {
        let items = bridge.listItems(entry) ?? []
        let removedHere = (card.rows[index].listEdits ?? []).compactMap { edit -> String? in
            guard !edit.present, let item = edit.item else { return nil }
            let shown = SettingsLists.shown(entry.id, item)
            return items.contains(shown) ? nil : shown
        }
        VStack(alignment: .leading, spacing: 4) {
            if items.isEmpty, removedHere.isEmpty {
                Text("Nothing here yet.").scaledFont(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(items.prefix(Self.listShown)), id: \.self) { item in
                if confirmingShow[index] == item {
                    // Settings asks before showing a folder to Claude again (decision IP); so does the card.
                    confirmation(.showToClaude(named: (item as NSString).lastPathComponent, isFolder: true),
                                 cancel: { confirmingShow[index] = nil }) {
                        confirmingShow[index] = nil
                        bridge.setListItem(itemID, index, item, false)
                    }
                } else {
                    listItemRow(entry.id == "intelligence.hidden" ? (item as NSString).lastPathComponent : item, struck: false) {
                        if entry.id == "intelligence.hidden" { confirmingShow[index] = item } else { bridge.setListItem(itemID, index, item, false) }
                    }
                    .help(item)
                }
            }
            if items.count > Self.listShown {
                Text("and \(items.count - Self.listShown) more, in Settings ▸ \(entry.tabName)")
                    .scaledFont(.footnote).foregroundStyle(.secondary)
            }
            ForEach(removedHere, id: \.self) { item in
                listItemRow(item, struck: true) { bridge.setListItem(itemID, index, item, true) }
            }
            if case .string(let suggested)? = pick, SettingsLists.takesClaudesPick(entry.id) {
                Toggle(isOn: Binding(get: { items.contains(suggested) },
                                     set: { bridge.setListItem(itemID, index, suggested, $0) })) {
                    Text("Ignore names matching \(suggested)").scaledFont(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityHint(items.contains(suggested) ? "" : "Claude suggests On")
            }
            if entry.id == "sync.ignorePatterns" {
                HStack(spacing: 6) {
                    TextField("*.tmp, .DS_Store", text: Binding(get: { typedItems[index] ?? "" }, set: { typedItems[index] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { addTyped(index) }
                        .accessibilityLabel("New pattern")
                    Button("Add") { addTyped(index) }
                        .controlSize(.small)
                        .disabled(IgnoreRules.normalized(typedItems[index] ?? "") == nil)
                }
            }
            if entry.id == "intelligence.hidden" {
                Button("Add…") { bridge.chooseHidden(itemID, index) }
                    .controlSize(.small)
                    .help("Choose a folder to hide from Claude. Your next question starts a new chat.")
            }
        }
    }

    private func listItemRow(_ shown: String, struck: Bool, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(shown)
                .scaledFont(.system(.callout, design: .monospaced))
                .strikethrough(struck)
                .foregroundStyle(struck ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: action) {
                Image(systemName: struck ? "arrow.uturn.backward.circle" : "xmark.circle.fill").hoverInk()
            }
            .buttonStyle(.hoverAffordance(.inline))
            .help(struck ? "Put \(shown) back" : "Remove \(shown)")
            .accessibilityLabel(struck ? "Put \(shown) back" : "Remove \(shown)")
        }
    }

    private func addTyped(_ index: Int) {
        guard let pattern = IgnoreRules.normalized(typedItems[index] ?? "") else { return }
        bridge.setListItem(itemID, index, pattern, true)
        typedItems[index] = nil
    }

    // MARK: API key

    /// The API key row: 16 dots for a saved key, as Settings shows it, and a field for a new one.
    /// A message caught holding a key shows it masked, with Save as API Key while the chat still
    /// holds the key.
    @ViewBuilder
    private func keyControl(_ index: Int) -> some View {
        let row = card.rows[index]
        if row.keySaved != true {
            if let caught = card.caught {
                Text(caught)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.control))
            }
            if card.caught != nil, bridge.hasCaughtKey(itemID) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { caughtButtons(index) }
                    VStack(alignment: .leading, spacing: 6) { caughtButtons(index) }
                }
            } else {
                if bridge.keyIsSaved() {
                    Text("Saved key: ••••••••••••••••").scaledFont(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    SecureField("Paste the new sk-ant-… key", text: Binding(get: { typedKeys[index] ?? "" },
                                                                         set: { typedKeys[index] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { saveTyped(index) }
                        .accessibilityLabel("New API key")
                    Button("Save") { saveTyped(index) }
                        .controlSize(.small)
                        .disabled((typedKeys[index] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Paste the key here, not in the message box. It goes to your Keychain; Claude never sees it.")
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func caughtButtons(_ index: Int) -> some View {
        Button("Save as API Key") { bridge.saveCaughtKey(itemID, index) }
            .controlSize(.small)
            .help("Saves the key to your Keychain. The message isn’t sent.")
        Button("Edit Message") { bridge.editCaught(itemID) }
            .controlSize(.small)
            .help("Puts the message back in the text box")
    }

    private func saveTyped(_ index: Int) {
        let key = typedKeys[index] ?? ""
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        bridge.saveKey(itemID, index, key)
        typedKeys[index] = nil
    }

    // MARK: Status

    @ViewBuilder
    private func status(_ index: Int, _ row: AskClaudeSettingCard.Row, _ entry: SettingEntry, _ current: SettingValue?,
                        _ pick: SettingValue?) -> some View {
        let before = row.changedFrom.flatMap { SettingsCatalog.value($0, for: entry) ?? Self.storedValue($0, like: current) }
        if let refusal = row.refusal {
            Label(refusal, systemImage: "exclamationmark.circle")
                .scaledFont(.footnote).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let edits = row.listEdits, !edits.isEmpty {
            let words = edits.suffix(3).map { edit in
                SettingsLists.edit(entry.id, edit.item.map { SettingsLists.shown(entry.id, $0) } ?? "", present: edit.present,
                                   isHidden: bridge.isHiddenItem)
            }
            let more = edits.count > 3 ? " · and \(edits.count - 3) more" : ""
            HStack(spacing: 4) {
                Label("Changed · " + words.joined(separator: " · ") + more, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if bridge.offersUndo(itemID, index), let last = edits.last {
                    let raises = SettingsLists.raises(entry.id, present: !last.present)
                    Button(raises ? "Undo ↑" : "Undo") { bridge.undo(itemID, index) }
                        .controlSize(.small)
                        .help(raises ? "Undoing this raises Claude’s spending or access" : "Undoes the last change here")
                }
            }
            .scaledFont(.footnote)
            if entry.id == "intelligence.hidden", edits.last?.present == true {
                Text("Hidden. Your next question starts a new chat, and the cards above lose their Undo. Their changes stay, in Activity.")
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if row.keySaved == true {
            Label("Saved to your Keychain. Ask Claude and Refine use it from now on.", systemImage: "checkmark.circle")
                .scaledFont(.footnote).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        } else if let before, let current, before != current {
            let changed = row.byClaude == true ? "Changed by Claude" : "Changed"
            HStack(spacing: 4) {
                Label("\(changed) · was \(SettingsLookup.label(before, entry))", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Spacer(minLength: 4)
                if bridge.offersUndo(itemID, index) {
                    // Undoing a change that tightened Claude's reach raises it again: badged, and
                    // only here — Edit ▸ Undo passes over it.
                    let raises = entry.raises(from: current, to: before)
                    Button(raises ? "Undo ↑" : "Undo") { bridge.undo(itemID, index) }
                        .controlSize(.small)
                        .help(raises ? "Undoing this raises Claude’s spending or access" : "Puts \(entry.label) back to \(SettingsLookup.label(before, entry))")
                }
            }
            .scaledFont(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            badges(entry, from: before, to: current)
        } else if let pick, pick != current, entry.control != .list {
            Text("Claude suggests \(SettingsLookup.label(pick, entry))").foregroundStyle(.secondary)
                .scaledFont(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            badges(entry, from: current, to: pick)
        }
    }

    /// The change's badges on a line of their own, under what changed, so a card with several
    /// still fits 240 pt.
    @ViewBuilder
    private func badges(_ entry: SettingEntry, from old: SettingValue?, to new: SettingValue) -> some View {
        let badges = AskClaudeSettingBadge.badges(entry, from: old, to: new)
        if !badges.isEmpty {
            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge.rawValue).foregroundStyle(badge.color).help(badge.help)
                }
            }
            .scaledFont(.footnote)
        }
    }

    /// A remembered value for a setting with no choices (a stepper, a slider), in the shape of the
    /// value it now has.
    static func storedValue(_ text: String, like current: SettingValue?) -> SettingValue? {
        switch current {
        case .int?: Int(text).map(SettingValue.int)
        case .double?: Double(text).map(SettingValue.double)
        case .bool?: text == "true" ? .bool(true) : text == "false" ? .bool(false) : nil
        default: .string(text)
        }
    }
}

/// A slider that writes on release, not while dragging: Tint repaints the panel it sits in, and a
/// value written on every step would chase the pointer.
private struct SettingsCardSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        Slider(value: Binding(get: { dragging ?? value }, set: { dragging = $0 }), in: range) { editing in
            if !editing, let final = dragging {
                commit(final)
                dragging = nil
            }
        }
        .controlSize(.small)
    }
}

/// Settings' question, inside a card (TE290 step 10): Cancel first — Escape presses it — and the
/// red button takes no key, as Settings' own alerts are built.
struct AskClaudeSettingConfirmation: View {
    let prompt: RemovalPrompt
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt.messageText).scaledFont(.callout).bold()
                .fixedSize(horizontal: false, vertical: true)
            Text(prompt.informativeText).scaledFont(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.control))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        Button("Cancel", action: cancel)
            .keyboardShortcut(.cancelAction)
            .controlSize(.small)
        Button(prompt.confirmTitle, role: .destructive, action: confirm)
            .controlSize(.small)
    }
}
