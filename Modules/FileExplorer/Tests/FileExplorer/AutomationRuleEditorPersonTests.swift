import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The editor's half of "a rule can say whose document it is".
///
/// The condition itself is thoroughly pinned in `Sync` — `PersonRuleTests` covers matching,
/// completeness, the wire shape and the summary for a removed person. **Every rule the editor added
/// alongside it went untested**, and they are not the same subject: the condition decides what a
/// saved rule *matches*, and these decide what a user can build in the first place.
///
/// Three of them, all of which fail silently rather than loudly:
///
/// - **A person condition needs a roster.** Offering "Is this person's" with nobody to point at
///   builds a row that can never be completed, and Save is blocked with nothing on screen saying why.
/// - **A row's own type is always among its picker's options**, even a type nobody may add. A
///   `Picker` whose selection matches no tag renders *blank*, so the alternative is a control that
///   reads as broken rather than as unreadable.
/// - **A fresh person row starts empty**, and stays incomplete until somebody is chosen. Defaulting
///   to the first person on the roster would save a rule about a member of the household the user
///   never picked — the kind of wrong that files documents for two years before anyone notices.
///
/// `AutomationRuleEditorTests` covers this file's older seams (`relativePath`, `canonicalized`,
/// `isUnmatchableMentions`, `canSave`); it is untouched, and none of those has any person behaviour.
@Suite struct AutomationRuleEditorPersonTests {

    private static let household = [
        Person(id: "mother", displayName: "Mother", relationship: "wife"),
        Person(id: "daughter", displayName: "Daughter", relationship: "daughter"),
    ]

    // MARK: What a user may add

    /// **"Is this person's" is offered only when there is somebody to point at.**
    ///
    /// Both directions, in one test and in this order: the absence on an empty roster is the claim,
    /// and an assertion that some case is missing from a list is satisfied by an empty list — so the
    /// same call has to be shown *offering* it first.
    @Test func aPersonConditionIsOfferedOnlyWithARoster() {
        let withRoster = ConditionType.addable(hasPeople: true)
        #expect(withRoster.contains(.personIs),
                "the person condition cannot be added even with a household on file")

