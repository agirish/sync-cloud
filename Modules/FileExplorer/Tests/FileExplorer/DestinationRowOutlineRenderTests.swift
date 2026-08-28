import Testing
import AppKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// The destination picker's chosen row, **rendered and measured at the corners**.
///
/// `DestinationColumn`'s row drew a `Radius.chip` rounded rect for its chosen ground and then took
/// `.segment`'s CAPSULE default for its hover wash. On a row this shape a capsule's radius is half
/// the height — more than twice `Radius.chip` — so the wash pulled its ends well inside the accent
/// fill and a chosen row showed a pill floating in a rounded rectangle, with its own highlight
/// visible round the outside of the thing meant to be highlighting it.
///
/// **The wash itself is not renderable, so no test here paints one.** `.onHover` is driven by an
/// `NSTrackingArea`, and in an offscreen window there is no pointer to enter it: mounting the row
/// and delivering a synthesised `mouseEntered`/`mouseMoved` to the hosting view — directly and
/// through `sendEvent`, before and after `orderFrontRegardless()`, with `acceptsMouseMovedEvents`
/// set — moves the render by exactly zero pixels, measured. The defect therefore has to be
/// approached from three sides, and **no one of them is sufficient**:
///
/// 1. `HoverAffordanceOutlineTests` — the outline draws exactly what the style used to draw, and a
///    capsule differs from a `Radius.chip` rounded rect over 732 pixels of a row this size.
/// 2. Here, `theChosenRowsGroundHasTheOutlineTheStyleIsHanded` — the ground the row really paints
///    is measured out of a live column and matched against rendered references. This pins the
///    ground; it is **blind to the wash**, and stays green if `shape:` is dropped from the button
///    style. That was verified by mutation, not assumed.
/// 3. `theStyleIsHandedTheSameOutlineTheGroundIsDrawnFrom` — the half (2) cannot see: that the
///    style is handed the same constant the ground is drawn from.
///
/// `.machinePinned(.pixelSampling)` on the tests that read pixels — the pin is per test rather than
/// on the suite, so the two that read no pixels still run on CI.
@MainActor
@Suite(.serialized) struct DestinationRowOutlineRenderTests {

    static let columnWidth: CGFloat = 240
    static let columnHeight: CGFloat = 200
    /// Pure blue, so the chosen row's accent ground is separable from grey text and folder glyphs
    /// on one channel. Passed explicitly rather than defaulted for `PaneTabStripRenderTests`'
    /// reason: the system accent is a machine setting, and a test reading blue out of it would be
    /// reading System Settings.
    static let accent = Color(red: 0, green: 0, blue: 1)

    func listing(_ names: [String]) -> DestinationFolderListing {
        DestinationFolderListing(folders: names.map { DestinationFolder(path: "/Users/x/Docs/\($0)") },
                                 outcome: .listed)
    }

