import Foundation
import Testing
@testable import Sync

/// §5.5 steps 6 and 7 as the pure rules they are: the carry-over, the jurisdiction source, and
/// the key replay. The disk-facing sequencing is the apply engine's tests; nothing here needs one.
@Suite struct RestructureRederiveTests {

    private static func entry(_ path: String, naming: String? = nil,
                              acceptsNewFiles: Bool? = nil, noIntakeReason: String? = nil,
                              jurisdiction: String? = nil) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: nil, naming: naming, anchors: [],
                           acceptsNewFiles: acceptsNewFiles, noIntakeReason: noIntakeReason,
                           fileCount: 0, subfolderCount: 0,
                           axes: jurisdiction.map { ["jurisdiction": $0] } ?? [:])
    }

    private static func profile(id: String, _ entries: [FolderProfileEntry]) -> FolderProfile {
        FolderProfile(profileId: id, root: "~/Documents",
                      folders: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) }),
                      personTokens: [])
    }

    private static let manifest = RestructureManifest(
        profileId: "p", manifestId: "m1", createdAt: "t", family: "Tax", kind: .shape,
        actions: [
            .init(action: .renameDir, src: "Tax/Federal", dst: "Tax/Forms", filesCarried: 2),
            .init(action: .moveFile, src: "Tax/State/ca.pdf", dst: "Tax/Forms/ca.pdf"),
            .init(action: .moveFile, src: "Tax/State/dupe.pdf", dst: "Tax/Forms/dupe.pdf",
                  collidedInto: "Tax/Forms/dupe 2.pdf"),
        ])

    // MARK: - Carry-over (step 6)

    /// The three judgement fields ride from the old entry to the new — for a path that survived
    /// in place AND for one that moved through the manifest's rename, which is the case the 6 Aug
    /// proof names: the refusal must follow the folder, not the spelling.
    @Test func judgementsFollowBothSurvivingAndRenamedPaths() {
        let old = Self.profile(id: "old", [
            Self.entry("Tax/Outbound", acceptsNewFiles: false, noIntakeReason: "outbound-pack"),
            Self.entry("Tax/Federal", naming: "ordinal-month",
                       acceptsNewFiles: false, noIntakeReason: "todo-inbox"),
        ])
        // The walk found the tree as the apply left it: Federal is now Forms.
        let fresh = Self.profile(id: "new", [
            Self.entry("Tax/Outbound"),
            Self.entry("Tax/Forms"),
            Self.entry("Tax/Refund"),
        ])
        let carried = RestructureRederive.carryOver(from: old, into: fresh,
                                                    through: Self.manifest)
        #expect(carried.folders["Tax/Outbound"]?.noIntakeReason == "outbound-pack")
        #expect(carried.folders["Tax/Outbound"]?.acceptsNewFiles == false)
        #expect(carried.folders["Tax/Forms"]?.noIntakeReason == "todo-inbox",
                "the refusal follows the folder through its rename")
        #expect(carried.folders["Tax/Forms"]?.naming == "ordinal-month")
        // A folder the old profile never judged keeps whatever the walk said — silence does not
        // travel.
        #expect(carried.folders["Tax/Refund"]?.acceptsNewFiles == nil)
    }

    /// An old silence never erases what the walk found: the carry-over preserves judgements a
    /// walk cannot see, it does not overwrite what it did see.
    @Test func anOldNilDoesNotEraseTheWalksOwnFinding() {
        let old = Self.profile(id: "old", [Self.entry("Tax/TODO")])
        let fresh = Self.profile(id: "new", [
            Self.entry("Tax/TODO", acceptsNewFiles: false, noIntakeReason: "todo-inbox"),
        ])
        let carried = RestructureRederive.carryOver(
            from: old, into: fresh,
            through: RestructureManifest(profileId: "p", manifestId: "m", createdAt: "t",
                                         family: "Tax", kind: .shape, actions: []))
        #expect(carried.folders["Tax/TODO"]?.acceptsNewFiles == false)
        #expect(carried.folders["Tax/TODO"]?.noIntakeReason == "todo-inbox")
    }

    /// The jurisdiction set comes from the ENTRIES, never the header: the header says US, IN
    /// while the entries carry Singapore on 10 folders, and taking the header loses the tree an
    /// axis value (§5.5's decisions block, verbatim).
    @Test func jurisdictionsAreTheEntriesDistinctValues() {
        let profile = Self.profile(id: "p", [
            Self.entry("Finance/US", jurisdiction: "US"),
            Self.entry("Finance/IN", jurisdiction: "IN"),
            Self.entry("Work/Singapore", jurisdiction: "Singapore"),
            Self.entry("Work/Singapore/2020", jurisdiction: "Singapore"),
            Self.entry("Home"),
        ])
        #expect(RestructureRederive.entryJurisdictions(of: profile)
                == ["US", "IN", "Singapore"])
    }

    // MARK: - Key replay (step 7)

    /// A rename re-prefixes every key beneath it, a move re-keys one document — to where the file
    /// actually IS, which is the collision name when the landing had to pick one — and no stamp
    /// moves, because a file that only moved was not re-read.
    @Test func theCorpusFollowsTheManifestWithoutBeingReRead() {
        let document = FilingCorpusDocument(size: 10, modified: 1_700_000_000,
                                            anchors: ["w2"], idHashes: [])
        let corpus = FilingCorpus(profileId: "p", salt: "s", documents: [
            "Tax/Federal/w2.pdf": document,
            "Tax/Federal/Sub/deep.pdf": document,
            "Tax/State/ca.pdf": document,
            "Tax/State/dupe.pdf": document,
            "Tax/StateOther/other.pdf": document,
        ], surveyedAt: Date(timeIntervalSince1970: 1_755_000_000))

        let rekeyed = RestructureRederive.rekeyedCorpus(corpus, through: Self.manifest)

        #expect(Set(rekeyed.documents.keys) == [
            "Tax/Forms/w2.pdf",
            "Tax/Forms/Sub/deep.pdf",
            "Tax/Forms/ca.pdf",
            "Tax/Forms/dupe 2.pdf",
            // The sibling trap: `Tax/StateOther` shares `Tax/State`'s characters and is another
            // folder — untouched.
            "Tax/StateOther/other.pdf",
        ])
        #expect(rekeyed.documents["Tax/Forms/w2.pdf"] == document,
                "the document's stamp and tokens are untouched — moved, not re-read")
        #expect(rekeyed.surveyedAt == corpus.surveyedAt)
        #expect(rekeyed.salt == corpus.salt)
    }

    /// The moved claim WINS a destination-key collision, deterministically: a stale corpus key
    /// can already sit at a move's destination (its file was deleted since the last scan, so
    /// the apply saw no collision and recorded none), and the replay used to leave the winner
    /// to dictionary iteration order — `carryOver` and `RestructureStore.rekeyedMap` both
    /// decide this exact race explicitly, and the corpus was the one sibling that did not.
    @Test func aMovedDocumentWinsOverAStaleKeyAtItsDestination() {
        let moved = FilingCorpusDocument(size: 10, modified: 1_700_000_000,
                                         anchors: ["moved"], idHashes: [])
        let stale = FilingCorpusDocument(size: 99, modified: 1_600_000_000,
                                         anchors: ["stale"], idHashes: [])
        let corpus = FilingCorpus(profileId: "p", salt: "s", documents: [
            "Tax/Old/w2.pdf": moved,
            "Tax/Forms/w2.pdf": stale,   // the file is gone; the key lingers until re-survey
        ], surveyedAt: Date(timeIntervalSince1970: 1_755_000_000))
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "Tax", kind: .shape,
            actions: [.init(action: .moveFile, src: "Tax/Old/w2.pdf",
                            dst: "Tax/Forms/w2.pdf", evidence: "e")])

        let rekeyed = RestructureRederive.rekeyedCorpus(corpus, through: manifest)

        #expect(rekeyed.documents.count == 1)
        #expect(rekeyed.documents["Tax/Forms/w2.pdf"]?.anchors == ["moved"],
                "the moved document's claim wins — whatever the iteration order")
    }

    /// `mapped` applies renames sequentially, so a later rename legitimately acts on the product
    /// of an earlier one — §5.4's vacate-before-fill spelled as key movement.
    @Test func sequentialRenamesComposeInManifestOrder() {
        let renames = [(from: "Tax/Forms", to: "Tax/Tax Records"),
                       (from: "Tax/Federal", to: "Tax/Forms")]
        #expect(RestructureRederive.mapped("Tax/Forms/a.pdf", through: renames)
                == "Tax/Tax Records/a.pdf")
        #expect(RestructureRederive.mapped("Tax/Federal/b.pdf", through: renames)
                == "Tax/Forms/b.pdf")
    }

    // MARK: - What a refresh reports

    /// **The success sentence names the delta, not only the total.** A total alone cannot tell
    /// "it ran" from "it ran and the tree had not moved" — and on a settled tree the second is
    /// the ordinary outcome, which is exactly the case a reader has to be able to distinguish
    /// from a button that did nothing.
    @Test func theRefreshSentenceSaysHowMuchTheTreeMoved() {
        #expect(SurveyRefreshOutcome.updated(folders: 5021, previousFolders: 3013).sentence
            == "Survey updated — 5021 folders, 2008 more than before.")
        #expect(SurveyRefreshOutcome.updated(folders: 3013, previousFolders: 5021).sentence
            == "Survey updated — 3013 folders, 2008 fewer than before.")
        #expect(SurveyRefreshOutcome.updated(folders: 3013, previousFolders: 3013).sentence
            == "Survey updated — 3013 folders, unchanged since the last survey.")
        // The singular, because a one-folder tree is a real (if odd) thing and "1 folders" is the
        // tell that nobody read the sentence back.
        #expect(SurveyRefreshOutcome.updated(folders: 1, previousFolders: 0).sentence
            == "Survey updated — 1 folder, 1 more than before.")
    }

    /// A refusal is carried verbatim and is the only case with a `refusal` — the two call sites
    /// branch on exactly that, one putting it on a card and the other in the banner.
    @Test func aRefusalIsTheOnlyOutcomeThatReadsAsOne() {
        let refused = SurveyRefreshOutcome.refused("No folder survey is loaded.")
        #expect(refused.refusal == "No folder survey is loaded.")
        #expect(refused.sentence == "No folder survey is loaded.")
        #expect(SurveyRefreshOutcome.updated(folders: 2, previousFolders: 1).refusal == nil)
    }
}
