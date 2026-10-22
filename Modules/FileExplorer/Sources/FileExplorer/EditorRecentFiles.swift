import AppKit
import Design
import Events

/// One file Edit opened (TE58): where it is, when, and whether it is a PDF.
public struct EditorRecentFile: Codable, Equatable, Identifiable, Sendable {
    /// Which of Edit's two models opened it — what the row's icon says (decision BG).
    public enum Kind: String, Codable, Sendable {
        case text, pdf

        /// **An unknown kind reads as text rather than failing the whole list.** A later build may
        /// add a kind, and the two builds share a defaults domain; one row it cannot name must not
        /// send every row this build CAN read to the `.unreadable` key.
        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .text
        }
    }

    public var path: String
    public var openedAt: Date
    public var kind: Kind

    public init(path: String, openedAt: Date, kind: Kind) {
        self.path = path
        self.openedAt = openedAt
        self.kind = kind
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    /// The folder it is in, as the row names it — iCloud Drive's top by its own name rather than
    /// the `com~apple~CloudDocs` its path ends in.
    public var folderName: String {
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folder == "com~apple~CloudDocs" ? "iCloud Drive" : folder
    }
}

/// **The files Edit opened, newest first** (TE58) — the empty page's list and File ▸ Open Recent.
///
/// The sidebar's Recents rules (`FolderJumpStore`, which this module cannot import), copied:
///
/// - **Move-to-front, capped.** Opening a file again moves it to the top; 20 are kept, 10 shown.
/// - **Missing files are hidden, not forgotten.** A file on a volume that is not mounted, or in a
///   cloud folder that is offline, comes back with it — so the list keeps 20 and shows the first 10
///   that are there (``shown``).
/// - **Unreadable bytes are kept.** A list this build cannot decode goes to ``salvageKey`` before
///   the store carries on empty, so the next open cannot be what destroys it.
///
/// Paths, not bookmarks: the app is not sandboxed, so a path reaches everything a bookmark would,
/// and a moved open file is followed by ``move(from:to:)``.
@MainActor
public final class EditorRecentFiles: ObservableObject {
    /// The app's list — which also looks at the disk again each time the app comes forward, so a
    /// file deleted in Finder meanwhile is not in File ▸ Open Recent when the menu is next opened.
    public static let shared: EditorRecentFiles = {
        let store = EditorRecentFiles()
        store.activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak store] _ in
            Task { @MainActor in await store?.refreshShown() }
        }
        return store
    }()

    /// The stored list, as JSON.
    public nonisolated static let key = "editorRecentFiles"
    /// Where bytes this build cannot decode are kept — the sidebar's `.unreadable` rule.
    public nonisolated static var salvageKey: String { key + ".unreadable" }
    /// How many are kept.
    public nonisolated static let maxStored = 20
    /// How many the page and the menu list.
    public nonisolated static let maxShown = 10

    /// Everything remembered, newest first — missing files included.
    @Published public private(set) var stored: [EditorRecentFile]
    /// **What the page and the menu list**: the first ``maxShown`` of ``stored`` not known to be
    /// missing. Brought up to date at once by every change here, from what was last found on disk;
    /// ``refreshShown()`` looks at the disk again.
    @Published public private(set) var shown: [EditorRecentFile] = []

    /// `nil` keeps the list in memory only — a test's, or a preview's.
    private let defaults: UserDefaults?
    /// Whether a file is there. Asked off the main actor: a path on a network volume that has gone
    /// away can take seconds to answer.
    private let exists: @Sendable (String) -> Bool
    /// The stored paths last found missing.
    private var missing: Set<String> = []
    /// The shared list's activation observer, held for the app's life.
    private var activation: NSObjectProtocol?
    /// Which look at the disk is the latest, so an older one finishing late cannot write over it.
    private var generation = 0
    /// The newest look whose answer has landed.
    private var applied = 0

    public init(defaults: UserDefaults? = .standard,
                exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.defaults = defaults
        self.exists = exists
        stored = defaults.map(Self.storedList(from:)) ?? []
        shown = Self.shown(stored, missing: [])
        // The first look at the disk, so a file deleted while the app was not running is not listed.
        Task { await refreshShown() }
    }

    // MARK: - Changes

    /// Records an open: the file goes to the top. Called once a load has opened the file — never
    /// for a refused one, and not for a reload of the file already open.
    /// - Parameter at: injected, for `FolderJumpStore.recordVisit`'s reason — a `Date()` in here
    ///   can only be asserted against another `Date()`.
    public func record(path: String, kind: EditorRecentFile.Kind, at: Date = Date()) {
        guard path.hasPrefix("/") else { return }
        stored = Self.inserting(EditorRecentFile(path: path, openedAt: at, kind: kind), into: stored)
        // It opened, so it is there.
        missing.remove(path)
        changed()
    }

    /// **The open file moved, and the list follows it** — a rename in the rail, a move in Browse,
    /// Organize filing it, or Finder. Its place and its date stay; a row already at the new path
    /// (an older file of the same name, since replaced) goes, so the path is listed once.
    public func move(from old: String, to new: String) {
        guard old != new, let index = stored.firstIndex(where: { $0.path == old }) else { return }
        var moved = stored[index]
        moved.path = new
        stored = stored.indices.compactMap { i in
            i == index ? moved : (stored[i].path == new ? nil : stored[i])
        }
        missing.remove(new)
        changed()
    }

    /// The page's Remove from Recents. A row already gone is not an error, and writes nothing.
    public func remove(path: String) {
        guard stored.contains(where: { $0.path == path }) else { return }
        stored.removeAll { $0.path == path }
        changed()
    }

    /// File ▸ Open Recent ▸ Clear Menu — everything, the hidden files too, as Finder's does.
    public func clear() {
        guard !stored.isEmpty else { return }
        stored = []
        missing = []
        changed()
    }

    /// **Looks at the disk again**: a file deleted or put back since the last look. The stat runs
    /// off the main actor; a look that finishes after a LATER one has landed is dropped, so an old
    /// answer cannot write over a newer one. A caller that awaits this sees an answer at least as
    /// new as its own.
    public func refreshShown() async {
        generation &+= 1
        let ticket = generation
        let paths = stored.map(\.path)
        let exists = self.exists
        let gone = await Task.detached { Set(paths.filter { !exists($0) }) }.value
        guard ticket > applied else { return }
        applied = ticket
        missing = gone
        let next = Self.shown(stored, missing: gone)
        if next != shown { shown = next }
    }

    private func changed() {
        shown = Self.shown(stored, missing: missing)
        persist()
        Task { await refreshShown() }
    }

    private func persist() {
        guard let defaults, let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.key)
    }

    // MARK: - Rules

    /// Move-to-front, deduplicated, capped at ``maxStored``.
    nonisolated static func inserting(_ file: EditorRecentFile, into list: [EditorRecentFile]) -> [EditorRecentFile] {
        var result = list.filter { $0.path != file.path }
        result.insert(file, at: 0)
        return Array(result.prefix(maxStored))
    }

    /// The first ``maxShown`` not known to be missing.
    nonisolated static func shown(_ list: [EditorRecentFile], missing: Set<String>) -> [EditorRecentFile] {
        Array(list.lazy.filter { !missing.contains($0.path) }.prefix(maxShown))
    }

    /// **The stored list, with bytes this build cannot read kept rather than overwritten** —
    /// `FolderJumpStore.storedMap`'s three states. Absent is a fresh install; present and readable
    /// is the list, deduplicated and capped on the way in; present and unreadable goes to
    /// ``salvageKey`` — once, since the FIRST failure holds the real list — and the store starts
    /// empty.
    nonisolated static func storedList(from defaults: UserDefaults) -> [EditorRecentFile] {
        guard let data = defaults.data(forKey: key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([EditorRecentFile].self, from: data) else {
            if defaults.data(forKey: salvageKey) == nil {
                defaults.set(data, forKey: salvageKey)
                Logger.shared.warning("\(key) is present but could not be read — its \(data.count) bytes were "
                                      + "kept under \(salvageKey) rather than overwritten, and Edit's recent "
                                      + "files start empty")
            }
            return []
        }
        return decoded.reduce(into: [EditorRecentFile]()) { out, file in
            if out.count < maxStored, file.path.hasPrefix("/"), !out.contains(where: { $0.path == file.path }) {
                out.append(file)
            }
        }
    }

    // MARK: - Words

    /// **When a row was opened, in the fewest words**: "Just now", "5 min ago", a time today,
    /// "Yesterday", a weekday within the week, then a date — with the year only when it is not this
    /// one. In the reader's own format, through `ZoneRefreshedFormatter`, so a column left on screen
    /// follows a change of time zone.
    public nonisolated static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch bucket(date, now: now, calendar: calendar) {
        case .justNow: return "Just now"
        case .minutes(let minutes): return "\(minutes) min ago"
        case .today: return timeOfDay.string(from: date, in: calendar.timeZone)
        case .yesterday: return "Yesterday"
        case .thisWeek: return weekday.string(from: date, in: calendar.timeZone)
        case .thisYear: return dayMonth.string(from: date, in: calendar.timeZone)
        case .older: return dayMonthYear.string(from: date, in: calendar.timeZone)
        }
    }

    /// Which of ``when(_:now:calendar:)``'s words a date takes — the rule, apart from the reader's
    /// format, so a test can pin it on any Mac.
    enum When: Equatable { case justNow, minutes(Int), today, yesterday, thisWeek, thisYear, older }

    nonisolated static func bucket(_ date: Date, now: Date, calendar: Calendar) -> When {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return .justNow }
        if seconds < 60 * 60 { return .minutes(Int(seconds / 60)) }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? .max
        if days == 1 { return .yesterday }
        if days < 7 { return .thisWeek }
        return calendar.component(.year, from: date) == calendar.component(.year, from: now) ? .thisYear : .older
    }

    private nonisolated static let timeOfDay = ZoneRefreshedFormatter.localized(date: .none, time: .short)
    private nonisolated static let weekday = ZoneRefreshedFormatter.template("EEE")
    private nonisolated static let dayMonth = ZoneRefreshedFormatter.template("dMMM")
    private nonisolated static let dayMonthYear = ZoneRefreshedFormatter.template("dMMMyyyy")

    /// **A menu row's title**: the file's name, and its folder after a dash where another row
    /// shares the name — the menu has no folder column to tell two `README.md`s apart.
    public nonisolated static func menuTitles(_ files: [EditorRecentFile]) -> [String] {
        let counts = Dictionary(files.map { ($0.name, 1) }, uniquingKeysWith: +)
        return files.map { counts[$0.name, default: 0] > 1 ? "\($0.name) — \($0.folderName)" : $0.name }
    }
}
