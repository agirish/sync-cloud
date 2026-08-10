import Foundation
import Sync

// MARK: - Where a row takes you

/// One destination the palette can route to.
///
/// **A value, not a closure**, and that is the whole reason this feature is testable. The palette's
/// predecessor in this codebase — the pane search field's ↩ — shipped its routing *inverted*, and
/// nothing caught it: the decision lived in three lines inside an `onSubmit`, which cannot be fired
/// from a unit test and is attached to a SwiftUI `Button` that is not an `NSControl`. It only became
/// testable once the decision was pulled out into a pure function returning a value
/// (``PaneSearchSubmit``). This is the same shape, one size up: ``PaletteRouter`` turns a query into
/// rows carrying routes, a test asserts the routes, and the host's only job is to *apply* one.
public enum PaletteRoute: Equatable, Sendable {

    /// The Compare workspace — two trees side by side.
    case compare
    /// The Storage workspace — reads one tree, changes nothing.
    case storage

    /// Organize, at this rail item (`nil` is the overview), optionally re-aimed at a folder.
    ///
    /// The scope is an **absolute path**, or nil to leave the current aim alone. It is not folded
    /// into a separate `.folder` route because "organize income tax" is one request, not two: a
    /// route that only switched workspace would land you on Organize still answering about wherever
    /// you were, which is the same silent-loss ``OrganizeScope`` was built to stop.
    case organize(lens: OrganizeLens?, scope: String?)

    /// Everything that is this person's — the gather ⌘↩ opens from the pane search.
    case person(id: String)

    /// Point the single source at this provider.
    case provider(id: String)

    /// Reveal this folder in the source browser, without re-aiming Organize.
    case folder(path: String)

    /// A named action, run or opened.
    case action(PaletteAction)
}

/// The actions the palette can run.
///
/// Deliberately **only things that already exist as a menu item or a header control.** A palette is
/// a second way to reach what is there; inventing an action reachable *only* here would put a verb
/// in the app that nothing on screen can teach you.
public enum PaletteAction: String, CaseIterable, Sendable {
    case rescan
    case newFolder
    case chooseFolder
    case findInPane
    case settings
    case shortcuts
    case activityLog

    public var title: String {
        switch self {
        case .rescan: return "Rescan"
        case .newFolder: return "New Folder…"
        case .chooseFolder: return "Choose Folder…"
        case .findInPane: return "Find in Pane…"
        case .settings: return "Settings…"
        case .shortcuts: return "Keyboard Shortcuts"
        case .activityLog: return "Activity Log"
        }
    }

    public var symbol: String {
        switch self {
        case .rescan: return "arrow.clockwise"
        case .newFolder: return "folder.badge.plus"
        case .chooseFolder: return "folder"
        case .findInPane: return "magnifyingglass"
        case .settings: return "gearshape"
        case .shortcuts: return "keyboard"
        case .activityLog: return "list.bullet.rectangle"
        }
    }

    /// Extra words a query may use for this action that its title does not contain.
    ///
    /// The palette exists because *a user who thinks "rename" has no target for the thought* — so
    /// the vocabulary has to be the user's, not the menu's. Kept here rather than in the matcher so
    /// each action owns its own synonyms.
    var keywords: [String] {
        switch self {
        case .rescan: return ["scan", "refresh", "reload"]
        case .newFolder: return ["make folder", "create folder"]
        case .chooseFolder: return ["add folder", "open folder", "pick folder", "source"]
        case .findInPane: return ["search", "find"]
        case .settings: return ["preferences", "options"]
        case .shortcuts: return ["keys", "chords", "help"]
        case .activityLog: return ["log", "history"]
        }
    }
}

// MARK: - Rows

/// The palette's sections, in the order they are shown.
///
/// **"Places" rather than "Workspaces"**, because five of the nine places are rail items *inside*
/// Organize. Calling the group Workspaces would have made the six lenses look like a different kind
/// of thing from the three segments, when routing to them is exactly the same act — and the lenses
/// are the reason this item got more valuable than it was when written.
public enum PaletteGroup: String, CaseIterable, Sendable {
    case places = "Places"
    case people = "People"
    case folders = "Folders"
    case sources = "Sources"
    case actions = "Actions"

