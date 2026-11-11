import Events
import Foundation
import SwiftUI

/// One INFO line for each change committed in the Settings window (logging plan C11):
/// `Settings: Theme: System → Dark (Settings window)`.
///
/// Written where a control commits: a binding's set, a slider's release, a field's submit, a
/// confirmed button. Never by watching the stored keys, which would also catch the menus and
/// shortcuts that share them, Ask Claude (`SettingsWriter` writes its own line, naming its cause)
/// and every key Reset All clears (`SettingsManager.resetAllSettings` writes one line for it).
/// A change whose owner already logs it (a source, an ignore pattern, a person, a survey's choice)
/// gets no second line. People are named there: names stay in the log, and Copy Log for Sharing
/// masks them.
///
/// Values only for a `.plain` entry; any other is named alone, so a key, a hidden folder or what
/// is shared with Claude never reaches the log from here. The log level is left out:
/// `LogLevelSetting.applyRunning` writes its own line.
@MainActor
enum SettingsWindowLog {

    /// The line for a catalog entry moving from `old` to `new`, or nil when nothing moved.
    static func logLine(_ id: String, from old: SettingValue?, to new: SettingValue) -> String? {
        guard old != new, id != "advanced.logLevel", let entry = SettingsCatalog.entry(id) else { return nil }
        guard entry.privacy == .plain else { return logLine(entry.label, "changed") }
        let was = old.map { SettingsLookup.label($0, entry) } ?? "not set"
        return logLine(entry.label, "\(was) → \(SettingsLookup.label(new, entry))")
    }

    /// The line for a setting the catalog doesn't hold yet (TE332's Browse and Edit rows), by the
    /// label Settings shows and its values in Settings' words.
    static func logLine(label: String, from old: String, to new: String) -> String? {
        old == new ? nil : logLine(label, "\(old) → \(new)")
    }

    /// The line for what an action did, in words that carry no value: "saved", "removed".
    static func logLine(_ label: String, _ what: String) -> String {
        "Settings: \(label): \(what) (Settings window)"
    }

    /// Writes the line for a catalog entry's change, if it moved.
    static func log(_ id: String, from old: SettingValue?, to new: SettingValue) {
        if let line = logLine(id, from: old, to: new) { Logger.shared.info(line) }
    }

    /// Writes the line for a setting the catalog doesn't hold yet, if it moved.
    static func log(label: String, from old: String, to new: String) {
        if let line = logLine(label: label, from: old, to: new) { Logger.shared.info(line) }
    }

    /// Writes the line for an action on a catalog entry, by its label.
    static func log(_ id: String, _ what: String) {
        Logger.shared.info(logLine(SettingsCatalog.entry(id)?.label ?? id, what))
    }

    /// Writes the line for an action on a setting the catalog doesn't hold yet.
    static func log(label: String, _ what: String) {
        Logger.shared.info(logLine(label, what))
    }
}

/// A value Settings stores, as the catalog spells it.
protocol SettingValueConvertible: Equatable {
    var settingValue: SettingValue { get }
}

extension Bool: SettingValueConvertible { var settingValue: SettingValue { .bool(self) } }

extension Bool {
    /// A switch's state as `SettingValue` words it, for a row the catalog doesn't hold yet.
    var onOff: String { SettingValue.bool(self).description }
}
extension Int: SettingValueConvertible { var settingValue: SettingValue { .int(self) } }
extension Double: SettingValueConvertible { var settingValue: SettingValue { .double(self) } }
extension String: SettingValueConvertible { var settingValue: SettingValue { .string(self) } }

extension Binding {

    /// This binding, writing the Settings change line when a control sets a new value. For a control
    /// that sets once per change (a switch, a picker, a stepper); not for a slider or a text field,
    /// which set on every step and log at their release or submit instead.
    func loggingSettingsChange(_ id: String, as value: @escaping (Value) -> SettingValue) -> Binding<Value>
    where Value: Equatable {
        Binding(get: { wrappedValue }, set: { new, transaction in
            let old = wrappedValue
            self.transaction(transaction).wrappedValue = new
            if old != new { SettingsWindowLog.log(id, from: value(old), to: value(new)) }
        })
    }

    func loggingSettingsChange(_ id: String) -> Binding<Value> where Value: SettingValueConvertible {
        loggingSettingsChange(id, as: \.settingValue)
    }

    func loggingSettingsChange(_ id: String) -> Binding<Value> where Value: RawRepresentable & Equatable, Value.RawValue == String {
        loggingSettingsChange(id, as: { .string($0.rawValue) })
    }

    /// The same for a setting the catalog doesn't hold yet, worded by `words`.
    func loggingSettingsChange(label: String, words: @escaping (Value) -> String) -> Binding<Value> where Value: Equatable {
        Binding(get: { wrappedValue }, set: { new, transaction in
            let old = wrappedValue
            self.transaction(transaction).wrappedValue = new
            if old != new { SettingsWindowLog.log(label: label, from: words(old), to: words(new)) }
        })
    }
}
