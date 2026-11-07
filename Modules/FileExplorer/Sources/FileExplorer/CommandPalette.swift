import Foundation
import Sync

// MARK: - Where a row takes you

/// One destination the palette can route to.
///
/// A value, not a closure, so routing is testable: a decision inside an `onSubmit` on a SwiftUI
/// `Button` can't be fired from a unit test (the pane search's ↩ became testable only once it was
/// pulled out into ``PaneSearchSubmit``). ``PaletteRouter`` turns a query into rows carrying routes,
/// a test asserts the routes, and the host's only job is to apply one.
public enum PaletteRoute: Equatable, Sendable {

    /// The Browse workspace: one tree, full width, nothing proposing anything.
    case browse
    /// The Compare workspace: two trees side by side.
    case compare
    /// The Edit workspace: one open text file, the app's only writable surface.
    ///
    /// Carries no folder, like Browse: the editor lists whatever folder the sidebar has selected,
    /// and the `.folder` route already moves that.
    case editor

    /// Organize, at this rail item (`nil` is the overview), optionally re-aimed at a folder.
    ///
    /// The scope is an **absolute path**, or nil to leave the current aim alone. Not a separate
    /// `.folder` route, because "organize income tax" is one request: a route that only switched
    /// workspace would leave Organize answering about wherever you were, the silent loss
    /// ``OrganizeScope`` exists to stop.
    case organize(lens: OrganizeLens?, scope: String?)

    /// Everything that is this person's: the gather ⌘↩ opens from the pane search.
    case person(id: String)

    /// Point the single source at this provider.
    case provider(id: String)

    /// Reveal this folder in the source browser, without re-aiming Organize.
    case folder(path: String)

    /// Point the aimed pane at another source **and land on this folder**: Go to Folder across
    /// sources.
    ///
    /// A case of its own, not a `.folder` with a provider added. `.folder`'s callers (`folderRows`,
    /// and the same-source arm of ``PaletteRouter/pathRow(query:index:probe:)``) assume the pane is
    /// already aimed at the right source. And the host's `switch` has no `default:` (pinned by
    /// `everyRouteCaseIsHandledWithoutADefaultArm`), so a distinct case makes the compiler ask the
    /// one site that has to handle it.
    ///
    /// The provider arrives as its id, a plain string, as ``settings(tab:)`` carries a tab:
    /// `FileExplorer` can't see the settings model, so a provider crosses as data
    /// (``PaletteProvider``). An id the settings no longer know is representable, and the host says
    /// so rather than switching to nothing.
    ///
    /// `path` is **absolute** (the typed path, standardized by `PalettePath`), and the host
    /// relativizes it against the named source's root, never the pane's current one.
    case folderInSource(providerId: String, path: String)

    /// A named action, run or opened.
    case action(PaletteAction)

    /// Settings, opened on one named tab: the raw value of `SettingsView.SettingsTab`, plus `/` and a
    /// page's raw value when the row was matched through a word on that page.
    ///
    /// A string, not the enum, because the enum is in the sibling `Settings` package, which this one
    /// can't see. The tab arrives as data (``PaletteSettingsTab``, injected on the index) and the
    /// host turns it back with `SettingsTab(rawValue:)`. A raw value that names no tab is possible,
    /// and the host says so rather than opening the wrong page, as `.person` does for a dropped id.
    ///
    /// Distinct from `.action(.settings)`, which opens the tab you were last on: "take me to
    /// Appearance" and "put Settings back where I left it" are different requests.
    case settings(tab: String)
}

/// The actions the palette can run.
///
/// Only things that already exist as a menu item or a header control. A palette is a second way to
/// reach what is there; an action reachable only here would be a verb nothing on screen teaches.
///
/// None is conditional. Availability that really varies is carried per row, in
/// ``PaletteRow/unavailable``, with the reason attached.
public enum PaletteAction: String, CaseIterable, Sendable {
    case rescan
    case newFolder
    case chooseFolder
    case findInPane
    /// The shape question about the folder you are standing in: the row menu's "Check This
    /// Folder's Shape", aimed at the pane's current folder instead of a row.
    case restructureThisFolder
    case settings
    case shortcuts
    case activityLog

    public var title: String {
        switch self {
        case .rescan: return "Rescan"
        case .newFolder: return "New Folder…"
        case .chooseFolder: return "Choose Folder…"
        case .findInPane: return "Find in Pane…"
        // The row context menu's exact words: one action wears one name wherever it appears, and
        // the row menu (a real menu item) is what makes this palette entry lawful.
        case .restructureThisFolder: return "Check This Folder’s Shape"
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
        case .restructureThisFolder: return "rectangle.3.group"
        case .settings: return "gearshape"
        case .shortcuts: return "keyboard"
        case .activityLog: return "list.bullet.rectangle"
        }
    }

    /// Extra words a query may use for this action that its title doesn't contain. The palette is
    /// for a user who thinks "rename" and has no target for the thought, so the vocabulary is the
    /// user's, not the menu's. Kept here so each action owns its synonyms.
    var keywords: [String] {
        switch self {
        case .rescan: return ["scan", "refresh", "reload"]
        case .newFolder: return ["make folder", "create folder"]
        case .chooseFolder: return ["add folder", "open folder", "pick folder", "source"]
        case .findInPane: return ["search", "find"]
        case .restructureThisFolder: return ["shape", "structure", "check", "habits", "organize"]
        case .settings: return ["preferences", "options"]
        case .shortcuts: return ["keys", "chords", "help"]
        case .activityLog: return ["log", "history"]
        }
    }
}

// MARK: - Rows

