import Testing
@testable import FileExplorer

/// The differences header's shedding ladder and label rules. These are the design decisions the
/// bar is built from, asserted directly rather than through a rendered row: `ViewThatFits` picks
/// which rung applies, but which rung means what is decided here.
@Suite struct HeaderCompactionTests {

    @Test func testLadderIsOrderedWidestFirst() {
        // The view lists one ViewThatFits candidate per case in `allCases` order, so a reordering
        // here silently reorders what the header gives up. Pin the sequence.
        #expect(HeaderCompaction.allCases == [
            .full, .foldVerify, .foldReview, .shortReverse, .glyphFilter, .shortPrimary,
        ])
        #expect(HeaderCompaction.allCases == HeaderCompaction.allCases.sorted())
        #expect(HeaderCompaction.full < HeaderCompaction.shortPrimary)
    }

    @Test func testDestinationNamesAreShedAfterEverythingElse() {
        // Verify and Review name no destination, so both are gone before either transfer button
        // gives up a word — the property that makes this ladder the inverse of the old
        // truncationMode(.middle), which ate the destination out of the widest button first.
        #expect(HeaderCompaction.foldVerify < .shortReverse)
        #expect(HeaderCompaction.foldReview < .shortReverse)
        // And the primary's destination outlives the reverse's and the filter's.
        #expect(HeaderCompaction.shortReverse < .shortPrimary)
        #expect(HeaderCompaction.glyphFilter < .shortPrimary)
    }

    // MARK: Labels

    @Test func testCopyIsUnmarkedAndMoveIsSpelledOut() {
        // Copy carries no verb — the arrow says "to there". Move is the marked variant because it
        // is the one that removes the source.
        #expect(BulkActionLabel.text(count: 17, destination: "Dropbox", isMove: false) == "17 to Dropbox")
        #expect(BulkActionLabel.text(count: 17, destination: "Dropbox", isMove: true) == "Move 17 to Dropbox")
        #expect(BulkActionLabel.text(count: 4, destination: nil, isMove: false) == "4")
        #expect(BulkActionLabel.text(count: 4, destination: nil, isMove: true) == "Move 4")
    }

    @Test func testHelpAlwaysNamesTheVerbAndDestination() {
        // The label may shed words; the explanation may not — that is what makes the terse label
        // safe on a destructive action.
        #expect(BulkActionLabel.help(count: 17, destination: "Dropbox", isMove: false)
                == "Copy 17 items to Dropbox")
        #expect(BulkActionLabel.help(count: 1, destination: "iCloud", isMove: true)
                == "Move 1 item to iCloud")
    }

    @Test func testReverseKeepsItsDestinationAtEveryWidthWhenItIsTheMajority() {
        // The one thing a fixed left-to-right primary cannot tell you is that the loudest button
        // is pointing away from most of the work. So when the reverse IS the bulk, its destination
        // survives every rung — including the ones past `shortReverse`.
        for compaction in HeaderCompaction.allCases {
            #expect(BulkActionLabel.reverseNamesDestination(reverseIsMajority: true,
                                                            compaction: compaction),
                    "majority reverse lost its destination at \(compaction)")
        }
    }

    @Test func testReverseDropsItsDestinationOnlyOnceItIsTheMinorityAndTheRowIsTight() {
        #expect(BulkActionLabel.reverseNamesDestination(reverseIsMajority: false, compaction: .full))
        #expect(BulkActionLabel.reverseNamesDestination(reverseIsMajority: false, compaction: .foldReview))
        #expect(!BulkActionLabel.reverseNamesDestination(reverseIsMajority: false, compaction: .shortReverse))
        #expect(!BulkActionLabel.reverseNamesDestination(reverseIsMajority: false, compaction: .shortPrimary))
    }

    @Test func testPrimaryKeepsItsDestinationUntilTheLastRung() {
        for compaction in HeaderCompaction.allCases where compaction != .shortPrimary {
            #expect(BulkActionLabel.primaryNamesDestination(compaction: compaction),
                    "primary lost its destination early at \(compaction)")
        }
        #expect(!BulkActionLabel.primaryNamesDestination(compaction: .shortPrimary))
    }

    /// The view's ladder is a hand-maintained mirror of the enum — `ViewThatFits` treats a `ForEach`
    /// as one child, so the rows cannot be looped and a new rung has to be added in two places. Add
    /// it to the enum only and the header silently never renders it, while every test above still
    /// passes because they only ever ask the enum.
    @Test func testTheViewRendersEveryCompactionRung() {
        #expect(DifferencesView.renderedCompactionLadder == HeaderCompaction.allCases,
                "HeaderCompaction.allCases and the ViewThatFits ladder in DifferencesView have drifted")
    }
}
