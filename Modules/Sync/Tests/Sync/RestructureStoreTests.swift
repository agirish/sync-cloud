import Testing
import Foundation
@testable import Sync

/// The `kind × subject` identity every Restructure section keys on (ROADMAP_V5 §5.0).
///
/// The kind went into `StructureFinding.id` before the second detector landed, because
/// `RestructureLens` renders one `ForEach(findings)` and the second kind to fire on a family
/// would have collided with the first. The subject — not the family — is the other half, because
/// one family can hold two findings of the *same* kind about different children.
@Suite struct RestructureIdentityTests {

    @Test func theIdCarriesTheKindSoTwoKindsOnOneFamilyDoNotCollide() {
        let shape = StructureFinding(kind: .shape, family: "Finance/US/Income Tax", schemes: [])
        let series = StructureFinding(kind: .backlog, family: "Finance/US/Income Tax",
                                      subject: "Finance/US/Income Tax/2025", schemes: [])
        #expect(shape.id != series.id)
        #expect(shape.id == "shape|Finance/US/Income Tax")
    }

    @Test func theSubjectSeparatesTwoFindingsOfOneKindInOneFamily() {
        // Echo-name can fire twice in one family, on two different sibling pairs — the case that
        // made kind × family insufficient as an identity.
        let first = StructureFinding(kind: .echoName, family: "Forms",
                                     subject: "Forms/Form W2", schemes: [])
        let second = StructureFinding(kind: .echoName, family: "Forms",
                                      subject: "Forms/1099 INT", schemes: [])
        #expect(first.id != second.id)
    }

    @Test func theSubjectDefaultsToTheFamilyWhichIsWhatShapeMeans() {
        let finding = StructureFinding(family: "Finance/US/Income Tax", schemes: [])
        #expect(finding.kind == .shape)
        #expect(finding.subject == "Finance/US/Income Tax")
    }

    /// Raw values are a file format — `restructure.json` serialises them — so they are pinned
    /// here the way `GlassLevel`'s are: append-only, never renamed, never reused. A failure here
    /// is a failure to keep that promise, not a test to update.
    /// One spelling of the composite identity: a store key joined back to rendered findings must
    /// produce exactly ``StructureFinding/id``, or the two drift apart in silence.
    @Test func aKeysFindingIdMatchesTheFindingsOwnId() {
        let finding = StructureFinding(kind: .echoName, family: "Home",
                                       subject: "Home/ATT Bill",
                                       detail: .echoName(counterpart: "Home/ATT",
                                                         relation: .sibling))
        #expect(RestructureKey(finding).findingId == finding.id)
    }

    @Test func theRawValuesAreAFileFormatAndStayPinned() {
        let pinned: [FindingKind: String] = [
            .shape: "shape", .backlog: "backlog", .shadowAxis: "shadowAxis",
            .echoName: "echoName", .mirroredInbox: "mirroredInbox", .deadWeight: "deadWeight",
            .looseAboveSeries: "looseAboveSeries", .looseBesideContainer: "looseBesideContainer",
            .duplicatedTaxonomy: "duplicatedTaxonomy", .ask: "ask",
        ]
        #expect(FindingKind.allCases.count == pinned.count)
        for (kind, raw) in pinned { #expect(kind.rawValue == raw) }
    }

    /// The rail badge counts only plan-bearing kinds (§5.1): `ask` is the stated exclusion,
    /// `deadWeight` renders as the crowding strip rather than as cards, and `looseAboveSeries`
    /// hands its per-file fix to To File rather than growing an Apply.
    @Test func onlyThePlanBearingKindsCountTowardTheBadge() {
        let planless: Set<FindingKind> = [.ask, .deadWeight, .looseAboveSeries]
        for kind in FindingKind.allCases {
            #expect(kind.carriesPlan == !planless.contains(kind),
                    "\(kind.rawValue) has the wrong badge behaviour")
        }
    }
}

/// `restructure.json` — the one app-owned file for everything Restructure remembers.
///
/// Each proof here is §5.0's, verbatim: a round-trip per section, a suppression that outlives the
/// profile that was active when it was made, and a manifest rename that re-keys every section that
/// named the old path while leaving a sibling that merely shares a name prefix alone.
@MainActor
@Suite final class RestructureStoreTests {

