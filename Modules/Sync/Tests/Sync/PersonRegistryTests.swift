import Foundation
import Testing
@testable import Sync

/// The household matcher, pinned against a roster shaped like the real one, because the hard cases
/// are the way these six names overlap: `father` is one person's first name and three others'
/// surname, and `elder` is Dad's first name and two others' surname. Every test below fails under
/// the obvious rule, intersecting the file's tokens with a set of known person words.
@Suite struct PersonRegistryTests {

    /// The household, overlaps and all, so a rule that only works on tidy invented names can't pass.
    static let household = PersonRegistry(people: [
        Person(id: "father", displayName: "Father", relationship: "me",
               fullNames: ["Father Elder"]),
        Person(id: "mother", displayName: "Mother", relationship: "wife",
               fullNames: ["Mother Maiden", "Mother Inlaw Maiden", "Mother I Maiden", "Mother Father"]),
        Person(id: "daughter", displayName: "Daughter", relationship: "daughter",
               fullNames: ["Daughter Father"]),
        Person(id: "son", displayName: "Son", relationship: "son",
               fullNames: ["Son Father"]),
        Person(id: "granny", displayName: "Granny", relationship: "mother",
               fullNames: ["Granny Elder"], aliases: ["Mom", "Mother"]),
        Person(id: "elder", displayName: "Elder", relationship: "father",
               fullNames: ["Elder Forebear"], aliases: ["Dad", "Grandad"]),
    ])

    // MARK: - The lattice

    /// The case for phrase matching: "Daughter Father" is the daughter's full name, and `father` is
    /// also her father's given name, so a token intersection reports both. The phrase consumes the
    /// surname: Daughter alone.
    @Test func aFullNameConsumesItsSurname() {
        #expect(Self.household.detect(in: "Daughter Father - OCI Card") == ["daughter"])
        #expect(Self.household.detect(in: "Son Father Report Card 2026") == ["son"])
        #expect(Self.household.detect(in: "Mother Father PAN") == ["mother"])
    }

    /// The mirror: his own full name is not his daughter's. Without it, any rule that preferred
    /// whichever person sorted first would pass for "longest wins".
    @Test func hisOwnFullNameIsHisAlone() {
        #expect(Self.household.detect(in: "Father Elder - Passport.pdf") == ["father"])
        #expect(Self.household.detect(in: "Elder Forebear - OCI") == ["elder"])
        #expect(Self.household.detect(in: "Granny Elder - Visa") == ["granny"])
    }

    /// A shared token standing alone reads as the person whose given name it is: `elder` alone is
    /// Dad, not Mom or Father, whose surname it is.
    @Test func aSharedTokenAloneIsTheGivenName() {
        #expect(Self.household.detect(in: "Elder - Aadhaar.pdf") == ["elder"])
        #expect(Self.household.detect(in: "Father W2 2025") == ["father"])
    }

    /// A token unique to one person attributes them from anywhere in the string: the signal that
    /// survives when a document prints a surname with no given name.
    @Test func aUniqueTokenAttributesFromAnywhere() {
        #expect(Self.household.detect(in: "Statement for Maiden, S.") == ["mother"])
        #expect(Self.household.detect(in: "FOREBEAR pension order") == ["elder"])
    }

    /// Mom is Granny: a file named `Mom - passport.pdf` must resolve to the same person as a folder
    /// whose axis says `Granny`, or the cross-person veto fires against the correct folder.
    @Test func aRelationshipAliasIsTheSamePerson() {
        #expect(Self.household.detect(in: "Mom - passport.pdf") == ["granny"])
        #expect(Self.household.detect(in: "Dad medical records") == ["elder"])
        #expect(Self.household.person(forAxisValue: "Granny") == "granny")
        #expect(Self.household.person(forAxisValue: "Mom") == "granny")
    }

