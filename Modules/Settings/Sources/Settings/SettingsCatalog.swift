import Design
import Events
import Foundation
import Sync

// Every control in Settings, as data: what it is, where its value lives, its choices and default,
// who may change it from Ask Claude, and what Claude may be told about it.
//
// One entry per control, not per search-index row: some index rows are headings (People, Cloud
// providers, "Ask Claude"), and the index misses controls a person can change (the Ask Claude
// model, One-Way Sync's two pickers, Ignored items, several Clear and Reset buttons).
// `SettingsCatalogTests` holds the two together: every index row reaches an entry, and every
// stored key a Settings control reads is an entry or on a named exclusion list.
//
// Pure data: nothing here reads or writes a value.

/// A setting's value, in the four shapes Settings stores.
public enum SettingValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var description: String {
        switch self {
        case .bool(let value): value ? "On" : "Off"
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        }
    }
}

/// One choice of a picker: the stored value and the label Settings shows for it.
public struct SettingChoice: Hashable, Sendable {
    public let value: SettingValue
    public let label: String

    public init(_ value: SettingValue, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// The control a card holds for this setting, matching the one Settings shows.
public enum SettingControl: Hashable, Sendable {
    case toggle
    /// Two or three short choices, side by side.
    case segmented([SettingChoice])
    /// A pop-up menu, as Settings uses for longer lists.
    case menu([SettingChoice])
    case stepper(min: Int, max: Int, step: Int)
    case slider(min: Double, max: Double)
    case swatches([SettingChoice])
    case text
    case secret
    case list
    case folder
    /// A button that acts rather than holds a value; the button's title.
    case button(String)
    /// Shown, never set.
    case readout
}

/// Who may change the setting from Ask Claude.
public enum SettingTier: String, Hashable, Sendable, CaseIterable {
    /// Look and feel: Claude changes it when asked, with Undo.
    case direct
    /// Claude may change it itself only to lower its own spending or access.
    case directWhenTightening
    /// Claude shows a card; the person's click is the change.
    case suggested
    /// The card can't undo it: a red button, then a second question in the card.
    case asksTwice
    /// A readout or a lookup; nothing to set.
    case readOnly
    /// Never offered in chat (revealing or copying the key).
    case notInChat
    /// View state the view and go_to tools handle, outside the catalog's cards.
    case viewTools
}

/// Which thing a setting belongs to, when it is not app-wide.
public enum SettingTarget: String, Hashable, Sendable {
    case app
    case source
    case folderSource
    case cloudSource
    case person
    case syncPair
}

/// What Claude may be told of the value.
public enum SettingPrivacy: String, Hashable, Sendable {
    /// The value as it is.
    case plain
    /// Paths and names pass the Hidden from Claude filter: hidden ones are counted, never named.
    case hiddenFiltered
    /// Only how many there are.
    case countOnly
    /// Only whether one is set.
    case secret
}

/// When a change takes effect, beyond "at once".
public struct SettingEffects: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let nextLaunch = SettingEffects(rawValue: 1 << 0)
    public static let rescans = SettingEffects(rawValue: 1 << 1)
    public static let newChat = SettingEffects(rawValue: 1 << 2)
}

/// Where the value lives, and so who writes it.
public enum SettingStorage: Hashable, Sendable {
    /// A preferences key a view binds with `@AppStorage`. `keySource` and `defaultSource` are the
    /// Swift expressions the view writes, so a test can hold the view and this entry together.
    case appStorage(key: String, keySource: String, defaultSource: String)
    /// A key `SettingsManager` owns: written through it, never directly (it never re-reads).
    case settingsManager(key: String)
    /// Stored by another owner: the Keychain, the login item, a file, a store.
    case owner(String)
    /// No value: a button, a heading, a readout.
    case none
}

/// Which way a change has to go to count, for the Raises and Less safe badges.
public enum SettingDirection: Hashable, Sendable {
    case turningOn
    case turningOff
    /// A larger number counts; with `zeroIsUnlimited`, 0 is the largest of all ("No limit", "Off").
    case higher(zeroIsUnlimited: Bool)
    /// A smaller number counts.
    case lower
    /// Moving to a value later in this list counts.
    case laterIn([SettingValue])
    /// Moving to one of these values counts.
    case toAny([SettingValue])
    /// Every use counts (a button).
    case always

