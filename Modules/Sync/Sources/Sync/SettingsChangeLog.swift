import Combine
import Events
import Foundation

/// One change made from Ask Claude's chat, kept after the chat is gone. It holds what Revert needs
/// (the setting's catalog id, its target, the stored values before and after) and the words
/// Activity shows, taken when the change was made.
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
        /// A filing rule saved from a card. It has no Revert: rules are removed in Organize ▸
        /// Rules.
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

/// Changed from Chat: every setting changed from Ask Claude's chat, in a file of its own beside the
/// History file, so Activity can list it, with Revert, after the chat is gone.
///
/// Each change is written as it happens, so a crash mid-answer can lose a card's state but never
/// this record. Kept 90 days and 500 at most, trimmed at every write. The file is outside the
/// preferences: Reset All leaves it, and it has its own Clear. Under a test runner it is a
/// per-process temp file, as the History file is.
///
/// Read through the hidden filter: a change whose words name something later hidden from Claude is
/// shown, and told to Claude, without them (`visible(hiding:)`).
@MainActor
public final class SettingsChangeLog: ObservableObject {
    public static let shared = SettingsChangeLog()

    /// Oldest first.
    @Published public private(set) var changes: [SettingsChange] = []
    public let fileURL: URL
    /// Rows this build can't read (written by a newer one, say), kept and written back, so running
    /// an older build never deletes them.
    private var unreadable: [Data] = []
    /// Rows this copy holds that it couldn't write. Only these are written back over the file: a row
    /// it wrote that is gone from the file was trimmed or cleared by another copy.
    private var unwritten: Set<UUID> = []
    /// The file is there but couldn't be read as a list, so it may be the only copy of every change
    /// it held: no write may replace it until it has been set aside (`setAsideUnreadableFile`).
    /// Cleared only by a set-aside that worked, or by the file being gone.
    private var fileIsUnreadable = false
    private let fileManager: FileManager

    public static let maxChanges = 500
    public static let maxAge: TimeInterval = 90 * 86_400

    /// - Parameter fileManager: A seam, so a test can refuse the set-aside's move.
    public init(fileURL: URL = SettingsChangeLog.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        let loaded = Self.load(fileURL, fileManager: fileManager)
        changes = Self.trimmed(loaded.changes, now: Date())
        unreadable = loaded.unreadable
        // Set aside now, as the record is opened, so the move and its line come when the file was
        // found unreadable; a refused move is tried again before every write.
        if loaded.fileIsUnreadable {
            fileIsUnreadable = true
            setAsideUnreadableFile()
        }
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
    /// read the file are kept: the file is read again and merged, by id, before it is written. Rows
    /// another copy trimmed or cleared stay gone; only a row this copy couldn't write is added back.
    public func record(_ change: SettingsChange) {
        let disk = Self.load(fileURL, fileManager: fileManager)
        // Spoilt since it was opened: the write below must set it aside first, not replace it. Every
        // row this copy holds is then in no readable file, so the fresh record keeps them all.
        if disk.fileIsUnreadable {
            fileIsUnreadable = true
            unwritten = Set(changes.map(\.id))
        }
        let onDisk = Set(disk.changes.map(\.id))
        let merged = disk.changes + changes.filter { unwritten.contains($0.id) && !onDisk.contains($0.id) } + [change]
        // Oldest first by when each was made, so the trim drops the oldest whichever copy wrote it.
        let ordered = merged.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        changes = Self.trimmed(ordered, now: Date())
        // Rows this build can't read only ever come from the file, as last read: a spoilt one has none.
        if !disk.fileIsUnreadable { unreadable = disk.unreadable }
        unwritten = save() ? [] : unwritten.union([change.id])
    }

    /// Activity's Clear: the record goes; the settings stay as they are.
    public func clear() {
        changes = []
        unreadable = []
        unwritten = []
        save()
    }

    /// Newest first, with the words of any change that names a hidden item taken out.
    /// - Parameters:
    ///   - names: The names hidden from Claude, by their last path component.
    ///   - hidingTargets: Whether a change's target is hidden now — a source whose own folder is
    ///     hidden, whose name the words can hold without holding the folder's ("Google Drive (a@b.com)"
    ///     for `GoogleDrive-a@b.com`). A change with no target is judged by its words alone.
    ///   - limit: How many of the newest to give; all when nil.
    public func visible(hiding names: [String], hidingTargets: (String) -> Bool = { _ in false },
                        limit: Int? = nil) -> [SettingsChange] {
        let newest = changes.reversed().prefix(limit ?? changes.count)
        let matchers = Self.matchers(names)
        return newest.map { change in
            change.target.map(hidingTargets) == true ? Self.hiddenChange(change) : Self.redacted(change, matching: matchers)
        }
    }

    static func redacted(_ change: SettingsChange, hiding names: [String]) -> SettingsChange {
        redacted(change, matching: matchers(names))
    }

    /// One matcher per hidden name, matching it as a whole word or path component only: a hidden
    /// "Old" matches "Old" and "Archive/Old", never "Folder".
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
        return hiddenChange(change)
    }

