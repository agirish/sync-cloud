import Foundation

/// One place row: a cloud account, a folder source, a disk, the Trash, or a standard folder
/// SyncCloud hasn't been given yet. Used by both Locations and the standard-folder half of
/// Favorites; ``band`` says which.
///
/// Cloud accounts and folder sources share a band because the model treats them as one thing: a
/// folder source is a `CloudProvider` with `type == .localFolder`, and every pane, lens, diff, undo
/// and CLI path handles it identically. The type only lets name rules and the Drive date-noise
/// filter tell them apart.
public struct SidebarSourceRow: Identifiable, Equatable, Sendable {

    /// What clicking this row will do, and how the row reads before you click it.
    ///
    /// "Local folder" means two things here: a folder source is a root the user added in Settings,
    /// while `~/Downloads`, if never added, is nothing to this app. The row says which case it is
    /// in before the click, so the click is never a surprise.
    public enum State: Equatable, Sendable {
        /// A configured source: a discovered cloud account, or a folder source in Settings.
        case configured
        /// A local shortcut whose folder lives inside an existing source, as macOS's Desktop &
        /// Documents syncing makes `~/Desktop` a link into `com~apple~CloudDocs`. Clicking
        /// navigates there inside the owning source; nothing is added, or two sources would scan
        /// one tree.
        ///
        /// Carries the owner's id, and its name only for display: re-resolving the owner by name
        /// would pick the wrong one of two same-named sources.
        case inside(sourceId: String, sourceName: String)
        /// A local shortcut SyncCloud doesn't know about. Clicking adds it as a folder source,
        /// scans it, and says so with an inline Remove.
        case unknown
        /// A place that opens in Finder and is never added as a source: the Trash, and only the
        /// Trash. As a source it would be scanned, hashed, offered as a filing target and counted
        /// in Storage, though its contents are on their way out.
        case revealOnly
    }

    /// The provider id for a configured source; the absolute path for one that is not a source yet.
    public let id: String
        /// The leaf name: `Dropbox`, `Drive`, `Downloads`.
    public let name: String
    /// Shown only when needed to tell two rows apart, or when a shortcut lives inside another
    /// source. Three Google Drive accounts all read `Drive` without it.
    public let detail: String?
    /// The provider's mark, or an SF Symbol for a local folder.
    public let symbol: String
    public let absolutePath: String
    /// Which band of the column this row belongs to. A band rather than a Bool, because a Google
    /// Drive account, a mounted SD card and `~/Desktop` are three different things in two sections.
    public let band: Band

    /// Where a row sits, and therefore what it is. The cases are in drawing order, which is
    /// Finder's: the clouds you signed into, then the hardware, then the Trash.
    public enum Band: Int, Comparable, Sendable, CaseIterable {
        /// A cloud account or a folder source: something SyncCloud syncs.
        case cloud
        /// The home folder, the startup disk, an external drive, a mounted card.
        case device
        /// The Trash, which is last and unlike the others (see ``State/revealOnly``).
        case trash
        /// A standard folder that lives in Favorites, not here: Desktop, Documents, Downloads.
        case shortcut

        public static func < (a: Band, b: Band) -> Bool { a.rawValue < b.rawValue }
    }
    public let state: State
    /// False when the root didn't answer. The row stays listed and refuses, as folder rows do: a
    /// source that is asleep hasn't gone.
    public let isAvailable: Bool

    public init(id: String, name: String, detail: String?, symbol: String, absolutePath: String,
                band: Band, state: State, isAvailable: Bool) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.absolutePath = absolutePath
        self.band = band
        self.state = state
        self.isAvailable = isAvailable
    }

    /// Dimmed means "not answering", and nothing else. Not `.unknown`: on a fresh install every
    /// disk is unknown, and a column of grey rows reads as broken. Finder doesn't dim your disks
    /// either. What is unusual about an unadded place belongs in the tooltip and the notice the
    /// click produces.
    public var isDimmed: Bool { !isAvailable }

    /// Whether this row lives in Favorites rather than Locations.
    public var isFavoriteShortcut: Bool { band == .shortcut }

    /// The same place, in the other section. Favoriting a place moves its row rather than copying
    /// it: one place, one row, the invariant the builder's `claimed` set keeps. Two `Dropbox` rows
    /// would make "which one do I remove?" a question.
    public func inBand(_ band: Band) -> SidebarSourceRow {
        SidebarSourceRow(id: id, name: name, detail: detail, symbol: symbol,
                         absolutePath: absolutePath, band: band, state: state,
                         isAvailable: isAvailable)
    }
}

