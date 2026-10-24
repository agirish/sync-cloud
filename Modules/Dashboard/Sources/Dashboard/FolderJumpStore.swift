import SwiftUI
import Foundation
import Events
import Sync

/// One jump target within a provider pane: a folder to hop to, identified by its path relative to
/// the pane's provider root ("" is the root), plus the display name shown in the menu. `Sendable`
/// so the sibling enumeration can hand results back from a detached (off-main) task.
struct JumpLocation: Codable, Equatable, Identifiable, Hashable, Sendable {
    let relativePath: String
    let name: String
    /// When this folder was last visited — **optional, and the optionality is the migration.**
    ///
    /// Recents were stored as `{relativePath, name}` with no clock until v4.4, which made a
    /// cross-source "eight most recent" *uncomputable*: the per-root lists are each ordered, but
    /// two ordered lists cannot be interleaved without a time. The sidebar's global Recents section
    /// needs that interleaving, so the field arrives here.
    ///
    /// **`nil` means unknown, never "the beginning of time".** Every entry written before this
    /// build decodes with no date, and a defaulted `.distantPast` would be a claim — that those
    /// folders were visited longest ago — where the truth is that nobody recorded it. Unknown
    /// sorts *after* everything dated (``FolderJumpStore/mostRecentAcrossRoots``) and earns a real
    /// date the next time the folder is visited, so the list corrects itself through use rather
    /// than through a migration pass.
    ///
    /// Additive and therefore safe both ways, which matters because `FolderJumpStore.swift` is
    /// carried on all three release lines and they share a defaults domain: a v2.x or v3.x build
    /// writing an entry without this key produces exactly the `nil` this handles, and a v4.4 build
    /// writing one with it is an unknown key those decoders ignore.
    var visitedAt: Date?
    var id: String { relativePath }
}

/// One remembered visit **with the root it happened under** — what a cross-source list needs and
/// what the per-root accessors cannot express.
///
/// `JumpLocation` is deliberately root-less: it is stored *inside* a per-root list, so repeating the
/// root in every element would be a second place for the key to be wrong. That works right up until
/// the caller wants one list spanning every root, at which point the root stops being context and
/// becomes data — which is this type.
public struct RememberedVisit: Equatable, Sendable {
    /// The provider root, already normalised through `FolderJumpStore.key(forRoot:)`.
    public let root: String
    public let relativePath: String
    public let name: String
    /// `nil` for an entry recorded before v4.4 — see ``JumpLocation/visitedAt``.
    public let visitedAt: Date?

    public init(root: String, relativePath: String, name: String, visitedAt: Date?) {
        self.root = root
        self.relativePath = relativePath
        self.name = name
        self.visitedAt = visitedAt
    }
}

/// **What the sidebar's Recents heading lists** (SQ5, SR4) — its icon cycles through these.
///
/// The raw value is the heading's text and the stored setting, so an unknown stored value falls
/// back to plain Recents rather than to a list this build cannot draw.
public enum RecentsMode: String, CaseIterable, Sendable {
    /// Every folder you were last in, newest first — unchanged.
    case recents = "Recents"
    /// Folders stayed in on two or more different days, newest first (SQ1).
    case revisited = "Revisited"
    /// Folders stayed in most, by faded count of stays (SQ6, SQ8).
    case frequent = "Frequent"

    /// The mode one click of the heading's icon moves to: Recents → Revisited → Frequent → Recents.
    public var next: RecentsMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// **The stays one folder has had** — what Revisited and Frequent count.
///
/// A record of its own rather than a field on `JumpLocation`, because the lists answer different
/// questions over different spans. Recents is "where you were just now": eight per root, one date
/// each, written on every folder a pane shows. Revisited and Frequent look back 90 days, and the
/// folders that qualify are exactly the ones a run of one-offs pushes out of the eight before they
/// can be counted. (Decided 2026-10-19, SQ1/SQ2/SQ8.)
struct FolderStays: Codable, Equatable, Sendable {
    var name: String
    /// When each stay began, oldest first. Two are always ``FolderJumpStore/returnGap`` or more
    /// apart in time away — a return sooner than that continues the stay before it.
    var stays: [Date]
}

/// Both remembered lists as they should be drawn, and whether the root was there to be asked.
///
/// `rootIsAvailable == false` means the lists are **everything remembered, unchecked** — the caller
/// shows them, marked unavailable, rather than dropping them. See `FolderJumpStore.reachable`.
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

/// Backs the pane header's folder quick-jump menu. Each pane already has back/forward history and an
/// up-the-tree breadcrumb — both move *up and back*. This adds the lateral hops they can't reach:
/// sibling folders (from disk), the folders you've recently visited (this session), and a curated
/// set of pins (persisted). Keyed by the pane's provider ROOT path — stable and unique per provider —
/// so both panes and relaunches agree for the same provider.
@MainActor
public final class FolderJumpStore: ObservableObject {
    public static let shared = FolderJumpStore()

