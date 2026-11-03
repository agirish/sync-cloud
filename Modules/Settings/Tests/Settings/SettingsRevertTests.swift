import Foundation
import Testing
import Design
import Sync
@testable import Settings

/// TE290 step 5: Revert puts a setting back only while it still holds what the chat set, asks
/// first when that raises Claude's reach, and is recorded and told to an open chat.
@MainActor
@Suite struct SettingsRevertTests {

    @MainActor private struct Rig {
        let name: String
        let defaults: UserDefaults
        let log: SettingsChangeLog
        let url: URL
        let center = NotificationCenter()

        init(_ test: String) {
            name = "SettingsRevertTests.\(test).\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".json")
            log = SettingsChangeLog(fileURL: url)
        }

        var lookup: SettingsLookup {
            SettingsLookup(defaults: defaults, settings: nil, keyIsSaved: { false }, hiddenCount: { 0 },
                           isHidden: { _ in false }, loginItemIsOn: { false })
        }
        var writer: SettingsWriter { SettingsWriter(defaults: defaults, settings: nil) }

        func done() { wipeDefaultsSuite(name); try? FileManager.default.removeItem(at: url) }
    }

    private func themeToDark() -> SettingsChange {
        SettingsChange(setting: "appearance.theme", name: "Theme", from: "system", to: "dark",
                       fromLabel: "System", toLabel: "Dark", how: .claude)
    }

