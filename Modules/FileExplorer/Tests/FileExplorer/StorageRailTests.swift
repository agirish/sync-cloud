import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Storage's four places (All · Largest · Untouched · Reclaim) and the capsule that switches
/// between them, ``StorageSectionBar``, drawn in the content card in the Editor mode bar's idiom.
/// The header's rail slot belongs to the Organize rail, so the header draws one rail with one
/// shedding rule, as `OrganizeRailMetrics` asks. Also pinned: the section-to-list mapping, the "N
/// of M" arithmetic, and the collapse rule.
@MainActor
@Suite(.serialized) struct StorageRailTests {

    private func size<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: AnyView(view)).fittingSize
    }

    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    private func capsule(_ rung: StorageSectionBar.Rung, section: StorageSection? = nil,
                         scale: CGFloat = 1) -> CGSize {
        size(StorageSectionBar(section: .constant(section), accentFill: .blue, onAccent: .white,
                               forcedRung: rung)
            .environment(\.appFontScale, scale))
    }

    private static func entry(_ name: String, _ bytes: Int) -> StorageEntry {
        StorageEntry(path: "/root/\(name)", name: name, bytes: bytes,
                     modified: Date(timeIntervalSince1970: 0))
    }

    private static func report(largest: Int, stale: Int, reclaim: Int) -> StorageLensReport {
        StorageLensReport(treemap: [],
                          largest: (0..<largest).map { entry("big\($0)", 3_000_000) },
                          stale: (0..<stale).map { entry("old\($0)", 1_000_000) },
                          reclaimCandidates: (0..<reclaim).map { entry("r\($0)", 2_000_000) },
                          totalBytes: 48_200_000_000, fileCount: largest, staleCount: stale,
                          reclaimCount: reclaim, reclaimableBytes: reclaim * 2_000_000)
    }

    @Test("Every section the body draws is a place on the rail, and carries its own count")
    func everySectionIsOnTheRail() {
        // Built from `allCases`, so no section can be a full ranked list that nothing above it
        // announces: a new section is a rail item the day it is added.
        #expect(StorageSection.allCases.count == 3)
        let r = Self.report(largest: 50, stale: 96, reclaim: 18)
        #expect(StorageSection.largest.entries(in: r).count == 50)
        #expect(StorageSection.stale.entries(in: r).count == 96)
        #expect(StorageSection.reclaim.entries(in: r).count == 18)
        // Each maps to a different list: two cases pointed at one array would pass every count
        // above if the counts were equal, so they aren't.
        let counts = Set(StorageSection.allCases.map { $0.entries(in: r).count })
        #expect(counts.count == 3, "two sections are reading the same list")
    }

    @Test("A rail item is a place, not a heading")
    func theRailTitlesAreShortEnoughToBePlaces() {
        // `title` is a heading over a list and can afford a sentence; a rail item can't, though
        // both come off the same enum.
        for section in StorageSection.allCases {
            #expect(section.railTitle.count < section.title.count,
                    "\(section) puts its full heading on the rail")
            #expect(!section.railTitle.contains(" "),
                    "\(section)'s rail title is a phrase — a place wants one word")
        }
    }

    @Test("Every section the capsule offers still resolves to a symbol")
    func everySectionsGlyphResolves() throws {
        // `CapsuleGlyph` frames every glyph at one width, scaled with the text size, so symbol
        // widths enter no model. What a frame can't fix is a symbol that doesn't resolve: it draws
        // nothing, and on a shed rung the glyph is the only thing naming the section.
        for section in StorageSection.allCases {
            #expect(NSImage(systemSymbolName: section.railSymbol, accessibilityDescription: nil) != nil,
                    "\(section.railSymbol) does not resolve — on the glyph-only rung this segment is unnamed")
        }
        // "All" is not a StorageSection, so its symbol lives on the bar and is checked separately.
        #expect(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) != nil)
    }

    @Test("The capsule is one width whichever section is selected")
    func theCapsuleIsOneWidthWhicheverSectionIsSelected() {
        // Weight changes width, so a semibold selected segment among medium ones would resize the
        // capsule on every click and move everything beside it, as `EditorModeBar` also guards.
        // Semibold in both states; the fill marks the selection.
        for rung in [StorageSectionBar.Rung.labelled, .glyphOnly] {
            let widths = ([nil] + StorageSection.allCases.map { Optional($0) })
                .map { capsule(rung, section: $0).width }
            #expect(Set(widths.map { ($0 * 100).rounded() }).count == 1,
                    "the \(rung) capsule measures \(widths) across the four selections")
        }
    }

    @Test("The labelled rung is the wider one it sheds from")
    func theLabelledRungIsTheWiderOneItShedsFrom() {
        // Or `ViewThatFits` chooses between two rungs that cost the same, and shedding the words
        // buys nothing.
        for scale in scales {
            let labelled = capsule(.labelled, scale: scale).width
            let glyphs = capsule(.glyphOnly, scale: scale).width
            #expect(labelled > glyphs + 40,
                    "at scale \(scale) the rungs measure \(labelled) and \(glyphs) — shedding the words buys almost nothing")
        }
    }

    @Test("Both rungs grow with the app's text size")
    func bothRungsGrowWithTheAppsTextSize() {
        // Without this every ceiling above is vacuous: a control pinned at one size passes any
        // width assertion at the size it was tuned for. Asked of both rungs: the labelled one
        // scales through its `Text`, but the glyph rung scales only if `CapsuleGlyph`'s frame does,
        // rather than a hard frame the enlarged glyph overflows.
        for rung in [StorageSectionBar.Rung.labelled, .glyphOnly] {
            let widths = scales.map { capsule(rung, scale: $0).width }
            #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 },
                    "the \(rung) capsule measures \(widths) across \(scales) — it shrinks as the text grows")
            #expect((widths.last ?? 0) > (widths.first ?? 0),
                    "the \(rung) capsule measures \(widths) across \(scales) — it is not scaling")
        }
    }

    @Test("The capsule fits the content card at the window's floor, at every text size")
    func theCapsuleFitsTheNarrowestContentCard() {
        // The lens column's floor is 340pt, `PaneLogic.minLensWorkspaceWidth`, which lives in
        // MacApp out of this package's reach, so it is a literal here as in `OrganizeRailTests` and
        // `OrganizeRailOverflowTests`; the card's chrome comes off first, as there. At least one
        // rung must clear it at every text size, or `ViewThatFits` has nothing to fall back to and
        // SwiftUI draws the last rung overflowing.
        let usable = 340 - OrganizeRailMetrics.cardChrome
        for scale in scales {
            let glyphs = capsule(.glyphOnly, scale: scale).width
            #expect(glyphs < usable,
                    "at scale \(scale) even the glyph-only capsule is \(glyphs)pt against \(usable)pt of usable card at the 340pt lens column — it has nothing left to shed")
        }
    }

    @Test("“N of M” follows the rail, not the whole report")
    func theOfMCountsFollowTheRail() {
        // The counts follow the selection, as a pure function. A sum of all three ranked lists
        // describes a page nobody is looking at once a section is selected: on Largest with a
        // query showing 3 of its 50, the row would read "3 of 164", counting lists not on screen.
        let r = Self.report(largest: 50, stale: 96, reclaim: 18)

        // No selection: every list, as before. This half is what stops a fix to the half below
        // being a change to the All page as well.
        let all = StorageSection.counts(in: r, section: nil) { _ in true }
        #expect(all.total == 164)
        #expect(all.filtered == 164)

        // Selected: that list alone, on both numbers. Narrowing only the numerator would read
        // "50 of 164", still describing a page that is not on screen.
        let largest = StorageSection.counts(in: r, section: .largest) { _ in true }
        #expect(largest.total == 50, "M is still the whole report — the denominator describes lists the rail is not showing")
        #expect(largest.filtered == 50)
        #expect(StorageSection.counts(in: r, section: .stale) { _ in true }.total == 96)
        #expect(StorageSection.counts(in: r, section: .reclaim) { _ in true }.total == 18)

        // The query still narrows within the selection: N is the rows on screen, M is that list
        // before the search. Each section's fixture names its entries differently, so this
        // predicate keeps 50 of Largest and none of the others; a filter leaking across sections
        // would show a total that isn't 50.
        let searched = StorageSection.counts(in: r, section: .largest) { $0.name.hasPrefix("big") }
        #expect(searched == (filtered: 50, total: 50))
        let missing = StorageSection.counts(in: r, section: .largest) { $0.name.hasPrefix("old") }
        #expect(missing == (filtered: 0, total: 50),
                "the query narrowed the denominator too — M must be the list before the search")
    }

    /// Whole-line `//` comments removed, so a scan for what the code does can't be satisfied or
    /// falsified by the prose describing it. Only for the negative checks, per the convention in
    /// `OrganizeScopeCallSiteTests`.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("A fold made on the All page cannot empty a section the rail selected")
    func collapsingAppliesToTheAllPageOnly() throws {
        // The rail and the fold both hide a list, so together they could hide it twice:
        // `collapsed` is `@State` and survives a rail selection, so a section folded on the All
        // page would open, once selected, as one collapsed header and nothing else. The fold is for
        // triaging three lists stacked under a treemap; narrowed to one, it doesn't apply. Asserted
        // on the source because `collapsed` is view state with no seam.
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
        // Gating the read is only half. `isCollapsed` is false by construction on a narrowed page,
        // so a header action there would always take the `insert` arm: nothing visible where it was
        // clicked, the section folded on the All page instead, and no click there to undo it. So
        // on a narrowed page the header is a plain row, not a button, and draws no chevron.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/StorageLensView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read StorageLensView.swift — this scan would be vacuous")
        try #require(source.count > 500, "StorageLensView.swift is implausibly short")
        // The write is unreachable because the Button is: the header is only wrapped in one where
        // the fold applies, and the same row is drawn plain otherwise.
        #expect(source.contains("if canCollapse {\n                Button {"),
                "the header is a button on a page where the fold does not apply")
        #expect(source.contains("canCollapse: false, isCollapsed: false)"),
                "a narrowed page draws no plain header row")
        // Not a disabled button: that still announces an unavailable control and costs Full
        // Keyboard Access a stop, and the title, caption and count are reachable only through it.
        #expect(!Self.codeOnly(source).contains(".disabled(!canCollapse)"),
                "the narrowed header is a disabled button rather than a plain row")
        // The chevron follows the parameter the caller passes, not a re-read of the view's own
        // `section` through a shadowing name.
        #expect(source.contains("canCollapse: Bool, isCollapsed: Bool"),
                "the header row re-derives whether it can fold instead of being told")
        #expect(source.contains("            if canCollapse {\n                Image(systemName: isCollapsed"),
                "the chevron is still drawn on a page that cannot fold")
    }

    @Test("Before a scan there is no switcher at all, rather than one claiming zero")
    func theCapsuleIsAbsentBeforeAScan() throws {
        // A storage lens that hasn't run can't say there are no large files. The capsule carries no
        // counts (they live in the header's row-2 pills), so it isn't drawn until a report exists:
        // four segments over an intro card would offer places that don't exist yet.
        let empty = Self.report(largest: 0, stale: 0, reclaim: 0)
        #expect(StorageSection.allCases.allSatisfy { $0.entries(in: empty).isEmpty })

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/StorageLensView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read StorageLensView.swift — this scan would be vacuous")
        // Asserted on the source because the arm is a `@ViewBuilder` branch with no seam to ask.
        // Adjacency, not membership: the bar must sit immediately above `reportBody`, inside the
        // `let report` arm; "the file mentions sectionBar" would pass with the bar hoisted above
        // the whole `if`.
        #expect(source.contains("                sectionBar\n                reportBody(report)"),
                "the switcher is not immediately above the report body — it may now draw over the intro or building states, offering sections that do not exist yet")
        // Exactly two mentions: the declaration and that single use. A third is a second draw site,
        // which is how it would creep back onto a page with no report.
        #expect(source.components(separatedBy: "sectionBar").count - 1 == 2,
                "sectionBar is referenced more than the once it is declared and the once it is drawn")
    }

    @Test("A section pill says how many the tree has when the list is only its top")
    func aSectionPillCountsTheTreeBeyondTheCappedList() throws {
        // The pill counts the tree, not the 20-row list, so "Untouched" can't read 20 under an
        // Overview headline of 318. Each section's total is the tree's own.
        let r = StorageLensReport(treemap: [],
                                  largest: (0..<20).map { Self.entry("big\($0)", 3_000_000) },
                                  stale: (0..<20).map { Self.entry("old\($0)", 1_000_000) },
                                  reclaimCandidates: (0..<4).map { Self.entry("r\($0)", 2_000_000) },
                                  totalBytes: 1, fileCount: 1_640, staleCount: 318,
                                  reclaimCount: 4, reclaimableBytes: 8_000_000)
        #expect(StorageSection.largest.total(in: r) == 1_640)
        #expect(StorageSection.stale.total(in: r) == 318)
        #expect(StorageSection.reclaim.total(in: r) == 4)

        let capped = StorageSection.PillCount(shown: 20, listed: 20, total: 318)
        #expect(capped.text == "20 of 318")
        #expect(capped.speech == "20 of 318 files")
        #expect(StorageSection.PillCount(shown: 20, listed: 20, total: 1_640).text
                == "20 of \(1_640.formatted())")
        // Nothing was cut: the bare count.
        #expect(StorageSection.PillCount(shown: 4, listed: 4, total: 4).text == "4")
        // A report saved before the totals existed: the bare count, never a guess.
        #expect(StorageSection.PillCount(shown: 20, listed: 20, total: nil).text == "20")
        // A search narrows the 20 listed, not the tree: the matches alone.
        let searching = StorageSection.PillCount(shown: 3, listed: 20, total: 318)
        #expect(searching.text == "3")
        #expect(searching.speech == "3 files")
        #expect(StorageSection.PillCount(shown: 1, listed: 20, total: 318).speech == "1 file")

        // And the header draws it — from the section's own list and total, not the shown rows.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/StorageLensView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read StorageLensView.swift — this scan would be vacuous")
        #expect(source.contains("let count = StorageSection.PillCount(shown: entries.count,\n"
                                + "                                             listed: section.entries(in: report).count,\n"
                                + "                                             total: section.total(in: report))"))
        #expect(source.contains("Pill(.mini, tint: .secondary, text: count.text, isNumeric: true)\n"
                                + "                .accessibilityLabel(count.speech)"))
        #expect(!source.contains("text: count.formatted(), isNumeric: true"),
                "the section pill is counting the list again")
    }
}