    /// Recents outlive the session, as of v4.2.
    ///
    /// They were in memory because they mean "where I've been just now" — true of the pane's own
    /// jump menu, and false of the ⌘K field, whose empty state IS this list. Session-scoped, the
    /// first ⌘K of the day opens on nothing at all: the one moment the user is most likely to want
    /// yesterday's folder is the one moment the app had forgotten it.
    @Published private(set) var recentsByRoot: [String: [JumpLocation]] = [:]
    /// Pins are curated and outlive the session, so they persist.
    @Published private(set) var pinnedByRoot: [String: [JumpLocation]] = [:]
    /// Each folder's stays, per root — see ``FolderStays``. Fed by
    /// ``noteArrival(pane:root:relativePath:name:at:)``, never by `recordVisit`.
    @Published private(set) var staysByRoot: [String: [String: FolderStays]] = [:]
    /// Each pane's current folder, when it arrived, and whether that visit has counted yet.
    /// Session-only: a folder open when the app quits was either stayed in already or was not.
    private var panes: [String: PaneFolder] = [:]
    /// When a pane last LEFT a folder it had stayed in, by `favoriteKey` — so a return inside
    /// ``returnGap`` continues that stay rather than starting another. Session-only too: a relaunch
    /// takes longer than the gap is worth arguing over.
    private var departures: [String: Date] = [:]

    private struct PaneFolder {
        let root: String
        let relativePath: String
        let name: String
        let at: Date
        var counted: Bool
        var key: String { FolderJumpStore.favoriteKey(root: FolderJumpStore.key(forRoot: root), relativePath: relativePath) }
    }

    /// The user's dragged order, empty until they drag something. **Public because the row builder
    /// outside this module has to apply it** — see `FolderSidebarModel.rows(sources:recents:favoriteOrder:)`.
    @Published public private(set) var favoriteOrder: [String] = []

    private let defaults: UserDefaults
    static let pinnedKey = "folderJumpPinnedByRoot"
    static let recentsKey = "folderJumpRecentsByRoot"
    /// How many recents are kept **per root**, and — since v4.4 — how many the sidebar's one global
    /// list shows. Public because the sidebar is outside this module and asks for the same eight;
    /// two constants meaning "how many recents" is how they come to disagree.
    ///
    /// `nonisolated` so it can be a default argument outside the main actor —
    /// `FolderSidebarModel.rows` applies the cap and is pure.
    public nonisolated static let maxRecents = 8
    static let staysKey = "folderJumpStaysByRoot"
    /// **How long a pane must stay in a folder for the visit to count as a stay** (SQ4).
    /// Long enough that a folder clicked through on the way down, or skimmed past with Back and
    /// Forward, never counts; short enough that opening a folder to read what is in it does.
    nonisolated static let stayThreshold: TimeInterval = 4
    /// **How long away before a return is a new stay** (SQ8). Stepping into a subfolder and back
    /// out is one stay, not two. A tuning default, not a decision.
    nonisolated static let returnGap: TimeInterval = 5 * 60
    /// How far back Revisited and Frequent look (SQ2): a stay older than this is forgotten.
    nonisolated static let revisitWindow: TimeInterval = 90 * 24 * 60 * 60
    /// "Revisited" means stayed in on this many different calendar days (SQ1); Frequent asks for
    /// this many stays (SQ8).
    nonisolated static let revisitMinimum = 2
    /// **The fade** (SQ7): a stay — or for Revisited, a day — weighs 0.5^(age in days / this), and
    /// a folder needs a total weight of 1 to be listed. Two days a month ago just make it; two days
    /// two months ago do not. A tuning default, not a decision, so it is one constant.
    nonisolated static let fadeHalfLifeDays: Double = 30
    /// The most stays one folder keeps — the newest. At the fade above, stays past the first few
    /// dozen change nothing a person can see, and the record is rewritten on every stay.
    nonisolated static let maxStaysPerFolder = 200
    /// **A ceiling on the folders the stay record holds**, across every root. Not the eight rows —
    /// the record has to reach well past those, or one-offs push the regulars out before their
    /// second day — but a bound all the same, because the record is rewritten on every stay and
    /// 90 days of a busy week's one-offs is otherwise unbounded. The least recently stayed go first.
    nonisolated static let maxStayedFolders = 500
    /// The user's own order for the Favorites section, as `root\u{0}relativePath` keys.
    ///
    /// **A separate key rather than a field on `JumpLocation`, and separate from `pinnedByRoot`'s
    /// own array order.** Favorites span every source, so the section is a concatenation of
    /// per-root lists — and a drag that moves a Dropbox favorite above an iCloud one has no
    /// representation in per-root arrays at all. The section is one flat list with source badges
    /// and no visible group boundary inside it, so an order that stopped at a source would be an
    /// invisible constraint: the row would snap back for no reason the user can see.
    ///
    /// `pinnedByRoot` stays the truth about *membership*; this is the truth about *sequence*.
    static let favoriteOrderKey = "folderJumpFavoriteOrder"

