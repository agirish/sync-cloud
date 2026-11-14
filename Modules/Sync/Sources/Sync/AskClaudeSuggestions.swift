import Foundation

/// The one chip Ask Claude may show above its text box (TE309): "6 new files in Downloads · File
/// them?". Worked out on this Mac from facts the app already holds; nothing reaches Claude until
/// the chip is clicked, and a click sends `question` exactly as if it were typed.
///
/// **Never a hidden folder.** A folder on the Hidden from Claude list gives no chip, and files in a
/// hidden folder are never counted, so no count can hint at them. No item is ever named.
public enum AskClaudeSuggestions {

    /// On by default (decision IN).
    public static let enabledKey = "askClaudeSuggestions"
    /// What each kind last showed, was put away at or was turned off: `Memory`, as JSON.
    public static let memoryKey = "askClaudeSuggestionsMemory"

    /// Fewer new files than this isn't worth a chip.
    public static let minimumNewFiles = 3
    /// A Compare list older than this is stale, as Compare's own pill says.
    public static let freshFor: TimeInterval = 3600
    /// "New" the first time a folder is looked at: what arrived in the last day.
    public static let firstLook: TimeInterval = 24 * 3600

    /// The kinds that ship first (decision JE).
    public enum Kind: String, CaseIterable, Codable, Sendable {
        /// New loose files in a source's Downloads.
        case downloads
        /// New loose files in Organize's loose-files inbox.
        case inbox
        /// A Compare scan whose count changed.
        case compare

        /// The words of "Don't Suggest …" and of the Settings list of kinds turned off.
        public var title: String {
            switch self {
            case .downloads: return "New Files in Downloads"
            case .inbox: return "New Files in the Inbox"
            case .compare: return "New Differences in Compare"
            }
        }
    }

    public struct Suggestion: Equatable, Sendable {
        public var kind: Kind
        /// "6 new files in Downloads".
        public var text: String
        /// "File them?".
        public var action: String
        /// What a click sends.
        public var question: String
        /// What the chip counted, so ✕ can wait for more.
        public var count: Int
        /// The scan it is about (Compare only), so ✕ can wait for the next one.
        public var scannedAt: Date?
        /// Where a click or ✕ is remembered in `Memory.seen`.
        public var key: String
    }

    // MARK: Facts

    /// A folder whose new files are counted: a source's Downloads, or the inbox.
    public struct Folder: Equatable, Sendable {
        /// "Downloads", "TODO".
        public var name: String
        /// Where it is, as Ask Claude shows places: "iCloud › Downloads".
        public var place: String
        /// When each loose file arrived (added to the folder, else modified), hidden ones left out.
        public var arrivals: [Date]
        /// On the Hidden from Claude list, or inside a folder that is.
        public var hidden: Bool

        public init(name: String, place: String, arrivals: [Date], hidden: Bool) {
            self.name = name
            self.place = place
            self.arrivals = arrivals
            self.hidden = hidden
        }
    }

    /// Compare's list as Claude reads it: rows in a hidden folder already left out.
    public struct Comparison: Equatable, Sendable {
        public var count: Int
        /// When the scan behind the list finished.
        public var scannedAt: Date
        /// Either compared folder is hidden from Claude.
        public var hidden: Bool

        public init(count: Int, scannedAt: Date, hidden: Bool) {
            self.count = count
            self.scannedAt = scannedAt
            self.hidden = hidden
        }
    }

    public struct Facts: Equatable, Sendable {
        /// "Browse", "Compare", "Organize" or "Edit": the kind for the workspace on screen wins.
        public var workspace: String
        public var downloads: [Folder]
        public var inbox: Folder?
        public var comparison: Comparison?

        public init(workspace: String, downloads: [Folder] = [], inbox: Folder? = nil, comparison: Comparison? = nil) {
            self.workspace = workspace
            self.downloads = downloads
            self.inbox = inbox
            self.comparison = comparison
        }
    }

    /// Whether the box is free for a chip: no answer running, nothing queued or being edited, not
    /// listening, nothing typed, and Claude able to answer (a key, and under the monthly limit).
    public struct Box: Equatable, Sendable {
        public var isRunning = false
        public var hasQueued = false
        public var isEditing = false
        public var isListening = false
        public var hasDraft = false
        public var canAsk = true
        /// Items attached above the box: they were attached for a question of their own, and the
        /// chip's click would send them with its own.
        public var hasAttachments = false

        public init(isRunning: Bool = false, hasQueued: Bool = false, isEditing: Bool = false,
                    isListening: Bool = false, hasDraft: Bool = false, canAsk: Bool = true, hasAttachments: Bool = false) {
            self.hasAttachments = hasAttachments
            self.isRunning = isRunning
            self.hasQueued = hasQueued
            self.isEditing = isEditing
            self.isListening = isListening
            self.hasDraft = hasDraft
            self.canAsk = canAsk
        }

        public var isFree: Bool { canAsk && !isRunning && !hasQueued && !isEditing && !isListening && !hasDraft && !hasAttachments }
    }

    // MARK: Memory

    /// What was done with each kind, kept between launches.
    public struct Memory: Codable, Equatable, Sendable {
        public struct Seen: Codable, Equatable, Sendable {
            /// Files that arrived before this aren't new: set when the chip is clicked.
            public var since: Date?
            /// ✕ at this count: the chip waits until there are more.
            public var putAwayAt: Int?
            /// The Compare scan the chip was last clicked or put away for.
            public var scan: Date?

