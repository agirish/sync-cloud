import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// The pane bar's Delete rung: when it is offered at all, when it is live, and what it promises.
///
/// Three of the four claims here are checked in PAINT rather than in state, and that is deliberate.
/// A SwiftUI `Button` is not an `NSControl` — a unit test cannot click it and cannot read its
/// enabled flag back — so "disabled with an empty selection" asserted against the `selectionCount`
/// that produced it would be the model compared to itself. What a person actually sees is a red
/// trash or a grey one, so that is what is counted.
@MainActor
@Suite(.serialized) struct PaneBarDeleteTests {

    // MARK: - Availability

    /// A header with no delete handler does not offer the item — the gate that keeps every existing
    /// header test, snapshot and ladder measurement building exactly the bar it built before.
    @Test func testAHeaderWithNoHandlerOffersNoDelete() {
        #expect(!Self.header(onDelete: nil).availableItems.contains(.delete))
    }

    /// …and one that passes a handler does. Asserted alongside its negative because a gate that
    /// answers "no" in both directions is indistinguishable from a control that was never wired.
    @Test func testAHeaderWithAHandlerOffersDelete() {
        #expect(Self.header(onDelete: {}).availableItems.contains(.delete))
    }

    /// Availability does not depend on the selection: an empty selection disables the rung, it does
    /// not remove it. A control that vanished when there was nothing selected would take its own
    /// space with it and reflow the bar on every click in the tree.
    @Test func testAnEmptySelectionStillOffersTheItem() {
        #expect(Self.header(onDelete: {}, selectionCount: 0).availableItems.contains(.delete))
    }

    // MARK: - The promise in the tooltip

    /// The tooltip says the confirmation is unconditional. Without that sentence, someone who
    /// switched "Confirm before deleting" off reads the prompt as the setting being broken.
    @Test func testTheHelpSaysItAlwaysAsks() {
        let help = Self.header(onDelete: {}, selectionCount: 2).deleteHelp
        #expect(help.contains("always asks first"))
        #expect(help.contains("even with confirmations turned off"))
        // Names the number, so the button says what it would take before it is pressed.
        #expect(help.contains("2 selected items"))
    }

    /// With nothing selected it explains the disabled state instead of promising an act.
    @Test func testTheHelpExplainsTheDisabledState() {
        let help = Self.header(onDelete: {}, selectionCount: 0).deleteHelp
        #expect(help.contains("select something first"))
        #expect(!help.contains("always asks first"))
    }

    /// One item is not "1 selected items".
    @Test func testTheHelpNamesASingleItemInTheSingular() {
        #expect(Self.header(onDelete: {}, selectionCount: 1).deleteHelp.contains("the selected item"))
    }

    // MARK: - What is painted

    /// The rung is live only with a selection, measured as the eye measures it: the trash wears
    /// `SemanticColor.error` when it can act and the neutral chrome ink when it cannot.
    ///
    /// Mutation-tested by dropping the `.disabled(selectionCount == 0)` and the count-dependent
    /// `foregroundStyle` in turn: with either gone the two renders stop differing and this fails.
    @Test(.machinePinned(.pixelSampling)) func testTheTrashIsRedOnlyWhenSomethingIsSelected() throws {
        let empty = try Self.redPixels(inBarOf: Self.header(onDelete: {}, selectionCount: 0))
        let selected = try Self.redPixels(inBarOf: Self.header(onDelete: {}, selectionCount: 3))

        #expect(empty == 0, "a disabled Delete must not wear the destructive colour")
        #expect(selected > 20, "the enabled Delete paints its glyph red — measured \(selected) px")
    }