    /// Where bytes this build cannot decode are put, instead of being overwritten.
    ///
    /// **The failure this closes destroys the user's pins, and it destroys them on the NEXT write
    /// rather than on the read.** A `try?` that falls back to `[:]` leaves the store looking like a
    /// fresh install; the first `togglePin` after that encodes that empty map over the key and the
    /// real pins are gone. Absent and unreadable are not the same state, and only one of them is
    /// safe to write over.
    ///
    /// `PeopleStore` draws this line for `people.json` — "whether there is structured content to
    /// lose" — and answers it by REFUSING to write, because Settings ▸ People has a banner to
    /// explain the refusal with. This surface has none: the jump menu's pin item would simply stop
    /// working, which is this app's own named bug. So the bytes are kept and the store carries on,
    /// which loses nothing either way.
    static func salvageKey(for key: String) -> String { key + ".unreadable" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Re-keyed on the way in. Pins written before this store normalised its keys sit under
        // whatever spelling the writer happened to hold — `~/Documents` for a folder source —
        // and reading them back through `key(forRoot:)` would miss every one of them. A fix
        // that makes existing pins reachable must not begin by orphaning them.
        //
        // **Deduplicated as they merge, because the bug being repaired is what creates the
        // duplicates.** A folder pinned from the breadcrumb read as unpinned in the pane, so
        // pinning it again there was the obvious thing to do — and wrote a second entry for the
        // same folder under the other spelling. Concatenating the two lists lands that folder
        // twice on exactly the installs this migration exists for: the ⌘K palette then lists it
        // twice, and one unpin peels off one copy and leaves it pinned.
        //
        // Keys taken in sorted order so the merged ORDER is the same on every launch —
        // dictionary iteration is not, and pins are shown in the order they are held.
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
        // Recents, through the same re-keying — not for a legacy spelling (nothing ever wrote this
        // key before) but so the two lists cannot come to disagree about what a root is; they are
        // read side by side by the same callers.
        //
        // **Capped on the way in as well as on the way out.** The cap is a constant that can be
        // lowered, and a list written under a larger one would otherwise stay long forever.
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
        // **Not seeded, and never written on load.** An empty order means "the user has not dragged
        // anything", and `orderedFavorites` falls through to the deterministic default for every
        // key it does not name — the same shape `visitedAt` uses for entries written before it
        // existed. Seeding it here would mean writing to defaults during a read, which is exactly
        // how a misread destroys the thing it misread (see `storedMap`'s three states).
        favoriteOrder = defaults.stringArray(forKey: Self.favoriteOrderKey) ?? []
    }

    /// The composite key one favorite is identified by across the whole section.
    ///
    /// `\u{0}` as the separator because it is the one byte that cannot occur in a POSIX path — a
    /// `/` or a `:` would make `("a/b", "c")` and `("a", "b/c")` the same key, and those are two
    /// different folders in two different sources.
    public nonisolated static func favoriteKey(root: String, relativePath: String) -> String {
        "\(root)\u{0}\(relativePath)"
    }

    /// **The Favorites section in the user's own order.**
    ///
    /// Entries the stored order names come first, in that order; anything it does not name follows,
    /// in the deterministic root-sorted order the section had before anyone dragged. That second
    /// half is what makes this safe without a migration: a favorite added after the last drag, or
    /// every favorite on an install that has never dragged, simply appends rather than jumping to
    /// the front or vanishing.
    ///
    /// Keys in the stored order that name nothing are ignored, so a favorite removed while its key
    /// lingers cannot leave a hole or resurrect itself.
    nonisolated static func orderedFavorites(_ favorites: [RememberedVisit],
                                             order: [String]) -> [RememberedVisit] {
        guard !order.isEmpty else { return favorites }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // A stable partition rather than one `sorted(by:)` over an optional rank: `sorted(by:)` is
        // not a stable sort in Swift, so the unranked tail would be free to shuffle between runs.
        var ranked: [(RememberedVisit, Int)] = []
        var unranked: [RememberedVisit] = []
        for favorite in favorites {
            let key = favoriteKey(root: favorite.root, relativePath: favorite.relativePath)
            if let index = rank[key] { ranked.append((favorite, index)) } else { unranked.append(favorite) }
        }
        ranked.sort { $0.1 < $1.1 }
        return ranked.map(\.0) + unranked
    }

    /// One of the two stored maps, **with bytes this build cannot read preserved rather than
    /// silently replaced.**
    ///
    /// Three states, and the middle one is the whole reason this is not a `try?` at the call site:
    ///
    /// - **Absent** — a fresh install, or a list never written. Nothing to lose; empty is the truth.
    /// - **Present and undecodable** — a shape from another build, or a hand-edited plist. The
    ///   bytes go to ``salvageKey(for:)`` before the store carries on empty, so the next write
    ///   cannot be what destroys them.
    /// - **Present and decodable** — the ordinary case, unchanged.
    ///
    /// Recents get the same treatment as pins even though they regenerate by themselves: the two
    /// lists are read side by side by the same callers, and a rule that applied to one of them
    /// would be a rule somebody has to remember which.
    static func storedMap(_ key: String, from defaults: UserDefaults) -> [String: [JumpLocation]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        if let decoded = try? JSONDecoder().decode([String: [JumpLocation]].self, from: data) {
            return decoded
        }
        preserveUnreadable(data, from: key, in: defaults)
        return [:]
    }

    /// The stay record, with the same three states as ``storedMap(_:from:)`` — unreadable bytes are
    /// kept rather than written over by the next stay.
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
    /// **Only if nothing is stashed already**, and that is not tidiness: the FIRST failure is the
    /// one holding the user's real list. A later launch reads whatever the store has since written
    /// — quite possibly a valid, nearly empty map — and letting that overwrite the stash would
    /// destroy the thing the stash exists to keep, one launch later than the bug it replaces.
    private static func preserveUnreadable(_ data: Data, from key: String, in defaults: UserDefaults) {
        let salvage = salvageKey(for: key)
        guard defaults.data(forKey: salvage) == nil else { return }
        defaults.set(data, forKey: salvage)
        Logger.shared.warning("\(key) is present but could not be read — its \(data.count) bytes were "
                              + "kept under \(salvage) rather than overwritten, and the list starts "
                              + "empty this session")
    }

