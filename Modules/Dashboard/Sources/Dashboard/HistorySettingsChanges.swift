import AppKit
import Design
import Settings
import SwiftUI
import Sync

/// **Settings changes in History** (TE290 step 5): every setting changed from Ask Claude's chat,
/// listed in Activity ▸ History among the sync records, by time, with Revert while the setting
/// still holds what was set there. What History needs to list them, filter them and put one back.
@MainActor
public struct HistorySettingsChanges {
    let log: SettingsChangeLog
    /// The live values Revert compares with, and the writer it puts one back through.
    let lookup: () -> SettingsLookup
    let writer: () -> SettingsWriter
    /// The names hidden from Claude, whose changes are listed without their words.
    let hiddenNames: () -> [String]
    /// The lists a list edit's Revert puts an item back in or takes it out of (TE290 step 8).
    let lists: () -> SettingsLists?
    /// People, for a person edit's Revert (TE290 review).
    let people: () -> SettingsPeople?
    /// A Revert that raises Claude's spending or access asks once more.
    let confirmRaising: @MainActor (RemovalPrompt) -> Bool
    let confirmClear: @MainActor () -> Bool

    public init(log: SettingsChangeLog = .shared, lookup: @escaping () -> SettingsLookup,
                writer: @escaping () -> SettingsWriter, hiddenNames: @escaping () -> [String],
                lists: @escaping () -> SettingsLists? = { nil },
                people: @escaping () -> SettingsPeople? = { nil },
                confirmRaising: @escaping @MainActor (RemovalPrompt) -> Bool = HistorySettingsChanges.ask,
                confirmClear: @escaping @MainActor () -> Bool = HistorySettingsChanges.askToClear) {
        self.log = log
        self.lookup = lookup
        self.writer = writer
        self.hiddenNames = hiddenNames
        self.lists = lists
        self.people = people
        self.confirmRaising = confirmRaising
        self.confirmClear = confirmClear
    }

    /// The changes History shows, newest first: those at or after `start` whose name or values
    /// hold `search`, matched as the path filter matches a path. Matched on the words as shown, so
    /// a name hidden from Claude can't be found by typing it.
    static func filter(_ changes: [SettingsChange], search: String, start: Date?) -> [SettingsChange] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return changes.filter { change in
            if let start, change.at < start { return false }
            guard !needle.isEmpty else { return true }
            return change.name.localizedCaseInsensitiveContains(needle)
                || (change.valueWords?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    /// Who made the change, as the row says it: "Claude changed it".
    static func source(_ how: SettingsChange.How) -> String {
        switch how {
        case .claude: "Claude changed it"
        case .card: "You chose it on a card in Ask Claude"
        case .undo: "You undid it in Ask Claude"
        case .redo: "You redid it in Ask Claude"
        case .revert: "You reverted it here"
        case .rule: "You saved it as a rule from a card in Ask Claude"
        }
    }

    /// Whether an item names something hidden from Claude, for the words a Revert tells Claude.
    func isHidden(_ item: String) -> Bool {
        let names = Set(hiddenNames())
        return item.split(separator: "/").contains { names.contains(String($0)) }
    }

    /// Asks before a Revert that raises Claude's spending or access, in the question's own words:
    /// a change, not a deletion. Showing a folder to Claude again asks as Settings' Remove does,
    /// with Cancel the default (decision IP).
    public static func ask(_ prompt: RemovalPrompt) -> Bool {
        if asksAsSettings(prompt) { return prompt.ask() }
        return NativeAlerts.confirmChange(messageText: prompt.messageText, informativeText: prompt.informativeText,
                                          confirmTitle: prompt.confirmTitle)
    }

    /// Whether `prompt` is one of Settings' own questions rather than Revert's, and so asks the way
    /// Settings does.
    static func asksAsSettings(_ prompt: RemovalPrompt) -> Bool {
        prompt.confirmTitle != SettingsRevert.confirmTitle
    }

    /// Asks before Clear Settings Changes empties the list, which can't be brought back.
    public static func askToClear() -> Bool {
        NativeAlerts.confirmIrreversible(
            messageText: "Clear settings changes?",
            informativeText: "The settings changed from Ask Claude’s chat are taken off History, with their Revert buttons. The settings stay as they are, and sync history isn’t affected.",
            confirmTitle: "Clear")
    }
}

/// One settings change in History's list, in a sync record's shape: a glyph, a Setting pill and
/// the time, then what changed and who changed it, with Revert at the end.
struct SettingsChangeHistoryRow: View {
    let change: SettingsChange
    let settings: HistorySettingsChanges
    let density: ListDensity

    /// Redraws when a setting changes anywhere, so Revert follows the live value.
    @State private var tick = 0
    @State private var refusal: String?

    var body: some View {
        let _ = tick
        let state = SettingsRevert.state(change, lookup: settings.lookup(), lists: settings.lists(), people: settings.people())
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "gearshape")
                .scaledFont(.caption)
                .foregroundStyle(SemanticColor.info)
                .frame(width: 18)
                .padding(.top, 2)
            if density == .compact {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    pill
                    what
                    sourceText
                        .lineLimit(1)
                        .truncationMode(.tail)
                    timeText
                        .layoutPriority(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        pill
                        timeText
                    }
                    what
                    sourceText
                }
            }
            Spacer(minLength: 4)
            revert(state)
        }
        .padding(.vertical, density.metrics.flatRowVerticalPadding)
        .accessibilityElement(children: .contain)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in tick &+= 1 }
        .alert("Can’t revert", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
    }

    private var pill: some View {
        Pill(.mini, tint: SemanticColor.info, text: "Setting")
    }

    private var timeText: some View {
        Text(SyncHistoryRow.timeString(change.at))
            .scaledFont(.caption2)
            .foregroundStyle(.secondary)
    }

    /// "Theme  Light → Dark"
    private var what: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(change.name)
                .scaledFont(.subheadline.weight(.semibold))
            if let value = change.valueWords {
                Text(value)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private var sourceText: some View {
        Text(HistorySettingsChanges.source(change.how))
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private func revert(_ state: SettingsRevert.State) -> some View {
        switch state {
        case .ready(let raises):
            Button(raises ? "Revert ↑" : "Revert") {
                if case .refused(let why) = SettingsRevert.revert(change, lookup: settings.lookup(), writer: settings.writer(),
                                                                 lists: settings.lists(), people: settings.people(),
                                                                 isHidden: settings.isHidden, log: settings.log,
                                                                 confirmRaising: settings.confirmRaising),
                   why != "Not changed: you chose Cancel." {
                    refusal = why
                }
            }
            .controlSize(.small)
            .help(raises ? "Puts it back as it was. That raises Claude’s spending or access, so it asks first."
                         : "Puts it back as it was before this change")
        case .changedSince:
            Text("Changed again since")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .help("It has changed again since, so Revert would overwrite that")
        case .none:
            EmptyView()
        }
    }
}