    // A class suite so `deinit` can sweep what each test created — the struct version leaked
    // one fixture directory per test per run into the temp dir, standing debris on the
    // self-hosted runner. Swift Testing instantiates one suite per test, so the sweep runs
    // right after each test finishes.
    private var scratch: [URL] = []
    deinit { for dir in scratch { try? FileManager.default.removeItem(at: dir) } }

    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restructure-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        scratch.append(dir)
        return dir
    }

    private func fileBytes(_ dir: URL) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("p/restructure.json"))
    }

    // MARK: Round trips

    @Test func aSuppressionRoundTripsThroughTheFile() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .shape, path: "Finance/US/Income Tax")
        RestructureStore(directory: dir, profileId: "p").suppress(key)

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.isSuppressed(key))
        #expect(!reread.isSuppressed(RestructureKey(kind: .backlog,
                                                    path: "Finance/US/Income Tax")))
    }

    @Test func anAnswerRoundTripsThroughTheFile() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .ask, path: "Health/Kaiser - PG&E")
        RestructureStore(directory: dir, profileId: "p").recordAnswer("coverage", for: key)

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.answer(for: key) == "coverage")
    }

    @Test func removingAnAnswerRemovesItFromTheFileToo() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .ask, path: "Health/Kaiser - PG&E")
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordAnswer("coverage", for: key)
        store.removeAnswer(for: key)

        #expect(RestructureStore(directory: dir, profileId: "p").answer(for: key) == nil)
    }

    /// §5.0: "a suppressed finding stays suppressed after the profile is swapped for a derived
    /// one." The store's keys are paths, not profile ids — so a finding regenerated from a
    /// *different* profile object still matches, as long as it is about the same place.
    @Test func aSuppressionSurvivesTheProfileBeingReplacedUnderneathIt() throws {
        let dir = try makeDirectory()
        let fromHandBuilt = StructureFinding(kind: .shape, family: "Finance/US/Income Tax",
                                             schemes: [])
        RestructureStore(directory: dir, profileId: "p").suppress(RestructureKey(fromHandBuilt))

        // The same family, found again in a freshly derived profile: a different FolderProfile,
        // a different StructureFinding instance, the same identity.
        let fromDerived = StructureFinding(kind: .shape, family: "Finance/US/Income Tax",
                                           schemes: [StructureFinding.Scheme(
                                               vocabulary: ["forms"], members: ["2016", "2017"])])
        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.isSuppressed(RestructureKey(fromDerived)))
    }

    // MARK: Replay

    @Test func aRenameRekeysTheKeyItNamesAndEverySectionCarriesIt() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .echoName, path: "Home/ATT Bill"))
        store.recordAnswer("keep", for: RestructureKey(kind: .ask, path: "Home/ATT Bill"))

        store.rekey(renames: [(from: "Home/ATT Bill", to: "Home/ATT")])

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.isSuppressed(RestructureKey(kind: .echoName, path: "Home/ATT")))
        #expect(!reread.isSuppressed(RestructureKey(kind: .echoName, path: "Home/ATT Bill")))
        #expect(reread.answer(for: RestructureKey(kind: .ask, path: "Home/ATT")) == "keep")
    }

    @Test func aRenameRekeysDescendantsButNotASiblingSharingANamePrefix() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .shape, path: "Finance/A/B/2016"))
        // The sibling trap: `A/BB` starts with the characters of `A/B` but is another folder.
        store.suppress(RestructureKey(kind: .shape, path: "Finance/A/BB"))

        store.rekey(renames: [(from: "Finance/A/B", to: "Finance/A/C")])

        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "Finance/A/C/2016")))
        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "Finance/A/BB")))
        #expect(!store.isSuppressed(RestructureKey(kind: .shape, path: "Finance/A/B/2016")))
    }

    @Test func renamesApplyInManifestOrderSoALaterOneSeesTheEarlierOnesProduct() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .shape, path: "Tax/Forms"))

        // §5.4's vacate-before-fill: Forms is vacated to Tax Records, then Federal fills Forms.
        // The suppression about the ORIGINAL Forms must follow the vacating rename and must not
        // be picked up by the fill.
        store.rekey(renames: [(from: "Tax/Forms", to: "Tax/Tax Records"),
                              (from: "Tax/Federal", to: "Tax/Forms")])

        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "Tax/Tax Records")))
        #expect(!store.isSuppressed(RestructureKey(kind: .shape, path: "Tax/Forms")))
    }

    // MARK: The file on disk

    @Test func anAbsentFileIsAFreshStoreAndTheFirstWriteCreatesIt() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(!store.isUnreadable)
        #expect(store.suppressed.isEmpty)

        store.suppress(RestructureKey(kind: .shape, path: "A"))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("p/restructure.json").path))
    }

    /// Absent, unreadable and newer-than-me are three different claims, and only absent is
    /// writable. A file that did not decode must keep its bytes through any mutation — a
    /// whole-file save of the empty fallback state would replace the real file with nothing.
    @Test func anUnreadableFileIsNeverWrittenOver() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/restructure.json")
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: url)

        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isUnreadable)
        store.suppress(RestructureKey(kind: .shape, path: "A"))

        #expect(try fileBytes(dir) == garbage)
        // The change still holds in memory for the session.
        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "A")))
    }

    @Test func aNewerSchemaIsReadButRefusedForWriting() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/restructure.json")
        let newer = """
            {
              "schemaVersion": 99,
              "suppressed": [ { "kind": "shape", "path": "Finance/US/Income Tax" } ],
              "sectionsANewerBuildWrote": { "whatever": true }
            }
            """
        try Data(newer.utf8).write(to: url)

        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "Finance/US/Income Tax")))
        #expect(store.isUnreadable)

        let before = try fileBytes(dir)
        store.suppress(RestructureKey(kind: .backlog, path: "A"))
        #expect(try fileBytes(dir) == before)
    }

    /// A section this build does not model — hand-added, or written by a future schema this build
    /// happens to half-understand — must survive a save untouched. (`drafts` was this test's
    /// example while §5.4 was unbuilt; it is modelled now, so the foreign section here is one no
    /// planned schema claims.)
    @Test func sectionsThisBuildDoesNotModelSurviveASave() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/restructure.json")
        let withForeign = """
            {
              "schemaVersion": 1,
              "annotations": [ { "path": "Finance/US/Income Tax", "text": "revisit" } ],
              "_note": "hand-written, and load-bearing for this test"
            }
            """
        try Data(withForeign.utf8).write(to: url)

        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .shape, path: "A"))

        let object = try #require(try JSONSerialization.jsonObject(
            with: fileBytes(dir)) as? [String: Any])
        #expect(object["annotations"] != nil)
        #expect(object["_note"] as? String == "hand-written, and load-bearing for this test")
        #expect((object["suppressed"] as? [[String: Any]])?.count == 1)
    }

    /// A `drafts` section in a shape this build cannot decode is an UNREADABLE file, not an empty
    /// section: every save is whole-file, so writing would flatten what could not be read. Refusal
    /// is the same protection the syntax-error case gets.
    @Test func anUndecodableDraftsSectionRefusesWritesRatherThanFlattening() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/restructure.json")
        try Data("""
            {
              "schemaVersion": 1,
              "drafts": [ { "kind": "shape", "path": "F", "mapping": [] } ]
            }
            """.utf8).write(to: url)
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isUnreadable)
    }

    // MARK: Drafts (§5.4)

    private static func draftManifest(family: String = "Finance/US/Income Tax")
        -> RestructureManifest {
        RestructureManifest(
            profileId: "p", manifestId: "m1", createdAt: "2026-08-28T10:00:00",
            family: family, kind: .shape,
            mapping: [.init(source: "Federal Tax", target: "Forms")],
            actions: [.init(action: .renameDir, src: "\(family)/2013/Federal Tax",
                            dst: "\(family)/2013/Forms", filesCarried: 3)])
    }

    /// §5.7's *Planned, not applied*: the draft survives the sheet closing and the app quitting —
    /// mapping rows, actions and export mark all intact.
    @Test func aDraftRoundTripsThroughTheFileWhole() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .shape, path: "Finance/US/Income Tax")
        let record = RestructureStore.DraftRecord(
            manifest: Self.draftManifest(), savedAt: "2026-08-28T10:00:00",
            exportedTo: "restructure-2026-08-28-Finance-US-Income Tax.json",
            // The picker vocabulary, UNUSED names included — what lets a reopened draft offer
            // the same choices instead of only the targets its rows happen to use.
            vocabulary: ["Forms", "Payments", "Correspondence"])
        RestructureStore(directory: dir, profileId: "p").saveDraft(record, for: key)

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.draft(for: key) == record)
        #expect(reread.draft(for: key)?.vocabulary == ["Forms", "Payments", "Correspondence"])
        reread.removeDraft(for: key)
        #expect(RestructureStore(directory: dir, profileId: "p").draft(for: key) == nil)
    }

    /// A rename replays onto the draft's KEY — the section survives an Apply of another plan —
    /// while the manifest inside keeps the paths it was derived against: Apply re-validates a
    /// draft against the tree as it stands, and a stale path there is a card sentence, not a
    /// silent rewrite of a plan the user reviewed.
    @Test func aRenameRekeysADraftsKeyButNotItsManifest() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        let manifest = Self.draftManifest(family: "Home/ATT Bill")
        store.saveDraft(.init(manifest: manifest, savedAt: "t"),
                        for: RestructureKey(kind: .echoName, path: "Home/ATT Bill"))

        store.rekey(renames: [(from: "Home/ATT Bill", to: "Home/ATT")])

        let reread = RestructureStore(directory: dir, profileId: "p")
        let moved = try #require(reread.draft(for: RestructureKey(kind: .echoName,
                                                                  path: "Home/ATT")))
        #expect(reread.draft(for: RestructureKey(kind: .echoName, path: "Home/ATT Bill")) == nil)
        #expect(moved.manifest == manifest, "the reviewed plan's contents are not rewritten")
    }

    /// `Export plan…` writes the manifest beside the profile, named for its date and family with
    /// the path separators flattened — reviewable in a text editor with nothing at risk — and it
    /// writes even when the store itself is refusing: the refusal protects `restructure.json`,
    /// and this is a new file.
    @Test func exportWritesTheManifestBesideTheProfileEvenWhenTheStoreIsUnreadable() throws {
        let dir = try makeDirectory()
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("p/restructure.json"))
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isUnreadable)

        let name = try store.exportPlan(Self.draftManifest())

        #expect(name == "restructure-2026-08-28-Finance-US-Income Tax.json")
        let data = try Data(contentsOf: dir.appendingPathComponent("p/\(name)"))
        let decoded = try JSONDecoder().decode(RestructureManifest.self, from: data)
        #expect(decoded == Self.draftManifest())
        // The wire file is the log's vocabulary, and it carries the mapping it was derived from.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("rename-dir") && json.contains("\"mapping\""))
    }

    @Test func anUnchangedMutationDoesNotTouchTheDisk() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .shape, path: "A")
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(key)
        let stamp = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("p/restructure.json").path)[.modificationDate]

        store.suppress(key)
        store.rekey(renames: [(from: "Elsewhere", to: "Nowhere")])

        let after = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("p/restructure.json").path)[.modificationDate]
        #expect(stamp as? Date == after as? Date)
    }
}

