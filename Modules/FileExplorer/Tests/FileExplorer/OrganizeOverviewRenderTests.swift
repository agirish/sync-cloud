import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's overview, in pixels. Model assertions can be right while the screen is mostly empty,
/// so these read the render back. Three claims: the offer is a control, not grey text; the findings
/// carry real evidence, not a sample of one; and the pane is used.
///
/// ## Why this mounts `OrganizeOverview` and not `LensWorkspaceView`
///
/// Through `LensWorkspaceView` the first claim is untestable: a `.borderedProminent` button renders
/// unfilled in an offscreen host, so "is there a filled accent control" reads false with the
/// control on screen. Mounted directly, ``OrganizeOverview/runnablePasses`` is exactly the
/// difference between drawing that button and not, so two renders differ only in the element
/// under test.
///
/// `.machinePinned(.pixelSampling)`, like every suite here that samples a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct OrganizeOverviewRenderTests {

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

    private final class Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(host: NSHostingView<AnyView>, window: NSWindow) {
            self.host = host
            self.window = window
        }
    }

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
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        // Without a window every comparison below reads as zero difference ("nothing painted"),
        // whatever the code did. `window.layoutIfNeeded()` is deliberately not used: it disarms
        // AppKit's runaway guards, and a fixture that cannot fail is worse than none.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window)
    }

    private func bitmap(_ m: Mounted, _ band: CGRect) -> NSBitmapImageRep? {
        m.host.layoutSubtreeIfNeeded()
        guard let rep = m.host.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        m.host.cacheDisplay(in: band, to: rep)
        return rep
    }

    private static var fullBand: CGRect { CGRect(origin: .zero, size: canvas) }

    /// Pixels that differ between two renders of the same band. Differing, not inked: an ink tally
    /// can't tell "the button is gone" from "the button moved".
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        var n = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent),
                                max(abs(p.greenComponent - q.greenComponent),
                                    abs(p.blueComponent - q.blueComponent)))
                if delta > 0.04 { n += 1 }
            }
        }
        return n
    }

    /// Rows carrying real ink, measured against a background sampled where content never reaches.
    /// Rows, not a pixel tally, because an ink count can't tell a tall card from a dense one, and
    /// the claims below are about how far down content reaches and how many lines a card grew by.
    private func inkedRows(_ rep: NSBitmapImageRep, background: NSColor) -> [Int] {
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            var n = 0
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.04 { n += 1 }
            }
            if n >= 3 { rows.append(y) }
        }
        return rows
    }

    // MARK: The offer is a control, not a caption

    /// An unrun pass takes a card of its own. Measured against the same screen with that pass
    /// answered, so the diff is the card itself. The button needs no pixel test:
    /// `noPassIsOfferedWithoutAWayToRunIt` pins `pendingPasses ⊆ runnablePasses`, so a card without
    /// its button can't be represented.
    @Test func anUnrunPassTakesACardOfItsOwn() throws {
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
        // Heading, lede, two lens rows, two dividers and a cost line is ~130pt of card against
        // the one "to file checked · names checked" line it replaces. 60 clears that comfortably.
        #expect(grew > 60,
                "an unrun file pass added only \(Int(grew))pt of content — no card drawn")
    }

    /// How many rows the card drew, counted off the screen, not asked of the model. A diff can't
    /// see a row whose words come from a hard-coded fallback in the view (both renders match), and
    /// the pass's lens list can be right while the view iterates something else. So this counts the
    /// one mark a lens row can't be drawn without, the accent bracket on its leading edge, and
    /// requires one per lens. Other accent ink is on the screen too, so ``accentRowBrackets`` keys
    /// on a row's height (56 device pixels).
    @Test func theFileCardDrawsOneRowPerLens() throws {
        let mounted = mount(Self.sections(examples: 3))
        let rep = try #require(bitmap(mounted, Self.fullBand))
        let runs = Self.accentRowBrackets(rep)
        #expect(runs.count == OrganizePass.file.lenses.count,
                "the file card drew \(runs.count) lens rows for \(OrganizePass.file.lenses.count) lenses — heights \(runs)")
        // A detector reading the wrong shape can land on the right count by luck, and a bare "did
        // it find anything" can't tell. One card draws its rows to one height, so runs that
        // disagree about their height are not that card's brackets.
        #expect(!runs.isEmpty, "found no row bracket at all — the detector is measuring nothing")
        #expect((runs.max() ?? 0) - (runs.min() ?? 0) <= 4,
                "the runs counted as rows are \(runs) — differing heights mean this is not one card's brackets")
    }

    /// Heights of the vertical accent runs that are the height of a lens row, in whichever column
    /// carries the most of them. One per row.
    ///
    /// Not "the column with the most accent pixels": a reporting section draws its own accent bar,
    /// several rows tall, which outvotes the brackets. The row height is the discriminator: a row's
    /// bracket is 28pt (56 device pixels), a section's bar is several rows tall, and a tinted meter
    /// segment is a few points. Accepting 30...120 keeps exactly the first.
    private static func accentRowBrackets(_ rep: NSBitmapImageRep) -> [Int] {
        // A lens row is 28pt tall; the bounds are wide enough to survive a text-size change and
        // far from both other accent shapes on this screen.
        let rowHeights = 30...120
        func isAccent(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y) else { return false }
            return c.blueComponent - c.redComponent > 0.06
        }
        func rowRuns(inColumn x: Int) -> [Int] {
            var runs: [Int] = []
            var start: Int?
            // One `colorAt` per pixel: this walks every pixel of the canvas once per column, and
            // asking twice would double the test's time.
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

    /// A running pass shows its progress here, and stops offering to start. A button that starts
    /// work and leaves the screen unchanged is a dead end, and an unchanged `Run the file pass`
    /// under a scan in flight invites the second click that `rescanFilingButton` disables itself to
    /// prevent.
    @Test func aRunningPassReplacesItsOfferWithProgress() throws {
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

    /// Every lens answered, so no pass card is on offer: the fixture that isolates the rows.
    /// Without it, `runnablePasses` moves both the pass cards and the row controls, and a render
    /// diff couldn't say which it measured.
    private static func allAnswered() -> [OrganizeOverviewSection] {
        OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, .findings(count: 7, headline: "7 things", examples: ["evidence line"]))
        }
    }

    /// A lens that has already answered can re-run its own scan, so Duplicates, whose answer ages
    /// fastest, can be re-hashed from here and not only the file pass. Measured on a fixture where
    /// nothing is pending, so `runnablePasses` moves only the row controls.
    @Test func anAnsweredLensCanRerunItsOwnPass() throws {
        let band = Self.fullBand
        let a = try #require(bitmap(mount(Self.allAnswered()), band))
        let b = try #require(bitmap(mount(Self.allAnswered(), runnable: []), band))
        let scale = CGFloat(a.pixelsHigh) / band.height
        let points = CGFloat(differingPixels(a, b)) / (scale * scale)
        // Two rows earn a control here — Duplicates and Restructure — at roughly 60×18 and
        // 150×18pt of chrome, and since the cost line is priced off the same runnability each of
        // them also gains a rule and a line of small print. 600pt² is well above noise and well
        // under the smallest of those pieces on its own.
        #expect(points > 600,
                "no rescan control on an answered row (\(Int(points))pt² moved)")
    }

    /// A row says so while its scan runs: the count gives way to a spinner rather than a stale
    /// figure in bold. This can't also pin that the rescan control is withdrawn: the spinner
    /// changes the row so much that any threshold catching the button is met without it.
    @Test func aRunningLensSaysSoInItsRow() throws {
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

    // No pixel test here pins that a scanning row withdraws its rescan: runnability also moves the
    // cost line, and `isScanning` turns the count into a spinner, so every A/B axis carries a
    // second change. `OverviewCardConsistencyTests.aScanInFlightWithdrawsTheRescanAndKeepsTheWayIn`
    // pins it on `OrganizeOverview.actions(for:)`, the card's `actions:`, and names which control
    // survives.

    /// Nothing on this screen says “Scan…”, because nothing on it navigates instead of scanning. A
    /// guard against a navigating scan link returning.
    @Test func theOverviewOffersNoNavigatingScanLink() throws {
        let code = try Self.overviewCode()
        #expect(!code.contains("\"Scan…\""),
                "the overview draws a “Scan…” control again — it should name the pass it runs")
        #expect(!code.contains("onScan"),
                "the lens-taking scan callback is back; it navigated rather than scanning")
        // The scan is the point, so prove the check could have failed: the strings it hunts for
        // are in this file, and they are found when the comments are left in.
        let withComments = try Self.overviewSource()
        #expect(withComments.contains("\"Scan…\""),
                "nothing records what this screen used to draw — the guard above proves nothing")
    }

    /// The source with comment lines removed, because the file's comments quote `"Scan…"` and a
    /// scan of the raw text would read prose as code.
    private static func overviewCode() throws -> String {
        try overviewSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func overviewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // FileExplorer (tests)
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // FileExplorer (package)
            .appendingPathComponent("Sources/FileExplorer/OrganizeOverview.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: The evidence is real

    /// A finding draws every example it is given, up to the limit. Measured by changing how many
    /// there are, one against three: a single fixture would be satisfied by a view that drew one
    /// line and ignored the rest.
    @Test func aFindingDrawsEveryExampleItIsGiven() throws {
        let band = Self.fullBand
        let one = try #require(bitmap(mount(Self.sections(examples: 1)), band))
        let three = try #require(bitmap(mount(Self.sections(examples: 3)), band))
        let bg = try #require(one.colorAt(x: one.pixelsWide - 3, y: one.pixelsHigh - 3))
        let scale = CGFloat(one.pixelsHigh) / band.height
        let grew = CGFloat(inkedRows(three, background: bg).count
                           - inkedRows(one, background: bg).count) / scale
        // Two extra monospaced lines at 11.5pt with 2pt spacing are ~30pt of inked rows. 18 clears
        // rounding while staying well under the real figure.
        #expect(grew > 18,
                "three examples drew only \(Int(grew))pt more than one — the extra lines are lost")
    }

    /// The limit holds: a lens handing over more examples than the row allows draws no more than
    /// the row allows. Without it Duplicates' 722 groups could unroll into the card.
    @Test func aFindingDrawsNoMoreThanTheLimit() throws {
        let band = Self.fullBand
        let atLimit = try #require(bitmap(mount(Self.sections(examples: 3)), band))
        let over = try #require(bitmap(mount(Self.sections(examples: 12)), band))
        #expect(differingPixels(atLimit, over) == 0,
                "12 examples render differently from 3 — the limit is not being applied")
    }

    // MARK: The pane is used

    /// The content reaches down the column instead of stopping a fifth of the way. The floor is far
    /// below what the layout produces: a guard against collapse to a near-empty pane, not a
    /// pixel-accurate lock on the design.
    @Test func theOverviewFillsMoreThanTheTopOfThePane() throws {
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

    /// The sentence itself is drawn, not merely a row of the right height. "No nudge" against "a
    /// nudge" only proves the layout got taller, which a blank row would pass. Two nudges of the
    /// same height with different sentences can't be passed that way.
    @Test func theNudgesOwnSentenceIsDrawn() throws {
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

    /// And it renders only when one is due — the row is absent, not blank, with no nudge.
    @Test func theNudgeLineRendersOnlyWhenOneIsDue() throws {
        let without = try #require(bitmap(mount(Self.sections(examples: 1)), Self.fullBand))
        let with = try #require(bitmap(
            mount(Self.sections(examples: 1),
                  nudge: OrganizeOverview.BacklogNudge(
                    sentence: "2026 has files but no folders yet in Health/Dental.",
                    setUp: {}, dismiss: {})),
            Self.fullBand))
        #expect(differingPixels(without, with) > 500,
                "the nudge line takes its own space on the surface")
    }

    /// And it stays out of the ledger, checked where the ledger is computed as well as in the
    /// render. The render alone proves nothing, since `mount` passes a `Ledger` the test builds.
    /// `Ledger.derived` takes only the sections and the runnable passes, so the nudge can't reach
    /// the ratio.
    @Test func theNudgeDoesNotTouchTheChecksLedger() throws {
        // The derivation the workspace uses, over the same sections, is the number that must not
        // move; nothing about a nudge can reach it.
        let counted = OrganizeOverview.Ledger.derived(
            from: Self.sections(examples: 1),
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(counted.checksTotal
                == OrganizeOverview.Ledger.countedLenses(
                    runnablePasses: Set(OrganizePass.allCases)).count,
                "the denominator is the runnable lenses, and a nudge is not a lens")

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
