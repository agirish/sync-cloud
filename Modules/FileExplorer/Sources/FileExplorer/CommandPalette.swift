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

    /// The Browse workspace — one tree, full width, nothing proposing anything.
    case browse
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

    /// Settings, opened on one named tab — the raw value of `SettingsView.SettingsTab`.
    ///
    /// **A string, not the enum, because the enum is in a package this one cannot see.**
    /// `FileExplorer` and `Settings` are siblings, so the tab arrives here as data
    /// (``PaletteSettingsTab``, injected on the index) and leaves the same way; the host turns it
    /// back into a case with `SettingsTab(rawValue:)`. A raw value that no longer names a tab is
    /// therefore possible in principle, and the host says so out loud rather than opening the
    /// wrong page — the same treatment `.person` gets for an id the registry has dropped.
    ///
    /// Distinct from `.action(.settings)`, which opens **the tab you were last on**. Two requests,
    /// two destinations: "take me to Appearance" and "put Settings back where I left it" are not
    /// the same thing, so neither row is a duplicate of the other.
    case settings(tab: String)
}

/// The actions the palette can run.
///
/// Deliberately **only things that already exist as a menu item or a header control.** A palette is
/// a second way to reach what is there; inventing an action reachable *only* here would put a verb
/// in the app that nothing on screen can teach you.
///
/// **None of them is conditional, and one of them used to pretend to be.** `PaletteIndex` carried a
/// `canChooseFolder` flag gating "Choose Folder…", and every production call site passed `true`,
/// because the open panel behind it is always available — a field that looks like it varies and
/// cannot, with a test exercising a value the app never sends. Availability that is real is carried
/// per row, in ``PaletteRow/unavailable``, with the reason attached.
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
/// **"Places" rather than "Workspaces"**, because six of the ten places are rail items *inside*
/// Organize. Calling the group Workspaces would have made the six lenses look like a different kind
/// of thing from the four segments, when routing to them is exactly the same act — and the lenses
/// are the reason this item got more valuable than it was when written.
public enum PaletteGroup: String, CaseIterable, Sendable {
    case places = "Places"
    case people = "People"
    case folders = "Folders"
    case sources = "Sources"
    case actions = "Actions"
    /// The Settings tabs. **Last, and it is the tie-break only** — a group's position is decided
    /// by its own best row (see ``PaletteRouter/sorted(_:)``), so an exact hit on "Appearance"
    /// still opens the list. What this rank settles is where Settings sits among groups that
    /// scored the *same*, and there it belongs behind the places and the files: a query that
    /// answers both a folder and a preferences page nearly always means the folder.
    ///
    /// **That tie is real and measured, not a theoretical one.** A folder named `People` scores 400
    /// against Settings ▸ People's 396 and wins on score alone; the same folder five levels deep
    /// takes a depth penalty to exactly 396 and is separated *only* by this rank. So moving this
    /// case earlier in `allCases` would put a preferences page above the folder somebody was
    /// looking for — `aFolderNamedLikeATabKeepsItsLead` is what fails if it moves.
    case settings = "Settings"

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
    /// Where this source lives, tilde-expanded. **Only Go to Folder reads it**, to decide which
    /// source a typed path is inside — the rest of the palette never names a source by its path,
    /// which is why this arrived late rather than being here from the start.
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
/// Injected rather than known, for the reason ``PaletteRoute/settings(tab:)`` records: the tabs
/// live in the `Settings` package, which this one does not depend on. `MacApp` maps
/// `SettingsTabDigest` onto this — a one-line `map` whose only failure mode (mapping a subset) is
/// what `SyncCloudTests` pins.
public struct PaletteSettingsTab: Equatable, Sendable {
    /// `SettingsTab.rawValue`, carried into the route unchanged.
    public let id: String
    /// The rail's name for the tab — "Appearance", "Sources".
    public let name: String
    /// One line saying what is on it, drawn as the row's second line.
    public let detail: String
    public let symbol: String

