import Foundation
import Sync

/// What Ask Claude's `settings` tool answers (TE290 step 2): find a setting by the words someone
/// would use, read its value, default, choices and what it does, and list what differs from the
/// defaults. Text for Claude, built from `SettingsCatalog` and each setting's owner.
///
/// **Privacy is applied here, not by the caller.** The API key is only ever "saved" or "not
/// saved", Hidden from Claude is a count, and a path on the Never show Claude list is named as
/// hidden — so no route through this type can hand Claude what those settings protect.
@MainActor
public struct SettingsLookup {

    /// What a value reads as, before it is put in words.
    enum Reading: Equatable {
        case value(SettingValue)
        /// One value per source (or person); the first element names it.
        case targets([Target])
        /// Only how many — Hidden from Claude.
        case count(Int)
        /// Only whether one is saved — the API key.
        case saved(Bool)
        /// A setting whose value Claude can't read yet.
        case notReadable

        struct Target: Equatable {
            let name: String
            let value: SettingValue
        }
    }

    public var defaults: UserDefaults
    public var settings: SettingsManager?
    public var keyIsSaved: () -> Bool
    public var hiddenCount: () -> Int
    public var isHidden: (String) -> Bool
    /// Launch at login lives in macOS, and is read off the main thread.
    public var loginItemIsOn: () async -> Bool
    /// Changed from Chat (TE290 step 5), newest first and through the hidden filter.
    public var changesFromChat: () -> [SettingsChange]

    public init(defaults: UserDefaults, settings: SettingsManager?, keyIsSaved: @escaping () -> Bool,
                hiddenCount: @escaping () -> Int, isHidden: @escaping (String) -> Bool,
                loginItemIsOn: @escaping () async -> Bool,
                changesFromChat: @escaping () -> [SettingsChange] = { [] }) {
        self.defaults = defaults
        self.settings = settings
        self.keyIsSaved = keyIsSaved
        self.hiddenCount = hiddenCount
        self.isHidden = isHidden
        self.loginItemIsOn = loginItemIsOn
        self.changesFromChat = changesFromChat
    }

    /// How far back `changed` lists what was changed from chat.
    static let changedFromChatWindow: TimeInterval = 30 * 86_400

    /// The most matches `find` returns.
    static let findLimit = 8

    // MARK: - The three questions

    /// Settings whose words match, best first, each with its current value.
    public func find(_ words: String) async -> String {
        let wanted = Self.words(words)
        guard !wanted.isEmpty else { return "Give words to look for, as they’d say them: dark mode, monthly limit." }
        let scored = SettingsCatalog.all.compactMap { entry -> (SettingEntry, Int)? in
            let haystack = Self.haystack(entry)
            let score = wanted.filter { word in haystack.contains { $0.contains(word) } }.count
            return score > 0 ? (entry, score) : nil
        }
        let best = scored.sorted { $0.1 > $1.1 }.prefix(Self.findLimit)
        guard !best.isEmpty else { return "No setting matches “\(words)”. Try other words, or get by id." }
        var lines: [String] = []
        for (entry, _) in best {
            lines.append("\(entry.id) · \(entry.label) (\(entry.tabName)): \(Self.words(for: await read(entry), entry))")
        }
        return lines.joined(separator: "\n")
    }

