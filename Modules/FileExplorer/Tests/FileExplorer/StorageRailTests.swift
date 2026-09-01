import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Storage's four sections — the places, and the capsule that switches between them.
///
/// **These were a rail in the header until Storage folded into Organize.** While Storage was a
/// workspace, `LensHeaderCard`'s rail slot was free and Storage borrowed it for All · Largest ·
/// Untouched · Reclaim. The fold gives that slot to the Organize rail, so the switcher moved down
/// into the content card as a capsule (``StorageSectionBar``) — the idiom the Editor's mode bar
/// established — and the header now draws one rail with one shedding rule, which is what
/// `OrganizeRailMetrics`' own comment asked for all along.
///
/// What did **not** change is everything below: the section-to-list mapping, the "N of M"
/// arithmetic, and the collapse rule. Those tests are untouched on purpose — the switcher moved,
/// the sections did not.
@MainActor
@Suite(.serialized) struct StorageRailTests {

    private func size<V: View>(_ view: V) -> CGSize {
        NSHostingView(rootView: AnyView(view)).fittingSize
    }

    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    private func capsule(_ rung: StorageSectionBar.Rung, section: StorageSection? = nil,
                         scale: CGFloat = 1) -> CGSize {
        size(StorageSectionBar(section: .constant(section), accent: .blue, onAccent: .white,
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

    @Test("Every section the capsule offers still resolves to a symbol")
    func everySectionsGlyphResolves() throws {
        // **This replaced a glyph-width table, and the replacement is the point.** The rail
        // tabulated each symbol's rendered width (13, 15 and 16 at 10.5pt) because its arithmetic
        // had to reserve room per item, and a wrong number there sheds the row early or overruns
        // it. `CapsuleGlyph` frames every glyph at one width — scaled with the text size, but the
        // same for all four symbols — so the widths no longer enter any model. What remains is the
        // one thing a frame cannot fix: a symbol that does not resolve
        // draws nothing at all, and on a shed rung the glyph is the ONLY thing naming the section.
        for section in StorageSection.allCases {
            #expect(NSImage(systemSymbolName: section.railSymbol, accessibilityDescription: nil) != nil,
                    "\(section.railSymbol) does not resolve — on the glyph-only rung this segment is unnamed")
        }
        // "All" is not a StorageSection, so its symbol lives on the bar and is checked separately —
        // exactly the gap that once let the overview item ride the Organize rail uncounted.
        #expect(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) != nil)
    }

    @Test("The capsule is one width whichever section is selected")
    func theCapsuleIsOneWidthWhicheverSectionIsSelected() {
        // The bug `EditorModeBar` records and this control inherits the fix for: the selected
        // segment was semibold and the rest medium, weight changes width, so the capsule measured
        // differently depending on which segment was live — and everything beside it moved on every
        // click. Semibold in both states; the fill is what marks the selection.
        for rung in [StorageSectionBar.Rung.labelled, .glyphOnly] {
            let widths = ([nil] + StorageSection.allCases.map { Optional($0) })
                .map { capsule(rung, section: $0).width }
            #expect(Set(widths.map { ($0 * 100).rounded() }).count == 1,
                    "the \(rung) capsule measures \(widths) across the four selections")
        }
    }

    @Test("The labelled rung is the wider one it sheds from")
    func theLabelledRungIsTheWiderOneItShedsFrom() {
        // Or `ViewThatFits` is choosing between two rungs that cost the same, and shedding the
        // words buys nothing — which would make the fallback decorative.
        for scale in scales {
            let labelled = capsule(.labelled, scale: scale).width
            let glyphs = capsule(.glyphOnly, scale: scale).width
            #expect(labelled > glyphs + 40,
                    "at scale \(scale) the rungs measure \(labelled) and \(glyphs) — shedding the words buys almost nothing")
        }
    }

