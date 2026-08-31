import CoreGraphics
import Sync
import Testing
@testable import FileExplorer

/// The card grid the renames and duplicates lenses share — his ask, twice: "a grid of cards when
/// the window is wide, cards below each other in all other cases", and then "can we redesign it to
/// be like card grids?".
///
/// The arithmetic is the part that can be silently wrong. A column count one too high does not
/// crash or draw badly enough to notice in a screenshot; it just truncates every name on the
/// screen whose whole job is showing names.
@Suite struct LensCardGridTests {

    /// **The ordinary case is one column for the renames card**, and it has to be: the app's own
    /// window floor is 810pt wide and the Organize lens gets a fraction of it, so a rule that
    /// reached two columns too eagerly would make the narrow pane — the one this lens is usually
    /// read in — the broken one.
    @Test func aNarrowPaneStaysASingleColumn() {
        let renames = RenamePassLens.minimumCardWidth
        #expect(LensCardGrid.columns(forWidth: 320, minimumCardWidth: renames) == 1)
        #expect(LensCardGrid.columns(forWidth: 495, minimumCardWidth: renames) == 1)
        #expect(LensCardGrid.columns(forWidth: 600, minimumCardWidth: renames) == 1)
    }

    /// The threshold itself, from both sides — the assertion that fails if the padding allowance
    /// or the gutter term is dropped from the fit. Two cards need two minimums plus one gutter
    /// plus the list's own insets; a pixel under that is still one column.
    @Test func theSecondColumnArrivesExactlyWhenTwoCardsFit() {
        for minimum: CGFloat in [220, 340] {
            let needed = minimum * 2 + LensCardGrid.gutter + LensCardGrid.listHorizontalPadding
            #expect(LensCardGrid.columns(forWidth: needed - 1, minimumCardWidth: minimum) == 1)
            #expect(LensCardGrid.columns(forWidth: needed, minimumCardWidth: minimum) == 2)
        }
    }

