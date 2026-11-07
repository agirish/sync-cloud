import Testing
import AppKit
@testable import Dashboard

/// What Return does in the pane search field.
@Suite struct PaneSearchSubmitTests {

    @Test func theOfferNeverStealsEitherPlainDirection() {
        // If the person offer took ↩, forward advance would be unreachable on any query naming
        // someone. The placeholder promises "↩ next, ⇧↩ previous" whatever the query is.
        #expect(PaneSearchSubmit.action(modifiers: [], hasOffer: true) == .advance(reverse: false))
        #expect(PaneSearchSubmit.action(modifiers: .shift, hasOffer: true) == .advance(reverse: true))
    }

    @Test func theChordTakesTheOffer() {
        #expect(PaneSearchSubmit.action(modifiers: .command, hasOffer: true) == .acceptPerson)
    }

    @Test func theChordFallsThroughWhenTheQueryNamesNobody() {
        // ⌘↩ on an ordinary query must not swallow the keystroke — it advances, so the chord is
        // never a dead key.
        #expect(PaneSearchSubmit.action(modifiers: .command, hasOffer: false) == .advance(reverse: false))
        #expect(PaneSearchSubmit.action(modifiers: [.command, .shift], hasOffer: false)
                == .advance(reverse: true))
    }
}