    @Test("Both rungs grow with the app's text size")
    func bothRungsGrowWithTheAppsTextSize() {
        // The failure that would make every ceiling above vacuous: a control pinned at one size
        // passes any width assertion at the size it was tuned for.
        //
        // **Asked of the glyph-only rung too, because that is the one that was pinned.** This
        // measured the labelled rung alone — which scales, since its words are `Text` — and stayed
        // green over a glyph rung stuck at 113pt at all four sizes, its symbols in a hard `13×13`
        // frame that the enlarged glyph simply overflowed. Inherited from `EditorModeBar` along
        // with everything else this bar copied; fixed in both, in `CapsuleGlyph`.
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
        // Where it now has to fit. The lens column's floor is **340pt** — `PaneLogic.minLensWorkspace-
        // Width`, which lives in MacApp and is unreachable from this package, so the number is a
        // literal here exactly as it is in `OrganizeRailTests` and `OrganizeRailOverflowTests`. The
        // capsule sits inside the content card rather than in the header, so the question the rail
        // used to answer against row 1's reserve is asked here against the card — and the card's own
        // chrome comes off first, which is what those neighbouring tests do too. At least one rung
        // must clear it at every text size, or `ViewThatFits` has nothing to fall back to and
        // SwiftUI draws the LAST rung overflowing.
        let usable = 340 - OrganizeRailMetrics.cardChrome
        for scale in scales {
            let glyphs = capsule(.glyphOnly, scale: scale).width
            #expect(glyphs < usable,
                    "at scale \(scale) even the glyph-only capsule is \(glyphs)pt against \(usable)pt of usable card at the 340pt lens column — it has nothing left to shed")
        }
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

    /// Whole-line `//` comments removed — a scan for what the code does must not be satisfied or
    /// falsified by the prose describing it. Only for the negative checks, per the convention in
    /// `OrganizeScopeCallSiteTests`.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
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
        // The write is unreachable because the Button is: the header is only wrapped in one where
        // the fold applies, and the same row is drawn plain otherwise.
        #expect(source.contains("if canCollapse {\n                Button {"),
                "the header is a button on a page where the fold does not apply")
        #expect(source.contains("canCollapse: false, isCollapsed: false)"),
                "a narrowed page draws no plain header row")
        // Not a DISABLED button — that still announces an unavailable control and still costs
        // Full Keyboard Access a stop, and the title, caption and count are only reachable
        // through it.
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
        // **The rail answered this with a dot; the capsule answers it by not being there.** A
        // storage lens that has not run cannot say there are no large files — the rail said so with
        // `.notScanned` where a badge would go. The capsule carries no counts (they live in the
        // header's row-2 pills, unchanged by the fold), so the honest form of the same rule is that
        // it is not drawn until a report exists: there is nothing to switch between, and four
        // segments over an intro card would offer places that do not yet exist.
        let empty = Self.report(largest: 0, stale: 0, reclaim: 0)
        #expect(StorageSection.allCases.allSatisfy { $0.entries(in: empty).isEmpty })

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/StorageLensView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read StorageLensView.swift — this scan would be vacuous")
        // Asserted on the source because the arm is a `@ViewBuilder` branch with no seam to ask.
        // **Adjacency, not membership**: the bar has to sit immediately above `reportBody`, which
        // places it inside the `let report` arm and nowhere else. A looser "the file mentions
        // sectionBar" would pass with the bar hoisted above the whole `if`, which is exactly the
        // mistake — four segments over an intro card, offering places that do not exist yet.
        #expect(source.contains("                sectionBar\n                reportBody(report)"),
                "the switcher is not immediately above the report body — it may now draw over the intro or building states, offering sections that do not exist yet")
        // Exactly two mentions: the declaration and that single use. A third is a second draw site,
        // which is how it would creep back onto a page with no report.
        #expect(source.components(separatedBy: "sectionBar").count - 1 == 2,
                "sectionBar is referenced more than the once it is declared and the once it is drawn")
    }
}
