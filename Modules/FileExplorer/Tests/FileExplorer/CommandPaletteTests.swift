import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// The ⌘K palette's routing table.
///
/// A routing decision inside an `onSubmit` can't be fired from a unit test, so `PaletteRouter` is a
/// pure function returning a value, the pattern `PaneSearchSubmit` follows. Every test asserts a
/// route, not a row's existence: a palette that lists the right destination and routes it
/// somewhere else is the failure that matters.
@Suite struct CommandPaletteTests {

    // MARK: Fixtures — the real tree's shapes, cut to size

    static let root = "/Users/x/Documents"

    static var people: [Person] {
        [Person(id: "p.daughter", displayName: "Daughter", relationship: "daughter",
                fullNames: ["Daughter Elder"], aliases: []),
         Person(id: "p.elder", displayName: "Elder", relationship: "father",
                fullNames: ["Elder Forebear"], aliases: ["Dad"]),
         Person(id: "p.granny", displayName: "Granny", relationship: "mother",
                fullNames: ["Granny Elder"], aliases: ["Mom"])]
    }

    static func index(folders: [String] = ["Finance", "Finance/US", "Finance/US/Income Tax",
                                           "Legal", "Medical", "Archive/2019/Legal"],
                      recent: [String] = [],
                      providers: [PaletteProvider] = [
                          PaletteProvider(id: "icloud", name: "iCloud", isMounted: true, isCurrent: true),
                          PaletteProvider(id: "ssd", name: "Backup SSD", isMounted: false, isCurrent: false)],
                      isScanning: Bool = false,
                      hasSurvey: Bool = true,
                      hasRegistry: Bool = true) -> PaletteIndex {
        PaletteIndex(providers: providers, providerRoot: root, folders: folders,
                     recentFolders: recent, people: hasRegistry ? people : [],
                     registry: hasRegistry ? PersonRegistry(people: people) : nil,
                     isScanning: isScanning, hasSurvey: hasSurvey)
    }

    // MARK: A root that is merely asleep

