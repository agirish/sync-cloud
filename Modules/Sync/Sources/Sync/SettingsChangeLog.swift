import Combine
import Events
import Foundation

/// One change made from Ask Claude's chat (TE290 step 5), kept after the chat is gone.
///
/// It holds what Revert needs — the setting's catalog id, its target, the values before and after
/// as stored — and the words Activity shows, taken when the change was made.
public struct SettingsChange: Codable, Equatable, Identifiable, Sendable {

    /// Who made it, and how.
    public enum How: String, Codable, Sendable {
        /// Claude, with the settings tool's set.
        case claude
        /// Their click on a card.
        case card
        /// A card's Undo or Redo, or Edit ▸ Undo or Redo with the chat in front.
        case undo, redo
        /// Revert, in Activity ▸ History.
        case revert
        /// A filing rule saved from a card (TE286). It has no Revert: rules are removed in
        /// Organize ▸ Rules.
        case rule
    }

    public let id: UUID
    public let at: Date
    /// The catalog id (`SettingsCatalog`); "organize.rules" for a saved rule.
    public let setting: String
    /// The source or person it belongs to, by stable id.
    public let target: String?
    /// "Theme", "Show in Sidebar for Dropbox", a rule's name.
    public let name: String
    /// The values before and after, as stored; nil for a change that isn't a value (a rule).
    public let from: String?
    public let to: String?
    /// The same values in words, as the card showed them.
    public let fromLabel: String?
    public let toLabel: String?
    public let how: How

    public init(id: UUID = UUID(), at: Date = Date(), setting: String, target: String? = nil, name: String,
                from: String?, to: String?, fromLabel: String?, toLabel: String?, how: How) {
        self.id = id
        self.at = at
        self.setting = setting
        self.target = target
        self.name = name
        self.from = from
        self.to = to
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.how = how
    }

    /// "System → Dark", or nil for a change that isn't a value.
    public var valueWords: String? {
        guard let toLabel else { return nil }
        return fromLabel.map { "\($0) → \(toLabel)" } ?? toLabel
    }

    /// "by Claude", "on a card", for Activity and for Claude.
    public var howWords: String {
        switch how {
        case .claude: "by Claude"
        case .card: "on a card"
        case .undo: "with Undo"
        case .redo: "with Redo"
        case .revert: "with Revert"
        case .rule: "saved from a card"
        }
    }
}

/// **Changed from Chat** (TE290 step 5): every setting changed from Ask Claude's chat, in a file of
/// its own beside the History file, so Activity can list it — with Revert — after the chat is gone.
///
/// **Recorded the moment it's made.** Each change is written as it happens, so a crash mid-answer
/// can lose a card's state but never this record. **Kept 90 days, 500 at most**, whichever is less,
/// trimmed at every write. The file is outside the preferences: Reset All leaves it, and it has its
/// own Clear. Under a test runner it is a per-process temp file, as the History file is.
///
/// **Read through the hidden filter.** A change whose words name something later hidden from
/// Claude is shown, and told to Claude, without them (`visible(hiding:)`).
@MainActor
public final class SettingsChangeLog: ObservableObject {
    public static let shared = SettingsChangeLog()

    /// Oldest first.
    @Published public private(set) var changes: [SettingsChange] = []
    public let fileURL: URL

    public static let maxChanges = 500
    public static let maxAge: TimeInterval = 90 * 86_400

    public init(fileURL: URL = SettingsChangeLog.defaultFileURL()) {
        self.fileURL = fileURL
        changes = Self.trimmed(Self.load(fileURL), now: Date())
    }

    /// `SYNCCLOUD_SETTINGS_CHANGES_FILE`, else a per-process temp file under a test runner, else
    /// `~/sync-cloud-settings-changes.json` beside `~/sync-cloud-history.jsonl`.
    public nonisolated static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["SYNCCLOUD_SETTINGS_CHANGES_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if Logger.isRunningTests {
            return PerProcessTestFile.url(stem: PerProcessTestFile.settingsChangesStem, extension: "json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("sync-cloud-settings-changes.json")
    }

    /// Adds a change and writes the file at once.
    public func record(_ change: SettingsChange) {
        changes = Self.trimmed(changes + [change], now: Date())
        save()
    }

    /// Activity's Clear: the record goes; the settings stay as they are.
    public func clear() {
        changes = []
        save()
    }

    /// Newest first, with the words of any change that names a hidden item taken out.
    /// - Parameter hiding: The names hidden from Claude, by their last path component.
    public func visible(hiding names: [String]) -> [SettingsChange] {
        changes.reversed().map { Self.redacted($0, hiding: names) }
    }

    static func redacted(_ change: SettingsChange, hiding names: [String]) -> SettingsChange {
        let words = [change.name, change.fromLabel, change.toLabel, change.from, change.to].compactMap { $0 }
        guard names.contains(where: { name in !name.isEmpty && words.contains { $0.localizedCaseInsensitiveContains(name) } })
        else { return change }
        return SettingsChange(id: change.id, at: change.at, setting: change.setting, target: change.target,
                              name: "A change about an item hidden from Claude", from: nil, to: nil,
                              fromLabel: nil, toLabel: nil, how: change.how)
    }

    static func trimmed(_ changes: [SettingsChange], now: Date) -> [SettingsChange] {
        let recent = changes.filter { now.timeIntervalSince($0.at) < maxAge }
        return Array(recent.suffix(maxChanges))
    }

    private static func load(_ url: URL) -> [SettingsChange] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // One change that can't be read is left out, not the whole record.
        guard let items = try? JSONDecoder().decode([Tolerant].self, from: data) else {
            Logger.shared.error("Changed from Chat: \(url.lastPathComponent) can’t be read; starting a new record")
            return []
        }
        return items.compactMap(\.change)
    }

    private struct Tolerant: Decodable {
        let change: SettingsChange?
        init(from decoder: Decoder) throws { change = try? SettingsChange(from: decoder) }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(changes).write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.error("Changed from Chat: couldn’t write \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
