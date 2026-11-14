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

    /// Click the magnifier, start typing: the revealed field holds the caret with no second click.
    /// Deleting the `.onAppear` focus claim from `ExpandingSearchField` must make this fail.
    ///
    /// It does not pin the component's `Task` hop, which guards against a `FocusState` write in
    /// the inserting transaction being dropped; no harness here reproduces that drop.
    /// **Don't drop the hop on the strength of this test.**
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
                (gave up after \(caret.pumps) passes)
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
        #expect(caret.held, "the revealed field must hold the caret in Frosted too (gave up after \(caret.pumps) passes)")
    }

    // MARK: The field's layout

    /// The field's layout, which Compare's header is laid out against: 6pt above and below, each
    /// accessory row 7pt below the one above. The risk is two accessory rows arriving as a nested
    /// `TupleView`: unless SwiftUI flattens it into the field's `VStack(spacing: 7)`, they lose the
    /// gap between them.
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

    /// Polls until a text editor holds first responder, pumping layout each pass so AppKit can
    /// finish standing up the field editor. 15s matches the ceiling the FileExplorer mounted
    /// suites use for a loaded run of the whole test host.
    private static func becomesEditingText(_ window: NSWindow,
                                           timeout: TimeInterval = 15) async -> (held: Bool, pumps: Int) {
        await LayoutPumpWait.pump(window, upTo: timeout) { isEditingText(window) }
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
