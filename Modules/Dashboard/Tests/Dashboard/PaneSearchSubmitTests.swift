import Testing
import AppKit
@testable import Dashboard

/// What Return does in the pane search field.
@Suite struct PaneSearchSubmitTests {

    @Test func theOfferNeverStealsEitherPlainDirection() {
        // **The regression this table exists for.** The offer used to take ↩, which meant that on
        // any query naming someone, forward advance was unreachable — ⇧↩ is *previous*, not "the
        // plain search". The field's placeholder promises "↩ next, ⇧↩ previous", and both have to
        // keep working whether or not the query happens to be a name.
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

    @Test func plainSubmitIsUnchangedWithNoOffer() {
        // The behaviour every existing user has: exactly what it was before any of this.
        #expect(PaneSearchSubmit.action(modifiers: [], hasOffer: false) == .advance(reverse: false))
        #expect(PaneSearchSubmit.action(modifiers: .shift, hasOffer: false) == .advance(reverse: true))
    }
}
