import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's overview, in pixels: the offer is a control, not grey text; the findings carry real
/// evidence; and the pane is used. Mounts `OrganizeOverview`, not `LensWorkspaceView`: there a
/// `.borderedProminent` button renders unfilled offscreen, while mounted directly
/// ``OrganizeOverview/runnablePasses`` is exactly the difference between drawing it and not.
/// Pixel tests are `.machinePinned(.pixelSampling)`; the source scan is not.
@MainActor
@Suite(.serialized) struct OrganizeOverviewRenderTests {

    /// The Organize pane's real proportions: a tall column, where an empty lower half shows. A
    /// short canvas would hide it.
    private static let canvas = CGSize(width: 560, height: 900)

    // MARK: Fixture

    private static func section(_ lens: OrganizeLens, _ state: OrganizeOverviewState,
                                blurb: String = "What this lens is about.")
    -> OrganizeOverviewSection {
        OrganizeOverviewSection(lens: lens, blurb: blurb, state: state, isScanning: false)
    }

    /// Duplicates answered, the file pass never run. `examples` is a parameter because one claim is
    /// about how many evidence lines a finding draws, measured by changing how many there are.
    private static func sections(examples: Int) -> [OrganizeOverviewSection] {
        [section(.toFile, .notScanned, blurb: "Loose files and where they belong."),
         section(.duplicates,
                 .findings(count: 722, headline: "722 groups",
                           examples: (0..<examples).map { "clip\($0).mp4 — 2 copies" }),
                 blurb: "Identical content under different names or folders."),
         section(.renames, .notScanned, blurb: "Folders that have drifted."),
         section(.restructure,
                 .findings(count: 1, headline: "1 finding",
                           examples: ["Finance/US/Income Tax — 11 folders, 3 schemes"]),
                 blurb: "Where the tree disagrees with its own habits.")]
    }

    private typealias Mounted = (host: NSHostingView<AnyView>, window: NSWindow)

    private func mount(_ sections: [OrganizeOverviewSection],
                       runnable: Set<OrganizePass> = Set(OrganizePass.allCases),
                       nudge: OrganizeOverview.BacklogNudge? = nil) -> Mounted {
        let subject = OrganizeOverview(
            sections: sections, scopeLabel: nil,
            accent: LiquidGlassHue.blue.accentColor,
            backlogNudge: nudge,
            ledger: OrganizeOverview.Ledger(checksRun: 2, checksTotal: 5),
            runnablePasses: runnable,
            onOpen: { _ in }, onRun: { _ in })
        // `window.layoutIfNeeded()` is deliberately not used: it disarms AppKit's runaway guards,
        // and a fixture that cannot fail is worse than none.
        return ReviewLensHost.mount(subject, size: Self.canvas, passes: 2)
    }

    /// `m` is a parameter so its window outlives the render; a hosting view without one paints blank.
    private func bitmap(_ m: Mounted, _ band: CGRect) -> NSBitmapImageRep? {
        PixelProbe.render(m.host, band)
    }

    private static var fullBand: CGRect { CGRect(origin: .zero, size: canvas) }

    /// Pixels that differ between two renders of the same band. Differing, not inked: an ink tally
    /// can't tell "the button is gone" from "the button moved".
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        return PixelDiff.differingPixels(a, b, tolerance: 0.04)
    }

/// Rows carrying real ink, against a background sampled where content never reaches. Rows, not a
/// pixel tally, which can't tell a tall card from a dense one.
    private func inkedRows(_ rep: NSBitmapImageRep, background: NSColor) -> [Int] {
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            var n = 0
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if PixelProbe.distance(c, background) > 0.04 { n += 1 }
            }
            if n >= 3 { rows.append(y) }
        }
        return rows
    }

    // MARK: The offer is a control, not a caption

/// An unrun pass takes a card of its own, measured against the same screen with that pass answered.
/// `noPassIsOfferedWithoutAWayToRunIt` pins that a card without its button can't be represented.
    @Test(.machinePinned(.pixelSampling)) func anUnrunPassTakesACardOfItsOwn() throws {
        let band = Self.fullBand
        let pending = Self.sections(examples: 3)
        let answered = pending.map {
            OrganizePass.file.lenses.contains($0.lens)
                ? OrganizeOverviewSection(lens: $0.lens, blurb: $0.blurb, state: .clean,
                                          isScanning: false)
                : $0
        }
        let a = try #require(bitmap(mount(pending), band))
        let b = try #require(bitmap(mount(answered), band))
        let bg = try #require(a.colorAt(x: a.pixelsWide - 3, y: a.pixelsHigh - 3))
        let scale = CGFloat(a.pixelsHigh) / band.height
        let grew = CGFloat(inkedRows(a, background: bg).count
                           - inkedRows(b, background: bg).count) / scale
// The card is ~130pt against the one line it replaces; 60 clears that comfortably.
        #expect(grew > 60,
                "an unrun file pass added only \(Int(grew))pt of content — no card drawn")
    }