/// The palette's sections, in the order they are shown.
///
/// "Places", not "Workspaces": most places are not workspaces (of the nine, five are rail items
/// inside Organize and a sixth is its overview), and routing to a lens is the same act as routing
/// to a bar segment, so they belong under one name.
public enum PaletteGroup: String, CaseIterable, Sendable {
    case places = "Places"
    case people = "People"
    case folders = "Folders"
    case sources = "Sources"
    case actions = "Actions"
    /// The Settings tabs. Last, but only as the tie-break: a group's position is decided by its own
    /// best row (see ``PaletteRouter/sorted(_:)``), so an exact hit on "Appearance" still leads.
    /// Among groups that scored the same, Settings belongs behind places and files: a query that
    /// answers both a folder and a preferences page nearly always means the folder.
    ///
    /// The tie is real: a folder named `People` five levels deep takes a depth penalty to exactly
    /// a Settings row's 396, and only this rank separates them. Moving this case earlier in
    /// `allCases` fails `aFolderNamedLikeATabKeepsItsLead`.
    case settings = "Settings"

    /// Ties are broken in this order, which is also the order the sections are drawn in.
    var rank: Int { PaletteGroup.allCases.firstIndex(of: self) ?? 0 }
}

/// One row.
public struct PaletteRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let group: PaletteGroup
    public let title: String
    /// The second line: what this row is, or where it goes. nil draws a single-line row.
    public let detail: String?
    public let symbol: String
    public let route: PaletteRoute

    /// Why this row can't be chosen, or nil.
    ///
    /// A reason, not a Bool, and the row is kept rather than dropped. An unmounted source that
    /// vanished from the results would teach that the palette doesn't know it; the same row, dimmed
    /// and reading "Not mounted", answers the question asked.
    public let unavailable: String?

    public var isAvailable: Bool { unavailable == nil }

    /// How well this row matched: the sort key, kept on the row so a test can assert the order, not
    /// only the membership.
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
    /// Where this source lives, tilde-expanded. Only Go to Folder reads it, to decide which source
    /// a typed path is inside; the rest of the palette never names a source by its path.
    public let root: String

    public init(id: String, name: String, isMounted: Bool, isCurrent: Bool, root: String = "") {
        self.id = id
        self.name = name
        self.isMounted = isMounted
        self.isCurrent = isCurrent
        self.root = root
    }
}

/// A Settings tab, as the palette needs it.
///
    /// Injected rather than known, for the reason ``PaletteRoute/settings(tab:)`` gives: the tabs
    /// live in the `Settings` package, which this one doesn't depend on. `MacApp` maps
    /// `SettingsTabDigest` onto this; `SyncCloudTests` pins that the map drops no tab.
public struct PaletteSettingsTab: Equatable, Sendable {
    /// `SettingsTab.rawValue`, carried into the route unchanged.
    public let id: String
    /// The rail's name for the tab: "Appearance", "Sources".
    public let name: String
    /// One line saying what is on it, drawn as the row's second line.
    public let detail: String
    public let symbol: String

    /// Every word that should reach this tab: the titles and keywords of the controls on it.
    ///
    /// A whole tab's vocabulary behind one row, by design. A row per control would put several rows
    /// on screen that open the same page, and still couldn't scroll to the control, because the
    /// Settings sheet lands on a tab. Folding the words in keeps `glass`, `sk-ant` and
    /// `node_modules` answerable while the list stays at one row per tab.
    ///
    /// So a Settings row is often matched by text it doesn't display. That is what ``detail`` is
    /// for: the row can't bold what isn't in it, so it says what is on the tab.
    public let vocabulary: [String]

    /// The pages each word of ``vocabulary`` is on, for a tab with pages: lowercased word to the
    /// pages' raw values, in strip order. A row matched through its words opens the page they are
    /// most about, so `glass` lands on Appearance ▸ Look and not on whichever page was last
    /// shown. Empty for a one-page tab.
    public let pages: [String: [String]]

    /// The tab's pages in strip order, the last tie-break between them.
    public let pageOrder: [String]

    public init(id: String, name: String, detail: String, symbol: String, vocabulary: [String],
                pages: [String: [String]] = [:], pageOrder: [String] = []) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.vocabulary = vocabulary
        self.pages = pages
        self.pageOrder = pageOrder
    }

    /// The route for a row matched through `word`: the tab, and the word's page where it has one,
    /// as `tab/page` — the form `PaletteRoute.settings(tab:)` carries across the package wall.
    func routeID(matchedThrough word: String?) -> String {
        guard let word, let page = pages[word.lowercased()]?.first else { return id }
        return routeID(page: page)
    }

    func routeID(page: String?) -> String {
        page.map { "\(id)/\($0)" } ?? id
    }

    /// The page a query is most about: the one with the most words that match it, then the one
    /// whose best word matches it best, then the first in strip order. Not the first word in
    /// alphabetical order, which sent `ign` to the Google Drive switch over Ignored's three
    /// entries, and `folder` to Cloud Providers over Local Folders' five.
    func page(for query: String) -> String? {
        var best: [String: (count: Int, tier: PaletteMatch)] = [:]
        for word in vocabulary {
            let tier = PaletteRouter.match(word, query)
            guard tier != .none else { continue }
            for page in pages[word.lowercased()] ?? [] {
                let was = best[page] ?? (0, .none)
                best[page] = (was.count + 1, Swift.max(was.tier, tier))
            }
        }
        func rank(_ page: String) -> Int { pageOrder.firstIndex(of: page) ?? pageOrder.count }
        return best.max { a, b in
            if a.value.count != b.value.count { return a.value.count < b.value.count }
            if a.value.tier != b.value.tier { return a.value.tier < b.value.tier }
            return rank(a.key) > rank(b.key)
        }?.key
    }
}

