import Testing
import AppKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// Every FileExplorer control that marks one choice among siblings really hosts a selection lens
/// (roadmap RD46): in Frosted and Clear the lens sits exactly on the chosen stop.
///
/// Glass draws nothing offscreen, so these render with the probe (`drawsProbe`) — the lens's own
/// geometry in flat magenta. That is what makes this a call-site test rather than a test of the
/// seam: the seam's behaviour is pinned in `SelectionLensTests`; what is pinned here is that each
/// control wired its host and its stops, and wired them to the right frames. A control that
/// dropped its host would render no magenta at all; one whose stops sat on the wrong view would
/// render it in the wrong place.
///
/// Solid needs no test here: with no appearance set every control draws today's marker, and the
/// suites that already render these controls (`PaneTabStripRenderTests` and the rest) are that
/// test — untouched.
@MainActor
@Suite(.serialized) struct SelectionLensCallSiteTests {

    static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)

    /// `view` at `size` on white, pinned to the light scheme, an active window, and the appearance
    /// given — held in a `ProbeRig`, so a test that waits can read the same view again.
    static func rig<V: View>(_ view: V, size: CGSize, appearance: SelectionLensAppearance = probe) -> ProbeRig<AnyView> {
        ProbeRig(AnyView(view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            // Pinned, so the machine's own settings cannot decide these tests.
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard)
            .environment(\._accessibilityReduceMotion, false)), size: size)
    }

    /// Renders `view` at `size` with the probe on, and returns the probe's bounding box in points.
    static func probeBox<V: View>(_ view: V, size: CGSize,
                                  appearance: SelectionLensAppearance = probe) -> CGRect? {
        rig(view, size: size, appearance: appearance).box(Pixel.lensProbe)
    }

    static func expectNear(_ a: CGRect?, x: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil,
                           tolerance: CGFloat = 1.01,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        guard let a else {
            Issue.record("the probe drew nothing — no lens at this control", sourceLocation: sourceLocation)
            return
        }
        if let x { #expect(abs(a.minX - x) <= tolerance, "minX \(a.minX), want \(x)", sourceLocation: sourceLocation) }
        if let width { #expect(abs(a.width - width) <= tolerance, "width \(a.width), want \(width)", sourceLocation: sourceLocation) }
        if let height { #expect(abs(a.height - height) <= tolerance, "height \(a.height), want \(height)", sourceLocation: sourceLocation) }
    }

    // MARK: - RD46.2 · Pane tab strip

    private func tab(_ title: String, active: Bool) -> PaneTabStrip.Item {
        PaneTabStrip.Item(id: UUID(), title: title, markImageName: "folder.fill",
                          isActive: active, fullPath: "/Users/x/\(title)", isPinned: false)
    }

    private func strip(_ items: [PaneTabStrip.Item]) -> PaneTabStrip {
        PaneTabStrip(items: items, accent: .blue,
                     onSelect: { _ in }, onClose: { _ in }, onCloseOthers: { _ in },
                     onDuplicate: { _ in }, onCopyPath: { _ in }, onNew: {})
    }

    @Test(.machinePinned(.pixelSampling), arguments: [0, 2])
    func theTabStripsLensSitsOnTheActiveChip(active: Int) {
        let titles = ["Documents", "Taxes 2025", "Photos"]
        let items = titles.enumerated().map { tab($0.element, active: $0.offset == active) }
        let width: CGFloat = 640
        let layout = PaneTabStripLadder.layout(
            available: width - 2 * PaneTabStripLadder.stripGutter, titles: titles, scale: 1)
        #expect(layout.rung != .chip, "the fixture is meant to draw chips")
        let box = Self.probeBox(strip(items), size: CGSize(width: width, height: PaneTabStripLadder.stripHeight))
        Self.expectNear(box,
                        x: PaneTabStripLadder.stripGutter
                            + CGFloat(active) * (layout.tabWidth + PaneTabStripLadder.tabGap),
                        width: layout.tabWidth,
                        height: PaneTabStripLadder.tabHeight)
    }

    @Test(.machinePinned(.pixelSampling))
    func theChipRungsLensSitsOnItsOneChip() {
        let items = ["Documents", "Taxes 2025", "Photos", "Receipts"].enumerated()
            .map { tab($0.element, active: $0.offset == 1) }
        let width: CGFloat = 200
        let layout = PaneTabStripLadder.layout(
            available: width - 2 * PaneTabStripLadder.stripGutter, titles: items.map(\.title), scale: 1)
        #expect(layout.rung == .chip, "the fixture is meant to draw the chip rung")
        let box = Self.probeBox(strip(items), size: CGSize(width: width, height: PaneTabStripLadder.stripHeight))
        Self.expectNear(box, x: PaneTabStripLadder.stripGutter, height: PaneTabStripLadder.tabHeight)
    }

    /// **Choosing another tab from the chip rung's menu leaves the lens where it is.** The rung has
    /// one stop, the active tab's, so choosing another re-labels it: the lens was drawn there and is
    /// wanted there. The first version found no stop for the old tab, took the move for a growth,
    /// and blinked the lens out to regrow it from 40% on the same chip, every time.
    @Test(.machinePinned(.pixelSampling))
    func theChipRungsLensStaysPutWhenAnotherTabIsChosen() throws {
        let titles = ["Documents", "Taxes 2025", "Photos", "Receipts"]
        func items(active: Int) -> [PaneTabStrip.Item] {
            titles.enumerated().map { tab($0.element, active: $0.offset == active) }
        }
        // Stable ids across the two renders, as a real strip's are.
        let ids = titles.map { _ in UUID() }
        func stable(active: Int) -> [PaneTabStrip.Item] {
            items(active: active).enumerated().map { i, item in
                PaneTabStrip.Item(id: ids[i], title: item.title, markImageName: item.markImageName,
                                  isActive: item.isActive, fullPath: item.fullPath, isPinned: false)
            }
        }
        let size = CGSize(width: 200, height: PaneTabStripLadder.stripHeight)
        let rig = Self.rig(strip(stable(active: 1)), size: size)
        let before = try #require(rig.box(Pixel.lensProbe), "no lens on the chip")
        rig.host.rootView = AnyView(strip(stable(active: 2))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)
            .environment(\.selectionLensAppearance, Self.probe)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard)
            .environment(\._accessibilityReduceMotion, false))
        let after = rig.box(Pixel.lensProbe)
        #expect(after.map { abs($0.minX - before.minX) <= 1.01 && abs($0.height - before.height) <= 1.01 } == true,
                "the lens left the chip when another tab was chosen: \(before) → \(String(describing: after))")
    }

    /// **The active chip's slab steps aside for the lens.** Every chip wears a grey slab, and the
    /// active one's used to stay — drawn in the chip's own background, above the host's, so it laid
    /// an 85% quaternary film over the lens. Under that film the probe still reads as magenta to
    /// `Pixel.lensProbe` (it is that loose on purpose), so this reads the lens's middle against
    /// the bare probe, to within a couple of steps a channel.
    @Test(.machinePinned(.pixelSampling))
    func theActiveChipsSlabStepsAsideForTheLens() throws {
        let titles = ["Documents", "Taxes 2025", "Photos"]
        let items = titles.enumerated().map { tab($0.element, active: $0.offset == 1) }
        let size = CGSize(width: 640, height: PaneTabStripLadder.stripHeight)
        let rig = Self.rig(strip(items), size: size)
        let lens = try #require(rig.box(Pixel.lensProbe), "no lens on the active chip")
        let face = Pixel.at(rig.capture(), width: size.width, CGPoint(x: lens.midX, y: lens.minY + 6))
        let bare = Pixel.at(Self.rig(Color(red: 1, green: 0, blue: 1), size: CGSize(width: 20, height: 20)).capture(),
                            width: 20, CGPoint(x: 10, y: 10))
        #expect(abs(Int(face.0) - Int(bare.0)) <= 3 && abs(Int(face.1) - Int(bare.1)) <= 3
                    && abs(Int(face.2) - Int(bare.2)) <= 3,
                "the lens's face is \(face), not the bare probe \(bare) — something is drawn over it")
    }

    /// **The overflow menu's glass is a 22pt capsule, the ＋'s height.** AppKit sizes a borderless
    /// menu to its own 16pt and ignores the label's frame, so the first version, which took the
    /// label's 26pt at its word, drew a 10pt sliver. Read per control: the menu and the ＋ are the
    /// strip's two cyan runs.
    @Test(.machinePinned(.pixelSampling))
    func theOverflowMenusGlassIsAsTallAsTheNewTabButtons() throws {
        let titles = (1...9).map { "Folder number \($0)" }
        let items = titles.enumerated().map { tab($0.element, active: $0.offset == 0) }
        let width: CGFloat = 640
        let layout = PaneTabStripLadder.layout(
            available: width - 2 * PaneTabStripLadder.stripGutter, titles: titles, scale: 1)
        try #require(layout.showsOverflow && layout.rung != .chip, "the fixture is meant to fold tabs into the menu")
        let size = CGSize(width: width, height: PaneTabStripLadder.stripHeight)
        let runs = Pixel.columnRuns(Self.rig(strip(items), size: size).capture(), width: width, Pixel.chromeProbe)
        try #require(runs.count == 2, "want the menu's capsule and the ＋'s circle, got \(runs)")
        let (menu, plus) = (runs[0], runs[1])
        #expect(abs(plus.height - PaneTabStripLadder.plusSide) <= 1.01, "the ＋'s glass is \(plus)")
        #expect(abs(menu.height - plus.height) <= 1.01,
                "the overflow menu's glass is \(menu) — not the ＋'s \(plus.height)pt height")
        #expect(menu.width > menu.height, "the overflow menu's glass is \(menu) — not a capsule")
    }

    // MARK: - RD46.4 / 46.5 / 46.6 · The capsules

    /// A capsule bar's fitted size, so the expected lens edges come from the bar itself.
    static func fittingSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view.fixedSize()))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// Today's marker colour in these fixtures: pure green, passed as the capsule's `accent`, so
    /// the Solid render's marker can be found exactly — and compared with where the lens lands.
    static let markerGreen = Color(red: 0, green: 1, blue: 0)
    nonisolated static let isMarkerGreen: Pixel.Match = { r, g, b in g > 229 && r < 26 && b < 26 }

    /// **The lens lands exactly where today's marker is drawn** — the strongest call-site claim
    /// there is, and one that needs no knowledge of the control's internal insets. For the first
    /// and the last segment: render Solid and find the green marker, render the probe and find the
    /// lens, and require the same rectangle. Then require the two segments' lenses to differ, so a
    /// lens stuck on one segment cannot pass.
    static func expectLensOnTodaysMarker<V: View>(first: V, last: V,
                                                  sourceLocation: SourceLocation = #_sourceLocation) {
        let size = fittingSize(first)
        let canvas = CGSize(width: size.width + 40, height: size.height + 10)
        var lenses: [CGRect] = []
        for (name, view) in [("first", AnyView(first.fixedSize())), ("last", AnyView(last.fixedSize()))] {
            let solid = rig(view, size: canvas, appearance: .today).capture()
            let glass = rig(view, size: canvas).capture()
            let marker = Pixel.box(solid, width: canvas.width, isMarkerGreen)
            let lens = Pixel.box(glass, width: canvas.width, Pixel.lensProbe)
            guard let marker, let lens else {
                Issue.record("\(name): marker \(String(describing: marker)), lens \(String(describing: lens))",
                             sourceLocation: sourceLocation)
                continue
            }
            #expect(Pixel.same(marker, lens),
                    "\(name): lens \(lens) is not today's marker \(marker)", sourceLocation: sourceLocation)
            // The chosen label: white on Solid's fill, black on light-mode glass (`selectionLensLabelInk`).
            #expect(Pixel.count(solid, width: canvas.width, in: marker, Pixel.whiteInk) > 10,
                    "\(name): Solid's chosen label is not white on its fill", sourceLocation: sourceLocation)
            // Inset 4pt: a capsule leaves its box's corners to the light track behind it.
            let face = lens.insetBy(dx: 4, dy: 4)
            let white = Pixel.count(glass, width: canvas.width, in: face, Pixel.whiteInk)
            let dark = Pixel.count(glass, width: canvas.width, in: face, Pixel.blackInk)
            #expect(white == 0 && dark > 10,
                    "\(name): the chosen label on glass is not dark — \(white) white, \(dark) dark pixels",
                    sourceLocation: sourceLocation)
            lenses.append(lens)
        }
        if lenses.count == 2 {
            #expect(lenses[1].minX > lenses[0].maxX - 1, "the lens did not move", sourceLocation: sourceLocation)
        }
    }

    @Test(.machinePinned(.pixelSampling))
    func editsModeCapsuleHostsItsLens() {
        Self.expectLensOnTodaysMarker(
            first: EditorModeBar(mode: .constant(.edit), accent: Self.markerGreen, onAccent: .white, forcedRung: .labelled),
            last: EditorModeBar(mode: .constant(.split), accent: Self.markerGreen, onAccent: .white, forcedRung: .labelled))
    }

    @Test(.machinePinned(.pixelSampling))
    func editsModeCapsuleHostsItsLensOnTheGlyphRungToo() {
        Self.expectLensOnTodaysMarker(
            first: EditorModeBar(mode: .constant(.edit), accent: Self.markerGreen, onAccent: .white, forcedRung: .glyphOnly),
            last: EditorModeBar(mode: .constant(.split), accent: Self.markerGreen, onAccent: .white, forcedRung: .glyphOnly))
    }

    @Test(.machinePinned(.pixelSampling))
    func storagesSectionCapsuleHostsItsLensIncludingAll() {
        // All is the absence of a section; it must still be a place the lens can sit.
        Self.expectLensOnTodaysMarker(
            first: StorageSectionBar(section: .constant(nil), accent: Self.markerGreen, onAccent: .white, forcedRung: .labelled),
            last: StorageSectionBar(section: .constant(StorageSection.allCases.last), accent: Self.markerGreen,
                                    onAccent: .white, forcedRung: .labelled))
    }

    @Test(.machinePinned(.pixelSampling))
    func editsRailTabsHostTheirLens() {
        Self.expectLensOnTodaysMarker(
            first: EditorRailTabBar(tab: .constant(.files), accent: Self.markerGreen, onAccent: .white).frame(width: 232),
            last: EditorRailTabBar(tab: .constant(.outline), accent: Self.markerGreen, onAccent: .white).frame(width: 232))
    }

    // MARK: - RD46.13 · Restructure's crowding chips

    static func restructure(_ filter: DeadWeightClass) -> RestructureLens {
        RestructureLens(
            findings: [], hasProfile: true, folderCount: 3013,
            deadWeight: ["Travel/2019": .empty, "Finance/IN/2013-2014": .empty,
                         "Work/EMP/Offer Letter": .singleFileLeaf, "Photos/2011": .passThrough],
            accent: markerGreen, onReveal: { _ in }, hasReviewed: true,
            initialCrowdingFilter: filter)
    }

    /// Pure green at the chip's 0.18 wash over white — `(0.82, 1, 0.82)`. Nothing else on the lens
    /// is that pale a green: the accent's own uses are pure green, and its anti-aliased edges are
    /// not grey-balanced the way a flat wash is.
    nonisolated static let isGreenWash: Pixel.Match = { r, g, b in
        g > 247 && (194...224).contains(r) && (194...224).contains(b) && abs(Int(r) - Int(b)) < 8
    }

    static let restructureCanvas = CGSize(width: 720, height: 520)

    /// The lens once it has grown onto the chip Solid washes, or the box it was left at.
    ///
    /// The fixture's filter is SEEDED — `RestructureLens` applies `initialCrowdingFilter` in its
    /// own `onAppear`, after the lens has mounted with nothing chosen — so the lens grows in, the
    /// way it does when someone picks a chip, and the first frame shows it at opacity 0. Waited for
    /// in main-actor turns, not seconds (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"),
    /// and until it MATCHES the washed chip: "two reads in a row agree" was the first condition, and
    /// two frames of a growth the starved clock had not advanced between agree as well.
    static func grownLens(_ filter: DeadWeightClass) async throws
        -> (lens: CGRect?, washed: CGRect, rig: ProbeRig<AnyView>, pumps: Int) {
        let solid = rig(restructure(filter), size: restructureCanvas, appearance: .today)
        // The chip row is the wash's FIRST run of rows: the open list below it paints pale green too.
        let rep = solid.capture()
        let top = try #require(Pixel.box(rep, width: restructureCanvas.width, isGreenWash), "Solid drew no washed chip")
        var bottom = top.minY
        while bottom + 1 < restructureCanvas.height,
              Pixel.count(rep, width: restructureCanvas.width, rows: (bottom + 1)...(bottom + 1), isGreenWash) > 0 {
            bottom += 1
        }
        let band = (top.minY - 3)...(bottom + 3)
        let washedInBand = try #require(Pixel.box(rep, width: restructureCanvas.width, rows: band, isGreenWash))
        let glass = rig(restructure(filter), size: restructureCanvas)
        var lens: CGRect?
        let wait = await LayoutPumpWait.pump(glass.host, upTo: 15) {
            lens = glass.box(rows: band, Pixel.lensProbe)
            return Pixel.same(lens, washedInBand)
        }
        return (lens, washedInBand, glass, wait.pumps)
    }

    @Test(.machinePinned(.pixelSampling), arguments: [DeadWeightClass.passThrough, .empty])
    func restructuresCrowdingChipsHostTheirLens(filter: DeadWeightClass) async throws {
        let (lens, washed, rig, pumps) = try await Self.grownLens(filter)
        #expect(Pixel.same(lens, washed),
                "after \(pumps) passes the lens is \(String(describing: lens)), not the washed chip \(washed)")
        #expect(rig.box(rows: (washed.minY - 3)...(washed.maxY + 3), Self.isGreenWash) == nil,
                "today's wash must step aside for the lens")
    }

    @Test(.machinePinned(.pixelSampling))
    func restructuresLensMovesWithTheFilter() async throws {
        let a = try #require(try await Self.grownLens(.passThrough).lens)
        let b = try #require(try await Self.grownLens(.empty).lens)
        #expect(b.minX > a.maxX, "the lens did not move with the filter — \(a) then \(b)")
    }

    @Test(.machinePinned(.pixelSampling))
    func solidDrawsNoLensOnTheTabStrip() {
        let items = [tab("Documents", active: true), tab("Photos", active: false)]
        #expect(Self.probeBox(strip(items), size: CGSize(width: 640, height: PaneTabStripLadder.stripHeight),
                              appearance: SelectionLensAppearance(level: .solid, hue: .blue, tint: 0,
                                                                  drawsProbe: true)) == nil)
    }

    // MARK: - The destination picker's rail

    /// The rail the picker is modelled on Settings' after, and it now draws its highlighted row the
    /// same way: a lens exactly where Solid fills the row, the row's label white on that fill and
    /// black on the glass.
    @Test(.machinePinned(.pixelSampling))
    func theDestinationRailHostsItsLens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lens-rail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = ScratchDefaults("SelectionLensCallSiteTests-picker")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        let picker = DestinationPicker(
            request: DestinationRequest(sourcePaths: ["/x/a.txt"], firstItemName: "a.txt", isMove: true,
                                        providerRoot: dir.path, providerName: "Projects", openAt: dir.path),
            availableSize: CGSize(width: 700, height: 540), recents: [],
            onCommit: { _ in }, onChooseOther: {}, onCancel: {})
            .defaultAppStorage(defaults)
        let size = CGSize(width: 640, height: 480)
        let fill = Pixel.near(LiquidGlassHue.blue.accentFillColor)
        let solid = Self.rig(picker, size: size, appearance: .today).capture()
        let glass = Self.rig(picker, size: size).capture()
        // The lens is the only magenta in the card; Solid's row is read in the lens's band of rows
        // and its leftmost run, because the accent fills other things in the card too (the footer's
        // Move button, below).
        let lens = try #require(Pixel.columnRuns(glass, width: size.width, Pixel.lensProbe).first,
                                "the probe drew nothing — the rail hosts no lens")
        let marker = try #require(Pixel.columnRuns(solid, width: size.width, rows: (lens.minY - 3)...(lens.maxY + 3),
                                                   fill).first, "Solid highlighted no rail row")
        #expect(Pixel.same(marker, lens), "lens \(lens) is not the highlighted row \(marker)")
        #expect(Pixel.count(solid, width: size.width, in: marker, Pixel.whiteInk) > 10,
                "Solid's highlighted label is not white on its fill")
        let face = lens.insetBy(dx: 4, dy: 4)
        let white = Pixel.count(glass, width: size.width, in: face, Pixel.whiteInk)
        let dark = Pixel.count(glass, width: size.width, in: face, Pixel.blackInk)
        #expect(white == 0 && dark > 10, "the highlighted label on glass is not dark — \(white) white, \(dark) dark")
    }
}
