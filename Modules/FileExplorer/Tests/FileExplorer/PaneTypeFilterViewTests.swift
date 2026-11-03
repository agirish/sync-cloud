import Testing
import SwiftUI
import AppKit
import Foundation
import Sync
@testable import FileExplorer

/// RD70's pane-side pieces: the status bar's count and chip, the filtered-out empty state, the
/// closed folders' pill, and the type list's words. Every expectation is a literal.
@MainActor
@Suite struct PaneTypeFilterViewTests {

    // MARK: - Status bar (TE271)

    private func facts(filtered: Bool) -> PaneStatusFacts {
        PaneStatusFacts(itemCount: filtered ? 28 : 52, cloudOnlyCount: 9,
                        typeFilter: filtered ? .init(totalCount: 52, summary: "Images") : nil)
    }

    @Test func theCountSaysHowManyOfHowManyWhileFiltered() {
        #expect(facts(filtered: true).itemsCaption == "28 of 52 items")
        #expect(facts(filtered: false).itemsCaption == "52 items")
        #expect(facts(filtered: true).accessibilityLabel.hasPrefix("28 of 52 items, filtered to Images"))
    }

    /// The chip survives the narrowest rung: measured, the `.items` strip is wider with it than
    /// without it, at the same count.
    @Test func theChipIsKeptAtTheNarrowestRung() {
        func width(_ facts: PaneStatusFacts, clear: (() -> Void)?) -> CGFloat {
            NSHostingView(rootView: PaneStatusBar(facts: facts, forcedRung: .items, onClearTypeFilter: clear))
                .fittingSize.width
        }
        var plain = facts(filtered: true)
        plain.typeFilter = nil
        let withChip = width(facts(filtered: true), clear: {})
        let without = width(plain, clear: {})
        #expect(withChip > without + 30, "the chip did not draw at the items rung: \(withChip) vs \(without)")
    }

    // MARK: - Empty state (TE274)