/// What a source row is named, and when it needs qualifying. Separate from the view so the rule
/// can be asserted without mounting anything, and from `FolderSidebarModel` because it answers a
/// different question about a different list.
public enum SidebarSourceModel {

    /// The three standard folders that exist only as Favorites rows: Desktop, Documents and
    /// Downloads, the three a person files into.
    ///
    /// Not the whole of Favorites: ``SidebarFavoritePlaces/standard`` also puts the home folder
    /// above these. Home is absent here because it heads `deviceEntries()`, and a second entry
    /// would build two rows for one folder; the startup disk likewise. Membership of the Favorites
    /// list decides a place's section; this is only the set with no Locations row to fall back to.
    ///
    /// Fixed and short: any other folder is a preference, and adding a folder source covers it.
    /// Applications is left out because every Favorites row is a drop target, and a row you can
    /// drop a document onto should be somewhere you would file one.
    public static let favoriteShortcuts: [(name: String, symbol: String, path: String)] = [
        ("Desktop", "menubar.dock.rectangle", NSHomeDirectory() + "/Desktop"),
        ("Documents", "doc", NSHomeDirectory() + "/Documents"),
        ("Downloads", "arrow.down.circle", NSHomeDirectory() + "/Downloads"),
    ]

    /// The home folder, which heads the device band in Locations. ``SidebarFavoritePlaces/standard``
    /// favorites it, so by default it is drawn at the top of Favorites and the device band starts
    /// at the volumes. It is built as a device row either way, so taking it out of Favorites
    /// returns it to Locations rather than removing it from the column.
    public static let homeEntry: (name: String, symbol: String, path: String) =
        (NSUserName(), "house", NSHomeDirectory())

    /// The Trash, last in Locations and the one row that never becomes a source.
    public static let trashEntry: (name: String, symbol: String, path: String) =
        ("Trash", "trash", NSHomeDirectory() + "/.Trash")

    /// A mounted volume, as the sidebar needs it. Injected rather than read here so the rule that
    /// turns volumes into rows is testable without plugging in a card.
    public struct Volume: Equatable, Sendable {
        public let name: String
        public let path: String
        /// Removable or ejectable: an SD card, a USB stick, an external disk. Decides the glyph and
        /// nothing else; a card is browsed exactly like the startup disk.
        public let isRemovable: Bool
        /// The startup disk. Drawn first among the volumes, because it is always there.
        public let isInternal: Bool
        /// Local, as opposed to a network share. The row doesn't use it, but
        /// ``MountedVolumeMemory`` does: a share is `ejectable` too, and only a card being pulled
        /// means its sources are gone for good. Defaults to `true`, what an SD card is, so a test
        /// fixture can't silently exempt itself from the rule.
        public let isLocal: Bool

        public init(name: String, path: String, isRemovable: Bool, isInternal: Bool,
                    isLocal: Bool = true) {
            self.name = name
            self.path = path
            self.isRemovable = isRemovable
            self.isInternal = isInternal
            self.isLocal = isLocal
        }

        /// Whether unmounting this volume means its sources are gone, not asleep. Named once so
        /// the eject confirmation and `MountedVolumeMemory` can't answer it differently. A share
        /// is ejectable (Finder draws it an eject arrow) but not local, and a share that drops
        /// comes back, so the volume must be both.
        public var losesItsSourcesOnUnmount: Bool { isRemovable && isLocal }

        /// `internaldrive` for the startup disk, `sdcard` for something you can pull out,
        /// `externaldrive` for a disk that is neither.
        public var symbol: String {
            if isInternal { return "internaldrive" }
            return isRemovable ? "sdcard" : "externaldrive"
        }
    }

