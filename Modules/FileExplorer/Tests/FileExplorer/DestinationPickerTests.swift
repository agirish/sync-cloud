import Testing
import Foundation
@testable import FileExplorer
import Sync

/// The picker's pure decisions: which column stack shows a given folder, and what its Move button
/// refuses to do.
@Suite struct DestinationPickerTests {

    // MARK: - Opening position

    /// Opening on a nested folder must show the whole stack down to it, not just the root.
    @Test func testABrowsePathIsDerivedForANestedFolder() {
        let path = DestinationPicker.browsePath(for: "/p/Health/Medical", under: "/p")
        #expect(path.components == ["Health", "Medical"])
    }

    /// The root itself rests at one column.
    @Test func testTheRootRestsAtASingleColumn() {
        #expect(DestinationPicker.browsePath(for: "/p", under: "/p").isEmpty)
    }

    /// Trailing slashes on either side must not produce an empty leading component, which would
    /// render a nameless column.
    @Test func testTrailingSlashesAreNormalised() {
        let path = DestinationPicker.browsePath(for: "/p/Health/", under: "/p/")
        #expect(path.components == ["Health"])
    }

    /// A folder outside the root cannot be drawn as a stack under it, so it rests at the root —
    /// the only honest stack available. Reached when a recent survives a provider change.
    @Test func testAFolderOutsideTheRootRestsAtTheRoot() {
        #expect(DestinationPicker.browsePath(for: "/elsewhere/Deep", under: "/p").isEmpty)
    }

    /// Prefix aliasing: "/p" must not claim "/pictures/Deep" and render it as a stack.
    @Test func testASiblingSharingAPrefixIsNotUnderTheRoot() {
        #expect(DestinationPicker.browsePath(for: "/pictures/Deep", under: "/p").isEmpty)
    }

    /// An iCloud item lives at `~/Documents/…`, which iCloud Drive reaches through its hidden
    /// `Documents` link. The picker must open down that stack, not at the bare root (2026-11-01:
    /// it opened on iCloud's root with only Downloads and Word showing).
    @Test func testAFolderUnderALinkedFolderOpensThroughTheLink() {
        let links: PathBoundary.LinkedFolders = ["/icloud": ["Documents": "/home/Documents"]]
        let path = DestinationPicker.browsePath(for: "/home/Documents/Travel/Trips", under: "/icloud", links: links)
        #expect(path.components == ["Documents", "Travel", "Trips"])
        #expect(path.columnDirectories(treeRoot: "/icloud", links: links).last == "/home/Documents/Travel/Trips")
        // Control: without the table it is outside the root.
        #expect(DestinationPicker.browsePath(for: "/home/Documents/Travel/Trips", under: "/icloud", links: [:]).isEmpty)
    }

    // MARK: - Round trip

    /// Every folder under the root resolves back to itself through the stack, which is what makes
    /// the footer path and the highlighted column agree.
    @Test func testTheStackResolvesBackToTheFolderItOpenedOn() {
        let root = "/p"
        for folder in ["/p", "/p/Health", "/p/Health/Medical/Kaiser/Son"] {
            let path = DestinationPicker.browsePath(for: folder, under: root)
            #expect(path.currentDirectory(treeRoot: root) == folder, "round trip failed for \(folder)")
        }
    }

    // MARK: - Recents that share a name (BR20)

    /// **Two recents named Legal each say where they sit**; a recent with a name of its own says
    /// nothing more, and one directly under the provider names the provider.
    @Test func recentsThatShareANameCarryTheirParent() {
        let recents = ["/p/Clients/Acme/Legal", "/p/Archive/Legal", "/p/Medical", "/p/Legal"]
        func detail(_ path: String) -> String? {
            DestinationPicker.recentDetail(for: path, among: recents, under: "/p", rootName: "iCloud")
        }
        // The breadcrumb's style, provider first: not a slash path.
        #expect(detail("/p/Clients/Acme/Legal") == "iCloud › Clients › Acme")
        #expect(detail("/p/Archive/Legal") == "iCloud › Archive")
        #expect(detail("/p/Legal") == "iCloud")
        #expect(detail("/p/Medical") == nil, "a name no other recent shares stays one line")
    }

