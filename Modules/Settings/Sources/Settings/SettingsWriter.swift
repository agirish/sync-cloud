import Design
import Events
import Foundation
import Sync

/// Changes a setting from outside Settings — an Ask Claude card (TE290 step 4a) — the way Settings
/// changes it: through its owner, with the same side effect, so nothing is stored without it.
///
/// `SettingsManager` never re-reads the preferences it writes, so a setting it owns is set on the
/// manager, never on the key. The side effects step 0a moved out of the views are called here too:
/// notification permission, the running log level, Column widths' question, the login item.
@MainActor
public struct SettingsWriter {

    /// What a write came to.
    public enum Outcome: Equatable, Sendable {
        case done
        /// Not written, and why, in words for the card and for Claude.
        case refused(String)
    }

    public var defaults: UserDefaults
    public var settings: SettingsManager?
    public var setLoginItem: (Bool) -> Void
    /// Asks macOS for notification permission; reports whether it was denied.
    public var requestNotificationPermission: (@escaping @MainActor (Bool) -> Void) -> Void
    public var applyRunningLogLevel: (String) -> Void
    /// Settings' own question before All columns erases columns sized on their own.
    public var confirmReleasingColumnWidths: (Int) -> Bool
    /// Where a denied notification request is reported.
    public var notificationsDenied: @MainActor () -> Void

    public init(defaults: UserDefaults, settings: SettingsManager?,
                setLoginItem: @escaping (Bool) -> Void = { LoginItemController.shared.setFromUser($0) },
                requestNotificationPermission: @escaping (@escaping @MainActor (Bool) -> Void) -> Void = {
                    BackgroundNotificationPermission.request(report: $0)
                },
                applyRunningLogLevel: @escaping (String) -> Void = LogLevelSetting.applyRunning(raw:),
                confirmReleasingColumnWidths: @escaping (Int) -> Bool = { RemovalPrompt.releaseColumnWidths(count: $0).ask() },
                notificationsDenied: @escaping @MainActor () -> Void = {}) {
        self.defaults = defaults
        self.settings = settings
        self.setLoginItem = setLoginItem
        self.requestNotificationPermission = requestNotificationPermission
        self.applyRunningLogLevel = applyRunningLogLevel
        self.confirmReleasingColumnWidths = confirmReleasingColumnWidths
        self.notificationsDenied = notificationsDenied
    }

    /// The settings a write applies only once the sources are discovered again: reading one
    /// straight after its write still gives the old value (TE290 step 9).
    public static let appliedByDiscovery: Set<String> = ["sources.name", "sources.path", "sources.openAt"]

