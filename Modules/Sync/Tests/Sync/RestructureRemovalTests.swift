import Testing
import Foundation
@testable import Sync

/// The removal step's manifest builder — one construction serving both origins (ROADMAP_V5 §5.5's
/// landing-scoped removal and §5.2's decided route for the folders that were already empty).
@Suite struct RestructureRemovalTests {

    private static let stamp = "2026-08-29T09:15:00"

    // MARK: The two origins

    @Test func theStandingRemovalTrashesEveryTickedPathInOrder() throws {
        let manifest = try #require(RestructureRemoval.manifest(
            paths: ["Travel/2019", "Finance/IN/SBI NRE/2013-2014"],
            family: ".", origin: .standing, profileId: "p", createdAt: Self.stamp))
        #expect(manifest.schemaVersion == RestructureManifest.currentSchema)
        #expect(manifest.kind == .deadWeight)
        #expect(manifest.manifestId == "removal-standing-\(Self.stamp)")
        #expect(manifest.actions.map(\.action) == [.removeEmptyDir, .removeEmptyDir])
        #expect(manifest.actions.map(\.src) == ["Travel/2019",
                                                "Finance/IN/SBI NRE/2013-2014"],
                "the ticked order is the run order — the engine re-probes each in turn")
        #expect(manifest.actions.allSatisfy { $0.dst == nil })
        #expect(manifest.actions.allSatisfy { $0.evidence?.isEmpty == false },
                "every operation carries its written justification — the 6 Aug log's rule")
    }

    /// The landing origin's id and sentences are what shipped, and this pins them: the builder
    /// replaced two hand-written copies of this construction, and a landing removal whose id
    /// changed shape would orphan the ledger records already on disk.
    @Test func theLandingRemovalKeepsItsLandingsIdentityInTheId() throws {
        let manifest = try #require(RestructureRemoval.manifest(
            paths: ["Finance/US/Income Tax/2013/State Tax"],
            family: "Finance/US/Income Tax",
            origin: .landing(manifestId: "reorg-42"), profileId: "p", createdAt: Self.stamp))
        #expect(manifest.manifestId == "removal-reorg-42-\(Self.stamp)")
        #expect(manifest.family == "Finance/US/Income Tax")
        #expect(manifest.note?.contains("reorg-42") == true)
        #expect(manifest.actions.first?.evidence?.contains("reorg-42") == true)
    }

    /// The origins must be distinguishable in the record itself — an id and a justification that
    /// read the same for both would leave the ledger unable to say which sheet trashed what.
    @Test func theTwoOriginsJustifyThemselvesDifferently() throws {
        let standing = try #require(RestructureRemoval.manifest(
            paths: ["Travel/2019"], family: "Travel", origin: .standing,
            profileId: "p", createdAt: Self.stamp))
        let landing = try #require(RestructureRemoval.manifest(
            paths: ["Travel/2019"], family: "Travel",
            origin: .landing(manifestId: "m1"), profileId: "p", createdAt: Self.stamp))
        #expect(standing.manifestId != landing.manifestId)
        #expect(standing.note != landing.note)
        #expect(standing.actions.first?.evidence != landing.actions.first?.evidence)
        #expect(standing.note?.contains("survey") == true,
                "the standing empties came from the survey, not from a landing")
        #expect(standing.actions.first?.evidence?.contains("m1") == false)
    }

    @Test func nothingTickedBuildsNoManifest() {
        #expect(RestructureRemoval.manifest(paths: [], family: ".", origin: .standing,
                                            profileId: "p", createdAt: Self.stamp) == nil,
                "a landing with no actions is a junk ledger record, not a no-op")
    }

    /// Every removal is undoable by the ledger's stored inverse, and for this manifest that means
    /// re-creating each folder — the involution the schema's `create-dir` ⇄ `remove-empty-dir`
    /// pairing exists for.
    @Test func theRemovalInverseRecreatesEveryFolder() throws {
        let manifest = try #require(RestructureRemoval.manifest(
            paths: ["A/2019", "B/2020"], family: ".", origin: .standing,
            profileId: "p", createdAt: Self.stamp))
        let inverse = manifest.inverse
        #expect(inverse.actions.map(\.action) == [.createDir, .createDir])
        #expect(inverse.actions.map(\.dst) == ["B/2020", "A/2019"],
                "reversed, so the deepest-listed folder comes back first")
        #expect(inverse.inverse == manifest)
    }

    // MARK: The family a scattered removal belongs to

    @Test func theCommonAncestorNamesTheContainingFolder() {
        #expect(RestructureRemoval.commonAncestor(of: ["Travel/2019"]) == "Travel",
                "one ticked folder belongs to its parent, not to itself")
        #expect(RestructureRemoval.commonAncestor(
            of: ["Finance/IN/A/2013", "Finance/IN/B/2019"]) == "Finance/IN")
        #expect(RestructureRemoval.commonAncestor(
            of: ["Travel/2019", "Travel/2020"]) == "Travel")
    }

    @Test func pathsSharingNothingLandOnTheProfilesOwnSpellingForTheRoot() {
        #expect(RestructureRemoval.commonAncestor(
            of: ["Travel/2019", "Finance/IN/SBI NRE/2013-2014"]) == ".",
                "the standing empties are wherever the tree left them")
        #expect(RestructureRemoval.commonAncestor(of: ["Archive"]) == ".",
                "a top-level empty has no containing folder but the root")
        #expect(RestructureRemoval.commonAncestor(of: []) == ".")
    }

    /// The sentence the PAIR SHEET prints above its operation list, before Apply. This is a
    /// different type from the apply outcome's summary, and pinning one left the other free — a
    /// review screen reading "1 folders carried whole" was what rendering caught.
    @Test func theLedgersOwnSentenceReadsInTheSingular() {
        let one = RestructureLedger(of: RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "Work",
            kind: .looseBesideContainer,
            actions: [.init(action: .moveDir, src: "Work/Badge", dst: "Work/MapR/Badge",
                            movesWholeFolder: true)]))
        #expect(one.summary.contains("1 folder carried whole"))
        #expect(!one.summary.contains("1 folders"))

        let two = RestructureLedger(of: RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "W", kind: .shape,
            actions: [.init(action: .moveDir, src: "W/a/x", dst: "W/b/x"),
                      .init(action: .moveDir, src: "W/a/y", dst: "W/b/y")]))
        #expect(two.summary.contains("2 folders carried whole"))
    }

    // MARK: A family that IS the tree

    /// Two spellings reach the root — `"."`, which is how a profile keys it, and `""`, which is
    /// what deleting the last component of a top-level folder leaves. Both have to read as words:
    /// the label lands in a ⌘Z menu item and in an exported plan's filename, and
    /// `"Reorganise "` with nothing after it was a real menu item for a top-level pair.
    @Test func aRootFamilyIsLabelledInWords() {
        #expect(RestructurePaths.familyLabel(".") == "the tree")
        #expect(RestructurePaths.familyLabel("") == "the tree")
        #expect(RestructurePaths.familyLabel("Finance/US/Income Tax") == "Income Tax")
        #expect(RestructurePaths.familyLabel("Travel") == "Travel")
    }

    /// A prefix match on the STRING would call `Finance/INbox` a child of `Finance/IN`. The rule
    /// compares path components, and this is the fixture that tells the two apart.
    @Test func theAncestorComparesComponentsNotCharacters() {
        #expect(RestructureRemoval.commonAncestor(
            of: ["Finance/IN/2019", "Finance/INbox/2019"]) == "Finance")
    }
}
