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
                               matchCount: Int = 0, canAdvance: Bool = true,
                               withSearch: Bool = true) -> some View {
        PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud", imageName: "icloud-logo",
                                    rootPath: "/root", type: .iCloud),
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
            searchMatchCount: matchCount,
            onSearchAdvance: (withSearch && canAdvance) ? { box.advances.append($0) } : nil
        )
    }

    private static func laidOutHeight(_ view: some View, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: - The header's rung

    /// `PaneHeaderHeightTests` pins the header to `LiquidGlass.headerHeight`, which lines the pane's
    /// header↔list boundary up with the lens header card. The field takes the bar's row rather than
    /// adding one, so the height holds open or closed, and at the narrow width too.
    @Test("The header keeps its rung with the field closed", .machinePinned(.layoutMetrics))
    func theClosedHeaderKeepsItsHeight() {
        let box = Box()
        #expect(Self.laidOutHeight(Self.header(box), width: 560) == LiquidGlass.headerHeight)
        #expect(Self.laidOutHeight(Self.header(box), width: 250) == LiquidGlass.headerHeight)
    }

    @Test("…and with the field open, which is the row it took", .machinePinned(.layoutMetrics))
    func theOpenHeaderKeepsItsHeight() {
        let box = Box()
        box.isExpanded = true
        #expect(Self.laidOutHeight(Self.header(box, summary: "2 of 7"), width: 560) == LiquidGlass.headerHeight)
        #expect(Self.laidOutHeight(Self.header(box, summary: "No matches"), width: 250) == LiquidGlass.headerHeight)
    }

    // MARK: - The way out

    /// The field must not take the whole bar. The pane bar is replaced while the field is open, and
    /// once focus moves to the file list Escape goes with it, so the cap is what leaves a stretch of
    /// bar to click away on. Measured on the laid-out field, not the constant, so a
    /// `.frame(maxWidth:)` that failed to apply is caught.
    @Test("The field is capped, so there is bar left to click away on", .machinePinned(.layoutMetrics))
    func theFieldLeavesSomewhereToClick() async {
        let box = Box()
        box.isExpanded = true
        let width: CGFloat = 1200
        let window = Self.mount(Self.header(box, summary: "2 of 7"), width: width)
        let shown = await LayoutPumpWait.pump(window, upTo: 5) { FieldEditor.find(in: window) != nil }
        #expect(shown.held, "the revealed field should exist (\(shown.pumps) pumps)")
        guard let field = FieldEditor.find(in: window), let root = window.contentView else { return }

        let fieldRight = field.convert(field.bounds, to: root).maxX
        #expect(fieldRight < width - 200,
                "a \(width)pt header should leave a wide dead zone after the field, got \(fieldRight)")
        #expect(PaneHeader.searchFieldMaxWidth < width,
                "the cap has to bind at a realistic pane width or it is not a cap")
    }

    /// …and the cap must not starve the field on a narrow pane, where it is the only thing on the
    /// row. The 250pt pane is the split's own clamp — the narrowest the bar ever gets.
    @Test("A narrow pane still gets a usable field", .machinePinned(.layoutMetrics))
    func theFieldStillFitsANarrowPane() async {
        let box = Box()
        box.isExpanded = true
        let window = Self.mount(Self.header(box), width: 250)
        let shown = await LayoutPumpWait.pump(window, upTo: 5) { FieldEditor.find(in: window) != nil }
        #expect(shown.held, "the field should render at 250pt (\(shown.pumps) pumps)")
        guard let field = FieldEditor.find(in: window) else { return }
        #expect(field.bounds.width > 60, "the field collapsed to \(field.bounds.width)pt")
    }

    /// A header in a real window. The revealed field is an AppKit-backed text view that doesn't
    /// materialize in a bare `NSHostingView`, so without the window these tests would find nothing.
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

    /// An empty search field must still draw a way out. `ExpandingSearchField`'s clear button needs
    /// text, the row replaces the pane bar, and Escape only reaches the field while the caret is in
    /// it, so without a ✕ an empty field with focus elsewhere has no exit.
    ///
    /// Counted in painted pixels because SwiftUI's `Button` is not an `NSControl` and leaves nothing
    /// in the AppKit tree to find.
    @Test("The revealed field always offers a control, even with nothing typed", .machinePinned(.pixelSampling))
    func anEmptyFieldStillHasAWayOut() async {
        let box = Box()
        box.isExpanded = true
        box.query = ""
        let window = Self.mount(Self.header(box), width: 900)
        let shown = await LayoutPumpWait.pump(window, upTo: 5) { FieldEditor.find(in: window) != nil }
        #expect(shown.held, "the field should be revealed (\(shown.pumps) pumps)")
        guard let editor = FieldEditor.find(in: window), let host = window.contentView else { return }

        // The band just past the text, inside the field's surface, where the ✕ sits. Located from
        // the laid-out field: the field is capped and left-aligned, so most of a 900pt header is
        // dead zone, and a guessed band would read zero for the wrong reason.
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

    /// A stored arrangement may lack the magnifier, and ⋯ offers only controls the bar places, so
    /// the customize sheet's palette must be able to give it back. Otherwise removing Search would
    /// be a one-way door.
    @Test("A stored arrangement without Search does not hide it in ⋯, and the palette can add it")
    func searchIsRecoverableFromAStoredBar() {
        let box = Box()
        let stored = PaneBarArrangement(encoded: "flexibleSpace,backForward,scan,sort")
        #expect(!stored.items.contains(.search))
        let plan = PaneBarLayout.plan(arrangement: stored,
                                      available: Self.searchingHeader(box).availableItems,
                                      depth: 0)
        #expect(!plan.overflow.contains(.search), "the magnifier is back to living invisibly in ⋯")
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
            let focused = await LayoutPumpWait.pump(window, upTo: 5) { FieldEditor.find(in: window) != nil }
            #expect(focused.held, "the revealed field should have claimed focus (\(focused.pumps) pumps)")
            FieldEditor.find(in: window)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            let walked = await LayoutPumpWait.pump(window, upTo: 5) { !box.advances.isEmpty }
            #expect(walked.held, "submitting should have walked the hits (\(walked.pumps) pumps)")
            #expect(box.advances == [expected],
                    "modifiers \(modifiers) should walk \(expected ? "backward" : "forward")")
        }
    }

    // MARK: - Walking with the mouse

    /// The match count must come with buttons to walk it. ↩/⇧↩ appear only in the placeholder, which
    /// the query replaces, so without buttons the screen shows no way to walk.
    ///
    /// Counted in painted pixels against a control that differs only by the arrows (same summary,
    /// same ✕, `onSearchAdvance` withheld). A fixed ink threshold would count the counter and ✕ and
    /// pass with no arrows drawn.
    @Test("The counter comes with buttons to move it", .machinePinned(.pixelSampling))
    func theFieldDrawsWalkButtons() async {
        let width: CGFloat = 900
        func trailingInk(canAdvance: Bool) async -> (ink: Int, shown: Bool) {
            let box = Box()
            box.isExpanded = true
            box.query = "tax"
            let window = Self.mount(Self.header(box, summary: "2 of 7", matchCount: 7,
                                                canAdvance: canAdvance), width: width)
            let shown = await LayoutPumpWait.pump(window, upTo: 5) { FieldEditor.find(in: window) != nil }
            guard shown.held, let editor = FieldEditor.find(in: window), let host = window.contentView
            else { return (0, false) }
            // The controls band, from the end of the text editor, located from the laid-out editor
            // as in `anEmptyFieldStillHasAWayOut`.
            let text = editor.convert(editor.bounds, to: host)
            let band = NSRect(x: text.maxX, y: 0, width: 130, height: host.bounds.height)
            return (Self.ink(in: band, of: host), true)
        }

        let with = await trailingInk(canAdvance: true)
        let without = await trailingInk(canAdvance: false)
        #expect(with.shown && without.shown, "both fields should have revealed")
        #expect(without.ink > 0, "the control band reads zero even for the counter and ✕ — it is aimed wrong")
        #expect(with.ink > without.ink + 20,
                "the walk buttons paint nothing: \(with.ink) vs \(without.ink) with them withheld")
    }

    /// …and they go dim when there is nowhere to walk; live-looking arrows on "No matches" promise
    /// somewhere to go. Both arms use the same summary string, so only the arrows' state can move
    /// the count.
    @Test("With no hits the buttons are visibly disabled", .machinePinned(.pixelSampling))
    func theButtonsDimWithNothingToWalk() async {
        let width: CGFloat = 900
        func trailingInk(matchCount: Int) async -> Int {
            let box = Box()
            box.isExpanded = true
            box.query = "tax"
            let window = Self.mount(Self.header(box, summary: "2 of 7", matchCount: matchCount),
                                    width: width)
            let shown = await LayoutPumpWait.pump(window, upTo: 5) { FieldEditor.find(in: window) != nil }
            guard shown.held, let editor = FieldEditor.find(in: window), let host = window.contentView
            else { return -1 }
            let text = editor.convert(editor.bounds, to: host)
            return Self.ink(in: NSRect(x: text.maxX, y: 0, width: 130, height: host.bounds.height),
                            of: host)
        }

        let live = await trailingInk(matchCount: 7)
        let dead = await trailingInk(matchCount: 0)
        #expect(live >= 0 && dead >= 0, "both fields should have revealed")
        #expect(dead < live, "the buttons look identical with 0 hits and with 7: \(dead) vs \(live)")
    }

    /// The two buttons differ only in a Bool, and a swap is invisible on screen: a ▲ that walks
    /// forward draws like one that walks back.
    @Test("Previous walks back, next walks forward, and they say so")
    func theStepsPointOppositeWays() {
        #expect(PaneSearchStep.previous.reverse)
        #expect(!PaneSearchStep.next.reverse)
        #expect(PaneSearchStep.allCases.count == 2)
        #expect(Set(PaneSearchStep.allCases.map(\.systemImage)).count == 2, "both buttons draw the same glyph")
        #expect(Set(PaneSearchStep.allCases.map(\.label)).count == 2)
        #expect(PaneSearchStep.previous.label.contains("Previous"))
        #expect(PaneSearchStep.next.label.contains("Next"))
    }

    /// A tooltip naming a chord the field doesn't honour teaches a dead shortcut. Each button's
    /// chord is checked against `PaneSearchSubmit`, the table that routes ↩ and ⇧↩, not a second
    /// copy of the intent.
    @Test("The button chords match what submitting actually does")
    func theButtonChordsMatchWhatSubmitActuallyDoes() {
        for step in PaneSearchStep.allCases {
            let modifiers: NSEvent.ModifierFlags = step.chord.hasPrefix("⇧") ? .shift : []
            #expect(PaneSearchSubmit.action(modifiers: modifiers, hasOffer: false)
                    == .advance(reverse: step.reverse),
                    "\(step.label) advertises \(step.chord), which submits the other direction")
        }
    }
}
