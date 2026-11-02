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
                                              confirmRaising: { asked.append($0); return false })
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
                                      confirmRaising: { asked.append($0); return false }) != .done)
        #expect(asked == ["Hidden from Claude: unhid a folder? That raises Claude’s spending or access."])
        #expect(AskClaudePrivacy.hiddenFolders(in: rig.defaults) == ["/Users/me/Medical"])
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
