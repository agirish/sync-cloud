import Design
import Foundation
import Sync
import Testing
@testable import FileExplorer

/// Sectioning the Duplicates list by match kind, so a crowded grid reads as a few decisions. The
/// claims that can rot: the partition is total, sections keep their consequence order and vanish
/// at zero, and the order is a decision, not the enum's declaration order.
@Suite struct DuplicateSectionsTests {

    private func group(_ matchType: DuplicateMatchType, name: String,
                       reclaim: Int = 100) -> DuplicateGroup {
        let copies = (0..<2).map { i in
            DuplicateCopy(id: "/\(name)/c\(i)", name: name, isDirectory: false, size: 100,
                          itemCount: 1, modificationDate: nil, uniqueItemCount: 0, depth: 1,
                          isRecommendedKeeper: i == 0)
        }
        return DuplicateGroup(matchType: matchType, name: name, isDirectory: false,
                              copies: copies, reclaimableBytes: reclaim)
    }

    /// Every group lands in exactly one section, and a kind with no findings gets no heading: "0 to
    /// merge" is chrome explaining an absence.
    @Test func thePartitionIsTotalAndEmptySectionsVanish() {
        let groups = [group(.identical, name: "a"), group(.identical, name: "b"),
                      group(.sameText, name: "c"), group(.versions, name: "d")]
        let sections = DuplicateSections.sections(groups)
        #expect(sections.map(\.kind) == [.identical, .sameText, .versions],
                "no overlapping section, and the order otherwise")
        let placed = sections.flatMap(\.groups).map(\.name)
        #expect(Set(placed).count == placed.count, "no group is in two sections")
        #expect(Set(placed) == Set(groups.map(\.name)))
    }

    /// `identical` leads, as the only kind the header's button clears and the only one with a
    /// reclaim figure; the rest follow in consequence order. Leading with the judgment calls would
    /// bury the one-click findings below the fold.
    @Test func theOrderPutsTheBulkFirstAndTheJudgmentCallsUnderIt() {
        let all: [DuplicateMatchType] = [.identical, .versions, .sameText,
                                         .overlapping(sharedFraction: 0.8)]
        let sections = DuplicateSections.sections(all.enumerated().map {
            group($0.element, name: "g\($0.offset)")
        })
        #expect(sections.map(\.kind) == [.identical, .overlapping, .sameText, .versions])
        #expect(sections.first?.kind == .identical,
                "the bulk you can clear in a click leads; everything under it needs a person")
        // The declaration order is not this order, so the constant does real work.
        #expect(DuplicateSections.order != DuplicateMatchType.Kind.allCases)
    }

    /// A new match kind must not fall out of the list: `sections` builds from `order`, so a kind
    /// missing from it would silently drop every group of that kind.
    @Test func everyKindHasAPlaceAndSaysSomething() {
        #expect(Set(DuplicateSections.order) == Set(DuplicateMatchType.Kind.allCases))
        #expect(DuplicateSections.order.count == DuplicateMatchType.Kind.allCases.count,
                "no kind listed twice")
        for kind in DuplicateMatchType.Kind.allCases {
            #expect(!DuplicateSections.label(kind).isEmpty)
            #expect(!DuplicateSections.definition(kind).isEmpty)
            #expect(DuplicateSections.representative(kind).kind == kind,
                    "\(kind)'s representative type must be of that kind, or the heading takes another's colour")
        }
    }

    /// Sectioning re-groups the list without re-ranking it: the lens sorts by reclaimable size, and
    /// a card a reader was looking at must not move within its section.
    @Test func groupsKeepTheirIncomingOrderWithinASection() {
        let groups = [group(.identical, name: "big", reclaim: 900),
                      group(.sameText, name: "mid", reclaim: 500),
                      group(.identical, name: "small", reclaim: 100)]
        let identical = DuplicateSections.sections(groups).first { $0.kind == .identical }!
        #expect(identical.groups.map(\.name) == ["big", "small"])
        #expect(identical.reclaimableBytes == 1000)
    }

    /// The whole row picks the copy, and only where a pick exists. This pins the gate, so it can't
    /// drift from the radio's rule. Not pinned: that the view wraps the row in a button. A
    /// `.hoverAffordance` style draws nothing at rest and the accessibility tree is empty without
    /// an assistive client, so deleting the wrapper leaves this green.
    @Test func onlyACopyThatCanBePickedMakesItsRowClickable() {
        func card(_ matchType: DuplicateMatchType) -> DuplicateGroupCard {
            DuplicateGroupCard(group: group(matchType, name: "x"), isExpanded: true,
                               providerName: nil, scanRoot: nil,
                               densityMetrics: ListDensity.comfortable.metrics,
                               onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                               onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: .row)
        }
        // Identical allows a choice: the redundant row is pickable, the kept one is not.
        let identical = card(.identical)
        #expect(identical.isRowPickable(identical.group.copies[1]))
        #expect(!identical.isRowPickable(identical.group.copies[0]),
                "the kept copy's row must not offer to keep it again")

        // Overlapping allows none: neither row is a control.
        let overlap = card(.overlapping(sharedFraction: 0.3))
        #expect(!overlap.isRowPickable(overlap.group.copies[0]))
        #expect(!overlap.isRowPickable(overlap.group.copies[1]),
                "a row that highlights under the pointer and does nothing is the same complaint")

        // It is the shared rule, not a second copy of it.
        for matchType: DuplicateMatchType in [.identical, .versions, .sameText,
                                              .overlapping(sharedFraction: 0.5)] {
            let c = card(matchType)
            for copy in c.group.copies {
                #expect(c.isRowPickable(copy)
                        == (DuplicateKeeperMarker.style(
                                allowsKeeperChoice: c.group.allowsKeeperChoice,
                                isKeeper: copy.isRecommendedKeeper) == .selectable),
                        "\(matchType) disagrees with the marker rule")
            }
        }
    }

    /// A "merge" that copies nothing is a removal, and the card says so. The action is the same
    /// code path either way; this pins that the wording follows the contents, so a 100%-shared
    /// folder isn't offered a merge that "copies those" 0 unique items.
    // `@MainActor` because a `View`'s members are implicitly main-actor isolated, and
    // `mergeCopiesNothing` closes over one inside `allSatisfy`: off the main actor the isolation
    // check traps rather than failing an assertion.
    @MainActor
    @Test func aMergeThatCopiesNothingSaysSo() {
        func card(_ unique: [Int]) -> DuplicateGroupCard {
            let copies = unique.enumerated().map { i, u in
                DuplicateCopy(id: "/c\(i)/Visa", name: "Visa", isDirectory: true, size: 100,
                              itemCount: 3, modificationDate: nil, uniqueItemCount: u, depth: 1,
                              isRecommendedKeeper: i == 0)
            }
            let g = DuplicateGroup(matchType: .overlapping(sharedFraction: 1.0), name: "Visa",
                                   isDirectory: true, copies: copies, reclaimableBytes: 100)
            return DuplicateGroupCard(group: g, isExpanded: true, providerName: nil, scanRoot: nil,
                                      densityMetrics: ListDensity.comfortable.metrics,
                                      onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
                                      onChooseKeeper: { _ in }, onMerge: {}, onOpenInEditor: nil, headerLayout: .row)
        }
        // Keeper first, then the folded copies' unique counts.
        #expect(card([0, 0]).mergeCopiesNothing, "the folded copy is wholly inside the keeper")
        #expect(!card([0, 2]).mergeCopiesNothing, "two unique items really would be copied")
        #expect(!card([0, 0, 3]).mergeCopiesNothing,
                "one folded copy with something of its own is enough to make it a merge")

        // The note follows, rather than describing a copy of nothing.
        let empty = DuplicateGroupNote.text(for: card([0, 0]).group) ?? ""
        #expect(empty.contains("nothing the keeper lacks"))
        #expect(empty.contains("only trashes it"))
        #expect(!empty.contains("0 unique item"), "the old wording counted the nothing")
        let real = DuplicateGroupNote.text(for: card([0, 2]).group) ?? ""
        #expect(real.contains("2 unique items"))
        #expect(real.contains("copied into"))
    }

    /// A count of one is singular: a number interpolated into a noun phrase is where plural bugs
    /// like "1 items" live.
    @Test func countsReadAsEnglish() {
        #expect(DuplicateGroupCard.uniqueHere(1) == "1 unique here")
        #expect(DuplicateGroupCard.uniqueHere(4) == "4 unique here")
    }

    /// The fold: whole rows at any column count, and never so tight that a short list folds.
    @Test func theFoldIsAWholeNumberOfRows() {
        for columns in 1...3 {
            let fold = LensCardGrid.itemsBeforeFold(columns: columns)
            #expect(fold >= 6, "\(columns) columns folds after \(fold) — too eager for a short list")
            if columns > 1 {
                #expect(fold % columns == 0,
                        "\(fold) tiles in a \(columns)-wide grid leaves the button under a half-row")
            }
        }
        // A degenerate column count cannot produce a zero fold, which would hide every tile.
        #expect(LensCardGrid.itemsBeforeFold(columns: 0) >= 6)
        #expect(LensCardGrid.itemsBeforeFold(columns: 3) == 12)
    }
}