            public init(since: Date? = nil, putAwayAt: Int? = nil, scan: Date? = nil) {
                self.since = since
                self.putAwayAt = putAwayAt
                self.scan = scan
            }
        }

        /// Keyed by `"<kind>"` for Compare and the inbox, `"downloads:<place>"` per Downloads.
        public var seen: [String: Seen] = [:]
        /// Kinds turned off with "Don't Suggest …".
        public var off: Set<Kind> = []

        public init(seen: [String: Seen] = [:], off: Set<Kind> = []) {
            self.seen = seen
            self.off = off
        }

        public static func load(_ defaults: UserDefaults) -> Memory {
            guard let data = defaults.data(forKey: memoryKey),
                  let memory = try? JSONDecoder().decode(Memory.self, from: data) else { return Memory() }
            return memory
        }
    }

    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// When each of `folder`'s loose files arrived: put in the folder, else last modified. The
    /// filing card's own rules decide what counts, so the chip never counts a file the card would
    /// skip; hidden items aren't counted at all. Reads the disk.
    public static func arrivals(in folder: String, isHidden: (String) -> Bool,
                                fileManager fm: FileManager = .default) -> [Date] {
        AskClaudeLooseFiles.collect(in: folder, isHidden: isHidden, fileManager: fm).files.compactMap { $0.added ?? $0.modified }
    }

    // MARK: Choosing

    /// The chip to show, or nil. One at a time: the kind for the workspace on screen first, then
    /// the newest.
    public static func suggestion(_ facts: Facts, box: Box, memory: Memory, now: Date,
                                  timeZone: TimeZone = .current) -> Suggestion? {
        guard box.isFree else { return nil }
        var found: [(suggestion: Suggestion, newest: Date, onScreen: Bool)] = []
        let filing = facts.workspace != "Compare"
        if !memory.off.contains(.downloads) {
            for folder in facts.downloads {
                if let hit = newFiles(folder, kind: .downloads, seen: memory.seen[memoryKey(.downloads, folder)], now: now) {
                    found.append((hit.0, hit.1, filing))
                }
            }
        }
        if !memory.off.contains(.inbox), let inbox = facts.inbox,
           // An inbox inside Downloads would say the same files twice.
           !facts.downloads.contains(where: { inbox.place == $0.place || inbox.place.hasPrefix($0.place + " › ") }),
           let hit = newFiles(inbox, kind: .inbox, seen: memory.seen[memoryKey(.inbox, inbox)], now: now) {
            found.append((hit.0, hit.1, filing))
        }
        if !memory.off.contains(.compare), let comparison = facts.comparison,
           let hit = differences(comparison, seen: memory.seen[Kind.compare.rawValue], now: now, timeZone: timeZone) {
            found.append((hit, comparison.scannedAt, !filing))
        }
        return found.max { a, b in
            a.onScreen != b.onScreen ? !a.onScreen : a.newest < b.newest
        }?.suggestion
    }

    /// The `Memory.seen` key a suggestion's folder or kind is remembered under.
    public static func memoryKey(_ kind: Kind, _ folder: Folder?) -> String {
        kind == .downloads ? "downloads:" + (folder?.place ?? "") : kind.rawValue
    }

    private static func newFiles(_ folder: Folder, kind: Kind, seen: Memory.Seen?, now: Date) -> (Suggestion, Date)? {
        guard !folder.hidden else { return nil }
        let since = seen?.since ?? now.addingTimeInterval(-firstLook)
        let arrived = folder.arrivals.filter { $0 > since }
        guard arrived.count >= minimumNewFiles, arrived.count > (seen?.putAwayAt ?? 0),
              let newest = arrived.max() else { return nil }
        let chip = Suggestion(kind: kind, text: "\(arrived.count) new files in \(folder.name)", action: "File them?",
                              question: "File the new files in \(folder.place)", count: arrived.count, scannedAt: nil,
                              key: memoryKey(kind, folder))
        return (chip, newest)
    }

    private static func differences(_ comparison: Comparison, seen: Memory.Seen?, now: Date, timeZone: TimeZone) -> Suggestion? {
        guard !comparison.hidden, comparison.count > 0,
              now.timeIntervalSince(comparison.scannedAt) <= freshFor,
              seen?.scan.map({ comparison.scannedAt > $0 }) ?? true,
              comparison.count != seen?.putAwayAt else { return nil }
        let n = comparison.count
        let things = n == 1 ? "1 difference" : "\(n) differences"
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return Suggestion(kind: .compare, text: "The \(comparison.scannedAt.formatted(style)) scan found \(things)",
                          action: "Ask about them",
                          question: "Sum up Compare’s \(things) by kind and folder",
                          count: n, scannedAt: comparison.scannedAt, key: Kind.compare.rawValue)
    }

    // MARK: What a click and ✕ remember

    /// Clicked: what arrived until now is no longer new; the next chip counts from here.
    public static func clicked(_ suggestion: Suggestion, memory: inout Memory, now: Date) {
        memory.seen[suggestion.key] = suggestion.kind == .compare ? .init(putAwayAt: suggestion.count, scan: suggestion.scannedAt)
                                                       : .init(since: now)
    }

    /// Put away: the chip waits until more files arrive, or for the next scan whose count changed.
    public static func putAway(_ suggestion: Suggestion, memory: inout Memory) {
        var seen = memory.seen[suggestion.key] ?? .init()
        seen.putAwayAt = suggestion.count
        if suggestion.kind == .compare { seen.scan = suggestion.scannedAt }
        memory.seen[suggestion.key] = seen
    }
}
