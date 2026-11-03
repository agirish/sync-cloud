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
    /// Rows this build can't read — written by a newer one, say — kept as they were and written
    /// back, so running an older build never deletes them.
    private var unreadable: [Data] = []

    public static let maxChanges = 500
    public static let maxAge: TimeInterval = 90 * 86_400

    public init(fileURL: URL = SettingsChangeLog.defaultFileURL()) {
        self.fileURL = fileURL
        let loaded = Self.load(fileURL, setAsideIfUnreadable: true)
        changes = Self.trimmed(loaded.changes, now: Date())
        unreadable = loaded.unreadable
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

    /// Adds a change and writes the file at once. Rows another copy of the app wrote since this one
    /// read the file are kept: the file is read again and merged, by id, before it is written.
    public func record(_ change: SettingsChange) {
        // In the file's order, oldest first: what's on disk, then what only this copy holds, then
        // the new change.
        let disk = Self.load(fileURL, setAsideIfUnreadable: false)
        let onDisk = Set(disk.changes.map(\.id))
        let merged = disk.changes + changes.filter { !onDisk.contains($0.id) } + [change]
        changes = Self.trimmed(merged, now: Date())
        unreadable = Array(Set(unreadable + disk.unreadable))
        save()
    }

    /// Activity's Clear: the record goes; the settings stay as they are.
    public func clear() {
        changes = []
        unreadable = []
        save()
    }

    /// Newest first, with the words of any change that names a hidden item taken out.
    /// - Parameters:
    ///   - names: The names hidden from Claude, by their last path component.
    ///   - limit: How many of the newest to give; all when nil.
    public func visible(hiding names: [String], limit: Int? = nil) -> [SettingsChange] {
        let newest = changes.reversed().prefix(limit ?? changes.count)
        let matchers = Self.matchers(names)
        return newest.map { Self.redacted($0, matching: matchers) }
    }

    static func redacted(_ change: SettingsChange, hiding names: [String]) -> SettingsChange {
        redacted(change, matching: matchers(names))
    }

    /// One matcher per hidden name, matching it as a whole word or path component only: a hidden
    /// "Old" names "Old" and "Archive/Old", never "Folder" (TE290 review).
    private static func matchers(_ names: [String]) -> [NSRegularExpression] {
        names.compactMap { name in
            let plain = name.precomposedStringWithCanonicalMapping
            guard !plain.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: plain)
                                            + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
        }
    }

    private static func redacted(_ change: SettingsChange, matching matchers: [NSRegularExpression]) -> SettingsChange {
        let words = [change.name, change.fromLabel, change.toLabel, change.from, change.to].compactMap { $0?.precomposedStringWithCanonicalMapping }
        guard matchers.contains(where: { matcher in
            words.contains { matcher.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }) else { return change }
        return SettingsChange(id: change.id, at: change.at, setting: change.setting, target: change.target,
                              name: "A change about an item hidden from Claude", from: nil, to: nil,
                              fromLabel: nil, toLabel: nil, how: change.how)
    }

    static func trimmed(_ changes: [SettingsChange], now: Date) -> [SettingsChange] {
        let recent = changes.filter { now.timeIntervalSince($0.at) < maxAge }
        return Array(recent.suffix(maxChanges))
    }

    /// The rows on disk: those this build reads, and the rest as raw JSON. A file that isn't a list
    /// at all is moved aside once, so the next write can't replace the only copy.
    private static func load(_ url: URL, setAsideIfUnreadable: Bool) -> (changes: [SettingsChange], unreadable: [Data]) {
        guard let data = try? Data(contentsOf: url) else { return ([], []) }
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            if setAsideIfUnreadable {
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                Logger.shared.error("Changed from Chat: \(url.lastPathComponent) can’t be read; moved it to \(aside.lastPathComponent) and started a new record")
            }
            return ([], [])
        }
        var changes: [SettingsChange] = []
        var unreadable: [Data] = []
        for item in items {
            guard let row = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { continue }
            if let change = try? JSONDecoder().decode(SettingsChange.self, from: row) { changes.append(change) } else { unreadable.append(row) }
        }
        return (changes, unreadable)
    }

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(changes)
            let rows = ((try JSONSerialization.jsonObject(with: encoded)) as? [Any] ?? [])
                + unreadable.compactMap { try? JSONSerialization.jsonObject(with: $0) }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.error("Changed from Chat: couldn’t write \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
