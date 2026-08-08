import Foundation
import Testing
@testable import Sync

/// The household matcher, pinned against **the real roster**, because the hard cases are not
/// hypothetical — they are the specific way these six names overlap.
///
/// `abhishek` is one person's first name and three others' surname; `girish` is Dad's first name,
/// Mom's surname and Abhishek's surname. Every test below fails under the obvious implementation
/// (intersect the file's tokens with a set of known person words), which is what the engine did
/// before this type existed.
@Suite struct PersonRegistryTests {

    /// Abhishek's actual household — the fixture is the roster, so a rule that only works on
    /// invented names cannot pass here.
    static let household = PersonRegistry(people: [
        Person(id: "abhishek", displayName: "Abhishek", relationship: "me",
               fullNames: ["Abhishek Girish"]),
        Person(id: "shweta", displayName: "Shweta", relationship: "wife",
               fullNames: ["Shweta Dani", "Shweta Ravindra Dani", "Shweta R Dani", "Shweta Abhishek"]),
        Person(id: "aditi", displayName: "Aditi", relationship: "daughter",
               fullNames: ["Aditi Abhishek"]),
        Person(id: "divit", displayName: "Divit", relationship: "son",
               fullNames: ["Divit Abhishek"]),
        Person(id: "muktha", displayName: "Muktha", relationship: "mother",
               fullNames: ["Muktha Girish"], aliases: ["Mom", "Mother"]),
        Person(id: "girish", displayName: "Girish", relationship: "father",
               fullNames: ["Girish Krishnamurthy"], aliases: ["Dad", "Father"]),
    ])

    // MARK: - The lattice

    /// **The case that motivates phrase matching.** "Aditi Abhishek" is the daughter's full name,
    /// and `abhishek` is also her father's given name — so a token intersection reports both people
    /// and the document becomes unattributable. The phrase consumes the surname: Aditi alone.
    @Test func aFullNameConsumesItsSurname() {
        #expect(Self.household.detect(in: "Aditi Abhishek - OCI Card") == ["aditi"])
        #expect(Self.household.detect(in: "Divit Abhishek Report Card 2026") == ["divit"])
        #expect(Self.household.detect(in: "Shweta Abhishek PAN") == ["shweta"])
    }

    /// The mirror: his own full name is not his daughter's. Without this, "longest wins" could be
    /// satisfied by any rule that simply preferred whichever person sorted first.
    @Test func hisOwnFullNameIsHisAlone() {
        #expect(Self.household.detect(in: "Abhishek Girish - Passport.pdf") == ["abhishek"])
        #expect(Self.household.detect(in: "Girish Krishnamurthy - OCI") == ["girish"])
        #expect(Self.household.detect(in: "Muktha Girish - Visa") == ["muktha"])
    }

    /// A shared token standing alone reads as the person whose *given* name it is. `girish` on its
    /// own is Dad — not Mom (whose surname it is) and not Abhishek (whose surname it is).
    @Test func aSharedTokenAloneIsTheGivenName() {
        #expect(Self.household.detect(in: "Girish - Aadhaar.pdf") == ["girish"])
        #expect(Self.household.detect(in: "Abhishek W2 2025") == ["abhishek"])
    }

    /// A token unique to one person attributes them from anywhere in the string — this is the
    /// signal that survives when a document prints a surname with no given name.
    @Test func aUniqueTokenAttributesFromAnywhere() {
        #expect(Self.household.detect(in: "Statement for Dani, S.") == ["shweta"])
        #expect(Self.household.detect(in: "KRISHNAMURTHY pension order") == ["girish"])
    }

    /// **Mom is Muktha.** The whole reason the alias map had to stop being discarded: a file the
    /// user named `Mom - passport.pdf` must resolve to the same person as a folder whose axis says
    /// `Muktha`, or the cross-person veto fires against the correct folder.
    @Test func aRelationshipAliasIsTheSamePerson() {
        #expect(Self.household.detect(in: "Mom - passport.pdf") == ["muktha"])
        #expect(Self.household.detect(in: "Dad medical records") == ["girish"])
        #expect(Self.household.person(forAxisValue: "Muktha") == "muktha")
        #expect(Self.household.person(forAxisValue: "Mom") == "muktha")
    }

