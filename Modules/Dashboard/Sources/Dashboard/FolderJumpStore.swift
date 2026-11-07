import SwiftUI
import Foundation
import Design
import Events
import FileExplorer
import Sync

/// One jump target within a provider pane: a folder, by its path relative to the pane's provider
/// root ("" is the root), plus the name shown in the menu. `Sendable` so the sibling enumeration can
/// hand results back from a detached task.
struct JumpLocation: Codable, Equatable, Identifiable, Hashable, Sendable {
    let relativePath: String
    let name: String
    /// When this folder was last visited, which a cross-source "most recent" list needs: two
    /// ordered per-root lists can't be interleaved without a time.
    ///
    /// **`nil` means unknown, never "the beginning of time".** Entries written without a date decode
    /// as nil, and `.distantPast` would claim they were visited longest ago. Unknown sorts after
    /// everything dated (``FolderJumpStore/mostRecentAcrossRoots``) and earns a real date on the
    /// next visit, so the list corrects itself through use, with no migration pass.
    ///
    /// Additive, so safe both ways across builds that share this defaults domain: an older build's
    /// entry without the key decodes as nil, and an older decoder ignores the key.
    var visitedAt: Date?
    var id: String { relativePath }
}

/// One remembered visit with the root it happened under, for a list spanning every root.
///
/// `JumpLocation` is root-less on purpose: it is stored inside a per-root list, so repeating the
/// root in each element would be a second place for the key to be wrong. Across roots the root
/// becomes data, which is this type.
public struct RememberedVisit: Equatable, Sendable {
    /// The provider root, already normalised through `FolderJumpStore.key(forRoot:)`.
    public let root: String
    public let relativePath: String
    public let name: String
    /// `nil` when the visit's time is unknown; see ``JumpLocation/visitedAt``.
    public let visitedAt: Date?

    public init(root: String, relativePath: String, name: String, visitedAt: Date?) {
        self.root = root
        self.relativePath = relativePath
        self.name = name
        self.visitedAt = visitedAt
    }
}

/// The stays one folder has had, which Revisited and Frequent count.
///
/// A record of its own, not a field on `JumpLocation`, because the lists cover different spans.
/// Recents is "where you were just now": eight per root, one date each, written on every folder a
/// pane shows. Revisited and Frequent look back 90 days, and the folders that qualify are exactly
/// the ones a run of one-offs would push out of the eight before they could be counted.
struct FolderStays: Codable, Equatable, Sendable {
    var name: String
    /// When each stay began, oldest first. A return within ``FolderJumpStore/returnGap`` of leaving
    /// continues the stay before it rather than adding one.
    var stays: [Date]
}

/// Both remembered lists as they should be drawn, and whether the root was there to be asked.
///
/// `rootIsAvailable == false` means the lists are everything remembered, unchecked: the caller
/// shows them marked unavailable rather than dropping them. See `FolderJumpStore.reachable`.
public struct RememberedFolders: Equatable, Sendable {
    public var recents: [String]
    public var pinned: [String]
    public var rootIsAvailable: Bool

    public init(recents: [String], pinned: [String], rootIsAvailable: Bool) {
        self.recents = recents
        self.pinned = pinned
        self.rootIsAvailable = rootIsAvailable
    }
}

/// Backs the pane header's folder quick-jump menu. Back/forward and the breadcrumb move up and
/// back; this adds the lateral hops: sibling folders (from disk), recently visited folders, and
/// pinned favorites, both persisted. Keyed by the pane's provider root path, stable and unique per
/// provider, so both panes and relaunches agree.
@MainActor
public final class FolderJumpStore: ObservableObject {
    public static let shared = FolderJumpStore()

    /// Recents outlive the session. They mean "where I've been just now", but the ⌘K field's empty
    /// state is this list, and a session-only list would greet the first ⌘K of the day with nothing,
    /// just when yesterday's folder is most wanted.
    @Published private(set) var recentsByRoot: [String: [JumpLocation]] = [:]
    /// Pins are curated and outlive the session, so they persist.
    @Published private(set) var pinnedByRoot: [String: [JumpLocation]] = [:]
    /// Each folder's stays, per root (``FolderStays``). Fed by
    /// ``noteArrival(pane:root:relativePath:name:at:)``, never by `recordVisit`.
    @Published private(set) var staysByRoot: [String: [String: FolderStays]] = [:]
    /// Each pane's current folder, when it arrived, and whether that visit has counted yet.
    /// Session-only: a folder open when the app quits was either stayed in already or was not.
    private var panes: [String: PaneFolder] = [:]
    /// When a pane last left a folder it had stayed in, by `favoriteKey`, so a return inside
    /// ``returnGap`` continues that stay. Session-only too: a relaunch outlasts the gap anyway.
    private var departures: [String: Date] = [:]

    private struct PaneFolder {
        let root: String
        let relativePath: String
        let name: String
        let at: Date
        var counted: Bool
        var key: String { FolderJumpStore.favoriteKey(root: FolderJumpStore.key(forRoot: root), relativePath: relativePath) }
    }

    /// The user's dragged order, empty until they drag something. Public because the row builder
    /// outside this module applies it: `FolderSidebarModel.rows(sources:recents:favoriteOrder:)`.
    @Published public private(set) var favoriteOrder: [String] = []

