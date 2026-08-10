import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's overview, in pixels.
///
/// **The defect this suite exists for was a screenshot, not a failing test.** The overview drew two
/// findings and then stopped, roughly 200pt down a column of about a thousand, and what filled the
/// rest was nothing. Every assertion about that screen was satisfied: the sections were right, the
/// counts were scoped, the three states were kept apart. Emptiness is not a property any of them
/// could see, and it is the property the user reported.
///
/// So these read the render back. Three claims: **the offer is a control** and not the tertiary
/// grey text it replaced, **the findings carry real evidence** rather than a sample of size one,
/// and **the pane is used**.
///
/// ## Why this mounts `OrganizeOverview` and not `TidyView`
///
/// Both were tried. Through `TidyView` the first claim is untestable: a `.borderedProminent` button
/// renders *unfilled* in an offscreen host — confirmed by writing the render out and looking at it,
/// which is also how the cost line was caught rendering as illegible tertiary grey — so "is there a
/// filled accent control" reads false with the control plainly on screen. Mounting the view
/// directly gives the claim a seam it can use: ``OrganizeOverview/runnablePasses`` is exactly the
/// difference between drawing that button and not, so the two renders differ in the one element
/// under test and in nothing else.
///
/// `.machinePinned(.pixelSampling)`, like every suite here that samples a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct OrganizeOverviewRenderTests {

    /// The Organize pane's real proportions — a tall column, which is the shape that made the old
    /// screen's emptiness visible in the first place. A short canvas would hide it.
    private static let canvas = CGSize(width: 560, height: 900)

    // MARK: Fixture

    private static func section(_ lens: OrganizeLens, _ state: OrganizeOverviewState,
                                blurb: String = "What this lens is about.")
    -> OrganizeOverviewSection {
        OrganizeOverviewSection(lens: lens, blurb: blurb, state: state, isScanning: false)
    }

    /// The state in the report: Duplicates answered, the file pass never run.
    ///
    /// `examples` is a parameter because one of the claims is about how many evidence lines a
    /// finding draws, and that can only be measured by changing how many there are to draw.
    private static func sections(examples: Int) -> [OrganizeOverviewSection] {
        [section(.toFile, .notScanned, blurb: "Loose files and where they belong."),
         section(.duplicates,
                 .findings(count: 722, headline: "722 groups",
                           examples: (0..<examples).map { "clip\($0).mp4 — 2 copies" }),
                 blurb: "Identical content under different names or folders."),
         section(.names, .notScanned, blurb: "Names this provider will not accept."),
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
                       runnable: Set<OrganizePass> = Set(OrganizePass.allCases)) -> Mounted {
        let subject = OrganizeOverview(
            sections: sections, scopeLabel: nil,
            accent: LiquidGlassHue.blue.accentColor,
            ledger: OrganizeOverview.Ledger(checksRun: 2, checksTotal: 5),
            runnablePasses: runnable,
            onOpen: { _ in }, onRun: { _ in })
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        // Without a window the content composites against the borderless window's own buffer and
        // every comparison below reads as zero difference — "nothing painted", whatever the code
        // did. `window.layoutIfNeeded()` is deliberately not used: it disarms AppKit's runaway
        // guards, and a fixture that cannot fail is worse than no fixture.
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

    /// Pixels that differ between two renders of the same band.
    ///
    /// **Differing pixels, not inked ones.** An ink tally cannot tell "the button is gone" from
    /// "the button moved", and what is under test here is a single element appearing.
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
    ///
    /// Rows rather than a raw pixel tally: **an ink count cannot tell a tall card from a dense
    /// one**, and the claims below are about how far down the column content reaches and how many
    /// lines a card grew by.
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

    /// **An unrun pass takes a card, where three tertiary footnotes used to sit.**
    ///
    /// Measured against the same screen with that pass answered, so what the diff contains is the
    /// card itself rather than some property of the fixture.
    ///
    /// **This was once phrased as a claim about the button** — runnable versus not-runnable, on the
    /// theory that `runnablePasses` moved only the control. Review made that false and better:
    /// `pendingPasses` is now gated on runnability, so a non-runnable pass draws no card at all and
    /// the old A/B silently began measuring the whole card while still being named for the button.
    /// The button's presence needs no pixel test now — `noPassIsOfferedWithoutAWayToRunIt` pins
    /// `pendingPasses ⊆ runnablePasses` directly, which makes a card without its button
    /// unrepresentable rather than merely untested.
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
        // Heading, lede, three lens rows, two dividers and a cost line is ~150pt of card against
        // the one "to file checked · names checked" line it replaces. 60 clears that comfortably.
        #expect(grew > 60,
                "an unrun file pass added only \(Int(grew))pt of content — no card drawn")
    }

    /// **A running pass shows its progress here, and stops offering to start.**
    ///
    /// Half the point of moving the scan onto this screen is that its progress lands here too — a
    /// button that starts work and then hands you an unchanged screen is the same dead end as one
    /// that navigates. The other half is that the offer must go while it runs: an unchanged
    /// `Run the file pass` under a scan already in flight invites the second click that
    /// `rescanFilingButton` disables itself to prevent.
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

    /// Every lens answered, so no pass card is on offer — the fixture that isolates the *rows*.
    ///
    /// Without this, `runnablePasses` moves two things at once (the pass cards and the row
    /// controls), and a render diff could not say which of them it had measured.
    private static func allAnswered() -> [OrganizeOverviewSection] {
        OrganizeLens.allCases.filter(\.carriesBadge).map {
            section($0, .findings(count: 7, headline: "7 things", examples: ["evidence line"]))
        }
    }

    /// **A lens that has already answered can re-run its own scan.**
    ///
    /// The gap this closes: the only scan control on the overview beside the pass cards was row 2's
    /// Rescan, which runs the *file* pass alone — so Duplicates could be read from here but never
    /// re-hashed, which is the pass whose answer ages fastest.
    ///
    /// Measured against a fixture where nothing is pending, so the pass cards are out of the
    /// picture and `runnablePasses` moves only the row controls.
    @Test func anAnsweredLensCanRerunItsOwnPass() throws {
        let band = Self.fullBand
        let a = try #require(bitmap(mount(Self.allAnswered()), band))
        let b = try #require(bitmap(mount(Self.allAnswered(), runnable: []), band))
        let scale = CGFloat(a.pixelsHigh) / band.height
        let points = CGFloat(differingPixels(a, b)) / (scale * scale)
        // Two rows earn a control here — Duplicates and Restructure — at roughly 60×18 and
        // 150×18pt of chrome. 600pt² is well above noise and well under the pair.
        #expect(points > 600,
                "no rescan control on an answered row (\(Int(points))pt² moved)")
    }

    /// **A row says so while its scan runs** — the count gives way to a spinner rather than
    /// redrawing a stale figure in confident bold.
    ///
    /// Named for what it actually measures. It was once called "withdraws its rescan control" and
    /// **survived the mutation that removed the withdrawal**: the row changes so much when the
    /// headline becomes a spinner that any threshold catching the button was already met without
    /// it. The claim about the button needs a fixture where the spinner is not also moving, which
    /// is the test below.
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

    /// **A scan already running does not offer to start itself again**, or the screen invites the
    /// second click that `rescanFilingButton` disables itself to prevent.
    ///
    /// Isolated by making **every** row that could carry the control scan at once, then rendering
    /// that with the passes runnable and not runnable. If the withdrawal holds, neither render
    /// draws a rescan and the two are pixel-identical; if it is removed, only one of them does.
    /// The spinner is in both, so it cannot stand in for the button — which is precisely what it
    /// did in the first version of this check.
    @Test func aRunningLensWithdrawsItsRescanControl() throws {
        let band = Self.fullBand
        let running = Self.allAnswered().map {
            OrganizeOverviewSection(lens: $0.lens, blurb: $0.blurb, state: $0.state,
                                    isScanning: OrganizePass(producing: $0.lens)?
                                        .answersOneLens == true)
        }
        let runnable = try #require(bitmap(mount(running), band))
        let notRunnable = try #require(bitmap(mount(running, runnable: []), band))
        #expect(differingPixels(runnable, notRunnable) == 0,
                "a rescan control is still drawn on a row whose scan is already running")
    }

    /// **Nothing on this screen says “Scan…” any more**, because nothing on it navigates instead of
    /// scanning. A guard against the old control returning by the back door.
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

    /// The source with **comment lines removed**.
    ///
    /// Not fastidiousness: the first version of the guard above searched the raw file and failed on
    /// this very file's prose, which quotes `"Scan…"` while explaining why the control went. A
    /// source scan that cannot tell code from the comment describing it is the shape of check that
    /// passes with the bug present — here it did the reverse, and either way it was not reading
    /// what it claimed to.
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

    /// **A finding draws every example it is given, up to the limit.**
    ///
    /// Measured by changing how many there are: one line against three. Comparing two renders is
    /// what makes this a test of the examples rather than of the card — a single fixture would be
    /// satisfied by a view that drew one line and ignored the rest, which is exactly what the row
    /// this replaces did, correctly, for its whole life.
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

    /// **The content reaches down the column instead of stopping a fifth of the way.**
    ///
    /// The complaint, stated as a measurement. The floor is deliberately far below what the current
    /// layout produces — this is a guard against a *collapse* back to a near-empty pane, not a
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
}
