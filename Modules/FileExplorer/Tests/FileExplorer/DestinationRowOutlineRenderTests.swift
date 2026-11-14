import Testing
import AppKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// The destination picker's chosen row, rendered and measured at the corners. Its chosen ground is
/// a `Radius.chip` rounded rect, and its hover wash must be the same shape: `.segment`'s capsule
/// default would draw a pill inside the rounded rect, its ends well inside the accent fill.
///
/// The wash itself can't be rendered here: `.onHover` needs an `NSTrackingArea`, and synthesised
/// mouse events in an offscreen window move the render by zero pixels. So three checks, none
/// sufficient alone:
///
/// 1. `HoverAffordanceOutlineTests`: the outline draws what the style draws, and a capsule
///    differs visibly from a `Radius.chip` rounded rect at this size.
/// 2. `theChosenRowsGroundHasTheOutlineTheStyleIsHanded`: the ground the row paints matches
///    rendered references. Blind to the wash: it stays green if `shape:` is dropped.
/// 3. `theStyleIsHandedTheSameOutlineTheGroundIsDrawnFrom`: the style is handed the constant the
///    ground is drawn from.
///
/// `.machinePinned(.pixelSampling)` is per test, so the two that read no pixels still run on CI.
@MainActor
@Suite(.serialized) struct DestinationRowOutlineRenderTests {

    static let columnWidth: CGFloat = 240
    static let columnHeight: CGFloat = 200
    /// Pure blue, so the accent ground separates from grey text and folder glyphs on one channel.
    /// Passed explicitly, as in `PaneTabStripRenderTests`: the system accent is a machine setting.
    static let accent = Color(red: 0, green: 0, blue: 1)

    func listing(_ names: [String]) -> DestinationFolderListing {
        DestinationFolderListing(folders: names.map { DestinationFolder(path: "/Users/x/Docs/\($0)") },
                                 outcome: .listed)
    }

    /// Mounts a column with `chosen` highlighted and returns the bitmap. `controlActiveState` is
    /// pinned, as in `PaneTabStripRenderTests`, or SwiftUI renders the desaturated inactive variant.
    /// The backdrop is flat, not the picker's card: glass renders white through a bare host.
    func render(names: [String], chosen: String) -> NSBitmapImageRep {
        let subject = DestinationColumn(listing: listing(names),
                                        highlighted: "/Users/x/Docs/\(chosen)",
                                        onPathAt: nil,
                                        accent: Self.accent,
                                        onOpen: { _ in })
        guard let rep = bitmap(of: subject, size: CGSize(width: Self.columnWidth, height: Self.columnHeight)) else {
            fatalError("no bitmap rep")
        }
        return rep
    }

    /// `view` on white, light and active, laid out in a borderless sRGB window and cached.
    private func bitmap(of view: some View, size: CGSize) -> NSBitmapImageRep? {
        let subject = view
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
        // Laid out twice before it is cached.
        return offscreenBitmap(subject, size: size, appearance: .aqua, layoutPasses: 2)
    }

    /// Every pixel carrying the accent ground: bluer than white by a clear margin, and not the
    /// row's near-black text or its saturated folder glyph. The ground is `accent` at
    /// `PaneSelectionWash.active` over white, a pale blue; red is bounded from below too, or the
    /// mask would trace the full-strength folder icon.
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

    /// The chosen row's ground: its size in points, and how far its corner runs before the edge
    /// reaches full width (for a rounded rect, its radius). Only scanlines at least half the widest
    /// run are kept, which drops the accent-coloured fringe of the folder glyph on the row above.
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

    /// The same corner measurement on a bare outline of known shape, so the row is compared with
    /// rendered references, not a written number. A continuous rounded rect's corner doesn't run
    /// for exactly its radius and the top scanline is antialiased; measuring alike cancels both.
    func referenceCorner(_ shape: HoverAffordanceShape, size: CGSize) -> CGFloat? {
        let outline = shape.outline.fill(Self.accent.opacity(PaneSelectionWash.active))
        return bitmap(of: outline, size: size).flatMap { groundGeometry($0)?.corner }
    }

    // MARK: - The row's ground is the shape the style is handed

    /// The chosen row's ground, read from a live column, matches the outline it hands the style and
    /// not the capsule. Both directions, because "close to a rounded rect" alone would also pass a
    /// ground that had quietly squared off.
    @Test(.machinePinned(.pixelSampling)) func theChosenRowsGroundHasTheOutlineTheStyleIsHanded() throws {
        let rep = render(names: ["Invoices", "Receipts", "Statements"], chosen: "Receipts")
        let row = try #require(groundGeometry(rep),
                               "no accent ground found — the chosen row did not draw one")
        let chip = try #require(referenceCorner(DestinationRowShape.kind, size: row.size))
        let capsule = try #require(referenceCorner(.capsule, size: row.size))