/// Where the two lenses' minimum card widths disagree, and which header a duplicates
/// card draws — both read from the shipped constants rather than restating them.
@Suite struct DuplicateGridWidthTests {

    /// The two lenses ask for different minimums, and the difference bites: a renames card holds a
    /// two-column table of names, a collapsed duplicates tile a caption, and the pane he reads them
    /// in is where they disagree.
    @Test func theDuplicatesTileReachesTwoColumnsWhereARenamesCardCannot() {
        // Both minimums read from the source, not restated, so a change to either can't leave
        // this asserting a column count the app no longer produces.
        let duplicates = LensWorkspaceView.duplicateTileMinimumWidth
        let renames = RenamePassLens.minimumCardWidth
        #expect(duplicates < renames, "a positive control: the two lenses really do differ")

        // The width where they disagree, derived rather than guessed: wide enough for two
        // duplicates tiles, too narrow for two renames cards.
        let pane = duplicates * 2 + LensCardGrid.gutter + LensCardGrid.listHorizontalPadding
        #expect(LensCardGrid.columns(forWidth: pane, minimumCardWidth: duplicates) == 2)
        #expect(LensCardGrid.columns(forWidth: pane, minimumCardWidth: renames) == 1)
    }
}

/// Which header a duplicates card draws depends on the card's width, not the pane's column count.
/// One column only means the pane is narrow; at the app's minimum window width a one-column card
/// is near 350pt, too narrow for the one-line header, which would clip its chevron and figure.
@Suite struct DuplicateCardHeaderLayoutTests {