    /// A longer name form wins over a shorter one inside it, a different rule from consuming the
    /// span. With *Mother Inlaw Maiden* and *Inlaw Maiden* on one roster, matching shortest-first
    /// would attribute her PAN card to him as well. Only the longest match may claim the span.
    @Test func aLongerNameFormWinsOverAShorterOneInsideIt() {
        let withInLaw = PersonRegistry(people: [
            Person(id: "mother", displayName: "Mother",
                   fullNames: ["Mother Inlaw Maiden", "Mother Maiden"]),
            Person(id: "inlaw", displayName: "Inlaw", fullNames: ["Inlaw Maiden"]),
        ])
        #expect(withInLaw.detect(in: "Mother Inlaw Maiden - PAN card") == ["mother"])
        // The shorter name still matches on its own: the rule is precedence, not suppression.
        #expect(withInLaw.detect(in: "Inlaw Maiden - lease") == ["inlaw"])
    }

    /// A document naming two people names both: the veto is about contradiction, and a joint
    /// document must not be forced onto one of them.
    @Test func aJointDocumentNamesBoth() {
        #expect(Self.household.detect(in: "Father Elder and Mother Maiden - Grant Deed")
                == ["father", "mother"])
    }

    /// Nobody named is the ordinary state for a scan, and it must stay empty rather than falling
    /// back to a nearest match.
    @Test func aFileNamingNobodyDetectsNobody() {
        #expect(Self.household.detect(in: "Scan 2026-08-02").isEmpty)
        #expect(Self.household.detect(in: "").isEmpty)
        #expect(PersonRegistry(people: []).detect(in: "Daughter Father").isEmpty)
    }

    /// An initial is part of a phrase and never a key on its own: "Mother I Maiden" matches her, but
    /// a stray "R" in some other document names nobody.
    @Test func anInitialIsNeverAStandaloneKey() {
        #expect(Self.household.detect(in: "Mother I Maiden - PAN card") == ["mother"])
        #expect(Self.household.detect(in: "Form R - schedule").isEmpty)
    }

    /// Separators are not significant: names come with commas, underscores and hyphens, and the
    /// phrase has to survive all of them.
    @Test func phrasesMatchAcrossSeparators() {
        #expect(Self.household.detect(in: "daughter_father-oci.pdf") == ["daughter"])
        #expect(Self.household.detect(in: "SON FATHER") == ["son"])
    }

    // MARK: - The derived split, and what Settings shows

    /// Strong vs shared is computed, never declared: adding a person must be able to demote a
    /// token, so the split is derived from the roster on every build.
    @Test func theStrongWeakSplitIsDerivedFromTheRoster() {
        let breakdown = Self.household.tokenBreakdown(for: "daughter")
        #expect(breakdown.unique == ["daughter"])
        #expect(breakdown.shared == ["father"])
        #expect(Self.household.othersSharing("father", with: "daughter") == 3)

        // A roster where the surname is nobody else's makes the same token unique.
        let smaller = PersonRegistry(people: [
            Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
        ])
        #expect(smaller.tokenBreakdown(for: "daughter").shared.isEmpty)
        #expect(smaller.tokenBreakdown(for: "daughter").unique == ["daughter", "father"])
    }

    /// An axis value the registry can't pin to exactly one person resolves to nil rather than
    /// guessing: the veto reads this, and a wrong resolution refuses a correct folder.
    @Test func anUnresolvableAxisValueIsNil() {
        #expect(Self.household.person(forAxisValue: "Ravi") == nil)
        #expect(Self.household.person(forAxisValue: "Father and Mother") == nil)
    }

    // MARK: - Seeding from a profile with no people.json

    /// The seed carries the alias map, which matters even with no `people.json`: `mom` and
    /// `granny` become one person rather than two tokens in a bag.
    @Test func seedingFromAProfilePairsAliasesWithTheirPerson() {
        let profile = FolderProfile(profileId: "t", root: "~", folders: [:],
                                    personTokens: ["father", "mother", "mom", "granny"],
                                    personAliases: ["mom": "granny"])
        let seeded = PersonRegistry.seeded(from: profile)
        #expect(seeded.source == .profileAxis)
        #expect(Set(seeded.people.map(\.id)) == ["father", "mother", "granny"])
        #expect(seeded.detect(in: "Mom - passport.pdf") == ["granny"])
        #expect(seeded.person(forAxisValue: "Granny") == "granny")
        // No full names to work with, so a bare surname reaches nobody: the honest outcome, and
        // the reason `people.json` is worth writing.
        #expect(seeded.detect(in: "Maiden statement").isEmpty)
    }
}