    /// Ties are broken in this order, which is also the order the sections are drawn in.
    var rank: Int { PaletteGroup.allCases.firstIndex(of: self) ?? 0 }
}

/// One row.
public struct PaletteRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let group: PaletteGroup
    public let title: String
    /// The second line — what this row *is*, or where it goes. nil draws a single-line row.
    public let detail: String?
    public let symbol: String
    public let route: PaletteRoute

    /// Why this row cannot be chosen, or nil.
    ///
    /// **A reason, not a Bool, and the row is kept rather than dropped.** An unmounted source that
    /// simply vanished from the results teaches the user that the palette does not know about it;
    /// the same row, dimmed and reading "Not mounted", answers the question they actually asked.
    /// This is stated as a requirement in ROADMAP 14 and it is the one thing a filtered list gets
    /// wrong by default.
    public let unavailable: String?

    public var isAvailable: Bool { unavailable == nil }

    /// How well this row matched — the sort key, kept on the row so a test can assert the ORDER
    /// rather than only the membership.
    public let score: Int

    public init(id: String, group: PaletteGroup, title: String, detail: String? = nil,
                symbol: String, route: PaletteRoute, unavailable: String? = nil, score: Int = 0) {
        self.id = id
        self.group = group
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.route = route
        self.unavailable = unavailable
        self.score = score
    }
}

// MARK: - What the router is allowed to read

/// A provider, as the palette needs it.
public struct PaletteProvider: Equatable, Sendable {
    public let id: String
    public let name: String
    /// Whether its folder is actually there. False keeps the row and dims it.
    public let isMounted: Bool
    public let isCurrent: Bool

    public init(id: String, name: String, isMounted: Bool, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.isMounted = isMounted
        self.isCurrent = isCurrent
    }
}

/// Everything the router may read, snapshotted.
///
/// A plain `Sendable` value rather than the manager, so the routing table is a **function** of
/// state that a test can write down in full. Nothing here is optional-for-convenience: each field
/// is something a row's presence, wording or availability genuinely depends on.
public struct PaletteIndex: Equatable, Sendable {
    public var providers: [PaletteProvider]
    /// The absolute root of the source Organize and the rail are pointed at, if there is one.
    public var providerRoot: String?
    /// Folders under `providerRoot`, **relative**, from the folder profile the survey built.
    public var folders: [String]
    /// Recently focused folders, most recent first, relative — the empty-query state.
    public var recentFolders: [String]
    /// Folders the user has pinned, relative. ROADMAP 14 asks the Folders group for "recent and
    /// pinned paths"; they are two lists rather than one because they are two different claims —
    /// *where you just were* and *where you keep going back to* — and a row labelled "Recent" for a
    /// folder you pinned months ago would be the wrong one.
    public var pinnedFolders: [String]
    public var people: [Person]
    /// The registry, when there is one. Person routing is phrase-first and longest-wins; the
    /// palette must not hand-roll a second matcher (see ``PaletteRouter/personRow(for:index:)``).
    public var registry: PersonRegistry?
    /// True while a scan is running — the one thing that makes Rescan unavailable rather than absent.
    public var isScanning: Bool
    /// Whether a document survey exists for a person gather to read. Without one the offer is a
    /// button that does nothing, which is what the gather's own failure path had to be taught to say.
    public var hasSurvey: Bool
    /// Whether the current source is one the user can re-point ("Choose Folder…").
    public var canChooseFolder: Bool

    public init(providers: [PaletteProvider] = [], providerRoot: String? = nil,
                folders: [String] = [], recentFolders: [String] = [],
                pinnedFolders: [String] = [], people: [Person] = [],
                registry: PersonRegistry? = nil, isScanning: Bool = false, hasSurvey: Bool = false,
                canChooseFolder: Bool = false) {
        self.providers = providers
        self.providerRoot = providerRoot
        self.folders = folders
        self.recentFolders = recentFolders
        self.pinnedFolders = pinnedFolders
        self.people = people
        self.registry = registry
        self.isScanning = isScanning
        self.hasSurvey = hasSurvey
        self.canChooseFolder = canChooseFolder
    }
}

