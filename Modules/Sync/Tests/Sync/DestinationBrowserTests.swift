import Testing
import Foundation
@testable import Sync

/// The destination picker's model: what it offers, in what order, and the two questions it asks
/// before lighting up its Move button.
@Suite struct DestinationBrowserTests {

    /// A provider at `/p` with two same-named leaves, which is the case the trail exists for:
    ///
    ///     /p/Health/Medical/Kaiser/Divit
    ///     /p/School/Divit
    ///     /p/Health/Prescriptions
    ///     /p/.hidden
    ///     /p/loose.txt
    private func fixture() throws -> MockFileManager {
        let fm = MockFileManager()
        for dir in ["/p", "/p/Health", "/p/Health/Medical", "/p/Health/Medical/Kaiser",
                    "/p/Health/Medical/Kaiser/Divit", "/p/Health/Prescriptions",
                    "/p/School", "/p/School/Divit", "/p/.hidden"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        fm.virtualDisk["/p/loose.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        return fm
    }

    // MARK: - Listing

    /// Folders only, name-sorted. A file row would be a destination you cannot pick.
    @Test func testSubfoldersListsDirectoriesOnly() throws {
        let fm = try fixture()
        let names = DestinationBrowser.subfolders(of: "/p", fileManager: fm).map(\.name)
        #expect(names == ["Health", "School"])
    }

    /// Dot-directories are dropped by name as well as by the enumerator's hidden flag — a folder
    /// can be one without the other.
    @Test func testHiddenFoldersAreDroppedUnlessAsked() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.subfolders(of: "/p", fileManager: fm).map(\.name) == ["Health", "School"])
        let shown = DestinationBrowser.subfolders(of: "/p", showHidden: true, fileManager: fm).map(\.name)
        #expect(shown.contains(".hidden"))
    }

