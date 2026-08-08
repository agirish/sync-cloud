import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Do Organize's focus chips reach the screen, and does the selected one wear the ring?
///
/// **Pixels, because nothing else here is open.** The chips are `StatPill`s inside `Button`s inside
/// the header card's summary row: `fittingSize` cannot see them (the lens fills a fixed frame), and
/// a caption assertion passes vacuously with no assistive client attached to the test process. A
/// feature in this app shipped visibly broken behind forty green tests for exactly that reason.
///
/// `OrganizeFocusTests` asserts what the rules decide; this suite asserts the view asks them. The
/// two that would survive a decorative rule are `theFindingsChipAppearsOnlyWhenThereIsAFinding`
/// (the row must change shape when `riskyNames` does) and `theSelectedChipIsRinged` (an `.overlay`
/// that never draws is invisible to every geometry assertion).
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels back out of a live renderer, the repo-wide
/// marker for a suite that only produces a trustworthy verdict on the recording Mac.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct OrganizeFocusChipTests {

    private static let canvas = CGSize(width: 900, height: 620)
    /// The summary row's band, cropped so a difference in the LIST below cannot be mistaken for one
    /// in the header.
    ///
    /// **Measured, not guessed.** The title row inks y≈22–34pt and the pills row y≈50–72pt; an
    /// earlier cut of this suite took y 34–80 and clipped the pills, which made `inkedPixels` return
    /// the identical figure for two rows that plainly differ on screen. The band is deliberately
    /// wider than the pills on both sides so a point of layout drift cannot silently empty it —
    /// `theStripActuallyContainsTheChips` is the guard that would catch it if it did.
    private static let summaryStrip = CGRect(x: 0, y: 42, width: 900, height: 40)
    /// The focus chips ALONE — both capsules, stopping short of everything that follows them.
    ///
    /// Measured on the shipping render at a two-digit queue count: the queue chip spans x 14-104 pt,
    /// the names chip 112-236, the scope chip 245-298 and `ready` 308-396. 240 clears the chips by
    /// 4 pt and excludes the rest.
    ///
    /// This constant has been wrong once already. It was 330 when the scope chip led the row; moving
    /// the scope to sit with the pills it describes slid everything left, and 330 quietly swallowed
    /// both the scope chip and part of `ready` — with `theQueueCountReachesItsChip` still passing,
    /// on the pills, exactly as it had before the crop existed. Hence
    /// `theChipsOnlyBandStopsShortOfTheScope` below, which pins the boundary against the element
    /// that is now nearest to it rather than against a pill two positions away.
    private static let chipsOnlyStrip = CGRect(x: 0, y: 42, width: 240, height: 40)

    /// `confident: false` gives the file no confident home, which moves it from `ready` to
    /// `unsure` without changing the queue's length — the one knob that separates the pills from
    /// the chips.
    private static func suggestion(_ name: String, confident: Bool = true) -> FilingSuggestion {
        FilingSuggestion(
            filePath: "/root/Downloads/\(name)", fileName: name, size: 4_096,
            modificationDate: Date(timeIntervalSince1970: 0),
            candidates: [FilingDestination(path: "/root/Documents/Family",
                                           confidence: confident ? .high : .low,
                                           reasons: ["test"], newSegments: [])],
            providerRoot: "/root")
    }

    private static func risky(_ name: String) -> RiskyName {
        RiskyName(id: "/root/\(name)", relativePath: name, currentName: name,
                  sanitizedName: name.replacingOccurrences(of: ":", with: "-"),
                  reason: "colon", isDirectory: false)
    }

    /// A manager holding a COMPLETED Organize scan — the state the lens is in when the user is
    /// looking at results, with both of Organize's lists under caller control.
    private static func plan(_ i: Int) -> RenamePlan {
        RenamePlan(folderPath: "/root/Bills/20\(10 + i)", relativePath: "Bills/20\(10 + i)",
                   scheme: .position,
                   steps: [RenameStep(currentPath: "/root/Bills/20\(10 + i)/1. Jan.pdf",
                                      currentName: "1. Jan.pdf", proposedName: "01. Jan.pdf",
                                      kind: .tidied, reason: "Padded")],
                   skips: [])
    }

    private static func manager(queue: Int, names: Int, confident: Bool = true,
                                renames: Int = 0) -> FileSyncManager {
        let m = FileSyncManager()
        m.publishFilingSuggestions((0..<queue).map { suggestion("file\($0).pdf", confident: confident) })
        m.hasSuggestedFiling = true
        m.filingScanFolder = "/root/Downloads"
        m.filingLastProviderRoot = "/root"
        m.riskyNames = (0..<names).map { risky("bad:name\($0).pdf") }
        m.nameScanRoot = URL(fileURLWithPath: "/root")
        m.hasScannedNames = names > 0 || renames > 0
        m.publishRenamePlans((0..<renames).map { plan($0) })
        return m
    }

    /// The hue goes into the store the view itself reads, applied INSIDE the subject. The innermost
    /// `defaultAppStorage` is the one that wins — a second one layered on by the caller never
    /// arrives, and the ring then measures 0 accent pixels, which reads identically to "the ring
    /// ignores the accent".
    private func mount(_ manager: FileSyncManager, hue: LiquidGlassHue = .blue) -> NSHostingView<AnyView> {
        let defaults = ScratchDefaults("OrganizeFocusChipTests")
        defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)
        let subject = TidyView(syncManager: manager, lens: .filing,
                               providerName: "Projects", scanTargetFolder: "/root/Downloads",
                               onFindDuplicates: {})
            .defaultAppStorage(defaults)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        // The window background is not decoration: without one the content composites against the
        // borderless window's own buffer and every comparison reads as zero difference.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func strip(_ host: NSHostingView<AnyView>, _ rect: CGRect? = nil) -> NSBitmapImageRep? {
        let band = rect ?? Self.summaryStrip
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        host.cacheDisplay(in: band, to: rep)
        return rep
    }

    /// Pixels that are not the window background.
    ///
    /// Measured against the corner rather than by brightness. A `brightnessComponent < 0.90` filter
    /// — the usual one in this repo, and what this suite used first — counts the dark TEXT in a pill
    /// and none of the pale wash behind it, so adding a whole chip moved the figure by nothing at
    /// all and "the row painted the same thing" looked true when the render plainly disagreed.
    private func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.03 { count += 1 }
            }
        }
        return count
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.02
                    || abs(p.greenComponent - q.greenComponent) > 0.02
                    || abs(p.blueComponent - q.blueComponent) > 0.02 { count += 1 }
            }
        }
        return count
    }

    @Test func theStripActuallyContainsTheChips() throws {
        // The band is a hard-coded rectangle over a laid-out view, which is exactly the kind of
        // constant that goes stale silently: every comparison below still "passes" when the crop
        // has drifted off the chips onto empty card. So pin it against a state whose chips are
        // known to differ — an empty queue draws "0 to file" where a full one draws "24 to file",
        // same layout, different glyphs — and require the band to see it.
        let full = try #require(strip(mount(Self.manager(queue: 24, names: 17))))
        let empty = try #require(strip(mount(Self.manager(queue: 0, names: 17))))
        #expect(inkedPixels(full) > 600, "the summary band is nearly blank — it has drifted off the chips")
        #expect(differingPixels(full, empty) > 40,
                "the band cannot tell 24 from 0 on the queue chip — it is not over the chips")
    }

    @Test func theQueueChipPaintsWhenThereAreResults() throws {
        let rep = try #require(strip(mount(Self.manager(queue: 24, names: 0))))
        #expect(inkedPixels(rep) > 400, "Organize's summary row painted nothing with 24 files to file")
    }

    @Test func theFindingsChipAppearsOnlyWhenThereIsAFinding() throws {
        // The shape of the row must follow `riskyNames`. A build that always drew both chips, or
        // never drew the second, rasterizes these two identically.
        let clean = try #require(strip(mount(Self.manager(queue: 24, names: 0))))
        let flagged = try #require(strip(mount(Self.manager(queue: 24, names: 17))))
        #expect(differingPixels(clean, flagged) > 300,
                "the summary row looks the same with 0 and 17 risky names — the finding chip is not reading the scan")
        // …and in the direction that matters: the finding ADDS a chip, so it adds ink.
        #expect(inkedPixels(flagged) > inkedPixels(clean))
    }

    @Test func theFindingsCountReachesTheChip() throws {
        // Same shape, different number. A chip that hard-coded its label, or counted the wrong
        // list, paints "3" and "17" the same.
        let few = try #require(strip(mount(Self.manager(queue: 24, names: 3))))
        let many = try #require(strip(mount(Self.manager(queue: 24, names: 17))))
        #expect(differingPixels(few, many) > 20,
                "3 and 17 risky names paint the same chip — the count is not the finding's")
    }

    @Test func theQueueCountReachesItsChip() throws {
        // Cropped to the chips so this means the CHIP and not the pills after it. Both fixtures use
        // two-digit counts so the capsule is the same width in each and nothing downstream shifts —
        // any difference inside this band is the digits the queue chip drew.
        //
        // The finding is held constant at 17 for the same reason. Mutation-checked: a queue chip
        // returning a constant fails here, and passed every test in this file before this crop.
        let twelve = try #require(strip(mount(Self.manager(queue: 12, names: 17)), Self.chipsOnlyStrip))
        let twentyFour = try #require(strip(mount(Self.manager(queue: 24, names: 17)), Self.chipsOnlyStrip))
        #expect(differingPixels(twelve, twentyFour) > 8,
                "12 and 24 loose files paint the same queue chip — its count is not the queue's")
    }

    @Test func theChipsOnlyBandStopsShortOfTheScope() throws {
        // `chipsOnlyStrip` is a hard-coded rectangle over a laid-out row, so it needs a guard that
        // fails when the layout moves under it — the failure mode is silent, and it has happened.
        //
        // Pinned against the SCOPE chip, the element immediately right of the chips: two fixtures
        // identical but for the scanned folder's name, so the only thing that can move is that chip
        // and the pills after it. The band must not see any of it.
        let shortName = Self.manager(queue: 24, names: 17)
        let longName = Self.manager(queue: 24, names: 17)
        longName.filingScanFolder = "/root/AnArchiveFolderWithAMuchLongerName"

        // Non-vacuity first: `== 0` is also what two identical renders produce, so prove the change
        // is real over the whole row before claiming the narrow band cannot see it.
        #expect(differingPixels(try #require(strip(mount(shortName))),
                                try #require(strip(mount(longName)))) > 20,
                "renaming the scanned folder changed no pixels anywhere — this guard tests nothing")
        #expect(differingPixels(try #require(strip(mount(shortName), Self.chipsOnlyStrip)),
                                try #require(strip(mount(longName), Self.chipsOnlyStrip))) == 0,
                "the chips-only band moved with the scope chip — it has widened past the chips")
    }

    /// What the band paints with nothing in it. **Not zero** — the header card's own edge runs
    /// through this crop, measured at ~200 px — so "empty" is this figure, and asserting `== 0`
    /// fails on a correctly empty row. Every emptiness claim below is relative to this.
    private func emptyRowBaseline() throws -> NSBitmapImageRep {
        try #require(strip(mount(Self.manager(queue: 0, names: 0))))
    }

    @Test func theRowIsEmptyWhileAScanRuns() throws {
        // The regression this suite missed first time round. Both of Organize's lists are published
        // on COMPLETION — mid-scan `filingSuggestions`, `filingScanFolder` and `riskyNames` still
        // hold the previous scan's answer, deliberately, so a cancelled rescan leaves the old
        // results intact. Drawing the row from them puts last scan's "24 to file" beside a list
        // that is still counting.
        //
        // Asserted as "identical to the empty row", not "has little ink": a scan-gated row that
        // still drew one stale chip would clear any threshold this side of exact.
        let scanning = Self.manager(queue: 24, names: 17)
        scanning.isSuggestingFiles = true
        let mid = try #require(strip(mount(scanning)))
        #expect(differingPixels(mid, try emptyRowBaseline()) == 0,
                "Organize's summary row painted during a scan — those counts are the previous scan's")
    }

    @Test func theRowIsEmptyWhenTheScanFoundNothing() throws {
        // No queue, no finding: a lone scope chip summarises nothing, and the content card below
        // already says the folder came back clean.
        //
        // Pinned by contrasting the two things that decide whether that chip can draw — a scan
        // folder that exists, and one that does not. With the emptiness gate in place both render
        // the same nothing; drop it and only the first draws "Downloads", so they diverge. An
        // earlier cut compared ink against a populated row instead and let that mutation through:
        // one extra chip is far too small to close a 400 px gap.
        let scanned = Self.manager(queue: 0, names: 0)
        let neverScanned = Self.manager(queue: 0, names: 0)
        neverScanned.filingScanFolder = nil
        #expect(differingPixels(try #require(strip(mount(scanned))),
                                try #require(strip(mount(neverScanned)))) == 0,
                "the scope chip drew for a scan with nothing to report — the row is not gated on having something to summarise")
    }

    @Test func theRowSurvivesAnEmptyQueueBesideAFinding() throws {
        // …but the state after "File all" is not "nothing to report": the files are filed and the
        // names are still wrong. Both chips must be there, or the finding has no way back to the
        // queue and the queue no way to the finding.
        let filedButFlagged = try #require(strip(mount(Self.manager(queue: 0, names: 17))))
        #expect(inkedPixels(filedButFlagged) > inkedPixels(try emptyRowBaseline()) + 400,
                "an empty queue beside 17 risky names painted no row")
    }

    @Test func theSelectedChipIsRinged() throws {
        // THE assertion. The ring is an `.overlay` — it costs no size, so nothing geometric can see
        // it, and a build that dropped it would pass every other test in this file.
        //
        // Isolated by ACCENT, not by "something differs": the ring is the app accent, and the two
        // chips themselves are `.info` and `.caution` — semantic, hue-independent. So rendering the
        // same state under two accents leaves the chips identical and moves the ring alone.
        let blue = try #require(strip(mount(Self.manager(queue: 24, names: 17), hue: .blue)))
        let green = try #require(strip(mount(Self.manager(queue: 24, names: 17), hue: .green)))
        let ringed = differingPixels(blue, green)

        // The control: the same two hues with NO ring on screen. One chip means no radio group,
        // which means no selection to draw — so whatever accent-tinted chrome shares this strip
        // differs by the same amount in both comparisons, and only the ring is left over.
        let blueAlone = try #require(strip(mount(Self.manager(queue: 24, names: 0), hue: .blue)))
        let greenAlone = try #require(strip(mount(Self.manager(queue: 24, names: 0), hue: .green)))
        let unringed = differingPixels(blueAlone, greenAlone)

        #expect(ringed > unringed + 150,
                "swapping the accent moved \(ringed) px with a selection and \(unringed) px without one — the selected chip is not drawing an accent ring")
    }

    // MARK: - What is deliberately NOT tested here
    //
    // **The fallback's WIRING.** `OrganizeFocus.effective` — a focus whose list emptied falls back
    // to `.queue` — is asserted in `OrganizeFocusTests`, but that it is the function
    // `effectiveOrganizeFocus` calls is not asserted anywhere, and cannot be from here. `organizeFocus`
    // is `@State`: a test can neither set it nor click the chip that would (a SwiftUI `Button` is not
    // an `NSControl`), so every fixture in this file renders with the focus on its `.queue` default —
    // where `effective(.queue, …)` and a raw `organizeFocus` return the same answer for every input.
    // A mutation replacing the call with the stored value changes no pixel in any of these tests.
    //
    // Not closed with an `initialFocus` parameter on purpose: it would exist only for this suite, and
    // a seam with no production caller is the thing that gets deleted as dead and takes its coverage
    // with it. When the palette entry and the Home tile land (ROADMAP 14/16) they will route to
    // Organize with a focus, and that parameter becomes real — that is the point to test this
    // properly, not before.
    //
    // **"The ring costs the row no space."** It is true, it is why the ring is an `.overlay` rather
    // than a border or padding, and there is no honest automated assertion for it in this suite.
    // Both halves were checked by hand, by rendering the header to a PNG and reading it back:
    //
    // - *Vertically* it cannot fail. `LensHeaderCard` pins this header's height, so a chip that
    //   grows inside the row is absorbed and nothing below the header moves. A test written against
    //   that landmark passed with a deliberate `.padding(6)` mutation in place — it was not
    //   measuring the ring, it was measuring the pinned height, which `LensHeaderCard` already owns.
    // - *Horizontally* padding does displace the chips after it, but only by the padding — and every
    //   measurement that separates a 12 px shove from the ring's own antialiased edge needs colour
    //   thresholds tight enough that ordinary retuning of the row would break them. A hard-coded
    //   right edge would fail the next time a pill is added to this row for good reasons.
    //
    // So the claim rests on `.overlay`'s documented behaviour and on the render, and this note
    // exists so the next person does not mistake the gap for an oversight — or re-add the version
    // that passes no matter what the ring does.

    // MARK: The rename backlog chip (ROADMAP 19)

    /// **The call site, not the rule.** `OrganizeFocusTests` proves `chips(…)` returns `.renames`
    /// when there are plans; this proves the header actually draws it. A third case added to the
    /// enum and never read by the view would pass every one of those tests.
    @Test("A rename backlog paints a third chip on the summary row")
    @MainActor func theBacklogChipPaints() throws {
        let without = try #require(strip(mount(Self.manager(queue: 6, names: 0, renames: 0))))
        let with = try #require(strip(mount(Self.manager(queue: 6, names: 0, renames: 9))))
        let bare = inkedPixels(without)
        let extra = inkedPixels(with)
        // Measured as delta-from-the-corner, not by brightness: the chip's wash is pale, and a
        // `brightness < 0.90` filter counts only its text — which moved this figure by almost
        // nothing when the row plainly gained a whole capsule.
        #expect(extra > bare, "adding 9 plans must paint more than an empty backlog does")
        // A real capsule, not a stray pixel or two of relayout.
        #expect(extra - bare > 200, "gained only \(extra - bare) inked pixels")
    }

    @Test("No backlog paints no backlog chip")
    @MainActor func anEmptyBacklogPaintsNothing() throws {
        // The other direction, and the one that makes the test above mean something: the row with
        // zero plans must be pixel-identical to the row that never had a backlog concept at all.
        let a = try #require(strip(mount(Self.manager(queue: 6, names: 0, renames: 0))))
        let b = try #require(strip(mount(Self.manager(queue: 6, names: 0, renames: 0))))
        #expect(differingPixels(a, b) == 0)
    }
}
