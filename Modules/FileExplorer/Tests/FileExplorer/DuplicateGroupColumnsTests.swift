import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer
@testable import Sync

/// The invisible-column slots behind the Duplicates group header. A slot is exactly as wide as the
/// widest member of its vocabulary, measured, so no verb can overflow it and break the columns
/// after it. Also the severity predicate the cards share.
@MainActor
@Suite struct DuplicateGroupColumnsTests {

    /// `identical` is the only kind allowed no severity. `DuplicateGroupCard.severity` reads
    /// `DuplicateMatchStyle.badgeLabel`, where nil means the majority kind: no stripe, no wash. A
    /// new kind returning nil would silently join it, with nothing to mark it as needing a person.
    /// Swept over `Kind.allCases`, not a list written here, so a new case can't be missed.
    @Test func onlyTheMajorityKindMayGoWithoutSeverity() {
        for kind in DuplicateMatchType.Kind.allCases {
            let type = Self.sample(of: kind)
            if DuplicateMatchStyle.badgeLabel(type) == nil {
                #expect(kind == .identical,
                        "\(kind) reports no severity — it would draw with the majority's weight, unstriped and unwashed, in a section that exists because it needs a person")
            }
        }
        // The control: the predicate really separates the kinds, or the loop above is vacuous.
        #expect(DuplicateMatchStyle.badgeLabel(.identical) == nil)
        #expect(DuplicateMatchStyle.badgeLabel(.versions) != nil)
    }

    /// One `DuplicateMatchType` per `Kind`. The exhaustive switch stops compiling when a case is
    /// added, so this can't go stale unnoticed.
    static func sample(of kind: DuplicateMatchType.Kind) -> DuplicateMatchType {
        switch kind {
        case .identical: return .identical
        case .sameText: return .sameText
        case .overlapping: return .overlapping(sharedFraction: 1.0)
        case .versions: return .versions
        }
    }

    @Test func slotsScaleWithTheFont() {
        // At a larger scale every slot must grow — a fixed slot under a grown font truncates.
        #expect(DuplicateGroupColumns.verbSlotWidth(scale: 1.35) > DuplicateGroupColumns.verbSlotWidth(scale: 1))
        #expect(DuplicateGroupColumns.digitsSlotWidth(scale: 1.35) > DuplicateGroupColumns.digitsSlotWidth(scale: 1))
    }

    /// The verb slot holds the widest verb, and is spent on a real one rather than on padding.
    @Test func everyVerbFitsItsSlot() {
        let slot = DuplicateGroupColumns.verbSlotWidth(scale: 1)
        for verb in DuplicateGroupColumns.verbVocabulary {
            #expect(LabelMetrics.width(of: verb, font: .system(size: 11), scale: 1) <= slot,
                    "\(verb) overflows the verb slot")
        }
        #expect(DuplicateGroupColumns.verbVocabulary.contains {
            LabelMetrics.width(of: $0, font: .system(size: 11), scale: 1) == slot
        })
    }
}