    /// The rail draws the rule's answer under every recent, and its full path as the tooltip.
    @Test func theRailDrawsTheParentAndTheFullPath() throws {
        let picker = try OrganizeScopeCallSiteTests.source("DestinationPicker.swift")
        let rail = try OrganizeScopeCallSiteTests.body(of: "private var shortcutsRail: some View {", in: picker)
        #expect(rail.contains("detail: Self.recentDetail(for: path, among: moves, under: requestRoot,"),
                "the rail's recents no longer carry their parent")
        #expect(picker.contains(".help((path as NSString).abbreviatingWithTildeInPath)"),
                "the rail's rows lost their full-path tooltip")
    }

    // MARK: - Here rows

    /// The item's own folder, then up one, then up two — the short moves, first in the rail.
    @Test func testHereRowsClimbFromTheItemsFolder() {
        let rows = DestinationPicker.hereRows(itemFolder: "/p/Travel/Trips/IN-US", root: "/p", rootName: "iCloud", links: [:])
        #expect(rows.map(\.name) == ["IN-US", "Trips", "Travel", "iCloud"])
        #expect(rows.map(\.path) == ["/p/Travel/Trips/IN-US", "/p/Travel/Trips", "/p/Travel", "/p"])
        #expect(rows.map(\.detail) == ["now here", "up one", "up two", "top"])
    }

    /// The climb stops at the root, which reads as the provider.
    @Test func testHereRowsStopAtTheRoot() {
        let travel = DestinationPicker.hereRows(itemFolder: "/p/Travel", root: "/p", rootName: "iCloud", links: [:])
        #expect(travel.map(\.name) == ["Travel", "iCloud"])
        #expect(travel.map(\.detail) == ["now here", "up one"])
        let atRoot = DestinationPicker.hereRows(itemFolder: "/p", root: "/p", rootName: "iCloud", links: [:])
        #expect(atRoot.map(\.name) == ["iCloud"])
        #expect(atRoot.map(\.detail) == ["now here"])
        // Outside the root: the root row alone, so the provider is always one click away.
        #expect(DestinationPicker.hereRows(itemFolder: "/elsewhere/x", root: "/p", rootName: "iCloud", links: [:])
            .map(\.path) == ["/p"])
    }

    /// Above `~/Documents` the real parent is the home folder, which is not in iCloud Drive; through
    /// the link it is iCloud Drive itself.
    @Test func testHereRowsClimbThroughALinkedFolder() {
        let links: PathBoundary.LinkedFolders = ["/icloud": ["Documents": "/home/Documents"]]
        let rows = DestinationPicker.hereRows(itemFolder: "/home/Documents/Travel", root: "/icloud",
                                              rootName: "iCloud", links: links)
        #expect(rows.map(\.name) == ["Travel", "Documents", "iCloud"])
        #expect(rows.map(\.path) == ["/home/Documents/Travel", "/home/Documents", "/icloud"])
    }

    // MARK: - Preview

    /// The item lands where it will sort, with its neighbours either side and the rest folded.
    @Test func testThePreviewShowsWhereTheItemLands() {
        let years = ["2012", "2013", "2014", "2015", "2017", "2018", "2020", "2022", "2023", "2024", "2025"]
        let rows = DestinationPicker.previewRows(existing: years + ["Family"], moving: ["2026 Sep"], context: 2)
        #expect(rows == [.more(9, 9), .folder("2024"), .folder("2025"), .moving("2026 Sep"), .folder("Family")])
        // Sorted as the columns sort: "16. Sep 2026" is a number, 16, before 2012.
        let first = DestinationPicker.previewRows(existing: years, moving: ["16. Sep 2026"], context: 1)
        #expect(first == [.moving("16. Sep 2026"), .folder("2012"), .more(10, 12)])
    }

    /// An empty destination (a new folder) shows only what lands in it.
    @Test func testThePreviewOfAnEmptyFolderIsTheItem() {
        #expect(DestinationPicker.previewRows(existing: [], moving: ["a.pdf", "b.pdf"]) == [.moving("a.pdf"), .moving("b.pdf")])
    }

    // MARK: - Column

    /// A suggested folder not yet made is drawn where it will sort once it is.
    @Test func testANewFolderIsDrawnWhereItWillSort() {
        let folders = ["2024", "2025", "Family"].map { DestinationFolder(path: "/p/\($0)") }
        let ghost = DestinationSuggestion(path: "/p/2026", name: "2026", isNew: true, reason: "")
        let entries = DestinationColumn.entries(folders, ghost: ghost).map(\.id)
        #expect(entries == ["/p/2024", "/p/2025", "new:/p/2026", "/p/Family"])
        // Already there (made by hand since): drawn once, as itself.
        let made = folders + [DestinationFolder(path: "/p/2026")]
        #expect(DestinationColumn.entries(made, ghost: ghost).count == made.count)
    }

    // MARK: - Review fixes, 2026-11-01

    /// Items not in the opening folder (a Downloads file filed into iCloud; a selection from two
    /// folders): nothing claims "now here" — the root row alone, with no rung named.
    @Test func testHereClaimsNothingWhenTheItemsAreElsewhere() {
        let rows = DestinationPicker.hereRows(itemFolder: "/p", root: "/p", rootName: "iCloud", itemsAreHere: false, links: [:])
        #expect(rows.map(\.name) == ["iCloud"])
        #expect(rows.map(\.detail) == [nil])
        #expect(DestinationPicker.railFocus(highlighted: "", itemFolder: "/p", itemsAreHere: false) == "")
        #expect(DestinationPicker.railFocus(highlighted: "", itemFolder: "/p", itemsAreHere: true) == "/p")
        #expect(DestinationPicker.railFocus(highlighted: "/p/A", itemFolder: "/p", itemsAreHere: true) == "/p/A")
    }

    /// Create and Move only for the suggestion that is new AND picked.
    @Test func testANewFolderIsMadeOnlyForThePickedNewSuggestion() {
        let new = DestinationSuggestion(path: "/p/2026", name: "2026", isNew: true, reason: "")
        let made = DestinationSuggestion(path: "/p/2026", name: "2026", isNew: false, reason: "")
        #expect(DestinationPicker.picksNewFolder(highlighted: "/p/2026", suggestion: new))
        #expect(!DestinationPicker.picksNewFolder(highlighted: "/p/2025", suggestion: new))
        #expect(!DestinationPicker.picksNewFolder(highlighted: "", suggestion: new))
        #expect(!DestinationPicker.picksNewFolder(highlighted: "/p/2026", suggestion: made))
        #expect(!DestinationPicker.picksNewFolder(highlighted: "/p/2026", suggestion: nil))
    }

    /// A destination spelled through iCloud's link is the `~/Documents` folder every node names.
    @Test func testALinkSpelledDestinationIsReadTheRealWay() {
        let links: PathBoundary.LinkedFolders = ["/icloud": ["Documents": "/home/Documents"]]
        #expect(DestinationPicker.canonical("/icloud/Documents/Travel", under: "/icloud", links: links) == "/home/Documents/Travel")
        #expect(DestinationPicker.canonical("/home/Documents/Travel/", under: "/icloud", links: links) == "/home/Documents/Travel")
        #expect(DestinationPicker.canonical("/icloud/Downloads", under: "/icloud", links: links) == "/icloud/Downloads")
        #expect(DestinationPicker.canonical("/elsewhere", under: "/icloud", links: links) == "/elsewhere")
    }

    /// A folder source inside Documents is its own place, not iCloud's through the link.
    @Test func testAPlaceBelongsToTheSourceThatHoldsItMostClosely() {
        let links: PathBoundary.LinkedFolders = ["/icloud": ["Documents": "/home/Documents"]]
        let sources = [(name: "iCloud", root: "/icloud"), (name: "Clients", root: "/home/Documents/Clients")]
        #expect(DestinationPlace.closestOwner(of: "/home/Documents/Clients", among: sources, links: links)?.name == "Clients")
        #expect(DestinationPlace.closestOwner(of: "/home/Documents/Clients/Acme", among: sources, links: links)?.name == "Clients")
        #expect(DestinationPlace.closestOwner(of: "/home/Documents/Travel", among: sources, links: links)?.name == "iCloud")
        #expect(DestinationPlace.closestOwner(of: "/home/Downloads", among: sources, links: links) == nil)
        // A root that normalized to nothing (the startup disk) owns nothing.
        #expect(DestinationPlace.closestOwner(of: "/home/x", among: [(name: "Mac", root: "")], links: links) == nil)
    }

    /// Each folder once across the rail, where it first appears; emptied sections go.
    @Test func testEachFolderAppearsOnceInTheRail() {
        func place(_ path: String) -> DestinationPlace { DestinationPlace(name: path, path: path, root: "/p", rootName: "P") }
        let sections = [DestinationPlaceSection(title: "Favorites", places: [place("/p/A"), place("/p/B"), place("/p/A")]),
                        DestinationPlaceSection(title: "Locations", places: [place("/p/B")]),
                        DestinationPlaceSection(title: "Recents", places: [place("/p/C"), place("/p/Here")])]
        let out = DestinationPlaceSection.deduplicated(sections, excluding: ["/p/Here"])
        #expect(out.map(\.title) == ["Favorites", "Recents"])
        #expect(out.map { $0.places.map(\.path) } == [["/p/A", "/p/B"], ["/p/C"]])
    }

    /// The column scroll lands on a column boundary: as many whole columns as fit, ending at the last.
    @Test func testTheColumnsOpenOnWholeColumns() {
        #expect(DestinationPicker.firstWholeColumn(count: 5, width: 540, columnWidth: 211) == 3)   // 2 fit
        #expect(DestinationPicker.firstWholeColumn(count: 5, width: 640, columnWidth: 211) == 2)   // 3 fit
        #expect(DestinationPicker.firstWholeColumn(count: 2, width: 900, columnWidth: 211) == 0)   // all fit
        #expect(DestinationPicker.firstWholeColumn(count: 3, width: 100, columnWidth: 211) == 2)   // narrower than one
        #expect(DestinationPicker.firstWholeColumn(count: 0, width: 500, columnWidth: 211) == 0)
        // The slack past the last column is what lets the leading edge land on a boundary.
        #expect(DestinationPicker.trailingSlack(width: 540, columnWidth: 211) == 118)
        #expect(DestinationPicker.trailingSlack(width: 422, columnWidth: 211) == 0)
        #expect(DestinationPicker.trailingSlack(width: 0, columnWidth: 211) == 0)
    }
}