    /// **The one place a provider root becomes a key.** Every entry point below routes through it,
    /// so a caller holding either spelling of the same root reaches the same entry.
    ///
    /// A folder source's path keeps its `~`, and the app carries both forms: the panes and the
    /// breadcrumb hand over `settings.rootPath(for:)` as stored, while surfaces that touch the disk
    /// expand it first. Used raw as dictionary keys, those two never met — a folder pinned from the
    /// breadcrumb was missing from every reader holding the expanded form, and "no pins" is exactly
    /// what an unpinned provider looks like, so nothing said so.
    ///
    /// **The one spelling of a root.** Public since v4.4: `FolderSidebarRow.root` is normalised
    /// through this, so a host comparing a row's root against a provider's path has to normalise
    /// the same way or the two spellings never meet — which is the exact defect the migration in
    /// `init` exists to repair. The rule itself lives in `PathBoundary.normalizedRoot`, hoisted
    /// there so `RootsMigration` — which has to write these very keys from a module that cannot
    /// import this one — spells them identically by construction rather than by a copied body.
    public nonisolated static func key(forRoot root: String) -> String {
        PathBoundary.normalizedRoot(root)
    }

    func recents(forRoot root: String) -> [JumpLocation] { recentsByRoot[Self.key(forRoot: root)] ?? [] }
    func pinned(forRoot root: String) -> [JumpLocation] { pinnedByRoot[Self.key(forRoot: root)] ?? [] }

    /// The pinned folders for a root, as relative paths — the ⌘K palette's Folders group, which
    /// ROADMAP 14 asks to hold "recent and pinned paths".
    ///
    /// Public and `[String]` rather than exposing `JumpLocation`: the palette needs the path and
    /// derives its own label, and widening the menu's own value type to another module would make
    /// every field of it API. **This store is the one recents list.** A second one was written over
    /// the pane's back/forward history before this was found; two would disagree the first time a
    /// scan moved a pane without pushing history.
    public func pinnedPaths(forRoot root: String) -> [String] {
        pinned(forRoot: root).map(\.relativePath)
    }

    /// The recently visited folders for a root, most recent first, **excluding anything pinned** —
    /// a folder listed twice under two headings is one wasted row in a list of eight.
    public func recentPaths(forRoot root: String) -> [String] {
        let pins = Set(pinnedPaths(forRoot: root))
        return recents(forRoot: root).map(\.relativePath).filter { !pins.contains($0) }
    }

    func isPinned(root: String, relativePath: String) -> Bool {
        (pinnedByRoot[Self.key(forRoot: root)] ?? []).contains { $0.relativePath == relativePath }
    }

    /// Records a visited folder, moving it to the front and capping the list. The provider root
    /// itself is never "recent" — it is always one crumb click away — so an empty relative path is
    /// ignored.
    /// - Parameter at: injected rather than read here, for the reason `opensInNewTab(_:)` takes its
    ///   modifiers and `reachable` takes its `isDirectory`: a `Date()` inside this call can only be
    ///   asserted against another `Date()`, so the ordering rule it feeds would be pinned by tests
    ///   that race the clock they are testing.
    public func recordVisit(root: String, relativePath: String, name: String, at: Date = Date()) {
        guard !relativePath.isEmpty, !name.isEmpty else { return }
        let visited = JumpLocation(relativePath: relativePath, name: name, visitedAt: at)
        let key = Self.key(forRoot: root)
        recentsByRoot[key] = Self.inserting(visited, into: recentsByRoot[key] ?? [], cap: Self.maxRecents)
        persistRecents()
    }

    /// Pins or unpins a folder for its pane's provider. Pinning the folder that's already pinned
    /// removes it, so the same menu item toggles.
    /// Public since v4.2, for the Browse sidebar — a second surface onto the same two lists, where
    /// a pin it could show but not remove would send the user back to the menu it replaces.
    /// That surface shipped in v4.4, and the sidebar's own verbs are the caller — Add to and
    /// Remove from Favorites, on a row and on a pane's folder alike.
    public func togglePin(root: String, relativePath: String, name: String) {
        let key = Self.key(forRoot: root)
        var list = pinnedByRoot[key] ?? []
        // `removeAll`, not `remove(at: firstIndex)`: a list written before the keys were normalised
        // can hold the same folder twice (see `init`), and peeling off one copy leaves the folder
        // pinned after the user asked for it not to be. The migration dedupes what it reads, so
        // this is belt and braces — and it is the half that also protects a store built in memory.
        let before = list.count
        list.removeAll { $0.relativePath == relativePath }
        if list.count == before {
            // **No date on a favorite.** Favorites are held in the order the user curated them, so
            // a timestamp here would be a field nothing reads — and one that would then have to be
            // kept correct. Recents are the only list that is ordered by time.
            list.append(JumpLocation(relativePath: relativePath, name: name, visitedAt: nil))
        }
        pinnedByRoot[key] = list
        persistPinned()
    }