/// How many rows the card drew, counted off the screen: a diff can't see rows drawn from a
/// hard-coded fallback. Counts the accent bracket on each lens row's leading edge, one per lens,
/// keyed on a row's height by ``accentRowBrackets``.
    @Test(.machinePinned(.pixelSampling)) func theFileCardDrawsOneRowPerLens() throws {
        let mounted = mount(Self.sections(examples: 3))
        let rep = try #require(bitmap(mounted, Self.fullBand))
        let runs = Self.accentRowBrackets(rep)
        #expect(runs.count == OrganizePass.file.lenses.count,
                "the file card drew \(runs.count) lens rows for \(OrganizePass.file.lenses.count) lenses — heights \(runs)")
// One card draws its rows to one height, so runs that disagree are not that card's brackets.
        #expect(!runs.isEmpty, "found no row bracket at all — the detector is measuring nothing")
        #expect((runs.max() ?? 0) - (runs.min() ?? 0) <= 4,
                "the runs counted as rows are \(runs) — differing heights mean this is not one card's brackets")
    }

/// Heights of the vertical accent runs that are a lens row tall (28pt, 56 device pixels), in the
/// column carrying the most of them. A section's accent bar is several rows tall and a meter
/// segment a few points, so 30...120 keeps only the brackets.
    private static func accentRowBrackets(_ rep: NSBitmapImageRep) -> [Int] {
// Bounds wide enough to survive a text-size change and far from the other accent shapes.
        let rowHeights = 30...120
        func isAccent(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y) else { return false }
            return c.blueComponent - c.redComponent > 0.06
        }
        func rowRuns(inColumn x: Int) -> [Int] {
            var runs: [Int] = []
            var start: Int?
// One `colorAt` per pixel: asking twice would double the test's time.
            for y in 0..<rep.pixelsHigh {
                let hit = isAccent(x, y)
                if hit, start == nil { start = y }
                if !hit, let s = start { runs.append(y - s); start = nil }
            }
            if let s = start { runs.append(rep.pixelsHigh - s) }
            return runs.filter { rowHeights.contains($0) }
        }
        return (0..<rep.pixelsWide).map(rowRuns(inColumn:)).max { $0.count < $1.count } ?? []
    }

/// A running pass shows its progress here, and stops offering to start: an unchanged `Run the file
/// pass` under a scan in flight invites a second click.
    @Test(.machinePinned(.pixelSampling)) func aRunningPassReplacesItsOfferWithProgress() throws {
        let band = Self.fullBand
        let idle = Self.sections(examples: 3)
        let running = idle.map {
            OrganizeOverviewSection(lens: $0.lens, blurb: $0.blurb, state: $0.state,
                                    isScanning: OrganizePass.file.lenses.contains($0.lens))
        }
        let a = try #require(bitmap(mount(idle), band))
        let b = try #require(bitmap(mount(running), band))
        let scale = CGFloat(a.pixelsHigh) / band.height
        let points = CGFloat(differingPixels(a, b)) / (scale * scale)
        #expect(points > 600,
                "a scan in flight changed only \(Int(points))pt² — the card still reads idle")
    }

/// Every lens answered, so no pass card is on offer and `runnablePasses` moves only the rows.
    private static func allAnswered() -> [OrganizeOverviewSection] {
        OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, .findings(count: 7, headline: "7 things", examples: ["evidence line"]))
        }
    }

/// A lens that has already answered can re-run its own scan from here, so Duplicates, whose answer
/// ages fastest, can be re-hashed. On a fixture where nothing is pending.
    @Test(.machinePinned(.pixelSampling)) func anAnsweredLensCanRerunItsOwnPass() throws {
        let band = Self.fullBand
        let a = try #require(bitmap(mount(Self.allAnswered()), band))
        let b = try #require(bitmap(mount(Self.allAnswered(), runnable: []), band))
        let scale = CGFloat(a.pixelsHigh) / band.height
        let points = CGFloat(differingPixels(a, b)) / (scale * scale)
// Duplicates and Restructure each gain a control, a rule and a cost line; 600pt² is above noise
// and under the smallest piece on its own.
        #expect(points > 600,
                "no rescan control on an answered row (\(Int(points))pt² moved)")
    }

/// A row says so while its scan runs: the count gives way to a spinner. The withdrawn rescan can't
/// be pinned here, since the spinner meets any threshold without it.
    @Test(.machinePinned(.pixelSampling)) func aRunningLensSaysSoInItsRow() throws {
        let band = Self.fullBand
        let idle = Self.allAnswered()
        let running = idle.map {
            OrganizeOverviewSection(lens: $0.lens, blurb: $0.blurb, state: $0.state,
                                    isScanning: $0.lens == .duplicates)
        }
        let a = try #require(bitmap(mount(idle), band))
        let b = try #require(bitmap(mount(running), band))
        let scale = CGFloat(a.pixelsHigh) / band.height
        let points = CGFloat(differingPixels(a, b)) / (scale * scale)
        #expect(points > 300,
                "a running Duplicates scan left its row unchanged (\(Int(points))pt² moved)")
    }

