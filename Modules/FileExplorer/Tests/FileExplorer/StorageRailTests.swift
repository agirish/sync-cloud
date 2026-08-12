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

    @Test("“N of M” follows the rail, not the whole report")
    func theOfMCountsFollowTheRail() {
        // **The regression the rail introduced, and the reason this arithmetic is a pure function.**
        // The header summed all three ranked lists unconditionally — correct while the page was
        // always all three. Once a section could be selected the sum described a page nobody was
        // looking at: standing on Largest with a query showing 3 of its 50, the row read "3 of
        // 164", a denominator drawn from two lists that were not on screen. That is the same
        // dishonesty the scope work removed from the Organize lenses, arriving through the rail.
        let r = Self.report(largest: 50, stale: 96, reclaim: 18)

        // No selection: every list, as before. This half is what stops a fix to the half below
        // being a change to the All page as well.
        let all = StorageSection.counts(in: r, section: nil) { _ in true }
        #expect(all.total == 164)
        #expect(all.filtered == 164)

        // Selected: that list alone, on BOTH numbers. A fix that narrowed only the numerator would
        // read "50 of 164" — still describing a page that is not on screen.
        let largest = StorageSection.counts(in: r, section: .largest) { _ in true }
        #expect(largest.total == 50, "M is still the whole report — the denominator describes lists the rail is not showing")
        #expect(largest.filtered == 50)
        #expect(StorageSection.counts(in: r, section: .stale) { _ in true }.total == 96)
        #expect(StorageSection.counts(in: r, section: .reclaim) { _ in true }.total == 18)

        // And the query still narrows within the selection: N is the rows on screen, M is that list
        // before the transient narrowing. Each section's fixture names its entries differently, so
        // this predicate keeps 50 of Largest and none of the other two — a filter that leaked
        // across sections would show up as a total that is not 50.
        let searched = StorageSection.counts(in: r, section: .largest) { $0.name.hasPrefix("big") }
        #expect(searched == (filtered: 50, total: 50))
        let missing = StorageSection.counts(in: r, section: .largest) { $0.name.hasPrefix("old") }
        #expect(missing == (filtered: 0, total: 50),
                "the query narrowed the denominator too — M must be the list before the search")
    }

    @Test("A fold made on the All page cannot empty a section the rail selected")
    func collapsingAppliesToTheAllPageOnly() throws {
        // **The rail and the fold are two ways to hide the same list, and together they hid it
        // twice.** `collapsed` is `@State` on the view and survives a rail selection, so folding
        // "Untouched" on the All page and then clicking Untouched on the rail produced a page with
        // one collapsed header and nothing else — the thing you just asked for, hidden by a
        // decision made somewhere else, with no hint that the fold was why.
        //
        // The fold is for triaging three lists stacked under a treemap. Narrowed to one, there is
        // nothing to get past, so it does not apply. Asserted on the source because `collapsed` is
        // view state with no seam: what matters is that the condition consults the *selection*.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/StorageLensView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read StorageLensView.swift — this scan would be vacuous")
        #expect(source.contains("let canCollapse = self.section == nil"),
                "the fold no longer consults the rail's selection, so selecting a folded section shows an empty page")
        #expect(source.contains("let isCollapsed = canCollapse && collapsed.contains(section)"))
        // Non-vacuity: the fold still exists and is still a thing the All page can do.
        #expect(source.contains("collapsed.insert(section)"))
    }

    @Test("The header cannot fold a section it is not allowed to fold")
    func aNarrowedPagesHeaderNeitherWritesNorInvitesAClick() throws {
        // **Gating the read was only half of it.** `isCollapsed` is false by construction on a
        // narrowed page, so the header's action always took the `insert` arm: the click did
        // nothing visible where it was made — chevron still down, list still open — and folded the
        // section on the All page, where the user never folded anything. No second click on the
        // narrowed page could undo it, because that one inserted too.
        //
        // Both halves are asserted: the action refuses, and the control stops advertising. The
        // chevron goes (there is nothing to point at) and the row is `.disabled`, which under
        // `HoverAffordanceStyle` suppresses exactly the hover wash and draws no dimming — so the
        // header still looks like a header and simply stops lighting up.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/StorageLensView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read StorageLensView.swift — this scan would be vacuous")
        try #require(source.count > 500, "StorageLensView.swift is implausibly short")
        #expect(source.contains("guard canCollapse else { return }"),
                "the header's action still writes `collapsed` on a page where the fold does not apply")
        #expect(source.contains(".disabled(!canCollapse)"),
                "a narrowed page's header still offers a hover affordance for a fold it will not perform")
        #expect(source.contains("if canCollapse {"),
                "the chevron is still drawn on a page that cannot fold")
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
