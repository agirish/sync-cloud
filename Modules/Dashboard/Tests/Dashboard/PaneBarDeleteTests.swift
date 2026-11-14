import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// The pane bar's Delete rung: when it is offered, when it is live, and what it promises.
///
/// Whether it is live is checked in paint, not state. A SwiftUI `Button` is not an `NSControl`, so a
/// test can't click it or read its enabled flag, and checking `selectionCount` would compare the
/// model to itself. A person sees a red trash or a grey one, so that is what is counted.
@MainActor
@Suite(.serialized) struct PaneBarDeleteTests {

    // MARK: - Availability

    /// A header with no delete handler doesn't offer the item, so header tests and ladder
    /// measurements that pass none build a bar without it.
    @Test func testAHeaderWithNoHandlerOffersNoDelete() {
        #expect(!Self.header(onDelete: nil).availableItems.contains(.delete))
    }

    /// …and one that passes a handler does, or a gate that always says no would look the same as a
    /// control never wired. An empty selection disables the rung, it doesn't remove it: a control
    /// that vanished would reflow the bar on every click in the tree.
    @Test func testAHeaderWithAHandlerOffersDeleteEvenWithNothingSelected() {
        #expect(Self.header(onDelete: {}).availableItems.contains(.delete))
        #expect(Self.header(onDelete: {}, selectionCount: 0).availableItems.contains(.delete))
    }

    // MARK: - The promise in the tooltip

    /// The tooltip says the confirmation is unconditional, or someone who switched "Confirm before
    /// deleting" off would read the prompt as a broken setting.
    @Test func testTheHelpSaysItAlwaysAsks() {
        let help = Self.header(onDelete: {}, selectionCount: 2).deleteHelp
        #expect(help.contains("always asks first"))
        #expect(help.contains("even with confirmations turned off"))
        // Names the number, so the button says what it would take before it's pressed.
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

    /// The rung is live only with a selection, measured as the eye sees it: the trash wears
    /// `SemanticColor.error` when it can act and neutral chrome ink when it can't. Dropping
    /// `.disabled(selectionCount == 0)` or the count-dependent `foregroundStyle` must fail it.
    @Test(.machinePinned(.pixelSampling)) func testTheTrashIsRedOnlyWhenSomethingIsSelected() throws {
        let empty = try Self.redPixels(inBarOf: Self.header(onDelete: {}, selectionCount: 0))
        let selected = try Self.redPixels(inBarOf: Self.header(onDelete: {}, selectionCount: 3))

        #expect(empty == 0, "a disabled Delete must not wear the destructive colour")
        #expect(selected > 20, "the enabled Delete paints its glyph red — measured \(selected) px")
    }

    /// Guards the measurement above: a header that draws no trash at all would also show zero red
    /// pixels, and the empty-selection case would pass for the wrong reason. Wrapping Delete in
    /// `if selectionCount > 0` instead of `.disabled(…)` must fail it.
    @Test(.machinePinned(.pixelSampling)) func testTheRungIsDrawnInBothStates() throws {
        // An ink count can't answer this: the neighbours alone supply plenty of ink, and removing a
        // rung lets the others reflow into the crop. Differing pixels can. Dimming recolours the
        // trash in place, so the two states differ in a small patch; vanishing reflows the rungs
        // beside it, so they differ almost everywhere. The bound separates the two.
        let dimmed = try Self.rendered(Self.header(onDelete: {}, selectionCount: 0))
        let enabled = try Self.rendered(Self.header(onDelete: {}, selectionCount: 3))
        let differing = Self.differingPixels(dimmed, enabled)
        let cropped = dimmed.pixelsWide * Self.barRows(dimmed).count

        #expect(differing > 0, "nothing changed between the two selection states at all")
        #expect(Double(differing) < Double(cropped) * 0.12,
                "\(differing) of \(cropped) pixels moved between selection states — the bar is reflowing rather than dimming, so every click resizes it")
    }

    // MARK: - Fixtures

    /// The bitmap rows the bar occupies: the upper of the header's two rows. The header renders at
    /// exactly `LiquidGlass.headerHeight` here and its pills end well above the midpoint, so the top
    /// half is the bar's band and the breadcrumb's is below. The bar packs left, so a crop by x
    /// would miss it.
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

    /// Renders the header wide enough that nothing folds into ⋯, with a pinned arrangement and
    /// appearance, so the machine's own bar and theme don't decide what is measured.
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

    /// Pixels in the bar's half of the header that are unmistakably red, by a margin over green and
    /// blue that no anti-aliased grey reaches.
    private static func redPixels(inBarOf header: PaneHeader) throws -> Int {
        try count(in: header) { px in
            px.redComponent - px.greenComponent > 0.25 && px.redComponent - px.blueComponent > 0.25
        }
    }

    /// Pixels that differ between two renders over the bar-row crop: what separates "recoloured in
    /// place" from "removed, and the neighbours slid over".
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
