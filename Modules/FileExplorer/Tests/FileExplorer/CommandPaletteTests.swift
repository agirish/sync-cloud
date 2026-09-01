import Testing
import Foundation
@testable import Sync
@testable import FileExplorer

/// The ⌘K palette's routing table (ROADMAP 14).
///
/// ## Why this suite exists in this shape
///
/// The last routing table this app shipped went out **inverted** and no test could have caught it:
/// the decision was three lines inside an `onSubmit`, which cannot be fired from a unit test, on a
/// SwiftUI `Button` that is not an `NSControl`. It only became testable once the decision was
/// extracted into a pure function returning a value — `PaneSearchSubmit`, whose own doc comment is
/// the record of that. `PaletteRouter` is built to that pattern from the start, and this suite is
/// the reason it is worth the indirection.
///
/// Every test below asserts a **route**, not a row's existence. A palette that lists the right
/// destination and routes it somewhere else is exactly the failure the pane search had.
@Suite struct CommandPaletteTests {

    // MARK: Fixtures — the real tree's shapes, cut to size

    static let root = "/Users/x/Documents"

    static var people: [Person] {
        [Person(id: "p.aditi", displayName: "Aditi", relationship: "daughter",
                fullNames: ["Aditi Girish"], aliases: []),
         Person(id: "p.girish", displayName: "Girish", relationship: "father",
                fullNames: ["Girish Krishnamurthy"], aliases: ["Dad"]),
         Person(id: "p.muktha", displayName: "Muktha", relationship: "mother",
                fullNames: ["Muktha Girish"], aliases: ["Mom"])]
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

    /// **The remembered folders are listed, marked, and unrunnable — not dropped.**
    ///
    /// The root is checked before any of its children, so a sleeping drive takes out every recent
    /// and every pin at once. This landing IS that list, so dropping them makes ⌘K open blank and
    /// "I have no recents" indistinguishable from "my drive is not awake". Decided 2026-08-19
    /// (ROADMAP_V4 §7), narrowing the earlier "a remembered folder that has gone does not appear"
    /// to the case where the root was there to be asked.
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

    /// **The typed query is the same disk**, and it was answering differently.
    ///
    /// `folders` comes from the survey profile held in memory, so it matches a query with the drive
    /// asleep exactly as it does awake. Until 2026-08-19 only the empty-query landing carried the
    /// mark: ⌘K opened saying "Not available" against every remembered folder, and typing one
    /// letter replaced them with the same tree offered as live destinations — ↩ then revealed a
    /// path that is not there. One root, one answer.
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

    /// ROADMAP 14's own example, and the property that makes the palette worth building: a query
    /// that is a verb and an object routes to **both**, in one row.
    @Test func organizeIncomeTaxAimsOrganizeAtThatFolder() {
        let top = try? #require(Self.first("organize income tax"))
        #expect(top == .organize(lens: nil, scope: "\(Self.root)/Finance/US/Income Tax"),
                "the top row for a verb-and-object query was \(String(describing: top))")
    }

    /// The object must not be dropped. This is the specific silent loss: routing to Organize alone
    /// lands you there still answering about wherever you were, with nothing on screen saying so.
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