/// Everything the router may read, snapshotted.
///
/// A plain `Sendable` value rather than the manager, so the routing table is a function of state a
/// test can write down in full. Nothing is optional for convenience: each field is something a
/// row's presence, wording or availability depends on.
public struct PaletteIndex: Equatable, Sendable {
    public var providers: [PaletteProvider]
    /// The absolute root of the source Organize and the rail are pointed at, if there is one.
    public var providerRoot: String?
    /// Folders under `providerRoot`, **relative**, from the folder profile the survey built.
    public var folders: [String]
    /// The leading segment every entry of `folders` shares: the survey anchor's position inside
    /// the source root, i.e. the source's `openAt`. Empty when the two are the same folder.
    ///
    /// The ranker subtracts it. A source's root is the account above its documents tree, so every
    /// key begins `Documents` (`My Drive Documents` on Drive), and
    /// ``PaletteRouter/rankedFolders(matching:in:)`` scores the path with slashes as spaces. Left in,
    /// typing `doc`, `my` or `drive` would prefix-match every surveyed folder and the group would
    /// show arbitrary rows instead of the folders whose names match.
    ///
    /// Set it from ``PaletteIndex/folderPrefix(profileRoot:providerRoot:)`` and from nothing else.
    public var folderPrefix: String
    /// Recently focused folders, most recent first, relative: the empty-query state.
    public var recentFolders: [String]
    /// Folders the user has pinned, relative. Two lists, not one, because they are two claims,
    /// where you just were and where you keep going back to, and a "Recent" label on a folder pinned
    /// months ago would be wrong.
    public var pinnedFolders: [String]

    /// Why no folder under this source can be reached right now, or nil.
    ///
    /// Set when the provider root didn't answer (an external drive asleep, a network mount down).
    /// That takes out every recent and pin at once, and the empty-query landing is that list, so
    /// dropping them would open ⌘K blank and make "no recents" look like "drive not awake". The rows
    /// are kept and marked instead, as for an unmounted source.
    ///
    /// It marks every folder row, not only the remembered ones: `folders` comes from the in-memory
    /// survey profile, which answers a typed query whether or not the disk is awake, so typing
    /// would otherwise offer the same tree as live destinations. One root, one answer.
    public var foldersUnavailable: String?
    /// This user's home directory, for expanding a typed `~`. On the index rather than read from
    /// `NSHomeDirectory()` inside the rule, so a test can resolve `~` against a fixture.
    public var home: String
    public var people: [Person]
    /// The registry, when there is one. Person routing is phrase-first and longest-wins; the
    /// palette must not hand-roll a second matcher (see ``PaletteRouter/personRow(for:index:)``).
    public var registry: PersonRegistry?
    /// True while a scan is running: the one thing that makes Rescan unavailable rather than absent.
    public var isScanning: Bool
    /// Whether a document survey exists for a person gather to read. Without one the offer would be
    /// a button that does nothing.
    public var hasSurvey: Bool
    /// The Settings tabs, in the rail's order. Empty offers no Settings rows, the default, so a test
    /// about the folder rules needn't reason about preferences pages it never mentions.
    public var settingsTabs: [PaletteSettingsTab]

    public init(providers: [PaletteProvider] = [], providerRoot: String? = nil,
                folders: [String] = [], folderPrefix: String = "",
                recentFolders: [String] = [],
                pinnedFolders: [String] = [], foldersUnavailable: String? = nil,
                home: String = NSHomeDirectory(),
                people: [Person] = [],
                registry: PersonRegistry? = nil, isScanning: Bool = false,
                hasSurvey: Bool = false,
                settingsTabs: [PaletteSettingsTab] = []) {
        self.providers = providers
        self.providerRoot = providerRoot
        self.folders = folders
        self.folderPrefix = folderPrefix
        self.recentFolders = recentFolders
        self.pinnedFolders = pinnedFolders
        self.foldersUnavailable = foldersUnavailable
        self.home = home
        self.people = people
        self.registry = registry
        self.isScanning = isScanning
        self.hasSurvey = hasSurvey
        self.settingsTabs = settingsTabs
    }
}

// MARK: - Building the folder index

public extension PaletteIndex {

    /// The folder list for a survey profile, or empty when that profile is about a different
    /// tree.
    ///
    /// Containment, with the keys re-based onto the provider root. The keys are relative to the
    /// profile's root, but every path the index joins them with (recents, pins, typed paths) is
    /// relative to the provider root. A profile is surveyed over the source's anchor, which sits
    /// inside the root, so the two bases differ by the source's `openAt` and the keys must carry it.
    ///
    /// Getting this wrong is silent: the palette would show rows from 0 folders, and every folder
    /// query and "organize <folder>" would answer nothing, with no routing or render test noticing.
    /// So it compares expanded paths by containment, not equality, and re-bases here rather than at
    /// the call site, where a second copy of the rule could drift.
    ///
    /// A profile rooted outside the provider root still yields nothing: its keys name paths that
    /// don't exist under this source.
    static func folders(profileRoot: String?, providerRoot: String, keys: [String]) -> [String] {
        guard let prefix = folderPrefix(profileRoot: profileRoot, providerRoot: providerRoot) else {
            return []
        }
        // `.` is the profile root itself, where the rail already opens: not a destination.
        return keys.filter { !$0.isEmpty && $0 != "." }
            .map { PathBoundary.joinRelative(prefix, $0) }
    }

    /// The segment `folders(profileRoot:providerRoot:keys:)` prepends to every key: the survey
    /// anchor's position inside the source root, i.e. the source's `openAt`. Nil on exactly the
    /// inputs that make `folders` empty.
    ///
    /// Lets the ranker score what a key means rather than where it lives. The same computation
    /// `folders` is written in terms of, carried onto the index as `PaletteIndex.folderPrefix` and
    /// stripped off in ``PaletteRouter/rankedFolders(matching:in:)`` (see it for why).
    /// `theIndexedFoldersAllCarryTheIndexPrefix` binds the two so neither can drift.
    static func folderPrefix(profileRoot: String?, providerRoot: String) -> String? {
        let profile = (profileRoot as NSString?)?.expandingTildeInPath ?? ""
        let provider = (providerRoot as NSString).expandingTildeInPath
        guard !profile.isEmpty, !provider.isEmpty else { return nil }
        return PathBoundary.relativize(profile, under: provider)
    }
}

