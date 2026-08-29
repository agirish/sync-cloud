import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer
@testable import Sync

/// The invisible-column slots behind the Duplicates group header. The model's one claim: a
/// slot is exactly wide enough for the widest member of its vocabulary — derived by measuring,
/// so no verb can overflow its slot and break the columns downstream of it.
///
/// **A third slot, and the render suite that measured it, used to live here.** It sized the
/// match-type badge, which went when the list was sectioned by match type: a badge reading
/// "Versions" under a heading reading *Versions* is the heading once per card. What did not go is
/// the predicate the badge shared with the severity stripe — see
/// `onlyTheMajorityKindMayGoWithoutSeverity` below, which is the surviving half of a test that
/// used to be about badge vocabulary.
@MainActor
@Suite struct DuplicateGroupColumnsTests {

    /// **`identical` is the only kind allowed to carry no severity, and this is still load-bearing
    /// after the badge went.** `DuplicateGroupCard.severity` reads `DuplicateMatchStyle.badgeLabel`
    /// — nil means "the majority kind", which draws no stripe and no wash. A new kind returning nil
    /// would silently join the majority: no stripe, no wash, and nothing to distinguish it in a
    /// list where it needs a human. The badge that once made that visible is gone, so this scan is
    /// now the only thing that would catch it.
    ///
    /// **Swept over `Kind.allCases`, not over a list written here** — the previous version compared
    /// one hand-copied array against another, so a new case left both stale together and the test
    /// green: an "every X does Y" scan that cannot see the X it is missing.
    @Test func onlyTheMajorityKindMayGoWithoutSeverity() {
        for kind in DuplicateMatchType.Kind.allCases {
            let type = Self.sample(of: kind)
            if DuplicateMatchStyle.badgeLabel(type) == nil {
                #expect(kind == .identical,
                        "\(kind) reports no severity — it would draw with the majority's weight, unstriped and unwashed, in a section that exists because it needs a person")
            }
        }
        // The positive control: the predicate really does separate the kinds, rather than
        // answering nil (or non-nil) for everything, which would make the loop above vacuous.
        #expect(DuplicateMatchStyle.badgeLabel(.identical) == nil)
        #expect(DuplicateMatchStyle.badgeLabel(.versions) != nil)
    }

    /// One `DuplicateMatchType` per `Kind`, exhaustively — the switch is the point, because it is
    /// what stops compiling when a case is added, which is how this stays honest without anyone
    /// remembering to come back here.
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