    private static func hiddenChange(_ change: SettingsChange) -> SettingsChange {
        SettingsChange(id: change.id, at: change.at, setting: change.setting, target: change.target,
                              name: "A change about an item hidden from Claude", from: nil, to: nil,
                              fromLabel: nil, toLabel: nil, how: change.how)
    }

    static func trimmed(_ changes: [SettingsChange], now: Date) -> [SettingsChange] {
        let recent = changes.filter { now.timeIntervalSince($0.at) < maxAge }
        return Array(recent.suffix(maxChanges))
    }

    /// The rows on disk: those this build reads, and the rest as raw JSON. `fileIsUnreadable` is a
    /// file that is there but can't be read, or isn't a list at all; the caller sets it aside before
    /// any write. A missing file is not unreadable: it is an empty record. Probed with
    /// `attributesOfItem`, not `fileExists`, so a dangling symlink counts as there, as in
    /// `PersonTagStore`.
    private static func load(_ url: URL, fileManager: FileManager)
        -> (changes: [SettingsChange], unreadable: [Data], fileIsUnreadable: Bool) {
        guard (try? fileManager.attributesOfItem(atPath: url.path)) != nil else { return ([], [], false) }
        guard let data = try? Data(contentsOf: url),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return ([], [], true)
        }
        var changes: [SettingsChange] = []
        var unreadable: [Data] = []
        for item in items {
            guard let row = try? JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) else { continue }
            if let change = try? JSONDecoder().decode(SettingsChange.self, from: row) { changes.append(change) } else { unreadable.append(row) }
        }
        return (changes, unreadable, false)
    }

    /// Moves the unreadable file out of the way of a fresh record, under a name unique to this
    /// episode (`UnreadableSetAside`), so a later one can never land on it. Nothing here deletes.
    ///
    /// A move that fails leaves the flag set and refuses the write: writing then would replace the
    /// only copy of every change the file held. The change stays in memory (`unwritten`) and is
    /// written once a later set-aside works. A file that is gone since leaves nothing to replace.
    /// - Returns: Whether a write may go ahead.
    @discardableResult
    private func setAsideUnreadableFile() -> Bool {
        let kept = UnreadableSetAside.destination(for: fileURL, at: Date(), fileManager: fileManager)
        do {
            try fileManager.moveItem(at: fileURL, to: kept)
            fileIsUnreadable = false
            // "Will be", not "has been": the fresh write is still ahead and can fail.
            Logger.shared.warning("Changed from Chat: \(fileURL.lastPathComponent) could not be read, so it "
                                  + "has been kept as \(kept.lastPathComponent); a fresh record will be "
                                  + "written beside it. The changes it held are in that file.")
            return true
        } catch {
            if (try? fileManager.attributesOfItem(atPath: fileURL.path)) == nil {
                fileIsUnreadable = false
                Logger.shared.warning("Changed from Chat: the unreadable \(fileURL.lastPathComponent) is no "
                                      + "longer there, so nothing is left to set aside and a fresh "
                                      + "record is written.")
                return true
            }
            Logger.shared.error("Changed from Chat: couldn’t set aside the unreadable "
                                + "\(fileURL.lastPathComponent) (\(error.localizedDescription)) — NOT "
                                + "overwriting it. Changes made now are kept in memory and written "
                                + "once it can be moved.")
            return false
        }
    }

    /// - Returns: Whether the file was written.
    @discardableResult
    private func save() -> Bool {
        if fileIsUnreadable, !setAsideUnreadableFile() { return false }
        do {
            let encoded = try JSONEncoder().encode(changes)
            let rows = ((try JSONSerialization.jsonObject(with: encoded)) as? [Any] ?? [])
                + unreadable.compactMap { try? JSONSerialization.jsonObject(with: $0) }
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: fileURL, options: .atomic)
            return true
        } catch {
            Logger.shared.error("Changed from Chat: couldn’t write \(fileURL.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}