    @Test func aFolderTheFilterEmptiedHasItsOwnState() {
        let filter = PaneTypeFilter(families: [.pdfs])
        #expect(PaneEmptyState.classify(treeIsEmpty: true, isLoading: false, providerIsEnabled: true,
                                        rootIsValid: true, hasOnlyHiddenEntries: false,
                                        typeFilterEmptied: filter) == .filteredOut(filter))
        #expect(PaneEmptyState.classify(treeIsEmpty: true, isLoading: true, providerIsEnabled: true,
                                        rootIsValid: true, hasOnlyHiddenEntries: false,
                                        typeFilterEmptied: filter) == .loading, "loading still wins")
        #expect(PaneEmptyState.classify(treeIsEmpty: true, isLoading: false, providerIsEnabled: true,
                                        rootIsValid: true, hasOnlyHiddenEntries: false)
                == .emptyFolder(hasOnlyHiddenEntries: false))
    }

    @Test func theEmptyStateNamesWhatIsMissing() {
        #expect(PaneEmptyState.filteredOutTitle(PaneTypeFilter(families: [.pdfs]), folder: "Downloads")
                == "No PDFs in Downloads")
        #expect(PaneEmptyState.filteredOutTitle(PaneTypeFilter(families: [.pdfs, .images]), folder: "Downloads")
                == "No matching files in Downloads")
        #expect(PaneEmptyState.filteredOutTitle(PaneTypeFilter(), folder: "Downloads") == "Nothing is ticked")
    }

    // MARK: - Folder pills (TE269)

    @Test func aClosedFolderCarriesTheFiltersCount() {
        let decor = PaneTypeFilterDecor(stamp: 4, filter: PaneTypeFilter(families: [.images]),
                                        matchCounts: ["/d/photos": 2, "/d/scans": 1])
        #expect(decor.phrase(forFolder: "/d/photos") == "2 images")
        #expect(decor.phrase(forFolder: "/d/scans") == "1 image")
        #expect(decor.phrase(forFolder: "/d/old") == nil)
        let closed = PaneSearchRowContext.typeFilter("2 images", isExpanded: false)
        #expect(closed.annotation == .typeFilterMatches("2 images"))
        #expect(PaneSearchRowContext.typeFilter("2 images", isExpanded: true).annotation == nil,
                "an open folder's rows already show what the count would say")
        #expect(PaneSearchRowContext.typeFilter(nil, isExpanded: false) == .none)
    }

    @Test func aRunningSearchsCountOutranksTheFilters() {
        let tree = PaneSearchTreeRevealTests.tree()
        let results = PaneSearchResults(side: .left, generation: 1, query: "tax", tree: tree, otherPaths: nil)
        var context = PaneSearchRowContext(results: results, path: "/root/Documents/IRS", isExpanded: false)
        context.typeFilterPhrase = "3 PDFs"
        #expect(context.annotation == .containedMatches(1))
    }

    /// An open column with no rows says "No matching files" only when the filter hid something in
    /// it (G10); a folder that held nothing at all says "Empty", filter or not.
    @Test func aGenuinelyEmptyColumnSaysEmptyUnderAFilter() {
        let decor = PaneTypeFilterDecor(stamp: 4, filter: PaneTypeFilter(families: [.pdfs]), matchCounts: [:],
                                        emptyFolders: ["/d/untitled folder"])
        #expect(!decor.hidesEverything(inFolder: "/d/untitled folder"))
        #expect(decor.hidesEverything(inFolder: "/d/photos"))
        func caption(_ path: String) -> PaneColumnsView.Caption? {
            PaneColumnsView.emptyCaption(rowsEmpty: true, depth: 1, isUnexplored: false, isLoading: false,
                                         isBeingRead: false, typeFiltered: decor.hidesEverything(inFolder: path))
        }
        #expect(caption("/d/untitled folder")?.text == "Empty")
        #expect(caption("/d/photos")?.text == "No matching files")
    }

    @Test func theDecorComparesByStampAndFilterOnly() {
        let a = PaneTypeFilterDecor(stamp: 4, filter: PaneTypeFilter(families: [.images]), matchCounts: ["/x": 1])
        let b = PaneTypeFilterDecor(stamp: 4, filter: PaneTypeFilter(families: [.images]), matchCounts: ["/x": 2])
        let c = PaneTypeFilterDecor(stamp: 5, filter: PaneTypeFilter(families: [.images]), matchCounts: ["/x": 1])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - The type list's words

    private func control(_ filter: PaneTypeFilter?, unexplored: Int = 0, listing: Bool = false) -> PaneTypeFilterControl {
        PaneTypeFilterControl(
            filter: .constant(filter),
            facts: PaneTypeFilterFacts(census: ["jpg": 10, "png": 3, "pdf": 12, "dmg": 1],
                                       unexploredCount: unexplored, itemCountBeforeFilter: 40),
            folderName: "Downloads", isListing: listing)
    }

    @Test func theListOpensOnWhatIsThereAndWhatIsTicked() {
        let popover = PaneTypeFilterPopover(control: control(PaneTypeFilter(extensions: ["mp4"])))
        #expect(popover.families == [.images, .pdfs, .movies, .appsAndInstallers],
                "a ticked .mp4 missing here keeps Movies listed, at 0")
        #expect(popover.scopeLine == "26 files in Downloads and its folders")
        #expect(PaneTypeFilterPopover(control: control(nil)).footnote == nil)
        #expect(PaneTypeFilterPopover(control: control(nil, unexplored: 2, listing: true)).footnote
                == "Still listing, counts may grow. 2 folders not looked inside aren’t counted.")
    }

    @Test func theButtonSaysItsState() {
        #expect(control(nil).help == "Filter by Type")
        #expect(control(nil).accessibilityValue == "Off")
        #expect(control(PaneTypeFilter(families: [.images])).help == "Showing only Images. Click to change.")
        #expect(control(PaneTypeFilter(families: [.images])).accessibilityValue == "Images")
        let allButImages = PaneTypeFilter(families: Set(FileTypeFamily.allCases).subtracting([.images]))
        #expect(control(allButImages).help == "Showing all but Images. Click to change.")
    }
}

/// The type list, drawn and kept (testing law 1: render it and look). Machine-pinned like every
/// reference image here, so CI never reads it.
@MainActor
@Suite(.serialized, .machinePinned(.referenceImages)) struct PaneTypeFilterSnapshotTests {
    @Test func theTypeList() {
        let control = PaneTypeFilterControl(
            filter: .constant(PaneTypeFilter(families: [.pdfs], extensions: ["jpg"])),
            facts: PaneTypeFilterFacts(census: ["jpg": 10, "png": 3, "pdf": 12, "dmg": 1, "zip": 4],
                                       unexploredCount: 1, itemCountBeforeFilter: 40),
            folderName: "Downloads")
        assertViewSnapshot(of: PaneTypeFilterPopover(control: control).padding(1),
                           size: CGSize(width: 302, height: 330), named: "type-list")
    }
}
