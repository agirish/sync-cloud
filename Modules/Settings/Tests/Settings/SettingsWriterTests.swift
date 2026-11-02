import Testing
import Foundation
import Design
import Events
import Sync
@testable import Settings

/// Pins how an Ask Claude card changes a setting (TE290 step 4a): through its owner, with the
/// side effect Settings' own control has, and only to a value the setting can hold.
@MainActor
@Suite struct SettingsWriterTests {

    private final class Calls {
        var login: [Bool] = []
        var permissionRequests = 0
        var denied = 0
        var logLevels: [String] = []
        var columnQuestions: [Int] = []
    }

    private func writer(_ defaults: UserDefaults, _ manager: SettingsManager?, _ calls: Calls,
                        permissionDenied: Bool = false, confirmColumns: Bool = false) -> SettingsWriter {
        SettingsWriter(defaults: defaults, settings: manager,
                       setLoginItem: { calls.login.append($0) },
                       requestNotificationPermission: { report in calls.permissionRequests += 1; report(permissionDenied) },
                       applyRunningLogLevel: { calls.logLevels.append($0) },
                       confirmReleasingColumnWidths: { calls.columnQuestions.append($0); return confirmColumns },
                       notificationsDenied: { calls.denied += 1 })
    }

    private func scratch(_ test: String = #function) -> (String, UserDefaults) {
        let name = "SettingsWriterTests.\(test).\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test func aManagedSettingIsSetOnTheManager() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let manager = SettingsManager(userDefaults: defaults)
        let outcome = writer(defaults, manager, Calls()).write("sync.dateTolerance", .double(0))
        #expect(outcome == .done)
        #expect(manager.dateToleranceSeconds == 0)
        #expect(defaults.double(forKey: "dateToleranceSeconds") == 0)
    }