    /// Whether moving from `old` to `new` goes this way.
    public func matches(from old: SettingValue?, to new: SettingValue) -> Bool {
        switch self {
        case .turningOn:
            return new == .bool(true) && old != .bool(true)
        case .turningOff:
            return new == .bool(false) && old != .bool(false)
        case .higher(let zeroIsUnlimited):
            guard let a = old.flatMap(Self.number), let b = Self.number(new) else { return false }
            let rank = { (x: Double) in zeroIsUnlimited && x == 0 ? Double.infinity : x }
            return rank(b) > rank(a)
        case .lower:
            guard let a = old.flatMap(Self.number), let b = Self.number(new) else { return false }
            return b < a
        case .laterIn(let order):
            guard let a = old.flatMap({ order.firstIndex(of: $0) }), let b = order.firstIndex(of: new) else { return false }
            return b > a
        case .toAny(let values):
            return values.contains(new) && old.map { !values.contains($0) } ?? true
        case .always:
            return true
        }
    }

    private static func number(_ value: SettingValue) -> Double? {
        switch value {
        case .int(let x): Double(x)
        case .double(let x): x
        default: nil
        }
    }
}

/// One control in Settings.
public struct SettingEntry: Identifiable, Hashable, Sendable {
    /// Stable, for tool calls and saved cards. Never renamed when a label is.
    public let id: String
    /// What Settings shows.
    public let label: String
    /// The search-index rows this entry answers. Empty for a control the index doesn't list.
    public let indexTitles: [String]
    /// Every other title on screen that belongs to it (buttons, a picker's own label).
    public let otherLabels: [String]
    let tab: SettingsView.SettingsTab
    public let storage: SettingStorage
    public let control: SettingControl
    public let defaultValue: SettingValue?
    public let tier: SettingTier
    public let target: SettingTarget
    public let privacy: SettingPrivacy
    public let effects: SettingEffects
    /// Entries that must be on for this one to be enabled.
    public let dependsOn: [String]
    /// A change this way raises Claude's spending or access.
    public let raises: SettingDirection?
    /// A change this way removes a safeguard.
    public let lessSafe: SettingDirection?
    /// Settings' own help text, word for word, where it has one.
    public let help: String?

    /// The tab's name as the rail shows it.
    public var tabName: String { tab.displayName }

    public func raises(from old: SettingValue?, to new: SettingValue) -> Bool {
        raises?.matches(from: old, to: new) ?? false
    }

    public func isLessSafe(from old: SettingValue?, to new: SettingValue) -> Bool {
        lessSafe?.matches(from: old, to: new) ?? false
    }

    /// What this entry holds when the entries that depend on it are disabled: a switch's Off, or
    /// Accent color's None, under which Settings disables Tint.
    public var offValue: SettingValue {
        id == "appearance.accent" ? .string(LiquidGlassHue.none.rawValue) : .bool(false)
    }
}

@MainActor
public enum SettingsCatalog {