    /// Volumes in the order Locations draws them: the startup disk, then everything else by name.
    /// Sorted, not left in mount order, which changes between launches and would rearrange the
    /// disks on every boot.
    public static func orderedVolumes(_ volumes: [Volume]) -> [Volume] {
        volumes.sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Qualify a name only when another row shares it: the duplicate-leaf rule that
    /// `FolderSidebarModel.rows` applies to folders, pointed at sources.
    ///
    /// Three Google Drive accounts and two OneDrive accounts would otherwise each render one word.
    /// Naming the difference inline beats Finder's hover tooltip, and rows that don't collide stay
    /// bare, since a qualifier on every row is the other failure.
    /// - Parameter names: the leaf name of every row that will be on screen together, in order.
    /// - Parameter qualifiers: what to say about each, when it has to be said.
    /// - Returns: the qualifier for each row, or `nil` where the name stands alone.
    public static func qualifiers(names: [String], qualifiers candidates: [String?]) -> [String?] {
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return zip(names, candidates).map { name, candidate in
            guard (counts[name] ?? 0) > 1, let candidate, !candidate.isEmpty else { return nil }
            return candidate
        }
    }

    /// Which existing source contains this path, if any: the check before a local shortcut is
    /// promoted to a source of its own.
    ///
    /// Under Desktop & Documents syncing `~/Desktop` is a link into `com~apple~CloudDocs`, so a
    /// plain path comparison misses iCloud Drive. `SettingsManager.addFolderSource` refuses a path
    /// that equals a source's root, but a contained path would pass, leaving two sources scanning
    /// one tree, double-counted in Storage. So: resolve symlinks on both sides, then test
    /// containment, longest root first so a nested source resolves to the more specific one.
    ///
    /// - Parameter resolve: injected so the rule is testable without a disk. Production passes
    ///   `URL(fileURLWithPath:).resolvingSymlinksInPath().path`.
    public static func owningSource(of path: String,
                                    among roots: [(id: String, name: String, path: String)],
                                    resolve: (String) -> String) -> (id: String, name: String)? {
        let target = resolve(path)
        var best: (id: String, name: String, length: Int)?
        for root in roots {
            let base = resolve(root.path)
            guard !base.isEmpty, contains(target, under: base) else { continue }
            if base.count > (best?.length ?? -1) { best = (root.id, root.name, base.count) }
        }
        return best.map { ($0.id, $0.name) }
    }

    /// Whether two paths name the same folder, normalised and case-folded. Its own member because
    /// "is this shortcut already a source" is a different question from "is it inside one", even
    /// though one rule can answer both.
    public static func isSameFolder(_ a: String, _ b: String) -> Bool {
        trimmed(a.lowercased()) == trimmed(b.lowercased())
    }

    /// Path containment on component boundaries, case-folded.
    ///
    /// Not `hasPrefix`, which reports `/Users/ab/Downloads2` as inside `/Users/ab/Downloads`.
    /// Case-folded because the default macOS volume is case-insensitive, and claiming is the safe
    /// direction: a wrong claim costs a visible navigation, a missed one an unnoticed duplicate
    /// source. Trailing slashes are stripped from both sides, because a provider Location is
    /// user-typed, and `…/Downloads/` as the base would put the source's own root outside itself.
    /// `FolderJumpStore.key(forRoot:)` normalises the same way.
    public static func contains(_ path: String, under base: String) -> Bool {
        let p = trimmed(path.lowercased()), b = trimmed(base.lowercased())
        guard !b.isEmpty else { return false }
        if p == b { return true }
        return p.hasPrefix(b + "/")
    }

    /// A path with any trailing slashes removed, keeping a bare `/` intact.
    private static func trimmed(_ path: String) -> String {
        var out = path
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }
}


/// Where a dragged row lands.
///
/// Pure arithmetic over measured geometry, kept apart because an off-by-one puts the row one place
/// from where the user aimed, which reads as a broken drag. It uses measured midpoints, not a row
/// height: a favorite with a parent qualifier draws a second line, so `translation / rowHeight`
/// drifts further the further you drag.
public enum SidebarReorder {

    /// The index a row dragged to `y` should be inserted at.
    ///
    /// - Parameter midpoints: each row's vertical midpoint, in the order the rows are drawn, in the
    ///   same coordinate space as `y`.
    /// - Returns: an insertion index in `0...midpoints.count`.
    ///
    /// Insertion semantics, not swap: the answer is a gap between rows, where the insertion line is
    /// drawn. Above every midpoint is 0; below every midpoint is the end.
    public static func insertionIndex(forY y: CGFloat, midpoints: [CGFloat]) -> Int {
        var index = 0
        for midpoint in midpoints {
            if y < midpoint { break }
            index += 1
        }
        return index
    }