/// The store under imperfect input and colliding history — every one of these used to trap
/// (`Dictionary(uniqueKeysWithValues:)`) or silently lie (a swallowed ledger write).
@MainActor
@Suite final class RestructureStoreRobustnessTests {

    // Class + deinit for the same reason as `RestructureStoreTests`: each test's fixture
    // directory is swept the moment its suite instance goes away.
    private var scratch: [URL] = []
    deinit { for dir in scratch { try? FileManager.default.removeItem(at: dir) } }

    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restructure-robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        scratch.append(dir)
        return dir
    }

    private func manifest(id: String, family: String = "F") -> RestructureManifest {
        RestructureManifest(profileId: "p", manifestId: id, createdAt: "t", family: family,
                            kind: .shape, actions: [
                                .init(action: .renameDir, src: "\(family)/a", dst: "\(family)/b"),
                            ])
    }

    /// A rename whose destination equals a key recorded before that folder was hand-deleted is
    /// history, not a programming error: the rekeyed claim wins and nothing traps at the tail
    /// of a successful apply.
    @Test func rekeyingTwoAnswersOntoOneKeySurvivesAndTheRekeyedClaimWins() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordAnswer("stale", for: RestructureKey(kind: .ask, path: "Tax/Tax Records"))
        store.recordAnswer("fresh", for: RestructureKey(kind: .ask, path: "Tax/Forms"))

        store.rekey(renames: [(from: "Tax/Forms", to: "Tax/Tax Records")])

        #expect(store.answer(for: RestructureKey(kind: .ask, path: "Tax/Tax Records")) == "fresh")
    }

    /// A hand-edited file with a duplicated row loads (last row wins, JSON's own object rule) —
    /// the whole philosophy here is refusal over trap, and `load` used to crash the store's
    /// construction on exactly this input.
    @Test func aDuplicatedAnswerRowLoadsInsteadOfTrapping() throws {
        let dir = try makeDirectory()
        let json = """
        {"schemaVersion": 1, "answers": [
          {"kind": "ask", "path": "A", "choice": "first"},
          {"kind": "ask", "path": "A", "choice": "second"}
        ]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("p/restructure.json"))
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(!store.isUnreadable)
        #expect(store.answer(for: RestructureKey(kind: .ask, path: "A")) == "second")
    }

    /// §5.5's licence to move files: `recordApplied` reports whether the record REACHED the
    /// disk, and the engine refuses the whole landing on false — tested here at the seam, with
    /// an unwritable directory standing in for a full disk.
    @Test func aFailedLedgerWriteIsReportedToTheCaller() throws {
        let dir = try makeDirectory()
        let folder = dir.appendingPathComponent("p")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: folder.path) }
        let store = RestructureStore(directory: dir, profileId: "p")
        let landed = store.recordApplied(RestructureStore.AppliedRecord(
            manifest: manifest(id: "m1"), inverse: manifest(id: "m1").inverse,
            at: "t", created: 0, skipped: 0, appliedUnderProfileId: "p"))
        #expect(!landed, "an unwritable ledger must be reported, not shrugged into memory")
    }

    // MARK: The one undoable landing (§5.5's chain, in its single spelling)

    private func record(id: String, appliedUnder: String? = "prof-a",
                        produced: String? = "prof-b", summary: String? = "did things",
                        undoneAt: String? = nil) -> RestructureStore.AppliedRecord {
        RestructureStore.AppliedRecord(
            manifest: manifest(id: id), inverse: manifest(id: id).inverse, at: "t",
            created: 0, skipped: 0, appliedUnderProfileId: appliedUnder,
            producedProfileId: produced, summary: summary, undoneAt: undoneAt)
    }

    @Test func theNewestNotUndoneReorganisationIsTheOneOffered() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", produced: "prof-b"))
        store.recordApplied(record(id: "m2", appliedUnder: "prof-b", produced: "prof-c"))
        #expect(store.undoableReorganisation(currentProfileId: "prof-c")?
            .manifest.manifestId == "m2")
        #expect(store.undoableReorganisation(currentProfileId: "prof-b") == nil,
                "the newest landing's produced directory is not active — nothing is offered")
    }

    /// A scaffold record never carries `appliedUnderProfileId`; it is not a link in the chain
    /// and must neither be offered nor block the reorganisation beneath it.
    @Test func aScaffoldRecordIsInvisibleToTheChain() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", produced: "prof-b"))
        store.recordApplied(record(id: "scaffold-1", appliedUnder: nil, produced: nil,
                                   summary: nil))
        #expect(store.undoableReorganisation(currentProfileId: "prof-b")?
            .manifest.manifestId == "m1")
    }

    /// A landing whose re-derive failed never re-pointed the survey (`producedProfileId` nil,
    /// summary set): it anchors on the directory it was applied under, and is still undoable —
    /// the first gate compared produced ids and stranded exactly these records forever.
    @Test func aLandingWhoseRederiveFailedIsStillOffered() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", appliedUnder: "prof-a", produced: nil))
        #expect(store.undoableReorganisation(currentProfileId: "prof-a")?
            .manifest.manifestId == "m1")
    }

    /// A record without a summary never finalised — the app quit mid-apply, so its stored
    /// inverse may not match the disk. Never offered.
    @Test func aNeverFinalisedLandingIsNotOffered() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", produced: nil, summary: nil))
        #expect(store.undoableReorganisation(currentProfileId: "prof-a") == nil)
    }

    @Test func anUndoneLandingReopensTheOneBeneathIt() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", produced: "prof-b"))
        store.recordApplied(record(id: "m2", appliedUnder: "prof-b", produced: "prof-c",
                                   undoneAt: "later"))
        #expect(store.undoableReorganisation(currentProfileId: "prof-b")?
            .manifest.manifestId == "m1")
    }
}
