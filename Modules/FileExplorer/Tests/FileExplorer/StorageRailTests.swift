import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Storage's rail — the four places that replaced an empty half-row.
///
/// **Removing the intro button gave Organize's rail 21pt and gave Storage nothing but a hole.**
/// Storage has no lens rail, so the ⓘ *was* row 1's leading half; without it the row was a 27pt
/// band with two controls floated right and its first two-thirds blank, on a card whose height is
/// pinned whatever it holds. The page underneath was already three ranked lists under a treemap,
/// so the hole and the structure to fill it arrived at the same time.
@MainActor
@Suite(.serialized) struct StorageRailTests {

    private static func entry(_ name: String, _ bytes: Int) -> StorageEntry {
        StorageEntry(path: "/root/\(name)", name: name, bytes: bytes,
                     modified: Date(timeIntervalSince1970: 0))
    }

    private static func report(largest: Int, stale: Int, reclaim: Int) -> StorageLensReport {
        StorageLensReport(treemap: [],
                          largest: (0..<largest).map { entry("big\($0)", 3_000_000) },
                          stale: (0..<stale).map { entry("old\($0)", 1_000_000) },
                          reclaimCandidates: (0..<reclaim).map { entry("r\($0)", 2_000_000) },
                          totalBytes: 48_200_000_000)
    }

    @Test("Every section the body draws is a place on the rail, and carries its own count")
    func everySectionIsOnTheRail() {
        // **The defect this is written against had already shipped, in the header it replaced.**
        // `storageSummary` drew a pill for `largest` and one for `reclaimCandidates` and none for
        // `stale`, so "Untouched for a long time" was a full section with its own ranked list that
        // nothing above it ever announced. Building the rail from `allCases` is what makes that
        // unrepeatable: a fourth section is a rail item the day it is added.
        #expect(StorageSection.allCases.count == 3)
        let r = Self.report(largest: 50, stale: 96, reclaim: 18)
        #expect(StorageSection.largest.entries(in: r).count == 50)
        #expect(StorageSection.stale.entries(in: r).count == 96)
        #expect(StorageSection.reclaim.entries(in: r).count == 18)
        // Each maps to a DIFFERENT list — a copy-paste that pointed two cases at one array would
        // pass every count assertion above if they happened to be equal, so they are not.
        let counts = Set(StorageSection.allCases.map { $0.entries(in: r).count })
        #expect(counts.count == 3, "two sections are reading the same list")
    }

    @Test("A rail item is a place, not a heading")
    func theRailTitlesAreShortEnoughToBePlaces() {
        // `title` is a heading over a list and can afford a sentence; a rail item cannot. Nothing
        // enforced that when both came off the same enum, and "Untouched for a long time" on the
        // rail is 129pt of a 417pt budget.
        for section in StorageSection.allCases {
            #expect(section.railTitle.count < section.title.count,
                    "\(section) puts its full heading on the rail")
            #expect(!section.railTitle.contains(" "),
                    "\(section)'s rail title is a phrase — a place wants one word")
        }
    }

    @Test("The rail's glyph table still matches the renderer")
    func theStorageGlyphTableMatchesTheRenderer() throws {
        // Tabulated for the reason `theGlyphTableMatchesTheRenderer` gives — measuring costs ~135µs
        // a symbol on a path that runs per `body` — and pinned here so the numbers cannot rot
        // silently. **A glyph is not its point size**: these are 13, 15 and 16 at 10.5pt, not 10.5.
        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        for section in StorageSection.allCases {
            let drawn = try #require(NSImage(systemSymbolName: section.railSymbol,
                                             accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?.size.width)
            #expect(abs(OrganizeRailMetrics.storageGlyphWidth(section) - drawn) < 0.51,
                    "\(section.railSymbol) renders \(drawn)pt and the table says \(OrganizeRailMetrics.storageGlyphWidth(section))")
        }
    }

    @Test("The rail fits the header it sits in, with every list reporting")
    func theStorageRailFits() {
        // The widest the rail ever gets is the day all three lists report, which is the day it must
        // still fit. Storage's trailing set is Reanalyze and the search toggle — 129pt measured —
        // so this clears with room; the point of asserting it is that Storage's leading half was
        // empty until now, and an unmodelled control on this side of a row is exactly how a 21pt
        // intro button once rode here uncharged.
        let reporting: (StorageSection) -> RailItemState = { _ in .reporting(999) }
        let width = OrganizeRailMetrics.storageLeadingWidth(scale: 1, state: reporting)
        #expect(width < 900 - OrganizeRailMetrics.searchToggleWidth,
                "Storage's rail models \(width)pt and would shed at the 900pt card it is used on")
        // …and it is not trivially small, or the assertion above holds for a rail that draws
        // nothing. Measured 417.8pt with three reporting lists.
        #expect(width > 350, "Storage's rail models \(width)pt — that is not four items")
        // An unscanned rail costs less than a reporting one, or the state is not reaching the model.
        let unscanned = OrganizeRailMetrics.storageLeadingWidth(scale: 1, state: { _ in .notScanned })
        #expect(unscanned < width)
    }

    @Test("Before a scan the rail says it has not looked, rather than claiming zero")
    func theRailDoesNotClaimZeroBeforeAScan() {
        // The rule Organize's rail follows, applied here: a storage lens that has not run cannot
        // say there are no large files. `.notScanned` draws a dot; `.clean` draws nothing; neither
        // draws a `0`.
        let empty = Self.report(largest: 0, stale: 0, reclaim: 0)
        #expect(StorageSection.allCases.allSatisfy { $0.entries(in: empty).isEmpty })
        #expect(OrganizeRailMetrics.stateWidth(.notScanned, scale: 1)
                > OrganizeRailMetrics.stateWidth(.clean, scale: 1),
                "unscanned and clean cost the same width — the dot is not being charged for")
    }
}
