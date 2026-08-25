import Foundation

/// **One place row** — a cloud account, a folder source, a disk, the Trash, or a standard folder
/// SyncCloud has not been given yet.
///
/// Used by both **Locations** and the standard-folder half of **Favorites**; ``band`` says which.
///
/// Cloud accounts and folder sources share a band because the model says they are one thing: a
/// folder source *is* a `CloudProvider` with `type == .localFolder`, and every pane, lens, diff,
/// undo and CLI path treats it identically — the type exists only so name rules and the Drive
/// date-noise filter can tell them apart.
public struct SidebarSourceRow: Identifiable, Equatable, Sendable {

    /// What clicking this row will do, and how the row reads before you click it.
    ///
    /// **The three states exist because "local folder" is two different things here.** A folder
    /// source is a root the user added in Settings; `~/Downloads`, if they never added it, is
    /// nothing to this app. Listing the familiar four regardless means a click has to resolve which
    /// case it is in — and the row says which *first*, so the click is never a surprise.
    public enum State: Equatable, Sendable {
        /// A configured source: a discovered cloud account, or a folder source in Settings.
        case configured
        /// A local shortcut whose folder lives **inside** a source that already exists — the case
        /// macOS's Desktop & Documents syncing creates, where `~/Desktop` is a link into
        /// `com~apple~CloudDocs`. Clicking navigates there inside the owning source; nothing is
        /// added, because adding it would mean two sources scanning one tree.
        case inside(sourceName: String)
        /// A local shortcut SyncCloud does not know about. Drawn dimmed. Clicking adds it as a
        /// folder source, scans it, and says so with an inline Remove.
        case unknown
        /// **A place that opens in Finder and is never added as a source.** The Trash, and only the
        /// Trash: promoting it would have SyncCloud scan it, hash it, offer to file into it and
        /// count it in Storage — for a folder whose whole purpose is that its contents are on their
        /// way out. Finder's own Trash row is a special case for the same reason.
        case revealOnly
    }

    /// The provider id for a configured source; the absolute path for one that is not a source yet.
    public let id: String
    /// The leaf name — `Dropbox`, `Drive`, `Downloads`.
    public let name: String
    /// Shown **only when it is needed to tell two rows apart**, or when a shortcut lives inside
    /// another source. Three Google Drive accounts all read `Drive` without it.
    public let detail: String?
    /// The provider's mark, or an SF Symbol for a local folder.
    public let symbol: String
    public let absolutePath: String
    /// Which band of the column this row belongs to.
    ///
    /// Replaced a plain `isLocal` when the section became **Locations** and the standard folders
    /// moved out of it: two booleans could not say the difference between a Google Drive account, a
    /// mounted SD card and `~/Desktop`, and those now live in two different sections.
    public let band: Band

    /// Where a row sits, and therefore what it is.
    ///
    /// The order of the cases is the order they are drawn in, which is Finder's: the clouds you
    /// signed into, then the hardware, then the Trash.
    public enum Band: Int, Comparable, Sendable, CaseIterable {
        /// A cloud account or a folder source — something SyncCloud syncs.
        case cloud
        /// The home folder, the startup disk, an external drive, a mounted card.
        case device
        /// The Trash, which is last and is not like the others — see ``State/revealOnly``.
        case trash
        /// A standard folder that lives in **Favorites**, not here — Desktop, Documents, Downloads.
        case shortcut

        public static func < (a: Band, b: Band) -> Bool { a.rawValue < b.rawValue }
    }
    public let state: State
    /// False when the root did not answer. The row stays listed and refuses, the same rule the
    /// folder rows have always used: a source that is asleep has not gone.
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

    /// **Dimmed means "not answering", and nothing else.**
    ///
    /// It also covered `.unknown` — a place SyncCloud has not been given yet — until that was drawn
    /// and looked wrong: Locations' whole device band greys out on a fresh install, because a disk
    /// is not a source until someone makes it one, and a column of grey rows reads as broken rather
    /// than as available. Finder does not dim your disks either. A place you have not added is a
    /// perfectly good place; what is unusual about it belongs in the tooltip and in the notice the
    /// click produces, not in the row's weight.
    public var isDimmed: Bool { !isAvailable }

