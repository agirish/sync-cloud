import AppKit
import SwiftUI
import Testing
@testable import Design

/// A borderless window that can take key. Focus is only granted inside a key window, but ordering
/// one in would flash on the test machine's screen, so this stays off-screen and only becomes key.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Host-owned reveal state, so a test can flip it from outside the view: the field must be
/// inserted by a transaction the test controls, as the magnifier's `withAnimation` insert does.
@MainActor
private final class RevealBox: ObservableObject {
    @Published var isExpanded = false
}

@MainActor
@Suite(.serialized) struct ExpandingSearchFieldTests {

    // MARK: The deferred focus

    /// Click the magnifier, start typing: the real component, revealed by the toggle's animated
    /// transaction, comes up holding the caret with no second click. Deleting the `.onAppear`
    /// focus claim from `ExpandingSearchField` must make this fail.
    ///
    /// It does not pin the component's `Task` hop, which guards against a `FocusState` write in
    /// the inserting transaction being dropped. No harness here reproduces that drop, so this test
    /// can't show the hop is needed. **Don't drop the hop on the strength of this test.**
    @Test func revealedFieldClaimsFocusWithoutAClick() async throws {
        let box = RevealBox()
        let window = Self.host(RealFieldHarness(box: box))
        try await Task.sleep(for: .milliseconds(100))

        withAnimation(ExpandingSearch.animation) { box.isExpanded = true }

        // The focus claim is asynchronous twice over (the `.onAppear` Task hop, then FocusState to
        // AppKit first responder), so a fixed pump here flakes under suite load. The deadline is
        // a ceiling, not a wait: the poll returns as soon as the caret lands.
        let caret = await Self.becomesEditingText(window)
        #expect(caret.held,
                """
                the revealed field must hold the caret — no second click \
                (gave up after \(caret.passes) passes)
                """)
    }

    /// The same promise on the glass path, which Frosted (the default) takes. There the field's
    /// content is at opacity 0 for the first 0.12 s, just when the focus claim lands, so a field
    /// that refused the caret while invisible would reveal dead in glass alone.
    @Test func revealedFieldClaimsFocusOnTheGlassPathToo() async throws {
        let box = RevealBox()
        let window = Self.host(RealFieldHarness(box: box, appearance: SelectionLensAppearance(
            level: .frosted, hue: .blue, tint: 0)))
        try await Task.sleep(for: .milliseconds(100))
        withAnimation(ExpandingSearch.animation) { box.isExpanded = true }
        let caret = await Self.becomesEditingText(window)
        #expect(caret.held, "the revealed field must hold the caret in Frosted too (gave up after \(caret.passes) passes)")
    }

    // MARK: The field's layout

    /// The field's own layout, which Compare's header is laid out against: 6pt above and below,
    /// and each accessory row 7pt below the one above it. The rows are fixed-height blocks and the
    /// trailing slot is the tallest thing in the field's row, so every height is known exactly.
    /// The risk is the accessories slot: two rows arrive through a ViewBuilder as a nested
    /// `TupleView`, and unless SwiftUI flattens it into the field's `VStack(spacing: 7)` they lose
    /// the gap between them.
    @Test(arguments: [(false, false, CGFloat(52)), (true, false, 69), (false, true, 79), (true, true, 96)])
    func theFieldPadsItsRowAndSpacesItsAccessories(chips: Bool, suggestions: Bool, height: CGFloat) {
        let field = ExpandingSearchField(
            text: .constant(""), isExpanded: .constant(true), placeholder: "",
            trailing: { Color.clear.frame(width: 1, height: 40) },
            accessories: { _ in
                if chips { Color.clear.frame(height: 10) }
                if suggestions { Color.clear.frame(height: 20) }
            })
        #expect(laidOutHeight(field, width: 480) == height)
    }

    // MARK: Collapse semantics

    /// Escape and the toggle's second click share one path: collapsing always clears. A query
    /// left live behind a hidden field is a filter the user can neither see nor undo.
    @Test func collapseClearsTheQuery() {
        var text = "kind:pdf >5mb"
        var expanded = true
        ExpandingSearch.collapse(
            text: Binding(get: { text }, set: { text = $0 }),
            isExpanded: Binding(get: { expanded }, set: { expanded = $0 }),
            reduceMotion: false
        )
        #expect(text.isEmpty)
        #expect(expanded == false)
    }

    /// Collapsing an already-collapsed field is a no-op, not a crash or a resurrection.
    @Test func collapseIsIdempotent() {
        var text = ""
        var expanded = false
        for _ in 0..<3 {
            ExpandingSearch.collapse(
                text: Binding(get: { text }, set: { text = $0 }),
                isExpanded: Binding(get: { expanded }, set: { expanded = $0 }),
                reduceMotion: false
            )
        }
        #expect(text.isEmpty)
        #expect(expanded == false)
    }

    // MARK: The floor itself

    /// The floor outlives an expired deadline: with the deadline already spent, a condition that
    /// never holds is still evaluated `pumpFloor` times. The sweep in `docs/flaky-tests.md` ("Fixed
    /// pumps and fixed sleeps") finds only unfloored loops and can't see a floor deleted from this
    /// one, so this test is what guards it.
    ///
    /// Drives `pumpUntil`, not `becomesEditingText`: the caret can arrive on the first pass, and a
    /// condition already true would pass with the floor at zero.
    @Test func theFloorOutlivesAnExpiredDeadline() async {
        let window = Self.host(EmptyView())
        var evaluated = 0
        let outcome = await Self.pumpUntil(window, timeout: 0) {
            evaluated += 1
            return false
        }
        #expect(outcome.held == false, "the condition never holds — the wait must say so")
        #expect(evaluated >= Self.passesDemanded,
                """
                the deadline was spent before the first pass, so only the floor can carry this — \
                the condition was evaluated \(evaluated) times against a demand of \
                \(Self.passesDemanded)
                """)
    }

    /// Pins the production floor's value. The case above doesn't compare against `pumpFloor`,
    /// since a demand derived from it would drop to zero with the floor and pass against a wait
    /// with no floor at all.
    @Test func theProductionFloorIsFifty() {
        #expect(Self.pumpFloor == 50,
                "the floor every real wait here uses is now \(Self.pumpFloor) — see docs/flaky-tests.md mechanism 2")
        #expect(Self.passesDemanded <= Self.pumpFloor,
                "the demand above must be reachable within the floor, or it measures the deadline")
    }

    // MARK: Fixtures

    /// Mounts a view in an off-screen key window and lets AppKit lay it out.
    @discardableResult
    private static func host<V: View>(_ view: V) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 320)))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        let window = KeyableWindow(contentRect: host.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.makeKey()
        return window
    }

    /// Whether a text editor holds first responder. AppKit hands editing to a shared field editor
    /// (an `NSTextView`) rather than to the text field itself, so this asks the responder chain
    /// what it actually is instead of guessing at a concrete class.
    private static func isEditingText(_ window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        return responder.isKind(of: NSTextView.self)
    }

    /// Ten times what a starved run was measured to need, so the floor carries this wait on its
    /// own. Same number and reason as `LayoutPumpWait.pumpFloor`; this wait polls a window's first
    /// responder, not a hosting view's layout, so it keeps its own loop.
    private static let pumpFloor = 50

    /// What `theFloorOutlivesAnExpiredDeadline` demands. A literal, not derived from `pumpFloor`,
    /// so zeroing the floor can't zero the expectation with it.
    private static let passesDemanded = 25

    /// Pumps `window`'s layout until `condition` holds, or until both the deadline has passed and
    /// `pumpFloor` passes have been made.
    ///
    /// Seconds alone are the wrong bound: this waits on main-actor turns, which a congested host
    /// delivers at no fixed rate, so a longer ceiling buys nothing (`docs/flaky-tests.md`, "Fixed
    /// pumps and fixed sleeps"). The floor is the bound that means something. It takes no `floor:`
    /// argument, so nothing here can lower it.
    ///
    /// Returns the pass count too: a wait that gave up after a handful of passes was starved, one
    /// after a thousand was disproved, and elapsed time can't tell them apart.
    private static func pumpUntil(_ window: NSWindow, timeout: TimeInterval,
                                  _ condition: () -> Bool) async -> (held: Bool, passes: Int) {
        var passes = 0
        let deadline = Date().addingTimeInterval(timeout)
        while passes < pumpFloor || Date() < deadline {
            passes += 1
            window.layoutIfNeeded()
            if condition() { return (true, passes) }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return (condition(), passes + 1)
    }

    /// Polls until a text editor holds first responder, pumping layout each pass so AppKit can
    /// finish standing up the field editor. 15s matches the ceiling the FileExplorer mounted
    /// suites use for a loaded run of the whole test host.
    private static func becomesEditingText(_ window: NSWindow,
                                           timeout: TimeInterval = 15) async -> (held: Bool, passes: Int) {
        await pumpUntil(window, timeout: timeout) { isEditingText(window) }
    }
}

/// The real component, revealed the way the app reveals it: absent until the host flips
/// `isExpanded`, then inserted by that transaction.
private struct RealFieldHarness: View {
    @ObservedObject var box: RevealBox
    var appearance: SelectionLensAppearance = .today
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 1)
            if box.isExpanded {
                ExpandingSearchField(
                    text: $text,
                    isExpanded: Binding(get: { box.isExpanded }, set: { box.isExpanded = $0 }),
                    placeholder: "kind:pdf, >5mb…"
                )
            }
        }
        .environment(\.selectionLensAppearance, appearance)
        .environment(\._accessibilityReduceMotion, false)
        .environment(\._accessibilityReduceTransparency, false)
    }
}
