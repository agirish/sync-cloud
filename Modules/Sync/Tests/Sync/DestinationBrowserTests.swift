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
        let paths = Set(DestinationBrowser.search("divit", under: "/p", fileManager: fm).map(\.path))
        #expect(paths == ["/p/Health/Medical/Kaiser/Divit", "/p/School/Divit"])
    }

    /// Case-insensitive and substring, so three characters reach a long folder name.
    @Test func testSearchIsCaseInsensitiveSubstring() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("PRESCRIP", under: "/p", fileManager: fm).map(\.name) == ["Prescriptions"])
    }

    /// Breadth-first: the shallow match is reached before the deep one, so a truncated result set
    /// holds the shallowest matches rather than whichever branch happened to be walked first.
    @Test func testSearchIsBreadthFirst() throws {
        let fm = try fixture()
        let first = DestinationBrowser.search("divit", under: "/p", limit: 1, fileManager: fm)
        #expect(first.map(\.path) == ["/p/School/Divit"], "School/Divit is two levels up from Kaiser/Divit")
    }

    /// The depth cap stops the walk before the deep match.
    @Test func testSearchRespectsMaxDepth() throws {
        let fm = try fixture()
        let shallow = DestinationBrowser.search("divit", under: "/p", maxDepth: 2, fileManager: fm)
        #expect(shallow.map(\.path) == ["/p/School/Divit"])
    }

    /// An empty or whitespace query matches nothing rather than everything — the picker shows the
    /// browse columns in that state, and a full-tree dump behind them would be noise.
    @Test func testBlankQueryMatchesNothing() throws {
        let fm = try fixture()
        #expect(DestinationBrowser.search("", under: "/p", fileManager: fm).isEmpty)
        #expect(DestinationBrowser.search("   ", under: "/p", fileManager: fm).isEmpty)
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
}
