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

        // Destination names are shed after everything else: a rule the pinned order only happens
        // to satisfy, so it is stated on its own. Verify and Review name no destination, so both
        // are gone before either transfer button gives up a word; the widest button never loses
        // its destination first, as a middle truncation would make it.
        #expect(HeaderCompaction.foldVerify < .shortReverse)
        #expect(HeaderCompaction.foldReview < .shortReverse)
        // And the primary's destination outlives the reverse's and the filter's.
        #expect(HeaderCompaction.shortReverse < .shortPrimary)
        #expect(HeaderCompaction.glyphFilter < .shortPrimary)
    }

    // MARK: Labels

    @Test func testBothVerbsAreSpelledOutWhileTheDestinationFits() {
        // The pair a user compares. Both verbs are spelled out, so telling them apart needs no
        // prior knowledge of a convention and the ⇧ flip is one swapped word.
        #expect(BulkActionLabel.text(count: 17, destination: "Dropbox", isMove: false) == "Copy 17 to Dropbox")
        #expect(BulkActionLabel.text(count: 17, destination: "Dropbox", isMove: true) == "Move 17 to Dropbox")
    }

    @Test func testCopyShedsItsVerbWithTheDestinationButMoveNever() {
        // The narrow rungs, where the ladder has already taken the destination. Copy's verb goes
        // with it: a bare count keeps narrow windows from compacting any earlier. Move's verb stays
        // at every width: it is the one word saying the source will not survive.
        #expect(BulkActionLabel.text(count: 4, destination: nil, isMove: false) == "4")
        #expect(BulkActionLabel.text(count: 4, destination: nil, isMove: true) == "Move 4")
    }

    /// The mutation this file exists to catch: if `text` spelled Copy out at the narrow rung too,
    /// the row would grow at exactly the widths that had no room to begin with. Asserting the
    /// lengths rather than the strings makes the intent, "the shed label is never longer than a
    /// bare count", the checked property.
    @Test func testShedCopyLabelIsNoLongerThanBeforeTheVerbExisted() {
        let shed = BulkActionLabel.text(count: 560, destination: nil, isMove: false)
        let named = BulkActionLabel.text(count: 560, destination: "Dropbox", isMove: false)
        #expect(shed.count == "560".count)
        #expect(shed.count < named.count)
        #expect(!shed.contains("Copy"))
    }

    @Test func testHelpAlwaysNamesTheVerbAndDestination() {
        // The label may shed words; the explanation may not. That is what makes the terse label
        // safe on a destructive action.
        #expect(BulkActionLabel.help(count: 17, destination: "Dropbox", isMove: false)
                == "Copy 17 items to Dropbox")
        #expect(BulkActionLabel.help(count: 1, destination: "iCloud", isMove: true)
                == "Move 1 item to iCloud")
    }

    @Test func testReverseKeepsItsDestinationAtEveryWidthWhenItIsTheMajority() {
        // The one thing a fixed left-to-right primary cannot tell you is that the loudest button
        // points away from most of the work. So when the reverse is the bulk, its destination
        // survives every rung, including the ones past `shortReverse`.
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

    /// The view's ladder is a hand-maintained mirror of the enum: `ViewThatFits` treats a `ForEach`
    /// as one child, so the rows cannot be looped and a new rung has to be added in two places.
    /// Added to the enum only, the header would silently never render it while every test above
    /// still passed.
    @Test func testTheViewRendersEveryCompactionRung() {
        #expect(DifferencesView.renderedCompactionLadder == HeaderCompaction.allCases,
                "HeaderCompaction.allCases and the ViewThatFits ladder in DifferencesView have drifted")
    }
}