    /// **Takes one folder out of Recents** — the sidebar's "Remove from Recents", on a row the
    /// user does not want offered any more.
    ///
    /// **Forgotten, not suppressed.** The alternative — a persisted list of folders Recents may
    /// not show — is a second store to keep in step with this one, and the two would disagree the
    /// first time a root was re-keyed or a volume renamed (both of which move entries here and
    /// would have to be taught to move entries there). Recents is a record of where you have been;
    /// removing the record is the whole of the answer.
    ///
    /// **Visiting the folder again writes it back**, and that is the intended behaviour rather
    /// than a hole in it. The row means "you were here recently", so a fresh visit earns a fresh
    /// row; a removal that outlived the next visit would be a hidden preference the user set once
    /// and could never see again. Favorites is the list that is curated, and it is one context-menu
    /// item away on the same row.
    ///
    /// `removeAll` for symmetry with ``togglePin(root:relativePath:name:)``, which needs it: pins
    /// written before the keys were normalised can hold one folder twice. **Recents cannot reach
    /// that shape today** — `init` dedupes what it reads, `inserting(_:into:cap:)` dedupes on every
    /// visit, and `rekeyed(_:whenVolumeMovedFrom:to:)` dedupes on a volume rename — so this is the
    /// spelling that stays correct if any of those three ever stops, rather than a case with a test
    /// behind it. There is no test, deliberately: one would have to plant a duplicate no code path
    /// can produce, and would then be asserting about a fixture rather than about the app.
    ///
    /// Silent, and does not persist, when nothing matched — a root with no entries or a folder
    /// already gone is not an error, and a write here would rewrite the whole map for no change.
    ///
    /// **The folder's stays go with it**, so the same item works on a Revisited row: the row is
    /// drawn from the stay record, and a removal that left that record in place would do nothing
    /// the user could see.
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

    /// **A pane arrived at a folder.** Called on every pane folder change, beside `recordVisit` —
    /// and unlike it, this records nothing yet. The folder the pane is LEAVING is settled first:
    /// if the pane was there for ``stayThreshold`` it counts as a stay, and if not — a parent
    /// clicked through on the way down, a Back/Forward skim — it is dropped (SQ4).
    ///
    /// A folder left after a stay and returned to inside ``returnGap`` is the same stay carrying
    /// on, so it does not count again (SQ8).
    ///
    /// - Parameter pane: which pane, as any stable name — each pane has one folder at a time, and
    ///   the left pane moving must not settle the right one's.
    public func noteArrival(pane: String, root: String, relativePath: String, name: String,
                            at: Date = Date()) {
        leave(pane, at: at)
        departures = departures.filter { at.timeIntervalSince($0.value) < Self.returnGap }
        // The root is never a recent, so it is never revisited either — see `recordVisit`.
        guard !relativePath.isEmpty, !name.isEmpty else { return }
        var folder = PaneFolder(root: root, relativePath: relativePath, name: name, at: at, counted: false)
        // Back within the gap, or the other pane is already there having stayed: one stay, going on.
        folder.counted = departures[folder.key] != nil
            || panes.values.contains { $0.key == folder.key && $0.counted }
        panes[pane] = folder
    }

    /// **Counts every pane that has now stayed long enough**, without waiting for it to move. The
    /// app calls this ``stayThreshold`` after each arrival, so a folder counts while you are still
    /// in it. Early or repeated calls are harmless: an arrival younger than the threshold is left
    /// alone, and one already counted is not counted twice.
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
        // Dated at the ARRIVAL: a stay settled late — by the next move, the morning after — still
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
    /// dropped, and — past `cap` folders — the least recently stayed dropped.
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

    /// What one stay (or day) counts for at `now` — 1 today, ½ after ``fadeHalfLifeDays`` (SQ7).
    nonisolated static func fadedWeight(of date: Date, now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(date)) / 86_400
        return pow(0.5, ageDays / fadeHalfLifeDays)
    }

    /// A total weight of at least 1, with room for the rounding a sum of powers carries.
    private nonisolated static func weighsEnough(_ total: Double) -> Bool { total >= 1 - 1e-9 }

    /// **One folder's standing in a mode, or nil when it is not listed.**
    ///
    /// - **Revisited** (SQ1, SQ7): stays on 2+ different calendar days, each day weighed by its
    ///   latest stay, summing to 1 or more. Ranked by the last stay — newest first.
    /// - **Frequent** (SQ8, SQ6): 2+ stays, every stay weighed, summing to 1 or more. Ranked by
    ///   that sum. So three stays this morning are Frequent and not Revisited.
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

    /// **The sidebar's Revisited or Frequent list**, across every root, with favorites and landing
    /// folders subtracted exactly as ``mostRecentAcrossRoots(recents:favorites:landings:limit:)``
    /// subtracts them — the same column, the same reasons. Highest rank first, ties to the most
    /// recent stay, then by root and path so the order is the same on every run.
    ///
    /// Pure, like that one, so every rule is asserted without a store or a clock.
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

    /// The sidebar's Recents section in `mode` — plain Recents, or one of the two stayed lists.
    /// Only the sidebar asks: the ⌘K palette keeps its unfiltered per-root recents.
    public func visitsAcrossRoots(_ mode: RecentsMode, landings: [String: String] = [:],
                                  limit: Int = FolderJumpStore.maxRecents,
                                  now: Date = Date()) -> [RememberedVisit] {
        guard mode != .recents else { return recentVisitsAcrossRoots(landings: landings, limit: limit) }
        return Self.stayedAcrossRoots(mode, stays: staysByRoot, favorites: pinnedByRoot,
                                      landings: landings, now: now, limit: limit)
    }

