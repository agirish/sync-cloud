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

    public static func state(_ change: SettingsChange, lookup: SettingsLookup, lists: SettingsLists? = nil) -> State {
        if SettingsLists.ids.contains(change.setting) { return listState(change, lists: lists) }
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
                              lists: SettingsLists? = nil, isHidden: (String) -> Bool = { _ in false },
                              log: SettingsChangeLog = .shared, center: NotificationCenter = .default,
                              confirmRaising: (String) -> Bool) -> SettingsWriter.Outcome {
        if SettingsLists.ids.contains(change.setting) {
            return revertListEdit(change, lists: lists, isHidden: isHidden, log: log, center: center, confirmRaising: confirmRaising)
        }
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

    /// A list edit (TE290 step 8): one item, in or out, put back while it still is.
    private static func listState(_ change: SettingsChange, lists: SettingsLists?) -> State {
        guard let lists, let item = change.target, let after = change.to.map({ $0 == "true" }) else { return .none }
        guard let now = lists.contains(change.setting, scoped: item), now == after else { return .changedSince }
        return .ready(raises: SettingsLists.raises(change.setting, present: !after))
    }

    private static func revertListEdit(_ change: SettingsChange, lists: SettingsLists?, isHidden: (String) -> Bool,
                                       log: SettingsChangeLog, center: NotificationCenter,
                                       confirmRaising: (String) -> Bool) -> SettingsWriter.Outcome {
        guard let lists, case .ready(let raises) = listState(change, lists: lists),
              let item = change.target, let after = change.to.map({ $0 == "true" }) else {
            return .refused("\(change.name) has changed since, so it isn’t put back.")
        }
        let words = SettingsLists.edit(change.setting, SettingsLists.shown(change.setting, item), present: !after, isHidden: isHidden)
        if raises, !confirmRaising("\(change.name): \(words)? That raises Claude’s spending or access.") {
            return .refused("Not changed: you chose Cancel.")
        }
        let outcome = lists.set(change.setting, scoped: item, present: !after)
        guard outcome == .done else { return outcome }
        log.record(SettingsChange(setting: change.setting, target: item, name: change.name,
                                  from: after ? "true" : "false", to: after ? "false" : "true",
                                  fromLabel: nil, toLabel: words, how: .revert))
        let raisesWords = raises ? " This raises Claude’s spending or access." : ""
        center.post(name: didRevert, object: nil,
                    userInfo: ["line": "They \(words) in \(change.name) with Revert in Activity.\(raisesWords)"])
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