    /// A path with nothing under it is empty, not an error — the picker renders "Empty" for it.
    @Test func testLeafFolderListsNothing() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.subfolders(of: "/p/School/Divit", fileManager: fm).isEmpty)
    }

    /// An empty root would otherwise resolve against the process working directory.
    @Test func testEmptyRootListsNothing() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.subfolders(of: "", fileManager: fm).isEmpty)
    }

    // MARK: - Search

    /// Both `Divit` folders are found, from different depths.
    @Test func testSearchFindsMatchesAtEveryDepth() throws {
        let fm = try fixture()
        let paths = Set(DestinationBrowser.search("divit", under: "/p", fileManager: fm).matches.map(\.path))
        #expect(paths == ["/p/Health/Medical/Kaiser/Divit", "/p/School/Divit"])
    }

    /// Case-insensitive and substring, so three characters reach a long folder name.
    @Test func testSearchIsCaseInsensitiveSubstring() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("PRESCRIP", under: "/p", fileManager: fm).matches.map(\.name) == ["Prescriptions"])
    }

    /// Breadth-first: the shallow match is reached before the deep one, so a truncated result set
    /// holds the shallowest matches rather than whichever branch happened to be walked first.
    @Test func testSearchIsBreadthFirst() throws {
        let fm = try fixture()
        let first = DestinationBrowser.search("divit", under: "/p", limit: 1, fileManager: fm)
        #expect(first.matches.map(\.path) == ["/p/School/Divit"], "School/Divit is two levels up from Kaiser/Divit")
    }

    /// The depth cap stops the walk before the deep match.
    @Test func testSearchRespectsMaxDepth() throws {
        let fm = try fixture()
        let shallow = DestinationBrowser.search("divit", under: "/p", maxDepth: 2, fileManager: fm)
        #expect(shallow.matches.map(\.path) == ["/p/School/Divit"])
    }

    /// An empty or whitespace query matches nothing rather than everything — the picker shows the
    /// browse columns in that state, and a full-tree dump behind them would be noise.
    @Test func testBlankQueryMatchesNothing() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("", under: "/p", fileManager: fm).matches.isEmpty)
        #expect(DestinationBrowser.search("   ", under: "/p", fileManager: fm).matches.isEmpty)
    }

    // MARK: - Ranking

    /// Recents lead, in their own order.
    @Test func testRecentsRankFirstInTheirOwnOrder() {
        let matches = [
            DestinationFolder(path: "/p/School/Divit"),
            DestinationFolder(path: "/p/Health/Medical/Kaiser/Divit"),
        ]
        let ranked = DestinationBrowser.ranked(
            matches,
            recents: ["/p/Health/Medical/Kaiser/Divit", "/p/School/Divit"],
            query: "divit",
            under: "/p"
        )
        #expect(ranked.map(\.path) == ["/p/Health/Medical/Kaiser/Divit", "/p/School/Divit"])
    }

    /// With no recency to go on, an exact name beats a mere substring.
    @Test func testExactNameBeatsSubstring() {
        let matches = [
            DestinationFolder(path: "/p/Divitations"),
            DestinationFolder(path: "/p/Divit"),
        ]
        let ranked = DestinationBrowser.ranked(matches, recents: [], query: "divit", under: "/p")
        #expect(ranked.map(\.name) == ["Divit", "Divitations"])
    }

    /// Equal on name, the shallower folder wins.
    @Test func testShallowerBeatsDeeper() {
        let matches = [
            DestinationFolder(path: "/p/Health/Medical/Kaiser/Divit"),
            DestinationFolder(path: "/p/School/Divit"),
        ]
        let ranked = DestinationBrowser.ranked(matches, recents: [], query: "divit", under: "/p")
        #expect(ranked.map(\.path) == ["/p/School/Divit", "/p/Health/Medical/Kaiser/Divit"])
    }

    /// A recent that is NOT among the matches must not be injected into the results.
    @Test func testRankingNeverAddsFolders() {
        let matches = [DestinationFolder(path: "/p/School/Divit")]
        let ranked = DestinationBrowser.ranked(
            matches, recents: ["/p/Health/Prescriptions"], query: "divit", under: "/p"
        )
        #expect(ranked.map(\.path) == ["/p/School/Divit"])
    }

    // MARK: - Trail

    /// The trail names the provider folder and every level between it and the match, so two
    /// same-named folders read differently.
    @Test func testTrailDistinguishesSameNamedFolders() {
        #expect(DestinationBrowser.trail(of: "/p/Health/Medical/Kaiser/Divit", under: "/p")
                == ["p", "Health", "Medical", "Kaiser"])
        #expect(DestinationBrowser.trail(of: "/p/School/Divit", under: "/p") == ["p", "School"])
    }

    /// A folder directly under the root trails just the root.
    @Test func testTrailOfATopLevelFolderIsTheRoot() {
        #expect(DestinationBrowser.trail(of: "/p/Health", under: "/p") == ["p"])
    }

    /// The root trails NOTHING — there is no level between a folder and itself.
    ///
    /// The `/p` fixture hid this: `"/p".deletingLastPathComponent` is `"/"`, which splits to the
    /// empty array by luck. A realistic root fell through to the outside-the-root branch and
    /// answered with the root's own ancestors.
    @Test func testTheRootItselfTrailsNothing() {
        #expect(DestinationBrowser.trail(of: "/p", under: "/p").isEmpty)
        #expect(DestinationBrowser.trail(of: "/Users/me/Dropbox", under: "/Users/me/Dropbox").isEmpty)
        #expect(DestinationBrowser.trail(of: "/Users/me/Dropbox/", under: "/Users/me/Dropbox").isEmpty,
                "a trailing slash is the same folder")
    }

    /// A path outside the root (the system-panel escape) still reads as its own parents rather
    /// than coming back empty.
    @Test func testTrailOutsideTheRootFallsBackToItsOwnParents() {
        #expect(DestinationBrowser.trail(of: "/elsewhere/Deep/Folder", under: "/p")
                == ["elsewhere", "Deep"])
    }

    /// Prefix aliasing: "/p" must not claim "/pictures/x".
    @Test func testTrailDoesNotClaimASiblingSharingAPrefix() {
        #expect(DestinationBrowser.trail(of: "/pictures/Deep/Folder", under: "/p")
                == ["pictures", "Deep"])
    }

    // MARK: - Breadcrumbs

    /// The footer names the provider, then every level down to the chosen folder.
    @Test func testCrumbsNameTheProviderThenEveryLevel() {
        #expect(DestinationBrowser.crumbs(for: "/Users/me/Dropbox/Health/Medical",
                                          under: "/Users/me/Dropbox", providerName: "Dropbox")
                == ["Dropbox", "Health", "Medical"])
        #expect(DestinationBrowser.crumbs(for: "/Users/me/Dropbox/Health",
                                          under: "/Users/me/Dropbox", providerName: "Dropbox")
                == ["Dropbox", "Health"])
    }

    /// The root is ONE crumb, and it is the PROVIDER'S name. This is the rail's "Places" row — one
    /// click, the most reachable control on the card — and it used to render the root's own
    /// ancestors between the two: "Dropbox › me › Dropbox".
    ///
    /// The provider name deliberately differs from the folder name here, because that is the real
    /// case and the only one that can tell the two failure modes apart: iCloud Drive's root folder
    /// is literally `com~apple~CloudDocs`. With the names equal, falling through to the
    /// outside-the-root branch produces the right answer for the wrong reason.
    @Test func testCrumbsForTheRootAreJustTheProviderName() {
        let root = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(DestinationBrowser.crumbs(for: root, under: root, providerName: "iCloud Drive")
                == ["iCloud Drive"])
        #expect(DestinationBrowser.crumbs(for: root + "/", under: root, providerName: "iCloud Drive")
                == ["iCloud Drive"], "a trailing slash is the same folder")
        #expect(DestinationBrowser.crumbs(for: root, under: root + "/", providerName: "iCloud Drive")
                == ["iCloud Drive"], "…on either side")

        // And one level down still swaps the display name in for the root's folder name.
        #expect(DestinationBrowser.crumbs(for: root + "/Receipts", under: root,
                                          providerName: "iCloud Drive")
                == ["iCloud Drive", "Receipts"])
    }

    /// A folder reached through `Other…` is outside the provider, so the provider's name would be a
    /// lie. It reads as its own path instead.
    @Test func testCrumbsOutsideTheRootDoNotClaimTheProvider() {
        let crumbs = DestinationBrowser.crumbs(for: "/Volumes/Archive/2025",
                                               under: "/Users/me/Dropbox", providerName: "Dropbox")
        #expect(crumbs == ["Volumes", "Archive", "2025"])
        #expect(!crumbs.contains("Dropbox"))
    }

    /// Prefix aliasing at the crumb layer too: "/p" must not claim "/pictures/x" and swap in the
    /// provider name for "pictures".
    @Test func testCrumbsDoNotClaimASiblingSharingAPrefix() {
        #expect(DestinationBrowser.crumbs(for: "/pictures/Deep", under: "/p", providerName: "P")
                == ["pictures", "Deep"])
    }

    /// No folder chosen yet is no crumbs, which is what the footer's placeholder keys on.
    @Test func testCrumbsForNoDestinationAreEmpty() {
        #expect(DestinationBrowser.crumbs(for: "", under: "/p", providerName: "P").isEmpty)
    }

    // MARK: - Pre-flight refusals

    /// Moving a folder into itself, or into anything under it.
    @Test func testDestinationInsideSelectionIsRefused() {
        #expect(DestinationBrowser.destinationIsInsideSelection("/p/Health", sources: ["/p/Health"]))
        #expect(DestinationBrowser.destinationIsInsideSelection("/p/Health/Medical/Kaiser", sources: ["/p/Health"]))
        #expect(!DestinationBrowser.destinationIsInsideSelection("/p/School", sources: ["/p/Health"]))
    }

    /// Boundary-safe: "/p/Health" must not claim "/p/HealthRecords".
    @Test func testNestingCheckStopsAtAComponentBoundary() {
        #expect(!DestinationBrowser.destinationIsInsideSelection("/p/HealthRecords", sources: ["/p/Health"]))
    }

    /// Every item already sitting in the destination — the case that used to move nothing and say
    /// nothing.
    @Test func testAllSourcesAlreadyInIsDetected() {
        #expect(DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/a.pdf", "/p/Health/b.pdf"]))
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/a.pdf", "/p/School/b.pdf"]))
    }

    /// An empty selection is not "already there" — there is simply nothing to say.
    @Test func testEmptySelectionIsNotAlreadyThere() {
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: []))
    }

    /// A file nested DEEPER than the destination has not arrived: only its immediate parent counts,
    /// or moving `/p/Health/Medical/x.pdf` into `/p/Health` would be reported as a no-op.
    @Test func testOnlyTheImmediateParentCountsAsAlreadyThere() {
        #expect(!DestinationBrowser.allSourcesAlreadyIn("/p/Health", sources: ["/p/Health/Medical/x.pdf"]))
    }

    // MARK: - Collision preview

    /// A name already taken in the destination is reported, one that is free is not.
    @Test func testCollidingNamesReportsOnlyTakenNames() throws {
        let fm = try fixture()
        fm.virtualDisk["/p/School/report.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/report.pdf", "/p/Health/notes.txt"],
            into: "/p/School",
            fileManager: fm
        )
        #expect(colliding == ["report.pdf"])
    }

    /// An item ALREADY in the destination is not colliding with itself. Without this, opening the
    /// picker on a folder the file already sits in would report a collision AND the already-there
    /// refusal — two contradictory statements about one file.
    @Test func testAnItemAlreadyInTheDestinationIsNotACollision() throws {
        let fm = try fixture()
        fm.virtualDisk["/p/School/settled.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/School/settled.pdf"], into: "/p/School", fileManager: fm
        )
        #expect(colliding.isEmpty)
    }

    /// A folder whose name is taken collides exactly as a file does — replacing a folder replaces
    /// its whole contents, so this is the case most worth seeing before confirming.
    @Test func testAFolderNameCollidesToo() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/School/Divit"], into: "/p/Health/Medical/Kaiser", fileManager: fm
        )
        #expect(colliding == ["Divit"])
    }

    /// Every name free means no preview to show.
    @Test func testNoCollisionsWhenEveryNameIsFree() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/a.pdf", "/p/Health/b.pdf"], into: "/p/School", fileManager: fm
        )
        #expect(colliding.isEmpty)
    }

    /// An empty destination is not a question yet.
    @Test func testNoDestinationYieldsNoCollisions() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.collidingNames(movingFrom: ["/p/Health/a.pdf"], into: "", fileManager: fm).isEmpty)
    }

    /// Two selected items sharing a name collide with EACH OTHER: the move is flat, so both derive
    /// the same target, the first arrives and the second prompts. Nothing has to be on disk for
    /// this, which is why an existence check alone reported a clean move and then asked anyway.
    @Test func testTwoSelectedItemsSharingANameCollide() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/report.pdf", "/p/School/report.pdf"],
            into: "/p/Health/Prescriptions",
            fileManager: fm
        )
        #expect(colliding == ["report.pdf"], "one name, one prompt — not one entry per source")
    }

    /// Three of a name is still one name: the footer counts names, and the second and third both
    /// land on the same target.
    @Test func testARepeatedNameIsReportedOnce() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/x.pdf", "/p/School/x.pdf", "/p/Health/Medical/x.pdf"],
            into: "/p/School/Divit",
            fileManager: fm
        )
        #expect(colliding == ["x.pdf"])
    }

    /// A name that collides for BOTH reasons at once — taken in the destination and repeated within
    /// the selection — is still one name. Without de-duplication the footer would say "2 of 2
    /// names" for what is one file's worth of question.
    @Test func testANameCollidingForBothReasonsIsReportedOnce() throws {
        let fm = try fixture()
        fm.virtualDisk["/p/School/dup.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/dup.pdf", "/p/Health/Medical/dup.pdf"],
            into: "/p/School",
            fileManager: fm
        )
        #expect(colliding == ["dup.pdf"])
    }

    /// Distinct names from distinct folders are still clean — the within-selection rule must not
    /// turn every multi-item move into a warning.
    @Test func testDistinctNamesFromDifferentFoldersStayClean() throws {
        let fm = try fixture()
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/a.pdf", "/p/School/b.pdf", "/p/Health/Medical/c.pdf"],
            into: "/p/Health/Prescriptions",
            fileManager: fm
        )
        #expect(colliding.isEmpty)
    }

    /// Reported in selection order, which is the order the tooltip lists them in.
    @Test func testCollidingNamesKeepSelectionOrder() throws {
        let fm = try fixture()
        fm.virtualDisk["/p/School/zebra.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        fm.virtualDisk["/p/School/apple.pdf"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let colliding = DestinationBrowser.collidingNames(
            movingFrom: ["/p/Health/zebra.pdf", "/p/Health/apple.pdf"],
            into: "/p/School",
            fileManager: fm
        )
        #expect(colliding == ["zebra.pdf", "apple.pdf"])
    }

    // MARK: - Search cost

    /// The listing cap bounds the walk by directories READ, not by matches found — the expensive
    /// query is the one that matches nothing, where `limit` never bites and the walk would
    /// otherwise read every directory within `maxDepth` before it could answer.
    @Test func testSearchStopsAfterItsListingBudget() throws {
        // Zero-padded so every sibling name is the same length: the mock's enumerator matches
        // children by string prefix, and "/p/d1" would otherwise claim "/p/d10" as its own child.
        let fm = MockFileManager()
        for i in 0..<12 {
            let parent = String(format: "/p/d%02d", i)
            try fm.createDirectory(at: URL(fileURLWithPath: parent), withIntermediateDirectories: true)
            for j in 0..<4 {
                try fm.createDirectory(at: URL(fileURLWithPath: String(format: "%@/e%02d", parent, j)),
                                       withIntermediateDirectories: true)
            }
        }
        var listings = 0
        fm.onEnumerate = { _ in listings += 1 }

        // Nothing matches, so `limit` never bites and only the listing budget can stop it.
        _ = DestinationBrowser.search("nothingmatchesthis", under: "/p", maxListings: 5, fileManager: fm)
        #expect(listings <= 5, "read \(listings) directories against a budget of 5")

        // …and the budget is a real ceiling, not a value the walk would have respected anyway:
        // unbudgeted, the same fruitless query reads the entire tree.
        listings = 0
        _ = DestinationBrowser.search("nothingmatchesthis", under: "/p", fileManager: fm)
        #expect(listings == 61, "/p plus its 12 children plus their 48 — every directory there is")
    }

    /// Cancellation is polled per directory, so a superseded keystroke's walk stops instead of
    /// running to completion behind the one the user is waiting on. `Task.detached` does not
    /// inherit cancellation, which is why this is an explicit hook rather than `Task.isCancelled`.
    @Test func testSearchStopsWhenCancelled() throws {
        let fm = try fixture()
        var listings = 0
        fm.onEnumerate = { _ in listings += 1 }
        let found = DestinationBrowser.search("divit", under: "/p", fileManager: fm,
                                              isCancelled: { true })
        #expect(found.matches.isEmpty)
        #expect(listings == 0, "cancelled before the first directory was even read")
    }

    // MARK: - Truncation is reported, not silent

    /// A walk that exhausts the tree is COMPLETE — the flag must not simply always be true, or the
    /// picker would permanently caveat results it fully searched.
    @Test func testAnExhaustiveSearchIsNotTruncated() throws {
        let fm = try fixture()
        let outcome = DestinationBrowser.search("divit", under: "/p", fileManager: fm)
        #expect(outcome.matches.count == 2)
        #expect(outcome.isTruncated == false)
    }

    /// Each of the three caps stops the walk early, and each must say so — a partial list that
    /// reads as the complete one is how "the folder isn't there" becomes a wrong conclusion.
    @Test func testEveryCapReportsTruncation() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("divit", under: "/p", limit: 1, fileManager: fm).isTruncated,
                "match limit")
        #expect(DestinationBrowser.search("divit", under: "/p", maxDepth: 2, fileManager: fm).isTruncated,
                "depth ceiling — Kaiser/Divit is below it")
        #expect(DestinationBrowser.search("divit", under: "/p", maxListings: 1, fileManager: fm).isTruncated,
                "listing budget")
    }

    /// A blank query is not a truncated search — it is no search. Otherwise the picker would show
    /// its "showing the first N" caveat over the browse columns, which ran no walk at all.
    @Test func testABlankQueryIsNotTruncated() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("", under: "/p", fileManager: fm).isTruncated == false)
    }

    /// …and an uncancelled walk is unaffected, so the hook cannot silently disable search.
    @Test func testSearchIsUnaffectedWhenNotCancelled() throws {
        let fm = try fixture()
        let found = DestinationBrowser.search("divit", under: "/p", fileManager: fm,
                                              isCancelled: { false })
        #expect(Set(found.matches.map(\.path)) == ["/p/Health/Medical/Kaiser/Divit", "/p/School/Divit"])
    }
}