// MARK: - Places

/// A destination in the app's own vocabulary: the two other workspaces, and Organize's rail.
///
/// Spelled out rather than derived from `Workspace`, which lives in `MacApp` — a target that is in
/// **no SPM package**, so a routing table written there is reachable by no `swift test`. That is not
/// a workaround: the palette's whole risk is a routing table that is wrong in a way nobody can see,
/// and the host's job is reduced to mapping these four cases onto its own selection type.
enum PalettePlace: CaseIterable {
    case compare
    case storage
    case organizeOverview
    case lens(OrganizeLens)

    static var allCases: [PalettePlace] {
        [.compare, .organizeOverview] + OrganizeLens.allCases.map(PalettePlace.lens) + [.storage]
    }

    var title: String {
        switch self {
        case .compare: return "Compare"
        case .storage: return "Storage"
        case .organizeOverview: return "Organize"
        case .lens(let lens): return "Organize ▸ \(lens.title)"
        }
    }

    /// The words a query may use to reach this place, beyond its title.
    ///
    /// `"file"` and `"filing"` reach To File because that is what the app calls the act everywhere
    /// else; `"rename"` reaches Names because ROADMAP 14's founding example is a user who thinks
    /// "rename" and has nothing to aim at — folding Rename into a conditional chip took its
    /// destination off the bar, and this is where it comes back.
    var keywords: [String] {
        switch self {
        case .compare: return ["diff", "differences", "sync", "compare"]
        case .storage: return ["space", "disk", "size", "storage"]
        case .organizeOverview: return ["organize", "tidy", "all"]
        case .lens(.toFile): return ["organize", "file", "filing", "loose", "inbox", "to file"]
        case .lens(.duplicates): return ["organize", "duplicates", "dupes", "copies", "identical"]
        case .lens(.names): return ["organize", "names", "rename", "risky", "illegal", "characters"]
        case .lens(.renames): return ["organize", "renames", "numbering", "backlog", "folders"]
        case .lens(.restructure): return ["organize", "restructure", "structure", "shape", "habits"]
        case .lens(.rules): return ["organize", "rules", "automations", "automatic", "learned"]
        }
    }

    var symbol: String {
        switch self {
        case .compare: return "arrow.left.arrow.right"
        case .storage: return "chart.pie"
        case .organizeOverview: return "folder.badge.gearshape"
        case .lens(let lens): return lens.symbol
        }
    }

    var detail: String {
        switch self {
        case .compare: return "Two trees, side by side"
        case .storage: return "What is using the space"
        case .organizeOverview: return "Every lens's answer, on one page"
        case .lens(let lens): return lens.help(state: .configuration)
        }
    }

    var id: String {
        switch self {
        case .compare: return "place.compare"
        case .storage: return "place.storage"
        case .organizeOverview: return "place.organize"
        case .lens(let lens): return "place.organize.\(lens.rawValue)"
        }
    }

    /// This place, optionally re-aimed at a folder. Only Organize can carry a scope — Compare has
    /// two trees and Storage analyses whatever the pane is on, so neither has one subject to move.
    func route(scope: String?) -> PaletteRoute {
        switch self {
        case .compare: return .compare
        case .storage: return .storage
        case .organizeOverview: return .organize(lens: nil, scope: scope)
        case .lens(let lens): return .organize(lens: lens, scope: scope)
        }
    }

    /// Whether "<this place> <a folder>" is a request that can be honoured.
    var takesAFolder: Bool {
        switch self {
        case .compare, .storage: return false
        case .organizeOverview, .lens: return true
        }
    }
}

extension PalettePlace: Equatable {}

// MARK: - Matching

