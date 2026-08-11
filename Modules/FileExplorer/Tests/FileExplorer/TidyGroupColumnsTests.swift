import Testing
import Design
@testable import FileExplorer
@testable import Sync

/// The invisible-column slots behind the Duplicates group header. The model's one claim: a
/// slot is exactly wide enough for the widest member of its vocabulary — derived by measuring,
/// so no badge or verb can overflow its slot and break the columns downstream of it.
@MainActor
@Suite struct TidyGroupColumnsTests {

    @Test func everyBadgeFitsItsSlot() {
        let slot = TidyGroupColumns.badgeSlotWidth(scale: 1)
        for type in TidyGroupColumns.badgeVocabulary {
            let width = LabelMetrics.symbolWidth(TidyMatchStyle.symbol(type),
                                                 font: .system(size: 11, weight: .bold), scale: 1)
                + 6
                + LabelMetrics.width(of: TidyMatchStyle.label(type),
                                     font: .system(size: 11, weight: .bold), scale: 1)
                + 2 * PillVariant.mini.horizontalPadding
            #expect(width <= slot, "\(type) overflows the badge slot")
        }
        // And the slot is spent on a real member, not padding — it equals the widest one.
        #expect(TidyGroupColumns.badgeVocabulary.contains { type in
            let width = LabelMetrics.symbolWidth(TidyMatchStyle.symbol(type),
                                                 font: .system(size: 11, weight: .bold), scale: 1)
                + 6
                + LabelMetrics.width(of: TidyMatchStyle.label(type),
                                     font: .system(size: 11, weight: .bold), scale: 1)
                + 2 * PillVariant.mini.horizontalPadding
            return width == slot
        })
    }

    @Test func theVocabularyCoversEveryMatchType() {
        // A new DuplicateMatchType case must join the badge vocabulary or its badge can
        // overflow the slot silently. Sweep every case shape the enum has today.
        let represented = Set(TidyGroupColumns.badgeVocabulary.map { TidyMatchStyle.label($0) })
        let all: [DuplicateMatchType] = [.identical, .sameText,
                                         .overlapping(sharedFraction: 1.0), .nameOnly, .versions]
        for type in all {
            #expect(represented.contains(TidyMatchStyle.label(type)),
                    "\(type) is not represented in the badge vocabulary")
        }
    }

    @Test func slotsScaleWithTheFont() {
        // At a larger scale every slot must grow — a fixed slot under a grown font truncates.
        #expect(TidyGroupColumns.badgeSlotWidth(scale: 1.35) > TidyGroupColumns.badgeSlotWidth(scale: 1))
        #expect(TidyGroupColumns.verbSlotWidth(scale: 1.35) > TidyGroupColumns.verbSlotWidth(scale: 1))
        #expect(TidyGroupColumns.digitsSlotWidth(scale: 1.35) > TidyGroupColumns.digitsSlotWidth(scale: 1))
    }
}
