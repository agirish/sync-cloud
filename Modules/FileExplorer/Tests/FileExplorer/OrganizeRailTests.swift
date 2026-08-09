import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// Organize's header, in pixels: the rail on row 1, the readout on row 2, and the controls that
/// used to go missing between them.
///
/// **This replaces `OrganizeFocusChipTests` and `OrganizeSummaryZoneTests`, whose shared premise
/// the layout retired.** Both were built on one row carrying navigation *and* prose side by side:
/// the chips and the readout were told apart by wash density measured in two zones of the *same*
/// band, and `SummaryZoneDivider` marked the boundary between them. The rail owns row 1 now and
/// the readout owns row 2, so that boundary is a row break and the divider is gone.
///
/// The claim those suites protected has not gone anywhere, and it is the first test below: **a
/// capsule is a control.** It is simply structural now — the question is no longer "which half of
/// this row is clickable" but "does the clickable row still look clickable and the prose row
/// still not". Measured across the two rows rather than across two zones of one.
///
/// **Pixels, because nothing else here is open.** The rail items are labels inside `Button`s inside
/// the header card: `fittingSize` cannot see them (the lens fills a fixed frame), and a caption
/// assertion passes vacuously with no assistive client attached to the test process. Three defects
/// in this feature shipped past a green suite and were caught by installing the app and looking —
/// the rail not drawing on two of six lenses among them.
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels back out of a live renderer, the repo-wide
/// marker for a suite that only produces a trustworthy verdict on the recording Mac.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct OrganizeRailTests {

    private static let canvas = CGSize(width: 900, height: 620)

    /// Row 1 — the rail. **Measured, not guessed**: a horizontal sweep of the rendered header in
    /// 6pt slices puts the card's first row of content at y 12–42 (wash peaking 16.4k at y 18–24),
    /// then a blank gutter at y 42–52, then row 2 at y 52–70. The zone stops at x 588 so the
    /// trailing controls, which are also capsules, cannot be mistaken for rail items.
    private static let railZone = CGRect(x: 8, y: 12, width: 580, height: 30)
    /// Row 2 — the readout. Same left edge, so the two densities compare over the same width.
    private static let readoutZone = CGRect(x: 8, y: 50, width: 580, height: 22)
    /// Row 1's trailing controls, **excluding the search toggle** at x≈860–890, which is drawn in
    /// every state and would make this band non-empty no matter what the actions did.
    private static let actionsZone = CGRect(x: 640, y: 12, width: 210, height: 30)

    // MARK: Fixtures

    private static func suggestion(_ name: String, confident: Bool = true) -> FilingSuggestion {
        FilingSuggestion(filePath: "/root/Downloads/\(name)", fileName: name, size: 4_096,
                         modificationDate: Date(timeIntervalSince1970: 0),
                         candidates: [FilingDestination(path: "/root/Documents/Family",
                                                        confidence: confident ? .high : .low,
                                                        reasons: ["t"], newSegments: [])],
                         providerRoot: "/root")
    }

    private static func risky(_ n: String) -> RiskyName {
        RiskyName(id: "/root/\(n)", relativePath: n, currentName: n,
                  sanitizedName: n.replacingOccurrences(of: ":", with: "-"),
                  reason: "colon", isDirectory: false)
    }

    private static func manager(queue: Int, names: Int, hasScanned: Bool = true) -> FileSyncManager {
        let m = FileSyncManager()
        m.publishFilingSuggestions((0..<queue).map { suggestion("f\($0).pdf", confident: $0 % 3 != 0) })
        m.hasSuggestedFiling = hasScanned
        m.filingScanFolder = "/root/Downloads"
        m.filingLastProviderRoot = "/root"
        m.riskyNames = (0..<names).map { risky("bad:name\($0).pdf") }
        m.nameScanRoot = URL(fileURLWithPath: "/root")
        m.hasScannedNames = names > 0
        return m
    }

    /// Mounts Organize with a **named rail selection**.
    ///
    /// The selection has to go through the defaults the view itself reads, because that is where
    /// `TidyView` keeps it — and it is not optional for a fixture: with the key unset the rail
    /// resolves to `nil`, which is the *overview*, where no lens's actions are drawn at all. A
    /// suite that forgot this measured the overview and reported that a full queue and an empty
    /// one inked the action band identically. The innermost `defaultAppStorage` wins.
    private func mount(_ manager: FileSyncManager, lens: OrganizeLens?) -> NSHostingView<AnyView> {
        let defaults = ScratchDefaults("OrganizeRailTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        if let lens {
            defaults.set(lens.rawValue, forKey: OrganizeLens.defaultsKey)
        } else {
            defaults.removeObject(forKey: OrganizeLens.defaultsKey)
        }
        let subject = TidyView(syncManager: manager, lens: .filing, providerName: "Projects",
                               scanTargetFolder: "/root/Downloads", onFindDuplicates: {})
            .defaultAppStorage(defaults)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        // Without a window the content composites against the borderless window's own buffer and
        // every comparison reads as zero difference.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func strip(_ host: NSHostingView<AnyView>, _ band: CGRect) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: band) else { return nil }
        host.cacheDisplay(in: band, to: rep)
        return rep
    }

    /// Pixels split by how far they are from the band's own background corner.
    ///
    /// **`wash` is what separates a capsule from a run of text.** A tinted capsule covers its whole
    /// area in a low-opacity fill — a large, soft, uniform departure from the background. Glyphs
    /// and text are the opposite: a small area of near-black `ink` with a thin antialiased fringe.
    /// So a row of capsules reads dense in `wash`, and the same words drawn without them read
    /// nearly empty of it however much text is in there.
    ///
    /// Deliberately not a brightness filter: `brightness < 0.90` counts the dark text *inside* a
    /// capsule and none of the pale wash behind it, which is exactly backwards for this question.
    private func counts(_ rep: NSBitmapImageRep) -> (wash: Int, ink: Int) {
        guard let background = rep.colorAt(x: 2, y: 2) else { return (0, 0) }
        var wash = 0, ink = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.35 { ink += 1 } else if delta > 0.03 { wash += 1 }
            }
        }
        return (wash, ink)
    }

    /// `wash` per point of band width, so bands of different widths compare directly.
    private func washDensity(_ rep: NSBitmapImageRep, width: CGFloat) -> Double {
        Double(counts(rep).wash) / Double(width)
    }

    /// Strong, blue-dominant pixels — **the ring, told apart from the fill behind it.**
    ///
    /// The selected item encodes selection twice: a 2pt full-opacity `accent` stroke, and a fill
    /// deepened from 14% to 22%. `differingPixels` between two selections therefore moves whether
    /// or not the ring draws at all, which is how the first version of these two tests passed with
    /// the ring deleted — they measured the fill, one property adjacent to the claim.
    ///
    /// A 22% wash sits at delta ≈ 0.22 from the background, so the 0.30 floor excludes it; text is
    /// near-neutral, so requiring blue to lead red by 0.18 excludes that too. Measured: **2,476**
    /// such pixels with the ring, **632** with the ring deleted (the accent glyph and badges of the
    /// selected item), and **402** on the overview, which rings nothing.
    private func accentEdge(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 2, y: 2) else { return 0 }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(c.redComponent - background.redComponent),
                                max(abs(c.greenComponent - background.greenComponent),
                                    abs(c.blueComponent - background.blueComponent)))
                if delta > 0.30 && (c.blueComponent - c.redComponent) > 0.18 { n += 1 }
            }
        }
        return n
    }

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var n = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { n += 1 }
        }
        return n
    }

    // MARK: The rule, ported across the row break — a capsule is a control

    @Test("The rail row wears capsules and the readout row does not")
    func onlyTheControlRowWearsCapsules() throws {
        let host = mount(Self.manager(queue: 24, names: 17), lens: .toFile)
        let rail = try #require(strip(host, Self.railZone))
        let readout = try #require(strip(host, Self.readoutZone))

        // Staleness guard first, and it is the half that makes the claim mean anything: a band that
        // has drifted off its row paints nothing, and "nothing" satisfies "no capsule" trivially.
        // The readout must be full of TEXT while being empty of WASH — a pairing that is only true
        // of words drawn without a capsule behind them.
        let readoutInk = counts(readout).ink
        #expect(readoutInk > 200,
                "the readout band drew only \(readoutInk) inked pixels — it has drifted off row 2, and every wash assertion here is vacuous")

        let railDensity = washDensity(rail, width: Self.railZone.width)
        let readoutDensity = washDensity(readout, width: Self.readoutZone.width)
        #expect(railDensity > 20,
                "the rail painted \(Int(railDensity)) wash px/pt — its items have lost their capsules, and with them the only thing saying the row is clickable")
        #expect(readoutDensity < 8,
                "the readout painted \(Int(readoutDensity)) wash px/pt — it is wearing capsules, so a number that does nothing when clicked looks exactly as pressable as the rail above it")
    }

    @Test("The readout still says its numbers")
    func theReadoutIsNotSimplyGone() throws {
        // The cheapest way to pass the test above is to draw no readout at all. So pin that it
        // still tracks the scan: same queue length, different confidence mix, which moves `ready`
        // and `unsure` without changing any rail badge.
        let allConfident = Self.manager(queue: 0, names: 17)
        allConfident.publishFilingSuggestions((0..<24).map { Self.suggestion("f\($0).pdf", confident: true) })
        allConfident.hasSuggestedFiling = true

        let mixed = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                       Self.readoutZone))
        let clean = try #require(strip(mount(allConfident, lens: .toFile), Self.readoutZone))
        #expect(counts(mixed).ink != counts(clean).ink,
                "the readout painted the same thing for 24 ready and for 16 ready with 8 unsure — it is not reading the scan")
    }

    // MARK: The rail is on screen, and it is the rail

    @Test("Every rail item reaches the screen")
    func theRailPaints() throws {
        let rail = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        // Six capsules and their labels. A bare threshold would pass on one item, so this is
        // paired with the per-item probe below.
        #expect(counts(rail).ink > 600, "row 1 is nearly empty — the rail is not drawing")
    }

    @Test("The rail draws on a lens whose apparatus is not the filing one")
    func theRailSurvivesTheApparatusSwitch() throws {
        // **The defect that shipped.** The rail was built inside the summary arm that only the
        // filing apparatus reaches, so standing on Duplicates or Rules drew that lens's own pills
        // and no rail at all. Rules borrows `.automations`' apparatus, which is the furthest from
        // filing's, so it is the strongest case to pin.
        let onFiling = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        let onRules = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .rules),
                                         Self.railZone))
        #expect(counts(onRules).ink > 600,
                "row 1 is empty on the Rules lens — the rail is drawn inside one apparatus's arm again")
        // Same six items either way; only the ring moves, so the two renders differ but neither is
        // blank. Asserting they DIFFER is what stops a cached or identical render passing both.
        #expect(differingPixels(onFiling, onRules) > 0,
                "the rail rendered identically on two different selections — the ring is not tracking the lens")
    }

    @Test("The selected item is ringed")
    func theSelectedItemIsRinged() throws {
        // An `.overlay` that never draws is invisible to every geometry assertion, so the ring is
        // pixels or it is nothing — and it has to be measured as the RING. Deleting the stroke
        // leaves the deepened fill behind, which still moves a whole-band pixel diff, so a diff is
        // not evidence the ring exists. `accentEdge` is: 2,476 with it, 632 without.
        let ringed = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                        Self.railZone))
        let edge = accentEdge(ringed)
        #expect(edge > 1500,
                "the selected item painted \(edge) full-strength accent pixels — the ring is not drawing, and only the fill is left to say which lens you are on")
    }

    @Test("Moving the selection moves the ring")
    func theRingFollowsTheSelection() throws {
        // A ring that drew on a fixed item would satisfy the test above forever. Both states are
        // ringed, so this is the pixel diff — here it IS the right instrument, because the
        // question is whether the ring MOVED, not whether it exists.
        let onToFile = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        let onNames = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .names),
                                         Self.railZone))
        #expect(accentEdge(onNames) > 1500, "the Names selection drew no ring")
        #expect(differingPixels(onToFile, onNames) > 200,
                "selecting a different rail item changed almost nothing — the ring is pinned to one item")
    }

    @Test("The overview rings nothing")
    func theOverviewIsTheUnselectedState() throws {
        // The overview is the rail's unselected state rather than a seventh item, so it must draw
        // the same six items with no ring — fewer inked pixels than any selected state, but not
        // zero.
        let overview = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: nil),
                                          Self.railZone))
        let selected = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                          Self.railZone))
        #expect(counts(overview).ink > 600, "the overview drew no rail — it is not the unselected state")
        // Measured at 402 against 2,476 for a ringed render: the overview rings nothing. A pixel
        // diff would pass here even with the ring deleted, so this asks the ring question directly.
        let edge = accentEdge(overview)
        #expect(edge < 900,
                "the overview painted \(edge) full-strength accent pixels — something is ringed, so the unselected state is quietly selecting a lens")
        #expect(differingPixels(overview, selected) > 200,
                "the overview and a selected lens rendered the same rail")
    }

    // MARK: Badges — absent at zero, present with a finding

    @Test("A badge appears only when its lens has something to report")
    func aBadgeIsAbsentAtZero() throws {
        // The surviving half of the chips' argument. The ITEM is unconditional — that is what
        // pointed invocation lands on — so this compares two renders of the same six items and
        // asserts the *badge* is what changed.
        let none = try #require(strip(mount(Self.manager(queue: 24, names: 0), lens: .toFile),
                                      Self.railZone))
        let some = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.railZone))
        #expect(differingPixels(none, some) > 100,
                "17 risky names painted the same rail as none — the Names badge is not drawing")
        // And the item itself is there either way: the rail must not shrink to five places.
        #expect(counts(none).ink > 600, "the rail lost an item at zero — a place is not a badge")
    }

    @Test("The badge carries the count, not just a dot")
    func theCountReachesTheBadge() throws {
        // Two non-zero counts of different digit widths. If the badge were a presence indicator
        // rather than a number these would render identically.
        let three = try #require(strip(mount(Self.manager(queue: 24, names: 3), lens: .toFile),
                                       Self.railZone))
        let seventeen = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                           Self.railZone))
        #expect(differingPixels(three, seventeen) > 50,
                "3 and 17 risky names painted the same badge — it is not carrying the count")
    }

    // MARK: The control — Rescan outlives the queue

    @Test("Rescan is there once a scan has run, even with nothing left to file")
    func rescanSurvivesAnEmptyQueue() throws {
        // The reported state: everything filed, findings still standing. Row 1's trailing half used
        // to be empty here, because Rescan sat inside the gate that draws "File all".
        let filed = try #require(strip(mount(Self.manager(queue: 0, names: 17), lens: .toFile),
                                       Self.actionsZone))
        #expect(counts(filed).ink > 100,
                "row 1 painted no controls with an empty queue beside 17 risky names — Rescan is gated on the queue again")
    }

    @Test("…and is absent before the first scan, where the intro owns the invitation")
    func rescanIsAbsentBeforeAnyScan() throws {
        // The other direction, and what stops the test above from being satisfied by a button that
        // is simply always drawn.
        let never = try #require(strip(mount(Self.manager(queue: 0, names: 17, hasScanned: false),
                                             lens: .toFile), Self.actionsZone))
        #expect(counts(never).ink < 20,
                "row 1's action band is inked before any scan has completed — Rescan is ungated")
    }

    @Test("The actions band is over the actions")
    func theActionsBandIsWhereTheActionsAre() throws {
        // `actionsZone` is a hard-coded rectangle over a laid-out row, the kind of constant that
        // goes stale silently — and a band that has slid off the buttons makes
        // `rescanIsAbsentBeforeAnyScan` pass for the wrong reason forever. Pinned against the state
        // with the MOST controls: a full queue draws Rescan, Refine and File all, so this band has
        // to be substantially more inked than the one that draws Rescan alone.
        let full = try #require(strip(mount(Self.manager(queue: 24, names: 17), lens: .toFile),
                                      Self.actionsZone))
        let rescanOnly = try #require(strip(mount(Self.manager(queue: 0, names: 17), lens: .toFile),
                                            Self.actionsZone))
        #expect(counts(full).ink > counts(rescanOnly).ink + 200,
                "three controls and one control inked this band almost identically — it is not over the actions")
    }
}