    /// Every word that should reach this tab: the titles and keywords of the controls on it.
    ///
    /// **It is a whole tab's worth of vocabulary behind ONE row**, and that is the design. The
    /// alternative was a row per control — 53 of them — which put four rows on screen that all
    /// open the same page and still could not scroll to the control, because the Settings sheet
    /// lands on a tab and not on a row. Folding the words in keeps `glass` and `sk-ant` and
    /// `node_modules` answerable while the list stays at ten.
    ///
    /// It is why a Settings row is often matched by text it does not display. That is what
    /// ``detail`` is for: the row cannot bold what is not in it, so it says what is on the tab.
    public let vocabulary: [String]

    public init(id: String, name: String, detail: String, symbol: String, vocabulary: [String]) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.vocabulary = vocabulary
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

    /// Why no folder under this source can be reached right now, or nil.
    ///
    /// Set when the provider **root** did not answer — an external drive asleep, a network mount
    /// down. That takes out every recent and every pin at once, and the empty-query landing IS that
    /// list, so dropping them silently makes ⌘K open blank and "I have no recents"
    /// indistinguishable from "my drive is not awake". The rows are kept and marked instead, which
    /// is what this palette already does for an unmounted source.
    ///
    /// **It marks every folder row, not only the remembered ones.** `folders` comes from the survey
    /// profile held in memory, which answers a typed query whether or not the disk is awake — so
    /// scoping this to recents and pins meant ⌘K opened saying "Not available" and then, the moment
    /// anything was typed, offered the same tree as live destinations. One root, one answer.
    public var foldersUnavailable: String?
    /// This user's home directory, for expanding a typed `~`. Carried on the index rather than read
    /// from `NSHomeDirectory()` inside the rule, so a test can resolve `~` against a fixture.
    public var home: String
    public var people: [Person]
    /// The registry, when there is one. Person routing is phrase-first and longest-wins; the
    /// palette must not hand-roll a second matcher (see ``PaletteRouter/personRow(for:index:)``).
    public var registry: PersonRegistry?
    /// True while a scan is running — the one thing that makes Rescan unavailable rather than absent.
    public var isScanning: Bool
    /// Whether a document survey exists for a person gather to read. Without one the offer is a
    /// button that does nothing, which is what the gather's own failure path had to be taught to say.
    public var hasSurvey: Bool
    /// The Settings tabs, in the rail's order. Empty offers no Settings rows at all, which is what
    /// every fixture that predates them gets — so a test written for the folder rules is not made
    /// to reason about a preferences page it never mentioned.
    public var settingsTabs: [PaletteSettingsTab]