    private let defaults: UserDefaults
    nonisolated(unsafe) private var change: NSObjectProtocol?
    static let pinnedKey = "folderJumpPinnedByRoot"
    static let recentsKey = "folderJumpRecentsByRoot"
    /// How many recents are kept per root, and how many the sidebar's one global list shows. Public
    /// because the sidebar is outside this module and asks for the same eight; two constants for
    /// "how many recents" would come to disagree.
    ///
    /// `nonisolated` so it can be a default argument off the main actor: `FolderSidebarModel.rows`
    /// applies the cap and is pure.
    public nonisolated static let maxRecents = 8
    static let staysKey = "folderJumpStaysByRoot"
    /// How long a pane must stay in a folder for the visit to count as a stay. Long enough that a
    /// folder clicked through on the way down, or skimmed with Back and Forward, never counts; short
    /// enough that opening a folder to read what is in it does.
    nonisolated static let stayThreshold: TimeInterval = 4
    /// How long away before a return is a new stay. Stepping into a subfolder and back out is one
    /// stay, not two. A tuning default.
    nonisolated static let returnGap: TimeInterval = 5 * 60
    /// How far back Revisited and Frequent look: a stay older than this is forgotten.
    nonisolated static let revisitWindow: TimeInterval = 90 * 24 * 60 * 60
    /// Revisited means stayed in on this many different calendar days; Frequent asks for this many
    /// stays.
    nonisolated static let revisitMinimum = 2
    /// The fade: a stay (or for Revisited, a day) weighs 0.5^(age in days / this), and a folder needs
    /// a total weight of 1 to be listed. Two days a month ago just make it; two days two months ago
    /// do not. A tuning default, so it is one constant.
    nonisolated static let fadeHalfLifeDays: Double = 30
    /// The most stays one folder keeps, the newest. At this fade, stays past the first few dozen
    /// change nothing visible, and the record is rewritten on every stay.
    nonisolated static let maxStaysPerFolder = 200
    /// A ceiling on the folders the stay record holds, across every root. It must reach well past
    /// the eight rows, or one-offs push the regulars out before their second day, but the record is
    /// rewritten on every stay and 90 days of one-offs is otherwise unbounded. The least recently
    /// stayed go first.
    nonisolated static let maxStayedFolders = 500
    /// The user's own order for the Favorites section, as `root\u{0}relativePath` keys.
    ///
    /// A separate key, not a field on `JumpLocation` nor `pinnedByRoot`'s array order: Favorites
    /// spans every source as one flat list, and a drag that moves a Dropbox favorite above an iCloud
    /// one has no representation in per-root arrays. An order that stopped at a source boundary
    /// would make the row snap back for no reason the user can see.
    ///
    /// `pinnedByRoot` is the truth about membership; this is the truth about sequence.
    static let favoriteOrderKey = "folderJumpFavoriteOrder"

    /// Where bytes this build can't decode are put, instead of being overwritten.
    ///
    /// **Unreadable is not absent.** A `try?` that falls back to `[:]` looks like a fresh install,
    /// and the next `togglePin` would encode that empty map over the key and destroy the real pins.
    ///
    /// `PeopleStore` refuses to write in this state, because Settings ▸ Organize ▸ People has a banner to
    /// explain it. This surface has none, and a refused write would just make the pin item stop
    /// working, so the bytes are kept aside and the store carries on, which loses nothing.
    static func salvageKey(for key: String) -> String { key + ".unreadable" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Re-keyed on the way in: pins may sit under a non-normalised spelling of their root
        // (`~/Documents` for a folder source), and reading them through `key(forRoot:)` alone
        // would orphan them.
        //
        // Deduplicated as they merge: the same folder can be stored under both spellings, and
        // concatenating would list it twice in ⌘K and let one unpin leave it pinned.
        //
        // Keys taken in sorted order so the merged order is the same on every launch; dictionary
        // iteration is not, and pins are shown in the order they are held.
        let storedPins = Self.storedMap(Self.pinnedKey, from: defaults)
        pinnedByRoot = storedPins.keys.sorted().reduce(into: [:]) { out, rawKey in
            let key = Self.key(forRoot: rawKey)
            var list = out[key] ?? []
            for pin in storedPins[rawKey] ?? []
            where !list.contains(where: { $0.relativePath == pin.relativePath }) {
                list.append(pin)
            }
            out[key] = list
        }
        // Recents, through the same re-keying, so the two lists, read side by side by the same
        // callers, can't disagree about what a root is.
        //
        // Capped on the way in as well as out: the cap can be lowered, and a list written under a
        // larger one would otherwise stay long forever.
        let storedRecents = Self.storedMap(Self.recentsKey, from: defaults)
        recentsByRoot = storedRecents.keys.sorted().reduce(into: [:]) { out, rawKey in
            let key = Self.key(forRoot: rawKey)
            var list = out[key] ?? []
            for visit in storedRecents[rawKey] ?? []
            where !list.contains(where: { $0.relativePath == visit.relativePath }) {
                list.append(visit)
            }
            out[key] = Array(list.prefix(Self.maxRecents))
        }
        // Stays, through the same re-keying, merged per folder where two spellings meet.
        staysByRoot = Self.rekeyedStays(Self.storedStays(from: defaults), moving: { $0 })
        // Not seeded, and never written on load. An empty order means "nothing dragged yet", and
        // `orderedFavorites` falls back to the default order for every key it doesn't name.
        // Writing defaults during a read is how a misread destroys what it misread (see
        // `storedMap`'s three states).
        favoriteOrder = defaults.stringArray(forKey: Self.favoriteOrderKey) ?? []
        // Reset All Settings removes recents and stays while the app runs (it keeps pins and their
        // order); forget them here, or the next visit writes them back.
        change = observeDefaultsChanges(of: defaults) { [weak self] in self?.forgetWhatWasRemoved() }
    }

    deinit { if let change { NotificationCenter.default.removeObserver(change) } }

    /// Drops a list whose key has gone while this store holds it. Nothing here removes either key
    /// (an empty list is written, not removed), so a missing key was taken from outside, and
    /// writing it back would undo that.
    private func forgetWhatWasRemoved() {
        if !recentsByRoot.isEmpty, defaults.object(forKey: Self.recentsKey) == nil { recentsByRoot = [:] }
        if !staysByRoot.isEmpty, defaults.object(forKey: Self.staysKey) == nil { staysByRoot = [:] }
    }

    /// The composite key one favorite is identified by across the whole section.
    ///
    /// `\u{0}` separates because it can't occur in a POSIX path; with `/` or `:`, `("a/b", "c")` and
    /// `("a", "b/c")`, two different folders, would share a key.
    public nonisolated static func favoriteKey(root: String, relativePath: String) -> String {
        "\(root)\u{0}\(relativePath)"
    }