    /// Mounts a column with `chosen` highlighted and returns the bitmap.
    ///
    /// `controlActiveState` pinned for the reason `PaneTabStripRenderTests` measured: without it
    /// SwiftUI renders the inactive-window desaturated variant and every colour read here is of
    /// something the user never sees. The backdrop is a flat opaque fill rather than the picker's
    /// card, because a glass wrapper renders its subject as white through a bare hosting view.
    func render(names: [String], chosen: String) -> NSBitmapImageRep {
        let subject = DestinationColumn(directory: "/Users/x/Docs",
                                        listing: listing(names),
                                        highlighted: "/Users/x/Docs/\(chosen)",
                                        onPathAt: nil,
                                        accent: Self.accent,
                                        onOpen: { _ in })
            .frame(width: Self.columnWidth, height: Self.columnHeight)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(x: 0, y: 0, width: Self.columnWidth, height: Self.columnHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("no bitmap rep")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Every pixel carrying the accent ground: bluer than white by a clear margin, and not the
    /// near-black of the row's text or the saturated blue of its folder glyph.
    ///
    /// The ground is `accent` at `PaneSelectionWash.active` (0.22) over white, so it is a pale blue
    /// — around 0.78 on red and green, 1.0 on blue. The glyph is the accent at full strength, which
    /// is why red is bounded from BELOW as well: without that the test would trace the outline of
    /// the folder icon.
    func groundMask(_ rep: NSBitmapImageRep) -> [[Bool]] {
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: rep.pixelsWide),
                            count: rep.pixelsHigh)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let blueLead = c.blueComponent - (c.redComponent + c.greenComponent) / 2
                mask[y][x] = blueLead > 0.08 && c.redComponent > 0.55 && c.redComponent < 0.95
            }
        }
        return mask
    }

    /// The chosen row's ground, located and measured: its size in points, and how far its corner
    /// runs before the edge reaches full width — which for a rounded rect is its radius.
    ///
    /// Scanlines are kept only when their run is at least half the widest run found, which is what
    /// separates the ground from the antialiased fringe of the folder glyph on the row ABOVE it.
    /// That fringe is accent-coloured and a few pixels wide; taking a naive bounding box over every
    /// masked pixel put the top of the ground 40pt too high and reported a 105pt corner.
    func groundGeometry(_ rep: NSBitmapImageRep) -> (size: CGSize, corner: CGFloat)? {
        let mask = groundMask(rep)
        var runs: [Int: (lo: Int, hi: Int)] = [:]
        for y in 0..<mask.count {
            let xs = (0..<mask[y].count).filter { mask[y][$0] }
            if let lo = xs.first, let hi = xs.last { runs[y] = (lo, hi) }
        }
        guard let widest = runs.values.map({ $0.hi - $0.lo }).max(), widest > 0 else { return nil }
        let band = runs.filter { $0.value.hi - $0.value.lo >= widest / 2 }
        guard let top = band.keys.min(), let bottom = band.keys.max() else { return nil }
        let left = band.values.map(\.lo).min()!
        let right = band.values.map(\.hi).max()!

        // The first scanline at full width. Everything above it is corner.
        let full = (top...bottom).first { y in
            guard let r = band[y] else { return false }
            return r.lo <= left && r.hi >= right
        } ?? top
        let perPoint = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        return (CGSize(width: CGFloat(right + 1 - left) / perPoint,
                       height: CGFloat(bottom + 1 - top) / perPoint),
                CGFloat(full - top) / perPoint)
    }

    /// The same corner measurement taken on a bare outline of known shape, so the row's corner is
    /// compared against rendered references rather than against a number written down here.
    ///
    /// This matters more than it looks: a continuous rounded rect's corner does not run for exactly
    /// its radius, and the topmost scanline is antialiased, so any hand-written expectation would be
    /// a tolerance nobody could justify. Measuring both candidates the same way through the same
    /// mask cancels all of it.
    func referenceCorner(_ shape: HoverAffordanceShape, size: CGSize) -> CGFloat? {
        let subject = shape.outline
            .fill(Self.accent.opacity(PaneSelectionWash.active))
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return groundGeometry(rep)?.corner
    }

    // MARK: - The row's ground is the shape the style is handed

    /// **The fix, measured.** The chosen row's ground is read out of a live column, its corner
    /// measured, and compared against the same corner measured on the two candidate outlines: the
    /// one the row now hands the style, and the capsule it used to take by default.
    ///
    /// The row must match its own outline and NOT the capsule. Asserting both directions is the
    /// point — "close to a 6pt rounded rect" alone would also be satisfied by a ground that had
    /// quietly squared off, and this is a test about two shapes agreeing, not about one of them.
    @Test(.machinePinned(.pixelSampling)) func theChosenRowsGroundHasTheOutlineTheStyleIsHanded() throws {
        let rep = render(names: ["Invoices", "Receipts", "Statements"], chosen: "Receipts")
        let row = try #require(groundGeometry(rep),
                               "no accent ground found — the chosen row did not draw one")
        let chip = try #require(referenceCorner(DestinationRowShape.kind, size: row.size))
        let capsule = try #require(referenceCorner(.capsule, size: row.size))

        #expect(DestinationRowShape.kind == .roundedRect(Radius.chip))
        // The two references must be far enough apart for the comparison below to mean anything —
        // on a row this shape they are about 6pt and about half its height.
        #expect(capsule - chip > 4,
                "the two candidate outlines measure \(chip)pt and \(capsule)pt on a \(row.size.width)×\(row.size.height) row; they are too close to tell apart, so the rest of this test proves nothing")
        #expect(abs(row.corner - chip) < 1.5,
                "the chosen row's corner measures \(row.corner)pt, against \(chip)pt for the outline it hands the style — the ground and the wash are drawing different shapes again")
        #expect(abs(row.corner - capsule) > abs(row.corner - chip),
                "the chosen row's corner (\(row.corner)pt) is nearer a capsule's \(capsule)pt than its own outline's \(chip)pt — the row is back on the capsule default")
    }

    /// The two surfaces that draw a non-capsule ground name their outline once, and it is a rounded
    /// rect. A capsule here would mean the ground itself had changed, not just the affordance.
    @Test func bothSurfacesNameTheirOutlineOnceAndAgree() {
        #expect(DestinationRowShape.kind == .roundedRect(Radius.chip))
        #expect(PaneTabStrip.chipShape == .roundedRect(Radius.chip))
        // Derived, not restated — the whole reason a drift is unrepresentable rather than untested.
        #expect(DestinationRowShape.outline.kind == DestinationRowShape.kind)
        #expect(PaneTabStrip.chipOutline.kind == PaneTabStrip.chipShape)
    }

    /// Every `hoverAffordance(…)` call in `text`, each as its complete expression — opening paren
    /// to the matching close, continuation lines and all.
    static func hoverAffordanceCalls(in text: String) -> [String] {
        var calls: [String] = []
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: "hoverAffordance(", range: search) {
            var depth = 0
            var i = text.index(before: hit.upperBound)   // the opening paren itself
            var end: String.Index?
            while i < text.endIndex {
                if text[i] == "(" { depth += 1 }
                if text[i] == ")" {
                    depth -= 1
                    if depth == 0 { end = text.index(after: i); break }
                }
                i = text.index(after: i)
            }
            let close = end ?? text.endIndex
            calls.append(String(text[hit.lowerBound..<close]))
            search = close..<text.endIndex
        }
        return calls
    }

    // MARK: - What the render above cannot see

    /// **The render test is blind to the regression it was written for, and this is the half that
    /// is not.**
    ///
    /// Measured, not assumed: dropping `shape:` from any of `DestinationPicker`'s three button
    /// styles — which is character for character the bug this whole audit is about — leaves
    /// `theChosenRowsGroundHasTheOutlineTheStyleIsHanded` green. It has to. The ground still draws
    /// itself from `DestinationRowShape.outline`, that constant still says `Radius.chip`, and the
    /// affordance that would disagree with it is never painted, because `.onHover` is driven by an
    /// `NSTrackingArea` and an offscreen window has no pointer to enter it. Seven ways of forcing
    /// one were tried — `mouseEntered` and `mouseMoved` delivered to the hosting view directly and
    /// through `sendEvent`, each before and after `orderFrontRegardless()`, with
    /// `acceptsMouseMovedEvents` set and tracking areas refreshed — and every one moved the render
    /// by exactly zero pixels.
    ///
    /// So the fact that the ground and the style share one value is checked where it is written.
    /// This is a source scan and inherits the weaknesses of one. It counts the `.segment` sites in
    /// each file it names, so a fourth appearing in either one fails here rather than sliding in —
    /// but **it knows only about these two files**, and a control in a third that grows a rounded
    /// ground is exactly as invisible as `DestinationPicker` was until today. The rule that would
    /// have caught it is prose, on `HoverAffordanceShape.default(for:)`.
    @Test func theStyleIsHandedTheSameOutlineTheGroundIsDrawnFrom() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()

        // `expected` is the exact expression each `.segment` call site in that file must hand
        // `shape:`; `declaration` is the positive control that the constant is still there to hand.
        let sites: [(path: String, declaration: String, expected: String, sites: Int)] = [
            ("Modules/FileExplorer/Sources/FileExplorer/DestinationPicker.swift",
             "static let kind = HoverAffordanceShape.", "shape: DestinationRowShape.kind", 3),
            ("Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift",
             "static let chipShape = HoverAffordanceShape.", "shape: Self.chipShape", 1),
        ]
        for site in sites {
            let text = try String(contentsOf: repo.appendingPathComponent(site.path), encoding: .utf8)
            // The positive control. A renamed constant or a moved file would otherwise make every
            // check below vacuously true by matching nothing at all — an absence check that cannot
            // tell "not there" from "not looked for" is worth nothing.
            guard text.contains(site.declaration) else {
                Issue.record("`\(site.declaration)` is gone from \(site.path) — this list is stale, not clean")
                continue
            }
            // **`.segment` is not always written as `.segment`, and a call site is not always one
            // line.** Three of this file's call sites spell the variant `isSelected ? .filled :
            // .segment`, so the obvious grep — the one the audit that produced this test started
            // from — matches `hoverAffordance(.segment` and misses every one of them; two of the
            // three were defects, unnoticed for exactly that reason. Two of them then wrap `shape:`
            // onto a continuation line, so a line-at-a-time scan reports those two as defects that
            // are not. Whole call expressions, matched by parenthesis balance, are the only reading
            // that gets both right.
            let styled = Self.hoverAffordanceCalls(in: text).filter { $0.contains(".segment") }
            #expect(styled.count == site.sites,
                    "\(site.path) has \(styled.count) `.segment` call sites, not the \(site.sites) this test knows about — audit the new one before updating this number")
            for line in styled {
                #expect(line.contains(site.expected),
                        "\(site.path) hands `.segment` a shape that is not `\(site.expected)`, so the affordance and the ground it lands on are two spellings again: \(line.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))")
            }
        }
    }
}
