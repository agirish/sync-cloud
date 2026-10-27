import AppKit
import Testing
@testable import SyncCloud

/// **VoiceOver hears each result once, and two at once as one** (Run Room TE226).
@MainActor
@Suite(.serialized) struct ActivityAnnouncerTests {

    @Test func severalInAMomentAreOneSentence() {
        #expect(ActivityAnnouncer.batched([]) == nil)
        #expect(ActivityAnnouncer.batched(["Merged “Photos”"]) == "Merged “Photos”")
        #expect(ActivityAnnouncer.batched(["Saved 4 compressed copies", "Saved 6 files as PDF."])
                == "2 new in Activity: Saved 4 compressed copies; Saved 6 files as PDF.")
    }

    /// Two said within the window are posted once, at high priority when either is a problem; a
    /// success alone waits its turn at medium.
    @Test func twoAtOnceArePostedOnceAtTheProblemsPriority() async throws {
        let saved = ActivityAnnouncer.post
        defer { ActivityAnnouncer.post = saved }
        var posted: [(String, NSAccessibilityPriorityLevel)] = []
        ActivityAnnouncer.post = { posted.append(($0, $1)) }

        ActivityAnnouncer.say("Saved 4 compressed copies", isProblem: false)
        ActivityAnnouncer.say("Couldn’t save “Budget.numbers” as PDF", isProblem: true)
        ActivityAnnouncer.speak()
        #expect(posted.count == 1)
        #expect(posted.first?.0 == "2 new in Activity: Saved 4 compressed copies; Couldn’t save “Budget.numbers” as PDF.")
        #expect(posted.first?.1 == .high)

        ActivityAnnouncer.say("Deleted “Test3.md”", isProblem: false)
        ActivityAnnouncer.speak()
        #expect(posted.count == 2)
        #expect(posted.last?.1 == .medium)
    }
}