    public init(providers: [PaletteProvider] = [], providerRoot: String? = nil,
                folders: [String] = [], recentFolders: [String] = [],
                pinnedFolders: [String] = [], foldersUnavailable: String? = nil,
                home: String = NSHomeDirectory(),
                people: [Person] = [],
                registry: PersonRegistry? = nil, isScanning: Bool = false,
                hasSurvey: Bool = false,
                settingsTabs: [PaletteSettingsTab] = []) {
        self.providers = providers
        self.providerRoot = providerRoot
        self.folders = folders
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

    /// The folder list for a survey profile, **or empty when that profile is about a different
    /// tree**.
    ///
    /// Extracted and pure because the host got it wrong in a way only the installed app showed:
    /// it compared `FolderProfile.root` against the provider root *unexpanded*, and the profile
    /// stores `~/Documents` while the provider root is expanded — so on the real tree the palette
    /// logged "25 rows from **0 folders**" with 3,013 folders surveyed, and every folder query and
    /// the whole "organize <folder>" lede silently answered nothing. Neither the routing tests (which
    /// are handed folders) nor the render tests could see it; the app's own log line did.
    ///
    /// **Containment, and the keys are re-based onto the provider root.** The keys are relative to
    /// the profile's root, and every path in the index it joins — recents, pins, typed paths — is
    /// relative to the *provider* root. Those were the same folder until a source gained a root
    /// above its documents tree; now a profile is surveyed over the source's ANCHOR, which sits
    /// inside the root, so the two bases differ by exactly the source's `openAt` and the keys have
    /// to carry it.
    ///
    /// Getting this wrong is silent, and has been once: comparing the two roots unexpanded made the
    /// palette log "25 rows from **0 folders**" with 3,013 folders surveyed, and every folder query
    /// and the whole "organize &lt;folder&gt;" lede answered nothing. An equality test would fail
    /// exactly that way again the moment a root widened, which is why this is containment — and why
    /// the re-basing happens here rather than at the call site, where a second copy of the rule
    /// could drift from the one the routes are built against.
    ///
    /// A profile rooted OUTSIDE the provider root still yields nothing: its keys name paths that do
    /// not exist under this source, and a folder that cannot be named is not a destination.
    static func folders(profileRoot: String?, providerRoot: String, keys: [String]) -> [String] {
        let profile = (profileRoot as NSString?)?.expandingTildeInPath ?? ""
        let provider = (providerRoot as NSString).expandingTildeInPath
        guard !profile.isEmpty, !provider.isEmpty,
              let prefix = PathBoundary.relativize(profile, under: provider) else { return [] }
        // `.` is the profile root itself, which is where the rail already opens — not a destination.
        return keys.filter { !$0.isEmpty && $0 != "." }
            .map { PathBoundary.joinRelative(prefix, $0) }
    }
}

// MARK: - Places

/// A destination in the app's own vocabulary: the three other workspaces, and Organize's rail.
///
/// Spelled out rather than derived from `Workspace`, which lives in `MacApp` — a target that is in
/// **no SPM package**, so a routing table written there is reachable by no `swift test`. That is not
/// a workaround: the palette's whole risk is a routing table that is wrong in a way nobody can see,
/// and the host's job is reduced to mapping these four cases onto its own selection type.
enum PalettePlace: CaseIterable {
    case browse
    case compare
    case storage
    case organizeOverview
    case lens(OrganizeLens)

    /// Hand-written, because the associated-value case rules out the synthesized conformance —
    /// which makes this the one place a new case can be added to the enum and silently never
    /// offered. `CommandPaletteTests.everyPlaceIsOfferedByTheHandWrittenAllCases` counts what this
    /// list produces against what the type can build, for exactly that reason.
    static var allCases: [PalettePlace] {
        [.browse, .compare, .organizeOverview]
            // `railItems`, not `allCases`: the folded Names lens is not a place any more, and
            // offering "Organize ▸ Names" beside "Organize ▸ Renames" was two rows for one
            // landing. Its search vocabulary lives on the Renames place now.
            + OrganizeLens.railItems.map(PalettePlace.lens) + [.storage]
    }

    var title: String {
        switch self {
        case .browse: return "Browse"
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
        // "files" and "finder" are the words someone reaches for when they want to go and look
        // at their files rather than have the app tell them something about them — which is the
        // whole distinction Browse exists to carry.
        case .browse: return ["browse", "files", "finder", "folders", "move", "look"]
        case .compare: return ["diff", "differences", "sync", "compare"]
        case .storage: return ["space", "disk", "size", "storage"]
        case .organizeOverview: return ["organize", "tidy", "all"]
        case .lens(.toFile): return ["organize", "file", "filing", "loose", "inbox", "to file"]
        case .lens(.duplicates): return ["organize", "duplicates", "dupes", "copies", "identical"]
        case .lens(.renames): return ["organize", "renames", "rename", "numbering", "backlog",
                                      "folders", "names", "risky", "illegal", "characters"]
        case .lens(.restructure): return ["organize", "restructure", "structure", "shape", "habits"]
        case .lens(.rules): return ["organize", "rules", "automations", "automatic", "learned"]
        }
    }

    var symbol: String {
        switch self {
        case .browse: return "folder"
        case .compare: return "arrow.left.arrow.right"
        case .storage: return "chart.pie"
        case .organizeOverview: return "folder.badge.gearshape"
        case .lens(let lens): return lens.symbol
        }
    }

    var detail: String {
        switch self {
        case .browse: return "Your files, with nothing proposed"
        case .compare: return "Two trees, side by side"
        case .storage: return "What is using the space"
        case .organizeOverview: return "Every lens's answer, on one page"
        case .lens(let lens): return lens.help(state: .configuration)
        }
    }

