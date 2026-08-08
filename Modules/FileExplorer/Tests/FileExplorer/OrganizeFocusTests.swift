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
        #expect(OrganizeFocus.effective(.names, riskyNameCount: 0, renamePlanCount: 0) == .queue)
    }

    @Test func theFallbackDoesNotFireWhileTheFindingStands() {
        #expect(OrganizeFocus.effective(.names, riskyNameCount: 1, renamePlanCount: 0) == .names)
        #expect(OrganizeFocus.effective(.names, riskyNameCount: 17, renamePlanCount: 0) == .names)
    }

    @Test func theQueueIsNeverFalledBackFrom() {
        // It is the destination of the fallback, so it has to be stable under one — including in
        // the state that has no chips at all.
        #expect(OrganizeFocus.effective(.queue, riskyNameCount: 0, renamePlanCount: 0) == .queue)
        #expect(OrganizeFocus.effective(.queue, riskyNameCount: 17, renamePlanCount: 0) == .queue)
    }

    // MARK: Which chips exist

    @Test func aFindingAtZeroDrawsNoChipAtAll() {
        // Not greyed, not "0". The whole argument for reporting a rare condition on this row
        // instead of giving it a tab is that it costs nothing on the days it has nothing to say.
        #expect(OrganizeFocus.chips(queueCount: 24, riskyNameCount: 0, renamePlanCount: 0) == [.queue])
    }

    @Test func aFindingBringsItsChipAndTheQueuesWithIt() {
        #expect(OrganizeFocus.chips(queueCount: 24, riskyNameCount: 17, renamePlanCount: 0) == [.queue, .names])
    }

    @Test func theQueueLeads() {
        // Reading order is load-bearing: the place first, then what the scan turned up on the way.
        let chips = OrganizeFocus.chips(queueCount: 3, riskyNameCount: 3, renamePlanCount: 0)
        #expect(chips.first == .queue)
    }

    @Test func anEmptyQueueStillDrawsItsChipWhenAFindingSitsBesideIt() {
        // The state after "File all": every file is filed and the names are still wrong. The queue
        // chip is the radio group's first button and the only way back to it, so this is the one
        // member exempt from absent-at-zero — and it is exempt only here, where there is something
        // to be selected back FROM.
        #expect(OrganizeFocus.chips(queueCount: 0, riskyNameCount: 17, renamePlanCount: 0) == [.queue, .names])
    }

    @Test func anEmptyQueueAloneDrawsNothing() {
        // With no finding beside it there is nothing to switch between, so the row is as bare as
        // today's results-gated pills leave it. A lone chip reading "0 to file" is a zero with no
        // job to do.
        #expect(OrganizeFocus.chips(queueCount: 0, riskyNameCount: 0, renamePlanCount: 0).isEmpty)
    }

    // MARK: What each chip counts

    @Test func eachChipCountsItsOwnList() {
        #expect(OrganizeFocus.count(.queue, queueCount: 24, riskyNameCount: 17, renamePlanCount: 0) == 24)
        #expect(OrganizeFocus.count(.names, queueCount: 24, riskyNameCount: 17, renamePlanCount: 0) == 17)
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

    // MARK: The third finding (ROADMAP 19)

    @Test("The rename backlog is a third chip, after the names")
    func renameBacklogIsAThirdChip() {
        #expect(OrganizeFocus.chips(queueCount: 24, riskyNameCount: 0, renamePlanCount: 9)
                == [.queue, .renames])
        // Reading order: the queue is the place, then the findings in the order the scan turned
        // them up. Two findings beside the queue is the state that made this a selection rather
        // than a Bool in the first place.
        #expect(OrganizeFocus.chips(queueCount: 24, riskyNameCount: 17, renamePlanCount: 9)
                == [.queue, .names, .renames])
    }

    @Test("An empty backlog is absent, not a chip showing zero")
    func anEmptyBacklogDrawsNothing() {
        #expect(OrganizeFocus.chips(queueCount: 24, riskyNameCount: 0, renamePlanCount: 0)
                == [.queue])
        #expect(OrganizeFocus.chips(queueCount: 0, riskyNameCount: 0, renamePlanCount: 0).isEmpty)
        // …and with nothing but a backlog, the queue is still drawn so the radio group has a first
        // button to come back to — the same exemption the names finding relies on.
        #expect(OrganizeFocus.chips(queueCount: 0, riskyNameCount: 0, renamePlanCount: 9)
                == [.queue, .renames])
    }

    @Test("Renaming the last folder drops you into the queue, not onto an empty list")
    func theBacklogFocusFallsBack() {
        #expect(OrganizeFocus.effective(.renames, riskyNameCount: 0, renamePlanCount: 0) == .queue)
        #expect(OrganizeFocus.effective(.renames, riskyNameCount: 0, renamePlanCount: 1) == .renames)
        // The two findings fall back independently: an emptied NAMES list must not strand you on
        // the queue while a live backlog sits beside it, and vice versa.
        #expect(OrganizeFocus.effective(.renames, riskyNameCount: 0, renamePlanCount: 9) == .renames)
        #expect(OrganizeFocus.effective(.names, riskyNameCount: 0, renamePlanCount: 9) == .queue)
    }

    @Test("The backlog chip counts FOLDERS, and says so")
    func theBacklogChipCountsFolders() {
        #expect(OrganizeFocus.count(.renames, queueCount: 24, riskyNameCount: 17,
                                    renamePlanCount: 9) == 9)
        #expect(OrganizeFocus.renames.label(count: 1) == "folder to rename")
        #expect(OrganizeFocus.renames.label(count: 9) == "folders to rename")
    }

    /// **No focus chip may wear a glyph that draws digits.**
    ///
    /// The rename backlog shipped with `textformat.123`, whose artwork is the literal characters
    /// `1 2 3`. Sitting immediately left of the chip's own count it rendered as
    /// "123 126 folders to rename", and the first question the chip asked its reader was which of
    /// the two numbers meant something. A glyph beside a number must not be readable as a number.
    ///
    /// A deny-list rather than an equality check on the chosen symbol: the defect is the whole
    /// family, not the one member that happened to ship, and pinning `folder.badge.gearshape`
    /// exactly would fail the next honest restyle while still waving `textformat.abc` through.
    @Test("No focus glyph is a symbol that draws its own digits")
    func noFocusGlyphDrawsDigits() {
        // Every SF Symbol whose artwork IS numerals. `list.number` and `textformat.numbers` draw
        // digits too; `number` is the ⌗ sign and is fine, which is why this is a list and not a
        // substring match on "number".
        let digitDrawing: Set<String> = ["textformat.123", "list.number", "textformat.numbers",
                                         "01.square", "123.rectangle", "number.square"]
        for focus in OrganizeFocus.allCases {
            let symbol = TidyView.focusSymbol(focus)
            #expect(!digitDrawing.contains(symbol),
                    "the \(focus.rawValue) chip wears \(symbol), which paints digits beside its own count")
            #expect(!symbol.isEmpty, "the \(focus.rawValue) chip has no glyph at all")
        }
        // Each focus reads its OWN number — a chip labelled with a neighbour's count is the defect
        // this triple-argument shape exists to make impossible.
        #expect(OrganizeFocus.count(.names, queueCount: 24, riskyNameCount: 17,
                                    renamePlanCount: 9) == 17)
        #expect(OrganizeFocus.count(.queue, queueCount: 24, riskyNameCount: 17,
                                    renamePlanCount: 9) == 24)
    }
}
