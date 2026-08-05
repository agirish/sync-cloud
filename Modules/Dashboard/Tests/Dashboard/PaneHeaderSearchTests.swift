import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import Dashboard

/// The pane header's search field: where it appears, what it costs the header, and how ↩/⇧↩ reach
/// the walk.
@MainActor
@Suite struct PaneHeaderSearchTests {

    final class Box: ObservableObject {
        @Published var query = ""
        @Published var isExpanded = false
        @Published var advances: [Bool] = []
    }

    private static func header(_ box: Box, summary: String? = nil,
                               withSearch: Bool = true) -> some View {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud", imageName: "icloud-logo",
                                    path: "/root", type: .iCloud),
            rootPath: "/root",
            relativePath: "Documents",
            canGoBack: true, canGoForward: false,
            onBack: {}, onForward: {}, onNavigate: { _ in }, onNavigateBoth: { _ in },
            sortOption: .constant(.name),
            onRefresh: {},
            showHiddenFiles: .constant(false),
            viewMode: .constant(.columns),
            onNewFolder: {},
            searchText: withSearch ? Binding(get: { box.query }, set: { box.query = $0 }) : nil,
            searchIsExpanded: withSearch ? Binding(get: { box.isExpanded }, set: { box.isExpanded = $0 }) : nil,
            searchSummary: summary,
            onSearchAdvance: withSearch ? { box.advances.append($0) } : nil
        )
    }

    private static func laidOutHeight(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: - The header's rung

    /// **The constraint this feature had to live inside.** `PaneHeaderHeightTests` pins the header to
    /// `LiquidGlass.headerHeight`, because that is what puts the pane's header↔list boundary on the
    /// same 83.5 as Tidy's card. The field takes the BAR's row rather than adding one, so the number
    /// cannot move — open or closed, and at the narrow width where the bar is already stepping down.
    @Test("The header keeps its rung with the field closed")
    func theClosedHeaderKeepsItsHeight() {
        let box = Box()
        #expect(Self.laidOutHeight(Self.header(box), width: 560) == LiquidGlass.headerHeight)
        #expect(Self.laidOutHeight(Self.header(box), width: 250) == LiquidGlass.headerHeight)
    }

    @Test("…and with the field open, which is the row it took")
    func theOpenHeaderKeepsItsHeight() {
        let box = Box()
        box.isExpanded = true
        #expect(Self.laidOutHeight(Self.header(box, summary: "2 of 7"), width: 560) == LiquidGlass.headerHeight)
        #expect(Self.laidOutHeight(Self.header(box, summary: "No matches"), width: 250) == LiquidGlass.headerHeight)
    }

    // MARK: - The way out

    /// **The field must not take the whole bar.** It did, and the result was reported as "NO way to
    /// exit": the pane bar is replaced while the field is open, the field's own clear button only
    /// exists once there is text to clear, and once focus moves to the file list Escape goes with
    /// it — so an empty search field on a wide pane offered no target of any kind.
    ///
    /// The cap is what leaves a stretch of bar to click. Measured against the LAID-OUT field, not
    /// the constant: a `.frame(maxWidth:)` that failed to apply would still read 460 in the source.
    @Test("The field is capped, so there is bar left to click away on")
    func theFieldLeavesSomewhereToClick() async {
        let box = Box()
        box.isExpanded = true
        let width: CGFloat = 1200
        let window = Self.mount(Self.header(box, summary: "2 of 7"), width: width)
        let shown = await LayoutPumpWait.pump(window, upTo: 5) { Self.fieldEditor(window) != nil }
        #expect(shown.held, "the revealed field should exist (\(shown.pumps) pumps)")
        guard let field = Self.fieldEditor(window), let root = window.contentView else { return }

        let fieldRight = field.convert(field.bounds, to: root).maxX
        #expect(fieldRight < width - 200,
                "a \(width)pt header should leave a wide dead zone after the field, got \(fieldRight)")
        #expect(PaneHeader.searchFieldMaxWidth < width,
                "the cap has to bind at a realistic pane width or it is not a cap")
    }

    /// …and the cap must not starve the field on a narrow pane, where it is the only thing on the
    /// row. The 250pt pane is the split's own clamp — the narrowest the bar ever gets.
    @Test("A narrow pane still gets a usable field")
    func theFieldStillFitsANarrowPane() async {
        let box = Box()
        box.isExpanded = true
        let window = Self.mount(Self.header(box), width: 250)
        let shown = await LayoutPumpWait.pump(window, upTo: 5) { Self.fieldEditor(window) != nil }
        #expect(shown.held, "the field should render at 250pt (\(shown.pumps) pumps)")
        guard let field = Self.fieldEditor(window) else { return }
        #expect(field.bounds.width > 60, "the field collapsed to \(field.bounds.width)pt")
    }

    /// A header in a real window. The revealed field is an AppKit-backed text view and does not
    /// materialize in a bare `NSHostingView` — without the window these tests find nothing and would
    /// have to pass vacuously.
    private static func mount(_ view: some View, width: CGFloat) -> NSWindow {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 120)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    // MARK: - There is always something to click

    /// **The reported defect, stated as an assertion: an EMPTY search field drew no control at
    /// all.** `ExpandingSearchField`'s clear button is conditional on there being text, this row
    /// replaces the pane bar while it is open, and Escape only reaches the field while the caret is
    /// in it — so a field with nothing typed, on a pane whose focus had moved to the file list, had
    /// no exit by any means. That is what "NO way to exit" was.
    ///
    /// Counted in painted pixels, and it has to be: SwiftUI's `Button` is not an `NSControl` and
    /// leaves nothing in the AppKit tree to find, so a structural search cannot see it. Measured in
    /// the band just past the text, inside the field's own surface, where the ✕ sits.
    @Test("The revealed field always offers a control, even with nothing typed")
    func anEmptyFieldStillHasAWayOut() async {
        let box = Box()
        box.isExpanded = true
        box.query = ""
        let window = Self.mount(Self.header(box), width: 900)
        let shown = await LayoutPumpWait.pump(window, upTo: 5) { Self.fieldEditor(window) != nil }
        #expect(shown.held, "the field should be revealed (\(shown.pumps) pumps)")
        guard let editor = Self.fieldEditor(window), let host = window.contentView else { return }

        // The band just past the text, still inside the field's surface — where the ✕ sits. Located
        // from the LAID-OUT field rather than guessed: the field is capped at 460pt and left-aligned,
        // so most of a 900pt header is dead zone, and the first version of this test measured
        // exactly that and read zero for entirely the wrong reason.
        let text = editor.convert(editor.bounds, to: host)
        let controls = NSRect(x: text.maxX, y: 0, width: 44, height: host.bounds.height / 2)
        #expect(Self.ink(in: controls, of: host) > 0,
                "an empty field must still draw a dismiss control — this is the reported bug")

        // The discriminator: an equally sized band out in the dead zone must read zero, or the
        // threshold is counting the field's own fill and would pass with no ✕ at all.
        let deadZone = NSRect(x: host.bounds.width - 60, y: 0, width: 44, height: host.bounds.height / 2)
        #expect(Self.ink(in: deadZone, of: host) == 0,
                "the dead zone should be blank — otherwise this measurement cannot see a control")
    }

    /// Dismissing closes the field AND drops the query — a query left live behind a hidden field is
    /// a filter you cannot see or undo. Both ways out call this one function; that they call it is
    /// not reachable from a test (see `PaneHeader.dismissSearch`).
    @Test("Dismissing closes the field and clears the query")
    func dismissingClearsAndCloses() {
        let box = Box()
        box.isExpanded = true
        box.query = "tax"
        Self.searchingHeader(box).dismissSearch()
        #expect(!box.isExpanded)
        #expect(box.query.isEmpty)
    }

    /// A header with no search bindings must not act on a dismissal it has no state for.
    @Test("Dismissing a header that has no search is inert")
    func dismissingWithoutSearchIsInert() {
        let plain = PaneHeader(
            title: "Left", provider: nil, rootPath: "/root", relativePath: "",
            canGoBack: false, canGoForward: false,
            onBack: {}, onForward: {}, onNavigate: { _ in }, onNavigateBoth: { _ in },
            sortOption: .constant(.name), showHiddenFiles: .constant(false))
        plain.dismissSearch()   // must not trap
    }

    /// Pixels appreciably darker than the field's own surface, inside `rect` (view coordinates).
    private static func ink(in rect: NSRect, of host: NSView) -> Int {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / host.bounds.height
        var ink = 0
        for px in Int(rect.minX * scaleX)..<Int(rect.maxX * scaleX) {
            for py in Int(rect.minY * scaleY)..<Int(rect.maxY * scaleY) {
                guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                      let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                c.getRed(&r, green: &g, blue: &b, alpha: &a)
                if a > 0.5, (r + g + b) / 3 < 0.72 { ink += 1 }
            }
        }
        return ink
    }

    // MARK: - What the bar offers

    /// A header with no search bindings offers no magnifier — which is why every existing header
    /// test, snapshot and ladder measurement is untouched by this feature. If this ever answered
    /// true, those would all be measuring a bar one pill wider than the one they were written for.
    @Test("A header with no search bindings has no Search item to place")
    func aHeaderWithoutSearchOffersNoMagnifier() {
        let box = Box()
        let plain = PaneHeader(
            title: "Left", provider: nil, rootPath: "/root", relativePath: "",
            canGoBack: false, canGoForward: false,
            onBack: {}, onForward: {}, onNavigate: { _ in }, onNavigateBoth: { _ in },
            sortOption: .constant(.name), showHiddenFiles: .constant(false))
        #expect(!plain.availableItems.contains(.search))
        // …and one WITH them does, or the pill could never be drawn at all.
        #expect(Self.searchingHeader(box).availableItems.contains(.search))
    }

    /// Needed as a concrete `PaneHeader` (not `some View`) so `availableItems` is reachable.
    private static func searchingHeader(_ box: Box) -> PaneHeader {
        PaneHeader(
            title: "Left", provider: nil, rootPath: "/root", relativePath: "",
            canGoBack: false, canGoForward: false,
            onBack: {}, onForward: {}, onNavigate: { _ in }, onNavigateBoth: { _ in },
            sortOption: .constant(.name), showHiddenFiles: .constant(false),
            searchText: Binding(get: { box.query }, set: { box.query = $0 }),
            searchIsExpanded: Binding(get: { box.isExpanded }, set: { box.isExpanded = $0 }))
    }

    /// The shipped bar carries it, at the trailing end — where the ladder gives it up first, which is
    /// right for the one control here that has a keyboard equivalent.
    @Test("The shipped arrangement carries Search last")
    func theDefaultBarCarriesSearchLast() {
        #expect(PaneBarArrangement.default.items.last == .search)
    }

    /// A bar someone arranged on an earlier build predates this case, so it does not carry the
    /// magnifier — and the customize sheet's palette has to be able to give it back. Shipping
    /// without this would make removing Search a one-way door for everyone who ever opened the
    /// sheet.
    @Test("A stored arrangement without Search offers it in the overflow, and the palette can add it")
    func searchIsRecoverableFromAStoredBar() {
        let box = Box()
        let stored = PaneBarArrangement(encoded: "flexibleSpace,backForward,scan,sort")
        #expect(!stored.items.contains(.search))
        #expect(stored.absent(from: Self.searchingHeader(box).availableItems).contains(.search))
        #expect(PaneBarCustomizeSheet.palette.contains(.search))
    }

    // MARK: - Walking from the field

    /// ↩ and ⇧↩ both arrive as `onSubmit`; the direction is the modifier state at that moment. The
    /// environment pin is what makes “this is a plain Return” part of the test rather than of the
    /// room — see `paneSearchSubmitModifiers`.
    @Test("A plain Return walks forward and Shift-Return walks back")
    func submitDirectionComesFromTheModifiers() async {
        for (modifiers, expected) in [(NSEvent.ModifierFlags(), false), (NSEvent.ModifierFlags.shift, true)] {
            let box = Box()
            box.isExpanded = true
            box.query = "tax"
            let host = NSHostingView(rootView:
                Self.header(box, summary: "1 of 3")
                    .environment(\.paneSearchSubmitModifiers, modifiers)
                    .frame(width: 560))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 120),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.layoutIfNeeded()

            // The field claims focus one Task hop after it appears, and only a focused field submits.
            let focused = await LayoutPumpWait.pump(window, upTo: 5) { Self.fieldEditor(window) != nil }
            #expect(focused.held, "the revealed field should have claimed focus (\(focused.pumps) pumps)")
            Self.fieldEditor(window)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            let walked = await LayoutPumpWait.pump(window, upTo: 5) { !box.advances.isEmpty }
            #expect(walked.held, "submitting should have walked the hits (\(walked.pumps) pumps)")
            #expect(box.advances == [expected],
                    "modifiers \(modifiers) should walk \(expected ? "backward" : "forward")")
        }
    }

    /// The revealed field's own text view, which is what a submission has to come from.
    private static func fieldEditor(_ window: NSWindow) -> NSTextView? {
        var found: NSTextView?
        func walk(_ v: NSView) {
            if found == nil, let text = v as? NSTextView, text.isEditable { found = text }
            for sub in v.subviews where found == nil { walk(sub) }
        }
        walk(window.contentView!)
        return found
    }
}