    /// **A longer name form wins over a shorter one embedded inside it**, which is a different rule
    /// from consuming the span and needs its own case to reach.
    ///
    /// The roster grows — a brother-in-law, a brother — and the moment a two-word name sits inside
    /// somebody's three-word name, order decides the answer. Shweta's full form is *Shweta Ravindra
    /// Dani*; add a *Ravindra Dani* and matching shortest-first attributes her PAN card to him as
    /// well as to her. Only the longest match may claim the span.
    @Test func aLongerNameFormWinsOverAShorterOneInsideIt() {
        let withInLaw = PersonRegistry(people: [
            Person(id: "shweta", displayName: "Shweta",
                   fullNames: ["Shweta Ravindra Dani", "Shweta Dani"]),
            Person(id: "ravindra", displayName: "Ravindra", fullNames: ["Ravindra Dani"]),
        ])
        #expect(withInLaw.detect(in: "Shweta Ravindra Dani - PAN card") == ["shweta"])
        // And the shorter name still matches on its own — the rule is precedence, not suppression.
        #expect(withInLaw.detect(in: "Ravindra Dani - lease") == ["ravindra"])
    }

    /// A document naming two people names two people — the veto is about contradiction, and a
    /// joint document must not be forced onto one of them.
    @Test func aJointDocumentNamesBoth() {
        #expect(Self.household.detect(in: "Abhishek Girish and Shweta Dani - Grant Deed")
                == ["abhishek", "shweta"])
    }

    /// Nobody named is the ordinary state for a scan, and it must stay empty rather than falling
    /// back to a nearest match.
    @Test func aFileNamingNobodyDetectsNobody() {
        #expect(Self.household.detect(in: "Scan 2026-08-02").isEmpty)
        #expect(Self.household.detect(in: "").isEmpty)
        #expect(PersonRegistry(people: []).detect(in: "Aditi Abhishek").isEmpty)
    }

    /// An initial is part of a phrase and never a key on its own: "Shweta R Dani" matches her, but
    /// a stray "R" in some other document names nobody.
    @Test func anInitialIsNeverAStandaloneKey() {
        #expect(Self.household.detect(in: "Shweta R Dani - PAN card") == ["shweta"])
        #expect(Self.household.detect(in: "Form R - schedule").isEmpty)
    }

    /// Separators are not significant — a document prints names with commas, underscores and
    /// hyphens, and the phrase has to survive all of them.
    @Test func phrasesMatchAcrossSeparators() {
        #expect(Self.household.detect(in: "aditi_abhishek-oci.pdf") == ["aditi"])
        #expect(Self.household.detect(in: "DIVIT ABHISHEK") == ["divit"])
    }

    // MARK: - The derived split, and what Settings shows

    /// **Strong vs shared is computed, never declared.** Adding a seventh person must be able to
    /// demote a token, so the split is derived from the roster on every build.
    @Test func theStrongWeakSplitIsDerivedFromTheRoster() {
        let breakdown = Self.household.tokenBreakdown(for: "aditi")
        #expect(breakdown.unique == ["aditi"])
        #expect(breakdown.shared == ["abhishek"])
        #expect(Self.household.othersSharing("abhishek", with: "aditi") == 3)

        // A roster where the surname is nobody else's makes the same token unique — the split
        // followed the roster rather than a hard-coded list.
        let smaller = PersonRegistry(people: [
            Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
        ])
        #expect(smaller.tokenBreakdown(for: "aditi").shared.isEmpty)
        #expect(smaller.tokenBreakdown(for: "aditi").unique == ["abhishek", "aditi"])
    }

    /// An axis value the registry cannot pin to exactly one person resolves to nil rather than
    /// guessing — the veto reads this, and a wrong resolution there refuses a correct folder.
    @Test func anUnresolvableAxisValueIsNil() {
        #expect(Self.household.person(forAxisValue: "Ravi") == nil)
        #expect(Self.household.person(forAxisValue: "Abhishek and Shweta") == nil)
    }

    // MARK: - Seeding from a profile with no people.json

    /// The seed carries the alias map, which is the fix that matters even with no `people.json`:
    /// `mom` and `muktha` become one person rather than two tokens in a bag.
    @Test func seedingFromAProfilePairsAliasesWithTheirPerson() {
        let profile = FolderProfile(profileId: "t", root: "~", folders: [:],
                                    personTokens: ["abhishek", "shweta", "mom", "muktha"],
                                    personAliases: ["mom": "muktha"])
        let seeded = PersonRegistry.seeded(from: profile)
        #expect(seeded.source == .profileAxis)
        #expect(Set(seeded.people.map(\.id)) == ["abhishek", "shweta", "muktha"])
        #expect(seeded.detect(in: "Mom - passport.pdf") == ["muktha"])
        #expect(seeded.person(forAxisValue: "Muktha") == "muktha")
        // No full names to work with, so a bare surname reaches nobody — the honest outcome, and
        // the reason `people.json` is worth writing.
        #expect(seeded.detect(in: "Dani statement").isEmpty)
    }
}