    @Test func revertPutsItBackOnlyWhileItHoldsWhatWasSet() {
        let rig = Rig(#function); defer { rig.done() }
        rig.defaults.set(AppearanceMode.dark.rawValue, forKey: LiquidGlass.appearanceModeKey)
        let change = themeToDark()
        #expect(SettingsRevert.state(change, lookup: rig.lookup) == .ready(raises: false))

        var lines: [String] = []
        let observer = rig.center.addObserver(forName: SettingsRevert.didRevert, object: nil, queue: nil) {
            lines.append($0.userInfo?["line"] as? String ?? "")
        }
        defer { rig.center.removeObserver(observer) }
        let outcome = SettingsRevert.revert(change, lookup: rig.lookup, writer: rig.writer, log: rig.log,
                                            center: rig.center, confirmRaising: { _ in Issue.record("asked"); return false })
        #expect(outcome == .done)
        #expect(rig.defaults.string(forKey: LiquidGlass.appearanceModeKey) == AppearanceMode.system.rawValue)
        #expect(rig.log.changes.map(\.how) == [.revert])
        #expect(rig.log.changes.first?.valueWords == "Dark → System")
        #expect(lines == ["They put Theme back to System with Revert in Activity."])

        // Now it's System again, not the Dark this change set: nothing to put back.
        #expect(SettingsRevert.state(change, lookup: rig.lookup) == .changedSince)
        #expect(SettingsRevert.revert(change, lookup: rig.lookup, writer: rig.writer, log: rig.log,
                                      center: rig.center, confirmRaising: { _ in true }) != .done)
    }

    @Test func aRevertThatRaisesAsksFirst() {
        let rig = Rig(#function); defer { rig.done() }
        let off = SettingsChange(setting: "intelligence.readsFiles", name: "Let Claude read files", from: "true", to: "false",
                                 fromLabel: "On", toLabel: "Off", how: .claude)
        rig.defaults.set(false, forKey: AskClaudePrivacy.readsFilesKey)
        #expect(SettingsRevert.state(off, lookup: rig.lookup) == .ready(raises: true))
        var asked: [String] = []
        let cancelled = SettingsRevert.revert(off, lookup: rig.lookup, writer: rig.writer, log: rig.log, center: rig.center,
                                              confirmRaising: { asked.append($0.messageText); return false })
        #expect(cancelled != .done)
        #expect(asked.count == 1)
        #expect(rig.defaults.bool(forKey: AskClaudePrivacy.readsFilesKey) == false)
        #expect(rig.log.changes.isEmpty)
        #expect(SettingsRevert.revert(off, lookup: rig.lookup, writer: rig.writer, log: rig.log, center: rig.center,
                                      confirmRaising: { _ in true }) == .done)
        #expect(rig.defaults.bool(forKey: AskClaudePrivacy.readsFilesKey))
    }

    /// TE290 step 8: a list edit goes back one item at a time, while the item still is (or
    /// isn't) there; putting back a hidden folder's unhide asks first.
    @Test func aListEditIsRevertedWhileItStillApplies() {
        let rig = Rig(#function); defer { rig.done() }
        let settings = SettingsManager(userDefaults: rig.defaults)
        let lists = SettingsLists(settings: settings, sync: nil, defaults: rig.defaults)
        #expect(lists.add("sync.ignorePatterns", "~$*") == .done)
        let added = SettingsChange(setting: "sync.ignorePatterns", target: "~$*", name: "Ignored name patterns",
                                   from: "false", to: "true", fromLabel: nil, toLabel: "added ~$*", how: .card)
        #expect(SettingsRevert.state(added, lookup: rig.lookup, lists: lists) == .ready(raises: false))
        #expect(SettingsRevert.state(added, lookup: rig.lookup) == .none)
        #expect(SettingsRevert.revert(added, lookup: rig.lookup, writer: rig.writer, lists: lists, log: rig.log,
                                      center: rig.center, confirmRaising: { _ in Issue.record("asked"); return false }) == .done)
        #expect(!settings.ignorePatterns.contains("~$*"))
        #expect(rig.log.changes.last?.toLabel == "removed ~$*")
        #expect(SettingsRevert.state(added, lookup: rig.lookup, lists: lists) == .changedSince)

        #expect(lists.add("intelligence.hidden", "/Users/me/Medical") == .done)
        let hid = SettingsChange(setting: "intelligence.hidden", target: "/Users/me/Medical", name: "Hidden from Claude",
                                 from: "false", to: "true", fromLabel: nil, toLabel: "hid a folder", how: .card)
        #expect(SettingsRevert.state(hid, lookup: rig.lookup, lists: lists) == .ready(raises: true))
        var asked: [String] = []
        #expect(SettingsRevert.revert(hid, lookup: rig.lookup, writer: rig.writer, lists: lists, log: rig.log, center: rig.center,
                                      confirmRaising: { asked.append($0.messageText); return false }) != .done)
        #expect(asked == ["Show “Medical” to Claude again?"])
        #expect(AskClaudePrivacy.hiddenFolders(in: rig.defaults) == ["/Users/me/Medical"])
    }

    /// TE290 review: a Revert line never names a folder hidden from Claude, even one hidden since.
    @Test func aRevertLineNeverNamesAHiddenFolder() throws {
        let rig = Rig(#function); defer { rig.done() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsRevertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Medical"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Work"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsManager(autoDiscover: false, userDefaults: rig.defaults, overridesDomainName: rig.name,
                                       cloudStorageLister: { .read([]) }, pathValidator: { _ in true })
        settings.availableProviders = [CloudProvider(id: "Acct", displayName: "Dropbox", imageName: "cloud", rootPath: root.path,
                                                     openAt: "Work", type: .dropBox)]
        let lookup = SettingsLookup(defaults: rig.defaults, settings: settings, keyIsSaved: { false }, hiddenCount: { 0 },
                                    isHidden: { _ in false }, loginItemIsOn: { false })
        let moved = SettingsChange(setting: "sources.openAt", target: "Acct", name: "Open at for Dropbox", from: "Medical", to: "Work",
                                   fromLabel: "Medical", toLabel: "Work", how: .card)
        var lines: [String] = []
        let observer = rig.center.addObserver(forName: SettingsRevert.didRevert, object: nil, queue: nil) {
            lines.append($0.userInfo?["line"] as? String ?? "")
        }
        defer { rig.center.removeObserver(observer) }
        #expect(SettingsRevert.revert(moved, lookup: lookup, writer: SettingsWriter(defaults: rig.defaults, settings: settings),
                                      isHidden: { $0.contains("Medical") }, log: rig.log, center: rig.center,
                                      confirmRaising: { _ in true }) == .done)
        #expect(lines == ["They put Open at for Dropbox back to a folder hidden from you with Revert in Activity."])
    }

    /// A source whose own folder is hidden: its Revert line names neither the source nor the name
    /// it goes back to.
    @Test func aRevertLineNeverNamesASourceHiddenFromClaude() throws {
        let rig = Rig(#function); defer { rig.done() }
        let settings = SettingsManager(autoDiscover: false, userDefaults: rig.defaults, overridesDomainName: rig.name,
                                       cloudStorageLister: { .read([]) }, pathValidator: { _ in true })
        settings.availableProviders = [CloudProvider(id: "folder:1", displayName: "Clinic", imageName: "folder",
                                                     rootPath: "/Users/me/Medical Records", type: .localFolder)]
        let lookup = SettingsLookup(defaults: rig.defaults, settings: settings, keyIsSaved: { false }, hiddenCount: { 1 },
                                    isHidden: { $0.hasPrefix("/Users/me/Medical Records") }, loginItemIsOn: { false })
        let renamed = SettingsChange(setting: "sources.name", target: "folder:1", name: "Source name for Medical Records",
                                     from: "Medical Records", to: "Clinic", fromLabel: "Medical Records", toLabel: "Clinic", how: .card)
        var lines: [String] = []
        let observer = rig.center.addObserver(forName: SettingsRevert.didRevert, object: nil, queue: nil) {
            lines.append($0.userInfo?["line"] as? String ?? "")
        }
        defer { rig.center.removeObserver(observer) }
        #expect(SettingsRevert.revert(renamed, lookup: lookup, writer: SettingsWriter(defaults: rig.defaults, settings: settings),
                                      log: rig.log, center: rig.center, confirmRaising: { _ in true }) == .done)
        #expect(lines == ["They put Source name for a source hidden from you back to a name hidden from you with Revert in Activity."])
    }

    /// TE290 review: a person's edit goes back as that person; an added person isn't taken out here.
    @Test func aPersonsEditIsRevertedAndAnAddIsNot() throws {
        let rig = Rig(#function); defer { rig.done() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsRevertTests-people-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let people = SettingsPeople(store: PeopleStore(directory: dir, profileId: "t", profile: nil))
        let jane = try #require(people.add(name: "Jane", relationship: nil, fullNames: [], aliases: []).person)
        let before = try #require(people.value("people.edit", target: jane.id)).stored
        var renamed = jane
        renamed.displayName = "Janet"
        #expect(people.update(renamed) == .done)
        let after = try #require(people.value("people.edit", target: jane.id)).stored
        let edit = SettingsChange(setting: "people.edit", target: jane.id, name: "People", from: before, to: after,
                                  fromLabel: nil, toLabel: "saved Janet", how: .card)
        #expect(SettingsRevert.state(edit, lookup: rig.lookup, people: people) == .ready(raises: false))
        // A row recorded with its keys in another order is still the same person.
        let reordered = SettingsChange(setting: "people.edit", target: jane.id, name: "People", from: before,
                                       to: #"{"fullNames":[],"displayName":"Janet","aliases":[]}"#,
                                       fromLabel: nil, toLabel: "saved Janet", how: .card)
        #expect(SettingsRevert.state(reordered, lookup: rig.lookup, people: people) == .ready(raises: false))
        #expect(SettingsRevert.revert(edit, lookup: rig.lookup, writer: rig.writer, people: people, log: rig.log,
                                      center: rig.center, confirmRaising: { _ in false }) == .done)
        #expect(people.person(named: jane.id)?.displayName == "Jane")
        #expect(SettingsRevert.state(edit, lookup: rig.lookup, people: people) == .changedSince)
        let add = SettingsChange(setting: "people.add", target: jane.id, name: "People", from: "", to: before,
                                 fromLabel: nil, toLabel: "added Jane", how: .card)
        #expect(SettingsRevert.state(add, lookup: rig.lookup, people: people) == .none)
    }

    @Test func aSavedRuleHasNoRevert() {
        let rig = Rig(#function); defer { rig.done() }
        let rule = SettingsChange(setting: "organize.rules", name: "Rule “Tickets”", from: nil, to: nil,
                                  fromLabel: nil, toLabel: nil, how: .rule)
        #expect(SettingsRevert.state(rule, lookup: rig.lookup) == .none)
    }

    @Test func changedListsWhatTheChatChanged() async {
        let rig = Rig(#function); defer { rig.done() }
        var lookup = rig.lookup
        let recent = themeToDark()
        let old = SettingsChange(at: Date().addingTimeInterval(-40 * 86_400), setting: "readability.textSize",
                                 name: "Text size", from: "100", to: "110", fromLabel: "100%", toLabel: "110%", how: .card)
        lookup.changesFromChat = { [recent, old] }
        let answer = await lookup.changed()
        #expect(answer.contains("Changed from chat in the last 30 days, newest first:\nTheme: System → Dark, by Claude, "))
        #expect(!answer.contains("Text size: 100%"))
    }
}