    /// The duplicates lens is a `ScrollView` with its own padding, not the renames `List`, and it
    /// passes that padding — one shared constant under-counted its usable width by 8–16pt.
    @Test func aCallerCanSupplyItsOwnContainerPadding() {
        let minimum: CGFloat = 250
        // Exactly wide enough for two tiles once only the ScrollView's 24pt of padding is taken.
        let pane = minimum * 2 + LensCardGrid.gutter + 24
        #expect(LensCardGrid.columns(forWidth: pane, minimumCardWidth: minimum,
                                     horizontalPadding: 24) == 2)
        #expect(LensCardGrid.columns(forWidth: pane, minimumCardWidth: minimum) == 1,
                "the List's wider chrome really does cost a column at this width")
        // A nonsense padding must not widen the pane into more columns than fit.
        #expect(LensCardGrid.columns(forWidth: pane, minimumCardWidth: minimum,
                                     horizontalPadding: -1000) <= LensCardGrid.maximumColumns)
    }

    /// Wide panes fill up to the cap and stop. Beyond three, cards get narrower rather than the
    /// layout getting better.
    @Test func aWidePaneFillsToTheCapAndNoFurther() {
        let minimum = RenamePassLens.minimumCardWidth
        let three = minimum * 3 + LensCardGrid.gutter * 2 + LensCardGrid.listHorizontalPadding
        #expect(LensCardGrid.columns(forWidth: three, minimumCardWidth: minimum) == 3)
        #expect(LensCardGrid.columns(forWidth: 4000, minimumCardWidth: minimum)
                == LensCardGrid.maximumColumns)
        #expect(LensCardGrid.maximumColumns == 3)
    }

    /// **A `GeometryReader` reports 0 on its first pass**, and a proposal can be infinite. Either
    /// one divided into a column count gives nonsense — 0 columns renders nothing at all, and the
    /// chunker would then divide by zero.
    @Test func aDegenerateWidthFallsBackToOneColumn() {
        let minimum = RenamePassLens.minimumCardWidth
        #expect(LensCardGrid.columns(forWidth: 0, minimumCardWidth: minimum) == 1)
        #expect(LensCardGrid.columns(forWidth: -50, minimumCardWidth: minimum) == 1)
        #expect(LensCardGrid.columns(forWidth: .infinity, minimumCardWidth: minimum) == 1)
        #expect(LensCardGrid.columns(forWidth: .nan, minimumCardWidth: minimum) == 1)
        // The width that is positive but smaller than the list's own insets — the pane mid-drag.
        #expect(LensCardGrid.columns(forWidth: LensCardGrid.listHorizontalPadding - 1,
                                     minimumCardWidth: minimum) == 1)
        // And a nonsense minimum must not divide either.
        #expect(LensCardGrid.columns(forWidth: 1200, minimumCardWidth: 0) == 1)
    }

    /// Chunking is total and order-preserving: widening the window must rearrange the list without
    /// reordering it, or a card a reader was looking at moves for no reason.
    @Test func everyCardAppearsOnceInTheOrderGiven() {
        let items = Array(0..<7)
        for columns in 1...4 {
            let rows = LensCardGrid.rows(items, columns: columns)
            #expect(rows.flatMap { $0 } == items, "\(columns) columns reorders or drops")
            #expect(rows.allSatisfy { $0.count <= columns && !$0.isEmpty })
            #expect(rows.count == (items.count + columns - 1) / columns)
        }
    }

    /// The remainder row is short rather than padded — the view fills it with spacers, and it
    /// must not receive phantom items to do that with.
    @Test func theLastRowCarriesTheRemainder() {
        let rows = LensCardGrid.rows(Array(0..<7), columns: 3)
        #expect(rows.map(\.count) == [3, 3, 1])
        #expect(LensCardGrid.rows([Int](), columns: 3).isEmpty, "nothing in, nothing out")
        // A column count of zero cannot come from `columns(forWidth:)`, but `rows` is generic and
        // reachable from the module: it must not divide by it.
        #expect(LensCardGrid.rows([1, 2], columns: 0).map(\.count) == [1, 1])
    }

    // MARK: Full-width rows

    /// **An expanded card takes a row to itself, and the tiling resumes after it.** This is why the
    /// division cannot be a plain chunk: the buffer has to flush at the full-width item and start
    /// again after it, or the row following one would carry four cards in a three-wide grid.
    @Test func aFullWidthItemBreaksTheRowAndStartsANewOne() {
        let rows = LensCardGrid.rows(Array(0..<7), columns: 3, spansFullWidth: { $0 == 4 })
        #expect(rows.map { $0 } == [[0, 1, 2], [3], [4], [5, 6]])
        #expect(rows.flatMap { $0 } == Array(0..<7), "still total, still in order")
        #expect(rows.allSatisfy { !$0.isEmpty }, "no empty row is ever emitted")
    }

    /// The boundary cases the flush-and-restart gets wrong when written casually: a full-width item
    /// first (no buffer to flush), last (buffer flushed before it), one exactly filling a row
    /// before it, and two in a row.
    @Test func fullWidthItemsAtEveryPosition() {
        #expect(LensCardGrid.rows([0, 1, 2], columns: 2, spansFullWidth: { $0 == 0 })
                    .map { $0 } == [[0], [1, 2]])
        #expect(LensCardGrid.rows([0, 1, 2], columns: 2, spansFullWidth: { $0 == 2 })
                    .map { $0 } == [[0, 1], [2]])
        // Exactly one full row, then the full-width item: the buffer was already flushed by the
        // count, and must not produce an empty row on top of it.
        #expect(LensCardGrid.rows([0, 1, 2], columns: 2, spansFullWidth: { $0 == 2 })
                    .allSatisfy { !$0.isEmpty })
        #expect(LensCardGrid.rows([0, 1, 2, 3], columns: 3, spansFullWidth: { $0 >= 1 && $0 <= 2 })
                    .map { $0 } == [[0], [1], [2], [3]])
        // Every item full-width: a list of single-card rows, none merged.
        #expect(LensCardGrid.rows([0, 1], columns: 3, spansFullWidth: { _ in true })
                    .map { $0 } == [[0], [1]])
    }

    // MARK: Row identity

    private struct Card: Identifiable, Equatable { let id: String }

    /// **Row ids must be unique across the WHOLE list, not within one section.**
    ///
    /// This is the defect his screenshots caught. Every section's rows were numbered from zero, so
    /// a `LazyVStack` — which identifies its children across the whole stack, not per `ForEach` —
    /// saw several children claiming to be row 0, and reused cells against the wrong content:
    /// "to merge" rendered the tiles of "to decide", two sections drew blank, and the list only
    /// filled in as scrolling forced a rebuild. His report: "tiles only show up when scrolling
    /// down."
    ///
    /// Concatenating the sections is the test, because concatenating them is what the stack does.
    ///
    /// **Not pinned, stated:** that the views call `identifiedRows` at all. Reverting either lens
    /// to an index-keyed `ForEach` reproduces the reported defect with this green. Binding it needs
    /// a test that mounts the lens and reads back cell contents; nothing cheaper does.
    @Test func rowIdsAreUniqueAcrossEverySectionOfAList() {
        let sections = [(0..<7).map { Card(id: "decide\($0)") },
                        (0..<4).map { Card(id: "merge\($0)") },
                        (0..<2).map { Card(id: "remove\($0)") }]
        let ids = sections.flatMap { LensCardGrid.identifiedRows($0, columns: 3).map(\.id) }
        #expect(ids.count > 3, "a positive control: there are rows to collide")
        #expect(Set(ids).count == ids.count, "duplicate row ids: \(ids)")

        // The index-based scheme this replaced, for contrast: three sections all starting at 0.
        let byIndex = sections.flatMap { LensCardGrid.rows($0, columns: 3).indices.map { $0 } }
        #expect(Set(byIndex).count < byIndex.count,
                "a positive control: row indices really do collide across sections")
    }

    /// The identified rows are the same partition, just carrying an id — the layout must not have
    /// been re-implemented alongside it.
    @Test func identifiedRowsAreTheSamePartition() {
        let cards = (0..<7).map { Card(id: "c\($0)") }
        for columns in 1...3 {
            let plain = LensCardGrid.rows(cards, columns: columns)
            let identified = LensCardGrid.identifiedRows(cards, columns: columns)
            #expect(identified.map(\.items) == plain)
            #expect(identified.map(\.id) == plain.map { $0[0].id },
                    "the row's id is its first card's")
        }
        // And it carries the full-width rule through, which is the call the views actually make.
        let spanning = LensCardGrid.identifiedRows(cards, columns: 3,
                                                   spansFullWidth: { $0.id == "c4" })
        #expect(spanning.map(\.items.count) == [3, 1, 1, 2])
    }
}