    var id: String {
        switch self {
        case .browse: return "place.browse"
        case .compare: return "place.compare"
        case .storage: return "place.storage"
        case .organizeOverview: return "place.organize"
        case .lens(let lens): return "place.organize.\(lens.rawValue)"
        }
    }

    /// This place, optionally re-aimed at a folder. Only Organize can carry a scope: Compare has
    /// two trees, Storage analyses whatever the pane is on, and Browse has no *subject* to re-aim
    /// — it shows wherever the pane already is, and the existing `.folder` route is how the
    /// palette moves the pane there.
    func route(scope: String?) -> PaletteRoute {
        switch self {
        case .browse: return .browse
        case .compare: return .compare
        case .storage: return .storage
        case .organizeOverview: return .organize(lens: nil, scope: scope)
        case .lens(let lens): return .organize(lens: lens, scope: scope)
        }
    }

    /// Whether "<this place> <a folder>" is a request that can be honoured.
    var takesAFolder: Bool {
        switch self {
        case .browse, .compare, .storage: return false
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
    /// - Parameter probe: what is at a typed path, for **Go to Folder**. `nil` means the caller
    ///   cannot answer that — no path row is offered rather than one being offered on faith. It is
    ///   injected because this is the only thing in the whole router that touches the disk, and it
    ///   runs on the keystroke path: `PalettePath` says what bounds it, and
    ///   `theHostGivesTheRouterARealPathProbe` is what stops the app quietly passing `nil`.
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

    /// Best first, **and each group in one run.**
    ///
    /// Groups are ordered by their own best row, then every row of that group follows before the
    /// next group starts; within a group it is score, then title, so the list is fully
    /// deterministic — a palette whose rows shuffled between identical queries would be unusable.
    ///
    /// **A flat score sort is what this replaces, and it was wrong in a way only a render could
    /// show.** `PaletteResultsList` emits a header wherever the group changes, so a flat sort put
    /// the same header on screen several times: measured over the fixture, `"s"` produced *Places,
    /// Actions, Sources, Actions, Places, Actions, Folders* — five groups in seven headings. It is
    /// not a rare tie either; nearly every one- and two-letter query did it, because a group's rows
    /// are spread across the whole score range and the group rank was only a tie-break.
    ///
    /// Ordering by the group's best row keeps what the flat sort was for: whatever matched best is
    /// still the first row on screen, and `PaletteSelection` still walks the array, so ↑/↓ still
    /// move the way the eye does. What changes is that the rest of that group comes with it.
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
                // **The third builder that names a path under the root, and the one the first fix
                // for this missed.** `scope` is a folder under `providerRoot` exactly as
                // `folderRows`' path is, so a root that did not answer cannot deliver it either:
                // running it writes an Organize scope for a folder that is not there, moves the
                // workspace, and reveals nothing. Marked here for the same reason and with the same
                // string. `everyPathBearingRouteIsRefusedWhenTheRootIsAsleep` walks all three.
                unavailable: index.foldersUnavailable,
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

    // MARK: Go to Folder — a typed path

    /// The one row a typed path produces, or nil when the query is not a path at all.
    ///
    /// **Always exactly one row, and often a refusal.** The user has said precisely where they mean,
    /// so there is nothing to rank — and the cases where the palette cannot take them there are the
    /// point of the feature rather than an edge of it: a path that resolves to nothing, or to a
    /// folder outside every source, is a question this surface can answer, and answering it is
    /// strictly better than the empty list a path query used to produce.
    ///
    /// The order of the checks is `PalettePath`'s stall guard — everything answerable from the
    /// index first, the disk last and only inside the aimed source, once that source has answered.
    ///
    /// **The route on a refusal is not a destination.** It is the typed path, because a refusal is
    /// reached before anything knows whether that path names a folder, a file, or nothing at all —
    /// `PaletteSelection.chosen` is what stops it being run, the same way it stops an unmounted
    /// source's row. Read `unavailable` before reading `route` on any row from here.
    static func pathRow(query: String, index: PaletteIndex,
                        probe: PalettePathProbe?) -> PaletteRow? {
        guard PalettePath.looksLikeAPath(query), let probe else { return nil }
        let typed = PalettePath.absolute(query, home: index.home)
        // Refusals first, each stated without the disk being asked. `id` is the typed path rather
        // than the destination, so a refusal and the row it becomes once the path is fixed are the
        // same row rather than two — the highlight does not jump as you type.
        // **The reasons are sized against the 320pt floor, and that was rendered rather than
        // guessed.** `PaletteResultsList` draws the reason `.fixedSize()`, so it never truncates and
        // always wins its row: measured 2026-08-19 at 320pt, the longest of these ("In Dropbox —
        // switch source first", 32 characters) leaves the title intact and squeezes the path detail
        // to `/Us…Legal`, and a long title degrades to `Some Very…` with the reason still whole.
        // That is the right way round for a refusal — the reason is what the row is *for*, and the
        // path is still sitting in the field above it — but a reason much longer than this one
        // starts eating the folder name, which is the half that says WHICH folder was refused.
        // `unknown` marks the one refusal that is a claim about *existence*. The other three are
        // refusals about reachability — the folder is very probably there, in a source that is not
        // mounted or not the one on screen — and badging those with a question mark says the app
        // does not know whether the folder exists, which is a different and wronger thing to say.
        func refusal(_ reason: String, unknown: Bool = false) -> PaletteRow {
            PaletteRow(id: "path.\(typed)", group: .folders, title: leaf(typed), detail: typed,
                       symbol: unknown ? "folder.badge.questionmark" : "folder",
                       route: .folder(path: typed),
                       unavailable: reason, score: pathRowScore)
        }
        // **Deliverable is decided against `providerRoot`, which is the root the reveal will
        // actually relativize against** — not against the owning provider's `isCurrent` flag.
        //
        // **Nested sources are what make those two different, and they are ordinary.** `~/Documents`
        // and `~/Documents/Clients` are both perfectly reasonable things to configure, and
        // `PalettePath.owner` deliberately answers with the innermost — it has to, or a path deep
        // inside the inner one would be handed to the outer. So with the pane aimed at `~/Documents`
        // and a path typed inside `Clients`, the owner is a provider that is NOT current, and the
        // old check refused a folder the pane on screen can show perfectly well ("In Clients —
        // switch source first"). Two sources pointed at the same folder do the same thing, which
        // `SettingsManager` allows for a re-pointed account.
        //
        // Asking `providerRoot` cannot drift from the route, because it *is* the value the route is
        // applied with. (An earlier version of this comment blamed the `enabledProviders` /
        // `availableProviders` split instead — disable the source a pane is showing, the reasoning
        // went, and it leaves the list while the pane keeps it. **That is not reachable**:
        // `onChange(of: settings.enabledProviders)` re-points any pane whose provider was switched
        // off. It survives only in the corner where `enabledProviders` goes *empty* — every
        // discovered source disabled, which `canDisable` refuses to do but a source disappearing
        // afterwards can still produce — where `resolvedProviderSelection` returns nil and the panes
        // keep their ids. Reachable, but not the case worth naming.)
        guard PathBoundary.contains(typed, under: index.providerRoot ?? "") else {
            guard let owner = PalettePath.owner(of: typed, in: index.providers) else {
                // The commonest refusal by far, and the one worth being plain about: this palette
                // can only show folders inside a source, because a pane IS a source.
                return refusal("Not in any source")
            }
            guard owner.isMounted else { return refusal("\(owner.name) is not mounted") }
            // Decided 2026-08-19: refuse and name the source rather than switching to it.
            // Switching means suppressing the provider change's own navigation reset (the counter
            // `adoptProviderForTab` arms) and driving the reload, or the pane lands at the root
            // with the folder silently dropped. Deferred to v4.3 — ROADMAP_V4 §3.
            return refusal("In \(owner.name) — switch source first")
        }
        // **The aimed root itself did not answer.** Every remembered folder is already marked with
        // this exact reason (`foldersUnavailable`), so a typed path under the same root says the
        // same thing — and probing a child of a root that did not answer is precisely the stall
        // this whole ordering exists to avoid.
        if let asleep = index.foldersUnavailable { return refusal(asleep) }
        switch probe(typed) {
        case .missing:
            return refusal("No folder at that path", unknown: true)
        case .directory:
            return PaletteRow(id: "path.\(typed)", group: .folders, title: leaf(typed),
                              detail: typed, symbol: "folder", route: .folder(path: typed),
                              score: pathRowScore)
        case .file:
            // A pasted path is usually a file's — that is what a Finder copy puts on the clipboard.
            // Its enclosing folder is the destination, the way ⇧⌘G accepts a file, and the row says
            // so rather than silently going somewhere the user did not type.
            let parent = (typed as NSString).deletingLastPathComponent
            return PaletteRow(id: "path.\(typed)", group: .folders, title: leaf(parent),
                              detail: "Enclosing folder of \(leaf(typed))", symbol: "folder",
                              route: .folder(path: parent), score: pathRowScore)
        }
    }

    /// Above every other folder row. A typed path is the most specific claim a query can make —
    /// nothing was inferred from it — so it leads, and `initialIndex` puts ↩ on it.
    static let pathRowScore = 1_100

    static func folderRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        guard let root = index.providerRoot, !root.isEmpty else { return [] }
        return rankedFolders(matching: query, in: index).prefix(6).map { folder in
            PaletteRow(id: "folder.\(folder.path)", group: .folders,
                       title: leaf(folder.path), detail: folder.path,
                       symbol: "folder",
                       route: .folder(path: (root as NSString).appendingPathComponent(folder.path)),
                       // **The same mark the landing carries, for the same root.** These come from
                       // the survey profile in memory, so they answer a query perfectly well with
                       // the drive asleep — and offering them as live while the empty-query landing
                       // says "Not available" is one surface making two claims about one disk.
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
                   // ROADMAP 14 names this case specifically: an unmounted source is shown
                   // disabled WITH ITS REASON, not hidden. Hiding it teaches that the palette does
                   // not know about the drive; this answers the question that was asked.
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

    /// One row per Settings tab, matched on its **name and its whole vocabulary**.
    ///
    /// Two candidates rather than one, and the second is penalised:
    ///
    /// - the row's own **title** and the tab **name**, at full score. `"Settings ▸ Appearance"`
    ///   carries the prefix, which is what makes typing `settings` list every tab — the same shape
    ///   `organize` already has, where the overview and all six lenses answer the parent word.
    /// - every word in ``PaletteSettingsTab/vocabulary``, at `score - 20`, the same penalty
    ///   ``rankedFolders(matching:in:)`` puts on a path match under a leaf match.
    ///
    /// **The penalty is load-bearing, and the case that shows it is real.** Readability's
    /// "Size & spacing" deliberately keeps the keyword `appearance`, because the tab moved out of
    /// Appearance and people still look for it there. Without the penalty the query `appearance`
    /// scores Readability's keyword hit at whatever tier it lands on and Appearance's own name at
    /// `.exact`, and they are only ordered correctly by luck; with it, a vocabulary hit can never
    /// reach the tier above it — 20 exceeds the largest position decrement below, and the tiers
    /// are 100 apart.
    ///
    /// The decrement itself keeps the **rail's order** among tabs that matched equally well, which
    /// is what `settings` produces: ten rows all matched by the same prefix, listed as the rail
    /// lists them rather than alphabetically. `index.settingsTabs` arrives in rail order and this
    /// is the only thing that preserves it.
    ///
    /// Cost, measured against a 3013-folder index — his real tree: `rows` already takes ~16ms and
    /// this adds ~1.1ms of it (+7%), for ~370 vocabulary words. Recorded rather than optimised,
    /// because the 93% is where the time is; `rows` is read twice per keystroke, so the figure to
    /// hold against a future change to either is ~34ms per keystroke, not ~17.
    static func settingsRows(query: String, index: PaletteIndex) -> [PaletteRow] {
        index.settingsTabs.enumerated().compactMap { offset, tab in
            let title = settingsTitle(tab)
            let named = best(of: [title, tab.name], query: query)
            let spoken = best(of: tab.vocabulary, query: query)
            let combined = Swift.max(score(named), score(spoken) - vocabularyPenalty)
            guard combined > 0 else { return nil }
            return PaletteRow(id: "settings.\(tab.id)", group: .settings, title: title,
                              detail: tab.detail, symbol: tab.symbol,
                              route: .settings(tab: tab.id),
                              score: combined - Swift.min(offset, maxPositionDecrement))
        }
    }

    /// How far a vocabulary match scores below a name match. The same shape
    /// ``rankedFolders(matching:in:)`` uses for a path match under a leaf match.
    static let vocabularyPenalty = 20

    /// The largest position decrement a Settings row may take, and it is **derived from the
    /// penalty rather than picked**.
    ///
    /// The ordering above only holds while every decrement is strictly smaller than the smallest
    /// gap between two distinct outcomes. Those outcomes are the four tiers at full score
    /// (100/200/300/400) and the same four penalised (80/180/280/380), so the smallest gap is
    /// `vocabularyPenalty` itself — 380 against 400 — and a decrement of `penalty - 1` is the
    /// largest that cannot cross it.
    ///
    /// **Clamped rather than asserted.** Ten tabs are comfortably inside it today and the comment
    /// above said so, which is exactly the kind of invariant that is true until a release adds an
    /// eleventh, and a twenty-first, and nothing fails — the rows would simply start outranking
    /// each other by where they sit in the rail. Past the clamp, tabs tie and fall back to the
    /// title, which is a worse order but never a wrong one.
    static let maxPositionDecrement = vocabularyPenalty - 1

    /// `"Settings ▸ Appearance"` — the same separator `PalettePlace` draws for Organize's lenses,
    /// because a Settings tab is a page inside a thing exactly as a lens is, and two spellings for
    /// one relationship would say they were different.
    ///
    /// **The prefix restates the group header, and it stays anyway.** Under a `SETTINGS` heading a
    /// row reading "Settings ▸ Appearance" says Settings twice, and at the 320pt floor those eleven
    /// characters are about a quarter of the ~215pt the text is given — a real cost, and the reason
    /// dropping them was considered. What decides it is that **the header scrolls away and the row
    /// does not**: `GoToResultsPanel.listMaxHeight` is 420pt against a two-line row of ~44pt, so
    /// nine rows are visible and the ten tabs do not fit under their own heading. A row left reading
    /// only "Appearance", scrolled past its header, is indistinguishable from a folder of that name.
    /// `PalettePlace` prefixes its lenses for the same reason, and there the header is `Places`, so
    /// the redundancy here is the price of a row that names its own destination rather than an
    /// oversight.
    static func settingsTitle(_ tab: PaletteSettingsTab) -> String { "Settings ▸ \(tab.name)" }

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
                    // Kept and marked rather than dropped when the root is asleep — see
                    // `foldersUnavailable`. ↑↓ skip these and ↩ refuses them, so a row that
                    // cannot deliver is never run.
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
        // **The Settings tabs are deliberately NOT here.** They would be ten more rows on a
        // landing whose whole job is "where you have been, then where you can go" — nearly
        // doubling it, and pushing the recents that lead it off the opening. `Settings…` is
        // already in the actions above and is the honest empty-query answer: somebody who has not
        // typed anything has not named a tab. They appear the moment a query does.
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

    /// The range `match` decided by — the same lookup with the same options, exposed so the row
    /// can emphasize exactly what matched. **This is the one matcher**: a second tokenizer for
    /// display would disagree with the ranking in precisely the cases that matter (case folds,
    /// diacritics), which is the known two-tokenizers failure mode.
    ///
    /// nil when the string does not contain the query — a row matched through its keywords or a
    /// verb parse draws no emphasis, which is honest: the visible text did not match.
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