    /// A lens name is a verb too — the six rail items are the reason this item got more valuable
    /// than it was when written.
    @Test func aLensNameAndAFolderRouteToThatLensScoped() {
        #expect(Self.first("duplicates in Legal")
                == .organize(lens: .duplicates, scope: "\(Self.root)/Legal"))
        // The connective is dropped only between the halves, so this is the same request.
        #expect(Self.first("duplicates Legal")
                == .organize(lens: .duplicates, scope: "\(Self.root)/Legal"))
    }

    /// **"rename" reaches the place that fixes names.** ROADMAP 14's founding case: a user who
    /// thinks "rename" must have something to aim at. That place is Renames now — the Names lens
    /// folded into it as the "to fix" section — and the vocabulary moved with it, which is what
    /// this pins: the word still routes, and it routes to where the findings actually live.
    @Test func renameReachesTheNamesLensEvenThoughNothingIsCalledRename() {
        #expect(Self.routes("rename").contains(.organize(lens: .renames, scope: nil)))
        // The folded vocabulary rode along: the words the OLD place answered to reach the
        // same landing, so no muscle memory dead-ends.
        #expect(Self.routes("risky").contains(.organize(lens: .renames, scope: nil)))
        #expect(Self.routes("illegal").contains(.organize(lens: .renames, scope: nil)))
        // And "names" reaches exactly one place — the retired lens is gone, so a second row for
        // the same landing is now unrepresentable rather than merely absent.
        #expect(Self.routes("names").filter { route in
            if case .organize = route { return true } else { return false }
        }.count == 1)
    }

    /// A place whose name is **two words** is found, object and all.
    ///
    /// Named for what it actually proves. It was called *…IsPreferredOverItsFirstWord*, claiming the
    /// longest-first scan order; mutating that order to shortest-first failed nothing, because no
    /// two-word name in the vocabulary has a head that is also a name. What the scan genuinely buys
    /// is the multi-word match at all — a single-word parse loses this query outright. The direction
    /// is documented as unobservable-today at `splitVerb`, rather than tested for here as if it were.
    @Test func aTwoWordPlaceNameIsFoundBeforeItsFirstWordCanMisfire() {
        #expect(Self.first("to file legal")
                == .organize(lens: .toFile, scope: "\(Self.root)/Legal"))
    }

    @Test func aVerbWithNoObjectIsJustThePlace() {
        // **"storage" reaches the LENS now, and that is an upgrade rather than a rename.** It used
        // to resolve to a hand-written `.storage` place whose `takesAFolder` was false — so
        // "storage Legal" silently dropped the folder. As a derived lens place it carries a scope
        // like every other lens; the unscoped query still lands in the same page.
        #expect(Self.first("storage") == .organize(lens: .storage, scope: nil))
        #expect(Self.first("compare") == .compare)
    }

    /// The half the fold actually bought: Storage takes a folder now.
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

    // MARK: People — "aditi's files"

    @Test func aPossessiveQueryRoutesToThatPersonsGather() {
        #expect(Self.routes("aditi's files").contains(.person(id: "p.aditi")))
        #expect(Self.routes("aditi").contains(.person(id: "p.aditi")))
    }

    /// **Exactly one, or nobody** — delegated to `PersonSearchOffer` precisely so the palette and
    /// the pane search cannot answer the same question differently. "girish krishnamurthy muktha"
    /// names a couple, and picking one of them is the over-attribution these names invite.
    @Test func aQueryNamingTwoPeopleOffersNeither() {
        let rows = PaletteRouter.rows(query: "girish krishnamurthy muktha", index: Self.index())
        #expect(!rows.contains { if case .person = $0.route { return true } else { return false } })
    }

    /// A roster can outlive the survey it was built beside. The row stays and says why — an offer
    /// whose accept does nothing is the "nothing happened" this family of features exists to remove.
    @Test func aPersonRowWithNoSurveyIsShownDisabledWithItsReason() {
        let rows = PaletteRouter.rows(query: "aditi", index: Self.index(hasSurvey: false))
        let person = rows.first { if case .person = $0.route { return true } else { return false } }
        #expect(person != nil, "the person row was hidden rather than disabled")
        #expect(person?.isAvailable == false)
        #expect(person?.unavailable == "No document survey on this Mac yet")
    }

    // MARK: Availability is a REASON, never an absence

    /// ROADMAP 14 names this case: an unmounted source shown disabled *with its reason*, not hidden.
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

    /// "recent and likely actions" — ROADMAP 14. Recents lead because the commonest reason to open
    /// a palette is to go back to where you just were.
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

    /// ⌘K reaches Browse — which takes TWO things, and the second is the one that rots. A
    /// `PaletteRoute` case with no `PalettePlace` beside it compiles, routes correctly when it is
    /// run, and can never be run, because nothing ever emits a row carrying it.
    @Test func browseIsReachableByName() {
        #expect(Self.first("browse") == .browse)
    }

    /// The words someone reaches for when they want to look at their files rather than be told
    /// something about them. "files" especially: it is the query for "I just want to go and move
    /// this", which is the whole distinction Browse carries.
    @Test func theWordsForLookingAtFilesReachBrowse() {
        for query in ["files", "finder", "folders"] {
            #expect(Self.routes(query).contains(.browse), "'\(query)' does not reach Browse")
        }
    }

    /// `PalettePlace.allCases` is hand-written — the associated-value case rules out the
    /// synthesized conformance — so it is the one list where a new place can be added to the enum
    /// and silently never offered. Counted rather than eyeballed: every place the type can build
    /// has to appear in the list the router walks.
    @Test func everyPlaceIsOfferedByTheHandWrittenAllCases() {
        let offered = Set(PalettePlace.allCases.map(\.id))
        // Storage is no longer hand-written here: it arrives through `railItems` below, which is
        // what gives it a scope route the hand-written place never had.
        let expected = Set(([PalettePlace.browse, .compare, .editor, .organizeOverview]
                            + OrganizeLens.railItems.map(PalettePlace.lens)).map(\.id))
        #expect(offered == expected)
        // And the list is what the ROWS come from, so an entry that exists but scores nothing is
        // still a place nobody can reach.
        let rows = PaletteRouter.rows(query: "", index: Self.index())
        for place in PalettePlace.allCases {
            #expect(rows.contains { $0.route == place.route(scope: nil) },
                    "\(place.title) is in allCases but no empty-query row carries it")
        }
    }

    /// Browse takes no scope. It shows wherever the pane already is, and moving the pane is what
    /// the existing `.folder` route does — so "browse income tax" must not mint a second, silently
    /// different way of aiming a workspace.
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
        let rows = PaletteRouter.rows(query: "aditi", index: Self.index(hasRegistry: false))
        #expect(!rows.contains { if case .person = $0.route { return true } else { return false } })
    }

    // MARK: Pinned and recent are two different claims

    /// ROADMAP 14 asks the Folders group for "recent and pinned paths". They are two lists because
    /// they are two claims — *where you just were* and *where you keep going back to* — and a row
    /// labelled "Recent" for a folder pinned months ago is the wrong one.
    @Test func theEmptyQueryLeadsWithPinnedThenRecentAndSaysWhichIsWhich() {
        var index = Self.index(recent: ["Medical"])
        index.pinnedFolders = ["Legal"]
        let rows = PaletteRouter.rows(query: "", index: index)
        let folders = rows.filter { $0.group == .folders }
        #expect(folders.map(\.route) == [.folder(path: "\(Self.root)/Legal"),
                                         .folder(path: "\(Self.root)/Medical")])
        #expect(folders.first?.detail?.hasPrefix("Pinned ") == true)
        #expect(folders.dropFirst().first?.detail?.hasPrefix("Recent ") == true)
    }

    // MARK: ↑ ↓ ↩

    /// The highlight opens on the first row that can actually be **chosen**.
    ///
    /// Not row 0: unavailable rows are deliberately kept in the list, and a palette that opened with
    /// the highlight on one would make ↩ do nothing — which reads as the palette being broken rather
    /// than as the source being unmounted.
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

    /// An index left over from the previous results names a different row now. The host recomputes
    /// the selection on every keystroke for that reason; this pins the half that can be tested —
    /// an index past the end must never be run.
    @Test func aStaleIndexRunsNothing() {
        let rows = [PaletteRow(id: "a", group: .places, title: "A", symbol: "x", route: .compare)]
        #expect(PaletteSelection.chosen(at: 7, in: rows) == nil)
        #expect(PaletteSelection.chosen(at: -1, in: rows) == nil)
    }

    // MARK: The folder index — the defect the installed app found

    /// **A tilde-spelled profile root still matches an expanded provider root.**
    ///
    /// This is the bug the app's own log line caught after everything else was green: the host
    /// compared `FolderProfile.root` (`~/Documents`) against `lensProviderRootExpanded`
    /// (`/Users/abhishek/Documents`) as plain strings, so on the real tree the palette indexed
    /// **0 of 3,013 folders** — every folder query and the entire "organize <folder>" lede silently
    /// answering nothing, with no error anywhere. The routing tests could not see it: they are
    /// handed the folder list.
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

    /// A profile about a tree **outside** the provider root contributes nothing.
    ///
    /// Containment, not equality — but containment in one direction only. A profile rooted *above*
    /// the provider root, or off in another tree entirely, yields keys relative to the wrong thing,
    /// and no prefix repairs them; a folder that cannot be named is not a destination.
    @Test func aProfileAboutADifferentTreeContributesNoFolders() {
        #expect(PaletteIndex.folders(profileRoot: "/a/Documents", providerRoot: "/b/Documents",
                                     keys: ["Legal"]).isEmpty)
        // Above the provider root: its keys name paths that are not under this source at all.
        #expect(PaletteIndex.folders(profileRoot: "/a", providerRoot: "/a/Documents",
                                     keys: ["Legal"]).isEmpty)
        // A sibling that merely shares a string prefix is outside, not inside — the boundary rule
        // `PathBoundary` exists for, and the one a `hasPrefix` re-implementation would get wrong.
        #expect(PaletteIndex.folders(profileRoot: "/a/Documentsly", providerRoot: "/a/Documents",
                                     keys: ["Legal"]).isEmpty)
        #expect(PaletteIndex.folders(profileRoot: nil, providerRoot: "/a", keys: ["Legal"]).isEmpty)
        #expect(PaletteIndex.folders(profileRoot: "/a", providerRoot: "", keys: ["Legal"]).isEmpty)
    }

    /// A profile rooted **inside** the provider root contributes its folders, re-based.
    ///
    /// This is the ordinary case now, not an exotic one: a source's root is its account folder
    /// while the folder profile is surveyed over the source's landing folder inside it, so the two
    /// differ by exactly that source's `openAt` for every cloud account on the machine.
    ///
    /// The re-basing is what makes containment safe where equality used to be required. Every other
    /// path in the index — recents, pins, a typed path — is measured from the provider root, and a
    /// route is built by joining that root to what this returns; so a key handed back unchanged
    /// would name `<account>/Legal` for a folder really at `<account>/Documents/Legal`. Returning
    /// nothing instead, which is what an equality test does here, is no better: ⌘K's whole Folders
    /// group and the "organize &lt;folder&gt;" lede go silently empty, which is how this last broke.
    @Test func aProfileInsideTheProviderRootContributesItsFoldersRebased() {
        #expect(PaletteIndex.folders(profileRoot: "/a/Documents", providerRoot: "/a",
                                     keys: [".", "Legal", "Finance/US"])
                == ["Documents/Legal", "Documents/Finance/US"])
        // Two levels down, which is Google Drive's shape (`My Drive/Documents`).
        #expect(PaletteIndex.folders(profileRoot: "/a/My Drive/Documents", providerRoot: "/a",
                                     keys: ["Legal"]) == ["My Drive/Documents/Legal"])
    }

    /// **The prefix the index carries is the segment its folders actually carry.**
    ///
    /// `folderPrefix` exists so the ranker can subtract the shared `Documents` from every key
    /// before scoring it; that only works while it is the *same* segment `folders` prepended. The
    /// two are written as one rule — `folders` calls `folderPrefix` — and this is what stops a
    /// later edit from splitting them, because a drift is otherwise silent: the ranker would strip
    /// nothing and every folder would score its whole path again, which is the ⌘K blowup below.
    ///
    /// Also pinned: nil from `folderPrefix` on exactly the inputs that make `folders` empty. A `?? ""`
    /// at the call site must mean "no re-base happened", never "re-base of an unusable pair".
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

    /// **A query that only matches the shared prefix ranks nothing.**
    ///
    /// The defect this pins: a source's root is the account *above* its documents tree, so every
    /// indexed key begins `Documents` — and `rankedFolders` scores the path with its slashes
    /// flattened to spaces. Typing `doc` therefore scored an identical prefix match on every
    /// surveyed folder (~3,013 of them on the real tree), and the Folders group answered six
    /// alphabetically-arbitrary rows rather than the folders whose names contain "doc".
    ///
    /// Mutation-checked: dropping the `below(index.folderPrefix, folder)` call — scoring the whole
    /// key, which is what shipped — returns all four folders here instead of one.
    @Test func aQueryMatchingOnlyTheSharedPrefixRanksNothing() {
        let index = PaletteIndex(
            providerRoot: "/a",
            folders: ["Documents/Legal", "Documents/Finance/US",
                      "Documents/Archive/Old Docs", "Documents/Receipts"],
            folderPrefix: "Documents")
        let ranked = PaletteRouter.rankedFolders(matching: "doc", in: index)
        #expect(ranked.map(\.path) == ["Documents/Archive/Old Docs"],
                "\"doc\" matched \(ranked.map(\.path)) — the shared prefix is being scored")
        // The prefix's own name is no longer a query at all. It was not one before the split
        // either: the survey anchor was `.` then, and `.` is filtered out of the index.
        #expect(PaletteRouter.rankedFolders(matching: "documents", in: index).isEmpty)
        // ...and a real name still ranks, so the test above is not passing by matching nothing.
        #expect(PaletteRouter.rankedFolders(matching: "legal", in: index).map(\.path)
                == ["Documents/Legal"])
        // A multi-word path query still works below the prefix — `Finance/US` is scored as
        // "Finance US", which is the whole reason the path half of the score exists.
        #expect(PaletteRouter.rankedFolders(matching: "finance us", in: index).map(\.path)
                == ["Documents/Finance/US"])
    }

    /// **The shared prefix comes off on a component boundary, or not at all.**
    ///
    /// A plain `hasPrefix` would take `Documents` off `Documentsly/Q4` and leave `y/Q4` — not a
    /// path, and scored as though it were one. Same trap as the absolute-side boundary rule in
    /// `aProfileAboutADifferentTreeContributesNoFolders`, one level down.
    ///
    /// A folder that is not under the prefix is kept whole rather than dropped: it is still a real
    /// destination, and the shared segment says nothing about it either way.
    @Test func theSharedPrefixComesOffOnlyOnAComponentBoundary() {
        #expect(PaletteRouter.below("Documents", "Documents/Legal") == "Legal")
        #expect(PaletteRouter.below("Documents", "Documentsly/Q4") == "Documentsly/Q4")
        #expect(PaletteRouter.below("Documents", "Documents") == "Documents")
        #expect(PaletteRouter.below("", "Documents/Legal") == "Documents/Legal")
        #expect(PaletteRouter.below("My Drive/Documents", "My Drive/Documents/Legal") == "Legal")
    }

    /// **Depth is measured below the landing folder too.**
    ///
    /// The tiebreak says a shallower folder wins, and "shallow" has to mean what the person
    /// navigating sees. Measured on the whole key it is a constant offset today — one prefix per
    /// index — so this pins the intent rather than a live bug: the day two sources with different
    /// `openAt` depths share one index, measuring from the account root would rank Drive's folders
    /// below OneDrive's for no reason a user could name.
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

    /// **A group's header must appear exactly once.**
    ///
    /// `PaletteResultsList` emits one wherever the group changes, so a ranking that interleaves
    /// groups puts the same heading on screen two or three times. The flat score sort this replaced
    /// did exactly that on nearly every short query — measured over this fixture, `"s"` produced
    /// *Places, Actions, Sources, Actions, Places, Actions, Folders*: five groups, seven headings.
    ///
    /// Swept over one- and two-letter queries because that is where a group's rows spread widest
    /// across the score range; a single hand-picked query would have missed it, and did.
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

    /// ...and **the top row is still the best-scoring row**, which is what the flat sort was for.
    ///
    /// Grouping the rows is only safe if it does not bury the best match: ordering the groups by
    /// `rank` instead of by their best row would put a weak place match above a strong folder one,
    /// which is the obvious way to write this and the wrong one. Asserted over a sweep, with the
    /// cross-group case pinned separately so the sweep cannot pass on single-group queries alone.
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