// MARK: - Places

/// A destination in the app's own vocabulary: the three workspaces that aren't Organize, and
/// Organize's rail.
///
/// Spelled out rather than derived from `Workspace`, which lives in `MacApp`, a target in no SPM
/// package, so a routing table there could be reached by no `swift test`. The host only maps these
/// cases onto its own selection type.
enum PalettePlace: CaseIterable {
    case browse
    case compare
    case editor
    case organizeOverview
    case lens(OrganizeLens)

    /// Hand-written, because the associated-value case rules out the synthesized conformance, which
    /// makes this the one place a new case could be added and never offered.
    /// `CommandPaletteTests.everyPlaceIsOfferedByTheHandWrittenAllCases` counts what this list
    /// produces against what the type can build.
    static var allCases: [PalettePlace] {
        [.browse, .compare, .organizeOverview]
            // `railItems`, not `allCases`: the folded Names lens isn't a place, and offering it
            // beside Renames would be two rows for one landing. Its vocabulary is on Renames.
            //
            // Storage comes through this map like every other lens, so it takes a folder:
            // "storage Legal" analyses `Legal` rather than ignoring the word.
            + OrganizeLens.railItems.map(PalettePlace.lens) + [.editor]
    }

    var title: String {
        switch self {
        case .browse: return "Browse"
        case .compare: return "Compare"
        case .editor: return "Edit"
        case .organizeOverview: return "Organize"
        case .lens(let lens): return "Organize ▸ \(lens.title)"
        }
    }

    /// The words a query may use to reach this place, beyond its title.
    ///
    /// `"file"` and `"filing"` reach To File because that is what the app calls the act elsewhere;
    /// `"rename"` reaches Renames for the user who thinks "rename" and has nothing to aim at, since
    /// Rename has no destination on the bar.
    var keywords: [String] {
        switch self {
        // "files" and "finder" are the words for going to look at your files rather than having
        // the app tell you something about them, the distinction Browse exists to carry.
        case .browse: return ["browse", "files", "finder", "folders", "move", "look"]
        case .compare: return ["diff", "differences", "sync", "compare"]
        // "note" and "write" are for putting words in a file, which no other place answers to.
        // The PDF words are for Edit's other half: a PDF opens, is filled in and signed there.
        case .editor: return ["edit", "editor", "text", "write", "note", "notes", "markdown",
                              "pdf", "pdfs", "sign", "signature", "fill"]
        case .organizeOverview: return ["organize", "tidy", "all"]
        case .lens(.toFile): return ["organize", "file", "filing", "loose", "inbox", "to file"]
        case .lens(.duplicates): return ["organize", "duplicates", "dupes", "copies", "identical"]
        case .lens(.renames): return ["organize", "renames", "rename", "numbering", "backlog",
                                      "folders", "names", "risky", "illegal", "characters"]
        case .lens(.restructure): return ["organize", "restructure", "structure", "shape", "habits"]
        case .lens(.rules): return ["organize", "rules", "automations", "automatic", "learned"]
        // `space`, `disk` and `size` are what someone reaches for who wants to know where their
        // storage went.
        case .lens(.storage): return ["organize", "storage", "space", "disk", "size", "large",
                                      "reclaim", "treemap"]
        }
    }

    var symbol: String {
        switch self {
        case .browse: return "folder"
        case .compare: return "arrow.left.arrow.right"
        case .editor: return "square.and.pencil"
        case .organizeOverview: return "folder.badge.gearshape"
        case .lens(let lens): return lens.symbol
        }
    }

    var detail: String {
        switch self {
        case .browse: return "Your files, with nothing proposed"
        case .compare: return "Two trees, side by side"
        case .editor: return "Write in a text file, or fill and sign a PDF"
        case .organizeOverview: return "Every lens’s answer, on one page"
        case .lens(let lens): return lens.help(state: .configuration)
        }
    }

    var id: String {
        switch self {
        case .browse: return "place.browse"
        case .compare: return "place.compare"
        case .editor: return "place.editor"
        case .organizeOverview: return "place.organize"
        case .lens(let lens): return "place.organize.\(lens.rawValue)"
        }
    }

    /// This place, optionally re-aimed at a folder. Only Organize, its lenses included, can carry a
    /// scope: Compare has two trees, and Browse and Editor have no subject to re-aim. Both show
    /// wherever the pane already is, and the `.folder` route is how the palette moves the pane.
    func route(scope: String?) -> PaletteRoute {
        switch self {
        case .browse: return .browse
        case .compare: return .compare
        case .editor: return .editor
        case .organizeOverview: return .organize(lens: nil, scope: scope)
        case .lens(let lens): return .organize(lens: lens, scope: scope)
        }
    }

    /// Whether "<this place> <a folder>" is a request that can be honoured.
    var takesAFolder: Bool {
        switch self {
        case .browse, .compare, .editor: return false
        case .organizeOverview, .lens: return true
        }
    }
}

extension PalettePlace: Equatable {}

// MARK: - Matching

/// How well a candidate answers a query: ordered, and the order is the ranking.
///
/// Tiers rather than a similarity score: the whole title beats the start of a word, which beats
/// somewhere in the middle, and that is all anyone can predict about a palette. A continuous score
/// would be unpredictable exactly where being wrong costs a keystroke.
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
/// Every decision the palette makes is here, and it is pure. See ``PaletteRoute`` for why that
/// matters.
public enum PaletteRouter {