    /// Written on every stay — far rarer than a visit, since a stay needs seconds in the folder.
    private func persistStays() {
        if let data = try? JSONEncoder().encode(staysByRoot) {
            defaults.set(data, forKey: Self.staysKey)
        } else {
            Logger.shared.error("The revisited-folders record could not be encoded for saving — the previously stored record is left in place")
        }
    }

    /// The stay record with each root passed through `moving` and then ``key(forRoot:)``, folders
    /// meeting under one key merged — their stays combined, the first name kept. Keys in sorted
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

    /// Written on every visit, which is every pane folder change. Cheap on purpose: a capped list
    /// of eight small values per root, and `UserDefaults` coalesces its own writes to disk — the
    /// alternative (persisting on quit) loses the whole list to a crash or a force-quit, and the
    /// list is worth exactly as much as it is current.
    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recentsByRoot) {
            defaults.set(data, forKey: Self.recentsKey)
        } else {
            // The read side treats unreadable bytes as a state worth preserving; a write that
            // silently skips is the same loss one step earlier, so it at least gets a line.
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

    /// The stored folders that are still there — **filtered, never deleted**.
    ///
    /// A recent or a pin can name a folder that has since been renamed, deleted, or that lives on a
    /// drive which is not awake right now. Offering it is offering a destination that cannot be
    /// delivered; deleting it would mean an external disk being asleep at the wrong moment quietly
    /// costs the user their pins. So the answer is drawn from the list rather than written back to
    /// it: the entry survives and reappears when its drive does.
    ///
    /// **The root is checked first, and a missing root ends it.** Under an unreachable network
    /// mount every `stat` can block, and one stall is better than one per remembered folder.
    ///
    /// `isDirectory` is injected so the rule is testable without a disk, and `nonisolated` so a
    /// caller off the main actor could use it.
    ///
    /// **Both lists and the root's own verdict, in one pass.** The distinction is the point: a
    /// folder that has gone under a live root should not be offered; a root that is merely asleep takes out **every** recent and **every** pin at once,
    /// and the ⌘K landing *is* that list, so hiding them turns "my drive is not awake" into a
    /// palette that opens blank. Those are different claims and this answers both: the lists come
    /// back unchecked with `rootIsAvailable == false`, for the caller to mark unavailable rather
    /// than drop. Decided 2026-08-19 (ROADMAP v4 §7), narrowing "a remembered folder that has gone
    /// does not appear" to the case where the root is actually there to be asked.
    ///
    /// One pass so the root is `stat`ed **once** for both lists — under an unreachable network
    /// mount every one of those can block.
    ///
    /// (There was a single-list form of this until 2026-08-19, answering a bare `[String]`. It
    /// yielded `[]` for a root that did not respond — the right answer to "is this one folder still
    /// there" and the wrong one to what ⌘K asks — and once the palette moved to this signature it
    /// had no caller left, kept alive only by four tests of its own. Deleted rather than left
    /// standing as a second way to ask one question.)
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

    /// The entries that name a folder at all. The root's own spellings are never rows — a `"."`
    /// under a live root exists, so without this it would be offered as a destination you are
    /// already at.
    private nonisolated static func named(_ relatives: [String]) -> [String] {
        relatives.filter { !$0.isEmpty && $0 != "." }
    }

    /// **The most recent visits across every root, newest first** — the sidebar's Recents
    /// section, which is one global list of eight rather than eight per source.
    ///
    /// Decided 2026-08-24. With eleven sources connected, per-source recents means the section
    /// changes under you whenever you switch source, and can never take you back to a folder in a
    /// different account — which is the one thing a cross-source sidebar can do that Finder cannot.
    /// The ⌘K palette keeps its per-root list, and that is not an inconsistency: a palette aimed at
    /// one pane should answer for that pane.
    ///
    /// **The per-root cap stays.** `maxRecents` still bounds what is *stored* per root; this bounds
    /// what is *shown*. Nothing about the store's size changes.
    ///
    /// Four rules, in order:
    ///
    /// 1. **Favorites are subtracted**, per root, exactly as `recentPaths(forRoot:)` does it — a
    ///    folder listed twice under two headings is one wasted row in a list of eight.
    /// 2. **Landing folders are subtracted too**, per root — see `landings`.
    /// 3. **Dated entries first, newest first.**
    /// 4. **Undated entries after every dated one** — see ``JumpLocation/visitedAt``: `nil` is
    ///    unknown, not `.distantPast`, but "we do not know when" is still weaker evidence of
    ///    recency than any actual date, so unknown yields to known. Among themselves they are
    ///    ordered by root and then by position in that root's list, which is arbitrary but
    ///    *stable*: dictionary iteration order is not, and a Recents section that reshuffled on
    ///    every launch would look broken.
    ///
    /// Pure, `static` and `nonisolated` — so the rule can be asserted without a store, a disk, a
    /// clock or a main actor, the same way `reachable` and `key(forRoot:)` are.
    ///
    /// - Parameter landings: each root's **landing folder**, root-relative — the folder a pane on
    ///   that source opens at (`SettingsManager.openAt`). Subtracted for the same reason favorites
    ///   are, and the redundancy is worse: a Locations row IS that source, one click away, and the
    ///   landing is where the click arrives. So merely *visiting* a source writes a recent for a
    ///   place already listed above, and with seven sources connected that filled seven of the
    ///   eight rows — `Documents` under OneDrive, `Documents` under Dropbox, `My Drive` under two
    ///   Drive accounts — leaving one row for anywhere the user actually went.
    ///
    ///   **Subtracted HERE rather than where the rows are drawn, because the cap is here.** A
    ///   filter applied to the eight this returns would show fewer than eight and leave real
    ///   recents unshown behind the landings that displaced them; this way the cap counts only
    ///   rows worth having.
    ///
    ///   Only the landing itself, never the folders under it: `Documents/Taxes` is somewhere you
    ///   navigated to and nothing else on the column will take you there.
    nonisolated static func mostRecentAcrossRoots(recents: [String: [JumpLocation]],
                                      favorites: [String: [JumpLocation]],
                                      landings: [String: String] = [:],
                                      limit: Int) -> [RememberedVisit] {
        guard limit > 0 else { return [] }
        var dated: [(RememberedVisit, Date)] = []
        var undated: [RememberedVisit] = []
        for root in recents.keys.sorted() {
            var pinned = Set((favorites[root] ?? []).map(\.relativePath))
            // No guard on an empty landing — that spelling means the source root, and `recordVisit`
            // refuses to write a recent for it, so the entry it would match cannot exist. A guard
            // here would be a clamp half nothing can reach and no test could hold to account.
            if let landing = landings[root] { pinned.insert(landing) }
            for visit in recents[root] ?? [] where !pinned.contains(visit.relativePath) {
                let entry = RememberedVisit(root: root, relativePath: visit.relativePath,
                                            name: visit.name, visitedAt: visit.visitedAt)
                if let at = visit.visitedAt { dated.append((entry, at)) } else { undated.append(entry) }
            }
        }
        // `sorted(by:)` is not a stable sort in Swift, so two visits sharing a date could swap on
        // any run. The root and path break the tie and make the whole order reproducible.
        dated.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.root != $1.0.root { return $0.0.root < $1.0.root }
            return $0.0.relativePath < $1.0.relativePath
        }
        return Array((dated.map(\.0) + undated).prefix(limit))
    }

    /// ``mostRecentAcrossRoots(recents:favorites:landings:limit:)`` against this store's two maps.
    ///
    /// - Parameter landings: root-relative landing folders, keyed by ``key(forRoot:)``. The store
    ///   does not know them — they are `SettingsManager`'s, and this module cannot see it — so the
    ///   caller supplies them. Defaulted to none, which is the ⌘K palette's case: it asks per root
    ///   and answers for one pane.
    public func recentVisitsAcrossRoots(landings: [String: String] = [:],
                                        limit: Int = FolderJumpStore.maxRecents) -> [RememberedVisit] {
        Self.mostRecentAcrossRoots(recents: recentsByRoot, favorites: pinnedByRoot,
                                   landings: landings, limit: limit)
    }

    /// **Every favorite, across every root**, in each root's curated order with the roots sorted —
    /// the sidebar's Favorites section, which spans sources exactly as Recents now does.
    ///
    /// Sorted by root rather than left to dictionary order for the reason above: the order has to
    /// be the same on every launch. Within a root the user's own order is preserved untouched.
    public func favoriteVisitsAcrossRoots() -> [RememberedVisit] {
        let flat = pinnedByRoot.keys.sorted().flatMap { root in
            (pinnedByRoot[root] ?? []).map {
                RememberedVisit(root: root, relativePath: $0.relativePath,
                                name: $0.name, visitedAt: $0.visitedAt)
            }
        }
        return Self.orderedFavorites(flat, order: favoriteOrder)
    }

    /// **Records the order a drag produced.** The whole sequence is written, not a delta, so the
    /// stored list is always a complete answer for what is on screen — a delta would leave the
    /// unranked tail's meaning depending on when each entry was added.
    public func setFavoriteOrder(_ ordered: [RememberedVisit]) {
        favoriteOrder = ordered.map { Self.favoriteKey(root: $0.root, relativePath: $0.relativePath) }
        defaults.set(favoriteOrder, forKey: Self.favoriteOrderKey)
    }

    /// **Follows a volume rename**, so the pins and recents on a card that was renamed in Finder
    /// stay attached to it.
    ///
    /// These maps are keyed by provider root, and a renamed card's root changes — so without this
    /// the pins survive on disk under a key nothing will ever ask for again. `reachable` would not
    /// even show them as missing: it filters what a root holds, and the root is what moved.
    /// `SettingsManager.followVolumeRename` moves the source itself; this is the same rename
    /// applied to the two per-root maps and to the Favorites order, so the card comes back whole.
    ///
    /// Called on the `NSWorkspace` notification, which carries both URLs — see that method for why
    /// a rename is followed silently and an unplugged card is not touched at all.
    public func followVolumeRename(from oldVolume: String, to newVolume: String) {
        let pins = Self.rekeyed(pinnedByRoot, whenVolumeMovedFrom: oldVolume, to: newVolume)
        // Capped after the merge, which is the one place this can grow a list: two roots' recents
        // meeting under one key is the merge case above, and `init` caps on the way in for the
        // same reason — a list written longer than the cap would otherwise stay long forever.
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
    /// **Merged rather than overwritten where both keys exist**, which is the case that arises when
    /// the user has already re-added the card under its new name and pinned something there: the
    /// destination's own entries come first and the arrivals are appended, deduplicated by relative
    /// path. Dropping either side would lose pins to a rename, which is what this exists to stop.
    /// Keys are taken in sorted order so the merged sequence is the same every time, the reason
    /// `init`'s own re-keying gives.
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
    /// strings rather than plain roots, and the separator is load-bearing: splitting on the wrong
    /// byte would make two different folders share one key. A key naming nothing is harmless —
    /// `orderedFavorites` ignores it — but leaving the old root in place would drop every favorite
    /// on the renamed card to the unranked tail, which is a silent reordering of the section.
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

    /// Pure move-to-front dedupe + cap (newest first). Extracted so the recents ordering is
    /// testable without the store's persistence.
    ///
    /// Its doc sat on `mostRecentAcrossRoots` for a while: v4.4 inserted the cross-source members
    /// between the two, and a doc comment attaches to whatever declaration follows it, so the note
    /// moved to a member it did not describe while this one went bare.
    static func inserting(_ location: JumpLocation, into list: [JumpLocation], cap: Int) -> [JumpLocation] {
        var result = list.filter { $0.relativePath != location.relativePath }
        result.insert(location, at: 0)
        return Array(result.prefix(cap))
    }
}