    /// The Favorites section in the user's own order.
    ///
    /// Entries the stored order names come first, in that order; the rest follow in the default
    /// root-sorted order. So a favorite added after the last drag, or every favorite on an install
    /// that never dragged, appends rather than jumping to the front or vanishing, with no
    /// migration. Stored keys that name nothing are ignored, so a removed favorite can't leave a hole
    /// or come back.
    nonisolated static func orderedFavorites(_ favorites: [RememberedVisit],
                                             order: [String]) -> [RememberedVisit] {
        guard !order.isEmpty else { return favorites }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // A stable partition, not one `sorted(by:)` over an optional rank: `sorted(by:)` isn't
        // stable in Swift, so the unranked tail could shuffle between runs.
        var ranked: [(RememberedVisit, Int)] = []
        var unranked: [RememberedVisit] = []
        for favorite in favorites {
            let key = favoriteKey(root: favorite.root, relativePath: favorite.relativePath)
            if let index = rank[key] { ranked.append((favorite, index)) } else { unranked.append(favorite) }
        }
        ranked.sort { $0.1 < $1.1 }
        return ranked.map(\.0) + unranked
    }

    /// One of the stored maps, with bytes this build can't read preserved rather than replaced.
    ///
    /// Three states, and the middle one is why this is not a `try?` at the call site:
    ///
    /// - Absent: a fresh install, or a list never written. Nothing to lose; empty is the truth.
    /// - Present and undecodable: a shape from another build, or a hand-edited plist. The bytes go
    ///   to ``salvageKey(for:)`` before the store carries on empty, so the next write can't destroy
    ///   them.
    /// - Present and decodable: the ordinary case.
    ///
    /// Recents get the same treatment as pins, though they regenerate: the lists are read side by
    /// side, and one rule for both needs no remembering which.
    static func storedMap(_ key: String, from defaults: UserDefaults) -> [String: [JumpLocation]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        if let decoded = try? JSONDecoder().decode([String: [JumpLocation]].self, from: data) {
            return decoded
        }
        preserveUnreadable(data, from: key, in: defaults)
        return [:]
    }

    /// The stay record, with the same three states as ``storedMap(_:from:)``: unreadable bytes are
    /// kept, not written over by the next stay.
    static func storedStays(from defaults: UserDefaults) -> [String: [String: FolderStays]] {
        guard let data = defaults.data(forKey: staysKey) else { return [:] }
        if let decoded = try? JSONDecoder().decode([String: [String: FolderStays]].self, from: data) {
            return decoded
        }
        preserveUnreadable(data, from: staysKey, in: defaults)
        return [:]
    }

    /// Stashes undecodable bytes once, under ``salvageKey(for:)``.
    ///
    /// **Only if nothing is stashed already**: the first failure holds the user's real list. A later
    /// launch may read what the store has since written, a valid, nearly empty map, and letting
    /// that overwrite the stash would destroy what it exists to keep.
    private static func preserveUnreadable(_ data: Data, from key: String, in defaults: UserDefaults) {
        let salvage = salvageKey(for: key)
        guard defaults.data(forKey: salvage) == nil else { return }
        defaults.set(data, forKey: salvage)
        Logger.shared.warning("\(key) is present but could not be read — its \(data.count) bytes were "
                              + "kept under \(salvage) rather than overwritten, and the list starts "
                              + "empty this session")
    }

    /// The one place a provider root becomes a key. Every entry point routes through it, so either
    /// spelling of a root reaches the same entry.
    ///
    /// A folder source's path keeps its `~`, and the app carries both forms: the panes and the
    /// breadcrumb hand over `settings.rootPath(for:)` as stored, while surfaces that touch the disk
    /// expand it. As raw keys the two would never meet, and "no pins" looks like a provider with
    /// none, so nothing would say so.
    ///
    /// Public because `FolderSidebarRow.root` is normalised through this, so a host comparing a
    /// row's root with a provider's path must normalise the same way. The rule lives in
    /// `PathBoundary.normalizedRoot` so `RootsMigration`, which writes these keys from a module
    /// that can't import this one, spells them identically by construction.
    public nonisolated static func key(forRoot root: String) -> String {
        PathBoundary.normalizedRoot(root)
    }

    func recents(forRoot root: String) -> [JumpLocation] { recentsByRoot[Self.key(forRoot: root)] ?? [] }
    func pinned(forRoot root: String) -> [JumpLocation] { pinnedByRoot[Self.key(forRoot: root)] ?? [] }

    /// The pinned folders for a root, as relative paths: the ⌘K palette's Folders group of recent
    /// and pinned paths.
    ///
    /// Public and `[String]` rather than exposing `JumpLocation`: the palette derives its own label,
    /// and exporting the menu's value type would make every field of it API. Keep this store the one
    /// recents list: a second, built from back/forward history, would disagree the first time a
    /// scan moved a pane without pushing history.
    public func pinnedPaths(forRoot root: String) -> [String] {
        pinned(forRoot: root).map(\.relativePath)
    }

    /// The recently visited folders for a root, most recent first, excluding anything pinned: a
    /// folder under two headings is a wasted row in a list of eight.
    public func recentPaths(forRoot root: String) -> [String] {
        let pins = Set(pinnedPaths(forRoot: root))
        return recents(forRoot: root).map(\.relativePath).filter { !pins.contains($0) }
    }

    func isPinned(root: String, relativePath: String) -> Bool {
        (pinnedByRoot[Self.key(forRoot: root)] ?? []).contains { $0.relativePath == relativePath }
    }

    /// Records a visited folder, moving it to the front and capping the list. The provider root is
    /// never recent (it is one crumb click away), so an empty relative path is ignored.
    /// - Parameter at: injected, like `opensInNewTab(_:)`'s modifiers and `reachable`'s
    ///   `isDirectory`, so tests of the ordering it feeds don't race the clock.
    public func recordVisit(root: String, relativePath: String, name: String, at: Date = Date()) {
        guard !relativePath.isEmpty, !name.isEmpty else { return }
        let visited = JumpLocation(relativePath: relativePath, name: name, visitedAt: at)
        let key = Self.key(forRoot: root)
        recentsByRoot[key] = Self.inserting(visited, into: recentsByRoot[key] ?? [], cap: Self.maxRecents)
        persistRecents()
    }

