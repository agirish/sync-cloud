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
        try await Task.sleep(for: .milliseconds(400))

        #expect(Self.isEditingText(window), "the revealed field must hold the caret — no second click")
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
            isExpanded: Binding(get: { expanded }, set: { expanded = $0 })
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
                isExpanded: Binding(get: { expanded }, set: { expanded = $0 })
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