    /// Whether this row lives in Favorites rather than Locations.
    public var isFavoriteShortcut: Bool { band == .shortcut }

    /// **The same place, in the other section.** Favoriting a place MOVES its row rather than
    /// copying it: one place, one row, which is the invariant the builder's `claimed` set exists to
    /// keep. Two rows for `Dropbox` in a 180pt column — one under each heading — is worse than
    /// either place on its own, and it would make "which one do I remove?" a question.
    public func inBand(_ band: Band) -> SidebarSourceRow {
        SidebarSourceRow(id: id, name: name, detail: detail, symbol: symbol,
                         absolutePath: absolutePath, band: band, state: state,
                         isAvailable: isAvailable)
    }
}

/// **What a source row is named, and when it needs qualifying.**
///
/// Separate from the view so the rule can be asserted without mounting anything, and separate from
/// `FolderSidebarModel` because it answers a different question about a different list.
public enum SidebarSourceModel {

    /// **The standard folders, which live in Favorites** — Finder's own arrangement.
    ///
    /// Desktop, Documents and Downloads are the three a person files *into*, which is what makes
    /// them belong beside the folders they curated rather than beside the disks those folders sit
    /// on. Home is deliberately not here: it is the folder that *contains* these three, so listing
    /// it alongside them puts a container and its contents in one flat list. It sits in Locations,
    /// with the other volumes.
    ///
    /// **Fixed, and deliberately short.** Every folder past these is somebody's preference rather
    /// than everybody's, and adding a folder source is the mechanism this list is a shortcut *to*
    /// rather than a replacement for. Applications is left out for a reason of its own: every row
    /// in Favorites is a drop target, and a sidebar row you can drop a document onto should be
    /// somewhere you would actually file one.
    public static let favoriteShortcuts: [(name: String, symbol: String, path: String)] = [
        ("Desktop", "menubar.dock.rectangle", NSHomeDirectory() + "/Desktop"),
        ("Documents", "doc", NSHomeDirectory() + "/Documents"),
        ("Downloads", "arrow.down.circle", NSHomeDirectory() + "/Downloads"),
    ]

    /// The home folder, which heads the device band in Locations.
    public static let homeEntry: (name: String, symbol: String, path: String) =
        (NSUserName(), "house", NSHomeDirectory())

    /// The Trash, last in Locations and the one row that never becomes a source.
    public static let trashEntry: (name: String, symbol: String, path: String) =
        ("Trash", "trash", NSHomeDirectory() + "/.Trash")

    /// **A mounted volume, as the sidebar needs it.** Injected rather than read here so the rule
    /// that turns volumes into rows is testable without plugging in a card.
    public struct Volume: Equatable, Sendable {
        public let name: String
        public let path: String
        /// Removable or ejectable — an SD card, a USB stick, an external disk. Decides the glyph,
        /// and nothing else: a card is browsed exactly like the startup disk.
        public let isRemovable: Bool
        /// The startup disk. Drawn first among the volumes, because it is the one that is always
        /// there.
        public let isInternal: Bool

        public init(name: String, path: String, isRemovable: Bool, isInternal: Bool) {
            self.name = name
            self.path = path
            self.isRemovable = isRemovable
            self.isInternal = isInternal
        }

        /// `internaldrive` for the startup disk, `sdcard` for something you can pull out,
        /// `externaldrive` for a disk that is neither.
        public var symbol: String {
            if isInternal { return "internaldrive" }
            return isRemovable ? "sdcard" : "externaldrive"
        }
    }