    /// Pins or unpins a folder for its pane's provider; the same menu item toggles. Public for the
    /// Browse sidebar, a second surface onto the same lists, whose Add to and Remove from Favorites
    /// call it from a row and from a pane's folder alike.
    public func togglePin(root: String, relativePath: String, name: String) {
        let key = Self.key(forRoot: root)
        var list = pinnedByRoot[key] ?? []
        // `removeAll`, not `remove(at: firstIndex)`: a list stored before the keys were normalised
        // can hold one folder twice (see `init`), and removing one copy would leave it pinned.
        // `init` dedupes what it reads; this also covers a store built in memory.
        let before = list.count
        list.removeAll { $0.relativePath == relativePath }
        if list.count == before {
            // No date on a favorite: favorites keep the user's curated order, so a timestamp would
            // be a field nothing reads that still had to be kept correct.
            list.append(JumpLocation(relativePath: relativePath, name: name, visitedAt: nil))
        }
        pinnedByRoot[key] = list
        persistPinned()
    }

    /// Takes one folder out of Recents: the sidebar's "Remove from Recents".
    ///
    /// Forgotten, not suppressed. A persisted list of folders Recents may not show would be a
    /// second store to keep in step, and it would drift the first time a root was re-keyed or a
    /// volume renamed. Removing the record is the whole answer.
    ///
    /// Visiting the folder again writes it back, on purpose: the row means "you were here
    /// recently", and a removal that outlived the next visit would be a hidden preference the user
    /// could never see again. Favorites is the curated list, one menu item away on the same row.
    ///
    /// `removeAll` to match ``togglePin(root:relativePath:name:)``. Recents can't hold one folder
    /// twice today (`init`, `inserting(_:into:cap:)` and `rekeyed(_:whenVolumeMovedFrom:to:)` all
    /// dedupe), so this only keeps it correct if one of those stops; no test, since one would need
    /// a duplicate no code path can produce.
    ///
    /// Silent, and doesn't persist, when nothing matched: a missing entry is not an error, and a
    /// write would rewrite the whole map for nothing.
    ///
    /// The folder's stays go with it, so the same item works on a Revisited row, which is drawn
    /// from the stay record.
    public func forgetRecent(root: String, relativePath: String) {
        let key = Self.key(forRoot: root)
        if staysByRoot[key]?.removeValue(forKey: relativePath) != nil {
            if staysByRoot[key]?.isEmpty == true { staysByRoot[key] = nil }
            persistStays()
        }
        guard var list = recentsByRoot[key] else { return }
        let before = list.count
        list.removeAll { $0.relativePath == relativePath }
        guard list.count != before else { return }
        recentsByRoot[key] = list
        persistRecents()
    }

    // MARK: - Stays, for Revisited and Frequent

    /// A pane arrived at a folder. Called on every pane folder change beside `recordVisit`, but
    /// records nothing yet. The folder the pane is leaving is settled first: after
    /// ``stayThreshold`` it counts as a stay; sooner (a parent clicked through, a Back/Forward skim)
    /// it is dropped.
    ///
    /// A folder left after a stay and returned to inside ``returnGap`` is the same stay carrying on,
    /// so it doesn't count again.
    ///
    /// - Parameter pane: which pane, as any stable name. Each pane has one folder at a time, and the
    ///   left pane moving must not settle the right one's.
    public func noteArrival(pane: String, root: String, relativePath: String, name: String,
                            at: Date = Date()) {
        leave(pane, at: at)
        departures = departures.filter { at.timeIntervalSince($0.value) < Self.returnGap }
        // The root is never a recent, so never revisited either (see `recordVisit`).
        guard !relativePath.isEmpty, !name.isEmpty else { return }
        var folder = PaneFolder(root: root, relativePath: relativePath, name: name, at: at, counted: false)
        // Back within the gap, or the other pane is already there having stayed: one stay, going on.
        folder.counted = departures[folder.key] != nil
            || panes.values.contains { $0.key == folder.key && $0.counted }
        panes[pane] = folder
    }

    /// Counts every pane that has now stayed long enough, without waiting for it to move. The app
    /// calls this ``stayThreshold`` after each arrival, so a folder counts while you are still in
    /// it. Early or repeated calls are harmless: a young arrival is left alone, and nothing counts
    /// twice.
    public func settleStays(at now: Date = Date()) {
        for pane in panes.keys.sorted() { settle(pane, at: now) }
    }

    /// How long the app should wait after an arrival before calling ``settleStays(at:)``.
    public nonisolated static var settleDelay: Duration { .seconds(stayThreshold) }

    private func leave(_ pane: String, at now: Date) {
        settle(pane, at: now)
        guard let folder = panes.removeValue(forKey: pane) else { return }
        if folder.counted { departures[folder.key] = now }
    }

    private func settle(_ pane: String, at now: Date) {
        guard let folder = panes[pane], !folder.counted,
              now.timeIntervalSince(folder.at) >= Self.stayThreshold else { return }
        panes[pane]?.counted = true
        // Dated at the arrival: a stay settled late (by the next move, the morning after) still
        // happened when the pane got there.
        recordStay(root: folder.root, relativePath: folder.relativePath, name: folder.name, at: folder.at)
    }

    /// Records one stay and forgets what has aged out of the window.
    func recordStay(root: String, relativePath: String, name: String, at: Date) {
        let key = Self.key(forRoot: root)
        var folders = staysByRoot[key] ?? [:]
        var record = folders[relativePath] ?? FolderStays(name: name, stays: [])
        record.name = name
        record.stays = Array((record.stays + [at]).sorted().suffix(Self.maxStaysPerFolder))
        folders[relativePath] = record
        var all = staysByRoot
        all[key] = folders
        staysByRoot = Self.pruned(all, now: at, cap: Self.maxStayedFolders)
        persistStays()
    }