    public static func entry(_ id: String) -> SettingEntry? { byID[id] }

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    // swiftlint:disable function_body_length
    public static let all: [SettingEntry] = [
        // MARK: General
        e("general.launchAtLogin", .general, "Launch SyncCloud at login", indexed: true,
          storage: .owner("LoginItemController"), control: .toggle, default: .bool(false), tier: .suggested,
          help: "Adds SyncCloud to your Mac’s Login Items, so it opens when you log in."),
        e("general.showHiddenByDefault", .general, "Show hidden files by default", indexed: true,
          storage: app(GeneralSettings.showHiddenByDefaultKey, "GeneralSettings.showHiddenByDefaultKey", "false"),
          control: .toggle, default: .bool(false), tier: .suggested, effects: .nextLaunch,
          raises: .turningOn,
          help: "Starts each launch with hidden files shown in both panes. Showing or hiding them while you work lasts until you quit."),
        e("general.reopenPanes", .general, "Reopen panes where I left off", indexed: true,
          storage: app(GeneralSettings.restoreLastFocusKey, "GeneralSettings.restoreLastFocusKey", "true"),
          control: .toggle, default: .bool(true), tier: .suggested, effects: .nextLaunch,
          help: "Reopens each pane with the tabs and folders it had when you last quit. Off, every pane starts with one tab at its source’s opening folder."),
        e("general.sortPanesBy", .general, "Sort panes by", indexed: true,
          storage: .settingsManager(key: "defaultSortOption"),
          control: .menu(["Name", "Kind", "Date Modified", "Size", "Tags"].map { SettingChoice(.string($0), $0) }),
          default: .string("Name"), tier: .direct),
        e("general.notifyInBackground", .general, "Notify when operations finish in the background", indexed: true,
          storage: app(GeneralSettings.notifyOnBackgroundCompletionKey, "GeneralSettings.notifyOnBackgroundCompletionKey", "false"),
          control: .toggle, default: .bool(false), tier: .suggested,
          help: "Posts a system notification when a copy, sync, or verify finishes while SyncCloud isn’t the active app. Turning it on asks macOS for permission."),
        e("general.warnBeforeQuit", .general, "Warn before quitting during file operations", indexed: true,
          storage: app(GeneralSettings.warnBeforeQuitKey, "GeneralSettings.warnBeforeQuitKey", "true"),
          control: .toggle, default: .bool(true), tier: .suggested, lessSafe: .turningOff,
          help: "Asks before quitting while a copy, move, or delete is still running. Off, SyncCloud quits at once."),
        e("general.runSetupAgain", .general, "Run Setup Again", indexed: true, others: ["Run Setup Again…"],
          control: .button("Run Setup Again…"), tier: .suggested),

        // MARK: Appearance
        e("appearance.theme", .appearance, "Theme", indexed: true,
          storage: app(LiquidGlass.appearanceModeKey, "LiquidGlass.appearanceModeKey", "AppearanceMode.system.rawValue"),
          control: .segmented([.init(.string("system"), "System"), .init(.string("light"), "Light"), .init(.string("dark"), "Dark")]),
          default: .string(AppearanceMode.system.rawValue), tier: .direct),
        e("appearance.accent", .appearance, "Accent color", indexed: true,
          storage: app(LiquidGlass.hueKey, "LiquidGlass.hueKey", "LiquidGlassHue.blue.rawValue"),
          control: .swatches(LiquidGlassHue.allCases.map { SettingChoice(.string($0.rawValue), $0.rawValue.capitalized) }),
          default: .string(LiquidGlassHue.blue.rawValue), tier: .direct),
        e("appearance.glass", .appearance, "Glass effect", indexed: true,
          storage: app(LiquidGlass.levelKey, "LiquidGlass.levelKey", "GlassLevel.frosted.rawValue"),
          control: .segmented(GlassLevel.allCases.map { SettingChoice(.string($0.rawValue), $0.rawValue.capitalized) }),
          default: .string(GlassLevel.frosted.rawValue), tier: .direct),
        e("appearance.tint", .appearance, "Tint", index: ["Surface tint"],
          storage: app(LiquidGlass.tintKey, "LiquidGlass.tintKey", "0"),
          control: .slider(min: 0, max: 1), default: .double(0), tier: .direct, dependsOn: ["appearance.accent"]),
        e("appearance.surface", .appearance, "Content surface", index: ["Content surface style"],
          storage: app(LiquidGlass.surfaceStyleKey, "LiquidGlass.surfaceStyleKey", "SurfaceStyle.unified.rawValue"),
          control: .segmented([.init(.string(SurfaceStyle.unified.rawValue), "Unified"), .init(.string(SurfaceStyle.cards.rawValue), "Cards")]),
          default: .string(SurfaceStyle.unified.rawValue), tier: .direct),

        // MARK: Readability
        e("readability.presets", .readability, "Size & spacing", indexed: true,
          // Nothing of its own to set: it sets Text size and Row spacing, which Claude can.
          control: .menu(SizePreset.all.map { SettingChoice(.string($0.id), "\($0.fontSize.percent)%, \($0.density.rawValue)") }),
          tier: .readOnly),
        e("readability.textSize", .readability, "Text size", indexed: true,
          storage: app(FontSize.defaultsKey, "FontSize.defaultsKey", "FontSize.medium.percent"),
          control: .stepper(min: FontSize.minimumPercent, max: FontSize.maximumPercent, step: FontSize.step),
          default: .int(FontSize.medium.percent), tier: .direct),
        e("readability.rowSpacing", .readability, "Row spacing", indexed: true,
          storage: app(ListDensity.defaultsKey, "ListDensity.defaultsKey", "ListDensity.comfortable.rawValue"),
          control: .segmented([.init(.string(ListDensity.comfortable.rawValue), "Comfortable"), .init(.string(ListDensity.compact.rawValue), "Compact")]),
          default: .string(ListDensity.comfortable.rawValue), tier: .direct),
        e("readability.columnWidths", .readability, "Column widths", indexed: true,
          storage: .appStorage(key: ColumnResizeMode.defaultsKey, keySource: "ColumnResizeMode.defaultsKey",
                               defaultSource: "ColumnResizeMode.default.rawValue"),
          control: .segmented([.init(.string(ColumnResizeMode.eachColumn.rawValue), "Each column"),
                               .init(.string(ColumnResizeMode.allColumns.rawValue), "All columns")]),
          default: .string(ColumnResizeMode.default.rawValue), tier: .suggested),

        // MARK: Sources
        e("sources.refresh", .providers, "Refresh", index: ["Cloud providers"], control: .button("Refresh"), tier: .suggested),
        e("sources.addFolder", .providers, "Add Folder…", index: ["Local folders"], control: .folder, tier: .suggested),
        e("sources.removeFolder", .providers, "Remove…", control: .button("Remove…"), tier: .asksTwice,
          target: .folderSource, lessSafe: .always),
        e("sources.showInFinder", .providers, "Show in Finder", control: .button("Show in Finder"), tier: .suggested,
          target: .source),
        e("sources.folderNameRule", .providers, "Check folder names against", indexed: true,
          storage: .settingsManager(key: "folderNameRuleProvider"),
          control: .menu([.init(.string(CloudProvider.ProviderType.oneDrive.rawValue), "OneDrive (strictest)"),
                          .init(.string(CloudProvider.ProviderType.dropBox.rawValue), "Dropbox"),
                          .init(.string(CloudProvider.ProviderType.localFolder.rawValue), "Don’t check")]),
          default: .string(CloudProvider.ProviderType.oneDrive.rawValue), tier: .suggested),
        e("sources.name", .providers, "Source name", index: ["Source name", "Display name"],
          storage: .settingsManager(key: "name_override_<id>"), control: .text, tier: .suggested, target: .source),
        e("sources.path", .providers, "Synchronized path", indexed: true, others: ["Browse…"],
          storage: .settingsManager(key: "folderSources"), control: .folder, tier: .suggested,
          target: .folderSource, privacy: .hiddenFiltered, dependsOn: ["sources.enabled"]),
        e("sources.rootReset", .providers, "Reset root", control: .button("Reset"), tier: .suggested, target: .cloudSource),
        e("sources.openAt", .providers, "Open at", indexed: true, others: ["Choose…"],
          storage: .settingsManager(key: "openAt_override_<id>"), control: .folder, tier: .suggested,
          target: .cloudSource, privacy: .hiddenFiltered, dependsOn: ["sources.enabled"]),
        e("sources.openAtReset", .providers, "Reset Open at", control: .button("Reset"), tier: .suggested, target: .cloudSource),
        e("sources.providerSettings", .providers, "Provider settings", control: .button("Settings"), tier: .suggested,
          target: .cloudSource),
        e("sources.enabled", .providers, "Enable or disable a source", indexed: true,
          storage: .settingsManager(key: "disabledProviderIds"), control: .toggle, default: .bool(true), tier: .suggested,
          target: .source, raises: .turningOn, lessSafe: .turningOff),

        // MARK: People
        e("people.edit", .people, "People", indexed: true, others: ["Edit…", "Move Up", "Move Down"],
          storage: .owner("PeopleStore"), control: .list, tier: .suggested, target: .person),
        e("people.defaultOrder", .people, "Use Default Order", control: .button("Use Default Order"), tier: .suggested),
        e("people.remove", .people, "Remove person", control: .button("Remove…"), tier: .asksTwice, target: .person,
          lessSafe: .always),
        e("people.lookForNames", .people, "Look for Names", others: ["Show Their Files"],
          control: .button("Look for Names"), tier: .suggested),
        e("people.add", .people, "Add Person…", indexed: true, storage: .owner("PeopleStore"), control: .text, tier: .suggested),
        e("people.suggestions", .people, "Suggested names", others: ["Add", "Not a Name"],
          control: .button("Add"), tier: .suggested),
        e("people.tryFilename", .people, "Try a filename", indexed: true, control: .readout, tier: .readOnly),

        // MARK: Sync
        e("oneWay.whenDeleted", .sync, "If a Dropbox file is deleted, renamed or moved", index: ["One-Way Sync"],
          storage: .owner("OneWaySyncStore"),
          control: .menu([.init(.string(OneWaySyncSettings.WhenDeletedRenamedOrMoved.matchICloud.rawValue), "Match iCloud"),
                          .init(.string(OneWaySyncSettings.WhenDeletedRenamedOrMoved.askMe.rawValue), "Ask Me")]),
          tier: .suggested, target: .syncPair,
          lessSafe: .toAny([.string(OneWaySyncSettings.WhenDeletedRenamedOrMoved.matchICloud.rawValue)])),
        e("oneWay.whenEdited", .sync, "If a Dropbox file is edited", storage: .owner("OneWaySyncStore"),
          control: .menu([.init(.string(OneWaySyncSettings.WhenEdited.askMe.rawValue), "Ask Me"),
                          .init(.string(OneWaySyncSettings.WhenEdited.useICloud.rawValue), "Use iCloud’s")]),
          tier: .suggested, target: .syncPair,
          lessSafe: .toAny([.string(OneWaySyncSettings.WhenEdited.useICloud.rawValue)])),
        e("oneWay.pause", .sync, "Pause", others: ["Sync Now"], control: .button("Pause"), tier: .suggested, target: .syncPair),
        e("oneWay.resume", .sync, "Resume…", control: .button("Resume…"), tier: .suggested, target: .syncPair),
        e("oneWay.show", .sync, "Show…", others: ["Show", "Choose Items to Empty…"], control: .button("Show…"),
          tier: .suggested, target: .syncPair),
        e("oneWay.setUp", .sync, "Set Up One-Way Sync…", others: ["Choose Folders…"],
          control: .button("Set Up One-Way Sync…"), tier: .suggested),
        e("oneWay.turnOff", .sync, "Turn Off One-Way Sync…", others: ["Sync From This Mac Instead…"],
          control: .button("Turn Off One-Way Sync…"),
          tier: .asksTwice, target: .syncPair, lessSafe: .always),
        e("sync.whenFileExists", .sync, "When a file already exists", indexed: true,
          storage: .settingsManager(key: ConflictPolicy.defaultsKey),
          control: .menu([.init(.string(ConflictPolicy.ask.rawValue), "Ask every time"),
                          .init(.string(ConflictPolicy.keepBoth.rawValue), "Keep both"),
                          .init(.string(ConflictPolicy.replace.rawValue), "Replace"),
                          .init(.string(ConflictPolicy.skip.rawValue), "Skip")]),
          default: .string(ConflictPolicy.ask.rawValue), tier: .suggested,
          lessSafe: .toAny([.string(ConflictPolicy.replace.rawValue)])),
        e("sync.dateTolerance", .sync, "Treat dates as equal within", indexed: true,
          storage: .settingsManager(key: "dateToleranceSeconds"),
          control: .menu([0, 1, 2, 5, 60].map { SettingChoice(.double(Double($0)), SettingsPickerOptions.dateToleranceLabel(Double($0))) }),
          default: .double(1), tier: .suggested, effects: .rescans,
          help: "Counts two modification dates as the same when they are this close, so a provider rounding dates on upload doesn’t show up as a difference."),
        e("sync.verifySameSize", .sync, "Verify same-size files during scans", indexed: true,
          storage: .settingsManager(key: "autoVerifySameSizeDuringScan"), control: .toggle, default: .bool(false),
          tier: .suggested, effects: .rescans,
          help: "During each scan, checksums same-size files that differ only by date and hides the ones that are identical. Files over 100 MB are left for Verify All. Slower on large folders."),
        e("sync.rescanOnChange", .sync, "Rescan when files change", indexed: true,
          storage: .settingsManager(key: "rescanWhenFilesChange"), control: .toggle, default: .bool(false), tier: .suggested),
        e("sync.ignoreGoogleDriveNewer", .sync, "Ignore “newer on Google Drive” when same size", indexed: true,
          storage: .settingsManager(key: "ignoreGoogleDriveNewerDateOnly"), control: .toggle, default: .bool(false),
          tier: .suggested),
        e("sync.confirmTransfer", .sync, "Confirm before copying or moving", indexed: true,
          storage: app(GeneralSettings.confirmBeforeTransferKey, "GeneralSettings.confirmBeforeTransferKey", "true"),
          control: .toggle, default: .bool(true), tier: .suggested, lessSafe: .turningOff,
          help: "Shows what will be copied or moved, and where, before it starts. Off, copies and moves start at once."),
        e("sync.confirmDelete", .sync, "Confirm before deleting", indexed: true,
          storage: app(GeneralSettings.confirmBeforeDeleteKey, "GeneralSettings.confirmBeforeDeleteKey", "true"),
          control: .toggle, default: .bool(true), tier: .suggested, lessSafe: .turningOff,
          help: "Asks before moving items to the Trash. They go to the Trash either way, and Undo brings them back."),
        e("sync.rememberIgnored", .sync, "Remember ignored items across rescans", indexed: true,
          storage: .settingsManager(key: "rememberIgnoredItems"), control: .toggle, default: .bool(true), tier: .suggested),
        e("sync.ignoredItems", .sync, "Ignored items", others: ["Stop ignoring"], storage: .owner("IgnoredItemsStore"),
          control: .list, tier: .suggested, privacy: .hiddenFiltered),
        e("sync.ignoredItemsClearAll", .sync, "Clear All ignored items", others: ["Clear All…"],
          control: .button("Clear All…"), tier: .asksTwice, lessSafe: .always),
        e("sync.ignorePatterns", .sync, "Ignored name patterns", indexed: true,
          storage: .settingsManager(key: "ignorePatterns"), control: .list, tier: .suggested),

        // MARK: Organize
        e("organize.inbox", .filing, "Loose-files inbox", indexed: true,
          storage: app(GeneralSettings.filingInboxRelativePathKey, "GeneralSettings.filingInboxRelativePathKey", "\"TODO\""),
          control: .text, default: .string("TODO"), tier: .suggested),
        e("organize.rules", .filing, "Remembered rules", indexed: true, control: .readout, tier: .readOnly,
          privacy: .hiddenFiltered),
        e("organize.surveys", .filing, "Folder surveys", indexed: true,
          others: ["Learn Its Folders", "Read Documents…", "Stop"], storage: .owner("FolderSurveys"),
          control: .button("Learn Its Folders"), tier: .suggested, target: .cloudSource, privacy: .hiddenFiltered),
        e("organize.surveyForget", .filing, "Forget survey", others: ["Forget…"], control: .button("Forget…"),
          tier: .asksTwice, target: .cloudSource),
        e("organize.keptNames", .filing, "Kept names", indexed: true, storage: .owner("KeptNamesStore"),
          control: .list, tier: .suggested, privacy: .hiddenFiltered),
        e("organize.keptNamesClearAll", .filing, "Clear All kept names", others: ["Clear All…"],
          control: .button("Clear All…"), tier: .asksTwice),

        // MARK: Duplicates
        e("duplicates.minSize", .duplicates, "Ignore files smaller than", indexed: true,
          storage: app(DuplicateFinderOptions.DefaultsKey.minFileSize, "DuplicateFinderOptions.DefaultsKey.minFileSize", "4096"),
          control: .menu([0, 4096, 102_400, 1_048_576].map { SettingChoice(.int($0), SettingsPickerOptions.fileSizeLabel($0)) }),
          default: .int(4096), tier: .suggested),
        e("duplicates.overlap", .duplicates, "Folders overlap at", indexed: true,
          storage: app(DuplicateFinderOptions.DefaultsKey.overlapThreshold, "DuplicateFinderOptions.DefaultsKey.overlapThreshold", "0.7"),
          control: .menu([0.5, 0.6, 0.7, 0.8, 0.9].map { SettingChoice(.double($0), "\(Int(($0 * 100).rounded()))%") }),
          default: .double(0.7), tier: .suggested),
        e("duplicates.detectVersions", .duplicates, "Detect versions", indexed: true,
          storage: app(DuplicateFinderOptions.DefaultsKey.detectVersions, "DuplicateFinderOptions.DefaultsKey.detectVersions", "true"),
          control: .toggle, default: .bool(true), tier: .suggested),
        e("duplicates.readPDFs", .duplicates, "Read PDFs to find copies a byte hash misses", indexed: true,
          storage: app(DuplicateFinderOptions.DefaultsKey.detectSameText, "DuplicateFinderOptions.DefaultsKey.detectSameText", "true"),
          control: .toggle, default: .bool(true), tier: .suggested),

        // MARK: Intelligence
        e("intelligence.onDeviceAI", .intelligence, "Suggest folders with on-device AI", indexed: true,
          storage: app(FileSyncManager.usesAIDefaultsKey, "FileSyncManager.usesAIDefaultsKey", "true"),
          control: .toggle, default: .bool(true), tier: .suggested, raises: .turningOn),
        e("intelligence.readContents", .intelligence, "Read file contents on-device for better signals", indexed: true,
          storage: app(FileSyncManager.readContentsDefaultsKey, "FileSyncManager.readContentsDefaultsKey", "true"),
          // On, Refine sends Claude excerpts of what it read.
          control: .toggle, default: .bool(true), tier: .suggested, raises: .turningOn),
        e("intelligence.cloudRefine", .intelligence, "Use Claude (cloud) to refine suggestions", indexed: true,
          storage: app(FileSyncManager.usesCloudDefaultsKey, "FileSyncManager.usesCloudDefaultsKey", "false"),
          control: .toggle, default: .bool(false), tier: .directWhenTightening, dependsOn: ["intelligence.onDeviceAI"],
          raises: .turningOn),
        e("intelligence.apiKey", .intelligence, "Claude API key", indexed: true, others: ["Save", "Replace…", "Test"],
          storage: .owner("AnthropicKeychain"), control: .secret, tier: .suggested, privacy: .secret),
        e("intelligence.apiKeyRemove", .intelligence, "Remove API key", others: ["Remove"], control: .button("Remove"),
          tier: .asksTwice),
        e("intelligence.apiKeyReveal", .intelligence, "Reveal API key", others: ["Copy"], control: .button("Reveal"),
          tier: .notInChat, privacy: .secret),
        e("intelligence.askClaudeModel", .intelligence, "Model", index: ["Ask Claude"],
          storage: app(AskClaudeModels.defaultsKey, "AskClaudeModels.defaultsKey", "AskClaudeModels.defaultModel.id"),
          control: .menu(AskClaudeModels.options.map { SettingChoice(.string($0.id), $0.label) }),
          default: .string(AskClaudeModels.defaultModel.id), tier: .suggested,
          raises: .laterIn([.string(AskClaudeModels.haiku.id), .string(AskClaudeModels.sonnet.id), .string(AskClaudeModels.opus.id)])),
        e("intelligence.answers", .intelligence, "Answers", indexed: true,
          storage: app(AskClaudeDetail.defaultsKey, "AskClaudeDetail.defaultsKey", "AskClaudeDetail.brief.rawValue"),
          control: .segmented(AskClaudeDetail.allCases.map { SettingChoice(.string($0.rawValue), $0.label) }),
          default: .string(AskClaudeDetail.brief.rawValue), tier: .suggested,
          raises: .laterIn([.string(AskClaudeDetail.brief.rawValue), .string(AskClaudeDetail.detailed.rawValue)])),
        e("intelligence.hidden", .intelligence, "Hidden from Claude", indexed: true, others: ["Add…"],
          storage: .owner("AskClaudePrivacy"), control: .list, tier: .suggested, privacy: .countOnly, effects: .newChat),
        // Never in chat: a folder shared without asking loosens what reaches Claude, so only the
        // person sets it, from the shield menu, and only they take one off.
        e("intelligence.shared", .intelligence, "Shared without asking", indexed: true,
          storage: .owner("AskClaudePrivacy"), control: .list, tier: .notInChat, privacy: .countOnly),
        e("intelligence.monthlyLimit", .intelligence, "Monthly limit", indexed: true,
          storage: app(AskClaudeSpend.limitDefaultsKey, "AskClaudeSpend.limitDefaultsKey", "AskClaudeSpend.defaultLimitUSD"),
          control: .menu(AskClaudeSpend.limitChoices.map { SettingChoice(.double($0), $0 == 0 ? "No limit" : AskClaudeSpend.format($0)) }),
          default: .double(AskClaudeSpend.defaultLimitUSD), tier: .directWhenTightening,
          raises: .higher(zeroIsUnlimited: true),
          help: "Ask Claude warns at 80% of this and stops taking questions at it, until the month turns. Estimated from list prices; the Console has what was billed."),
        e("intelligence.thisMonth", .intelligence, "This month", indexed: true, control: .readout, tier: .readOnly),
        e("intelligence.cloudModel", .intelligence, "Cloud model", indexed: true,
          storage: app(FileSyncManager.cloudModelDefaultsKey, "FileSyncManager.cloudModelDefaultsKey", "CloudFilingProtocol.defaultModel"),
          control: .menu(CloudFilingProtocol.selectableModelOptions.map { SettingChoice(.string($0.id), $0.label) }),
          default: .string(CloudFilingProtocol.defaultModel), tier: .suggested,
          dependsOn: ["intelligence.onDeviceAI", "intelligence.cloudRefine"],
          raises: .laterIn(CloudFilingProtocol.selectableModelOptions.map { .string($0.id) }),
          help: "Saved suggestions are per model — switching means the next Refine asks, and pays for, every file again."),
        e("intelligence.costHistory", .intelligence, "Cost and limits", indexed: true, others: ["View History…"],
          control: .readout, tier: .readOnly),
        e("intelligence.costClear", .intelligence, "Clear spend history", others: ["Clear"], control: .button("Clear"),
          tier: .asksTwice, raises: .always),
        e("intelligence.monthlyCap", .intelligence, "Monthly budget cap", indexed: true,
          storage: app(FileSyncManager.monthlyBudgetCapKey, "FileSyncManager.monthlyBudgetCapKey", "0"),
          control: .menu([0, 1, 5, 10, 25, 50].map { SettingChoice(.double(Double($0)), SettingsPickerOptions.budgetLabel(Double($0))) }),
          default: .double(0), tier: .directWhenTightening, raises: .higher(zeroIsUnlimited: true)),
        e("intelligence.totalCap", .intelligence, "Total budget cap", indexed: true,
          storage: app(FileSyncManager.totalBudgetCapKey, "FileSyncManager.totalBudgetCapKey", "FileSyncManager.defaultTotalBudgetCapUSD"),
          control: .menu([0, 5, 10, 25, 50, 100].map { SettingChoice(.double(Double($0)), SettingsPickerOptions.budgetLabel(Double($0))) }),
          default: .double(FileSyncManager.defaultTotalBudgetCapUSD), tier: .directWhenTightening,
          raises: .higher(zeroIsUnlimited: true)),
        e("intelligence.reuseSuggestions", .intelligence, "Reuse suggestions for files that haven’t changed", indexed: true,
          storage: app(FileSyncManager.reuseVerdictsDefaultsKey, "FileSyncManager.reuseVerdictsDefaultsKey", "true"),
          control: .toggle, default: .bool(true), tier: .suggested, dependsOn: ["intelligence.onDeviceAI"],
          raises: .turningOff),
        e("intelligence.savedSuggestionsClear", .intelligence, "Saved suggestions", indexed: true, others: ["Clear…"],
          control: .button("Clear…"), tier: .asksTwice, raises: .always),

        // MARK: Advanced
        e("advanced.resetSetup", .advanced, "Reset Setup", indexed: true, others: ["Reset Setup…"],
          control: .button("Reset Setup…"), tier: .asksTwice),
        e("advanced.logLevel", .advanced, "Log level", indexed: true,
          storage: app(Logger.minimumLevelDefaultsKey, "Logger.minimumLevelDefaultsKey", "LogLevel.debug.rawValue"),
          control: .menu(LogLevel.allCases.map { SettingChoice(.string($0.rawValue), $0.rawValue) }),
          default: .string(LogLevel.debug.rawValue), tier: .suggested),
        e("advanced.logShowInFinder", .advanced, "Log file", indexed: true, others: ["Show in Finder"],
          control: .button("Show in Finder"), tier: .suggested),
        e("advanced.logClear", .advanced, "Clear Log", others: ["Clear Log…"], control: .button("Clear Log…"),
          tier: .asksTwice),
        e("advanced.sweep", .advanced, "Sweep orphaned temporary files", indexed: true, others: ["Sweep Now"],
          control: .button("Sweep Now"), tier: .suggested),
        e("advanced.fileDigestsClear", .advanced, "File digests", indexed: true, others: ["Clear"],
          control: .button("Clear"), tier: .suggested),
        e("advanced.storageReportsClear", .advanced, "Saved Storage reports", indexed: true, others: ["Clear"],
          control: .button("Clear"), tier: .suggested),
        e("advanced.resetAll", .advanced, "Reset all settings", indexed: true, others: ["Reset All Settings…"],
          control: .button("Reset All Settings…"), tier: .asksTwice, raises: .always),
    ]
    // swiftlint:enable function_body_length

