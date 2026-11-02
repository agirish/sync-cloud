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
}

/// A card of settings (TE290 step 4a): each row is the setting's real control at its live value,
/// and a click changes the setting. Designed for 240 pt: a switch or a stepper sits beside the
/// name, anything wider goes below it, and every line wraps.
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
            ForEach(Array(card.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.vertical, 8) }
                if let entry = SettingsCatalog.entry(row.id) {
                    rowView(index, row, entry)
                } else {
                    // A later build dropped this id.
                    Text("This setting no longer exists.").scaledFont(.callout).foregroundStyle(.secondary)
                }
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
            status(row, entry, current, pick)
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
    private func status(_ row: AskClaudeSettingCard.Row, _ entry: SettingEntry, _ current: SettingValue?,
                        _ pick: SettingValue?) -> some View {
        let before = row.changedFrom.flatMap { SettingsCatalog.value($0, for: entry) ?? Self.storedValue($0, like: current) }
        if let refusal = row.refusal {
            Label(refusal, systemImage: "exclamationmark.circle")
                .scaledFont(.footnote).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let before, let current, before != current {
            HStack(spacing: 4) {
                Label("Changed · was \(SettingsLookup.label(before, entry))", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                badges(entry, from: before, to: current)
            }
            .scaledFont(.footnote)
            .fixedSize(horizontal: false, vertical: true)
        } else if let pick, pick != current {
            HStack(spacing: 4) {
                Text("Claude suggests \(SettingsLookup.label(pick, entry))").foregroundStyle(.secondary)
                badges(entry, from: current, to: pick)
            }
            .scaledFont(.footnote)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func badges(_ entry: SettingEntry, from old: SettingValue?, to new: SettingValue) -> some View {
        if entry.raises(from: old, to: new) {
            Text("↑ Raises").foregroundStyle(.orange).help("Raises Claude’s spending or access")
        }
        if entry.isLessSafe(from: old, to: new) {
            Text("⚠ Less safe").foregroundStyle(.red).help("Removes a safeguard")
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
