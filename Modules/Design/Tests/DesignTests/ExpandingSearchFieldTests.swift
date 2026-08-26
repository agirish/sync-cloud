import AppKit
import SwiftUI
import Testing
@testable import Design

/// A borderless window that can take key. Focus is only ever granted inside a key window, so a
/// test that wants to observe real first-responder behaviour has to have one — but ordering a
/// window in would flash on the test machine's screen, so this stays off-screen and merely
/// *becomes* key.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Host-owned reveal state, so a test can flip it from OUTSIDE the view — which is the whole
/// point: the field has to be inserted by a transaction the test controls, exactly as the
/// magnifier's `withAnimation` insert does in the app.
@MainActor
private final class RevealBox: ObservableObject {
    @Published var isExpanded = false
}

@MainActor
@Suite(.serialized) struct ExpandingSearchFieldTests {

    // MARK: The deferred focus

    /// The user-visible promise: click the magnifier, start typing. The REAL component is
    /// revealed by a real animated transaction — `withAnimation(.easeOut(0.15))`, what the
    /// toggle does — and must come up holding the caret, with no second click.
    ///
    /// Verified to have teeth by mutation: delete the `.onAppear` focus claim from
    /// `ExpandingSearchField` and this fails (the field reveals dead, exactly the bug).
    ///
    /// What it does NOT pin, recorded so the next reader doesn't over-trust the comment in the
    /// component: the `Task` hop. `DifferencesView` documented that a `FocusState` write landing
    /// in the transaction that inserts the field is silently dropped — hence the hop. That hazard
    /// could not be reproduced here on macOS 26 in ANY variant: a synchronous `.onAppear` write
    /// focuses, and so does a write from the revealer naming the not-yet-inserted field. Either
    /// SwiftUI has since fixed it or it needs a hierarchy deeper than a harness can stage. The hop
    /// is therefore carried verbatim rather than "simplified away" — it is what Compare has always
    /// shipped, and removing a defence whose absence you cannot test for is how the fix→regression
    /// cycle starts. Do not drop it on the strength of this note.
    @Test func revealedFieldClaimsFocusWithoutAClick() async throws {
        let box = RevealBox()
        let window = Self.host(RealFieldHarness(box: box))
        try await Task.sleep(for: .milliseconds(100))

        withAnimation(ExpandingSearch.animation) { box.isExpanded = true }

        // The focus claim is asynchronous twice over — the `.onAppear` Task hop, then
        // FocusState→AppKit first-responder propagation — so a fixed pump here flakes under
        // suite load (CI run 30403470882; shrinking the pump to 1ms reproduces that failure
        // exactly). The deadline is a ceiling, not a wait: the poll returns as soon as the
        // caret lands, ~150ms in a quiet run.
        let caret = await Self.becomesEditingText(window)
        #expect(caret.held,
                """
                the revealed field must hold the caret — no second click \
                (gave up after \(caret.passes) passes)
                """)
    }

    // MARK: Behaviour-preservation of the extraction

    /// Compare's adoption has to be a no-op visually, and the risky part is the accessories slot:
    /// the chips and suggestions used to be written inline as two siblings of a `VStack(spacing:
    /// 7)`, and now arrive through a ViewBuilder closure as a nested `TupleView`. If SwiftUI
    /// didn't flatten that, the 7pt spacing between them would change and Compare's header would
    /// silently shift.
    ///
    /// So: the pre-extraction shape, reproduced verbatim, measured against the component in every
    /// combination of chips and suggestions. Equal heights ⇒ the extraction preserved the layout.
    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func matchesThePreExtractionLayout(showsChips: Bool, showsSuggestions: Bool) {
        let legacy = LegacyCompareField(showsChips: showsChips, showsSuggestions: showsSuggestions)
        let adopted = AdoptedCompareField(showsChips: showsChips, showsSuggestions: showsSuggestions)
        #expect(laidOutHeight(legacy, width: 480) == laidOutHeight(adopted, width: 480))
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

    /// **The floor outlives an expired deadline** — the property the fix rests on, and the one
    /// thing standing over it.
    ///
    /// The sweep in `docs/flaky-tests.md` mechanism 2 finds an UNFLOORED loop; nothing in it can
    /// see a floor that was deleted from a floored one, and `pumpUntil` takes no argument a scan
    /// could watch. So this asserts the shape directly: with the deadline already spent, a
    /// condition that never holds is still evaluated `pumpFloor` times.
    ///
    /// Deliberately drives `pumpUntil` rather than `becomesEditingText`, because the caret arrives
    /// on the first pass in a quiet run — a fixture whose condition is already true would pass with
    /// the floor set to zero and prove nothing.
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

    /// **The production floor's VALUE**, pinned separately and cheaply.
    ///
    /// The case above deliberately does NOT compare against `pumpFloor`: deriving the demand from
    /// the constant defeats the mutation test, because zeroing the floor would zero the expectation
    /// with it and the case would pass against a wait that no longer has a floor at all. Measured
    /// here rather than reasoned — the first version of that case did derive it, and survived
    /// `pumpFloor = 0` untouched.
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

    /// Ten times what a starved run has been measured to need, which also clears what an idle one
    /// wants — so the floor carries this wait on its own. Same number and same reason as
    /// `LayoutPumpWait.pumpFloor` in FileExplorer; that type is in another package's test target,
    /// so the constant is restated rather than shared.
    private static let pumpFloor = 50

    /// What `theFloorOutlivesAnExpiredDeadline` demands — a LITERAL, deliberately not derived from
    /// `pumpFloor`, so zeroing the floor cannot zero the expectation along with it.
    private static let passesDemanded = 25

    /// Pumps `window`'s layout until `condition` holds, or until BOTH the deadline has passed and
    /// `pumpFloor` passes have been made.
    ///
    /// **Seconds are the wrong unit and the deadline alone was the bug.** What this waits on is
    /// main-actor turns, and a congested test host delivers them at no fixed rate — 15s bought
    /// four polls in a suite measured in `docs/flaky-tests.md` mechanism 2, so raising the ceiling
    /// buys nothing. The floor is the bound that means something.
    ///
    /// Deliberately takes no `floor:` argument. `LayoutPumpWait` has one for its own tests and pays
    /// for it with a repo-wide scan keeping every real wait on the default; with nothing here able
    /// to lower it, there is nothing for such a scan to catch.
    ///
    /// Returns the pass count as well, because that is the diagnosis: a wait that gave up after a
    /// handful of passes was starved, one that gave up after a thousand was genuinely disproved,
    /// and elapsed time cannot tell those apart.
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
    /// suites converged on for a loaded run of the whole test host.
    private static func becomesEditingText(_ window: NSWindow,
                                           timeout: TimeInterval = 15) async -> (held: Bool, passes: Int) {
        await pumpUntil(window, timeout: timeout) { isEditingText(window) }
    }
}

