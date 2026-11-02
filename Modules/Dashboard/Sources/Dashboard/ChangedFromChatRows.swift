import AppKit
import Design
import Settings
import SwiftUI
import Sync

/// **Changed from Chat** in Activity ▸ History (TE290 step 5): every setting changed from Ask
/// Claude's chat, newest first, with Revert while the setting still holds what was set there.
/// Shown only when there is any, above Sync History, as One-Way Sync's entries are.
public struct ChangedFromChatRows: View {
    @ObservedObject var log: SettingsChangeLog
    /// The live values Revert compares with, and the writer it puts one back through.
    let lookup: () -> SettingsLookup
    let writer: () -> SettingsWriter
    /// The names hidden from Claude, whose changes are listed without their words.
    let hiddenNames: () -> [String]
    /// A Revert that raises Claude's spending or access asks once more.
    let confirmRaising: @MainActor (String) -> Bool
    let confirmClear: @MainActor () -> Bool

    @State private var showsAll = false
    /// Redraws when a setting changes anywhere, so each row's Revert follows the live value.
    @State private var tick = 0
    @State private var refusal: String?
    /// The newest shown before *Show older*.
    static let firstShown = 30

    public init(log: SettingsChangeLog = .shared, lookup: @escaping () -> SettingsLookup,
                writer: @escaping () -> SettingsWriter, hiddenNames: @escaping () -> [String],
                confirmRaising: @escaping @MainActor (String) -> Bool = ChangedFromChatRows.ask,
                confirmClear: @escaping @MainActor () -> Bool = ChangedFromChatRows.askToClear) {
        self.log = log
        self.lookup = lookup
        self.writer = writer
        self.hiddenNames = hiddenNames
        self.confirmRaising = confirmRaising
        self.confirmClear = confirmClear
    }

    public var body: some View {
        let changes = log.visible(hiding: hiddenNames())
        VStack(alignment: .leading, spacing: 0) {
            if !changes.isEmpty {
                HStack {
                    Text("Changed from Chat")
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Clear…") { if confirmClear() { log.clear() } }
                        .buttonStyle(.link)
                        .scaledFont(.system(size: 11))
                        .help("Clear this list. The settings stay as they are.")
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                let lookup = self.lookup()
                ForEach(showsAll ? changes : Array(changes.prefix(Self.firstShown))) { change in
                    Divider().padding(.leading, 12)
                    row(change, SettingsRevert.state(change, lookup: lookup))
                }
                if !showsAll, changes.count > Self.firstShown {
                    Button("Show \(changes.count - Self.firstShown) Older") { showsAll = true }
                        .buttonStyle(.link)
                        .scaledFont(.system(size: 11))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        }
        .id(tick)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in tick &+= 1 }
        .alert("Can’t revert", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
    }

    /// "System → Dark · by Claude · 2 Nov 2026, 10:14"
    static func detail(_ change: SettingsChange) -> String {
        [change.valueWords, change.howWords, change.at.formatted(date: .abbreviated, time: .shortened)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func row(_ change: SettingsChange, _ state: SettingsRevert.State) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(change.name).scaledFont(.system(size: 12, weight: .semibold))
                Text(Self.detail(change))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            switch state {
            case .ready(let raises):
                Button(raises ? "Revert ↑" : "Revert") {
                    if case .refused(let why) = SettingsRevert.revert(change, lookup: lookup(), writer: writer(),
                                                                     log: log, confirmRaising: confirmRaising),
                       why != "Not changed: you chose Cancel." {
                        refusal = why
                    }
                }
                .controlSize(.small)
                .help(raises ? "Puts it back as it was. That raises Claude’s spending or access, so it asks first."
                             : "Puts it back as it was before this change")
            case .changedSince:
                Text("Changed since")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("It has changed again since, so Revert would overwrite that")
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    /// Asks before a Revert that raises Claude's spending or access: a change, not a deletion.
    public static func ask(_ message: String) -> Bool {
        NativeAlerts.confirmChange(messageText: "Revert this change?", informativeText: message, confirmTitle: "Revert")
    }

    /// Asks before Clear empties the list, which can't be brought back.
    public static func askToClear() -> Bool {
        NativeAlerts.confirmIrreversible(
            messageText: "Clear Changed from Chat?",
            informativeText: "The list of settings changed from Ask Claude’s chat is cleared, with its Revert buttons. The settings stay as they are.",
            confirmTitle: "Clear")
    }
}
