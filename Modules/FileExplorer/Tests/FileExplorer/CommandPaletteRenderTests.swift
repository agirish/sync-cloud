import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// The palette, **rendered and read back**, in light and dark.
///
/// ## Why pixels, on a view whose every decision is elsewhere
///
/// `CommandPaletteTests` proves the routing. It cannot see whether the row that carries a route is
/// legible, whether the disabled row's *reason* survives the layout, or whether the highlight is
/// visible at all — and this codebase's own record is that geometry and ink counts do not see what a
/// person sees. Four defects have shipped past green suites here and been caught by rendering.
///
/// Two claims in particular can only be made in pixels:
///
/// - **The reason on an unavailable row is drawn**, not merely present in the model. It is the row's
///   trailing text on a row whose title may be long; a layout that dropped it would leave an
///   unmounted source looking like an ordinary one.
/// - **The highlight is drawn on the selected row and only there**, in both schemes. The palette is
///   driven entirely by ↑ ↓ ↩, so a highlight that did not render would leave every keystroke
///   landing somewhere invisible.
///
/// **`.machinePinned(.pixelSampling)`** — it reads pixels out of a live renderer.
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
            people: [Person(id: "p.aditi", displayName: "Aditi", relationship: "daughter",
                            fullNames: ["Aditi Girish"])],
            registry: PersonRegistry(people: [Person(id: "p.aditi", displayName: "Aditi",
                                                     relationship: "daughter",
                                                     fullNames: ["Aditi Girish"])]),
            isScanning: false, hasSurvey: true)
    }

    static func rows(_ query: String) -> [PaletteRow] {
        PaletteRouter.rows(query: query, index: index())
    }

    /// Mounts the palette over a plain backdrop and returns the whole canvas.
    ///
    /// The scrim is part of the subject: it is what tells the eye the palette owns the window, and
    /// it is drawn from `glassLevel.overlayScrimOpacity` rather than by this view, so a level that
    /// stopped dimming would show up here.
    static func render(query: String, selection: Int?, scheme: ColorScheme) -> NSBitmapImageRep {
        let rows = rows(query)
        let subject = CommandPaletteView(
            rows: rows,
            query: .constant(query),
            selection: .constant(selection),
            accent: .blue,
            glassLevel: .frosted,
            onRun: { _ in },
            onClose: {})
            .frame(width: canvas.width, height: canvas.height)
            .background(scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.13)
                                        : Color(red: 0.91, green: 0.92, blue: 0.93))
            .environment(\.colorScheme, scheme)
            // **The app pins this and so must the harness.** SwiftUI materials thin out and
            // DESATURATE when the window is not key, and a borderless test window never is: without
            // it the whole card renders greyscale and every colour assertion here reads zero. That
            // is not a product bug — `ContentView` sets exactly this on the real window — it is the
            // harness measuring an inactive-window rendering the user never sees.
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
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

    /// Mounts **the results list on its own**, without the card's glass wrapper.
    ///
    /// **Measured, not assumed:** a plain blue rectangle renders blue through a bare
    /// `NSHostingView` and comes back WHITE through the same host once `contentSurface` +
    /// `groundedGlassCard` is wrapped around it. So the whole-card render above can see the text
    /// and nothing about the selection highlight — which is the one thing a keyboard-only surface
    /// depends on. `PaletteResultsList` exists to be measurable here, the same reason
    /// `ScopeChipLabel` is extracted from `TidyView`.
    static func renderList(rows: [PaletteRow], selection: Int?, scheme: ColorScheme,
                           width: CGFloat = 620, height: CGFloat = 460) -> NSBitmapImageRep {
        let subject = PaletteResultsList(rows: rows, selection: .constant(selection),
                                         accent: .blue, onChoose: {})
            .frame(width: width, height: height, alignment: .top)
            .background(scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.13)
                                        : Color(red: 0.98, green: 0.98, blue: 0.99))
            .environment(\.colorScheme, scheme)
            .environment(\.controlActiveState, .active)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
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

    /// Pixels differing between two same-sized images.
    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let pa = a.colorAt(x: x, y: y), let pb = b.colorAt(x: x, y: y) else { continue }
                if abs(pa.redComponent - pb.redComponent) > 0.01
                    || abs(pa.greenComponent - pb.greenComponent) > 0.01
                    || abs(pa.blueComponent - pb.blueComponent) > 0.01 { differing += 1 }
            }
        }
        return differing
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

    /// Pixels that are not the image's own corner — **read from the bitmap, never from an
    /// `NSColor` built by hand.** `NSColor(white:alpha:)` is in the generic gray space, and asking
    /// it for `redComponent` throws rather than converting; the corner pixel comes out of the same
    /// sRGB bitmap as everything it is compared against.
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

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func thePaletteDrawsItsCardAndRows(scheme: ColorScheme) {
        let rep = Self.render(query: "", selection: 0, scheme: scheme)
        // A card, a field and a dozen rows is a lot of paint. The floor is set well under what an
        // intact render produces and well over what a scrim alone would.
        #expect(Self.inked(rep) > 60_000,
                "the palette painted almost nothing in \(scheme) — a blank card, not a blank page")
    }

    // MARK: The highlight is real, and it is where the selection says

    /// Moving the selection must move paint, and the paint must be the **accent**.
    ///
    /// Two renders differing only in `selection`. A highlight that was not drawn, or was drawn in a
    /// fixed place, makes these identical; a highlight drawn in some neutral wash passes the
    /// difference check and fails the accent one, which is the failure this suite was written after
    /// finding — the fill came back white and the row's white-on-accent label was invisible on it.
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

    /// **↓ moves DOWN the screen.** The rows are ranked by score and drawn in that order, so the
    /// selection index and the vertical position agree — the first cut grouped them and drew the
    /// groups in a fixed order, which put index 2 *above* index 0 and made ↓ jump upward on a
    /// surface that has no other way to navigate.
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

    /// Two different queries produce two different lists — the discriminating check this codebase
    /// keeps needing, because a card clipped to stubs compares equal to itself and passes anything
    /// weaker.
    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func twoDifferentQueriesRenderDifferentLists(scheme: ColorScheme) {
        let legal = Self.render(query: "legal", selection: 0, scheme: scheme)
        let medical = Self.render(query: "medical", selection: 0, scheme: scheme)
        #expect(Self.differingPixels(legal, medical) > 1_000,
                "two different queries rendered the same palette in \(scheme)")
    }

    /// The empty-query landing and a typed query are different pages. If the field's text never
    /// reached the view, or the list never recomputed, these would coincide.
    @Test func theEmptyLandingIsNotTheSameAsAQueriedList() {
        #expect(Self.differingPixels(Self.render(query: "", selection: 0, scheme: .light),
                                     Self.render(query: "legal", selection: 0, scheme: .light)) > 2_000)
    }
}
