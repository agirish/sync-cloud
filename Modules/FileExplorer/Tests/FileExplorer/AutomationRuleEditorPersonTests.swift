import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The editor's half of "a rule can say whose document it is".
///
/// The condition itself is pinned in `Sync` (`PersonRuleTests`: matching, completeness, the wire
/// shape, a removed person). These pin what the editor lets a user build, three rules that would
/// fail silently:
///
/// - A person condition needs a roster: with nobody to point at, the row could never be completed
///   and Save would be blocked with nothing saying why.
/// - A row's own type is always among its picker's options, even a type nobody may add: a `Picker`
///   whose selection matches no tag renders blank and reads as broken.
/// - A fresh person row starts empty and stays incomplete until somebody is chosen. Defaulting to
///   the first person would save a rule about someone the user never picked.
///
/// `AutomationRuleEditorTests` covers the editor's other seams, none of which involve a person.
@Suite struct AutomationRuleEditorPersonTests {

    private static let household = [
        Person(id: "mother", displayName: "Mother", relationship: "wife"),
        Person(id: "daughter", displayName: "Daughter", relationship: "daughter"),
    ]

    // MARK: What a user may add

    /// "Is this person's" is offered only when there is somebody to point at. Shown offering it
    /// first, because "missing from the list" alone is satisfied by an empty list.
    @Test func aPersonConditionIsOfferedOnlyWithARoster() {
        let withRoster = ConditionType.addable(hasPeople: true)
        #expect(withRoster.contains(.personIs),
                "the person condition cannot be added even with a household on file")

        let without = ConditionType.addable(hasPeople: false)
        #expect(!without.contains(.personIs),
                "a person row can be added with nobody to point at — it could never be completed, and Save would refuse it with nothing on screen explaining why")
        // The roster governs that one type and nothing else.
        #expect(without.count == withRoster.count - 1,
                "an empty roster withdrew \(withRoster.count - without.count) condition types, not just the person one")
    }

    /// `unrecognized` is never addable, roster or not. It displays what a newer build wrote so it
    /// can be removed; as a new row it would be a condition this build can't edit or evaluate.
    @Test func theNewerBuildPlaceholderIsNeverAddable() {
        for hasPeople in [true, false] {
            #expect(!ConditionType.addable(hasPeople: hasPeople).contains(.unrecognized),
                    "the unrecognized placeholder is addable (hasPeople: \(hasPeople))")
        }
        // Non-vacuity: the case still exists, so `addable` is what filters it out.
        #expect(ConditionType.allCases.contains(.unrecognized),
                "the unrecognized case is gone — this test asserts nothing")
    }

    // MARK: The picker can never be blank

    /// The current type is added, not duplicated: `ForEach` over `ConditionType` is keyed on the
    /// case, so a type listed twice is a duplicate SwiftUI id, and every ordinary row goes through
    /// this clause. Added at all, so the picker is never blank: a person rule opens with an empty
    /// roster until the store loads, and a newer build's condition is never addable.
    @Test func thePickerNeverOffersATypeTwice() {
        // Literal types, since the loop's check goes through the `ConditionType(_:)` mapping.
        #expect(AutomationRuleEditor.pickerTypes(for: .personIs("daughter"), hasPeople: false).contains(.personIs),
                "with no roster a saved person row's kind picker matches no tag and renders blank")
        #expect(AutomationRuleEditor.pickerTypes(for: .unrecognized(name: "x", payload: Data()), hasPeople: true)
                    .contains(.unrecognized),
                "an alien row's picker matches no tag and renders blank, reading as broken rather than as unreadable")
        for condition: AutomationCondition in [.personIs("daughter"), .kindIs(.pdf),
                                               .nameMatches("*.pdf"),
                                               .unrecognized(name: "x", payload: Data())] {
            for hasPeople in [true, false] {
                let types = AutomationRuleEditor.pickerTypes(for: condition, hasPeople: hasPeople)
                #expect(Set(types).count == types.count,
                        "\(condition) offers a duplicated type (hasPeople: \(hasPeople)): \(types)")
                #expect(types.contains(ConditionType(condition)),
                        "\(condition)'s own type is missing from its picker (hasPeople: \(hasPeople))")
            }
        }
    }

    // MARK: A fresh row picks nobody

    /// Switching a row to "Is this person's" chooses nobody, and the row is incomplete until
    /// somebody is picked. `isComplete` gates `isRunnable` and so Save; a chosen id is shown
    /// passing, so "incomplete" isn't simply true of every person condition.
    @Test func aFreshPersonRowNamesNobodyAndCannotBeSaved() {
        let fresh = ConditionType.personIs.makeDefault()
        #expect(fresh == .personIs(""),
                "a fresh person row arrives pointing at \(fresh) — a rule about somebody the user never picked")
        #expect(!fresh.isComplete,
                "an unfilled person row is complete, so Save would accept a rule naming nobody")
        #expect(AutomationCondition.personIs("daughter").isComplete,
                "a person row is incomplete even with somebody chosen — the gate above is not about the empty id")
    }

    /// Every addable type produces a condition of its own type: choose a kind, get a row of that
    /// kind. Driven off `addable`, so a new type is covered the day it appears.
    @Test func everyAddableTypeMakesARowOfItsOwnKind() {
        let addable = ConditionType.addable(hasPeople: true)
        #expect(addable.count >= 8, "only \(addable.count) types are addable — check this still covers the picker")
        for type in addable {
            #expect(ConditionType(type.makeDefault()) == type,
                    "choosing “\(type.label)” builds a \(ConditionType(type.makeDefault())) row instead")
        }
    }

    /// Every addable type except the person one starts complete, so a new row is usable at once.
    /// Fails if the person default is ever filled in.
    @Test func onlyThePersonRowStartsIncomplete() {
        let incomplete = ConditionType.addable(hasPeople: true)
            .filter { !$0.makeDefault().isComplete }
        #expect(incomplete == [.personIs],
                "the types starting incomplete are \(incomplete) — expected exactly the person row, whose value the editor cannot guess")
    }
}
