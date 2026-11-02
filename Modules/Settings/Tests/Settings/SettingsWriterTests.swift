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
