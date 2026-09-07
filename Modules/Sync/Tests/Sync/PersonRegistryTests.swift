import Foundation
import Testing
@testable import Sync

/// The household matcher, pinned against **the real roster**, because the hard cases are not
/// hypothetical — they are the specific way these six names overlap.
///
/// `father` is one person's first name and three others' surname; `elder` is Dad's first name,
/// Mom's surname and Father's surname. Every test below fails under the obvious implementation
/// (intersect the file's tokens with a set of known person words), which is what the engine did
/// before this type existed.
@Suite struct PersonRegistryTests {

    /// Father's actual household — the fixture is the roster, so a rule that only works on
    /// invented names cannot pass here.
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

    /// **The case that motivates phrase matching.** "Daughter Father" is the daughter's full name,
    /// and `father` is also her father's given name — so a token intersection reports both people
    /// and the document becomes unattributable. The phrase consumes the surname: Daughter alone.
    @Test func aFullNameConsumesItsSurname() {
        #expect(Self.household.detect(in: "Daughter Father - OCI Card") == ["daughter"])
        #expect(Self.household.detect(in: "Son Father Report Card 2026") == ["son"])
        #expect(Self.household.detect(in: "Mother Father PAN") == ["mother"])
    }

    /// The mirror: his own full name is not his daughter's. Without this, "longest wins" could be
    /// satisfied by any rule that simply preferred whichever person sorted first.
    @Test func hisOwnFullNameIsHisAlone() {
        #expect(Self.household.detect(in: "Father Elder - Passport.pdf") == ["father"])
        #expect(Self.household.detect(in: "Elder Forebear - OCI") == ["elder"])
        #expect(Self.household.detect(in: "Granny Elder - Visa") == ["granny"])
    }

    /// A shared token standing alone reads as the person whose *given* name it is. `elder` on its
    /// own is Dad — not Mom (whose surname it is) and not Father (whose surname it is).
    @Test func aSharedTokenAloneIsTheGivenName() {
        #expect(Self.household.detect(in: "Elder - Aadhaar.pdf") == ["elder"])
        #expect(Self.household.detect(in: "Father W2 2025") == ["father"])
    }

    /// A token unique to one person attributes them from anywhere in the string — this is the
    /// signal that survives when a document prints a surname with no given name.
    @Test func aUniqueTokenAttributesFromAnywhere() {
        #expect(Self.household.detect(in: "Statement for Maiden, S.") == ["mother"])
        #expect(Self.household.detect(in: "FOREBEAR pension order") == ["elder"])
    }

    /// **Mom is Granny.** The whole reason the alias map had to stop being discarded: a file the
    /// user named `Mom - passport.pdf` must resolve to the same person as a folder whose axis says
    /// `Granny`, or the cross-person veto fires against the correct folder.
    @Test func aRelationshipAliasIsTheSamePerson() {
        #expect(Self.household.detect(in: "Mom - passport.pdf") == ["granny"])
        #expect(Self.household.detect(in: "Dad medical records") == ["elder"])
        #expect(Self.household.person(forAxisValue: "Granny") == "granny")
        #expect(Self.household.person(forAxisValue: "Mom") == "granny")
    }

    /// **A longer name form wins over a shorter one embedded inside it**, which is a different rule
    /// from consuming the span and needs its own case to reach.
    ///
    /// The roster grows — a brother-in-law, a brother — and the moment a two-word name sits inside
    /// somebody's three-word name, order decides the answer. Mother's full form is *Mother Inlaw
    /// Maiden*; add a *Inlaw Maiden* and matching shortest-first attributes her PAN card to him as
    /// well as to her. Only the longest match may claim the span.
    @Test func aLongerNameFormWinsOverAShorterOneInsideIt() {
        let withInLaw = PersonRegistry(people: [
            Person(id: "mother", displayName: "Mother",
                   fullNames: ["Mother Inlaw Maiden", "Mother Maiden"]),
            Person(id: "inlaw", displayName: "Inlaw", fullNames: ["Inlaw Maiden"]),
        ])
        #expect(withInLaw.detect(in: "Mother Inlaw Maiden - PAN card") == ["mother"])
        // And the shorter name still matches on its own — the rule is precedence, not suppression.
        #expect(withInLaw.detect(in: "Inlaw Maiden - lease") == ["inlaw"])
    }

    /// A document naming two people names two people — the veto is about contradiction, and a
    /// joint document must not be forced onto one of them.
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

    /// Separators are not significant — a document prints names with commas, underscores and
    /// hyphens, and the phrase has to survive all of them.
    @Test func phrasesMatchAcrossSeparators() {
        #expect(Self.household.detect(in: "daughter_father-oci.pdf") == ["daughter"])
        #expect(Self.household.detect(in: "SON FATHER") == ["son"])
    }

    // MARK: - The derived split, and what Settings shows

    /// **Strong vs shared is computed, never declared.** Adding a seventh person must be able to
    /// demote a token, so the split is derived from the roster on every build.
    @Test func theStrongWeakSplitIsDerivedFromTheRoster() {
        let breakdown = Self.household.tokenBreakdown(for: "daughter")
        #expect(breakdown.unique == ["daughter"])
        #expect(breakdown.shared == ["father"])
        #expect(Self.household.othersSharing("father", with: "daughter") == 3)

        // A roster where the surname is nobody else's makes the same token unique — the split
        // followed the roster rather than a hard-coded list.
        let smaller = PersonRegistry(people: [
            Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
        ])
        #expect(smaller.tokenBreakdown(for: "daughter").shared.isEmpty)
        #expect(smaller.tokenBreakdown(for: "daughter").unique == ["daughter", "father"])
    }

    /// An axis value the registry cannot pin to exactly one person resolves to nil rather than
    /// guessing — the veto reads this, and a wrong resolution there refuses a correct folder.
    @Test func anUnresolvableAxisValueIsNil() {
        #expect(Self.household.person(forAxisValue: "Ravi") == nil)
        #expect(Self.household.person(forAxisValue: "Father and Mother") == nil)
    }

    // MARK: - Seeding from a profile with no people.json

    /// The seed carries the alias map, which is the fix that matters even with no `people.json`:
    /// `mom` and `granny` become one person rather than two tokens in a bag.
    @Test func seedingFromAProfilePairsAliasesWithTheirPerson() {
        let profile = FolderProfile(profileId: "t", root: "~", folders: [:],
                                    personTokens: ["father", "mother", "mom", "granny"],
                                    personAliases: ["mom": "granny"])
        let seeded = PersonRegistry.seeded(from: profile)
        #expect(seeded.source == .profileAxis)
        #expect(Set(seeded.people.map(\.id)) == ["father", "mother", "granny"])
        #expect(seeded.detect(in: "Mom - passport.pdf") == ["granny"])
        #expect(seeded.person(forAxisValue: "Granny") == "granny")
        // No full names to work with, so a bare surname reaches nobody — the honest outcome, and
        // the reason `people.json` is worth writing.
        #expect(seeded.detect(in: "Maiden statement").isEmpty)
    }
}