    /// Everything about each setting: value, default, choices, help, who may change it.
    public func get(_ ids: [String]) async -> String {
        guard !ids.isEmpty else { return "Give the ids find returned." }
        var blocks: [String] = []
        for id in ids {
            guard let entry = SettingsCatalog.entry(id) else {
                blocks.append("\(id): no such setting. Use find to get an id.")
                continue
            }
            blocks.append(await describe(entry))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Every setting that differs from its default.
    public func changed() async -> String {
        var lines: [String] = []
        for entry in SettingsCatalog.all {
            switch await read(entry) {
            case .value(let value):
                guard let base = entry.defaultValue, value != base else { continue }
                lines.append("\(entry.label) (\(entry.tabName)): \(Self.label(value, entry)) — default \(Self.label(base, entry))")
            case .targets(let targets) where entry.id == "sources.enabled":
                for off in targets where off.value == .bool(false) {
                    lines.append("\(off.name) (Sources): turned off — default on")
                }
            case .count(let count) where count > 0:
                lines.append("\(entry.label) (\(entry.tabName)): \(count) item\(count == 1 ? "" : "s")")
            default:
                continue
            }
        }
        if let patterns = settings?.ignorePatterns, !patterns.isEmpty {
            lines.append("Ignored name patterns (Sync): \(patterns.count) added")
        }
        var answer = lines.isEmpty ? "Every setting is at its default." : lines.joined(separator: "\n")
        let now = Date()
        let recent = changesFromChat().filter { now.timeIntervalSince($0.at) < Self.changedFromChatWindow }
        if !recent.isEmpty {
            answer += "\n\nChanged from chat in the last 30 days, newest first:\n" + recent.prefix(20).map { change in
                "\(change.name)" + (change.valueWords.map { ": \($0)" } ?? "") + ", \(change.howWords), "
                    + change.at.formatted(date: .abbreviated, time: .shortened)
            }.joined(separator: "\n")
            if recent.count > 20 { answer += "\nand \(recent.count - 20) more, in Activity ▸ History." }
        }
        return answer
    }

    // MARK: - Reading

    /// The value a card's control shows now, for `target` when the setting belongs to one. Read on
    /// every draw, never stored: nil when the setting has no single value to show.
    public func currentValue(_ entry: SettingEntry, target: String? = nil) -> SettingValue? {
        if entry.id == "general.launchAtLogin" { return .bool(LoginItemController.shared.isOn) }
        switch readNow(entry) {
        case .value(let value):
            return value
        case .targets(let targets):
            guard let target, let settings else { return nil }
            if entry.id == "sources.enabled" { return .bool(settings.isEnabled(target)) }
            let name = settings.availableProviders.first { $0.id == target }?.displayName
            return targets.first { $0.name == name || $0.name == target }?.value
        default:
            return nil
        }
    }

    /// `read` without the login item's fresh read, which is the one value that needs a wait.
    func readNow(_ entry: SettingEntry) -> Reading {
        switch entry.storage {
        case .appStorage(let key, _, _):
            guard let base = entry.defaultValue else { return .notReadable }
            guard defaults.object(forKey: key) != nil else { return .value(base) }
            switch base {
            case .bool: return .value(.bool(defaults.bool(forKey: key)))
            case .int: return .value(.int(defaults.integer(forKey: key)))
            case .double: return .value(.double(defaults.double(forKey: key)))
            case .string: return .value(.string(defaults.string(forKey: key) ?? ""))
            }
        case .settingsManager:
            return readManaged(entry)
        default:
            return .notReadable
        }
    }

    func read(_ entry: SettingEntry) async -> Reading {
        switch entry.storage {
        case .appStorage, .settingsManager:
            return readNow(entry)
        case .owner:
            switch entry.id {
            case "general.launchAtLogin": return .value(.bool(await loginItemIsOn()))
            case "intelligence.apiKey": return .saved(keyIsSaved())
            case "intelligence.hidden": return .count(hiddenCount())
            default: return .notReadable
            }
        case .none:
            return .notReadable
        }
    }

    private func readManaged(_ entry: SettingEntry) -> Reading {
        guard let settings else { return .notReadable }
        switch entry.id {
        case "general.sortPanesBy": return .value(.string(settings.defaultSortOption.rawValue))
        case "sources.folderNameRule": return .value(.string(settings.folderNameRule.rawValue))
        case "sync.whenFileExists": return .value(.string(settings.conflictPolicy.rawValue))
        case "sync.dateTolerance": return .value(.double(settings.dateToleranceSeconds))
        case "sync.verifySameSize": return .value(.bool(settings.autoVerifySameSizeDuringScan))
        case "sync.rescanOnChange": return .value(.bool(settings.rescanWhenFilesChange))
        case "sync.ignoreGoogleDriveNewer": return .value(.bool(settings.ignoreGoogleDriveNewerDateOnly))
        case "sync.rememberIgnored": return .value(.bool(settings.rememberIgnoredItems))
        case "sync.ignorePatterns": return .value(.string(settings.ignorePatterns.joined(separator: ", ")))
        case "sources.enabled":
            return .targets(settings.availableProviders.map { .init(name: $0.displayName, value: .bool(settings.isEnabled($0.id))) })
        case "sources.name":
            return .targets(settings.availableProviders.map { .init(name: $0.id, value: .string($0.displayName)) })
        case "sources.path":
            return .targets(settings.availableProviders.filter(\.isLocalFolder).map {
                .init(name: $0.displayName, value: .string(isHidden($0.rootPath) ? "(hidden from Claude)" : $0.rootPath))
            })
        case "sources.openAt":
            return .targets(settings.availableProviders.filter { !$0.isLocalFolder }.map { provider in
                let folder = settings.openAt(for: provider.id)
                let path = (provider.rootPath as NSString).appendingPathComponent(folder)
                return .init(name: provider.displayName, value: .string(isHidden(path) ? "(hidden from Claude)" : folder))
            })
        default:
            return .notReadable
        }
    }

    // MARK: - Words

    private func describe(_ entry: SettingEntry) async -> String {
        let reading = await read(entry)
        var lines = ["id: \(entry.id)", "name: \(entry.label) (Settings ▸ \(entry.tabName))"]
        lines.append("value: \(Self.words(for: reading, entry))")
        if let base = entry.defaultValue {
            let changed = reading == .value(base) ? "no" : (reading.isValue ? "yes" : "—")
            lines.append("default: \(Self.label(base, entry)) · changed: \(changed)")
        }
        switch entry.control {
        case .menu(let choices), .segmented(let choices), .swatches(let choices):
            lines.append("choices: " + choices.map(\.label).joined(separator: " · "))
        case .stepper(let low, let high, let step):
            lines.append("range: \(low)–\(high)% in steps of \(step)")
        case .slider(let low, let high):
            lines.append("range: \(Int(low * 100))–\(Int(high * 100))%")
        default:
            break
        }
        if let help = entry.help { lines.append("help: \(help)") }
        lines.append("who changes it: \(Self.tierWords(entry))")
        var effects: [String] = []
        if entry.effects.contains(.nextLaunch) { effects.append("takes effect at the next launch") }
        if entry.effects.contains(.rescans) { effects.append("both panes rescan") }
        if entry.effects.contains(.newChat) { effects.append("applies from their next chat") }
        if !effects.isEmpty { lines.append("effects: " + effects.joined(separator: "; ")) }
        for dependency in entry.dependsOn {
            guard let parent = SettingsCatalog.entry(dependency) else { continue }
            if case .value(.bool(false)) = await read(parent) {
                lines.append("disabled: until \(parent.label) is on")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func tierWords(_ entry: SettingEntry) -> String {
        switch entry.tier {
        case .direct: "you may change it when they ask; otherwise show a card"
        case .directWhenTightening: "you may only lower it yourself, when they ask; raising it takes their click on a card"
        case .suggested: "show a card; their click changes it"
        case .asksTwice: "show a card; it asks them twice and can’t be undone"
        case .readOnly: "nothing to set"
        case .notInChat: "never offer this in chat"
        case .viewTools: "use view or go_to"
        }
    }

    static func words(for reading: Reading, _ entry: SettingEntry) -> String {
        switch reading {
        case .value(let value): label(value, entry)
        case .targets(let targets) where targets.isEmpty: "none"
        case .targets(let targets): targets.map { "\($0.name): \(label($0.value, entry))" }.joined(separator: "; ")
        case .count(let count): count == 1 ? "1 item hidden" : "\(count) items hidden"
        case .saved(let saved): saved ? "a key is saved" : "no key saved"
        case .notReadable: "shown in Settings ▸ \(entry.tabName)"
        }
    }

    /// A value as Settings shows it: a choice's label when it is one.
    public static func label(_ value: SettingValue, _ entry: SettingEntry) -> String {
        switch entry.control {
        case .menu(let choices), .segmented(let choices), .swatches(let choices):
            if let choice = choices.first(where: { $0.value == value }) { return choice.label }
        case .stepper:
            if case .int(let percent) = value { return "\(percent)%" }
        case .slider:
            if case .double(let fraction) = value { return "\(Int((fraction * 100).rounded()))%" }
        case .text:
            if case .string(let text) = value { return text.isEmpty ? "empty" : "“\(text)”" }
        default:
            break
        }
        return value.description
    }

    // MARK: - Matching

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Everything a word may match: names, the index's titles and keywords, the tab, the id.
    static func haystack(_ entry: SettingEntry) -> [String] {
        let rows = SettingsSearchIndex.all.filter { entry.indexTitles.contains($0.title) }
        return ([entry.label, entry.tabName, entry.id] + entry.indexTitles + entry.otherLabels
                + rows.flatMap(\.keywords)).map { $0.lowercased() }
    }
}

private extension SettingsLookup.Reading {
    var isValue: Bool { if case .value = self { true } else { false } }
}