    /// Volumes in the order Locations draws them: the startup disk, then everything else by name.
    ///
    /// Sorted rather than left in mount order, which is arrival order and therefore changes between
    /// launches — the same reason the favorites and source orders are partitioned rather than
    /// `sorted(by:)`-ed. A sidebar whose disks rearranged themselves on every boot would look
    /// broken.
    public static func orderedVolumes(_ volumes: [Volume]) -> [Volume] {
        volumes.sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// **Qualify a name only when another row shares it** — the duplicate-leaf rule that
    /// `FolderSidebarModel.rows` applies to folders, pointed at sources.
    ///
    /// This is the case the whole section is shaped around: three Google Drive accounts and two
    /// OneDrive accounts all render one word. Finder answers this with a tooltip, and shows two
    /// rows reading `Projects` and two reading the user's own name until you hover one of them.
    /// Naming the difference inline is simply better, and it costs nothing on the rows that do not
    /// collide — a column where every second row carries a qualifier is the other failure.
    ///
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

    /// **Which existing source contains this path, if any** — the check that has to happen before a
    /// local shortcut is promoted to a source of its own.
    ///
    /// Under macOS's Desktop & Documents syncing, `~/Desktop` is a link into
    /// `com~apple~CloudDocs`, so a plain path comparison says it is nothing to do with iCloud
    /// Drive. `SettingsManager.addFolderSource` already refuses to mint a duplicate for a path that
    /// *equals* a source's root — its own note says a cloud account "knows things about that folder
    /// (its name rules, its date behaviour) that a folder source would throw away" — but equality
    /// is not enough here: a *contained* path would sail past it, and the result is two sources
    /// scanning one tree, double-counted in Storage.
    ///
    /// So: resolve symlinks on both sides, then test containment, longest root first so a source
    /// nested inside another resolves to the more specific one.
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

    /// **Whether two paths name the same folder**, normalised and case-folded.
    ///
    /// Its own member because the call site had it as containment asserted in both directions,
    /// which is true but reads as a puzzle — and because "is this shortcut already a source in its
    /// own right" is a different question from "is it inside one", even though one rule can answer
    /// both.
    public static func isSameFolder(_ a: String, _ b: String) -> Bool {
        trimmed(a.lowercased()) == trimmed(b.lowercased())
    }

    /// Path containment on component boundaries, case-folded.
    ///
    /// **Not `hasPrefix`**, which reports `/Users/ab/Downloads2` as inside `/Users/ab/Downloads`.
    /// Case-folded because the default macOS volume is case-insensitive, so the two spellings name
    /// one folder — and claiming is the safe direction here: a wrong claim costs a navigation the
    /// user can see and correct, a missed one costs a duplicate source they will not notice.
    /// Trailing slashes are stripped from **both** sides before comparing, which is not cosmetic: a
    /// provider Location is user-settable and arrives spelled however it was typed, and with the
    /// base spelled `…/Downloads/` the equality case failed — the path `…/Downloads` is neither
    /// equal to it nor prefixed by `…/Downloads//`, so a source's own root read as outside itself.
    /// `FolderJumpStore.key(forRoot:)` normalises the same way for the same reason.
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


/// **Where a dragged row lands.**
///
/// Its own type because the rule is pure arithmetic over measured geometry and the risk here is all
/// in the arithmetic: an off-by-one puts the row one place from where the user aimed, which reads as
/// the drag being broken rather than as a rounding choice.
///
/// **Measured midpoints, not a row height.** The rows are not uniform — a favorite carrying a parent
/// qualifier draws a second line — so an index computed as `translation / rowHeight` is wrong the
/// moment one row in the list is taller, and wrong by more the further you drag. The view reports
/// each row's real midpoint and this compares against those.
public enum SidebarReorder {

    /// The index a row dragged to `y` should be inserted at.
    ///
    /// - Parameter midpoints: each row's vertical midpoint, in the order the rows are drawn, in the
    ///   same coordinate space as `y`.
    /// - Returns: an insertion index in `0...midpoints.count`.
    ///
    /// Insertion semantics, not swap semantics: the answer is a gap between rows, which is what the
    /// insertion line the user sees is drawn at. Above every midpoint is 0; below every midpoint is
    /// the end.
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
    /// **`to` is an insertion index measured against the ORIGINAL list**, which is the whole subtlety
    /// of a move: dragging row 0 down to the gap after row 2 gives `to == 3`, but once row 0 is
    /// lifted out every later index shifts down by one, so the actual destination is 2. Getting this
    /// backwards is the classic off-by-one that makes a downward drag land one short every time.
    public static func moved<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), to >= 0, to <= items.count else { return items }
        var out = items
        let item = out.remove(at: from)
        out.insert(item, at: to > from ? to - 1 : to)
        return out
    }

