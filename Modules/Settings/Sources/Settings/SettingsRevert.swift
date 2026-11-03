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

    public static func state(_ change: SettingsChange, lookup: SettingsLookup, lists: SettingsLists? = nil,
                             people: SettingsPeople? = nil) -> State {
        if SettingsLists.ids.contains(change.setting) { return listState(change, lists: lists) }
        // A person edited or the order changed is put back as that person, or that order; an
        // added person isn't taken back out here — removing someone asks first, in People.
        if change.setting == "people.add" || change.how == .rule { return .none }
        if change.setting == "people.edit" {
            guard let people, let to = change.to, change.from != nil else { return .none }
            guard case .string(let now)? = people.value("people.edit", target: change.target) else { return .changedSince }
            return SettingsPeople.same(now, to) ? .ready(raises: false) : .changedSince
        }
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
                              lists: SettingsLists? = nil, people: SettingsPeople? = nil,
                              isHidden: (String) -> Bool = { _ in false },
                              log: SettingsChangeLog = .shared, center: NotificationCenter = .default,
                              confirmRaising: (RemovalPrompt) -> Bool) -> SettingsWriter.Outcome {
        if SettingsLists.ids.contains(change.setting) {
            return revertListEdit(change, lists: lists, isHidden: isHidden, log: log, center: center, confirmRaising: confirmRaising)
        }
        if change.setting == "people.edit" {
            guard let people, state(change, lookup: lookup, people: people) == .ready(raises: false), let from = change.from else {
                return .refused("\(change.name) has changed since, so it isn’t put back.")
            }
            let outcome = people.set("people.edit", target: change.target, .string(from))
            guard outcome == .done else { return outcome }
            let words = change.target == nil ? "put People back in the order they were" : "put back \(SettingsPeople.words(from))"
            log.record(SettingsChange(setting: change.setting, target: change.target, name: change.name, from: change.to, to: from,
                                      fromLabel: nil, toLabel: words, how: .revert))
            center.post(name: didRevert, object: nil, userInfo: ["line": "They \(words) in People with Revert in Activity."])
            return .done
        }
        guard case .ready(let raises) = state(change, lookup: lookup), let entry = SettingsCatalog.entry(change.setting),
              let before = change.from.flatMap({ value($0, entry) }), let after = change.to.flatMap({ value($0, entry) })
        else { return .refused("\(change.name) has changed since, so it isn’t put back.") }
        let back = SettingsLookup.label(before, entry)
        // A folder hidden from Claude is never named to it, even one hidden since the change; nor
        // is a source whose own folder is hidden, or a name or path set on it.
        let source = change.target.flatMap { id in lookup.settings?.availableProviders.first { $0.id == id } }
        let sourceHidden = source.map { lookup.isHidden($0.rootPath) } ?? false
        let spokenName = sourceHidden ? "\(entry.label) for \(SettingsLookup.hiddenSource)" : change.name
        let spoken: String
        if entry.privacy == .hiddenFiltered, isHidden(back) || sourceHidden {
            spoken = "a folder hidden from you"
        } else if sourceHidden, case .string = before {
            spoken = "a name hidden from you"
        } else {
            spoken = back
        }
        if raises, !confirmRaising(RemovalPrompt(messageText: "Put \(change.name) back to \(back)?",
                                                 informativeText: "That raises Claude’s spending or access.", confirmTitle: "Revert")) {
            return .refused("Not changed: you chose Cancel.")
        }
        let outcome = writer.write(entry.id, before, target: change.target)
        guard outcome == .done else { return outcome }
        log.record(SettingsChange(setting: entry.id, target: change.target, name: change.name,
                                  from: after.stored, to: before.stored,
                                  fromLabel: SettingsLookup.label(after, entry), toLabel: back, how: .revert))
        let raisesWords = raises ? " This raises Claude’s spending or access." : ""
        center.post(name: didRevert, object: nil,
                    userInfo: ["line": "They put \(spokenName) back to \(spoken) with Revert in Activity.\(raisesWords)"])
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
                                       confirmRaising: (RemovalPrompt) -> Bool) -> SettingsWriter.Outcome {
        guard let lists, case .ready(let raises) = listState(change, lists: lists),
              let item = change.target, let after = change.to.map({ $0 == "true" }) else {
            return .refused("\(change.name) has changed since, so it isn’t put back.")
        }
        let words = SettingsLists.edit(change.setting, SettingsLists.shown(change.setting, item), present: !after, isHidden: isHidden)
        // Showing a folder to Claude again asks in Settings' words (decision IP).
        let shown = SettingsLists.shown(change.setting, item)
        let question = change.setting == "intelligence.hidden"
            ? RemovalPrompt.showToClaude(named: (shown as NSString).lastPathComponent, isFolder: true)
            : RemovalPrompt(messageText: "\(change.name): \(words)?", informativeText: "That raises Claude’s spending or access.",
                            confirmTitle: "Revert")
        if raises, !confirmRaising(question) {
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
        case .text, .folder: .string(text)
        default: nil
        }
    }
}