/// How well a candidate answers a query — **ordered, and the order is the ranking**.
///
/// Four tiers rather than a similarity score: a palette's job is to put the thing you meant first,
/// and "the whole title" beating "the start of a word" beating "somewhere in the middle" is the
/// whole of what anyone can predict about it. A continuous score would be unpredictable in exactly
/// the cases where being wrong costs a keystroke.
enum PaletteMatch: Int, Comparable {
    case none = 0
    case substring = 1
    case wordPrefix = 2
    case prefix = 3
    case exact = 4

    static func < (a: PaletteMatch, b: PaletteMatch) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - The router

/// The palette's routing table: a query and a snapshot in, ranked rows out.
///
/// Every decision the palette makes is here, and it is pure. See ``PaletteRoute`` for why that is
/// the point rather than a style.
public enum PaletteRouter {

    /// Rows for a query, best first.
    public static func rows(query: String, index: PaletteIndex) -> [PaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyQueryRows(index: index) }

        var rows: [PaletteRow] = []
        rows.append(contentsOf: verbRows(query: trimmed, index: index))
        rows.append(contentsOf: placeRows(query: trimmed))
        if let person = personRow(for: trimmed, index: index) { rows.append(person) }
        rows.append(contentsOf: folderRows(query: trimmed, index: index))
        rows.append(contentsOf: providerRows(query: trimmed, index: index))
        rows.append(contentsOf: actionRows(query: trimmed, index: index))

        // **No de-duplication pass, and that is measured rather than assumed.** One was written
        // here — keep the best-scoring copy of each id — on the reasoning that "organize legal"
        // reaches Organize through both the verb parse and the plain place match. It does, but as
        // two *different* rows with two different ids and two different destinations ("Organize ▸
        // Legal" and "Organize"), which is not a duplicate: every builder above mints at most one
        // row per id, so the pass could never fire. Mutating it to keep the WORST copy changed no
        // test, which is what an inert guard looks like. `aDestinationIsNeverListedTwice` pins the
        // property directly instead, where a future builder that did collide would fail.
        return sorted(rows)
    }