    /// Whether a move would change anything. A drag that ends where it started must not write to
    /// defaults or publish a change — it would put the column through a redraw and, for the source
    /// order, mark a preference the user never actually set.
    public static func isNoOp(from: Int, to: Int) -> Bool { to == from || to == from + 1 }

    /// **A new relative order for part of a list, without disturbing the rest.**
    ///
    /// The Locations section draws only some of the app's sources — a provider whose folder is a
    /// canonical place (Desktop, Downloads, the home folder) is drawn in Favorites instead — so a
    /// drag there reorders a SUBSET. Writing that subset out followed by everything else would move
    /// the sources nobody touched to the end of the pane header's dropdown, which is a change the
    /// user did not ask for and would not connect to the drag they made.
    ///
    /// Every member keeps the set of positions the members already occupied, filled in the new
    /// order; every non-member stays exactly where it was.
    /// An id in `subset` that is not in `all` is ignored rather than inserted: this is a new ORDER
    /// for existing members, never a membership change. Callers do filter first, and it still
    /// should not be possible to grow or shrink a list by reordering part of it.
    public static func reordering(_ all: [String], subsetInNewOrder subset: [String]) -> [String] {
        let members = Set(all)
        let slots = Set(subset).intersection(members)
        var next = subset.filter { slots.contains($0) }.makeIterator()
        return all.map { slots.contains($0) ? (next.next() ?? $0) : $0 }
    }

    /// **Clamps a drop to the band it started in.**
    ///
    /// Locations draws its rows grouped — clouds, a rule, then the device rows and the Trash — and
    /// that grouping is applied when the rows are BUILT, from each row's band. So a row released
    /// past the rule is re-grouped straight back, and the move appears to do nothing: the
    /// insertion line promised a landing the column cannot draw. Clamping makes the line honest —
    /// the row goes as far as its own band allows and stops there.
    ///
    /// `bandStart` and `bandEnd` are the half-open range of the dragged row's band; the returned
    /// insertion index is within `bandStart ... bandEnd`.
    public static func clampedToBand(_ to: Int, bandStart: Int, bandEnd: Int) -> Int {
        min(max(to, bandStart), bandEnd)
    }

    /// **Which of Favorites' two lists a drag addresses, and the index inside it.**
    ///
    /// The section draws place rows first and remembered folders after, in ONE index space, but
    /// they are two stores holding two different kinds of thing — a place is a root, a remembered
    /// folder is a path inside one. So a combined index has to be resolved before it can be used,
    /// and the resolution is the part that was missing: the combined index went straight to the
    /// remembered-folder list, where with three standard folders present the first folder's drag
    /// asked to move item 3 of a two-item list. `moved` returned it unchanged, so folders could not
    /// be reordered at all, and a place drag reordered a folder instead. Nothing wrote a wrong
    /// value and nothing logged, which is how it went unnoticed.
    ///
    /// - Parameter places: how many place rows are drawn above the remembered folders.
    /// - Returns: `isPlace` says which list, and `from`/`to` are indices within it.
    public static func favoritesMove(from: Int, to: Int, places: Int)
        -> (isPlace: Bool, from: Int, to: Int) {
        from < places
            ? (true, from, min(to, places))
            : (false, from - places, max(0, to - places))
    }

    /// **A reorder of the rows that were on screen, written back into a list that holds more.**
    ///
    /// The stored Favorites places outlive the drawn ones: a favorited volume that is unplugged
    /// keeps its entry and draws no row. Appending those leftovers after the reordered visible ones
    /// — which is what this did until it was reviewed — silently rewrites their positions, so
    /// dragging Desktop up moved an unplugged disk to the end of a list nothing on screen was
    /// describing, and it reappeared last when it was plugged back in.
    ///
    /// The invisible entries keep the slots they occupied; only the visible ones are re-dealt into
    /// theirs. `visibleInNewOrder` must be a permutation of the entries of `stored` that it names —
    /// anything it does not name is invisible by definition, so the caller does not pass a
    /// predicate as well.
    public static func resplicing<T: Hashable>(_ stored: [T], visibleInNewOrder: [T]) -> [T] {
        let visible = Set(visibleInNewOrder)
        var next = visibleInNewOrder.makeIterator()
        return stored.map { entry in
            guard visible.contains(entry), let replacement = next.next() else { return entry }
            return replacement
        }
    }
}