    /// The guard on the measurement above: a header that draws NO trash at all would also report
    /// zero red pixels, and the empty-selection case would pass for the wrong reason.
    ///
    /// **`ink > 40` was not that guard.** The crop is the trailing HALF of a 700pt header holding
    /// six rungs, so forty pixels of ink is met by the neighbours alone — wrap the Delete button in
    /// `if selectionCount > 0` instead of `.disabled(…)` and every assertion in this file still
    /// passed, which is exactly the regression the file's own prose names: Delete vanishing rather
    /// than dimming, so the bar reflows on every click.
    ///
    /// The differential is the guard, and it needs no coordinates: a header built WITHOUT the rung
    /// is the control, and the rung's own ink is what the two crops differ by. Asserted in both
    /// selection states, because "drawn but dimmed" and "drawn and red" are both drawn.
    @Test(.machinePinned(.pixelSampling)) func testTheRungIsDrawnInBothStates() throws {
        // An ink COUNT cannot answer this, and two attempts at one have now failed here. Forty
        // pixels of ink is met by the neighbours alone; and a differential against a header built
        // WITHOUT the rung fails too, because removing a rung lets the others reflow into the crop
        // and the total barely moves. Both mutations survived.
        //
        // Differing pixels can answer it. Dimming recolours the trash in place, so the two
        // selection states differ in a small, local patch; making it VANISH reflows every rung to
        // its left, so they differ almost everywhere. The bound separates the two.
        let dimmed = try Self.rendered(Self.header(onDelete: {}, selectionCount: 0))
        let enabled = try Self.rendered(Self.header(onDelete: {}, selectionCount: 3))
        let differing = Self.differingPixels(dimmed, enabled)
        let cropped = dimmed.pixelsWide * Self.barRows(dimmed).count

        #expect(differing > 0, "nothing changed between the two selection states at all")
        #expect(Double(differing) < Double(cropped) * 0.12,
                "\(differing) of \(cropped) pixels moved between selection states — the bar is reflowing rather than dimming, so every click resizes it")
    }

    // MARK: - Fixtures

    /// The bitmap rows the **bar** occupies — the header's upper row.
    ///
    /// Every crop in this file used to be the trailing HALF, for a reason that has expired: the
    /// provider capsule carried brand colour at the leading edge and a crop spanning both would have
    /// made the measurement about the wrong control. The capsule is retired, and the bar it was
    /// holding the leading edge against now packs left — so a trailing-half crop is bare header, and
    /// both measurements here read zero.
    ///
    /// The bar was never the trailing half; it is the upper of the header's two rows. The header
    /// renders at exactly `LiquidGlass.headerHeight` here and its pills end well above the midpoint,
    /// so the top half is the bar's band and the breadcrumb's is below it.
    static func barRows(_ rep: NSBitmapImageRep) -> Range<Int> {
        0..<(rep.pixelsHigh / 2)
    }

    private static func header(onDelete: (() -> Void)?, selectionCount: Int = 1) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            onDelete: onDelete, selectionCount: selectionCount)
    }

    /// Renders the header wide enough that nothing folds into ⋯, against a pinned arrangement and
    /// a pinned appearance — the machine's own customized bar and system theme must not decide
    /// what this test measures.
    static func rendered(_ header: PaneHeader) throws -> NSBitmapImageRep {
        let defaults = ScratchDefaults("PaneBarDeleteTests-render")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let size = CGSize(width: 700, height: LiquidGlass.headerHeight)
        let host = NSHostingView(rootView: AnyView(
            header
                .defaultAppStorage(defaults)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        ))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels in the bar's half of the header that are unmistakably red — more red than green and
    /// blue by a margin no anti-aliased grey can reach.
    private static func redPixels(inBarOf header: PaneHeader) throws -> Int {
        try count(in: header) { px in
            px.redComponent - px.greenComponent > 0.25 && px.redComponent - px.blueComponent > 0.25
        }
    }

    /// Pixels in the same crop that depart from the background at all — "something is drawn here".
    private static func inkPixels(inBarOf header: PaneHeader) throws -> Int {
        try count(in: header) { px in
            px.redComponent < 0.72 || px.greenComponent < 0.72 || px.blueComponent < 0.72
        }
    }

    /// Pixels that differ between two renders, over the same bar-row crop. Counting what MOVED is
    /// the only measurement that separates "recoloured in place" from "removed, and the neighbours
    /// slid over".
    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for x in 0..<a.pixelsWide {
            for y in barRows(a) {
                guard let pa = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let pb = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = abs(pa.redComponent - pb.redComponent)
                    + abs(pa.greenComponent - pb.greenComponent)
                    + abs(pa.blueComponent - pb.blueComponent)
                if d > 0.05 { differing += 1 }
            }
        }
        return differing
    }

    private static func count(in header: PaneHeader,
                              where matches: (NSColor) -> Bool) throws -> Int {
        let rep = try rendered(header)
        var hits = 0
        for x in 0..<rep.pixelsWide {
            for y in barRows(rep) {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if matches(px) { hits += 1 }
            }
        }
        return hits
    }
}
