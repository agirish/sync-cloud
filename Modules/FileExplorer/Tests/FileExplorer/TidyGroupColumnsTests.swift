import Testing
import Design
@testable import FileExplorer
@testable import Sync

/// The invisible-column slots behind the Duplicates group header. The model's one claim: a
/// slot is exactly wide enough for the widest member of its vocabulary — derived by measuring,
/// so no badge or verb can overflow its slot and break the columns downstream of it.
@MainActor
@Suite struct TidyGroupColumnsTests {

    /// - Note: The `width <= slot` half is **true by construction** — `badgeSlotWidth` is the
    ///   maximum of this very expression over this very vocabulary, so it can only fail if the two
    ///   stop being the same formula. That is worth keeping (it is exactly the drift that would
    ///   break the columns) but it is not evidence that any badge *fits* anything. The half below
    ///   it — the slot equals a real member — is the one that can fail on a bad measurement, and
    ///   `theSlotIsWideEnoughForTheWidestBadgeDrawnAtSize` measures the drawn text independently.
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

    /// A new `DuplicateMatchType` case must join the badge vocabulary, or its badge can overflow
    /// the slot silently.
    ///
    /// **Swept over `Kind.allCases`, not over a list written here.** It was a hand-copied array of
    /// the five shapes the enum had, which is the same hand copy as the vocabulary it is checking:
    /// a sixth case left both stale together and this test green — a "every X does Y" scan that
    /// cannot see the X it is missing.
    @Test func theVocabularyCoversEveryMatchType() {
        let represented = Set(TidyGroupColumns.badgeVocabulary.map { TidyMatchStyle.label($0) })
        for kind in DuplicateMatchType.Kind.allCases {
            let type = Self.sample(of: kind)
            #expect(represented.contains(TidyMatchStyle.label(type)),
                    "\(kind) is not represented in the badge vocabulary")
        }
    }

    /// One `DuplicateMatchType` per `Kind`, exhaustively — the switch is the point, because it is
    /// what stops compiling when a case is added, which is how this stays honest without anyone
    /// remembering to come back here.
    static func sample(of kind: DuplicateMatchType.Kind) -> DuplicateMatchType {
        switch kind {
        case .identical: return .identical
        case .sameText: return .sameText
        case .overlapping: return .overlapping(sharedFraction: 1.0)
        case .nameOnly: return .nameOnly
        case .versions: return .versions
        }
    }

    @Test func slotsScaleWithTheFont() {
        // At a larger scale every slot must grow — a fixed slot under a grown font truncates.
        #expect(TidyGroupColumns.badgeSlotWidth(scale: 1.35) > TidyGroupColumns.badgeSlotWidth(scale: 1))
        #expect(TidyGroupColumns.verbSlotWidth(scale: 1.35) > TidyGroupColumns.verbSlotWidth(scale: 1))
        #expect(TidyGroupColumns.digitsSlotWidth(scale: 1.35) > TidyGroupColumns.digitsSlotWidth(scale: 1))
    }
}