    /// Under a sleeping root, remembered folders are listed, marked and unrunnable, not dropped.
    /// The root is checked first, so a sleeping drive takes out every recent and pin at once;
    /// dropping them would make "no recents" look the same as "drive not awake". A remembered
    /// folder that has gone is hidden only when the root answered.
    @Test func anAsleepRootListsItsRememberedFoldersMarkedRatherThanHidingThem() throws {
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true, isCurrent: true)],
            providerRoot: Self.root, folders: [],
            recentFolders: ["Legal", "Finance/US"], pinnedFolders: ["Archive/2019/Legal"],
            foldersUnavailable: "Not available",
            people: [], registry: nil, isScanning: false, hasSurvey: true)
        let rows = PaletteRouter.rows(query: "", index: index)
        let folders = rows.filter { $0.group == .folders }

        #expect(folders.count == 3, "a sleeping drive cost the user their remembered folders entirely")
        #expect(folders.allSatisfy { $0.unavailable == "Not available" },
                "the rows are offered as if they could be delivered")
        // Marked is only half of it: the palette must also refuse to RUN one.
        #expect(PaletteSelection.chosen(at: rows.firstIndex(where: { $0.group == .folders }), in: rows) == nil,
                "↩ on an unreachable folder still tries to go there")
        // …and the opening highlight must skip past them to something that works.
        let opening = try #require(PaletteSelection.initialIndex(in: rows))
        #expect(rows[opening].isAvailable, "the palette opens with ↩ aimed at a row it cannot run")
        #expect(rows[opening].group != .folders)
    }

    /// A typed query under a sleeping root marks its folders too. `folders` comes from the survey
    /// profile in memory, so it matches with the drive asleep; without the mark, typing one letter
    /// would offer the tree as live destinations and ↩ would reveal a path that isn't there.
    @Test func aTypedQueryUnderAnAsleepRootMarksItsFoldersToo() {
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true, isCurrent: true)],
            providerRoot: Self.root, folders: ["Legal", "Archive/2019/Legal"],
            recentFolders: [], pinnedFolders: [],
            foldersUnavailable: "Not available",
            people: [], registry: nil, isScanning: false, hasSurvey: true)
        let rows = PaletteRouter.rows(query: "legal", index: index)
        let folders = rows.filter { $0.group == .folders }

        #expect(folders.count == 2, "the fixture matched no folders — it cannot detect the mark going missing")
        #expect(folders.allSatisfy { $0.unavailable == "Not available" },
                "a typed query offers folders on a sleeping drive as live destinations while the landing says they are not there")
        // And ↩ must refuse them, which is what the mark buys beyond the wording.
        for (offset, row) in rows.enumerated() where row.group == .folders {
            #expect(PaletteSelection.chosen(at: offset, in: rows) == nil,
                    "↩ on \(row.title) still tries to reveal a path under a root that did not answer")
        }
    }

    /// The awake half of the same query, so the assertion above is not just "unavailable is
    /// whatever we passed".
    @Test func aTypedQueryUnderAWakeRootStillOffersItsFolders() {
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true, isCurrent: true)],
            providerRoot: Self.root, folders: ["Legal", "Archive/2019/Legal"],
            recentFolders: [], pinnedFolders: [],
            foldersUnavailable: nil,
            people: [], registry: nil, isScanning: false, hasSurvey: true)
        let folders = PaletteRouter.rows(query: "legal", index: index).filter { $0.group == .folders }
        #expect(folders.count == 2)
        #expect(folders.allSatisfy { $0.isAvailable })
    }

    /// The other side, so the assertion above is not just "unavailable is whatever we passed":
    /// with the root awake the very same folders are live rows.
    @Test func aWakeRootListsTheSameFoldersAsRunnable() {
        let index = PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true, isCurrent: true)],
            providerRoot: Self.root, folders: [],
            recentFolders: ["Legal", "Finance/US"], pinnedFolders: ["Archive/2019/Legal"],
            foldersUnavailable: nil,
            people: [], registry: nil, isScanning: false, hasSurvey: true)
        let folders = PaletteRouter.rows(query: "", index: index).filter { $0.group == .folders }
        #expect(folders.count == 3)
        #expect(folders.allSatisfy { $0.isAvailable })
    }

    static func routes(_ query: String, _ index: PaletteIndex? = nil) -> [PaletteRoute] {
        PaletteRouter.rows(query: query, index: index ?? Self.index()).map(\.route)
    }

    static func first(_ query: String, _ index: PaletteIndex? = nil) -> PaletteRoute? {
        PaletteRouter.rows(query: query, index: index ?? Self.index()).first?.route
    }

    // MARK: The lede — free-text routing

    /// A query that is a verb and an object routes to both, in one row: the property that makes
    /// the palette worth having.
    @Test func organizeIncomeTaxAimsOrganizeAtThatFolder() {
        let top = try? #require(Self.first("organize income tax"))
        #expect(top == .organize(lens: nil, scope: "\(Self.root)/Finance/US/Income Tax"),
                "the top row for a verb-and-object query was \(String(describing: top))")
    }

    /// The object must not be dropped: routing to Organize alone would land you there still
    /// answering about wherever you were, with nothing on screen saying so.
    @Test func theFolderHalfOfAVerbQueryIsNeverDiscarded() {
        let rows = PaletteRouter.rows(query: "organize income tax", index: Self.index())
        let scoped = rows.filter {
            if case .organize(_, let scope) = $0.route { return scope != nil } else { return false }
        }
        #expect(!scoped.isEmpty, "no row carried the folder — the object was dropped")
        // And it outranks the bare place row, which is also in the results and answers half.
        let bareIndex = rows.firstIndex { $0.route == .organize(lens: nil, scope: nil) }
        let scopedIndex = rows.firstIndex { if case .organize(_, .some) = $0.route { return true } else { return false } }
        if let bareIndex, let scopedIndex {
            #expect(scopedIndex < bareIndex,
                    "the row that answers half the query is ranked above the one that answers all of it")
        }
    }

    /// A lens name is a verb too, and takes a folder like Organize does.
    @Test func aLensNameAndAFolderRouteToThatLensScoped() {
        #expect(Self.first("duplicates in Legal")
                == .organize(lens: .duplicates, scope: "\(Self.root)/Legal"))
        // The connective is dropped only between the halves, so this is the same request.
        #expect(Self.first("duplicates Legal")
                == .organize(lens: .duplicates, scope: "\(Self.root)/Legal"))
    }

    /// "rename" reaches Renames, the place that fixes names, even though nothing is called
    /// "rename". Names folded into Renames as its "to fix" section, and its vocabulary moved too.
    @Test func renameReachesTheNamesLensEvenThoughNothingIsCalledRename() {
        #expect(Self.routes("rename").contains(.organize(lens: .renames, scope: nil)))
        // The folded lens's words reach the same landing, so no muscle memory dead-ends.
        #expect(Self.routes("risky").contains(.organize(lens: .renames, scope: nil)))
        #expect(Self.routes("illegal").contains(.organize(lens: .renames, scope: nil)))
        // And "names" reaches exactly one place, not a second row for the same landing.
        #expect(Self.routes("names").filter { route in
            if case .organize = route { return true } else { return false }
        }.count == 1)
    }

    /// A place whose name is two words is found, object and all; a single-word parse loses this
    /// query. It doesn't prove longest-first order: no two-word name's head is also a name, so the
    /// direction is unobservable (noted at `splitVerb`).
    @Test func aTwoWordPlaceNameIsFoundBeforeItsFirstWordCanMisfire() {
        #expect(Self.first("to file legal")
                == .organize(lens: .toFile, scope: "\(Self.root)/Legal"))
    }

    @Test func aVerbWithNoObjectIsJustThePlace() {
        // "storage" reaches the Storage lens, which carries a scope like every other lens; the
        // unscoped query lands on the same page.
        #expect(Self.first("storage") == .organize(lens: .storage, scope: nil))
        #expect(Self.first("compare") == .compare)
    }

    /// Edit answers to what it does with a PDF: "pdf", "sign" and "fill" reach it, and its line
    /// under the name mentions PDFs, not just text files.
    @Test func editAnswersToItsPDFWords() {
        for query in ["pdf", "pdfs", "sign", "signature", "fill"] {
            let rows = PaletteRouter.rows(query: query, index: Self.index())
            #expect(rows.contains { $0.route == .editor }, "“\(query)” does not reach Edit")
        }
        #expect(PalettePlace.editor.detail == "Write in a text file, or fill and sign a PDF")
    }

    /// Storage, as a lens, takes a folder.
    @Test func storageTakesAFolderSinceItBecameALens() {
        #expect(Self.first("storage legal")
                == .organize(lens: .storage, scope: "\(Self.root)/Legal"),
                "\"storage <folder>\" no longer carries the folder — the derived lens place has lost its scope route")
    }

    /// A folder the tree does not have must not silently become the bare place — that would answer
    /// a question nobody asked while looking like it understood.
    @Test func aVerbWithAnUnknownObjectFallsBackToOrdinaryMatching() {
        let rows = PaletteRouter.rows(query: "organize kryptonite", index: Self.index())
        #expect(!rows.contains { if case .organize(_, .some) = $0.route { return true } else { return false } },
                "a folder that does not exist was invented as a scope")
    }

    // MARK: People — "daughter's files"

    @Test func aPossessiveQueryRoutesToThatPersonsGather() {
        #expect(Self.routes("daughter's files").contains(.person(id: "p.daughter")))
        #expect(Self.routes("daughter").contains(.person(id: "p.daughter")))
    }

    /// Exactly one person, or nobody. Delegated to `PersonSearchOffer` so the palette and the pane
    /// search can't answer differently. "elder forebear granny" names a couple, and picking one
    /// would over-attribute.
    @Test func aQueryNamingTwoPeopleOffersNeither() {
        let rows = PaletteRouter.rows(query: "elder forebear granny", index: Self.index())
        #expect(!rows.contains { if case .person = $0.route { return true } else { return false } })
    }

    /// A roster can outlive its survey. The row stays, disabled, and says why, rather than
    /// offering an accept that does nothing.
    @Test func aPersonRowWithNoSurveyIsShownDisabledWithItsReason() {
        let rows = PaletteRouter.rows(query: "daughter", index: Self.index(hasSurvey: false))
        let person = rows.first { if case .person = $0.route { return true } else { return false } }
        #expect(person != nil, "the person row was hidden rather than disabled")
        #expect(person?.isAvailable == false)
        #expect(person?.unavailable == "No document survey on this Mac yet")
    }

    // MARK: Availability is a REASON, never an absence

    /// An unmounted source is shown disabled with its reason, not hidden.
    @Test func anUnmountedSourceIsListedWithItsReason() {
        let rows = PaletteRouter.rows(query: "backup", index: Self.index())
        let ssd = rows.first { $0.route == .provider(id: "ssd") }
        #expect(ssd != nil, "the unmounted source was hidden — the palette looks like it does not know about it")
        #expect(ssd?.unavailable == "Not mounted")
    }

    @Test func rescanIsDisabledWithItsReasonWhileAScanRuns() {
        let running = PaletteRouter.rows(query: "rescan", index: Self.index(isScanning: true))
            .first { $0.route == .action(.rescan) }
        #expect(running?.unavailable == "A scan is already running")
        let idle = PaletteRouter.rows(query: "rescan", index: Self.index())
            .first { $0.route == .action(.rescan) }
        #expect(idle?.isAvailable == true, "Rescan is disabled while nothing is running")
    }

    // MARK: Ranking

    @Test func anExactTitleBeatsASubstringHit() {
        let rows = PaletteRouter.rows(query: "Legal", index: Self.index())
        let paths = rows.compactMap { row -> String? in
            if case .folder(let p) = row.route { return p } else { return nil }
        }
        #expect(paths.first == "\(Self.root)/Legal",
                "a deeper namesake outranked the folder the name means: \(paths)")
    }

    @Test func theOrderIsTotalSoTheSameQueryNeverShuffles() {
        let a = PaletteRouter.rows(query: "fin", index: Self.index()).map(\.id)
        let b = PaletteRouter.rows(query: "fin", index: Self.index()).map(\.id)
        #expect(a == b)
        // Not vacuous: the query really did produce a list to order.
        #expect(a.count > 2)
    }

    @Test func aDestinationIsNeverListedTwice() {
        // "organize" reaches the Organize place through the verb parse and the plain place match.
        let ids = PaletteRouter.rows(query: "organize legal", index: Self.index()).map(\.id)
        #expect(ids.count == Set(ids).count, "a destination appeared twice: \(ids)")
    }

    // MARK: The empty query

    /// The empty query offers recents, then places. Recents lead because the commonest reason to
    /// open a palette is to go back to where you just were.
    @Test func theEmptyQueryLeadsWithRecentsThenPlaces() {
        let rows = PaletteRouter.rows(query: "", index: Self.index(recent: ["Legal", "Medical"]))
        #expect(rows.first?.route == .folder(path: "\(Self.root)/Legal"))
        #expect(rows.dropFirst().first?.route == .folder(path: "\(Self.root)/Medical"))
        #expect(rows.contains { $0.route == .compare })
        #expect(rows.contains { $0.route == .organize(lens: .rules, scope: nil) })
    }

    @Test func theEmptyQueryWithNoHistoryStillOffersEveryPlace() {
        let rows = PaletteRouter.rows(query: "   ", index: Self.index())
        for place in [PaletteRoute.browse, .compare, .editor,
                      .organize(lens: nil, scope: nil)]
            + OrganizeLens.railItems.map({ PaletteRoute.organize(lens: $0, scope: nil) }) {
            #expect(rows.contains { $0.route == place }, "\(place) is unreachable from an empty query")
        }
    }

    /// ⌘K reaches Browse by name. A `PaletteRoute` case with no `PalettePlace` beside it compiles
    /// and routes correctly, but nothing ever emits a row carrying it.
    @Test func browseIsReachableByName() {
        #expect(Self.first("browse") == .browse)
    }

    /// The words for looking at files, rather than being told about them, reach Browse. "files"
    /// especially: it is the query for "I just want to go and move this".
    @Test func theWordsForLookingAtFilesReachBrowse() {
        for query in ["files", "finder", "folders"] {
            #expect(Self.routes(query).contains(.browse), "'\(query)' does not reach Browse")
        }
    }

    /// `PalettePlace.allCases` is hand-written (an associated-value case rules out synthesis), so a
    /// new place could be added and never offered. Every place the type can build must be in it.
    @Test func everyPlaceIsOfferedByTheHandWrittenAllCases() {
        let offered = Set(PalettePlace.allCases.map(\.id))
        // Storage arrives through `railItems`, which gives it a scope route.
        let expected = Set(([PalettePlace.browse, .compare, .editor, .organizeOverview]
                            + OrganizeLens.railItems.map(PalettePlace.lens)).map(\.id))
        #expect(offered == expected)
        // And the rows come from this list, so an entry that scores nothing is still unreachable.
        let rows = PaletteRouter.rows(query: "", index: Self.index())
        for place in PalettePlace.allCases {
            #expect(rows.contains { $0.route == place.route(scope: nil) },
                    "\(place.title) is in allCases but no empty-query row carries it")
        }
    }

    /// Browse takes no scope: it shows wherever the pane already is, and the `.folder` route moves
    /// the pane, so "browse income tax" must not become a second way of aiming a workspace.
    @Test func browseTakesNoFolder() {
        #expect(!PalettePlace.browse.takesAFolder)
        #expect(PalettePlace.browse.route(scope: "\(Self.root)/Finance") == .browse)
    }

    /// Whitespace is not a query. Without the trim, a stray space would drop the user from the
    /// recents-and-places landing into an empty result list.
    @Test func whitespaceIsTheEmptyQuery() {
        #expect(PaletteRouter.rows(query: "  \n ", index: Self.index()).map(\.id)
                == PaletteRouter.rows(query: "", index: Self.index()).map(\.id))
    }

    // MARK: Degenerate indexes

    @Test func noProviderRootMeansNoFolderRowsRatherThanBadPaths() {
        var index = Self.index()
        index.providerRoot = nil
        let rows = PaletteRouter.rows(query: "legal", index: index)
        #expect(!rows.contains { if case .folder = $0.route { return true } else { return false } },
                "a folder row was routed against a root that does not exist")
        // The places are still reachable — losing the root must not empty the palette.
        #expect(rows.contains { if case .organize = $0.route { return true } else { return false } }
                || PaletteRouter.rows(query: "compare", index: index).contains { $0.route == .compare })
    }

    @Test func noRegistryMeansNoPersonRowsAndNoCrash() {
        let rows = PaletteRouter.rows(query: "daughter", index: Self.index(hasRegistry: false))
        #expect(!rows.contains { if case .person = $0.route { return true } else { return false } })
    }

    // MARK: Pinned and recent are two different claims

    /// Pinned and recent are two lists because they are two claims, where you keep going back to
    /// and where you just were. A pinned folder labelled "Recent" would be wrong.
    @Test func theEmptyQueryLeadsWithPinnedThenRecentAndSaysWhichIsWhich() {
        var index = Self.index(recent: ["Medical"])
        index.pinnedFolders = ["Legal"]
        let rows = PaletteRouter.rows(query: "", index: index)
        let folders = rows.filter { $0.group == .folders }
        #expect(folders.map(\.route) == [.folder(path: "\(Self.root)/Legal"),
                                         .folder(path: "\(Self.root)/Medical")])
        #expect(folders.first?.detail?.hasPrefix("Favorite ") == true)
        #expect(folders.dropFirst().first?.detail?.hasPrefix("Recent ") == true)
    }

    // MARK: ↑ ↓ ↩

    /// The highlight opens on the first row that can be chosen, not row 0. Unavailable rows stay in
    /// the list, and opening on one would make ↩ do nothing, which reads as a broken palette.
    @Test func theHighlightSkipsRowsThatCannotBeChosen() {
        let rows = [PaletteRow(id: "a", group: .sources, title: "Backup SSD", symbol: "x",
                               route: .provider(id: "ssd"), unavailable: "Not mounted"),
                    PaletteRow(id: "b", group: .sources, title: "iCloud", symbol: "x",
                               route: .provider(id: "icloud"))]
        #expect(PaletteSelection.initialIndex(in: rows) == 1)
        #expect(PaletteSelection.chosen(at: 0, in: rows) == nil,
                "↩ on a disabled row ran its route anyway")
        #expect(PaletteSelection.chosen(at: 1, in: rows) == .provider(id: "icloud"))
    }

    @Test func arrowsWalkOnlyTheChoosableRowsAndWrap() {
        let rows = [PaletteRow(id: "a", group: .places, title: "A", symbol: "x", route: .compare),
                    PaletteRow(id: "b", group: .places, title: "B", symbol: "x", route: .browse,
                               unavailable: "Nope"),
                    PaletteRow(id: "c", group: .places, title: "C", symbol: "x",
                               route: .organize(lens: nil, scope: nil))]
        // ↓ from the first choosable row skips the disabled one entirely.
        #expect(PaletteSelection.moved(from: 0, by: 1, in: rows) == 2)
        // ...and wraps at the end rather than stopping dead.
        #expect(PaletteSelection.moved(from: 2, by: 1, in: rows) == 0)
        #expect(PaletteSelection.moved(from: 0, by: -1, in: rows) == 2)
    }

    @Test func arrowsOnAListWithNothingChoosableHighlightNothing() {
        let rows = [PaletteRow(id: "a", group: .sources, title: "A", symbol: "x",
                               route: .provider(id: "a"), unavailable: "Not mounted")]
        #expect(PaletteSelection.initialIndex(in: rows) == nil)
        #expect(PaletteSelection.moved(from: nil, by: 1, in: rows) == nil)
        #expect(PaletteSelection.chosen(at: nil, in: rows) == nil)
    }

    /// A leftover index names a different row now, so the host recomputes the selection on every
    /// keystroke. This pins the testable half: an index out of range runs nothing.
    @Test func aStaleIndexRunsNothing() {
        let rows = [PaletteRow(id: "a", group: .places, title: "A", symbol: "x", route: .compare)]
        #expect(PaletteSelection.chosen(at: 7, in: rows) == nil)
        #expect(PaletteSelection.chosen(at: -1, in: rows) == nil)
    }

    // MARK: The folder index — the defect the installed app found

    /// A tilde-spelled profile root (`~/Documents`) still matches an expanded provider root.
    /// Compared as plain strings, the palette would index no folders at all, and every folder query
    /// would answer nothing with no error. The routing tests can't see this: they are handed the
    /// folder list.
    @Test func aTildeSpelledProfileRootStillMatchesTheProviderRoot() {
        let home = NSHomeDirectory()
        #expect(PaletteIndex.folders(profileRoot: "~/Documents",
                                     providerRoot: "\(home)/Documents",
                                     keys: [".", "Legal", "Finance/US"]) == ["Legal", "Finance/US"])
        // ...and the other direction, since either side can be the tilde-spelled one.
        #expect(PaletteIndex.folders(profileRoot: "\(home)/Documents",
                                     providerRoot: "~/Documents",
                                     keys: ["Legal"]) == ["Legal"])
    }

    /// A profile about a tree outside the provider root contributes nothing. A profile rooted
    /// above it, or in another tree, yields keys relative to the wrong thing that no prefix repairs.
    @Test func aProfileAboutADifferentTreeContributesNoFolders() {
        #expect(PaletteIndex.folders(profileRoot: "/a/Documents", providerRoot: "/b/Documents",
                                     keys: ["Legal"]).isEmpty)
        // Above the provider root: its keys name paths that are not under this source at all.
        #expect(PaletteIndex.folders(profileRoot: "/a", providerRoot: "/a/Documents",
                                     keys: ["Legal"]).isEmpty)
        // A sibling that only shares a string prefix is outside: the `PathBoundary` rule, which a
        // `hasPrefix` re-implementation would get wrong.
        #expect(PaletteIndex.folders(profileRoot: "/a/Documentsly", providerRoot: "/a/Documents",
                                     keys: ["Legal"]).isEmpty)
        #expect(PaletteIndex.folders(profileRoot: nil, providerRoot: "/a", keys: ["Legal"]).isEmpty)
        #expect(PaletteIndex.folders(profileRoot: "/a", providerRoot: "", keys: ["Legal"]).isEmpty)
    }

    /// A profile rooted inside the provider root contributes its folders, re-based. This is the
    /// ordinary case: a cloud source's root is its account folder, and the profile is surveyed over
    /// the landing folder inside it, so the two differ by the source's `openAt`.
    ///
    /// Routes join the provider root to what this returns, so a key left unchanged would name
    /// `<account>/Legal` for `<account>/Documents/Legal`. Returning nothing instead would leave ⌘K's
    /// Folders group and the "organize &lt;folder&gt;" lede silently empty.
    @Test func aProfileInsideTheProviderRootContributesItsFoldersRebased() {
        #expect(PaletteIndex.folders(profileRoot: "/a/Documents", providerRoot: "/a",
                                     keys: [".", "Legal", "Finance/US"])
                == ["Documents/Legal", "Documents/Finance/US"])
        // Two levels down, which is Google Drive's shape (`My Drive/Documents`).
        #expect(PaletteIndex.folders(profileRoot: "/a/My Drive/Documents", providerRoot: "/a",
                                     keys: ["Legal"]) == ["My Drive/Documents/Legal"])
    }

    /// The index's `folderPrefix` is the segment its folders actually carry. The ranker subtracts
    /// it before scoring, which works only while it matches what `folders` prepended; a drift is
    /// silent, and every folder would score its whole path again (see the ranker tests below).
    ///
    /// Also pinned: `folderPrefix` is nil on exactly the inputs that make `folders` empty, so a
    /// `?? ""` at the call site means "no re-base", never "re-base of an unusable pair".
    @Test func theIndexedFoldersAllCarryTheIndexPrefix() {
        let cases: [(profile: String?, provider: String)] = [
            ("/a/Documents", "/a"),                 // OneDrive / Dropbox
            ("/a/My Drive/Documents", "/a"),        // Google Drive, two levels
            ("/a/Documents", "/a/Documents"),       // iCloud — the two are one folder, prefix ""
            ("/a/Documents", "/b/Documents"),       // a different tree — no folders, no prefix
            ("/a", "/a/Documents"),                 // above the root
            (nil, "/a"),
            ("/a", ""),
        ]
        for c in cases {
            let prefix = PaletteIndex.folderPrefix(profileRoot: c.profile, providerRoot: c.provider)
            let folders = PaletteIndex.folders(profileRoot: c.profile, providerRoot: c.provider,
                                               keys: [".", "Legal", "Finance/US"])
            guard let prefix else {
                #expect(folders.isEmpty, "no prefix, but \(c) still produced \(folders)")
                continue
            }
            #expect(!folders.isEmpty, "a prefix of \(prefix.debugDescription) produced no folders for \(c)")
            for folder in folders {
                // Whole-segment, not `hasPrefix` — the same boundary rule `below` is held to.
                #expect(PaletteRouter.below(prefix, folder) != folder || prefix.isEmpty,
                        "\(folder) does not sit under the index prefix \(prefix.debugDescription)")
            }
        }
    }

    // MARK: The folder ranker — scored below the landing folder

    /// A query that only matches the shared prefix ranks nothing. Every key begins `Documents`, and
    /// `rankedFolders` scores the path with slashes as spaces, so without the prefix off, `doc`
    /// would match every surveyed folder and the group would show arbitrary rows.
    ///
    /// Dropping the `below(index.folderPrefix, folder)` call must fail this: all four folders rank.
    @Test func aQueryMatchingOnlyTheSharedPrefixRanksNothing() {
        let index = PaletteIndex(
            providerRoot: "/a",
            folders: ["Documents/Legal", "Documents/Finance/US",
                      "Documents/Archive/Old Docs", "Documents/Receipts"],
            folderPrefix: "Documents")
        let ranked = PaletteRouter.rankedFolders(matching: "doc", in: index)
        #expect(ranked.map(\.path) == ["Documents/Archive/Old Docs"],
                "\"doc\" matched \(ranked.map(\.path)) — the shared prefix is being scored")
        // The prefix's own name is not a query at all.
        #expect(PaletteRouter.rankedFolders(matching: "documents", in: index).isEmpty)
        // ...and a real name still ranks, so the test above is not passing by matching nothing.
        #expect(PaletteRouter.rankedFolders(matching: "legal", in: index).map(\.path)
                == ["Documents/Legal"])
        // A multi-word path query still works below the prefix: `Finance/US` scores as
        // "Finance US", the reason the path half of the score exists.
        #expect(PaletteRouter.rankedFolders(matching: "finance us", in: index).map(\.path)
                == ["Documents/Finance/US"])
    }

    /// The shared prefix comes off on a component boundary, or not at all: a plain `hasPrefix`
    /// would turn `Documentsly/Q4` into `y/Q4`. A folder not under the prefix is kept whole, since
    /// it is still a real destination.
    @Test func theSharedPrefixComesOffOnlyOnAComponentBoundary() {
        #expect(PaletteRouter.below("Documents", "Documents/Legal") == "Legal")
        #expect(PaletteRouter.below("Documents", "Documentsly/Q4") == "Documentsly/Q4")
        #expect(PaletteRouter.below("Documents", "Documents") == "Documents")
        #expect(PaletteRouter.below("", "Documents/Legal") == "Documents/Legal")
        #expect(PaletteRouter.below("My Drive/Documents", "My Drive/Documents/Legal") == "Legal")
    }

    /// The depth tiebreak is measured below the landing folder, so "shallow" means what the person
    /// navigating sees. With one prefix per index this pins intent: sources with different
    /// `openAt` depths sharing an index would otherwise rank for no reason a user could name.
    @Test func theDepthTiebreakIsMeasuredBelowTheLandingFolder() {
        let index = PaletteIndex(providerRoot: "/a",
                                 folders: ["My Drive/Documents/Legal",
                                           "My Drive/Documents/Archive/2019/Legal"],
                                 folderPrefix: "My Drive/Documents")
        let ranked = PaletteRouter.rankedFolders(matching: "legal", in: index)
        #expect(ranked.map(\.path) == ["My Drive/Documents/Legal",
                                       "My Drive/Documents/Archive/2019/Legal"])
        // The top folder is at depth 0 below the landing folder, so it keeps its whole leaf score.
        #expect(ranked.first?.score == PaletteRouter.rankedFolders(
            matching: "legal", in: PaletteIndex(folders: ["Legal"])).first?.score)
    }

    // MARK: Each group appears once

    /// A group's header appears exactly once. `PaletteResultsList` emits one wherever the group
    /// changes, so a flat score sort that interleaves groups repeats headings. Swept over short
    /// queries, where a group's rows spread widest across the score range.
    @Test func everyGroupAppearsInExactlyOneRun() {
        let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)
        let queries = letters + ["fi", "re", "st", "or", "le", "do", "in", "organize", "legal"]
        for query in queries {
            let rows = PaletteRouter.rows(query: query, index: Self.index())
            let runs = rows.indices.filter { $0 == 0 || rows[$0 - 1].group != rows[$0].group }
                .map { rows[$0].group }
            #expect(runs.count == Set(runs).count,
                    "“\(query)” draws \(runs.map(\.rawValue)) — a section header appears more than once")
        }
    }

    /// ...and the top row is still the best-scoring row. Ordering groups by `rank` instead of by
    /// their best row would put a weak place match above a strong folder one. The sweep must span
    /// two groups at least once, or it proves nothing about ordering between them.
    @Test func theTopRowIsAlwaysTheBestScoringRow() {
        let queries = ["s", "legal", "fi", "organize legal", "in", "medical", "backup", "rescan"]
        var sawMoreThanOneGroup = false
        for query in queries {
            let rows = PaletteRouter.rows(query: query, index: Self.index())
            guard let first = rows.first, let best = rows.map(\.score).max() else { continue }
            #expect(first.score == best,
                    "“\(query)” leads with \(first.title) at \(first.score) while \(best) was available — grouping has buried the best match")
            if Set(rows.map(\.group)).count > 1 { sawMoreThanOneGroup = true }
        }
        #expect(sawMoreThanOneGroup,
                "no swept query spanned two groups, so this proved nothing about ordering between them")
    }

    // MARK: The matcher's own tiers

    @Test func theMatchTiersAreOrderedTheWayTheRankingClaims() {
        #expect(PaletteRouter.match("Legal", "legal") == .exact)
        #expect(PaletteRouter.match("Legal Archive", "legal") == .prefix)
        #expect(PaletteRouter.match("Income Tax", "tax") == .wordPrefix)
        #expect(PaletteRouter.match("Contax", "tax") == .substring)
        #expect(PaletteRouter.match("Medical", "tax") == .none)
        // Accents and case both fold — folder names in this tree carry both.
        #expect(PaletteRouter.match("Café Receipts", "cafe") == .prefix)
    }
}