        let without = ConditionType.addable(hasPeople: false)
        #expect(!without.contains(.personIs),
                "a person row can be added with nobody to point at — it could never be completed, and Save would refuse it with nothing on screen explaining why")
        // The roster governs that one type and nothing else: everything a person-less machine could
        // add before, it can still add.
        #expect(without.count == withRoster.count - 1,
                "an empty roster withdrew \(withRoster.count - without.count) condition types, not just the person one")
    }

    /// **`unrecognized` is never addable**, roster or no roster. It exists to display what a newer
    /// build wrote so it can be seen and removed; offering it as a *new* row would let a user mint a
    /// condition this build has no editor for and cannot evaluate.
    @Test func theNewerBuildPlaceholderIsNeverAddable() {
        for hasPeople in [true, false] {
            #expect(!ConditionType.addable(hasPeople: hasPeople).contains(.unrecognized),
                    "the unrecognized placeholder is addable (hasPeople: \(hasPeople))")
        }
        // Non-vacuity: the case is still in `allCases`, so this is a statement about `addable`
        // filtering it out rather than about the case having quietly been deleted.
        #expect(ConditionType.allCases.contains(.unrecognized),
                "the unrecognized case is gone — this test asserts nothing")
    }

    // MARK: The picker can never be blank

    /// **A person row keeps its own type in the picker after the roster empties.**
    ///
    /// The exact hazard, and it is reachable: both call sites pass
    /// `syncManager.filingPeopleStore?.people ?? []`, so a rule saved with a person condition is
    /// opened with an empty roster whenever the store has not loaded. `addable` excludes `personIs`
    /// there — so without the "plus the row's current type" clause the picker holds no tag matching
    /// its own selection, and a `Picker` in that state draws nothing at all.
    ///
    /// The empty-roster case is asserted against the populated one, so what is measured is the
    /// clause and not the fact that `personIs` is in the list generally.
    @Test func aPersonRowKeepsItsTypeInThePickerWithNoRoster() {
        let row = AutomationCondition.personIs("daughter")
        #expect(AutomationRuleEditor.pickerTypes(for: row, hasPeople: true).contains(.personIs),
                "a person row cannot show its own type even with a roster — the harness is wrong")
        #expect(AutomationRuleEditor.pickerTypes(for: row, hasPeople: false).contains(.personIs),
                "with no roster a saved person row's kind picker matches no tag and renders blank")
    }

    /// The same clause for the case it was written for: a condition from a newer build.
    @Test func anAlienRowKeepsItsTypeInThePicker() {
        let alien = AutomationCondition.unrecognized(name: "colourIs", payload: Data("{}".utf8))
        let types = AutomationRuleEditor.pickerTypes(for: alien, hasPeople: true)
        #expect(types.contains(.unrecognized),
                "an alien row's picker matches no tag and renders blank, reading as broken rather than as unreadable")
        #expect(!ConditionType.addable(hasPeople: true).contains(.unrecognized),
                "the clause under test is inert — `unrecognized` is addable, so it would be in the list anyway")
    }

    /// **The current type is added, not duplicated.** `ForEach` over `ConditionType` is keyed on the
    /// case itself, so a list holding one twice is a duplicate SwiftUI id — and the ordinary path
    /// (an addable row, on a machine with a roster) goes through the same clause every time the
    /// picker is built.
    @Test func thePickerNeverOffersATypeTwice() {
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

    /// **Switching a row to "Is this person's" chooses nobody**, and the row is incomplete until
    /// somebody is picked.
    ///
    /// Both halves, because the first alone is a statement about a string. `isComplete` is what
    /// `isRunnable` — and therefore Save — is built on, so the empty default is only meaningful if
    /// it actually holds the rule back; and a non-empty id has to be shown passing, or "incomplete"
    /// would be true of every person condition and this would measure nothing.
    @Test func aFreshPersonRowNamesNobodyAndCannotBeSaved() {
        let fresh = ConditionType.personIs.makeDefault()
        #expect(fresh == .personIs(""),
                "a fresh person row arrives pointing at \(fresh) — a rule about somebody the user never picked")
        #expect(!fresh.isComplete,
                "an unfilled person row is complete, so Save would accept a rule naming nobody")
        #expect(AutomationCondition.personIs("daughter").isComplete,
                "a person row is incomplete even with somebody chosen — the gate above is not about the empty id")
    }

    /// Every addable type produces a condition of **its own** type, which is what makes the kind
    /// picker's swap honest: choose a kind, get a row of that kind.
    ///
    /// Driven off `addable` rather than a list written here, so a type added later is covered the
    /// day it appears rather than the day someone remembers this file.
    @Test func everyAddableTypeMakesARowOfItsOwnKind() {
        let addable = ConditionType.addable(hasPeople: true)
        #expect(addable.count >= 8, "only \(addable.count) types are addable — check this still covers the picker")
        for type in addable {
            #expect(ConditionType(type.makeDefault()) == type,
                    "choosing “\(type.label)” builds a \(ConditionType(type.makeDefault())) row instead")
        }
    }

    /// Every addable type **except** the person one starts complete, so a new row is usable
    /// immediately; the person row is the deliberate exception, and its emptiness is the reason.
    ///
    /// This is the test that would catch the person default being "helpfully" filled in: it asserts
    /// the exception exists rather than merely tolerating it.
    @Test func onlyThePersonRowStartsIncomplete() {
        let incomplete = ConditionType.addable(hasPeople: true)
            .filter { !$0.makeDefault().isComplete }
        #expect(incomplete == [.personIs],
                "the types starting incomplete are \(incomplete) — expected exactly the person row, whose value the editor cannot guess")
    }
}