    /// The record with every stay older than the window dropped, every folder left with none
    /// dropped, and past `cap` folders the least recently stayed dropped.
    nonisolated static func pruned(_ stays: [String: [String: FolderStays]], now: Date,
                                   cap: Int) -> [String: [String: FolderStays]] {
        let cutoff = now.addingTimeInterval(-revisitWindow)
        var kept: [(root: String, path: String, record: FolderStays, last: Date)] = []
        for (root, folders) in stays {
            for (path, record) in folders {
                let live = record.stays.filter { $0 >= cutoff }
                guard let last = live.max() else { continue }
                kept.append((root, path, FolderStays(name: record.name, stays: live), last))
            }
        }
        if kept.count > cap {
            kept.sort {
                if $0.last != $1.last { return $0.last > $1.last }
                return ($0.root, $0.path) < ($1.root, $1.path)
            }
            kept = Array(kept.prefix(cap))
        }
        return kept.reduce(into: [:]) { out, entry in out[entry.root, default: [:]][entry.path] = entry.record }
    }

    /// What one stay (or day) counts for at `now`: 1 today, ½ after ``fadeHalfLifeDays``.
    nonisolated static func fadedWeight(of date: Date, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(date)) / 86_400
        return pow(0.5, ageDays / fadeHalfLifeDays)
    }

    /// A total weight of at least 1, with room for the rounding a sum of powers carries.
    private nonisolated static func weighsEnough(_ total: Double) -> Bool { total >= 1 - 1e-9 }

    /// One folder's standing in a mode, or nil when it isn't listed.
    ///
    /// - Revisited: stays on 2+ different calendar days, each day weighed by its latest stay,
    ///   summing to 1 or more. Ranked by the last stay, newest first.
    /// - Frequent: 2+ stays, every stay weighed, summing to 1 or more. Ranked by that sum. So three
    ///   stays this morning are Frequent and not Revisited.
    nonisolated static func standing(of stays: [Date], in mode: RecentsMode, now: Date,
                                     calendar: Calendar) -> (rank: Double, last: Date)? {
        let cutoff = now.addingTimeInterval(-revisitWindow)
        let live = stays.filter { $0 >= cutoff && $0 <= now }
        guard let last = live.max() else { return nil }
        switch mode {
        case .recents:
            return nil
        case .revisited:
            let latestPerDay = Dictionary(grouping: live, by: { calendar.startOfDay(for: $0) })
                .values.compactMap { $0.max() }
            let total = latestPerDay.reduce(0) { $0 + fadedWeight(of: $1, now: now) }
            guard latestPerDay.count >= revisitMinimum, weighsEnough(total) else { return nil }
            return (last.timeIntervalSinceReferenceDate, last)
        case .frequent:
            let total = live.reduce(0) { $0 + fadedWeight(of: $1, now: now) }
            guard live.count >= revisitMinimum, weighsEnough(total) else { return nil }
            return (total, last)
        }
    }

    /// The sidebar's Revisited or Frequent list across every root, with favorites and landing
    /// folders subtracted as ``mostRecentAcrossRoots(recents:favorites:landings:limit:)`` does, for
    /// the same reasons. Highest rank first, ties to the most recent stay, then root and path so the
    /// order is the same on every run. Pure, so every rule is asserted without a store or a clock.
    nonisolated static func stayedAcrossRoots(_ mode: RecentsMode,
                                              stays: [String: [String: FolderStays]],
                                              favorites: [String: [JumpLocation]],
                                              landings: [String: String] = [:],
                                              now: Date, calendar: Calendar = .current,
                                              limit: Int) -> [RememberedVisit] {
        guard limit > 0 else { return [] }
        var found: [(visit: RememberedVisit, rank: Double, last: Date)] = []
        for root in stays.keys.sorted() {
            var subtracted = Set((favorites[root] ?? []).map(\.relativePath))
            if let landing = landings[root] { subtracted.insert(landing) }
            for (path, record) in stays[root] ?? [:] where !subtracted.contains(path) {
                guard let standing = standing(of: record.stays, in: mode, now: now, calendar: calendar)
                else { continue }
                found.append((RememberedVisit(root: root, relativePath: path, name: record.name,
                                              visitedAt: standing.last),
                              standing.rank, standing.last))
            }
        }
        found.sort {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            if $0.last != $1.last { return $0.last > $1.last }
            if $0.visit.root != $1.visit.root { return $0.visit.root < $1.visit.root }
            return $0.visit.relativePath < $1.visit.relativePath
        }
        return Array(found.map(\.visit).prefix(limit))
    }

    /// The sidebar's Recents section in `mode`: plain Recents, or one of the two stayed lists. Only
    /// the sidebar asks; the ⌘K palette keeps its unfiltered per-root recents.
    public func visitsAcrossRoots(_ mode: RecentsMode, landings: [String: String] = [:],
                                  limit: Int = FolderJumpStore.maxRecents,
                                  now: Date = Date()) -> [RememberedVisit] {
        guard mode != .recents else { return recentVisitsAcrossRoots(landings: landings, limit: limit) }
        return Self.stayedAcrossRoots(mode, stays: staysByRoot, favorites: pinnedByRoot,
                                      landings: landings, now: now, limit: limit)
    }

    /// Written on every stay, far rarer than a visit, since a stay needs seconds in the folder.
    private func persistStays() {
        if let data = try? JSONEncoder().encode(staysByRoot) {
            defaults.set(data, forKey: Self.staysKey)
        } else {
            Logger.shared.error("The revisited-folders record could not be encoded for saving — the previously stored record is left in place")
        }
    }

    /// The stay record with each root passed through `moving` and then ``key(forRoot:)``; folders
    /// meeting under one key are merged, stays combined and the first name kept. Keys in sorted
    /// order so the merge is the same on every run.
    nonisolated static func rekeyedStays(_ stays: [String: [String: FolderStays]],
                                         moving: (String) -> String) -> [String: [String: FolderStays]] {
        var out: [String: [String: FolderStays]] = [:]
        for rawKey in stays.keys.sorted() {
            let key = Self.key(forRoot: moving(rawKey))
            for (path, record) in stays[rawKey] ?? [:] {
                if var existing = out[key]?[path] {
                    existing.stays = (existing.stays + record.stays).sorted()
                    out[key]?[path] = existing
                } else {
                    out[key, default: [:]][path] = record
                }
            }
        }
        return out
    }

    /// Written on every visit, which is every pane folder change. Cheap: eight small values per
    /// root, and `UserDefaults` coalesces its own disk writes. Persisting on quit instead would lose
    /// the list to a crash or force-quit, and it is worth only as much as it is current.
    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recentsByRoot) {
            defaults.set(data, forKey: Self.recentsKey)
        } else {
            // The read side preserves unreadable bytes; a write that silently skips is the same
            // loss one step earlier, so it at least gets a log line.
            Logger.shared.error("The recent-folders list could not be encoded for saving — the previously stored list is left in place")
        }
    }

    private func persistPinned() {
        if let data = try? JSONEncoder().encode(pinnedByRoot) {
            defaults.set(data, forKey: Self.pinnedKey)
        } else {
            Logger.shared.error("The pinned-folders list could not be encoded for saving — the previously stored list is left in place")
        }
    }

    /// The stored folders that are still there: filtered, never deleted.
    ///
    /// A recent or a pin can name a folder since renamed or deleted, or on a drive that is asleep.
    /// Offering it offers a destination that can't be reached; deleting it would let a sleeping
    /// disk quietly cost the user their pins. So the answer is drawn from the list, never written
    /// back: the entry survives and reappears when its drive does.
    ///
    /// The root is checked first, once for both lists, and a missing root ends it: under an
    /// unreachable network mount every `stat` can block, and one stall beats one per folder.
    ///
    /// Both lists and the root's own verdict, in one pass. A folder gone under a live root is not
    /// offered; but a root that is merely asleep would take out every recent and pin at once, and
    /// the ⌘K landing is that list, so hiding them opens a blank palette. So under a missing root
    /// the lists come back unchecked with `rootIsAvailable == false`, for the caller to mark
    /// unavailable rather than drop.
    ///
    /// `isDirectory` is injected so the rule is testable without a disk, and `nonisolated` so a
    /// caller off the main actor can use it.
    public nonisolated static func reachable(recents: [String], pinned: [String],
                                             underRoot root: String,
                                             isDirectory: (String) -> Bool) -> RememberedFolders {
        let base = key(forRoot: root)
        guard !base.isEmpty, isDirectory(base) else {
            return RememberedFolders(recents: named(recents), pinned: named(pinned),
                                     rootIsAvailable: false)
        }
        func present(_ relatives: [String]) -> [String] {
            named(relatives).filter { isDirectory((base as NSString).appendingPathComponent($0)) }
        }
        return RememberedFolders(recents: present(recents), pinned: present(pinned),
                                 rootIsAvailable: true)
    }

    /// The entries that name a folder at all. The root's own spellings are never rows: a `"."` under
    /// a live root exists, and would be offered as the place you already are.
    private nonisolated static func named(_ relatives: [String]) -> [String] {
        relatives.filter { !$0.isEmpty && $0 != "." }
    }

    /// The most recent visits across every root, newest first: the sidebar's Recents section, one
    /// global list of eight rather than eight per source.
    ///
    /// Per-source recents would change under you on every source switch and could never take you
    /// back to a folder in another account, the one thing a cross-source sidebar can do that Finder
    /// can't. The ⌘K palette keeps its per-root list, which is right for a palette aimed at one pane.
    ///
    /// `maxRecents` still bounds what is stored per root; this bounds what is shown.
    ///
    /// Four rules, in order:
    ///
    /// 1. Favorites are subtracted, per root, as `recentPaths(forRoot:)` does: a folder under two
    ///    headings is a wasted row in a list of eight.
    /// 2. Landing folders are subtracted too, per root (see `landings`).
    /// 3. Dated entries first, newest first.
    /// 4. Undated entries after every dated one (``JumpLocation/visitedAt``): unknown is not
    ///    `.distantPast`, but it is weaker evidence of recency than any date. Among themselves they
    ///    go by root, then position in that root's list: arbitrary but stable, since dictionary
    ///    order isn't, and a section that reshuffled every launch would look broken.
    ///
    /// Pure, `static` and `nonisolated`, so the rule is asserted without a store, disk, clock or
    /// main actor, like `reachable` and `key(forRoot:)`.
    ///
    /// - Parameter landings: each root's landing folder, root-relative: where a pane on that source
    ///   opens (`SettingsManager.openAt`). A Locations row is that source, and its landing is where
    ///   the click arrives, so merely visiting sources would fill the eight rows with their
    ///   `Documents` and `My Drive` landings, places already listed above.
    ///
    ///   Subtracted here, not where rows are drawn, because the cap is here: filtering the eight
    ///   afterwards would show fewer than eight and hide real recents behind the landings.
    ///
    ///   Only the landing itself, never the folders under it: `Documents/Taxes` is somewhere you
    ///   navigated to, and nothing else on the column takes you there.
    nonisolated static func mostRecentAcrossRoots(recents: [String: [JumpLocation]],
                                      favorites: [String: [JumpLocation]],
                                      landings: [String: String] = [:],
                                      limit: Int) -> [RememberedVisit] {
        guard limit > 0 else { return [] }
        var dated: [(RememberedVisit, Date)] = []
        var undated: [RememberedVisit] = []
        for root in recents.keys.sorted() {
            var pinned = Set((favorites[root] ?? []).map(\.relativePath))
            // No guard for an empty landing: that spelling is the source root, and `recordVisit`
            // never writes a recent for it, so nothing could match.
            if let landing = landings[root] { pinned.insert(landing) }
            for visit in recents[root] ?? [] where !pinned.contains(visit.relativePath) {
                let entry = RememberedVisit(root: root, relativePath: visit.relativePath,
                                            name: visit.name, visitedAt: visit.visitedAt)
                if let at = visit.visitedAt { dated.append((entry, at)) } else { undated.append(entry) }
            }
        }
        // `sorted(by:)` isn't stable in Swift, so two visits with one date could swap on any run;
        // root and path break the tie and make the order reproducible.
        dated.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.root != $1.0.root { return $0.0.root < $1.0.root }
            return $0.0.relativePath < $1.0.relativePath
        }
        return Array((dated.map(\.0) + undated).prefix(limit))
    }

    /// ``mostRecentAcrossRoots(recents:favorites:landings:limit:)`` against this store's two maps.
    ///
    /// - Parameter landings: root-relative landing folders, keyed by ``key(forRoot:)``. They are
    ///   `SettingsManager`'s, which this module can't see, so the caller supplies them. None by
    ///   default, the ⌘K palette's case: it asks per root and answers for one pane.
    public func recentVisitsAcrossRoots(landings: [String: String] = [:],
                                        limit: Int = FolderJumpStore.maxRecents) -> [RememberedVisit] {
        Self.mostRecentAcrossRoots(recents: recentsByRoot, favorites: pinnedByRoot,
                                   landings: landings, limit: limit)
    }

    /// Every favorite across every root, in each root's curated order with the roots sorted: the
    /// sidebar's Favorites section, which spans sources as Recents does. Roots sorted, not left to
    /// dictionary order, so the order is the same on every launch; then the drag order applies.
    public func favoriteVisitsAcrossRoots() -> [RememberedVisit] {
        let flat = pinnedByRoot.keys.sorted().flatMap { root in
            (pinnedByRoot[root] ?? []).map {
                RememberedVisit(root: root, relativePath: $0.relativePath,
                                name: $0.name, visitedAt: $0.visitedAt)
            }
        }
        return Self.orderedFavorites(flat, order: favoriteOrder)
    }

    /// Records the order a drag produced. The whole sequence is written, not a delta, so the stored
    /// list always fully answers for what is on screen; with a delta, the unranked tail's meaning
    /// would depend on when each entry was added.
    public func setFavoriteOrder(_ ordered: [RememberedVisit]) {
        favoriteOrder = ordered.map { Self.favoriteKey(root: $0.root, relativePath: $0.relativePath) }
        defaults.set(favoriteOrder, forKey: Self.favoriteOrderKey)
    }

    /// Follows a volume rename, so the pins, recents, stays and Favorites order on a card renamed in
    /// Finder stay attached to it.
    ///
    /// These maps are keyed by provider root, and a renamed card's root changes, so without this
    /// the entries survive on disk under a key nothing asks for. `reachable` wouldn't even show them
    /// missing: it filters what a root holds, and the root is what moved.
    /// `SettingsManager.followVolumeRename` moves the source itself; this moves the rest.
    ///
    /// Called on the `NSWorkspace` notification, which carries both URLs; see that method for why a
    /// rename is followed silently and an unplugged card is not touched.
    public func followVolumeRename(from oldVolume: String, to newVolume: String) {
        let pins = Self.rekeyed(pinnedByRoot, whenVolumeMovedFrom: oldVolume, to: newVolume)
        // Capped after the merge, the one place this can grow a list: two roots' recents can meet
        // under one key, and a list longer than the cap would otherwise stay long (as in `init`).
        let visits = Self.rekeyed(recentsByRoot, whenVolumeMovedFrom: oldVolume, to: newVolume)
            .mapValues { Array($0.prefix(Self.maxRecents)) }
        let order = Self.rekeyedFavoriteOrder(favoriteOrder, whenVolumeMovedFrom: oldVolume, to: newVolume)
        let stays = Self.rekeyedStays(staysByRoot) {
            FolderSource.repathed($0, whenVolumeMovedFrom: oldVolume, to: newVolume) ?? $0
        }
        let movedPins = pins != pinnedByRoot, movedVisits = visits != recentsByRoot
        let movedStays = stays != staysByRoot
        guard movedPins || movedVisits || movedStays || order != favoriteOrder else { return }
        if movedPins { pinnedByRoot = pins; persistPinned() }
        if movedVisits { recentsByRoot = visits; persistRecents() }
        if movedStays { staysByRoot = stays; persistStays() }
        if order != favoriteOrder {
            favoriteOrder = order
            defaults.set(favoriteOrder, forKey: Self.favoriteOrderKey)
        }
        Logger.shared.info("Volume renamed to \(newVolume): moved the pinned and recent folders held under \(oldVolume)")
    }

    /// One per-root map with every key on the renamed volume moved to its new root.
    ///
    /// Merged, not overwritten, where both keys exist, as when the user re-added the card under its
    /// new name and pinned something there: the destination's entries first, then the arrivals,
    /// deduplicated by relative path. Dropping either side would lose pins to a rename. Keys taken
    /// in sorted order so the merge is the same every time.
    nonisolated static func rekeyed(_ map: [String: [JumpLocation]],
                                    whenVolumeMovedFrom oldVolume: String,
                                    to newVolume: String) -> [String: [JumpLocation]] {
        var out: [String: [JumpLocation]] = [:]
        for rawKey in map.keys.sorted() {
            let moved = FolderSource.repathed(rawKey, whenVolumeMovedFrom: oldVolume, to: newVolume)
            let key = Self.key(forRoot: moved ?? rawKey)
            var list = out[key] ?? []
            for entry in map[rawKey] ?? []
            where !list.contains(where: { $0.relativePath == entry.relativePath }) {
                list.append(entry)
            }
            out[key] = list
        }
        return out
    }

    /// The Favorites order with the same rename applied to the root half of each composite key.
    ///
    /// Separate from ``rekeyed(_:whenVolumeMovedFrom:to:)`` because these are `root\u{0}relative`
    /// strings, and splitting on the wrong byte would make two folders share a key. Leaving the old
    /// root in place would drop every favorite on the renamed card to the unranked tail, a silent
    /// reordering of the section.
    nonisolated static func rekeyedFavoriteOrder(_ order: [String],
                                                 whenVolumeMovedFrom oldVolume: String,
                                                 to newVolume: String) -> [String] {
        order.map { entry in
            guard let separator = entry.firstIndex(of: "\u{0}") else { return entry }
            let root = String(entry[entry.startIndex..<separator])
            guard let moved = FolderSource.repathed(root, whenVolumeMovedFrom: oldVolume, to: newVolume)
            else { return entry }
            return Self.key(forRoot: moved) + String(entry[separator...])
        }
    }

    /// Pure move-to-front dedupe and cap (newest first), so the recents ordering is testable without
    /// the store's persistence.
    static func inserting(_ location: JumpLocation, into list: [JumpLocation], cap: Int) -> [JumpLocation] {
        var result = list.filter { $0.relativePath != location.relativePath }
        result.insert(location, at: 0)
        return Array(result.prefix(cap))
    }
}