/// Filesystem side of the quick-jump menu: the current folder's sibling directories.
enum FolderJump {
    /// The immediate subfolders of the current folder's PARENT, excluding the current folder — the
    /// lateral hops neither the breadcrumb (up) nor back/forward (back) can reach. Returns an empty
    /// list at the pane root (no in-pane parent) or on any read error. Honors the pane's
    /// show-hidden-files setting so the jump menu matches what the pane shows — **by the pane's
    /// own rule, a leading dot**, not `.skipsHiddenFiles`: the flag also drops folders carrying
    /// `UF_HIDDEN`, which the pane lists, and iCloud Drive's `Desktop` and `Documents` are exactly
    /// that (hidden links, see `PathBoundary.LinkedFolders`) — so at `iCloud ▸ Documents` the menu
    /// offered every sibling but Desktop. Names sort with the same localized-standard order the
    /// file panes use. `nonisolated` and pure so it can run off the main thread (a large cloud
    /// directory would otherwise jank the menu-open).
    ///
    /// The parent is composed through `PathBoundary.join`, which expands a tilde root and takes a
    /// first component that names a linked folder to where that folder really is — the listing
    /// below is URL-based, and `contentsOfDirectory(at:)` returns nothing for a path whose last
    /// component is the link itself.
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
            // Don't silently read as "no other folders" — a permission/IO failure is worth a
            // breadcrumb.
            //
            // **Debug, not warning, even though house style puts benign per-item read failures at
            // warning.** Those fire once per item per scan; this fires once per *navigation*. The
            // caller re-enumerates on every folder change (`.task(id:)` keyed on root/path/hidden),
            // so one unreadable parent emits a line every time the user steps into any of its
            // children — without bound, for as long as they browse. And nothing is actually lost:
            // the menu says "No other folders", and sibling hops are a lateral convenience the
            // breadcrumb and back/forward already cover. A repeating line about a working app at
            // the default level is how a log stops being read.
            //
            // Logged via the injected closure so this stays `nonisolated` and pure — the tests call
            // it with no logger at all, and the caller supplies one captured on the main actor.
            logError?("Folder jump: couldn't list siblings under \(parentAbsolute): \(error.localizedDescription)")
            return []
        }

        // A link the parent carries to a folder outside it reports `isDirectory == false` — the
        // resource read is about the link — and is a folder all the same; the pane lists it as
        // one (the walk substitutes the target). Known by name, from the same table.
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