    /// Stored keys a Settings control binds that are deliberately not entries of their own.
    public static let excludedAppStorageKeySources: Set<String> = [
        // Part of Column widths: All columns erases it; nothing sets it from a card.
        "PaneViewMode.columnWidthOverridesDefaultsKey",
    ]

    private static func app(_ key: String, _ keySource: String, _ defaultSource: String) -> SettingStorage {
        .appStorage(key: key, keySource: keySource, defaultSource: defaultSource)
    }

    private static func e(_ id: String, _ tab: SettingsView.SettingsTab, _ label: String,
                          indexed: Bool = false, index: [String] = [], others: [String] = [],
                          storage: SettingStorage = .none, control: SettingControl,
                          default value: SettingValue? = nil, tier: SettingTier,
                          target: SettingTarget = .app, privacy: SettingPrivacy = .plain,
                          effects: SettingEffects = [], dependsOn: [String] = [],
                          raises: SettingDirection? = nil, lessSafe: SettingDirection? = nil,
                          help: String? = nil) -> SettingEntry {
        SettingEntry(id: id, label: label, indexTitles: indexed ? [label] + index : index, otherLabels: others,
                     tab: tab, storage: storage, control: control, defaultValue: value, tier: tier,
                     target: target, privacy: privacy, effects: effects, dependsOn: dependsOn,
                     raises: raises, lessSafe: lessSafe, help: help)
    }
}