    /// Highest score first; then group order; then title, so the list is fully deterministic —
    /// a palette whose rows shuffled between identical queries would be unusable.
    static func sorted(_ rows: [PaletteRow]) -> [PaletteRow] {
        rows.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.group.rank != $1.group.rank { return $0.group.rank < $1.group.rank }
            return $0.title < $1.title
        }
    }

    // MARK: The lede — "organize income tax", "duplicates in Legal"

    /// Rows for a query that names a place **and then a folder**.
    ///
    /// This is what ROADMAP 14 calls the lede, and it is the one thing a filtered list of nouns
    /// cannot do: "organize income tax" is a verb and an object, and answering it with the Organize
    /// row alone drops the object silently — you land on Organize still answering about wherever you
    /// happened to be.
    ///
    /// The parse is deliberately blunt: take the **longest leading run of words** that names a place,
    /// and treat the rest as a folder. No grammar, no stop-word list beyond the connectives below,
    /// because everything it could get wrong it gets wrong into an ordinary place row, which is
    /// already in the results.
    static func verbRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        guard let (place, rest) = splitVerb(query), place.takesAFolder, !rest.isEmpty,
              let root = index.providerRoot, !root.isEmpty else { return [] }
        let folders = rankedFolders(matching: rest, in: index)
        return folders.prefix(5).map { folder in
            let absolute = (root as NSString).appendingPathComponent(folder.path)
            return PaletteRow(
                id: "verb.\(place.id).\(folder.path)",
                group: .places,
                title: "\(place.title) ▸ \(leaf(folder.path))",
                detail: "Point Organize at \(folder.path)",
                symbol: place.symbol,
                route: place.route(scope: absolute),
                // **Scored above a bare place match on purpose.** A query that named a verb AND an
                // object asked for both; putting the object-less row first would answer half of it.
                score: 900 + folder.score)
        }
    }

    /// The longest leading run of words naming a place, and what is left.
    ///
    /// Connectives between the two halves are dropped — "duplicates **in** Legal" is the same
    /// request as "duplicates Legal" — and only there, so a folder genuinely called "In Progress"
    /// still matches by its own name.
    static func splitVerb(_ query: String) -> (PalettePlace, String)? {
        let words = query.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        var found: (PalettePlace, String)?
        // **Longest first — and today that direction is unobservable**, which is worth saying rather
        // than leaving it to look load-bearing: reversing it fails no test, because no two-word place
        // name in the vocabulary has a first word that is itself a place name ("to file" is the only
        // two-word entry, and bare "to" reaches nothing). It stays longest-first because the day a
        // second one is added whose head already matches, shortest-first routes to the wrong lens
        // with the object still attached — wrong, and invisible.
        //
        // The multi-word scan itself is *not* inert: a single-word parse loses "to file legal"
        // outright, which `aTwoWordPlaceNameIsFoundBeforeItsFirstWordCanMisfire` asserts.
        for count in stride(from: min(words.count - 1, 3), through: 1, by: -1) {
            let head = words.prefix(count).joined(separator: " ").lowercased()
            guard let place = PalettePlace.allCases.first(where: { place in
                place.keywords.contains(head) || place.title.lowercased() == head
            }) else { continue }
            var tail = Array(words.dropFirst(count))
            if let first = tail.first, ["in", "of", "for", "under", "at"].contains(first.lowercased()) {
                tail = Array(tail.dropFirst())
            }
            found = (place, tail.joined(separator: " "))
            break
        }
        return found
    }

    // MARK: Places

    static func placeRows(query: String) -> [PaletteRow] {
        PalettePlace.allCases.compactMap { place in
            let match = best(of: [place.title] + place.keywords, query: query)
            guard match > .none else { return nil }
            return PaletteRow(id: place.id, group: .places, title: place.title,
                              detail: place.detail, symbol: place.symbol,
                              route: place.route(scope: nil), score: score(match))
        }
    }

    // MARK: People — "aditi's files"

    /// The person a query names, if it names exactly one.
    ///
    /// **Delegated to ``PersonSearchOffer``, and that is not laziness.** The registry's matcher is
    /// phrase-first and longest-wins — "Aditi Abhishek" resolves to Aditi alone, and a query naming
    /// two people resolves to neither, because picking one arbitrarily is the over-attribution this
    /// household's names invite. A second matcher here would disagree with the pane search's offer
    /// on exactly the names that are hard, and the two would then answer the same question
    /// differently depending on which field you typed into.
    ///
    /// "aditi's files" works without any possessive handling of its own: `PersonRegistry.words`
    /// splits on non-alphanumerics, so the apostrophe and the trailing noun fall out of the phrase
    /// match. That is worth stating because the temptation is to add a stripper, and a second
    /// tokenizer is exactly what the paragraph above rules out.
    static func personRow(for query: String, index: PaletteIndex) -> PaletteRow? {
        guard let registry = index.registry,
              let person = PersonSearchOffer.person(matching: query, registry: registry)
        else { return nil }
        return PaletteRow(
            id: "person.\(person.id)",
            group: .people,
            title: "Everything that is \(person.displayName)'s",
            detail: person.relationship.map { "\($0.capitalized) · gathers across the whole source" }
                ?? "Gathers across the whole source",
            symbol: "person.crop.circle",
            route: .person(id: person.id),
            // Named, and said out loud rather than hidden: the roster can outlive the survey it was
            // built beside, and an offer whose accept does nothing is the "nothing happened" this
            // whole family of features exists to remove.
            unavailable: index.hasSurvey ? nil : "No document survey on this Mac yet",
            // Above a plain folder match: a query that resolves to exactly one person is a much
            // more specific claim than a substring hit on a folder name.
            score: 850)
    }

    // MARK: Folders

    struct RankedFolder: Equatable {
        let path: String
        let score: Int
    }

    /// Folders whose **leaf name or relative path** answers the query, best first.
    ///
    /// The leaf is tried first and scores higher: `Finance/US/Income Tax` is "Income Tax" to the
    /// person typing, and ranking by the full path would put every folder under `Income` above it.
    static func rankedFolders(matching query: String, in index: PaletteIndex) -> [RankedFolder] {
        var ranked: [RankedFolder] = []
        for folder in index.folders where !folder.isEmpty && folder != "." {
            let leafMatch = match(leaf(folder), query)
            let pathMatch = match(folder.replacingOccurrences(of: "/", with: " "), query)
            let combined = max(score(leafMatch), score(pathMatch) - 20)
            guard combined > 0 else { continue }
            // Shallower folders win ties: `Legal` beats `Archive/2019/Legal` for the query "legal",
            // because the top-level one is the folder that name means to the tree.
            let depth = folder.count { $0 == "/" }
            ranked.append(RankedFolder(path: folder, score: combined - depth))
        }
        return ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
    }

    static func folderRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        guard let root = index.providerRoot, !root.isEmpty else { return [] }
        return rankedFolders(matching: query, in: index).prefix(6).map { folder in
            PaletteRow(id: "folder.\(folder.path)", group: .folders,
                       title: leaf(folder.path), detail: folder.path,
                       symbol: "folder",
                       route: .folder(path: (root as NSString).appendingPathComponent(folder.path)),
                       score: folder.score)
        }
    }

    // MARK: Sources

    static func providerRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        index.providers.compactMap { provider in
            let match = match(provider.name, query)
            guard match > .none else { return nil }
            return providerRow(provider, score: score(match))
        }
    }

    static func providerRow(_ provider: PaletteProvider, score: Int) -> PaletteRow {
        PaletteRow(id: "source.\(provider.id)", group: .sources, title: provider.name,
                   detail: provider.isCurrent ? "The current source" : "Re-aim this workspace",
                   symbol: "externaldrive",
                   route: .provider(id: provider.id),
                   // ROADMAP 14 names this case specifically: an unmounted source is shown
                   // disabled WITH ITS REASON, not hidden. Hiding it teaches that the palette does
                   // not know about the drive; this answers the question that was asked.
                   unavailable: provider.isMounted ? nil : "Not mounted",
                   score: score)
    }

    // MARK: Actions

    static func actionRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        PaletteAction.allCases.compactMap { action in
            guard action != .chooseFolder || index.canChooseFolder else { return nil }
            let match = best(of: [action.title, action.title.replacingOccurrences(of: "…", with: "")]
                             + action.keywords, query: query)
            guard match > .none else { return nil }
            return actionRow(action, index: index, score: score(match))
        }
    }

    static func actionRow(_ action: PaletteAction, index: PaletteIndex, score: Int) -> PaletteRow {
        PaletteRow(id: "action.\(action.rawValue)", group: .actions, title: action.title,
                   symbol: action.symbol, route: .action(action),
                   unavailable: action == .rescan && index.isScanning
                       ? "A scan is already running" : nil,
                   score: score)
    }

    // MARK: The empty query

    /// What the palette shows before anything is typed: **where you have been, then where you can
    /// go.** Recents lead because the commonest reason to open a palette is to go back to the folder
    /// you were just in, and a list that led with nine fixed destinations would bury it.
    static func emptyQueryRows(index: PaletteIndex) -> [PaletteRow] {
        var rows: [PaletteRow] = []
        if let root = index.providerRoot, !root.isEmpty {
            // Pinned above recent: a pin is a standing choice and a recent is an accident of where
            // you happened to walk, so the standing one leads. Each says WHICH it is, because
            // labelling a folder pinned months ago as "Recent" is the wrong claim about it.
            let listed = index.pinnedFolders.prefix(4).map { ($0, "Pinned", "star.fill") }
                + index.recentFolders.prefix(4).map { ($0, "Recent", "clock.arrow.circlepath") }
            for (offset, entry) in listed.enumerated()
            where !entry.0.isEmpty && entry.0 != "." {
                rows.append(PaletteRow(
                    id: "folder.\(entry.0)", group: .folders, title: leaf(entry.0),
                    detail: "\(entry.1) · \(entry.0)", symbol: entry.2,
                    route: .folder(path: (root as NSString).appendingPathComponent(entry.0)),
                    score: 1_000 - offset))
            }
        }
        for (offset, place) in PalettePlace.allCases.enumerated() {
            rows.append(PaletteRow(id: place.id, group: .places, title: place.title,
                                   detail: place.detail, symbol: place.symbol,
                                   route: place.route(scope: nil), score: 900 - offset))
        }
        for (offset, provider) in index.providers.enumerated() {
            rows.append(providerRow(provider, score: 800 - offset))
        }
        for (offset, action) in PaletteAction.allCases.enumerated()
        where action != .chooseFolder || index.canChooseFolder {
            rows.append(actionRow(action, index: index, score: 700 - offset))
        }
        return sorted(rows)
    }

    // MARK: Scoring primitives

    static func leaf(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// A tier, comparing case- and diacritic-insensitively.
    ///
    /// `range(of:options:)` rather than a hand-rolled scan: it is the only correct way to compare
    /// user-typed text against folder names that carry accents, and it is measurably faster than a
    /// hand-rolled substring search over a list this size.
    static func match(_ candidate: String, _ query: String) -> PaletteMatch {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard !query.isEmpty, !candidate.isEmpty else { return .none }
        if candidate.compare(query, options: options) == .orderedSame { return .exact }
        guard let found = candidate.range(of: query, options: options) else { return .none }
        if found.lowerBound == candidate.startIndex { return .prefix }
        // A word boundary immediately before the hit — "Income **Tax**" for "tax".
        let before = candidate[candidate.index(before: found.lowerBound)]
        return before == " " || before == "-" || before == "_" ? .wordPrefix : .substring
    }

    static func best(of candidates: [String], query: String) -> PaletteMatch {
        candidates.reduce(PaletteMatch.none) { Swift.max($0, match($1, query)) }
    }

    /// A tier as a sortable number. Spread wide so a folder's depth penalty can never lift a
    /// substring hit above a prefix one.
    static func score(_ match: PaletteMatch) -> Int {
        switch match {
        case .none: return 0
        case .substring: return 100
        case .wordPrefix: return 200
        case .prefix: return 300
        case .exact: return 400
        }
    }
}

