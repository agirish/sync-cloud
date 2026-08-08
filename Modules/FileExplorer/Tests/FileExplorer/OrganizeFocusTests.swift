import Testing
@testable import FileExplorer

/// Organize's focus rules — which chips the row draws, what number each carries, and the fallback
/// that keeps a stored selection from stranding you.
///
/// These are pure so they can be asserted directly. What they cannot see is whether the view uses
/// them at all, which is why `OrganizeFocusChipTests` mounts the header and reads pixels back: a
/// rule extracted for testability is one revert away from being decorative.
@Suite struct OrganizeFocusTests {

    // MARK: The fallback — the safety property

    @Test func aFocusWhoseListEmptiedFallsBackToTheQueue() {
        // Fixing the last risky name has to land you in the queue. Left on `.names`, the list is
        // empty AND the chip that would take you out of it is gone with the finding — a dead end
        // reachable by doing exactly what the lens asked.
        #expect(OrganizeFocus.effective(.names, riskyNameCount: 0) == .queue)
    }

    @Test func theFallbackDoesNotFireWhileTheFindingStands() {
        #expect(OrganizeFocus.effective(.names, riskyNameCount: 1) == .names)
        #expect(OrganizeFocus.effective(.names, riskyNameCount: 17) == .names)
    }

    @Test func theQueueIsNeverFalledBackFrom() {
        // It is the destination of the fallback, so it has to be stable under one — including in
        // the state that has no chips at all.
        #expect(OrganizeFocus.effective(.queue, riskyNameCount: 0) == .queue)
        #expect(OrganizeFocus.effective(.queue, riskyNameCount: 17) == .queue)
    }

    // MARK: Which chips exist

    @Test func aFindingAtZeroDrawsNoChipAtAll() {
        // Not greyed, not "0". The whole argument for reporting a rare condition on this row
        // instead of giving it a tab is that it costs nothing on the days it has nothing to say.
        #expect(OrganizeFocus.chips(queueCount: 24, riskyNameCount: 0) == [.queue])
    }

    @Test func aFindingBringsItsChipAndTheQueuesWithIt() {
        #expect(OrganizeFocus.chips(queueCount: 24, riskyNameCount: 17) == [.queue, .names])
    }

    @Test func theQueueLeads() {
        // Reading order is load-bearing: the place first, then what the scan turned up on the way.
        let chips = OrganizeFocus.chips(queueCount: 3, riskyNameCount: 3)
        #expect(chips.first == .queue)
    }

    @Test func anEmptyQueueStillDrawsItsChipWhenAFindingSitsBesideIt() {
        // The state after "File all": every file is filed and the names are still wrong. The queue
        // chip is the radio group's first button and the only way back to it, so this is the one
        // member exempt from absent-at-zero — and it is exempt only here, where there is something
        // to be selected back FROM.
        #expect(OrganizeFocus.chips(queueCount: 0, riskyNameCount: 17) == [.queue, .names])
    }

    @Test func anEmptyQueueAloneDrawsNothing() {
        // With no finding beside it there is nothing to switch between, so the row is as bare as
        // today's results-gated pills leave it. A lone chip reading "0 to file" is a zero with no
        // job to do.
        #expect(OrganizeFocus.chips(queueCount: 0, riskyNameCount: 0).isEmpty)
    }

    // MARK: What each chip counts

    @Test func eachChipCountsItsOwnList() {
        #expect(OrganizeFocus.count(.queue, queueCount: 24, riskyNameCount: 17) == 24)
        #expect(OrganizeFocus.count(.names, queueCount: 24, riskyNameCount: 17) == 17)
    }

    // MARK: The words

    @Test func theNamesChipPluralisesAndTheQueueChipDoesNot() {
        #expect(OrganizeFocus.names.label(count: 1) == "risky name")
        #expect(OrganizeFocus.names.label(count: 2) == "risky names")
        // "to file" is a job, not a noun that counts — "1 to files" would be the bug this pins.
        #expect(OrganizeFocus.queue.label(count: 1) == "to file")
        #expect(OrganizeFocus.queue.label(count: 24) == "to file")
    }

    // MARK: Persistence shape

    @Test func theRawValuesAreStableAndDistinct() {
        // This selection is not persisted today, but it is the kind of thing that gets an
        // `@AppStorage` the moment a third focus arrives — and `Workspace` is in this repo
        // precisely because a raw value that moves strands whoever stored the old one.
        #expect(OrganizeFocus.queue.rawValue == "queue")
        #expect(OrganizeFocus.names.rawValue == "names")
        #expect(Set(OrganizeFocus.allCases.map(\.rawValue)).count == OrganizeFocus.allCases.count)
    }
}
