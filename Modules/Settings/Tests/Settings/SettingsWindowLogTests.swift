import Design
import Events
import Foundation
import SwiftUI
import Sync
import Testing
@testable import Settings

/// The Settings window's change lines (logging plan C11): one INFO line per committed change, a
/// value only for a plain setting, and no second line where an owner already writes one.
@MainActor
@Suite struct SettingsWindowLogTests {

    // MARK: The line

    @Test func aPlainSettingSaysWhatItWasAndIsInSettingsWords() {
        #expect(SettingsWindowLog.logLine("appearance.theme", from: .string("system"), to: .string("dark"))
                == "Settings: Theme: System → Dark (Settings window)")
        #expect(SettingsWindowLog.logLine("sync.confirmDelete", from: .bool(true), to: .bool(false))
                == "Settings: Confirm before deleting: On → Off (Settings window)")
        #expect(SettingsWindowLog.logLine("duplicates.overlap", from: .double(0.7), to: .double(0.9))
                == "Settings: Folders overlap at: 70% → 90% (Settings window)")
        // Nothing moved, nothing to say.
        #expect(SettingsWindowLog.logLine("appearance.theme", from: .string("dark"), to: .string("dark")) == nil)
    }

    @Test func aSecretOrCountedSettingIsNamedWithoutItsValue() throws {
        let key = "sk-ant-api03-\(UUID().uuidString)"
        let secret = try #require(SettingsWindowLog.logLine("intelligence.apiKey", from: nil, to: .string(key)))
        #expect(secret == "Settings: Claude API key: changed (Settings window)")

        let folder = "/Users/someone/Private-\(UUID().uuidString)"
        let hidden = try #require(SettingsWindowLog.logLine("intelligence.hidden", from: .string(""), to: .string(folder)))
        #expect(hidden == "Settings: Hidden from Claude: changed (Settings window)")
        #expect(!hidden.contains(folder))

        // The actions those rows log carry no value either.
        #expect(SettingsWindowLog.logLine("Claude API key", "saved") == "Settings: Claude API key: saved (Settings window)")
    }

    @Test func theLogLevelIsLeftToItsOwnLine() {
        #expect(SettingsWindowLog.logLine("advanced.logLevel", from: .string("info"), to: .string("debug")) == nil)
    }

    @Test func aRowTheCatalogDoesNotHoldYetIsNamedByItsLabel() {
        #expect(SettingsWindowLog.logLine(label: "Wrap lines", from: true.onOff, to: false.onOff)
                == "Settings: Wrap lines: On → Off (Settings window)")
        #expect(SettingsWindowLog.logLine(label: "Wrap lines", from: "On", to: "On") == nil)
    }

    // MARK: What reaches the log

    /// A control's set writes one line, and a set to the same value writes none.
    @Test func aControlsBindingLogsEachChangeOnce() async {
        var stored = 0.5
        let binding = Binding(get: { stored }, set: { stored = $0 }).loggingSettingsChange("duplicates.overlap")
        let lines = await linesWritten {
            binding.wrappedValue = 0.8
            binding.wrappedValue = 0.8
        }
        #expect(stored == 0.8)
        #expect(lines.filter { $0.message.hasSuffix("(Settings window)") }.map(\.message)
                == ["Settings: Folders overlap at: 50% → 80% (Settings window)"], "\(lines.map(\.message))")
        #expect(lines.allSatisfy { $0.level == .info || !$0.message.hasSuffix("(Settings window)") })
    }

    /// A person's change already has its line from the People list, which names them (Copy Log for
    /// Sharing masks it); Settings adds none, so one change is one line.
    @Test func aPersonsRenameIsOneLineFromThePeopleList() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsWindowLog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "t", profile: nil)
        var person = try #require(store.add(displayName: "Rename\(UUID().uuidString.prefix(8))"))
        person.displayName = "Renamed\(UUID().uuidString.prefix(8))"
        let lines = await linesWritten { store.update(person) }
        #expect(lines.filter { $0.message.hasPrefix("People: ") || $0.message.hasSuffix("(Settings window)") }.map(\.message)
                == ["People: updated '\(person.displayName)' (\(person.id))"], "\(lines.map(\.message))")
    }

    /// Reset All writes one line, from the manager; every setting it clears writes none of its own.
    @Test func resetAllIsOneLine() async {
        let test = TestDefaults()
        let settings = test.manager(domain: test.suiteName)
        settings.conflictPolicy = .replace
        test.defaults.set(false, forKey: GeneralSettings.confirmBeforeDeleteKey)
        test.defaults.set(LiquidGlassHue.none.rawValue, forKey: LiquidGlass.hueKey)
        let lines = await linesWritten { settings.resetAllSettings() }
        let reset = lines.filter { $0.message.hasPrefix("User reset all settings to defaults") }
        #expect(reset.count == 1 && reset.first?.level == .info, "\(lines.map(\.message))")
        #expect(!lines.contains { $0.message.hasSuffix("(Settings window)") }, "\(lines.map(\.message))")
    }

    // MARK: Coverage

    /// Every setting the window changes writes its line, or has an owner that writes one. A new
    /// row fails here until it does one or the other.
    @Test func everyChangeableEntryLogsInTheWindowOrHasAnOwnerThatDoes() throws {
        let sources = try ["SettingsView.swift", "GeneralRows.swift", "CloudKeyRow.swift", "NotesForClaudeSection.swift",
                           "AskClaudeSuggestionsSection.swift", "AskClaudeIntroSection.swift", "AskClaudePastChatsSettings.swift", "FolderSurveysSection.swift",
                           "ProviderOptionRows.swift"]
            .map { try settingsSource($0, minLength: 1) }.joined(separator: "\n")
        var missing: [String] = []
        for entry in SettingsCatalog.all where Self.changes(entry) && !Self.loggedByOwner.keys.contains(entry.id) {
            let logged = sources.contains("loggingSettingsChange(\"\(entry.id)\"")
                || sources.contains("SettingsWindowLog.log(\"\(entry.id)\"")
            if !logged { missing.append(entry.id) }
        }
        #expect(missing.isEmpty, "Settings changes these and writes no line: \(missing)")
        // The exclusions are real entries, so a renamed id can't leave a stale pass behind.
        #expect(Self.loggedByOwner.keys.allSatisfy { SettingsCatalog.entry($0) != nil })
    }

    /// Whether the window changes something through this entry: a value it holds, or a button that
    /// alters what is kept. Buttons that only show or open something change nothing.
    private static func changes(_ entry: SettingEntry) -> Bool {
        switch entry.control {
        case .readout: return entry.id == "intelligence.notes"
        case .button: return !showsOrOpens.contains(entry.id)
        default: return true
        }
    }

    private static let showsOrOpens: Set<String> = [
        "general.runSetupAgain", "sources.refresh", "sources.showInFinder", "sources.providerSettings",
        "people.lookForNames", "oneWay.show", "oneWay.setUp", "advanced.logShowInFinder",
        "advanced.logCopyForSharing", "intelligence.apiKeyReveal",
    ]

    /// Changes whose owner writes the line, wherever they are made, and what writes it.
    private static let loggedByOwner: [String: String] = [
        "advanced.logLevel": "LogLevelSetting.applyRunning",
        "advanced.resetAll": "SettingsManager.resetAllSettings",
        "advanced.resetSetup": "ContentView.resetSetupAction",
        "advanced.fileDigestsClear": "AdvancedSettingsTab, User cleared the saved file digests",
        "advanced.storageReportsClear": "AdvancedSettingsTab, User cleared the saved Storage reports",
        "advanced.sweep": "FileSyncManager.sweepOrphanedTempArtifactsNow's banner",
        // Clearing the log empties it: a line written after would be the new log's first.
        "advanced.logClear": "nothing, by choice",
        "sources.addFolder": "SettingsManager.addFolderSource", "sources.removeFolder": "SettingsManager.removeFolderSource",
        "sources.name": "SettingsManager.setCustomName", "sources.path": "SettingsManager.setPath",
        "sources.rootReset": "SettingsManager.resetPath", "sources.openAt": "SettingsManager.setOpenAt",
        "sources.openAtReset": "SettingsManager.resetOpenAt", "sources.enabled": "SettingsManager.setEnabled",
        "sync.ignorePatterns": "SettingsManager.addIgnorePattern / removeIgnorePattern",
        "sync.ignoredItemsClearAll": "IgnoredItemsList's onClear, as sync.ignoredItems",
        "people.edit": "PeopleStore", "people.add": "PeopleStore", "people.remove": "PeopleStore",
        "people.defaultOrder": "PeopleStore", "people.suggestions": "PeopleStore", "people.tryFilename": "reads only",
        "organize.surveys": "FileSyncManager.learnSourceSurvey / setSourceSurveyChoice",
        "organize.keptNames": "KeptNamesStore.stopKeeping", "organize.keptNamesClearAll": "KeptNamesStore.stopKeepingAll",
        "duplicates.keptSeparateShowAgain": "FileSyncManager.forgetAllKeptSeparateGroups",
        "intelligence.apiKeyRemove": "CloudKeyRow, as intelligence.apiKey",
        "intelligence.pastChatsClearAll": "AskClaudePastChatFiles.clearAll",
        "intelligence.savedSuggestionsClear": "FileSyncManager.clearFilingVerdictCache",
        "intelligence.thisMonth": "reads only", "intelligence.organizeShare": "reads only",
        "organize.rules": "reads only", "readability.presets": "Text size and Row spacing, each",
        "oneWay.whenDeleted": "OneWaySyncController", "oneWay.whenEdited": "OneWaySyncController",
        "oneWay.pause": "OneWaySyncController", "oneWay.resume": "OneWaySyncController",
        "oneWay.turnOff": "OneWaySyncController",
    ]

    // MARK: Helpers

    /// What the logger was handed while `body` ran on the main actor, between two markers of its own:
    /// nothing else on the main actor runs in between, so a sibling suite's line can't be counted.
    private func linesWritten(_ body: () -> Void) async -> [LogEntry] {
        let token = UUID().uuidString
        let log = LogCapture()
        Logger.shared.debug("settings-window-log start \(token)")
        body()
        Logger.shared.debug("settings-window-log end \(token)")
        let entries = await log.entries
        guard let start = entries.firstIndex(where: { $0.message == "settings-window-log start \(token)" }),
              let end = entries.firstIndex(where: { $0.message == "settings-window-log end \(token)" }) else { return [] }
        return Array(entries[(start + 1)..<end])
    }
}