    /// Writes `value` to the setting `id` (for `target`, when it belongs to one).
    @discardableResult
    public func write(_ id: String, _ value: SettingValue, target: String? = nil) -> Outcome {
        guard let entry = SettingsCatalog.entry(id) else { return .refused("There’s no setting \(id).") }
        guard Self.accepts(entry, value) else {
            return .refused("\(value) isn’t one of \(entry.label)’s choices.")
        }
        switch (entry.id, value) {
        // Owned by SettingsManager: set there, never on the key.
        case ("general.sortPanesBy", .string(let raw)):
            guard let option = SortOption(rawValue: raw), let settings else { return unavailable(entry) }
            settings.defaultSortOption = option
        case ("sources.folderNameRule", .string(let raw)):
            guard let rule = CloudProvider.ProviderType(rawValue: raw), let settings else { return unavailable(entry) }
            settings.folderNameRule = rule
        case ("sync.whenFileExists", .string(let raw)):
            guard let policy = ConflictPolicy(rawValue: raw), let settings else { return unavailable(entry) }
            settings.conflictPolicy = policy
        case ("sync.dateTolerance", .double(let seconds)):
            guard let settings else { return unavailable(entry) }
            settings.dateToleranceSeconds = seconds
        case ("sync.verifySameSize", .bool(let on)):
            guard let settings else { return unavailable(entry) }
            settings.autoVerifySameSizeDuringScan = on
        case ("sync.rescanOnChange", .bool(let on)):
            guard let settings else { return unavailable(entry) }
            settings.rescanWhenFilesChange = on
        case ("sync.ignoreGoogleDriveNewer", .bool(let on)):
            guard let settings else { return unavailable(entry) }
            settings.ignoreGoogleDriveNewerDateOnly = on
        case ("sync.rememberIgnored", .bool(let on)):
            guard let settings else { return unavailable(entry) }
            settings.rememberIgnoredItems = on
        case ("sources.enabled", .bool(let on)):
            guard let settings, let target else { return .refused("Say which source.") }
            guard settings.availableProviders.contains(where: { $0.id == target }) else {
                return .refused("There’s no source \(target).")
            }
            settings.setEnabled(on, for: target)
            // SettingsManager refuses to switch off the last source, silently.
            if settings.isEnabled(target) != on { return .refused("Your only source can’t be turned off.") }

        // A source's name, path and Open at (TE290 step 9), as Settings' rows set them.
        case ("sources.name", .string(let name)):
            guard let settings, let target, settings.availableProviders.contains(where: { $0.id == target }) else {
                return .refused("Say which source.")
            }
            if let other = settings.availableProviders.first(where: { $0.id != target && $0.displayName == name.trimmingCharacters(in: .whitespaces) }) {
                return .refused("\(other.displayName) is another source’s name.")
            }
            settings.setCustomName(name, for: target)
        case ("sources.path", .string(let path)):
            guard let settings, let target else { return .refused("Say which folder source.") }
            guard FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) else {
                return .refused("There’s no folder at \(path).")
            }
            if case .refusedDuplicate(let existing) = settings.setPath(path, for: target) {
                let name = settings.availableProviders.first { $0.id == existing }?.displayName ?? existing
                return .refused("Already a source: \(name).")
            }
        case ("sources.openAt", .string(let folder)):
            guard let settings, let target else { return .refused("Say which source.") }
            // A folder chosen in the panel comes as a full path; Undo and Revert give back the
            // stored form, relative to the source's root.
            let outcome = folder.hasPrefix("/") || folder.hasPrefix("~")
                ? settings.setOpenAt(folder, for: target) : settings.setOpenAtRelative(folder, for: target)
            switch outcome {
            case .refusedOutsideRoot: return .refused("That folder isn’t inside \(settings.availableProviders.first { $0.id == target }?.displayName ?? "the source").")
            case .refusedUnknownSource: return .refused("That source isn’t there right now.")
            default: break
            }

        // Owned elsewhere.
        case ("general.launchAtLogin", .bool(let on)):
            setLoginItem(on)

        // Stored keys whose views did more than store them (step 0a).
        case ("general.notifyInBackground", .bool(let on)):
            defaults.set(on, forKey: GeneralSettings.notifyOnBackgroundCompletionKey)
            if on {
                let denied = notificationsDenied
                requestNotificationPermission { if $0 { denied() } }
            }
        case ("advanced.logLevel", .string(let raw)):
            guard let level = LogLevel(rawValue: raw) else { return unavailable(entry) }
            LogLevelSetting.set(level, in: defaults, applyRunning: applyRunningLogLevel)
        case ("readability.columnWidths", .string(let raw)):
            let stored = defaults.string(forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
            let overrides = stored.flatMap(ColumnWidthOverrides.init(rawValue:)) ?? ColumnWidthOverrides()
            let count = overrides.widths.count
            guard let choice = ColumnResizeChoice.choose(raw, overrides: overrides, confirm: { confirmReleasingColumnWidths(count) }) else {
                return .refused("Not changed: you chose Cancel.")
            }
            defaults.set(choice.mode, forKey: ColumnResizeMode.defaultsKey)
            // Only what changed, as Settings writes it: a write of the same widths is still a
            // defaults change every window's columns react to.
            if choice.overrides != overrides {
                defaults.set(choice.overrides.rawValue, forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
            }

        // Stored keys and nothing more: views bound with @AppStorage see the change themselves.
        default:
            guard case .appStorage(let key, _, _) = entry.storage else {
                return .refused("\(entry.label) can’t be changed from a card yet. It’s in Settings ▸ \(entry.tabName).")
            }
            switch value {
            case .bool(let x): defaults.set(x, forKey: key)
            case .int(let x): defaults.set(x, forKey: key)
            case .double(let x): defaults.set(x, forKey: key)
            case .string(let x): defaults.set(x, forKey: key)
            }
        }
        Logger.shared.info("Settings: \(entry.label) set to \(value) from Ask Claude")
        return .done
    }

    private func unavailable(_ entry: SettingEntry) -> Outcome {
        .refused("\(entry.label) can’t be changed here. It’s in Settings ▸ \(entry.tabName).")
    }

    /// Whether `value` is one the setting can hold: one of its choices, or inside its range.
    static func accepts(_ entry: SettingEntry, _ value: SettingValue) -> Bool {
        switch entry.control {
        case .toggle:
            if case .bool = value { return true }
            return false
        case .menu(let choices), .segmented(let choices), .swatches(let choices):
            return choices.contains { $0.value == value }
        case .stepper(let low, let high, _):
            if case .int(let x) = value { return (low...high).contains(x) }
            return false
        case .slider(let low, let high):
            if case .double(let x) = value { return (low...high).contains(x) }
            return false
        case .text, .folder:
            if case .string = value { return true }
            return false
        default:
            return false
        }
    }

    /// Text Claude offers for a field (TE290 step 9), held to what Settings would take: one line
    /// of up to 64 characters, with no control or direction-changing characters.
    public static func acceptsClaudesText(_ text: String) -> Bool {
        text.count <= 64 && !text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
        }
    }
}

extension SettingsCatalog {

    /// A value given as text — Claude's pick, a stored card value — read as one of the setting's
    /// own: a choice by its stored value or its label, On or Off, a percent.
    public static func value(_ text: String, for entry: SettingEntry) -> SettingValue? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch entry.control {
        case .toggle:
            switch trimmed.lowercased() {
            case "on", "true", "yes": return .bool(true)
            case "off", "false", "no": return .bool(false)
            default: return nil
            }
        case .menu(let choices), .segmented(let choices), .swatches(let choices):
            if let byValue = choices.first(where: { $0.value.stored == trimmed }) { return byValue.value }
            if let byLabel = choices.first(where: { $0.label.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                return byLabel.value
            }
            // A number for a numeric choice: "1" for the 1-second tolerance, "50" for the $50 limit.
            let number = Double(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "$%")))
            return choices.first { choice in
                switch choice.value {
                case .double(let x): x == number
                case .int(let x): number.map { Double(x) == $0 } ?? false
                default: false
                }
            }?.value
        case .stepper:
            return Int(trimmed.replacingOccurrences(of: "%", with: "")).map(SettingValue.int)
        case .slider:
            let number = Double(trimmed.replacingOccurrences(of: "%", with: ""))
            return number.map { .double(trimmed.hasSuffix("%") || $0 > 1 ? $0 / 100 : $0) }
        case .text, .folder:
            return .string(text)
        default:
            return nil
        }
    }
}

extension SettingValue {
    /// The value as stored, for a card to remember it as text.
    public var stored: String {
        switch self {
        case .bool(let x): x ? "true" : "false"
        case .int(let x): String(x)
        case .double(let x): String(x)
        case .string(let x): x
        }
    }
}
