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
        let pick = row.pick.flatMap { SettingsCatalog.value($0, for: entry) }
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
        switch entry.control {
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

    // MARK: Status

    @ViewBuilder
    private func status(_ index: Int, _ row: AskClaudeSettingCard.Row, _ entry: SettingEntry, _ current: SettingValue?,
                        _ pick: SettingValue?) -> some View {
        let before = row.changedFrom.flatMap { SettingsCatalog.value($0, for: entry) ?? Self.storedValue($0, like: current) }
        if let refusal = row.refusal {
            Label(refusal, systemImage: "exclamationmark.circle")
                .scaledFont(.footnote).foregroundStyle(.red)
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
        } else if let pick, pick != current {
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