    /// The list after moving the item at `from` to insertion index `to`.
    ///
    /// `to` is an insertion index into the original list: dragging row 0 to the gap after row 2
    /// gives `to == 3`, but once row 0 is lifted out the destination is 2. Getting this backwards
    /// makes every downward drag land one short.
    public static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), to >= 0, to <= items.count else { return items }
        var out = items
        let item = out.remove(at: from)
        out.insert(item, at: to > from ? to - 1 : to)
        return out
    }

    /// Whether a move would change anything. A drag that ends where it started must not write to
    /// defaults or publish a change, which would redraw the column and, for the source order, mark
    /// a preference the user never set.
    public static func isNoOp(from: Int, to: Int) -> Bool { to == from || to == from + 1 }

    /// A new relative order for part of a list, without disturbing the rest.
    ///
    /// Locations draws only some sources (a provider at a canonical place like Desktop is drawn in
    /// Favorites), so a drag there reorders a subset. Writing the subset followed by everything
    /// else would move the untouched sources to the end of the pane header's dropdown. Members
    /// refill the positions members already held, in the new order; non-members stay put. An id in
    /// `subset` not in `all` is ignored: reordering never changes membership.
    public static func reordering(_ all: [String], subsetInNewOrder subset: [String]) -> [String] {
        let members = Set(all)
        let slots = Set(subset).intersection(members)
        var next = subset.filter { slots.contains($0) }.makeIterator()
        return all.map { slots.contains($0) ? (next.next() ?? $0) : $0 }
    }

    /// Clamps a drop to the band it started in.
    ///
    /// Locations groups its rows by band when they are built, so a row released past the rule
    /// between bands would be re-grouped straight back and the drop would seem to do nothing.
    /// Clamped, the row goes as far as its band allows and the insertion line stays honest.
    ///
    /// `bandStart` and `bandEnd` are the half-open range of the dragged row's band; the returned
    /// insertion index is within `bandStart ... bandEnd`.
    public static func clampedToBand(_ to: Int, bandStart: Int, bandEnd: Int) -> Int {
        min(max(to, bandStart), bandEnd)
    }

    /// Which of Favorites' two lists a drag addresses, and the index inside it.
    ///
    /// The section draws place rows, then remembered folders, in one index space, but they are two
    /// stores of different things (a place is a root, a remembered folder a path inside one). The
    /// combined index must be split before use, or a folder drag would address the wrong list and
    /// index past its end, and `moved` would silently do nothing.
    ///
    /// - Parameter places: how many place rows are drawn above the remembered folders.
    /// - Returns: `isPlace` says which list, and `from`/`to` are indices within it.
    public static func favoritesMove(from: Int, to: Int, places: Int)
        -> (isPlace: Bool, from: Int, to: Int) {
        from < places
            ? (true, from, min(to, places))
            : (false, from - places, max(0, to - places))
    }

    /// A reorder of the rows on screen, written back into a list that holds more.
    ///
    /// Stored Favorites places outlive drawn ones: an unplugged favorited volume keeps its entry
    /// and draws no row. Appending such leftovers after the visible ones would silently move them
    /// to the end, so they keep the slots they held and only the visible entries are re-dealt into
    /// theirs. `visibleInNewOrder` must be a permutation of the entries of `stored` it names;
    /// anything it doesn't name is invisible by definition.
    public static func resplicing<T: Hashable>(_ stored: [T], visibleInNewOrder: [T]) -> [T] {
        let visible = Set(visibleInNewOrder)
        var next = visibleInNewOrder.makeIterator()
        return stored.map { entry in
            guard visible.contains(entry), let replacement = next.next() else { return entry }
            return replacement
        }
    }
}

/// Which places sit in Favorites: the standard set to begin with, and whatever the user has added
/// or removed since. A place row's section is decided by membership of this list.
///
/// Stored as one JSON string, not a key per place, for the reason `browseSidebarCollapsed` gives:
/// one answer belongs in one key, and per-place keys would need cleaning up when a disk is
/// unplugged. JSON, not a joined string, because POSIX paths may contain any separator.
public enum SidebarFavoritePlaces {