    private let minimum = DuplicateCardHeaderLayout.rowHeaderMinimumWidth

    @Test func aRoomyCardKeepsTheDenseOneLineHeader() {
        #expect(DuplicateCardHeaderLayout.forCard(width: minimum, isExpanded: false) == .row)
        #expect(DuplicateCardHeaderLayout.forCard(width: 900, isExpanded: false) == .row)
    }

    /// From both sides of the threshold, so the comparison cannot silently invert.
    @Test func aNarrowCardStacksInstead() {
        #expect(DuplicateCardHeaderLayout.forCard(width: minimum - 1, isExpanded: false) == .stacked)
        #expect(DuplicateCardHeaderLayout.forCard(width: 220, isExpanded: false) == .stacked)
        #expect(DuplicateCardHeaderLayout.forCard(width: 0, isExpanded: false) == .stacked,
                "a degenerate width must not produce a header that overflows it")
    }

    /// An expanded card stacks at any width: the row header spends the width after the name on a
    /// subtitle and two figure columns, so a long name truncates even on a wide card. Stacking
    /// gives the name a line to itself.
    @Test func anExpandedCardStacksAtEveryWidth() {
        for width: CGFloat in [220, minimum, 600, 1200] {
            #expect(DuplicateCardHeaderLayout.forCard(width: width, isExpanded: true) == .stacked,
                    "\(width)pt")
        }
    }
}