/// Filesystem side of the quick-jump menu: the current folder's sibling directories.
enum FolderJump {
    /// The subfolders of the current folder's parent, excluding the current folder: the lateral hops
    /// neither the breadcrumb (up) nor back/forward (back) reach. Empty at the pane root or on any
    /// read error. Sorted in the file panes' localized-standard order. `nonisolated` and pure so it
    /// runs off the main thread; a large cloud directory would otherwise stall the menu.
    ///
    /// Hidden folders follow the pane's own rule, a leading dot, not `.skipsHiddenFiles`: that flag
    /// also drops `UF_HIDDEN` folders, which the pane lists, and iCloud Drive's `Desktop` and
    /// `Documents` are exactly that (hidden links, `PathBoundary.LinkedFolders`).
    ///
    /// The parent is composed through `PathBoundary.join`, which expands a tilde root and resolves a
    /// first component naming a linked folder: `contentsOfDirectory(at:)` returns nothing for a
    /// path whose last component is the link itself.
    nonisolated static func siblings(rootPath: String, relativePath: String, showHidden: Bool = false, fileManager: FileManager = .default, logError: (@Sendable (String) -> Void)? = nil, links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> [JumpLocation] {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let currentName = components.last else { return [] } // "" → root has no in-pane parent
        let parentComponents = components.dropLast()
        let parentRelative = parentComponents.joined(separator: "/")
        let parentAbsolute = PathBoundary.join(root: rootPath, relative: parentRelative, links: links)

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: parentAbsolute),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [])
        } catch {
            // A permission or IO failure shouldn't read silently as "no other folders".
            //
            // At debug, not the warning level used for per-item read failures: this fires once per
            // navigation (the caller re-lists on every folder change), so one unreadable parent
            // would log every time the user steps into any of its children, without bound. Nothing
            // is lost: the menu says "No other folders", and the breadcrumb and back/forward still
            // work. A repeating line about a working app is how a log stops being read.
            //
            // Logged through the injected closure so this stays `nonisolated` and pure; tests pass
            // no logger, and the caller supplies one captured on the main actor.
            logError?("Folder jump: couldn't list siblings under \(parentAbsolute): \(error.localizedDescription)")
            return []
        }

        // A link from the parent to a folder outside it reports `isDirectory == false` (the read
        // is about the link) but is a folder all the same, and the pane lists it as one. Known by
        // name, from the same table.
        let linked = PathBoundary.linkedFolders(atRoot: parentAbsolute, in: links)
        return entries.compactMap { url -> JumpLocation? in
            let name = url.lastPathComponent
            guard linked[name] != nil
                    || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            guard name != currentName, showHidden || !name.hasPrefix(".") else { return nil }
            let relative = parentRelative.isEmpty ? name : parentRelative + "/" + name
            return JumpLocation(relativePath: relative, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The quick-jump menu on the current-folder crumb: pinned, recent and sibling folders, plus a pin
/// toggle for the current folder. Siblings are listed off the main thread whenever the folder
/// changes, so opening the menu never waits on the disk.
struct FolderJumpMenu: View {
    let rootPath: String
    let relativePath: String
    let currentName: String
    /// The pane's live show-hidden-files state, so the menu's siblings match what the pane lists.
    let showHidden: Bool
    let onNavigate: (String) -> Void

    @ObservedObject private var store = FolderJumpStore.shared
    /// Sibling folders, listed off the main thread whenever the current folder (or the show-hidden
    /// setting) changes, so opening the menu never blocks on a large cloud directory.
    @State private var siblings: [JumpLocation] = []

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "chevron.down")
                .scaledFont(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Jump to a favorite, recent, or nearby folder")
        .accessibilityLabel("Jump to another folder")
        .task(id: "\(rootPath)|\(relativePath)|\(showHidden)") {
            let root = rootPath, rel = relativePath, hidden = showHidden
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            siblings = await Task.detached(priority: .userInitiated) {
                // `.debug` on purpose: this runs on every folder change, so a failure repeats per
                // navigation. The full reason is at the `logError?(…)` call inside `siblings`.
                FolderJump.siblings(rootPath: root, relativePath: rel, showHidden: hidden,
                                    logError: { logger.debug($0) })
            }.value
        }
    }

    @ViewBuilder
    private var content: some View {
        let pinned = store.pinned(forRoot: rootPath)
        // A recent entry for the folder you're already in would do nothing, so drop it.
        let recents = store.recents(forRoot: rootPath).filter { $0.relativePath != relativePath }
        // `siblings` is the preloaded @State, listed off-main on folder change, not a synchronous
        // directory read at menu-open time.

        if pinned.isEmpty && recents.isEmpty && siblings.isEmpty {
            Text("No other folders")
        }
        if !pinned.isEmpty {
            Section("Favorites") {
                ForEach(pinned) { jumpButton($0, pinned: true) }
            }
        }
        if !recents.isEmpty {
            Section("Recent") {
                ForEach(recents.prefix(6)) { jumpButton($0, pinned: store.isPinned(root: rootPath, relativePath: $0.relativePath)) }
            }
        }
        if !siblings.isEmpty {
            Section("Nearby folders") {
                ForEach(siblings.prefix(20)) { jumpButton($0, pinned: store.isPinned(root: rootPath, relativePath: $0.relativePath)) }
            }
        }

        Divider()
        let isCurrentPinned = store.isPinned(root: rootPath, relativePath: relativePath)
        Button {
            store.togglePin(root: rootPath, relativePath: relativePath, name: currentName)
        } label: {
            // "Favorites" and a star, as on the sidebar and the row menu; "pin" belongs to tabs (see
            // `FolderSidebarRow.Group`). The folder is named because every other item in this
            // menu is somewhere else.
            Label(isCurrentPinned ? "Remove “\(currentName)” from Favorites"
                                  : "Add “\(currentName)” to Favorites",
                  systemImage: isCurrentPinned ? "star.slash" : "star")
        }
        .disabled(relativePath.isEmpty) // the root is always reachable; pinning it adds nothing
    }

    private func jumpButton(_ location: JumpLocation, pinned: Bool) -> some View {
        Button {
            onNavigate(location.relativePath)
        } label: {
            Label(location.name, systemImage: pinned ? "star.fill" : "folder")
        }
    }
}