// MARK: - Moving through the list

/// What ↑, ↓ and ↩ do inside the palette.
///
/// **Extracted for the same reason ``PaletteRoute`` is a value.** The field's key handling and its
/// `onSubmit` are unreachable from a unit test, and this is precisely where the last routing bug of
/// this shape lived: three lines in a submit handler that nothing could exercise. The rules are here
/// and the view calls them.
public enum PaletteSelection {

    /// Where a freshly-computed list starts: **the first row that can actually be chosen.**
    ///
    /// Not simply row 0. Unavailable rows are deliberately kept in the list — an unmounted source
    /// says so rather than vanishing — and a list that opened with the highlight sitting on one
    /// would make ↩ do nothing, which reads as the palette being broken rather than as the source
    /// being unmounted.
    public static func initialIndex(in rows: [PaletteRow]) -> Int? {
        rows.firstIndex(where: \.isAvailable)
    }

    /// Where ↑ / ↓ land, **skipping unavailable rows and wrapping at the ends**.
    ///
    /// Wrapping because a palette is a short list you are meant to spin through, and stopping dead
    /// at the last row costs a second keystroke to get back to the top. Returns nil when nothing in
    /// the list can be chosen at all, so the caller never highlights an inert row.
    public static func moved(from current: Int?, by step: Int, in rows: [PaletteRow]) -> Int? {
        let choosable = rows.indices.filter { rows[$0].isAvailable }
        guard !choosable.isEmpty else { return nil }
        guard let current, let position = choosable.firstIndex(of: current) else {
            // Coming from nowhere (or from a row that is no longer choosable): ↓ takes the first,
            // ↑ takes the last.
            return step >= 0 ? choosable.first : choosable.last
        }
        let next = (position + step % choosable.count + choosable.count) % choosable.count
        return choosable[next]
    }

    /// What ↩ does: the route of the highlighted row, or nil if there is nothing to run.
    public static func chosen(at index: Int?, in rows: [PaletteRow]) -> PaletteRoute? {
        guard let index, rows.indices.contains(index), rows[index].isAvailable else { return nil }
        return rows[index].route
    }
}