    /// What a first run gets: the home folder, then Finder's own three. These are the places a
    /// person navigates to from a standing start, and a default every user rebuilds by hand is no
    /// default. Order is Finder's, which is why this is a list, not a set.
    ///
    /// The startup disk is left out: it is the widest scope and least often wanted, and Locations'
    /// device band is where hardware belongs (the disk, any card beside it, then the Trash;
    /// ``SidebarSourceModel/orderedVolumes(_:)`` and `Band`'s declaration order handle that).
    /// ``migrate(defaults:)`` moves it out of lists stored before.
    ///
    /// Home is also a Locations row (``SidebarSourceModel/homeEntry``), so removing it from
    /// Favorites moves it back down the column rather than off it, and the startup disk falls back
    /// the same way through the mounted-volume walk. Desktop, Documents and Downloads have only
    /// `.shortcut`, and ``restoring(_:)`` is their way back.
    public static var standard: [String] {
        [SidebarSourceModel.homeEntry.path] + SidebarSourceModel.favoriteShortcuts.map(\.path)
    }

    /// Absent is not the same as empty, and the difference is the whole default.
    ///
    /// Someone who has never touched Favorites gets ``standard``; someone who removed every place
    /// gets none, and must not have them handed back on the next launch. An empty string is the
    /// untouched key and an empty array is a decision, which a comma-joined list couldn't tell
    /// apart. A value that won't decode also reads as ``standard``: a recognisable reset beats
    /// silently lost Favorites. `restoring` brings the standard set back deliberately.
    public static func places(from raw: String) -> [String] {
        guard !raw.isEmpty else { return standard }
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return standard }
        return list
    }

    /// Whether `raw` holds bytes this build can't read: the third state, and the one that must
    /// never be written over.
    ///
    /// `places(from:)` answers ``standard`` for both an untouched key and an unreadable one, which
    /// is right for a read and wrong for the write after it: the next Add, Remove or drag would
    /// encode the standard set over the key and lose the real list. This lets a caller notice.
    /// `FolderJumpStore.salvageKey(for:)` keeps such bytes for the pinned and recent maps the same
    /// way; see ``salvageKey``.
    public static func isUnreadable(_ raw: String) -> Bool {
        guard !raw.isEmpty else { return false }
        guard let data = raw.data(using: .utf8),
              (try? JSONDecoder().decode([String].self, from: data)) != nil else { return true }
        return false
    }

    /// Where the list is stored. `ContentView` reads it through `@AppStorage`, which needs the
    /// literal at the property; `favoritePlacesKeyMatchesTheAppStorageProperty` binds the two.
    public static let storageKey = "browseSidebarFavoritePlaces"

    /// Where bytes this build can't decode are put instead of being overwritten, in
    /// `FolderJumpStore.salvageKey(for:)`'s spelling so both stores recover the same way. Derived
    /// from ``storageKey`` so a rename can't leave the salvage pointing at the old name.
    public static let salvageKey = storageKey + ".unreadable"

    public static func encoded(_ places: [String]) -> String {
        guard let data = try? JSONEncoder().encode(places),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Adds a place that isn't there, removes one that is. Added at the end, because a new favorite
    /// at the top would push the row the user is looking at elsewhere on the same click.
    public static func toggling(_ path: String, in places: [String]) -> [String] {
        places.contains(path) ? places.filter { $0 != path } : places + [path]
    }

    /// ``standard`` put back at the top in its own order, with everything the user has added kept
    /// below it in its order.
    ///
    /// This keeps "Remove from Favorites" from being a one-way door: a removed Desktop appears
    /// nowhere else, and adding `~/Desktop` as a folder source is a different thing. The standard
    /// places come back as a block in standard order, as the item's name promises, so one the user
    /// had dragged below a place of their own comes back up.
    public static func restoring(_ places: [String]) -> [String] {
        standard + places.filter { !standard.contains($0) }
    }

    /// Whether anything standard is missing, the one condition under which Restore is worth
    /// offering. A menu item that would do nothing teaches nothing.
    public static func isMissingStandard(_ places: [String]) -> Bool {
        standard.contains { !places.contains($0) }
    }
}

extension SidebarSourceModel {

    /// What the Favorites verb reads for a place row, or nil where there is none to offer. The
    /// Trash has none: it is `revealOnly`, opens in Finder and is never a pane's scope, so a
    /// Favorites row for it couldn't do what every other row there does.
    public static func favoriteVerb(for row: SidebarSourceRow) -> String? {
        guard row.state != .revealOnly else { return nil }
        return row.isFavoriteShortcut ? "Remove from Favorites" : "Add to Favorites"
    }
}
