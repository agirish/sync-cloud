@testable import SyncCloud
import Testing

/// An overtaken rail survey still lands, unless a newer one already has (`RefreshCounter`). Edit's
/// file rail re-lists its folder off the main actor after every autosave, and surveys overlap. A
/// "latest ticket only" rule would drop every overtaken survey, so on a folder slower to list than
/// the autosave gap the rail would stop updating while the user types.
@MainActor @Suite struct EditorRailRefreshTicketTests {

    @Test func anOvertakenSurveyLandsWhenNothingNewerHas() {
        let tickets = RefreshCounter()
        let slow = tickets.take()
        let newer = tickets.take()        // the next autosave, still listing
        #expect(tickets.admit(slow), "a survey overtaken by one still running was thrown away")
        #expect(tickets.admit(newer))
    }

    @Test func anOlderSurveyNeverUndoesANewerOne() {
        let tickets = RefreshCounter()
        let older = tickets.take()
        let newer = tickets.take()
        #expect(tickets.admit(newer))
        #expect(!tickets.admit(older), "an older survey finishing last wrote over a newer one")
        #expect(!tickets.admit(newer), "one survey wrote twice")
    }
}
