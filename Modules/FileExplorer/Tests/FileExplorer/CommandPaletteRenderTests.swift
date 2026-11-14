import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// The palette's results list, rendered and read back in light and dark.
///
/// `CommandPaletteTests` proves the routing; only pixels show whether the rows draw and whether the
/// highlight is on the selected row and only there. The list is driven entirely by ↑ ↓ ↩, so a
/// highlight that did not render would leave every keystroke landing somewhere invisible.
///
/// The subject is `PaletteResultsList` alone, the list under ⌘K's Go to field
/// (`GoToResultsPanel`), mounted without glass so the highlight is measurable.
///
/// `.machinePinned(.pixelSampling)`: it reads pixels out of a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct CommandPaletteRenderTests {

    static let root = "/Users/x/Documents"
    static let canvas = CGSize(width: 900, height: 700)

    static func index() -> PaletteIndex {
        PaletteIndex(
            providers: [PaletteProvider(id: "icloud", name: "iCloud", isMounted: true, isCurrent: true),
                        PaletteProvider(id: "ssd", name: "Backup SSD", isMounted: false, isCurrent: false)],
            providerRoot: root,
            folders: ["Finance", "Finance/US", "Finance/US/Income Tax", "Legal", "Medical"],
            recentFolders: ["Legal"], pinnedFolders: ["Finance/US"],
            people: [Person(id: "p.daughter", displayName: "Daughter", relationship: "daughter",
                            fullNames: ["Daughter Elder"])],
            registry: PersonRegistry(people: [Person(id: "p.daughter", displayName: "Daughter",
                                                     relationship: "daughter",
                                                     fullNames: ["Daughter Elder"])]),
            isScanning: false, hasSurvey: true)
    }

    static func rows(_ query: String) -> [PaletteRow] {
        PaletteRouter.rows(query: query, index: index())
    }

    /// Mounts the results list on its own, without a glass wrapper: offscreen, a blue rectangle
    /// inside `contentSurface` + `groundedGlassCard` reads back white, which would hide the
    /// selection highlight. `PaletteResultsList` is separate to be measurable here, as
    /// `ScopeChipLabel` is from `LensWorkspaceView`.
    static func renderList(rows: [PaletteRow], selection: Int?, scheme: ColorScheme,
                           width: CGFloat = 620, height: CGFloat = 460,
                           accent: Color = .blue) -> NSBitmapImageRep {
        let subject = PaletteResultsList(rows: rows, selection: .constant(selection),
                                         accent: accent, onChoose: {})
            .frame(width: width, height: height, alignment: .top)
            .background(scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.13)
                                        : Color(red: 0.98, green: 0.98, blue: 0.99))
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .active)
        // Laid out twice before it is cached.
        guard let rep = offscreenBitmap(subject, size: CGSize(width: width, height: height), appearance: scheme == .dark ? .darkAqua : .aqua,
                                        layoutPasses: 2) else {
            fatalError("no bitmap rep")
        }
        return rep
    }

    /// Pixels differing between two same-sized images.
    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        return PixelDiff.differingPixels(a, b, tolerance: 0.01)
    }

    /// Pixels that are recognisably the accent (blue clear of red and green) — the selection fill.
    static func accentPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.blueComponent - c.redComponent > 0.25 && c.blueComponent > 0.4 { count += 1 }
            }
        }
        return count
    }

    /// Pixels that are not the image's own corner. The corner is read from the bitmap, never built
    /// as an `NSColor`: `NSColor(white:alpha:)` is grey-space, and its `redComponent` throws.
    static func inked(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 1, y: 1) else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(c.redComponent - background.redComponent),
                       max(abs(c.greenComponent - background.greenComponent),
                           abs(c.blueComponent - background.blueComponent))) > 0.04 { count += 1 }
            }
        }
        return count
    }

    // MARK: It draws at all, in both schemes

    /// A blank-render smoke check only. An empty list paints nothing at all, which keeps the floor
    /// below meaningful. The floor tells blank from drawn and nothing finer: one row inks ~109,000
    /// and twenty ~151,000, so a list cut to one row still passes. Row-level regressions are caught
    /// by `theHighlightFollowsTheSelection`, `theSelectionMovesDownTheScreenAsTheIndexRises` and
    /// the two differing-pixel tests.
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theListDrawsItsRows(scheme: ColorScheme) {
        let rows = Self.rows("")
        #expect(rows.count > 4, "too few rows to tell — this test would be vacuous")
        let empty = Self.inked(Self.renderList(rows: [], selection: nil, scheme: scheme))
        #expect(empty == 0,
                "an empty results list painted \(empty) pixels in \(scheme) — it draws only rows, and the floor below is only meaningful while that holds")
        let drawn = Self.inked(Self.renderList(rows: rows, selection: 0, scheme: scheme))
        #expect(drawn > 50_000,
                "the results list rendered as a blank page in \(scheme) — \(drawn) ink, against ~150,000 measured intact")
    }

    // MARK: The highlight is real, and it is where the selection says

    /// Moving the selection must move paint, and the paint must be the accent. A highlight not
    /// drawn, or drawn in a fixed place, makes the two renders identical; one drawn in a neutral or
    /// white wash passes the difference check and fails the accent one, and hides the white label.
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theHighlightFollowsTheSelection(scheme: ColorScheme) {
        let rows = Self.rows("")
        let first = Self.renderList(rows: rows, selection: 0, scheme: scheme)
        let third = Self.renderList(rows: rows, selection: 2, scheme: scheme)
        #expect(Self.differingPixels(first, third) > 2_000,
                "moving the selection two rows changed almost nothing in \(scheme) — the highlight is not drawn")
        #expect(Self.accentPixels(first) > 3_000, "no accent fill under the selection in \(scheme)")
        #expect(Self.accentPixels(third) > 3_000, "no accent fill under the moved selection in \(scheme)")
    }

    /// The highlight is the deepened accent under a white label, the fill every other lit control
    /// takes. The raw accent with `Color.onFillLabel` would draw dark ink on Green. The ground is
    /// read back first and must match what was painted, so a colour-shifting read can't pass.
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theHighlightIsTheDeepenedAccent(scheme: ColorScheme) throws {
        let raw = try #require(NSColor(LiquidGlassHue.green.accentColor).usingColorSpace(.sRGB))
        let deepened = AccentFill.deepened(raw)
        #expect(PixelProbe.distance(raw, deepened) > 0.1, "Green's fill and raw accent are too close to tell apart")

        let rep = Self.renderList(rows: Self.rows(""), selection: 0, scheme: scheme,
                                  accent: LiquidGlassHue.green.accentColor)
        let ground = try #require(rep.colorAt(x: 1, y: rep.pixelsHigh - 2))
        let painted = scheme == .dark ? (0.11, 0.12, 0.13) : (0.98, 0.98, 0.99)
        #expect(abs(ground.redComponent - painted.0) < 0.005 && abs(ground.greenComponent - painted.1) < 0.005
                && abs(ground.blueComponent - painted.2) < 0.005,
                "the ground reads back as \(PixelProbe.describe(ground)), not the \(painted) it was painted")

        let fill = try #require(PixelProbe.dominant(in: rep) { PixelProbe.distance($0, ground) > 0.1 })
        #expect(PixelProbe.distance(fill, deepened) < 0.01,
                "the selected row fills with \(PixelProbe.describe(fill)) in \(scheme), not the deepened Green \(PixelProbe.describe(deepened))")
        // The label, inside the fill's own box: white there, and no dark ink.
        let box = try #require(PixelProbe.bounds(in: rep) { PixelProbe.distance($0, fill) < 0.01 })
        let scale = CGFloat(rep.pixelsWide) / 620
        let inner = box.insetBy(dx: 12 * scale, dy: 6 * scale)
        #expect(PixelProbe.count(in: rep, inner) { $0.isNearWhite } > 100, "no white label on the selected row in \(scheme)")
        #expect(PixelProbe.count(in: rep, inner) { $0.isDark } == 0, "the selected row's label is dark ink in \(scheme)")
    }

    /// A list with **nothing** selected draws no highlight. Without this, the test above is
    /// satisfied by a view that fills every row.
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func nothingSelectedDrawsNoHighlight(scheme: ColorScheme) {
        let rows = Self.rows("")
        let none = Self.renderList(rows: rows, selection: nil, scheme: scheme)
        let one = Self.renderList(rows: rows, selection: 0, scheme: scheme)
        #expect(Self.accentPixels(none) < Self.accentPixels(one) / 4,
                "a palette with no selection is still painting a highlight in \(scheme)")
    }

    /// ↓ moves down the screen: rows are drawn in score order, so the selection index and the
    /// vertical position agree. Drawing grouped rows in a fixed order would make ↓ jump upward.
    @Test func theSelectionMovesDownTheScreenAsTheIndexRises() {
        let rows = Self.rows("")
        #expect(rows.count > 4, "too few rows to tell the order — this test would be vacuous")
        func highlightMidpoint(_ index: Int) -> Double? {
            let rep = Self.renderList(rows: rows, selection: index, scheme: .light)
            var ys: [Int] = []
            for y in 0..<rep.pixelsHigh {
                for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if c.blueComponent - c.redComponent > 0.25 && c.blueComponent > 0.4 {
                        ys.append(y)
                        break
                    }
                }
            }
            guard let lo = ys.min(), let hi = ys.max() else { return nil }
            return Double(lo + hi) / 2
        }
        let top = try? #require(highlightMidpoint(0))
        let lower = try? #require(highlightMidpoint(3))
        #expect((lower ?? 0) > (top ?? 0) + 20,
                "row 3's highlight is not below row 0's — the drawn order does not match the selection order, so ↓ moves the highlight the wrong way")
    }

    // MARK: The rows say different things

    /// Two different queries produce two different lists: the discriminating check, because a list
    /// clipped to stubs compares equal to itself and passes anything weaker.
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func twoDifferentQueriesRenderDifferentLists(scheme: ColorScheme) {
        let legal = Self.renderList(rows: Self.rows("legal"), selection: 0, scheme: scheme)
        let medical = Self.renderList(rows: Self.rows("medical"), selection: 0, scheme: scheme)
        #expect(Self.differingPixels(legal, medical) > 1_000,
                "two different queries rendered the same list in \(scheme)")
    }
}