        #expect(DestinationRowShape.kind == .roundedRect(Radius.chip))
        // The references must be far enough apart to mean anything: about 6pt and about half the
        // row's height.
        #expect(capsule - chip > 4,
                "the two candidate outlines measure \(chip)pt and \(capsule)pt on a \(row.size.width)×\(row.size.height) row; they are too close to tell apart, so the rest of this test proves nothing")
        #expect(abs(row.corner - chip) < 1.5,
                "the chosen row's corner measures \(row.corner)pt, against \(chip)pt for the outline it hands the style — the ground and the wash are drawing different shapes again")
        #expect(abs(row.corner - capsule) > abs(row.corner - chip),
                "the chosen row's corner (\(row.corner)pt) is nearer a capsule's \(capsule)pt than its own outline's \(chip)pt — the row is back on the capsule default")
    }

    /// The two surfaces that draw a non-capsule ground name their outline once, and neither is a
    /// capsule.
    ///
    /// They don't share a radius, on purpose: a tab chip takes `PaneTabStripLadder.chipRadius` to
    /// nest concentrically in the strip card (`theChipNestsConcentricallyInsideTheCard`), while a
    /// picker row sits in a card of its own. Tying them would drag the picker along with the strip.
    /// What is invariant: each derives its drawable outline from the value it hands the style.
    @Test func eachSurfaceNamesItsOutlineOnceAndNeitherIsACapsule() {
        // The picker's radius is the shared token, so naming it is a claim, not an echo.
        #expect(DestinationRowShape.kind == .roundedRect(Radius.chip))
        // The strip's is not: `chipShape` is defined as `.roundedRect(chipRadius)`, so that
        // equality would compare a constant to itself. This file claims only the shape, a rounded
        // rect and not a capsule; `theChipNestsConcentricallyInsideTheCard` checks the radius.
        for (name, shape) in [("the picker row", DestinationRowShape.kind),
                              ("the tab chip", PaneTabStrip.chipShape)] {
            switch shape {
            case .roundedRect(let r):
                #expect(r > 0, "\(name)'s outline is a rounded rect of radius \(r) — that is a rectangle")
            case .capsule, .circle:
                Issue.record("""
                             \(name) draws a ground but hands the style \(shape) — the wash will \
                             round past its corners, which is the defect this file exists for
                             """)
            }
        }
        // Derived, not restated, so a drift is unrepresentable rather than untested.
        #expect(DestinationRowShape.outline.kind == DestinationRowShape.kind)
        #expect(PaneTabStrip.chipOutline.kind == PaneTabStrip.chipShape)
    }

    /// Every `hoverAffordance(…)` call in `text`, each as its complete expression, from opening
    /// paren to matching close.
    static func hoverAffordanceCalls(in text: String) -> [String] {
        calls(of: "hoverAffordance(", in: text)
    }

    /// Every call of `name` (written with its opening parenthesis), whole, by parenthesis balance.
    static func calls(of name: String, in text: String) -> [String] {
        var calls: [String] = []
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: name, range: search) {
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

    /// The half the render test can't see. Dropping `shape:` from a `DestinationPicker` button style
    /// leaves `theChosenRowsGroundHasTheOutlineTheStyleIsHanded` green: the ground still draws from
    /// `DestinationRowShape.outline`, and the wash that would disagree is never painted offscreen.
    ///
    /// So the shared value is checked where it is written, by a source scan that counts the
    /// `.segment` sites in each file it names; a new site fails here. It knows only these two
    /// files: the rule for any other control is prose, on `HoverAffordanceShape.default(for:)`.
    @Test func theStyleIsHandedTheSameOutlineTheGroundIsDrawnFrom() throws {
        let repo = AppCopyScan.repoRoot

        // `expected` is the exact expression each `.segment` call site in that file must hand
        // `shape:`; `declaration` is the positive control that the constant is still there to hand.
        let sites: [(path: String, declaration: String, expected: String, sites: Int)] = [
            ("Modules/FileExplorer/Sources/FileExplorer/DestinationPicker.swift",
             // The three rows, the preview's actions and the new-folder row: all hand the
             // constant their grounds use.
             "static let kind = HoverAffordanceShape.", "shape: DestinationRowShape.kind", 5),
            ("Modules/FileExplorer/Sources/FileExplorer/PaneTabStrip.swift",
             "static let chipShape = HoverAffordanceShape.", "shape: Self.chipShape", 1),
        ]
        for site in sites {
            let text = try String(contentsOf: repo.appendingPathComponent(site.path), encoding: .utf8)
            // The positive control: a renamed constant or moved file would otherwise make every
            // check below pass by matching nothing.
            guard text.contains(site.declaration) else {
                Issue.record("`\(site.declaration)` is gone from \(site.path) — this list is stale, not clean")
                continue
            }
            // `.segment` is not always written `.segment`, and a call is not always one line: a
            // site may spell `isSelected ? .filled : .segment`, which a grep for
            // `hoverAffordance(.segment` misses, and wrap `shape:` onto a continuation line, which a
            // line scan misreads. Whole call expressions, matched by parenthesis balance, get both.
            //
            // `selectionLensChoiceButtonStyle` also takes `.segment` unless told otherwise (the
            // destination rail's rows), without spelling it.
            let styled = Self.hoverAffordanceCalls(in: text).filter { $0.contains(".segment") }
                + Self.calls(of: "selectionLensChoiceButtonStyle(", in: text)
                    .filter { !$0.contains("unselected:") || $0.contains("unselected: .segment") }
            #expect(styled.count == site.sites,
                    "\(site.path) has \(styled.count) `.segment` call sites, not the \(site.sites) this test knows about — audit the new one before updating this number")
            for line in styled {
                #expect(line.contains(site.expected),
                        "\(site.path) hands `.segment` a shape that is not `\(site.expected)`, so the affordance and the ground it lands on are two spellings again: \(line.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))")
            }
        }
    }
}