    /// Rows for a query, best first.
    /// - Parameter probe: what is at a typed path, for **Go to Folder**. `nil` means the caller
    ///   can't answer, and no path row is offered on faith. Injected because it is the router's only
    ///   disk access and runs on the keystroke path: `PalettePath` says what bounds it, and
    ///   `theHostGivesTheRouterARealPathProbe` stops the app quietly passing `nil`.
    public static func rows(query: String, index: PaletteIndex,
                            probe: PalettePathProbe? = nil) -> [PaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyQueryRows(index: index) }

        var rows: [PaletteRow] = []
        if let path = pathRow(query: trimmed, index: index, probe: probe) { rows.append(path) }
        rows.append(contentsOf: verbRows(query: trimmed, index: index))
        rows.append(contentsOf: placeRows(query: trimmed))
        if let person = personRow(for: trimmed, index: index) { rows.append(person) }
        rows.append(contentsOf: folderRows(query: trimmed, index: index))
        rows.append(contentsOf: providerRows(query: trimmed, index: index))
        rows.append(contentsOf: actionRows(query: trimmed, index: index))
        rows.append(contentsOf: settingsRows(query: trimmed, index: index))

        // No de-duplication pass: every builder above mints at most one row per id, so one could
        // never fire. "organize legal" reaches Organize twice, but as two rows with different ids
        // and destinations ("Organize ▸ Legal" and "Organize"). `aDestinationIsNeverListedTwice`
        // pins the property, so a builder that did collide would fail.
        return sorted(rows)
    }

    /// Best first, and each group in one run.
    ///
    /// Groups are ordered by their own best row, and each group's rows follow before the next
    /// starts; within a group by score, then title, so the list is fully deterministic. A flat score
    /// sort would repeat headers, since `PaletteResultsList` emits one wherever the group changes and
    /// a group's rows spread across the score range: short queries would show the same heading
    /// several times.
    ///
    /// The best match is still the first row, and `PaletteSelection` still walks the array, so ↑/↓
    /// move the way the eye does; the rest of that group just comes with it.
    static func sorted(_ rows: [PaletteRow]) -> [PaletteRow] {
        let byGroup = Dictionary(grouping: rows, by: \.group)
        return PaletteGroup.allCases
            .compactMap { group -> (group: PaletteGroup, rows: [PaletteRow])? in
                guard let inGroup = byGroup[group], !inGroup.isEmpty else { return nil }
                return (group, inGroup.sorted {
                    $0.score != $1.score ? $0.score > $1.score : $0.title < $1.title
                })
            }
            // The group's best row decides where the group goes; `rank` breaks a tie between two
            // groups whose best rows scored the same, so the order is total.
            .sorted {
                let a = $0.rows.first?.score ?? 0, b = $1.rows.first?.score ?? 0
                return a != b ? a > b : $0.group.rank < $1.group.rank
            }
            .flatMap(\.rows)
    }

    // MARK: The lede — "organize income tax", "duplicates in Legal"

    /// Rows for a query that names a place and then a folder: the palette's lede.
    ///
    /// "organize income tax" is a verb and an object, and answering it with the Organize row alone
    /// drops the object silently: you'd land on Organize still answering about wherever you were.
    ///
    /// The parse is deliberately blunt: take the **longest leading run of words** that names a
    /// place, and treat the rest as a folder. No grammar, no stop-word list beyond the connectives
    /// below, because anything it gets wrong falls back to an ordinary place row, already listed.
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
                // `scope` is a folder under `providerRoot`, as `folderRows`' path is, so a root
                // that didn't answer can't deliver it either: running it would write a scope for a
                // folder that isn't there, move the workspace and reveal nothing. Same mark, same
                // string; `everyPathBearingRouteIsRefusedWhenTheRootIsAsleep` walks all three.
                unavailable: index.foldersUnavailable,
                // Above a bare place match: a query naming a verb and an object asked for both,
                // and the object-less row first would answer half of it.
                score: 900 + folder.score)
        }
    }

    /// The longest leading run of words naming a place, and what is left. Connectives between the
    /// halves are dropped ("duplicates **in** Legal" means "duplicates Legal"), and only there, so a
    /// folder called "In Progress" still matches by its own name.
    static func splitVerb(_ query: String) -> (PalettePlace, String)? {
        let words = query.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        var found: (PalettePlace, String)?
        // Longest first. No current two-word place name starts with a word that is itself a place
        // ("to file" is the only one, and bare "to" reaches nothing), so reversing this fails no
        // test today; but add one whose head matches and shortest-first would route to the wrong
        // lens, object attached, invisibly.
        //
        // The multi-word scan itself matters: a single-word parse loses "to file legal", which
        // `aTwoWordPlaceNameIsFoundBeforeItsFirstWordCanMisfire` asserts.
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

    // MARK: People — "daughter's files"

    /// The person a query names, if it names exactly one.
    ///
    /// Delegated to ``PersonSearchOffer`` so the palette and the pane search can't disagree. The
    /// registry's matcher is phrase-first and longest-wins: "Daughter Father" resolves to Daughter
    /// alone, and a query naming two people resolves to neither rather than over-attributing. A
    /// second matcher would differ on exactly the hard names.
    ///
    /// "daughter's files" needs no possessive handling: `PersonRegistry.words` splits on
    /// non-alphanumerics, so the apostrophe and trailing noun fall out of the phrase match. Don't
    /// add a stripper; a second tokenizer is what this rules out.
    static func personRow(for query: String, index: PaletteIndex) -> PaletteRow? {
        guard let registry = index.registry,
              let person = PersonSearchOffer.person(matching: query, registry: registry)
        else { return nil }
        return PaletteRow(
            id: "person.\(person.id)",
            group: .people,
            title: "Everything that is \(person.displayName)’s",
            detail: person.relationship.map { "\($0.capitalized) · gathers across the whole source" }
                ?? "Gathers across the whole source",
            symbol: "person.crop.circle",
            route: .person(id: person.id),
            // Named, not hidden: the roster can outlive the survey it was built beside, and an
            // offer whose accept does nothing is the "nothing happened" this feature removes.
            unavailable: index.hasSurvey ? nil : "No document survey on this Mac yet",
            // Above a plain folder match: resolving to exactly one person is a much more specific
            // claim than a substring hit on a folder name.
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
    ///
    /// The path is scored below the source's landing folder (`index.folderPrefix` is subtracted).
    /// Every key carries the same leading `Documents`, and with slashes scored as spaces `doc` would
    /// prefix-match every folder at an identical score. A folder is scored on the part of its path
    /// that distinguishes it, so the landing folder's own name is not a query.
    ///
    /// `path` on the result stays the whole key, since the route and the detail line use it. Only
    /// the scoring string is trimmed.
    static func rankedFolders(matching query: String, in index: PaletteIndex) -> [RankedFolder] {
        var ranked: [RankedFolder] = []
        for folder in index.folders where !folder.isEmpty && folder != "." {
            let distinguishing = below(index.folderPrefix, folder)
            let leafMatch = match(leaf(folder), query)
            let pathMatch = match(distinguishing.replacingOccurrences(of: "/", with: " "), query)
            let combined = max(score(leafMatch), score(pathMatch) - 20)
            guard combined > 0 else { continue }
            // Shallower folders win ties: `Legal` beats `Archive/2019/Legal` for "legal", since the
            // top-level one is what that name means to the tree. Depth is measured on the trimmed
            // path, the depth the person navigating sees.
            let depth = distinguishing.count { $0 == "/" }
            ranked.append(RankedFolder(path: folder, score: combined - depth))
        }
        return ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
    }

    /// `folder` with a leading `prefix` component removed: the part of the path that distinguishes
    /// it from its siblings under the survey anchor.
    ///
    /// Only on a component boundary: a plain `hasPrefix` would turn `Documentsly/Q4` into `y/Q4`,
    /// the trap `PaletteIndex.folders` guards on the absolute side. A folder not under the prefix is
    /// returned whole rather than dropped; it is still a real destination.
    static func below(_ prefix: String, _ folder: String) -> String {
        guard !prefix.isEmpty, folder.hasPrefix(prefix + "/") else { return folder }
        return String(folder.dropFirst(prefix.count + 1))
    }

    // MARK: Go to Folder — a typed path

    /// The one row a typed path produces, or nil when the query isn't a path at all.
    ///
    /// Always exactly one row, and often a refusal. The user said precisely where they mean, so
    /// there is nothing to rank, and a path that resolves to nothing or lies outside every source
    /// gets an answer rather than an empty list.
    ///
    /// A path inside another configured, mounted source is a navigation the app can perform, so it
    /// is a live row routing to ``PaletteRoute/folderInSource(providerId:path:)``. The other three
    /// cases are refusals; the branch below says why.
    ///
    /// The checks run in `PalettePath`'s stall-guard order: everything the index can answer first,
    /// the disk last and only inside the aimed source, once that source has answered.
    ///
    /// **The route on a refusal is not a destination.** It is the typed path, because a refusal is
    /// reached before anything knows whether that path names a folder, a file or nothing;
    /// `PaletteSelection.chosen` stops it being run, as for an unmounted source's row. Read
    /// `unavailable` before `route` on any row from here.
    static func pathRow(query: String, index: PaletteIndex,
                        probe: PalettePathProbe?) -> PaletteRow? {
        guard PalettePath.looksLikeAPath(query), let probe else { return nil }
        let typed = PalettePath.absolute(query, home: index.home)
        // Refusals first, each stated without asking the disk. `id` is the typed path rather than
        // the destination, so a refusal and the row it becomes once the path is fixed are the same
        // row, and the highlight doesn't jump as you type.
        //
        // Keep reasons short: `PaletteResultsList` draws the reason `.fixedSize()`, so it never
        // truncates and squeezes the path detail instead. At the 320pt floor a 32-character reason
        // still left the title intact; much longer starts eating the folder name, the half that
        // says which folder was refused. New reasons should come in under 32 characters.
        //
        // `unknown` marks the one refusal that is a claim about existence. The other two are about
        // reachability (the folder is probably there, in a source not mounted or not configured),
        // and a question mark would wrongly say the app doesn't know whether it exists.
        func refusal(_ reason: String, unknown: Bool = false) -> PaletteRow {
            PaletteRow(id: "path.\(typed)", group: .folders, title: leaf(typed), detail: typed,
                       symbol: unknown ? "folder.badge.questionmark" : "folder",
                       route: .folder(path: typed),
                       unavailable: reason, score: pathRowScore)
        }
        // Deliverable is decided against `providerRoot`, the root the reveal relativizes against,
        // not the owning provider's `isCurrent` flag.
        //
        // Nested sources make those differ, and they are ordinary: `~/Documents` and
        // `~/Documents/Clients` can both be configured, and `PalettePath.owner` answers with the
        // innermost. With the pane on `~/Documents` and a path inside `Clients`, the owner isn't
        // current, yet the pane can show the folder. Two sources on one folder (allowed by
        // `SettingsManager` for a re-pointed account) do the same. Deciding on `isCurrent` would
        // hand that folder to `.folderInSource` and silently switch the pane to a source it never
        // needed to leave. `providerRoot` can't drift from the route: it is the value the route is
        // applied with.
        guard PathBoundary.contains(typed, under: index.providerRoot ?? "") else {
            guard let owner = PalettePath.owner(of: typed, in: index.providers) else {
                // The commonest refusal: this palette can only show folders inside a source,
                // because a pane is a source.
                return refusal("Not in any source")
            }
            guard owner.isMounted else { return refusal("\(owner.name) is not mounted") }
            // A live row: the host switches the pane to the owning source and lands on the folder.
            // It must suppress the provider change's own navigation reset (the counter
            // `adoptProviderForTab` arms) and drive the reload, or the pane lands at the source
            // root with the typed folder dropped. `unavailable` is nil, which is what lets
            // `PaletteSelection.chosen` return it.
            //
            // The other three stay refusals, each for a reason this one lacks. "Not in any source"
            // is about the configuration: there is no source to switch to. "<Source> is not
            // mounted" names a source that can't be shown. "No folder at that path" is a claim
            // about existence, made only inside the aimed source.
            //
            // The disk is not asked here, by the stall guard: a `stat` inside a source the pane
            // isn't showing has no `foldersUnavailable` in front of it as the aimed root does
            // (`theDiskIsNeverAskedAboutAPathOutsideTheAimedSource` holds the order). So the row is
            // offered without knowing the folder is there, and the host probes once on ↩, off the
            // keystroke path, and refuses out loud rather than switching to a folder that is gone.
            //
            // The title carries the verb and the source, since the row's content is that the pane
            // changes source. The detail is the bare path because `PaletteResultsList` truncates a
            // detail containing `/` in the middle so the leaf survives; appending anything would
            // move the leaf into the middle. The list already draws `↩` on a live selected row.
            return PaletteRow(id: "path.\(typed)", group: .folders,
                              title: "Open in \(owner.name)", detail: typed,
                              symbol: "folder",
                              route: .folderInSource(providerId: owner.id, path: typed),
                              score: pathRowScore)
        }
        // The aimed root itself didn't answer. Every remembered folder already carries this reason
        // (`foldersUnavailable`), so a typed path under the same root says the same, and probing a
        // child of a root that didn't answer is the stall this ordering exists to avoid.
        if let asleep = index.foldersUnavailable { return refusal(asleep) }
        switch probe(typed) {
        case .missing:
            return refusal("No folder at that path", unknown: true)
        case .directory:
            return PaletteRow(id: "path.\(typed)", group: .folders, title: leaf(typed),
                              detail: typed, symbol: "folder", route: .folder(path: typed),
                              score: pathRowScore)
        case .file:
            // A pasted path is usually a file's: that is what a Finder copy puts on the clipboard.
            // Its enclosing folder is the destination, as ⇧⌘G accepts a file, and the row says so
            // rather than silently going somewhere the user didn't type.
            let parent = (typed as NSString).deletingLastPathComponent
            return PaletteRow(id: "path.\(typed)", group: .folders, title: leaf(parent),
                              detail: "Enclosing folder of \(leaf(typed))", symbol: "folder",
                              route: .folder(path: parent), score: pathRowScore)
        }
    }

    /// Above every other folder row. A typed path is the most specific claim a query can make
    /// (nothing was inferred from it), so it leads, and `initialIndex` puts ↩ on it.
    static let pathRowScore = 1_100

    static func folderRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        guard let root = index.providerRoot, !root.isEmpty else { return [] }
        return rankedFolders(matching: query, in: index).prefix(6).map { folder in
            PaletteRow(id: "folder.\(folder.path)", group: .folders,
                       title: leaf(folder.path), detail: folder.path,
                       symbol: "folder",
                       route: .folder(path: (root as NSString).appendingPathComponent(folder.path)),
                       // The landing's mark, for the same root. These come from the in-memory
                       // survey profile and answer a query with the drive asleep; offering them
                       // live while the landing says "Not available" would make two claims about
                       // one disk.
                       unavailable: index.foldersUnavailable,
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
                   // An unmounted source is shown disabled with its reason, not hidden: hiding it
                   // would teach that the palette doesn't know the drive.
                   unavailable: provider.isMounted ? nil : "Not mounted",
                   score: score)
    }

    // MARK: Actions

    static func actionRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        PaletteAction.allCases.compactMap { action in
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

    // MARK: Settings

    /// One row per Settings tab, matched on its **name and its whole vocabulary**. Two candidates,
    /// the second penalised:
    ///
    /// - the row's own **title** and the tab **name**, at full score. `"Settings ▸ Appearance"`
    ///   carries the prefix, so typing `settings` lists every tab, as `organize` lists the overview
    ///   and every lens.
    /// - every word in ``PaletteSettingsTab/vocabulary``, at `score - 20`, the penalty
    ///   ``rankedFolders(matching:in:)`` puts on a path match under a leaf match.
    ///
    /// The penalty matters: without it, a tab that only lists a word in its vocabulary could order
    /// against the tab named by that word by luck. With it, a vocabulary hit can never reach the
    /// tier above: 20 exceeds the largest position decrement, and the tiers are 100 apart.
    ///
    /// The decrement keeps the rail's order among tabs that matched equally well, as `settings`
    /// produces. `index.settingsTabs` arrives in rail order and this is the only thing preserving it.
    ///
    /// Cost: about 1 ms of the ~16 ms `rows` takes over a 3,000-folder tree, and `rows` runs twice
    /// per keystroke.
    static func settingsRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        index.settingsTabs.enumerated().compactMap { offset, tab in
            let title = settingsTitle(tab)
            let named = best(of: [title, tab.name], query: query)
            let spoken = best(of: tab.vocabulary, query: query)
            let combined = Swift.max(score(named), score(spoken) - vocabularyPenalty)
            guard combined > 0 else { return nil }
            // Matched through its words, not its name: open the page they are most about.
            let page = score(spoken) - vocabularyPenalty > score(named) ? tab.page(for: query) : nil
            return PaletteRow(id: "settings.\(tab.id)", group: .settings, title: title,
                              detail: tab.detail, symbol: tab.symbol,
                              route: .settings(tab: tab.routeID(page: page)),
                              score: combined - Swift.min(offset, maxPositionDecrement))
        }
    }

    /// How far a vocabulary match scores below a name match, as in
    /// ``rankedFolders(matching:in:)`` for a path match under a leaf match.
    static let vocabularyPenalty = 20

    /// The largest position decrement a Settings row may take, derived from the penalty.
    ///
    /// The ordering holds only while every decrement is smaller than the smallest gap between two
    /// outcomes: the four tiers at full score (100–400) and penalised (80–380), so the gap is
    /// `vocabularyPenalty` itself, and `penalty - 1` is the largest decrement that can't cross it.
    ///
    /// Clamped rather than asserted, so adding tabs never lets rows outrank each other by rail
    /// position. Past the clamp, tabs tie and fall back to the title: a worse order, never a wrong
    /// one.
    static let maxPositionDecrement = vocabularyPenalty - 1

    /// `"Settings ▸ Appearance"`: the separator `PalettePlace` draws for Organize's lenses, since a
    /// Settings tab is a page inside a thing exactly as a lens is.
    ///
    /// The prefix repeats the group header and stays anyway: the header scrolls away and the row
    /// doesn't. `GoToResultsPanel.listMaxHeight` shows about nine two-line rows, so the tabs
    /// can't all sit under their heading, and a row reading only "Appearance" past its header
    /// looks like a folder of that name. That is worth the width it costs at the 320pt floor.
    static func settingsTitle(_ tab: PaletteSettingsTab) -> String { "Settings ▸ \(tab.name)" }

    // MARK: The empty query

    /// What the palette shows before anything is typed: where you have been, then where you can
    /// go. Recents lead because the commonest reason to open a palette is to go back to the
    /// folder you were just in.
    static func emptyQueryRows(index: PaletteIndex) -> [PaletteRow] {
        var rows: [PaletteRow] = []
        if let root = index.providerRoot, !root.isEmpty {
            // Favorites above recent: a favorite is a standing choice, a recent an accident of
            // where you walked. Each says which it is. "Favorite", not "Pinned": "pin" belongs to
            // tabs.
            let listed = index.pinnedFolders.prefix(4).map { ($0, "Favorite", "star.fill") }
                + index.recentFolders.prefix(4).map { ($0, "Recent", "clock.arrow.circlepath") }
            for (offset, entry) in listed.enumerated()
            where !entry.0.isEmpty && entry.0 != "." {
                rows.append(PaletteRow(
                    id: "folder.\(entry.0)", group: .folders, title: leaf(entry.0),
                    detail: "\(entry.1) · \(entry.0)", symbol: entry.2,
                    route: .folder(path: (root as NSString).appendingPathComponent(entry.0)),
                    // Kept and marked rather than dropped when the root is asleep (see
                    // `foldersUnavailable`). ↑↓ skip these and ↩ refuses them, so a row that
                    // can't deliver is never run.
                    unavailable: index.foldersUnavailable,
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
        for (offset, action) in PaletteAction.allCases.enumerated() {
            rows.append(actionRow(action, index: index, score: 700 - offset))
        }
        // No Settings tabs here: nine more rows would nearly double the landing and push the
        // recents off it. `Settings…` is already among the actions, and someone who has typed
        // nothing hasn't named a tab. They appear as soon as a query does.
        return sorted(rows)
    }

    // MARK: Scoring primitives

    static func leaf(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// A tier, comparing case- and diacritic-insensitively. `range(of:options:)` because it is the
    /// correct way to compare typed text with accented folder names, and faster than a hand-rolled
    /// scan over a list this size.
    static func match(_ candidate: String, _ query: String) -> PaletteMatch {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard !query.isEmpty, !candidate.isEmpty else { return .none }
        if candidate.compare(query, options: options) == .orderedSame { return .exact }
        guard let found = candidate.range(of: query, options: options) else { return .none }
        if found.lowerBound == candidate.startIndex { return .prefix }
        // A word boundary immediately before the hit: "Income **Tax**" for "tax".
        let before = candidate[candidate.index(before: found.lowerBound)]
        return before == " " || before == "-" || before == "_" ? .wordPrefix : .substring
    }

    static func best(of candidates: [String], query: String) -> PaletteMatch {
        candidates.reduce(PaletteMatch.none) { Swift.max($0, match($1, query)) }
    }

    /// The range `match` decided by: the same lookup with the same options, so the row can
    /// emphasize exactly what matched. This is the one matcher: a second tokenizer for display
    /// would disagree with the ranking on case folds and diacritics.
    ///
    /// nil when the string doesn't contain the query: a row matched through its keywords or a verb
    /// parse draws no emphasis, because the visible text didn't match.
    static func matchRange(_ candidate: String, _ query: String) -> Range<String.Index>? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        return candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
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
/// Extracted for the same reason ``PaletteRoute`` is a value: the field's key handling and its
/// `onSubmit` are unreachable from a unit test. The rules are here and the view calls them.
public enum PaletteSelection {

    /// Where a freshly computed list starts: the first row that can actually be chosen. Not
    /// simply row 0: unavailable rows stay in the list, and a highlight opening on one would make ↩
    /// do nothing, which reads as the palette being broken.
    public static func initialIndex(in rows: [PaletteRow]) -> Int? {
        rows.firstIndex(where: \.isAvailable)
    }

    /// Where ↑ / ↓ land, skipping unavailable rows and wrapping at the ends: a palette is a
    /// short list you spin through, and stopping at the last row costs a keystroke back. Returns
    /// nil when nothing can be chosen, so the caller never highlights an inert row.
    public static func moved(from current: Int?, by step: Int, in rows: [PaletteRow]) -> Int? {
        let choosable = rows.indices.filter { rows[$0].isAvailable }
        guard !choosable.isEmpty else { return nil }
        guard let current, let position = choosable.firstIndex(of: current) else {
            // Coming from nowhere, or from a row no longer choosable: ↓ takes the first, ↑ the
            // last.
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
