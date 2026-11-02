import Foundation
import Sync

/// Revert, on a Changed from Chat row in Activity ▸ History (TE290 step 5): a value goes back only
/// while it is still the one set there, so Revert never overwrites a later change.
///
/// Revert is its own row in the record, isn't on any ⌘Z stack, and is told to Claude in an open
/// chat (`didRevert`). One that would raise Claude's spending or access asks once more first.
@MainActor
public enum SettingsRevert {

    /// Posted after a Revert, with the line for Claude in `userInfo["line"]`.
    public static let didRevert = Notification.Name("SettingsRevertDidRevert")

    public enum State: Equatable {
        /// It can go back; `raises` when going back raises Claude's spending or access.
        case ready(raises: Bool)
        /// The setting has changed since, so going back would overwrite that.
        case changedSince
        /// Nothing to put back: a saved rule, a change whose before isn't known, or one hidden.
        case none
    }

    public static func state(_ change: SettingsChange, lookup: SettingsLookup) -> State {
        guard change.how != .rule, let entry = SettingsCatalog.entry(change.setting),
              let before = change.from.flatMap({ value($0, entry) }), let after = change.to.flatMap({ value($0, entry) })
        else { return .none }
        guard lookup.currentValue(entry, target: change.target) == after else { return .changedSince }
        return .ready(raises: entry.raises(from: after, to: before))
    }

    /// Puts the setting back to what it was before `change`, records the Revert, and tells an open
    /// chat. A Revert that raises runs only when `confirmRaising` says yes.
    @discardableResult
    public static func revert(_ change: SettingsChange, lookup: SettingsLookup, writer: SettingsWriter,
                              log: SettingsChangeLog = .shared, center: NotificationCenter = .default,
                              confirmRaising: (String) -> Bool) -> SettingsWriter.Outcome {
        guard case .ready(let raises) = state(change, lookup: lookup), let entry = SettingsCatalog.entry(change.setting),
              let before = change.from.flatMap({ value($0, entry) }), let after = change.to.flatMap({ value($0, entry) })
        else { return .refused("\(change.name) has changed since, so it isn’t put back.") }
        let back = SettingsLookup.label(before, entry)
        if raises, !confirmRaising("Put \(change.name) back to \(back)? That raises Claude’s spending or access.") {
            return .refused("Not changed: you chose Cancel.")
        }
        let outcome = writer.write(entry.id, before, target: change.target)
        guard outcome == .done else { return outcome }
        log.record(SettingsChange(setting: entry.id, target: change.target, name: change.name,
                                  from: after.stored, to: before.stored,
                                  fromLabel: SettingsLookup.label(after, entry), toLabel: back, how: .revert))
        let raisesWords = raises ? " This raises Claude’s spending or access." : ""
        center.post(name: didRevert, object: nil,
                    userInfo: ["line": "They put \(change.name) back to \(back) with Revert in Activity.\(raisesWords)"])
        return .done
    }

    /// A stored value read back in the shape the setting holds.
    static func value(_ text: String, _ entry: SettingEntry) -> SettingValue? {
        switch entry.control {
        case .toggle: text == "true" ? .bool(true) : text == "false" ? .bool(false) : nil
        case .menu(let choices), .segmented(let choices), .swatches(let choices):
            choices.first { $0.value.stored == text }?.value
        case .stepper: Int(text).map(SettingValue.int)
        case .slider: Double(text).map(SettingValue.double)
        default: nil
        }
    }
}