    @Test func aStoredKeyIsWrittenAndAValueThatIsntAChoiceIsRefused() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let w = writer(defaults, nil, Calls())
        #expect(w.write("appearance.theme", .string(AppearanceMode.dark.rawValue)) == .done)
        #expect(defaults.string(forKey: LiquidGlass.appearanceModeKey) == AppearanceMode.dark.rawValue)
        guard case .refused = w.write("appearance.theme", .string("purple")) else { Issue.record("purple was accepted"); return }
        guard case .refused = w.write("readability.textSize", .int(200)) else { Issue.record("200% was accepted"); return }
        #expect(defaults.string(forKey: LiquidGlass.appearanceModeKey) == AppearanceMode.dark.rawValue)
    }

    @Test func turningNotificationsOnAsksMacOSAndReportsADenial() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let calls = Calls()
        writer(defaults, nil, calls, permissionDenied: true).write("general.notifyInBackground", .bool(true))
        #expect(defaults.bool(forKey: GeneralSettings.notifyOnBackgroundCompletionKey))
        #expect(calls.permissionRequests == 1)
        #expect(calls.denied == 1)
        writer(defaults, nil, calls).write("general.notifyInBackground", .bool(false))
        #expect(calls.permissionRequests == 1)
    }

    @Test func theLogLevelTellsTheRunningLogger() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let calls = Calls()
        writer(defaults, nil, calls).write("advanced.logLevel", .string(LogLevel.warning.rawValue))
        #expect(calls.logLevels == [LogLevel.warning.rawValue])
        #expect(defaults.string(forKey: Logger.minimumLevelDefaultsKey) == LogLevel.warning.rawValue)
    }

    @Test func allColumnsAsksBeforeErasingWidthsAndCancelWritesNothing() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        var overrides = ColumnWidthOverrides()
        overrides.widths[1] = 200
        overrides.widths[3] = 140
        defaults.set(overrides.rawValue, forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
        let calls = Calls()
        let refused = writer(defaults, nil, calls, confirmColumns: false)
            .write("readability.columnWidths", .string(ColumnResizeMode.allColumns.rawValue))
        #expect(refused == .refused("Not changed: you chose Cancel."))
        #expect(calls.columnQuestions == [2])
        #expect(defaults.string(forKey: ColumnResizeMode.defaultsKey) == nil)
        #expect(defaults.string(forKey: PaneViewMode.columnWidthOverridesDefaultsKey) == overrides.rawValue)
    }

    /// Settings writes the widths only when they change; so does a card, or every window's
    /// columns hear a change that isn't one.
    @Test func widthsAreWrittenOnlyWhenTheyChange() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let w = writer(defaults, nil, Calls())
        #expect(w.write("readability.columnWidths", .string(ColumnResizeMode.allColumns.rawValue)) == .done)
        #expect(w.write("readability.columnWidths", .string(ColumnResizeMode.eachColumn.rawValue)) == .done)
        #expect(defaults.string(forKey: ColumnResizeMode.defaultsKey) == ColumnResizeMode.eachColumn.rawValue)
        #expect(defaults.object(forKey: PaneViewMode.columnWidthOverridesDefaultsKey) == nil)
    }

    /// TE290 step 9: a source's name and Open at, from a card, as Settings' rows set them.
    private func sources(_ name: String, _ defaults: UserDefaults, root: String) -> SettingsManager {
        let manager = SettingsManager(autoDiscover: false, userDefaults: defaults, overridesDomainName: name,
                                      cloudStorageLister: { .read([]) }, pathValidator: { _ in true })
        manager.availableProviders = [
            CloudProvider(id: "Acct", displayName: "Dropbox", imageName: "cloud", rootPath: root, openAt: "Documents", type: .dropBox),
            CloudProvider(id: "Other", displayName: "OneDrive", imageName: "cloud", rootPath: "/nowhere", type: .oneDrive),
        ]
        return manager
    }

    @Test func aSourcesNameAndOpenAtAreSetAsSettingsSetsThem() throws {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsWriterTests-\(UUID().uuidString)")
        let inside = root.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = sources(name, defaults, root: root.path)
        let w = writer(defaults, manager, Calls())

        #expect(w.write("sources.name", .string("Dropbox (Work)"), target: "Acct") == .done)
        #expect(defaults.string(forKey: "name_override_Acct") == "Dropbox (Work)")
        #expect(w.write("sources.name", .string("OneDrive"), target: "Acct") == .refused("OneDrive is another source’s name."))
        #expect(w.write("sources.name", .string("x")) == .refused("Say which source."))

        #expect(w.write("sources.openAt", .string(inside.path), target: "Acct") == .done)
        #expect(defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") == "Work")
        #expect(w.write("sources.openAt", .string("/Users"), target: "Acct") == .refused("That folder isn’t inside Dropbox."))
        // Undo and Revert hand back the stored, relative form, once discovery has applied the
        // change (as the card waits for it to).
        manager.availableProviders[0] = CloudProvider(id: "Acct", displayName: "Dropbox", imageName: "cloud", rootPath: root.path,
                                                      openAt: "Work", type: .dropBox)
        #expect(w.write("sources.openAt", .string("Documents"), target: "Acct") == .done)
        #expect(defaults.string(forKey: SettingsManager.openAtOverrideKeyPrefix + "Acct") == "Documents")
        #expect(w.write("sources.path", .string("/no/such/folder"), target: "Acct") == .refused("There’s no folder at /no/such/folder."))
    }

    @Test func claudesTextIsOneShortLineWithNothingHiddenInIt() {
        #expect(SettingsWriter.acceptsClaudesText("Dropbox (Work)"))
        #expect(!SettingsWriter.acceptsClaudesText(String(repeating: "a", count: 65)))
        #expect(!SettingsWriter.acceptsClaudesText("Work\nEvil"))
        #expect(!SettingsWriter.acceptsClaudesText("Work\u{202E}xob"))
    }

    @Test func launchAtLoginGoesToTheLoginItem() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let calls = Calls()
        writer(defaults, nil, calls).write("general.launchAtLogin", .bool(true))
        #expect(calls.login == [true])
    }

    @Test func aSourceThatIsntThereIsRefused() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let w = writer(defaults, SettingsManager(userDefaults: defaults), Calls())
        #expect(w.write("sources.enabled", .bool(false), target: "nope") == .refused("There’s no source nope."))
        #expect(w.write("sources.enabled", .bool(false)) == .refused("Say which source."))
    }

    @Test func textIsReadAsTheSettingsOwnValue() throws {
        let theme = try #require(SettingsCatalog.entry("appearance.theme"))
        #expect(SettingsCatalog.value("Dark", for: theme) == .string("dark"))
        #expect(SettingsCatalog.value("dark", for: theme) == .string("dark"))
        let confirm = try #require(SettingsCatalog.entry("sync.confirmTransfer"))
        #expect(SettingsCatalog.value("Off", for: confirm) == .bool(false))
        let size = try #require(SettingsCatalog.entry("readability.textSize"))
        #expect(SettingsCatalog.value("110%", for: size) == .int(110))
        let tolerance = try #require(SettingsCatalog.entry("sync.dateTolerance"))
        #expect(SettingsCatalog.value("1 second", for: tolerance) == .double(1))
        #expect(SettingsCatalog.value("0", for: tolerance) == .double(0))
        let limit = try #require(SettingsCatalog.entry("intelligence.monthlyLimit"))
        #expect(SettingsCatalog.value("$50", for: limit) == .double(50))
        #expect(SettingsCatalog.value("No limit", for: limit) == .double(0))
        #expect(SettingsCatalog.value("Purple", for: theme) == nil)
    }
}