// No pixel test pins that a scanning row withdraws its rescan (every A/B axis carries a second
// change); `OverviewCardConsistencyTests.aScanInFlightWithdrawsTheRescanAndKeepsTheWayIn` does.

    // MARK: The evidence is real

/// A finding draws every example it is given, up to the limit: one against three, so a view drawing
/// one line fails.
    @Test(.machinePinned(.pixelSampling)) func aFindingDrawsEveryExampleItIsGiven() throws {
        let band = Self.fullBand
        let one = try #require(bitmap(mount(Self.sections(examples: 1)), band))
        let three = try #require(bitmap(mount(Self.sections(examples: 3)), band))
        let bg = try #require(one.colorAt(x: one.pixelsWide - 3, y: one.pixelsHigh - 3))
        let scale = CGFloat(one.pixelsHigh) / band.height
        let grew = CGFloat(inkedRows(three, background: bg).count
                           - inkedRows(one, background: bg).count) / scale
// Two extra lines are ~30pt of inked rows; 18 clears rounding.
        #expect(grew > 18,
                "three examples drew only \(Int(grew))pt more than one — the extra lines are lost")
    }

    /// The limit holds: a lens handing over more examples than the row allows draws no more than
    /// the row allows. Without it Duplicates' 722 groups could unroll into the card.
    @Test(.machinePinned(.pixelSampling)) func aFindingDrawsNoMoreThanTheLimit() throws {
        let band = Self.fullBand
        let atLimit = try #require(bitmap(mount(Self.sections(examples: 3)), band))
        let over = try #require(bitmap(mount(Self.sections(examples: 12)), band))
        #expect(differingPixels(atLimit, over) == 0,
                "12 examples render differently from 3 — the limit is not being applied")
    }

    // MARK: The pane is used

/// The content reaches down the column instead of stopping a fifth of the way: a guard against
/// collapse, not a lock on the design.
    @Test(.machinePinned(.pixelSampling)) func theOverviewFillsMoreThanTheTopOfThePane() throws {
        let band = Self.fullBand
        let rep = try #require(bitmap(mount(Self.sections(examples: 3)), band))
        let bg = try #require(rep.colorAt(x: rep.pixelsWide - 3, y: rep.pixelsHigh - 3))
        let rows = inkedRows(rep, background: bg)
        let scale = CGFloat(rep.pixelsHigh) / band.height
        let reach = CGFloat(try #require(rows.last)) / scale
        #expect(reach > 400,
                "the overview's content stops \(Int(reach))pt into a \(Int(band.height))pt pane")
    }

    // MARK: The backlog nudge (proposal O15)

/// The sentence itself is drawn: two same-height nudges with different sentences, so a blank row
/// of the right height fails.
    @Test(.machinePinned(.pixelSampling)) func theNudgesOwnSentenceIsDrawn() throws {
        func mounted(_ sentence: String) -> Mounted {
            mount(Self.sections(examples: 1),
                  nudge: OrganizeOverview.BacklogNudge(sentence: sentence,
                                                       setUp: {}, dismiss: {}))
        }
        // Same length, same wrapping, so the row's height cannot differ between them.
        let one = try #require(bitmap(mounted("2026 has files but no folders yet in Aaaa/Aaaaaa."),
                                      Self.fullBand))
        let other = try #require(bitmap(mounted("2026 has files but no folders yet in Bbbb/Bbbbbb."),
                                        Self.fullBand))
        #expect(differingPixels(one, other) > 40,
                "the sentence reaches the pixels, not just the space it occupies")
    }

    /// And it stays out of the ledger. `Ledger.derived` takes only the sections and the runnable
    /// passes, so the nudge can't reach the ratio; this pins the drawn tile.
    @Test(.machinePinned(.pixelSampling)) func theNudgeDoesNotTouchTheChecksLedger() throws {
        // The ledger strip is the top band; the nudge renders beneath it.
        let ledgerBand = CGRect(x: 0, y: 0, width: Self.canvas.width, height: 74)
        let without = try #require(bitmap(mount(Self.sections(examples: 1)), ledgerBand))
        let with = try #require(bitmap(
            mount(Self.sections(examples: 1),
                  nudge: OrganizeOverview.BacklogNudge(
                    sentence: "2026 has files but no folders yet in Health/Dental.",
                    setUp: {}, dismiss: {})),
            ledgerBand))
        #expect(differingPixels(without, with) == 0,
                "the checks tile counts checks, and a nudge is not one")
    }
}