/// Stand-ins for Compare's accessories, shaped like the real ones (a chips capsule row and a
/// one-tap suggestion row) so the two layouts below are measured with identical content.
private struct AccessoryStubs {
    @ViewBuilder
    static var chips: some View {
        HStack(spacing: 6) {
            TokenChipsRow(items: [TokenChipsRow.Item(label: "kind: pdf", word: "kind:pdf", isActive: true)],
                          tint: .blue, onRemove: { _ in })
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    static var suggestions: some View {
        HStack(spacing: 6) {
            Text("Add filter").font(.caption2).foregroundStyle(.tertiary).fixedSize()
            Text("PDFs").font(.caption2).padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary.opacity(0.6)))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    static var trailing: some View {
        Text("3 of 12").font(.caption).monospacedDigit().foregroundStyle(.secondary)
    }
}

/// Compare's search field EXACTLY as it was written before the extraction (DifferencesView:765–806
/// at `9733e2f`). The reference the adoption is measured against.
private struct LegacyCompareField: View {
    let showsChips: Bool
    let showsSuggestions: Bool
    @State private var text = "kind:pdf"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                TextField("Search — try kind:pdf, >10mb, only:left", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                AccessoryStubs.trailing
            }
            if showsChips { AccessoryStubs.chips }
            if showsSuggestions { AccessoryStubs.suggestions }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .searchFieldSurface()
    }
}

/// The same field, expressed through the extracted component the way `DifferencesView` now does.
private struct AdoptedCompareField: View {
    let showsChips: Bool
    let showsSuggestions: Bool
    @State private var text = "kind:pdf"

    var body: some View {
        ExpandingSearchField(
            text: $text,
            isExpanded: .constant(true),
            placeholder: "Search — try kind:pdf, >10mb, only:left",
            trailing: { AccessoryStubs.trailing },
            accessories: { _ in
                if showsChips { AccessoryStubs.chips }
                if showsSuggestions { AccessoryStubs.suggestions }
            }
        )
    }
}

/// The real component, revealed the way the app reveals it: absent until the host flips
/// `isExpanded`, then inserted by that transaction.
private struct RealFieldHarness: View {
    @ObservedObject var box: RevealBox
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
    }
}