/// **Which places sit in Favorites** — the three standard folders to begin with, and whatever the
/// user has added or removed since.
///
/// Before this, Favorites' place rows were the fixed `SidebarSourceModel.favoriteShortcuts` and
/// nothing else: Desktop, Documents and Downloads, always, with no way to take one out and no way
/// to put a source you actually live in beside them. The list is now the user's, seeded with those
/// three — which keeps the first run identical to what it was — and a place row's SECTION is
/// decided by membership of it rather than by a constant in the source.
///
/// Stored as one JSON string rather than as a set of keys, for the reason `browseSidebarCollapsed`
/// gives: one answer belongs in one key, and a per-place key would need cleaning up when a disk is
/// unplugged. JSON rather than a joined string because these are POSIX paths, which may contain the
/// separator any plain join would pick.
public enum SidebarFavoritePlaces {

    /// What a first run gets: Finder's own three, in Finder's order.
    public static var standard: [String] { SidebarSourceModel.favoriteShortcuts.map(\.path) }

    /// **Absent is not the same as empty, and the difference is the whole default.**
    ///
    /// Someone who has never touched Favorites gets the three standard folders; someone who has
    /// deliberately removed all three gets none, and must not have them handed back on the next
    /// launch. An empty *string* is the untouched key and an empty *array* is a decision, so the
    /// encoding has to be able to say both — which a comma-joined list cannot.
    ///
    /// A value that will not decode falls back to the standard three rather than to nothing: it is
    /// the same answer a first run gets, and a column that has lost its Favorites silently is worse
    /// than one that has been reset to a state the user recognises. `restoring` is how the three
    /// come back deliberately.
    public static func places(from raw: String) -> [String] {
        guard !raw.isEmpty else { return standard }
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return standard }
        return list
    }

    public static func encoded(_ places: [String]) -> String {
        guard let data = try? JSONEncoder().encode(places),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Adds a place that is not there, removes one that is. Added at the END, because a new
    /// favorite joining the list at the top would push the row the user is looking at somewhere
    /// else on the same click.
    public static func toggling(_ path: String, in places: [String]) -> [String] {
        places.contains(path) ? places.filter { $0 != path } : places + [path]
    }

    /// The standard three, put back at the top **in Finder's order**, with everything the user has
    /// added kept below them in the order they were in.
    ///
    /// The affordance that stops "Remove from Favorites" being a one-way door. Removing Desktop
    /// takes its row off the column and there is nowhere else it appears, so without this the only
    /// route back would be adding `~/Desktop` as a folder source — which is a different thing that
    /// happens to look similar.
    ///
    /// **Only the missing ones used to be prepended**, which restored them in an order the name
    /// does not promise: with Documents still there, Restore produced Desktop, Downloads,
    /// Documents. An item called "Restore Standard Folders" that leaves the standard folders out of
    /// their standard order has done half of what it says. The three are placed as a block, so the
    /// one cost is that a standard folder the user had dragged below a place of their own comes
    /// back up — which is the same thing the item is named after.
    public static func restoring(_ places: [String]) -> [String] {
        standard + places.filter { !standard.contains($0) }
    }

    /// Whether anything standard is currently missing — the one condition under which Restore is
    /// worth offering. A menu item that would do nothing is a menu item that teaches nothing.
    public static func isMissingStandard(_ places: [String]) -> Bool {
        standard.contains { !places.contains($0) }
    }
}

extension SidebarSourceModel {

    /// **What the Favorites verb reads for a place row, or nil where there is none to offer.**
    ///
    /// The Trash is the one place with no answer: it is `revealOnly` — it opens in Finder and is
    /// never a pane's scope — so a Favorites row for it would be a row that cannot do what every
    /// other row in that section does.
    public static func favoriteVerb(for row: SidebarSourceRow) -> String? {
        guard row.state != .revealOnly else { return nil }
        return row.isFavoriteShortcut ? "Remove from Favorites" : "Add to Favorites"
    }
}