/// The quick-jump menu hung off the current-folder crumb: pinned, recent, and sibling folders, plus
/// a pin toggle for the current folder. Reads the shared store and the filesystem lazily, only when
/// the menu opens.
struct FolderJumpMenu: View {
    let rootPath: String
    let relativePath: String
    let currentName: String
    /// The pane's live show-hidden-files state, so the menu's siblings match what the pane lists.
    let showHidden: Bool
    let onNavigate: (String) -> Void

    @ObservedObject private var store = FolderJumpStore.shared
    /// Sibling folders, enumerated OFF the main thread whenever the current folder (or the
    /// show-hidden setting) changes, so opening the menu never blocks on a large cloud directory.
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
        .help("Jump to a pinned, recent, or nearby folder")
        .accessibilityLabel("Jump to another folder")
        .task(id: "\(rootPath)|\(relativePath)|\(showHidden)") {
            let root = rootPath, rel = relativePath, hidden = showHidden
            let logger = Logger.shared // captured on the main actor; its methods are nonisolated
            siblings = await Task.detached(priority: .userInitiated) {
                // `.debug` deliberately — this runs on every folder change, so the failure it
                // reports repeats per navigation rather than per item. Reasoning in full at the
                // `logError?(…)` call inside `siblings`.
                FolderJump.siblings(rootPath: root, relativePath: rel, showHidden: hidden,
                                    logError: { logger.debug($0) })
            }.value
        }
    }

    @ViewBuilder
    private var content: some View {
        let pinned = store.pinned(forRoot: rootPath)
        // A recent entry for the folder you're already in would be a no-op — drop it.
        let recents = store.recents(forRoot: rootPath).filter { $0.relativePath != relativePath }
        // `siblings` is the pre-loaded @State (scanned off-main on folder change), not a fresh
        // synchronous directory read at menu-open time.

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
            // "Favorites" and a star, as on the sidebar and the row menu — "pin" belongs to tabs
            // (decided 2026-08-24, recorded at `FolderSidebarRow.Group`). The folder is named
            // because every other item in this menu is somewhere else.
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
