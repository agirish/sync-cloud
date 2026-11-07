import Combine
import EventsTestSupport
import CryptoKit
import Foundation
import Testing
@testable import Sync

/// The restructure apply, end to end: one apply against a real temporary tree in which the disk
/// moved between plan and apply, the two undos (⌘Z this launch, the ledger's inverse after the
/// manager is thrown away), and the re-derived profile carrying the judgements forward.
@MainActor
@Suite struct RestructureApplyTests {

    // MARK: - The world

    struct World {
        let manager: FileSyncManager
        let root: URL
        let profiles: URL
        let manifest: RestructureManifest
        /// Where this world's landings trash to, inside its temp root — never the real Trash.
        let trash: ScratchTrash
    }

    static func write(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    static func treeList(_ root: URL) -> String {
        var lines: [String] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                lines.append(String(url.path.dropFirst(root.path.count)))
            }
        }
        return lines.sorted().joined(separator: " | ")
    }

    /// One content hash over the whole tree (paths and bytes, sorted), so "restored" means
    /// byte-identical, not same-sized.
    static func treeHash(_ root: URL) -> String {
        var hasher = SHA256()
        let keys: [URLResourceKey] = [.isDirectoryKey]
        var entries: [(String, Data)] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                let relative = url.path.dropFirst(root.path.count)
                guard !relative.contains("/.") else { continue }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                entries.append((String(relative),
                                isDirectory ? Data() : ((try? Data(contentsOf: url)) ?? Data())))
            }
        }
        for (path, data) in entries.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A real `FileManager` with a hole in it: one path that `fileExists(atPath:)` denies.
    ///
    /// The landing's verifier re-lists the touched folders through the manager's OWN file
    /// manager, so a hole here is a mismatch the verifier must find and report — which is how a
    /// test can drive the unhappy branch on a tree the executor moves correctly. Everything else
    /// is passed straight through, including the two-argument existence probe the executor uses
    /// for directories, so nothing else in the landing behaves differently.
    final class HidingFileManager: ForwardingFileManaging<FileManager>, @unchecked Sendable {
        let hidden: Set<String>
        init(hiding: Set<String>, over inner: FileManager) {
            hidden = hiding
            super.init(inner: inner)
        }

        override func fileExists(atPath path: String) -> Bool {
            hidden.contains(where: { path.hasSuffix($0) }) ? false : inner.fileExists(atPath: path)
        }
    }

    /// The flagship-shaped fixture: an era to converge (rename + merge + a seeded collision), a
    /// keep, a refused folder with its reason, and a Singapore folder for the jurisdiction rule.
    ///
    /// `fileManager` is handed the world's own Trash to build on, so a double a test layers over
    /// it still trashes into the temp root.
    static func makeWorld(fileManager: (ScratchTrash) -> FileManaging = { $0 }) async throws -> World {
        let base = try makeCanonicalTempRoot(prefix: "RestructureApply")
        let trash = ScratchTrash(in: base)
        let root = base.appendingPathComponent("Documents")
        try write(root.appendingPathComponent("Tax/2013/Federal Tax/1040.pdf"), "federal 1040")
        try write(root.appendingPathComponent("Tax/2013/Federal Tax/w2.pdf"), "w2")
        try write(root.appendingPathComponent("Tax/2013/State Tax/1040.pdf"), "state 1040")
        try write(root.appendingPathComponent("Tax/2013/State Tax/ca-540.pdf"), "ca-540")
        try write(root.appendingPathComponent("Tax/2013/State Tax/Refund/check.pdf"), "check")
        try write(root.appendingPathComponent("Tax/2013/Transcripts/t.pdf"), "transcript")
        try write(root.appendingPathComponent("Tax/2016/Payment/receipt.pdf"), "receipt 2016")
        try write(root.appendingPathComponent("Tax/2016/Payments/receipt.pdf"), "receipt other")
        try write(root.appendingPathComponent("Tax/Outbound/o.pdf"), "outbound")
        try write(root.appendingPathComponent("Tax/Singapore/s.pdf"), "sg")

        func entry(_ path: String, files: Int, subs: Int,
                   naming: String? = nil, accepts: Bool? = nil, reason: String? = nil,
                   jurisdiction: String? = nil) -> FolderProfileEntry {
            FolderProfileEntry(path: path, role: nil, naming: naming, anchors: [],
                               acceptsNewFiles: accepts, noIntakeReason: reason,
                               fileCount: files, subfolderCount: subs,
                               axes: jurisdiction.map { ["jurisdiction": $0] } ?? [:])
        }
        let profile = FolderProfile(
            profileId: "t", root: root.path,
            folders: [
                "Tax": entry("Tax", files: 0, subs: 4),
                "Tax/2013": entry("Tax/2013", files: 0, subs: 3),
                "Tax/2013/Federal Tax": entry("Tax/2013/Federal Tax", files: 2, subs: 0,
                                              naming: "ordinal-month", reason: "carried-reason"),
                "Tax/2013/State Tax": entry("Tax/2013/State Tax", files: 2, subs: 1),
                "Tax/2013/State Tax/Refund": entry("Tax/2013/State Tax/Refund", files: 1, subs: 0),
                "Tax/2013/Transcripts": entry("Tax/2013/Transcripts", files: 1, subs: 0),
                "Tax/2016": entry("Tax/2016", files: 0, subs: 2),
                "Tax/2016/Payment": entry("Tax/2016/Payment", files: 1, subs: 0),
                "Tax/2016/Payments": entry("Tax/2016/Payments", files: 1, subs: 0),
                "Tax/Outbound": entry("Tax/Outbound", files: 1, subs: 0,
                                      accepts: false, reason: "outbound-pack"),
                "Tax/Singapore": entry("Tax/Singapore", files: 1, subs: 0,
                                       jurisdiction: "Singapore"),
            ],
            personTokens: [])
        let profiles = base.appendingPathComponent("profiles")
        try FilingProfileStore.writeProfile(profile, in: profiles,
                                            builtBy: "hand — apply-test fixture")

        // A corpus whose keys the replay must move without re-reading a page.
        let corpus = FilingCorpus(profileId: "t", salt: "s", documents: [
            "Tax/2013/Federal Tax/w2.pdf": FilingCorpusDocument(
                size: 2, modified: 1_700_000_000, anchors: ["w2"], idHashes: []),
        ])
        try FilingSurveyStore.write(corpus: corpus,
                                    memory: FilingMemory(profileId: "t", salt: "s", folders: [:]),
                                    previousMemory: nil, id: "t", in: profiles, root: root.path,
                                    now: Date(timeIntervalSince1970: 1_755_000_000))
        try Data(#"{"people": []}"#.utf8).write(
            to: profiles.appendingPathComponent("t/people.json"))

        let manager = FileSyncManager(fileManager: fileManager(trash))
        manager.filingFolderProfile = profile
        manager.filingProfilesDirectory = profiles
        manager.filingProfileDirectoryId = "t"
        manager.restructureStore = RestructureStore(directory: profiles, profileId: "t")

        // The plan, derived by the real planner against the real disk — the same path the sheet
        // takes — then the tree moves underneath it (below, per test).
        let mapping = RestructureMapping(rows: [
            .init(source: "Federal Tax", target: "Forms"),
            .init(source: "State Tax", target: "Forms"),
            .init(source: "Payment", target: "Payments"),
            .init(source: "Transcripts", target: nil),
        ])
        let manifest = try RestructurePlanner.manifest(
            family: "Tax", members: ["2013", "2016"], mapping: mapping, kind: .shape,
            in: .fromDisk(root: root), profileId: "t", manifestId: "apply-test-1",
            createdAt: "2026-08-28T12:00:00").get()
        return World(manager: manager, root: root, profiles: profiles, manifest: manifest,
                     trash: trash)
    }

    // MARK: - The landing, with the tree moving underneath it

    /// The proof's core: a listed file is deleted and an unlisted one added between plan and
    /// apply. The unlisted folder is skipped and NAMED, the deleted file's own move is skipped,
    /// the rest lands, the counts match a walk of the result, and the collision is a counted
    /// fact with the file kept under a unique name.
    @Test func theLandingSkipsAndNamesDriftAndTheRestLands() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        // The tree moves between plan and apply.
        try FileManager.default.removeItem(
            at: world.root.appendingPathComponent("Tax/2013/State Tax/ca-540.pdf"))
        try Self.write(world.root.appendingPathComponent("Tax/2016/Payment/surprise.pdf"), "new")

        let outcome = await world.manager.applyPlan(world.manifest,
                                                    now: Date(timeIntervalSince1970: 1_756_500_000))
        #expect(outcome.refusal == nil)
        #expect(outcome.renamed == 1, "Federal Tax → Forms")
        #expect(outcome.filesMoved == 1, "State Tax's 1040 — ca-540 was deleted, Payment vetoed")
        #expect(outcome.foldersMovedWhole == 1, "Refund carried whole")
        #expect(outcome.collisions == 1, "Forms already held a 1040.pdf")
        #expect(outcome.skipped.contains { $0.contains("Payment/") && $0.contains("surprise.pdf") },
                "the unlisted folder is skipped AND NAMED")
        #expect(outcome.skipped.contains { $0.contains("ca-540.pdf") })
        #expect(outcome.verifierMismatches.isEmpty)

        let fm = FileManager.default
        let forms = world.root.appendingPathComponent("Tax/2013/Forms")
        let formsFiles = try Set(fm.contentsOfDirectory(atPath: forms.path))
        #expect(formsFiles.contains("1040.pdf") && formsFiles.contains("w2.pdf"))
        #expect(formsFiles.contains("Refund"))
        let collisionName = formsFiles.first { $0.hasPrefix("1040") && $0 != "1040.pdf" }
        #expect(collisionName != nil,
                "the collision landed under a unique name, never an overwrite")
        #expect(try String(contentsOf: forms.appendingPathComponent("1040.pdf"),
                           encoding: .utf8) == "federal 1040",
                "the standing file was not overwritten")
        // The vetoed folder is untouched, surprise and all.
        #expect(fm.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2016/Payment/receipt.pdf").path))
        #expect(fm.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2016/Payment/surprise.pdf").path))

        // The ledger's finalised record: performed actions only, collision recorded as its own
        // fact, bytes and digest filled at apply time from the disk.
        let store = try #require(world.manager.restructureStore)
        let record = try #require(store.applied.first)
        let movedAction = try #require(record.manifest.actions.first {
            $0.action == .moveFile && $0.src == "Tax/2013/State Tax/1040.pdf"
        })
        #expect(movedAction.collidedInto?.hasPrefix("Tax/2013/Forms/1040") == true)
        #expect(movedAction.bytes == "state 1040".utf8.count)
        // No digest, on purpose: hashing every moved file would read gigabytes for a big merge,
        // inside the window where the landing flag refuses every other scan, and nothing reads
        // it. The field stays on `Action` so ledgers on disk keep decoding. `bytes` above is the
        // audit fact, free from the `attributesOfItem` call the move already makes.
        #expect(movedAction.md5 == nil,
                "a same-volume move is a rename; the landing must not read the file to hash it")
        #expect(record.summary == outcome.summary)
        #expect(!record.manifest.actions.contains {
            $0.src?.contains("ca-540") == true || $0.src?.contains("Payment/") == true
        }, "skipped actions are not in the landed manifest — its inverse must not reverse them")
    }

    /// Step 6 and 7: the derived profile is active under a fresh id with the chain recorded, the
    /// judgements carried — for a surviving refused folder AND for the renamed one — Singapore
    /// survives via the entries, the corpus key moved without its stamp, and the fingerprint moved.
    ///
    /// The same clean landing also pins the call sites around it: step 4's verdict reaches the
    /// ledger; the stages are published in the checklist's order and cleared; the trend is stamped
    /// and marked as a landing; the journal goes; the replayed memory becomes the live one; and the
    /// re-derive records the lineage the undo follows.
    @Test func theProfileFollowsTheTreeAndTheJudgementsFollowTheProfile() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let fingerprintBefore = FilingProfileStore.fingerprint(id: "t", in: world.profiles)
        let profileId = try #require(world.manager.filingProfileDirectoryId)
        #expect(world.manager.filingMemory == nil, "nothing is published before the landing")
        // Subscribes to the real landing: the enum's declaration order (the suite next door) would
        // still pass with `applyPlan` publishing `verify` before `inverse`, or never publishing.
        var seen: [RestructureApplyProgress.Stage] = []
        let sink = world.manager.$restructureApplyProgress.sink { progress in
            if let stage = progress?.stage, seen.last != stage { seen.append(stage) }
        }
        defer { sink.cancel() }

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        #expect(outcome.surveyRefreshFailure == nil)
        #expect(outcome.verifierMismatches.isEmpty, "this fixture lands cleanly")
        let newId = try #require(outcome.producedProfileId)
        #expect(newId.hasPrefix("reorg-"))

        // The active profile IS the derived one, and the manager is looking at it.
        #expect(FilingProfileStore.activeProfileId(in: world.profiles) == newId)
        let derived = try #require(world.manager.filingFolderProfile)
        #expect(derived.profileId == newId)
        #expect(derived.derivedFrom == "t")
        #expect(world.manager.filingProfileDirectoryId == newId)

        // The judgements: the surviving refusal, the renamed folder's reason and naming, and the
        // jurisdiction from the entries.
        #expect(derived.folders["Tax/Outbound"]?.noIntakeReason == "outbound-pack")
        #expect(derived.folders["Tax/Outbound"]?.acceptsNewFiles == false)
        #expect(derived.folders["Tax/2013/Forms"]?.noIntakeReason == "carried-reason",
                "the judgement follows the folder through its rename")
        #expect(derived.folders["Tax/2013/Forms"]?.naming == "ordinal-month")
        #expect(derived.folders["Tax/Singapore"]?.axes["jurisdiction"] == "Singapore",
                "the jurisdiction set comes from the entries, never the header")

        // The finding is gone because the tree was re-read: the detector on the derived profile
        // reports nothing for the family it just converged.
        let findings = StructureDivergence.findings(in: derived)
        #expect(!findings.contains { $0.family.hasPrefix("Tax/2013") })

        // Step 7: the corpus key moved, the document's stamp did not, and the artifacts rode
        // along into the new directory.
        let corpus = try #require(FilingSurveyStore.corpus(id: newId, in: world.profiles))
        let moved = try #require(corpus.documents["Tax/2013/Forms/w2.pdf"])
        #expect(moved.modified == 1_700_000_000, "moved, never re-read")
        #expect(corpus.documents["Tax/2013/Federal Tax/w2.pdf"] == nil)
        #expect(FileManager.default.fileExists(
            atPath: world.profiles.appendingPathComponent("\(newId)/people.json").path))

        // The fingerprint moved — every cached verdict names paths that just changed.
        #expect(world.manager.filingArtifactFingerprint != fingerprintBefore)
        #expect(world.manager.filingArtifactFingerprint?.isEmpty == false)

        // The old directory kept everything, byte-untouched profile included — it is what Undo
        // re-points to.
        #expect(FilingProfileStore.profile(id: "t", in: world.profiles) != nil)

        // Step 4's verdict reaches the ledger. A clean landing must say so positively, since `nil`
        // is also what a record older than the field carries; deleting `$0.verifiedOK = ...` from
        // the finalize must fail this.
        let record = try #require(world.manager.restructureStore?.applied.first)
        #expect(record.verifiedOK == true, "a clean landing records agreement, not silence")
        #expect(record.verifierNote == nil, "and has nothing to point at")

        #expect(seen == seen.sorted(), "a checklist that went backwards would be unreadable")
        let inverse = try #require(seen.firstIndex(of: .inverse))
        let operations = try #require(seen.firstIndex(of: .operations))
        #expect(inverse < operations,
                "the inverse is announced before the first file moves — the trust §5.5 paid for")
        #expect(world.manager.restructureApplyProgress == nil,
                "and nothing is left showing a checklist over a finished landing")

        // The trend stamp, read from the store the re-derive produced. Its dedupe and the chart's
        // rules have their own tests; without the call every landing would be invisible on a line
        // whose point is showing what caused the drops. Not `total == structureFindings.count`:
        // both are zero here, so that would be vacuous (`RestructureTrendStampTests` owns counts).
        let stamped = try #require(world.manager.restructureStore?.trend.last)
        #expect(stamped.landing, "the point a landing produced carries its cause")
        #expect(stamped.profileId == world.manager.filingProfileDirectoryId)
        #expect(stamped.countsByKind.values.allSatisfy { $0 > 0 }, "a kind with none is absent, never a zero")

        let journal = RestructureLandingJournal.url(manifestId: world.manifest.manifestId,
                                                    profileId: profileId, in: world.profiles)
        #expect(!FileManager.default.fileExists(atPath: journal.path), "a finished landing kept its journal")

        let memory = try #require(world.manager.filingMemory, "the replayed memory never reached the manager")
        #expect(memory.profileId == newId, "and it is the NEW profile's, not the old one's")
        #expect(world.manager.filingSurveyedAt != nil)

        // The lineage the undo follows, through the landing's own rename: a rule nothing calls is
        // one revert away from unused.
        let hop = try #require(world.manager.restructureStore?.lineage.last,
                               "the re-derive swapped stores without recording which one it carried on from")
        #expect(hop.profileId == "t")
        #expect(hop.renames.contains { $0.from == "Tax/2013/Federal Tax" && $0.to == "Tax/2013/Forms" })
    }

    /// The guard: an apply started while a filing scan runs is refused with a sentence, not
    /// queued — and nothing lands.
    @Test func anApplyDuringAScanIsRefusedWithASentence() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        world.manager.filingScanLifecycle.isRunning = true

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal?.contains("filing scan") == true)
        #expect(world.manager.restructureStore?.applied.isEmpty == true)
        #expect(FileManager.default.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2013/Federal Tax").path))
    }

    /// The other side of it: a disagreement is recorded WITH its note, so the card can point at
    /// something. Forced by verifying a landing that claims an action nothing performed — the
    /// verifier's own input, which is the only seam that does not require breaking the disk.
    @Test func aDisagreementIsRecordedWithItsNote() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Nothing was ever moved, so re-listing finds neither side of this claim.
        let mismatches = FileSyncManager.verifyRestructureLanding(
            [.init(action: .moveFile, src: "A/x.pdf", dst: "B/x.pdf")], root: root.path,
            fm: FileManager.default)
        #expect(!mismatches.isEmpty, "the verifier disagrees with a claim nothing performed")
        // The note the record carries is `RestructureRemovalTests.theVerifierNoteNamesTheFirstAndCountsTheRest`'s.
        #expect(FileSyncManager.verifierNote(mismatches) != nil)
    }

    // MARK: - The two undos

    /// ⌘Z restores a byte-identical tree: hash it, do not size it.
    @Test func oneGroupedUndoRestoresAByteIdenticalTree() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let undo = UndoManager()
        world.manager.undoManager = undo
        world.manager.permanentDeleteConfirmer = { _ in true }
        let before = Self.treeHash(world.root)

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        #expect(Self.treeHash(world.root) != before, "the landing must change the tree")
        #expect(undo.canUndo)

        undo.undo()
        #expect(undo.canRedo, "the undo closures never ran")
        for _ in 0..<600 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            if world.manager.activeFileOperationsCount == 0,
               Self.treeHash(world.root) == before { break }
        }
        #expect(Self.treeHash(world.root) == before,
                "one ⌘Z must take back the whole landing, byte for byte — now: \(Self.treeList(world.root))")
    }

    /// Undo never shows the landing's survey date under the restored folder. The restored folder's
    /// date is read off the main actor, from its whole corpus; until it arrives the footnote must
    /// say nothing, not the date of the folder being left.
    @Test @MainActor func undoNeverShowsTheLeavingFoldersSurveyDate() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let applied = await world.manager.applyPlan(world.manifest, now: Date(timeIntervalSince1970: 1_756_500_000))
        let newId = try #require(applied.producedProfileId)
        let landingDate = try #require(world.manager.filingSurveyedAt, "the landing published no date to leave behind")
        // What the footnote shows under the restored folder while its date is read off the main
        // actor: sampled at every turn the Undo yields, from the folder switch on.
        final class Seen { var dates: [Date?] = []; var done = false }
        let seen = Seen()
        let poll = Task { @MainActor [manager = world.manager] in
            while !seen.done {
                if manager.filingProfileDirectoryId != newId { seen.dates.append(manager.filingSurveyedAt) }
                await Task.yield()
            }
        }
        let undone = await world.manager.undoReorganisation(manifestId: world.manifest.manifestId)
        seen.done = true
        await poll.value
        #expect(undone.refusal == nil)
        let shownOnSwitch = seen.dates
        try #require(!shownOnSwitch.isEmpty, "the undo never moved to another folder — nothing to test")
        #expect(!shownOnSwitch.contains(landingDate), "the restored folder showed the landing's survey date")
        let restoredId = try #require(world.manager.filingProfileDirectoryId)
        #expect(world.manager.filingSurveyedAt == FilingSurveyStore.surveyedAt(id: restoredId, in: world.profiles),
                "the restored folder's own date never arrived")
    }

    /// The on-disk inverse restores the tree after the manager is thrown away and rebuilt — the
    /// undo that survives a quit — and `profiles.json` is re-pointed back to the kept profile.
    @Test func theLedgerInverseSurvivesAQuitAndRePointsTheProfile() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let before = Self.treeHash(world.root)
        let applied = await world.manager.applyPlan(world.manifest)
        #expect(applied.refusal == nil)
        let newId = try #require(applied.producedProfileId)

        // The quit: a fresh manager, configured the way FilingArtifacts.attach would from the
        // directory as the apply left it.
        let reborn = FileSyncManager(fileManager: world.trash)
        let loaded = try #require(FilingProfileStore.active(in: world.profiles))
        #expect(loaded.id == newId)
        reborn.filingFolderProfile = loaded.profile
        reborn.filingProfilesDirectory = world.profiles
        reborn.filingProfileDirectoryId = loaded.id
        reborn.restructureStore = RestructureStore(directory: world.profiles, profileId: loaded.id)

        let undone = await reborn.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(undone.refusal == nil)
        #expect(Self.treeHash(world.root) == before,
                "the stored inverse must restore the tree byte for byte — now: \(Self.treeList(world.root))")
        #expect(FilingProfileStore.activeProfileId(in: world.profiles) == "t",
                "profiles.json re-points to the profile recorded as applied-under")
        #expect(reborn.filingFolderProfile?.profileId == "t")
        // Marked undone in the restored directory's ledger, so it cannot run twice.
        let restored = try #require(reborn.restructureStore)
        #expect(restored.applied.first?.undoneAt != nil)
        let again = await reborn.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(again.refusal?.contains("already undone") == true)
    }

    /// What the user made after a landing survives that landing's Undo. Undo re-points to the
    /// folder the landing started from and re-opens every store there, so a person added, a verdict
    /// given or a finding suppressed afterwards must come back with the survey (the suppression
    /// rekeyed through the undo's renames), while the ledger still says the landing is undone.
    @Test func editsMadeAfterALandingSurviveItsUndo() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let profiles = world.profiles
        let manager = world.manager
        manager.filingPeopleStore = PeopleStore(directory: profiles, profileId: "t",
                                                profile: manager.filingFolderProfile)
        manager.filingPersonTagStore = PersonTagStore(directory: profiles, profileId: "t")
        let applied = await manager.applyPlan(world.manifest)
        #expect(applied.refusal == nil)
        let producedId = try #require(applied.producedProfileId)

        // After the landing, in the folder the app now reads.
        manager.filingPeopleStore?.add(displayName: "After Landing")
        manager.filingPersonTagStore?.record(personId: "after-landing", key: .path("Tax/Outbound/o.pdf"),
                                             verdict: .rejected, path: "Tax/Outbound/o.pdf")
        let suppressedThere = RestructureKey(kind: .shape, path: "Tax/2013/Forms")
        manager.restructureStore?.suppress(suppressedThere)
        #expect(manager.restructureStore?.profileId == producedId)

        let undone = await manager.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(undone.refusal == nil)
        #expect(manager.filingProfileDirectoryId == "t")
        #expect(manager.filingPeopleStore?.people.contains { $0.displayName == "After Landing" }
                == true, "the person added after the landing was left behind in \(producedId)")
        #expect(manager.filingPersonTagStore?.tags.contains { $0.personId == "after-landing" }
                == true)
        let restored = try #require(manager.restructureStore)
        #expect(restored.profileId == "t")
        #expect(restored.isSuppressed(RestructureKey(kind: .shape, path: "Tax/2013/Federal Tax")),
                "the suppression comes back under the folder's restored name")
        #expect(!restored.isSuppressed(suppressedThere))
        #expect(restored.applied.first { $0.manifest.manifestId == world.manifest.manifestId }?
            .undoneAt != nil, "the ledger must still record the landing as undone")
        // And from disk, the way the next launch reads it.
        let relaunched = RestructureStore(directory: profiles, profileId: "t")
        #expect(relaunched.isSuppressed(RestructureKey(kind: .shape, path: "Tax/2013/Federal Tax")))
        #expect(relaunched.undoableReorganisation(currentProfileId: "t") == nil)
        let again = await manager.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(again.refusal?.contains("already undone") == true)
    }

    /// A quit while the survey is re-derived must not take the landing's Undo with it.
    /// `profiles.json` names the new folder before the corpus replay's seconds-long wait, so the
    /// ledger must already offer the Undo there, read the way a relaunch reads it.
    @Test func aQuitDuringTheReDeriveStillLeavesTheLandingUndoable() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let profiles = world.profiles
        let manifestId = world.manifest.manifestId
        // What a relaunch would find at the instant step 7 begins: the active id from the index
        // and a ledger opened fresh from that folder. `@Published` delivers in `willSet`, after
        // the write that re-points the index and before the awaited replay.
        var atTheCut: (active: String?, undoable: String?)?
        let watch = world.manager.$restructureApplyProgress.sink { progress in
            guard progress?.stage == .artifacts, atTheCut == nil else { return }
            let active = FilingProfileStore.activeProfileId(in: profiles)
            let undoable = active.flatMap {
                RestructureStore(directory: profiles, profileId: $0)
                    .undoableReorganisation(currentProfileId: $0)?.manifest.manifestId
            }
            atTheCut = (active, undoable)
        }
        defer { watch.cancel() }

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        let cut = try #require(atTheCut, "the landing never reached step 7")
        #expect(cut.active == outcome.producedProfileId,
                "the cut must be after the re-point, or it tests nothing")
        #expect(cut.undoable == manifestId,
                "relaunched there, the ledger in the active folder offered no Undo of the landing")
    }

    /// An edit made in the People pane while the re-derive replays the corpus lands in the folder
    /// the app goes on reading. Stores left open on the old folder through that wait would write
    /// the edit there after the copy was taken, where nothing reads it.
    @Test func anEditDuringTheReDeriveLandsInTheFolderTheAppReads() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let profiles = world.profiles
        world.manager.filingPeopleStore = PeopleStore(
            directory: profiles, profileId: "t", profile: world.manager.filingFolderProfile)
        world.manager.filingPersonTagStore = PersonTagStore(directory: profiles, profileId: "t")
        let manager = world.manager
        var edited = false
        // `.artifacts` is published right before the replay's wait: the copy is taken and the
        // index re-pointed, and the window is live for the seconds that follow.
        let watch = manager.$restructureApplyProgress.sink { progress in
            guard progress?.stage == .artifacts, !edited else { return }
            edited = true
            MainActor.assumeIsolated {
                manager.filingPeopleStore?.add(displayName: "Late Edit")
                manager.filingPersonTagStore?.record(personId: "late-edit",
                                                     key: .path("Tax/Outbound/o.pdf"),
                                                     verdict: .confirmed,
                                                     path: "Tax/Outbound/o.pdf")
            }
        }
        defer { watch.cancel() }

        let outcome = await manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        #expect(edited, "the landing never reached step 7")
        let newId = try #require(outcome.producedProfileId)
        let people = try String(contentsOf: profiles.appendingPathComponent("\(newId)/people.json"),
                                encoding: .utf8)
        #expect(people.contains("Late Edit"),
                "the person was written to a folder nothing reads any more")
        let tags = try String(
            contentsOf: profiles.appendingPathComponent("\(newId)/person-tags.json"), encoding: .utf8)
        #expect(tags.contains("late-edit"))
        // And the live stores the window keeps editing are the new folder's.
        #expect(manager.filingPeopleStore?.fileURL.path.contains("/\(newId)/") == true)
        #expect(manager.filingPeopleStore?.people.contains { $0.displayName == "Late Edit" } == true)
    }

    /// A stopped document survey can still be carried on after a landing and after a refresh. Its
    /// progress lives in the profile folder, so left behind, the next survey would start from 0 and
    /// the retire sweep would delete it. A copy won't do (the checkpoint names its profile and keys
    /// what it read by paths the landing just moved), so it is rekeyed like the corpus.
    @Test func aStoppedSurveysProgressFollowsTheProfileThroughALanding() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let profiles = world.profiles
        let folder = try #require(world.manager.documentSurveyFolder)
        func doc(_ size: Int) -> FilingCorpusDocument {
            FilingCorpusDocument(size: size, modified: 1_700_000_000, anchors: ["a"], idHashes: [])
        }
        let stopped = DocumentSurveyCheckpoint(
            profileId: "t", rootPath: folder.path, salt: "s",
            plan: ["Tax/2013/State Tax/ca-540.pdf", "Tax/2013/Transcripts/t.pdf",
                   "Tax/Outbound/o.pdf"],
            nextIndex: 2,
            read: ["Tax/2013/State Tax/ca-540.pdf": doc(6), "Tax/2013/Transcripts/t.pdf": doc(10)],
            documentsUnavailable: 1,
            startedAt: Date(timeIntervalSince1970: 1_760_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_760_000_100))
        try DocumentSurveyCheckpointStore.write(stopped, id: "t", in: profiles)
        #expect(world.manager.resumableDocumentSurvey(root: folder)?.done == 2)

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        let newId = try #require(outcome.producedProfileId)
        #expect(world.manager.resumableDocumentSurvey(root: folder)?.done == 2,
                "the landing left the app on a folder with no survey progress")
        let carried = try #require(DocumentSurveyCheckpointStore.read(id: newId, in: profiles)
            .checkpoint)
        #expect(carried.resumes(profileId: newId, rootPath: folder.path, salt: "s"),
                "a checkpoint naming the old profile is refused as another run's")
        #expect(Set(carried.read.keys) == ["Tax/2013/Forms/ca-540.pdf",
                                           "Tax/2013/Transcripts/t.pdf"],
                "what was read must sit where the landing put it")
        #expect(carried.plan.first == "Tax/2013/Forms/ca-540.pdf")
        #expect(carried.documentsUnavailable == 1)
        #expect(DocumentSurveyCheckpointStore.read(id: "t", in: profiles).checkpoint == stopped,
                "copied, never moved — the old folder is what Undo re-points to")

        // A plain refresh mints a folder too, and retires the one it replaced — progress and all.
        let refreshed = await world.manager.refreshDerivedProfile(
            now: Date().addingTimeInterval(5))
        #expect(refreshed.refusal == nil)
        #expect(world.manager.filingProfileDirectoryId != newId)
        #expect(world.manager.resumableDocumentSurvey(root: folder)?.done == 2,
                "a survey refresh dropped the unfinished survey's progress")
    }

    /// ⌘Q's count sees the re-derive. No file operation is queued through it, so a count of queued
    /// operations alone would read zero and let a quit through in silence.
    @Test func theQuitGuardsCountSeesALandingsReDerive() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let manager = world.manager
        var during: (queued: Int, counted: Int)?
        let watch = manager.$restructureApplyProgress.sink { progress in
            guard progress?.stage == .artifacts, during == nil else { return }
            MainActor.assumeIsolated {
                during = (manager.activeFileOperationsCount, manager.operationsAQuitWouldInterrupt)
            }
        }
        defer { watch.cancel() }
        #expect(manager.operationsAQuitWouldInterrupt == 0)
        let outcome = await manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        let seen = try #require(during, "the landing never reached step 7")
        #expect(seen.queued == 0, "the premise: the re-derive queues nothing")
        #expect(seen.counted == 1)
        #expect(manager.operationsAQuitWouldInterrupt == 0, "and nothing once it has finished")
    }

    /// The same cut on a survey refresh: it mints a folder too, and the undo chain must already
    /// be carried across when the index names it.
    @Test func aQuitDuringASurveyRefreshKeepsTheLastLandingUndoable() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let profiles = world.profiles
        let landed = await world.manager.applyPlan(world.manifest)
        #expect(landed.refusal == nil)

        var atTheCut: String??
        let watch = world.manager.$restructureApplyProgress.sink { progress in
            guard progress?.stage == .artifacts, atTheCut == nil else { return }
            let active = FilingProfileStore.activeProfileId(in: profiles)
            atTheCut = .some(active.flatMap {
                RestructureStore(directory: profiles, profileId: $0)
                    .undoableReorganisation(currentProfileId: $0)?.manifest.manifestId
            })
        }
        defer { watch.cancel() }
        let refreshed = await world.manager.refreshDerivedProfile(
            now: Date().addingTimeInterval(5))
        #expect(refreshed.refusal == nil)
        let cut = try #require(atTheCut, "the refresh never reached step 7")
        #expect(cut == world.manifest.manifestId)
    }

    /// The disk at the instant a survey refresh's replay begins — copied aside, so the test can
    /// read it the way a relaunch after a quit there would — and the folder the refresh left.
    /// `left` is the landing's produced folder: derived, so the sweep may take it, and holding
    /// the corpus that landing replayed. `prepare` runs on it before the refresh.
    private func cutASurveyRefreshBeforeItsReplay(
        _ world: World, prepare: (String) throws -> Void = { _ in }
    ) async throws -> (disk: URL, left: String) {
        let landed = await world.manager.applyPlan(world.manifest)
        #expect(landed.refusal == nil)
        let left = try #require(landed.producedProfileId)
        try prepare(left)
        let disk = world.root.deletingLastPathComponent().appendingPathComponent("at-the-cut")
        var copied = false
        let watch = world.manager.$restructureApplyProgress.sink { progress in
            guard progress?.stage == .artifacts, !copied else { return }
            copied = (try? FileManager.default.copyItem(at: world.profiles, to: disk)) != nil
        }
        defer { watch.cancel() }
        let refreshed = await world.manager.refreshDerivedProfile(now: Date().addingTimeInterval(5))
        #expect(refreshed.refusal == nil)
        try #require(copied, "the refresh never reached its replay")
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        try #require(active != left, "the cut must be after the re-point, or it tests nothing")
        return (disk, left)
    }

    /// What the app does at launch on that disk (`FilingArtifacts.attach`): the load, the
    /// manager handed what it found, then the read-back off the main actor.
    private func relaunch(_ disk: URL) async throws -> FileSyncManager {
        let loaded = try #require(FilingProfileStore.active(in: disk), "the relaunch's load")
        let manager = FileSyncManager()
        manager.filingProfilesDirectory = disk
        manager.filingFolderProfile = loaded.profile
        manager.filingMemory = loaded.memory
        manager.filingProfileDirectoryId = loaded.id
        await manager.finishInterruptedSurveyReplay()
        return manager
    }

    /// A `prepare` that turns the folder left into a first survey stopped part-way: progress, and
    /// no corpus or memory yet.
    @MainActor
    private func stopTheSurvey(_ world: World) throws -> (String) throws -> Void {
        let folder = try #require(world.manager.documentSurveyFolder)
        return { left in
            try FileManager.default.removeItem(at: FilingSurveyStore.corpusURL(id: left, in: world.profiles))
            try FileManager.default.removeItem(at: FilingSurveyStore.memoryURL(id: left, in: world.profiles))
            try DocumentSurveyCheckpointStore.write(DocumentSurveyCheckpoint(
                profileId: left, rootPath: folder.path, salt: "s",
                plan: ["Tax/Outbound/o.pdf"], nextIndex: 0, read: [:], documentsUnavailable: 0,
                startedAt: Date(timeIntervalSince1970: 1_760_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_760_000_100)), id: left, in: world.profiles)
        }
    }

    /// The sweep the next refresh or landing runs on that disk, protecting exactly what
    /// `rederiveProfile` protects: every id a record in the active ledger names.
    private func sweepAsTheNextReDeriveWould(_ disk: URL, sparing left: String) throws {
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        var protected: Set<String> = []
        for record in RestructureStore(directory: disk, profileId: active).applied {
            if let applied = record.appliedUnderProfileId { protected.insert(applied) }
            if let produced = record.producedProfileId { protected.insert(produced) }
        }
        try #require(!protected.contains(left), "premise: no record names the folder left behind")
        _ = try FilingProfileStore.retireSupersededProfiles(protecting: protected, in: disk)
    }

    /// A quit during a survey refresh's corpus replay must not cost the survey. The index names the
    /// new folder before the replay and the refresh re-points the undo chain there too, so the
    /// folder left behind, the only one holding the corpus and memory, is named by no record and
    /// its curated files were carried. The next sweep must still keep it.
    @Test func aQuitDuringASurveyRefreshsReplayKeepsTheOnlyCorpus() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let (disk, left) = try await cutASurveyRefreshBeforeItsReplay(world)
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        try #require(FilingSurveyStore.corpus(id: active, in: disk) == nil,
                     "the cut must be before the replay wrote the corpus")
        try #require(FilingSurveyStore.corpus(id: left, in: disk) != nil)

        try sweepAsTheNextReDeriveWould(disk, sparing: left)
        let kept = try #require(FilingSurveyStore.corpus(id: left, in: disk),
                                "the sweep deleted the only copy of the survey corpus")
        #expect(kept.documents["Tax/2013/Forms/w2.pdf"] != nil)
        #expect(FileManager.default.fileExists(
            atPath: FilingSurveyStore.memoryURL(id: left, in: disk).path))
    }

    /// The same cut for a stopped first survey: its progress is carried inside the replay, so at
    /// the cut the only copy is in the folder left behind.
    @Test func aQuitDuringASurveyRefreshsReplayKeepsAStoppedSurveysProgress() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let (disk, left) = try await cutASurveyRefreshBeforeItsReplay(world, prepare: try stopTheSurvey(world))
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        try #require(DocumentSurveyCheckpointStore.read(id: active, in: disk).checkpoint == nil,
                     "the cut must be before the progress was carried")

        try sweepAsTheNextReDeriveWould(disk, sparing: left)
        #expect(DocumentSurveyCheckpointStore.read(id: left, in: disk).checkpoint?.profileId == left,
                "the sweep deleted the only copy of the stopped survey's progress")
    }

    /// …and the survey kept there is read back, not only kept: relaunched on that disk, the load
    /// carries the folder's corpus and memory into the active one, and only then does the sweep let
    /// the old folder go. Kept alone, the next refresh would replay from the empty active folder,
    /// and the survey would be on disk but lost to the app.
    @Test func aRelaunchAfterACutSurveyRefreshReadsTheSurveyBack() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let (disk, left) = try await cutASurveyRefreshBeforeItsReplay(world)
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        try #require(FilingSurveyStore.corpus(id: active, in: disk) == nil,
                     "the cut must be before the replay wrote the corpus")
        let stamped = try #require(FilingSurveyStore.surveyedAt(id: left, in: disk))

        // The load itself carries nothing: it runs on the main actor.
        let load = try #require(FilingProfileStore.active(in: disk))
        #expect(load.id == active)
        #expect(FilingSurveyStore.corpus(id: active, in: disk) == nil,
                "the load decoded and rewrote the survey on the main actor")
        let relaunched = try await relaunch(disk)
        let memory = try #require(relaunched.filingMemory, "relaunched with no filing memory")
        #expect(memory.folders["Tax/2013/Forms"]?.docs == 1)
        let carried = try #require(FilingSurveyStore.corpus(id: active, in: disk),
                                   "the corpus was kept in \(left) and never read back")
        #expect(Set(carried.documents.keys) == ["Tax/2013/Forms/w2.pdf"])
        #expect(carried.profileId == active)
        #expect(FilingSurveyStore.surveyedAt(id: active, in: disk) == stamped,
                "nothing was read again, so the survey's date stays the one it was read on")

        try sweepAsTheNextReDeriveWould(disk, sparing: left)
        #expect(!FileManager.default.fileExists(atPath: disk.appendingPathComponent(left).path),
                "once the survey is in the active folder, the old one is superseded")
        #expect(FilingSurveyStore.corpus(id: active, in: disk) != nil)
    }

    /// The same read-back after a cut LANDING: the corpus comes in through the landing's own
    /// moves, found by its ledger record, so its keys name where the files are now.
    @Test func aRelaunchAfterACutLandingReadsTheSurveyBackThroughItsMoves() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let disk = world.root.deletingLastPathComponent().appendingPathComponent("at-the-cut")
        var copied = false
        let watch = world.manager.$restructureApplyProgress.sink { progress in
            guard progress?.stage == .artifacts, !copied else { return }
            copied = (try? FileManager.default.copyItem(at: world.profiles, to: disk)) != nil
        }
        defer { watch.cancel() }
        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        try #require(copied, "the landing never reached its replay")
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        try #require(active == outcome.producedProfileId,
                     "the cut must be after the re-point, or it tests nothing")
        try #require(FilingSurveyStore.corpus(id: active, in: disk) == nil)

        let relaunched = try await relaunch(disk)
        #expect(relaunched.filingMemory?.folders["Tax/2013/Forms"] != nil)
        let carried = try #require(FilingSurveyStore.corpus(id: active, in: disk),
                                   "the landing's survey was never read back")
        #expect(Set(carried.documents.keys) == ["Tax/2013/Forms/w2.pdf"],
                "the keys must follow the landing's moves, not name Federal Tax")
    }

    /// A stopped first survey's progress is read back the same way, so the next survey resumes.
    @Test func aRelaunchAfterACutSurveyRefreshReadsAStoppedSurveysProgressBack() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let folder = try #require(world.manager.documentSurveyFolder)
        let (disk, left) = try await cutASurveyRefreshBeforeItsReplay(world, prepare: try stopTheSurvey(world))
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        try #require(DocumentSurveyCheckpointStore.read(id: active, in: disk).checkpoint == nil)

        _ = try await relaunch(disk)
        let carried = try #require(DocumentSurveyCheckpointStore.read(id: active, in: disk).checkpoint,
                                   "the stopped survey's progress was never read back")
        #expect(carried.resumes(profileId: active, rootPath: folder.path, salt: "s"))
        #expect(carried.plan == ["Tax/Outbound/o.pdf"])
    }

    /// A profile folder `child` derived from `parent`, with `parent` holding a one-document
    /// corpus at `Tax/w2.pdf` — the read-back's raw material, by hand.
    private static func derivedPair(_ disk: URL) throws -> FolderProfile {
        func entry(_ path: String) -> FolderProfileEntry {
            FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [], acceptsNewFiles: nil,
                               fileCount: 0, subfolderCount: 0, axes: [:])
        }
        let profile = FolderProfile(profileId: "child", root: "~/R",
                                    folders: ["Tax": entry("Tax"), "New": entry("New")],
                                    personTokens: [], derivedFrom: "parent")
        try FileManager.default.createDirectory(at: disk.appendingPathComponent("child"),
                                                withIntermediateDirectories: true)
        try FilingSurveyStore.write(
            corpus: FilingCorpus(profileId: "parent", salt: "s", documents: [
                "Tax/w2.pdf": FilingCorpusDocument(size: 2, modified: 1_700_000_000,
                                                    anchors: ["w2"], idHashes: [])]),
            memory: FilingMemory(profileId: "parent", salt: "s", folders: [:]),
            previousMemory: nil, id: "parent", in: disk, root: "~/R",
            now: Date(timeIntervalSince1970: 1_755_000_000))
        return profile
    }

    private static func landing(_ id: String, moving file: String, to dst: String,
                                produced: String?, summary: String?) -> RestructureStore.AppliedRecord {
        let manifest = RestructureManifest(
            profileId: "parent", manifestId: id, createdAt: "2026-10-24T09:00:00", family: ".",
            kind: .shape, actions: [.init(action: .moveFile, src: file, dst: dst, evidence: "x")])
        return .init(manifest: manifest, inverse: manifest, at: "2026-10-24T09:00:00",
                     created: 0, skipped: 0, appliedUnderProfileId: "parent",
                     producedProfileId: produced, summary: summary)
    }

    /// The read-back rekeys through the landing that made the folder, not a later record under the
    /// same parent that never finalised (no `summary`: a landing cut off before its moves), whose
    /// moves never ran.
    @Test func theReadBackRekeysThroughTheFinishedLandingNotACutOne() throws {
        let disk = FileManager.default.temporaryDirectory
            .appendingPathComponent("readback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: disk) }
        let profile = try Self.derivedPair(disk)
        let store = RestructureStore(directory: disk, profileId: "child")
        try #require(store.recordApplied(Self.landing("made-it", moving: "Tax/w2.pdf",
                                                      to: "New/w2.pdf", produced: "child",
                                                      summary: "1 moved")))
        try #require(store.recordApplied(Self.landing("cut-off", moving: "Tax/w2.pdf",
                                                      to: "Old/w2.pdf", produced: nil,
                                                      summary: nil)))

        #expect(FileSyncManager.recoverInterruptedSurveyReplay(into: "child", profile: profile,
                                                               in: disk))
        let carried = try #require(FilingSurveyStore.corpus(id: "child", in: disk))
        #expect(Set(carried.documents.keys) == ["New/w2.pdf"],
                "the keys followed a landing that never ran its moves")
    }

    /// A stopped first survey (progress of its own, and a parent with progress but no corpus) has
    /// nothing to carry, so the read-back, which runs on every load, stops before decoding the
    /// ledger.
    @Test func theReadBackReadsNoLedgerWhenThereIsNothingToCarry() async throws {
        let disk = FileManager.default.temporaryDirectory
            .appendingPathComponent("readback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: disk) }
        let profile = try Self.derivedPair(disk)
        try FileManager.default.removeItem(at: FilingSurveyStore.corpusURL(id: "parent", in: disk))
        for id in ["parent", "child"] {
            try DocumentSurveyCheckpointStore.write(DocumentSurveyCheckpoint(
                profileId: id, rootPath: "/R", salt: "s", plan: ["Tax/w2.pdf"], nextIndex: 0,
                read: [:], documentsUnavailable: 0,
                startedAt: Date(timeIntervalSince1970: 1_760_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_760_000_100)), id: id, in: disk)
        }
        // A ledger that does not parse: reading it is the one thing that says so in the log.
        try Data("{ not a ledger".utf8).write(to: disk.appendingPathComponent("child/restructure.json"))
        let log = LogCapture()

        #expect(!FileSyncManager.recoverInterruptedSurveyReplay(into: "child", profile: profile,
                                                                in: disk))
        #expect(!(await log.holds(.warning, containing: "child/restructure.json could not be read")),
                "the read-back decoded the ledger with nothing to carry")
    }

    /// The refresh reads it back too, for a folder whose own replay failed in the session: the
    /// next refresh replays from the folder the app is on, so it must not find that empty.
    @Test func aRefreshFromAFolderWithNoSurveyReadsItsParentsBack() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let (disk, _) = try await cutASurveyRefreshBeforeItsReplay(world)
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        let profile = try #require(FilingProfileStore.profile(id: active, in: disk))
        try #require(FilingSurveyStore.corpus(id: active, in: disk) == nil)

        // Set up from the disk directly — not through `active(in:)`, which would read it back.
        let manager = FileSyncManager(fileManager: world.trash)
        manager.filingFolderProfile = profile
        manager.filingProfilesDirectory = disk
        manager.filingProfileDirectoryId = active
        manager.restructureStore = RestructureStore(directory: disk, profileId: active)
        let refreshed = await manager.refreshDerivedProfile(now: Date().addingTimeInterval(10))
        #expect(refreshed.refusal == nil)
        let produced = try #require(manager.filingProfileDirectoryId)
        #expect(produced != active)
        let corpus = try #require(FilingSurveyStore.corpus(id: produced, in: disk),
                                  "the refresh replayed from an empty folder")
        #expect(Set(corpus.documents.keys) == ["Tax/2013/Forms/w2.pdf"])
        #expect(manager.filingMemory?.folders["Tax/2013/Forms"] != nil)
    }

    /// Undo runs newest-first, the way ⌘Z would: a later landing on top of an earlier one blocks
    /// the earlier one's undo with a sentence — its inverse describes a tree the later landing
    /// reshaped — and undoing the later one first unblocks nothing silently.
    @Test func aLaterLandingBlocksUndoOfTheEarlierOne() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let first = await world.manager.applyPlan(world.manifest)
        #expect(first.refusal == nil)

        // A second landing on top: the removal step for a folder the first one emptied.
        let removal = RestructureManifest(
            profileId: world.manager.filingProfileDirectoryId ?? "t",
            manifestId: "removal-1", createdAt: "2026-08-28T13:00:00",
            family: "Tax", kind: .deadWeight,
            actions: [.init(action: .removeEmptyDir, src: "Tax/2013/State Tax",
                            evidence: "emptied by apply-test-1")])
        let second = await world.manager.applyPlan(removal)
        #expect(second.refusal == nil)
        #expect(second.removedEmpty == 1)
        #expect(world.trash.names == ["State Tax"],
                "the emptied folder left the tree but never reached the test's own Trash")

        let blocked = await world.manager.undoReorganisation(
            manifestId: world.manifest.manifestId)
        #expect(blocked.refusal?.contains("later reorganization") == true)

        // Newest first works: the removal undoes (the folder comes back), and then the first
        // landing is undoable again.
        let undoRemoval = await world.manager.undoReorganisation(manifestId: "removal-1")
        #expect(undoRemoval.refusal == nil)
        #expect(FileManager.default.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2013/State Tax").path))
        let unblocked = await world.manager.undoReorganisation(
            manifestId: world.manifest.manifestId)
        #expect(unblocked.refusal == nil)
    }
    // MARK: - The full-branch review's catches

    /// A manifest lands once: the finalize rewrites the record found by its id, so a second
    /// landing of the same id would replace the FIRST landing's stored inverse with its own
    /// near-empty one — destroying the post-quit undo of the real landing.
    @Test func theSameManifestIdRefusesASecondLanding() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let first = await world.manager.applyPlan(world.manifest,
                                                  now: Date(timeIntervalSince1970: 1_756_500_000))
        #expect(first.refusal == nil)
        let storedInverse = world.manager.restructureStore?.applied
            .first { $0.manifest.manifestId == world.manifest.manifestId }?.inverse

        let second = await world.manager.applyPlan(world.manifest,
                                                   now: Date(timeIntervalSince1970: 1_756_500_100))
        #expect(second.refusal?.contains("lands once") == true)
        let after = world.manager.restructureStore?.applied
            .filter { $0.manifest.manifestId == world.manifest.manifestId }
        #expect(after?.count == 1, "no second record was appended")
        #expect(after?.first?.inverse == storedInverse, "the real landing's inverse survives")
    }

    /// The chain is walked by ledger order, not by profile-id equality: a later landing whose
    /// re-derive failed never re-pointed the survey, so an id comparison can't see it sitting on
    /// top and would undo the older landing straight through it.
    @Test func aLaterUnfinalisedLandingStillBlocksTheOneBeneathIt() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let outcome = await world.manager.applyPlan(world.manifest,
                                                    now: Date(timeIntervalSince1970: 1_756_500_000))
        #expect(outcome.refusal == nil)
        let store = try #require(world.manager.restructureStore)

        // A later landing, applied under the produced profile, whose step 6 failed: summary set,
        // producedProfileId nil — exactly the record shape applyPlan leaves on that path.
        let later = RestructureManifest(profileId: "p", manifestId: "m-later", createdAt: "t",
                                        family: "Tax", kind: .shape, actions: [
                                            .init(action: .renameDir, src: "Tax/x", dst: "Tax/y"),
                                        ])
        store.recordApplied(RestructureStore.AppliedRecord(
            manifest: later, inverse: later.inverse, at: "t2", created: 0, skipped: 0,
            appliedUnderProfileId: world.manager.filingProfileDirectoryId,
            producedProfileId: nil, summary: "renamed 1 folder"))

        let blocked = await world.manager.undoReorganisation(
            manifestId: world.manifest.manifestId)
        #expect(blocked.refusal?.contains("later reorganization") == true)

        // A record that never finalised (no summary — the app quit mid-apply) refuses with its
        // own sentence: the stored inverse may not match the disk.
        store.recordApplied(RestructureStore.AppliedRecord(
            manifest: RestructureManifest(profileId: "p", manifestId: "m-crashed",
                                          createdAt: "t", family: "Tax", kind: .shape,
                                          actions: later.actions),
            inverse: later.inverse, at: "t3", created: 0, skipped: 0,
            appliedUnderProfileId: world.manager.filingProfileDirectoryId))
        let crashed = await world.manager.undoReorganisation(manifestId: "m-crashed")
        #expect(crashed.refusal?.contains("never finished recording") == true)
    }

    /// A landing cut off mid-run is refused by Undo. The log records nothing per action, so the
    /// refusal names the landing's journal when one is there, and says plainly when none is.
    @Test func anUnfinishedLandingsRefusalNamesItsJournal() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let store = try #require(world.manager.restructureStore)
        let profileId = try #require(world.manager.filingProfileDirectoryId)
        let crashed = RestructureManifest(profileId: "p", manifestId: "m-crashed", createdAt: "t",
                                          family: "Tax", kind: .shape, actions: [
                                              .init(action: .renameDir, src: "Tax/x", dst: "Tax/y"),
                                          ])
        store.recordApplied(RestructureStore.AppliedRecord(
            manifest: crashed, inverse: crashed.inverse, at: "t3", created: 0, skipped: 0,
            appliedUnderProfileId: profileId))

        let without = await world.manager.undoReorganisation(manifestId: "m-crashed")
        #expect(without.refusal?.contains("No list of the steps that ran was found.") == true)

        let journal = RestructureLandingJournal.url(manifestId: "m-crashed", profileId: profileId,
                                                    in: world.profiles)
        try Data().write(to: journal)
        let with = await world.manager.undoReorganisation(manifestId: "m-crashed")
        #expect(with.refusal?.contains(journal.path) == true, "\(with.refusal ?? "no refusal")")
    }

    /// The journal goes only once the finalised record is on disk. When the finalising
    /// write fails, the record on disk has no summary, the next launch refuses Undo as a landing
    /// that never finished, and the refusal points at this journal — so it must still be there.
    /// The write is broken mid-landing (the ledger's path becomes a folder at the first move), so
    /// the landing's own step-2 record is written and only the finalise fails.
    @Test func aLandingWhoseRecordCouldNotBeFinalisedKeepsItsJournal() async throws {
        let breaker = LedgerBreaker()
        let world = try await Self.makeWorld { trash in
            LedgerBreakingDisk(over: trash, breaker: breaker)
        }
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let profileId = try #require(world.manager.filingProfileDirectoryId)
        breaker.ledger = try #require(world.manager.restructureStore?.fileURL)
        let journal = RestructureLandingJournal.url(manifestId: world.manifest.manifestId,
                                                    profileId: profileId, in: world.profiles)

        _ = await world.manager.applyPlan(world.manifest, now: Date(timeIntervalSince1970: 1_756_500_000))

        #expect(breaker.broke, "the ledger was never broken — this measured an ordinary landing")
        #expect(FileManager.default.fileExists(atPath: journal.path),
                "the only list of what ran was removed though the record never reached the disk")
    }

    /// Makes the ledger unwritable at the first move: its path becomes a folder, so the store's
    /// atomic write cannot land over it.
    final class LedgerBreaker: @unchecked Sendable {
        private let lock = NSLock()
        private var _ledger: URL?
        private var _broke = false
        var ledger: URL? {
            get { lock.lock(); defer { lock.unlock() }; return _ledger }
            set { lock.lock(); _ledger = newValue; lock.unlock() }
        }
        var broke: Bool { lock.lock(); defer { lock.unlock() }; return _broke }
        func breakOnce() {
            lock.lock(); defer { lock.unlock() }
            guard !_broke, let ledger = _ledger else { return }
            try? FileManager.default.removeItem(at: ledger)
            try? FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
            _broke = true
        }
    }

    final class LedgerBreakingDisk: ForwardingFileManaging<FileManager>, @unchecked Sendable {
        private let breaker: LedgerBreaker
        init(over inner: FileManager, breaker: LedgerBreaker) {
            self.breaker = breaker
            super.init(inner: inner)
        }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            breaker.breakOnce()
            try inner.moveItem(at: srcURL, to: dstURL)
        }
    }

    /// An undo that could do NOTHING — the tree fully reshaped since — must not mark the record
    /// undone or re-point the survey: the kept profile would describe a tree that does not
    /// exist, and the record could never be retried.
    @Test func aFullyDriftedUndoRefusesInsteadOfRepointing() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let outcome = await world.manager.applyPlan(world.manifest,
                                                    now: Date(timeIntervalSince1970: 1_756_500_000))
        #expect(outcome.refusal == nil)
        let produced = world.manager.filingProfileDirectoryId

        // Everything the landing touched is swept away — every inverse step will skip as drift.
        try FileManager.default.removeItem(at: world.root.appendingPathComponent("Tax"))

        let undo = await world.manager.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(undo.refusal?.contains("Nothing could be moved back") == true)
        #expect(world.manager.filingProfileDirectoryId == produced,
                "the survey stays where the landing left it")
        #expect(world.manager.restructureStore?.applied
            .first { $0.manifest.manifestId == world.manifest.manifestId }?.undoneAt == nil,
                "the record stays applied, retryable once the drift is resolved")
    }

    /// The ledger Undo after the person hand-trashed a folder the merge emptied. The missing folder
    /// is the one each file came out of, so it is recreated and the tree comes back byte for byte.
    /// Otherwise the move-back would fail and the rename-back after it carry every merged file into
    /// a folder it never lived in, under a record marked undone.
    @Test func anUndoAfterTheEmptiedSourceWasTrashedPutsEachFileBack() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let before = Self.treeHash(world.root)
        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        let stateTax = world.root.appendingPathComponent("Tax/2013/State Tax")
        #expect(FileSyncManager.visibleFileCount(atPath: stateTax.path,
                                                 fm: FileManager.default) == 0,
                "the fixture must have emptied State Tax for this to be the tidy-up it models")
        // The tidy-up, by hand — inside the temp root, never the real Trash.
        try FileManager.default.removeItem(at: stateTax)

        let undo = await world.manager.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(undo.refusal == nil)
        #expect(Self.treeHash(world.root) == before,
                "every file goes back where it came from — now: \(Self.treeList(world.root))")
        #expect(!FileManager.default.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2013/Federal Tax/ca-540.pdf").path),
                "a merged file rode the rename-back into a folder it never lived in")
    }

    /// Back-dates an item's creation date, so a test can put a later file beside one "made long
    /// ago" — the whole fixture is otherwise made within the second the tolerance allows.
    static func madeLongAgo(_ url: URL) throws {
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                              ofItemAtPath: url.path)
    }

    /// Undo This Reorganization moves back the file the landing moved, not a new one put at its
    /// name since. The newcomer is the same size as the original; its file number and creation date
    /// tell it apart. A path-only probe would send it into `State Tax/` as though it were the
    /// landing's.
    @Test func anUndoLeavesANewFilePutInPlaceOfALandedOneWhereItIs() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        try Self.madeLongAgo(world.root.appendingPathComponent("Tax/2013/State Tax/ca-540.pdf"))
        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        let landed = world.root.appendingPathComponent("Tax/2013/Forms/ca-540.pdf")
        #expect(try String(contentsOf: landed, encoding: .utf8) == "ca-540",
                "the fixture must have merged ca-540.pdf into Forms/")
        // A new file at the same name — a download dropped in place.
        try FileManager.default.removeItem(at: landed)
        try Self.write(landed, "ca-541")

        let undo = await world.manager.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(undo.refusal == nil, "everything else still goes back")
        #expect(undo.skipped.contains { $0.contains("ca-540.pdf is a different item") },
                "the newcomer is named — skipped: \(undo.skipped)")
        #expect(!FileManager.default.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2013/State Tax/ca-540.pdf").path),
                "the new file was moved into the folder the landing emptied")
        #expect(try String(contentsOf: world.root.appendingPathComponent(
            "Tax/2013/Federal Tax/ca-540.pdf"), encoding: .utf8) == "ca-541",
                "it stays with the folder it was saved in, which the rename-back carries")
    }

    /// An edited file goes back, and is named. Most apps save by swapping in a new file
    /// (`replaceItemAt`): a new file number, the old creation date. A different document saved over
    /// this one through a Save dialog's Replace looks the same, so the rule is to move it back and
    /// say so rather than strand an edit.
    @Test func anUndoPutsBackAFileSavedOverSinceAndNamesIt() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        try Self.madeLongAgo(world.root.appendingPathComponent("Tax/2013/State Tax/ca-540.pdf"))
        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        let landed = world.root.appendingPathComponent("Tax/2013/Forms/ca-540.pdf")
        let numberBefore = try FileManager.default.attributesOfItem(atPath: landed.path)[.systemFileNumber]
            as? NSNumber
        let staged = world.root.deletingLastPathComponent().appendingPathComponent("ca-540 edit")
        try Data("ca-540, amended".utf8).write(to: staged)
        _ = try FileManager.default.replaceItemAt(landed, withItemAt: staged)
        let numberAfter = try FileManager.default.attributesOfItem(atPath: landed.path)[.systemFileNumber]
            as? NSNumber
        #expect(numberBefore != numberAfter, "premise: the save gave the file a new number")

        let undo = await world.manager.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(undo.refusal == nil)
        #expect(!undo.skipped.contains { $0.contains("ca-540.pdf") }, "skipped: \(undo.skipped)")
        #expect(undo.changedSince == ["Tax/2013/Forms/ca-540.pdf"], "\(undo.changedSince)")
        #expect(undo.summary.contains("1 changed since, moved back"))
        #expect(try String(contentsOf: world.root.appendingPathComponent(
            "Tax/2013/State Tax/ca-540.pdf"), encoding: .utf8) == "ca-540, amended",
                "the saved-over file went back where the landing took it from")
    }

    /// A plan exported after a landing comes back with the survey when the landing is undone —
    /// the sheet named it as beside the survey, and the survey goes back to the earlier folder.
    @Test func aPlanExportedAfterALandingFollowsItsUndo() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        #expect(await world.manager.applyPlan(world.manifest).refusal == nil)
        let produced = try #require(world.manager.filingProfileDirectoryId)
        #expect(produced != "t")
        let name = try #require(try world.manager.restructureStore?.exportPlan(world.manifest))

        let undo = await world.manager.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(undo.refusal == nil)
        #expect(world.manager.filingProfileDirectoryId == "t")
        #expect(FileManager.default.fileExists(
            atPath: world.profiles.appendingPathComponent("t/\(name)").path),
                "the plan stayed behind in \(produced), beside a survey nothing reads")
    }

    /// The same for a folder: a renamed folder set aside and replaced by a fresh one of the same
    /// name is not renamed back, since the fresh one is somebody else's.
    @Test func anUndoLeavesAFolderMadeInPlaceOfARenamedOneWhereItIs() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        try Self.madeLongAgo(world.root.appendingPathComponent("Tax/2013/Federal Tax"))
        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        let forms = world.root.appendingPathComponent("Tax/2013/Forms")
        try FileManager.default.moveItem(at: forms,
                                         to: world.root.appendingPathComponent("Tax/2013/Set Aside"))
        try Self.write(forms.appendingPathComponent("new.pdf"), "new")

        let undo = await world.manager.undoReorganisation(manifestId: world.manifest.manifestId)
        #expect(undo.skipped.contains { $0.contains("Tax/2013/Forms/ is a different item") },
                "skipped: \(undo.skipped)")
        #expect(FileManager.default.fileExists(atPath: forms.appendingPathComponent("new.pdf").path),
                "the fresh folder keeps its name")
        #expect(!FileManager.default.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2013/Federal Tax/new.pdf").path),
                "the fresh folder was renamed back as though it were the landing's")
    }

    /// The rule at its edges, on the executor: a different number with a creation date inside a
    /// second is a save (a provider may round the date), so it goes back named; a different number
    /// and a date well away is a new item, left. A ledger that recorded neither has only the size,
    /// and size alone never refuses.
    @Test func onlyAClearlyNewItemIsRefused() throws {
        let root = try makeCanonicalTempRoot(prefix: "RestructureIdentity")
        defer { try? FileManager.default.removeItem(at: root) }
        func undo(_ action: RestructureManifest.Action) throws -> FileSyncManager.RestructureExecution {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("A"))
            return FileSyncManager.executeRestructureActions(
                [action], root: root.path, fm: FileManager.default, vetoUnlistedSourceFolders: false,
                restoringMissingParents: true, refusingReplacedItems: true)
        }
        func back(number: Int?, createdOffset: Double?, bytes: Int?) throws -> RestructureManifest.Action {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("B"))
            try Self.write(root.appendingPathComponent("B/f.pdf"), "much longer than before")
            let attributes = try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent("B/f.pdf").path)
            let created = (attributes[.creationDate] as? Date)!.timeIntervalSince1970
            return RestructureManifest.Action(action: .moveFile, src: "B/f.pdf", dst: "A/f.pdf",
                                              bytes: bytes, fileNumber: number,
                                              created: createdOffset.map { created + $0 })
        }
        let rounded = try undo(try back(number: -1, createdOffset: 0.4, bytes: nil))
        #expect(rounded.filesMoved == 1 && rounded.changedSince == ["B/f.pdf"])
        let new = try undo(try back(number: -1, createdOffset: -3_600, bytes: nil))
        #expect(new.filesMoved == 0)
        #expect(new.skipped.first?.contains("B/f.pdf is a different item") == true)
        let old = try undo(try back(number: nil, createdOffset: nil, bytes: 3))
        #expect(old.filesMoved == 1, "an old ledger refused an edited file by its size")
        #expect(old.changedSince == ["B/f.pdf"], "and it is named")
        let untouched = try undo(try back(number: nil, createdOffset: nil,
                                          bytes: "much longer than before".utf8.count))
        #expect(untouched.filesMoved == 1 && untouched.changedSince.isEmpty)
    }

    /// A forward landing never refuses on identity: it is what records it.
    @Test func aLandingRecordsTheIdentityItsUndoChecks() throws {
        let root = try makeCanonicalTempRoot(prefix: "RestructureIdentityForward")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.write(root.appendingPathComponent("B/f.pdf"), "x")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"),
                                                withIntermediateDirectories: true)
        let forward = FileSyncManager.executeRestructureActions(
            [.init(action: .moveFile, src: "B/f.pdf", dst: "A/f.pdf", bytes: 99)],
            root: root.path, fm: FileManager.default, vetoUnlistedSourceFolders: false)
        #expect(forward.filesMoved == 1)
        #expect(forward.performed.first?.fileNumber != nil)
        #expect(forward.performed.first?.created != nil)
    }

    /// Two exports of one name can be two plans: one made before a landing and one after, under the
    /// same date and family. The undo's carry back keeps both, rather than skipping the second by
    /// name and leaving it beside a survey nothing reads.
    @Test func anUndoKeepsBothExportsOfOneName() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let first = try #require(try world.manager.restructureStore?.exportPlan(world.manifest))
        #expect(await world.manager.applyPlan(world.manifest).refusal == nil)
        var second = world.manifest
        second.note = "a second look"
        #expect(try world.manager.restructureStore?.exportPlan(second) == first,
                "premise: the same name")

        #expect(await world.manager.undoReorganisation(
            manifestId: world.manifest.manifestId).refusal == nil)
        let names = try #require(FilingProfileStore.exportedPlanNames(
            inProfile: "t", in: world.profiles, fileManager: FileManager.default))
        let contents = Set(try names.map {
            try Data(contentsOf: world.profiles.appendingPathComponent("t/\($0)")) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        #expect(contents == [try encoder.encode(world.manifest), try encoder.encode(second)],
                "names: \(names)")
    }

    /// ⌘Z of Never Suggest, after the same profile was reopened and a landing recorded into it,
    /// must not write the store captured at the hide over the file the landing wrote. That store is
    /// a snapshot from before the landing; saving it whole would drop the landing's record from the
    /// profile Undo This Reorganization re-points back to.
    @Test func undoingNeverSuggestAfterALandingKeepsTheLandingInTheOldLedger() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        world.manager.undoManager = undo
        world.manager.permanentDeleteConfirmer = { _ in true }
        let finding = StructureFinding(kind: .shape, family: "Tax/Outbound")

        undo.beginUndoGrouping()
        world.manager.suppressStructureFinding(finding)
        undo.endUndoGrouping()
        // A Setup Save beside the hand-built profile: attach reopens the SAME profile's store.
        world.manager.restructureStore = RestructureStore(directory: world.profiles, profileId: "t")

        undo.beginUndoGrouping()
        let outcome = await world.manager.applyPlan(world.manifest)
        undo.endUndoGrouping()
        #expect(outcome.refusal == nil)
        let id = world.manifest.manifestId
        #expect(RestructureStore(directory: world.profiles, profileId: "t").applied
            .contains { $0.manifest.manifestId == id }, "premise: the landing is in t's ledger")

        undo.undo()     // the landing's moves
        for _ in 0..<600 where world.manager.activeFileOperationsCount > 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        undo.undo()     // the hide
        let old = RestructureStore(directory: world.profiles, profileId: "t")
        #expect(old.applied.contains { $0.manifest.manifestId == id },
                "the hide's store wrote its pre-landing state over t/restructure.json")
        #expect(!old.isSuppressed(RestructureKey(finding)))
        #expect(world.manager.restructureStore?.isSuppressed(RestructureKey(finding)) == false,
                "the finding comes back in the store the app reads")
    }

    /// The same-name-subfolder merge the planner derives must land whole. The subfolder is never a
    /// move src, only its files are, so a veto that called it "unlisted" would skip its parent and
    /// half-land every merge of this shape.
    @Test func aSameNameSubfolderMergeLandsWhole() async throws {
        let base = try makeCanonicalTempRoot(prefix: "RestructureApplyMerge")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Documents")
        try Self.write(root.appendingPathComponent("F/2016/Payment/p.pdf"), "p")
        try Self.write(root.appendingPathComponent("F/2016/Payment/Receipts/r1.pdf"), "r1")
        try Self.write(root.appendingPathComponent("F/2016/Payments/Receipts/r2.pdf"), "r2")

        let manifest = try RestructurePlanner.manifest(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [.init(source: "Payment", target: "Payments")]),
            kind: .shape, in: .fromDisk(root: root),
            profileId: "t", manifestId: "merge-1", createdAt: "t").get()
        let execution = FileSyncManager.executeRestructureActions(
            manifest.actions, root: root.path, fm: FileManager.default)

        #expect(execution.skipped.isEmpty,
                "nothing in this plan is drift — the veto must credit deeper actions")
        let fm = FileManager.default
        #expect(fm.fileExists(
            atPath: root.appendingPathComponent("F/2016/Payments/p.pdf").path))
        #expect(fm.fileExists(
            atPath: root.appendingPathComponent("F/2016/Payments/Receipts/r1.pdf").path))
        #expect(fm.fileExists(
            atPath: root.appendingPathComponent("F/2016/Payments/Receipts/r2.pdf").path))
    }

    /// The removal step's "still empty" is recursive: a drained folder whose only remainder is an
    /// equally drained subfolder goes to the Trash whole. A shallow item count would call it "not
    /// empty", and both would linger.
    @Test func aDrainedFolderWithAnEmptyDrainedSubfolderIsRemovable() async throws {
        let base = try makeCanonicalTempRoot(prefix: "RestructureApplyEmpty")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = ScratchTrash(in: base)
        let root = base.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("F/Payment/Receipts"),
            withIntermediateDirectories: true)
        #expect(FileSyncManager.visibleFileCount(
            atPath: root.appendingPathComponent("F/Payment").path,
            fm: FileManager.default) == 0)

        let manifest = RestructureManifest(
            profileId: "t", manifestId: "rm-1", createdAt: "t", family: "F", kind: .deadWeight,
            actions: [.init(action: .removeEmptyDir, src: "F/Payment")])
        let execution = FileSyncManager.executeRestructureActions(
            manifest.actions, root: root.path, fm: trash)
        #expect(execution.removedEmpty == 1)
        #expect(execution.skipped.isEmpty)
        #expect(trash.names == ["Payment"],
                "the drained folder left the tree but never reached the test's own Trash")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("F/Payment").path))

        // And one visible file anywhere beneath still refuses — no file is ever deleted.
        try Self.write(root.appendingPathComponent("F/Other/Sub/real.pdf"), "real")
        let refused = FileSyncManager.executeRestructureActions(
            [.init(action: .removeEmptyDir, src: "F/Other")], root: root.path,
            fm: trash)
        #expect(refused.removedEmpty == 0)
        #expect(refused.skipped.contains { $0.contains("still holds 1 file") })

        // A hidden directory's contents are content: `.git/config` refuses the removal though its
        // container is dotted, since `.skipsHiddenFiles` would prune the subtree and read a whole
        // repository as empty. Only dot-named files themselves are junk.
        try Self.write(root.appendingPathComponent("F/Repo/.git/config"), "[core]")
        try Self.write(root.appendingPathComponent("F/Junk/Sub/.DS_Store"), "junk")
        #expect(FileSyncManager.visibleFileCount(
            atPath: root.appendingPathComponent("F/Repo").path, fm: FileManager.default) == 1)
        #expect(FileSyncManager.visibleFileCount(
            atPath: root.appendingPathComponent("F/Junk").path, fm: FileManager.default) == 0)
        let repo = FileSyncManager.executeRestructureActions(
            [.init(action: .removeEmptyDir, src: "F/Repo")], root: root.path,
            fm: trash)
        #expect(repo.removedEmpty == 0, "a repository is not an empty folder")
    }

    /// A folder holding only dot-files the user keeps is not empty: `.env`, `.gitignore`
    /// and an office suite's `.~lock…#` are files, and the removal's inverse is a bare
    /// `create-dir` that cannot bring them back. Only OS noise is ignorable — `.DS_Store` and
    /// kin, including a `.Trashes` directory with whatever the OS wrote into it.
    @Test func aFolderHoldingOnlyUserDotFilesIsNotRemovedAsEmpty() async throws {
        let base = try makeCanonicalTempRoot(prefix: "RestructureApplyDotFiles")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = ScratchTrash(in: base)
        let root = base.appendingPathComponent("Documents")
        try Self.write(root.appendingPathComponent("F/Config/.env"), "TOKEN=x")
        try Self.write(root.appendingPathComponent("F/Config/.DS_Store"), "junk")
        try Self.write(root.appendingPathComponent("F/Noise/.DS_Store"), "junk")
        try Self.write(root.appendingPathComponent("F/Noise/Sub/.localized"), "")
        try Self.write(root.appendingPathComponent("F/Noise/.Trashes/501/old.pdf"), "os")

        #expect(FileSyncManager.visibleFileCount(
            atPath: root.appendingPathComponent("F/Config").path, fm: FileManager.default) == 1)
        let kept = FileSyncManager.executeRestructureActions(
            [.init(action: .removeEmptyDir, src: "F/Config")], root: root.path, fm: trash)
        #expect(kept.removedEmpty == 0, "a folder holding .env is not empty")
        #expect(kept.skipped.contains { $0.contains("F/Config/ still holds 1 file") })
        #expect(trash.names.isEmpty, "nothing reached the Trash")
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("F/Config/.env").path))

        // The control: OS noise alone still reads empty and still goes, so the refusal above is
        // about `.env`, not about dot-files in general being newly counted.
        #expect(FileSyncManager.visibleFileCount(
            atPath: root.appendingPathComponent("F/Noise").path, fm: FileManager.default) == 0)
        let removed = FileSyncManager.executeRestructureActions(
            [.init(action: .removeEmptyDir, src: "F/Noise")], root: root.path, fm: trash)
        #expect(removed.removedEmpty == 1)
        #expect(trash.names == ["Noise"])
    }

    /// A rename skipped because its destination appeared takes the merges planned into that
    /// destination with it. The skip sentence promises the folder was not "merged unreviewed", so
    /// merges that consult only the unlisted-file veto must not land in it.
    @Test func aRenameRefusedAsDriftRefusesTheMergesHeadedIntoIt() async throws {
        let base = try makeCanonicalTempRoot(prefix: "RestructureApplyRefusedRename")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = ScratchTrash(in: base)
        let root = base.appendingPathComponent("Documents")
        try Self.write(root.appendingPathComponent("Tax/Form W2/a.pdf"), "a")
        try Self.write(root.appendingPathComponent("Tax/Form-W2/b.pdf"), "b")
        let actions: [RestructureManifest.Action] = [
            .init(action: .renameDir, src: "Tax/Form W2", dst: "Tax/Form W-2"),
            .init(action: .moveFile, src: "Tax/Form-W2/b.pdf", dst: "Tax/Form W-2/b.pdf"),
            .init(action: .createDir, dst: "Tax/Form W-2/2024"),
        ]
        // The drift: a `Form W-2/` synced in between plan and apply.
        try Self.write(root.appendingPathComponent("Tax/Form W-2/theirs.pdf"), "theirs")

        let execution = FileSyncManager.executeRestructureActions(actions, root: root.path,
                                                                  fm: trash)
        #expect(execution.renamed == 0)
        #expect(execution.filesMoved == 0, "a merge landed in the folder the rename refused")
        #expect(execution.created == 0)
        #expect(execution.performed.isEmpty)
        #expect(execution.skipped.contains { $0.contains("the rename of Tax/Form W2/ was skipped") })
        #expect(execution.skipped.contains {
            $0.hasPrefix("Tax/Form-W2/b.pdf was planned against Tax/Form W-2/")
        })
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Tax/Form-W2/b.pdf").path))
        #expect(Self.treeList(root.appendingPathComponent("Tax/Form W-2")) == "/theirs.pdf",
                "the foreign folder must be left exactly as it arrived")
    }

    /// A vetoed folder is skipped whole, in both directions, as the invariant-2 sentence ("left
    /// untouched") promises. A per-parent veto key alone would let a one-level-down merge drain
    /// `S/Sub` and a later group's arrivals merge into the vetoed folder unreviewed. Deleting
    /// either `vetoedAncestor` check must fail one half of this.
    @Test func aVetoedFolderIsSkippedWholeInBothDirections() async throws {
        let base = try makeCanonicalTempRoot(prefix: "RestructureApplyVeto")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Documents")
        try Self.write(root.appendingPathComponent("F/S/planned.pdf"), "planned")
        try Self.write(root.appendingPathComponent("F/S/surprise.pdf"), "unlisted")
        try Self.write(root.appendingPathComponent("F/S/Sub/g.pdf"), "sub")
        try Self.write(root.appendingPathComponent("F/X/x.pdf"), "x")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("F/T"), withIntermediateDirectories: true)

        let actions: [RestructureManifest.Action] = [
            // The first move out of S trips the veto: surprise.pdf is unlisted.
            .init(action: .moveFile, src: "F/S/planned.pdf", dst: "F/T/planned.pdf"),
            // OUT of the vetoed subtree, one level down.
            .init(action: .moveFile, src: "F/S/Sub/g.pdf", dst: "F/T/g.pdf"),
            // INTO the vetoed folder.
            .init(action: .moveFile, src: "F/X/x.pdf", dst: "F/S/x.pdf"),
        ]
        let execution = FileSyncManager.executeRestructureActions(
            actions, root: root.path, fm: FileManager.default)

        #expect(execution.filesMoved == 0, "the veto covers all three")
        #expect(execution.skipped.contains { $0.contains("F/S/") && $0.contains("surprise.pdf") },
                "the veto itself, named")
        #expect(execution.skipped.contains { $0.contains("F/S/Sub/g.pdf") },
                "the subtree half: nothing drains beneath a vetoed folder")
        #expect(execution.skipped.contains {
            $0.contains("F/X/x.pdf") && $0.contains("headed into")
        }, "the into half: nothing lands in a vetoed folder")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("F/S/Sub/g.pdf").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("F/X/x.pdf").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("F/S/x.pdf").path))
    }

    // MARK: - Retiring superseded profiles, end to end

    private static func profileIds(in profiles: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: profiles.path)) ?? [])
            .filter { name in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: profiles.appendingPathComponent(name).path, isDirectory: &isDir)
                    && isDir.boolValue
            }.sorted()
    }

    /// Repeated refreshes don't pile up: each mints a profile directory, and the retire step
    /// removes the one it supersedes. Two refreshes here leave the hand-built fixture and the
    /// newest derived profile, and nothing in between.
    @Test func repeatedRefreshesLeaveOneDerivedProfileBehind() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        #expect(Self.profileIds(in: world.profiles) == ["t"])

        let first = await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_500_000))
        #expect(first.refusal == nil)
        let afterFirst = Self.profileIds(in: world.profiles)
        #expect(afterFirst.count == 2, "the hand-built fixture plus one derived: \(afterFirst)")

        let second = await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_500_100))
        #expect(second.refusal == nil)
        let afterSecond = Self.profileIds(in: world.profiles)
        #expect(afterSecond.count == 2,
                "the first refresh's profile should have been retired: \(afterSecond)")
        #expect(afterSecond.contains("t"), "the hand-built fixture must never be retired")
        // The one that survives is the one the app is now reading.
        let active = try #require(FilingProfileStore.activeProfileId(in: world.profiles))
        #expect(afterSecond.contains(active))
        #expect(world.manager.filingProfileDirectoryId == active)
        // And the index agrees with the disk — no rows naming profiles that are gone.
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: world.profiles.appendingPathComponent("profiles.json")))
            as? [String: Any])
        let rows = try #require(object["profiles"] as? [[String: Any]])
        #expect(rows.compactMap { $0["profileId"] as? String }.sorted() == afterSecond)
    }

    /// A plan written by Export Plan survives "Update the survey". It sits in the profile's folder,
    /// so the refresh must carry it, or the retire sweep removes it with the old folder,
    /// permanently.
    @Test func anExportedPlanFollowsTheSurveyThroughARefresh() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        // One refresh first, so the folder the export sits in is a DERIVED one the sweep may
        // retire — the hand-built fixture is kept on its own rule.
        #expect(await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_500_000)).refusal == nil)
        let exportedIn = try #require(world.manager.filingProfileDirectoryId)
        let name = try #require(try world.manager.restructureStore?.exportPlan(world.manifest))
        let contents = try Data(contentsOf: world.profiles.appendingPathComponent("\(exportedIn)/\(name)"))

        #expect(await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_500_100)).refusal == nil)
        let active = try #require(world.manager.filingProfileDirectoryId)
        #expect(active != exportedIn)
        #expect(!Self.profileIds(in: world.profiles).contains(exportedIn),
                "the folder it was exported into is retired once the plan has moved on")
        #expect(try Data(contentsOf: world.profiles.appendingPathComponent("\(active)/\(name)"))
                == contents, "the exported plan is beside the survey the app now reads")
    }

    /// The sweep's side: a folder holding an export the active folder lacks (a carry that failed)
    /// is kept, the way it keeps one holding the only roster. It keeps an export by its contents,
    /// not its name: the active folder holding a different plan under the same name does not make
    /// this one disposable.
    @Test func aSameNamedExportElsewhereDoesNotRetireThisOne() async throws {
        final class SwitchableExportCopy: FileManager, @unchecked Sendable {
            nonisolated(unsafe) var refusing = true
            override func copyItem(at srcURL: URL, to dstURL: URL) throws {
                if refusing, srcURL.lastPathComponent.hasPrefix("restructure-") {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try super.copyItem(at: srcURL, to: dstURL)
            }
        }
        let fm = SwitchableExportCopy()
        let world = try await Self.makeWorld(fileManager: { _ in fm })
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        #expect(await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_500_000)).refusal == nil)
        let first = try #require(world.manager.filingProfileDirectoryId)
        let name = try #require(try world.manager.restructureStore?.exportPlan(world.manifest))
        // The carry fails, so the first folder holds the only copy and is kept.
        #expect(await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_500_100)).refusal == nil)
        #expect(world.manager.filingProfileDirectoryId != first)
        #expect(FileManager.default.fileExists(
            atPath: world.profiles.appendingPathComponent("\(first)/\(name)").path),
                "the only copy of the exported plan was deleted with its folder")
        // Another plan exported under the same name in the folder now active.
        var other = world.manifest
        other.note = "another plan"
        #expect(try world.manager.restructureStore?.exportPlan(other) == name)
        fm.refusing = false
        #expect(await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_500_200)).refusal == nil)

        #expect(FileManager.default.fileExists(
            atPath: world.profiles.appendingPathComponent("\(first)/\(name)").path),
                "the first plan was deleted because the active folder held another of its name")
    }

    /// A landing that can still be undone pins the profile it was applied under. Undo re-points at
    /// `appliedUnderProfileId` and `repointActiveProfile` requires that profile on disk, so
    /// retiring it would make a reversible reorganisation permanent.
    ///
    /// It refreshes before it applies, and that ordering is the test. Applied straight to the
    /// fixture, the undo target is `t`, hand-built and protected by its own provenance rule, so the
    /// test would pass with the whole `appliedUnderProfileId` loop deleted. One refresh first makes
    /// the undo target a derived profile, superseded by the next refresh, kept only by the ledger.
    @Test func aRefreshAfterALandingKeepsWhatUndoNeeds() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }

        // t → d1. The landing below is applied under d1, which is derived and retirable.
        #expect(await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_499_000)).refusal == nil)
        let undoTarget = try #require(world.manager.filingProfileDirectoryId)
        #expect(undoTarget != "t", "the undo target must be a derived profile for this to test anything")

        let applied = await world.manager.applyPlan(
            world.manifest, now: Date(timeIntervalSince1970: 1_756_500_000))
        #expect(applied.refusal == nil)
        let record = try #require(world.manager.restructureStore?.applied.first)
        #expect(record.appliedUnderProfileId == undoTarget)

        // A refresh on top of the landing — the sequence that would strand the undo.
        #expect(await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_500_200)).refusal == nil)

        #expect(Self.profileIds(in: world.profiles).contains(undoTarget),
                "the profile the landing was applied under was retired — its undo is now dead")
        #expect(FilingProfileStore.profile(id: undoTarget, in: world.profiles) != nil,
                "repointActiveProfile would refuse: the target is not readable on disk")
    }

    /// A re-derivation reads the household file, not the profile's leftovers.
    /// `PersonRegistry.seeded(from:)` is `FilingProfileStore.personRegistry`'s fallback for a
    /// machine with no `people.json`. Called directly, it would rebuild the person axis from
    /// whatever aliases the last profile kept, and `carryOver` writes that axis back, so the loss
    /// would compound with each refresh. The alias here is one the profile axis does not carry: it
    /// can only reach the re-derived profile by way of `people.json`.
    @Test func aReDerivationSeedsPeopleFromTheHouseholdFile() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let active = try #require(world.manager.filingProfileDirectoryId)
        #expect(world.manager.filingFolderProfile?.personAliases.isEmpty == true,
                "the fixture's profile axis must carry no aliases, or this proves nothing")

        try Data(#"{"people": [{"id": "elder", "displayName": "Elder", "aliases": ["Dad"]}]}"#.utf8)
            .write(to: world.profiles.appendingPathComponent("\(active)/people.json"))

        #expect(await world.manager.refreshDerivedProfile(
            now: Date(timeIntervalSince1970: 1_756_501_000)).refusal == nil)

        let derived = try #require(world.manager.filingFolderProfile)
        #expect(derived.personTokens.contains("elder"),
                "the household's person never reached the re-derived profile")
        #expect(derived.personAliases["dad"] == "elder",
                "the alias only people.json knows was dropped — the fallback registry was used")
    }
    // MARK: - Step 4's verdict, and step 7's memory

    /// The verifier's verdict reaches the outcome and the ledger. The verify runs through the same
    /// serial file-operation queue the executor used, not the main actor, so it reads the tree
    /// strictly after the moves and before anything else the app does to it, and is awaited. A
    /// correct landing has nothing to report, so a call replaced with `[]` would keep every
    /// green-path test green. This drives the unhappy branch, a file manager with a hole where the
    /// carried `Refund/` lands, and checks the mismatch on the outcome, in the log-bound list, and
    /// in the ledger record the Applied card reads.
    @Test func theVerifiersVerdictReachesTheOutcomeAndTheLedger() async throws {
        let world = try await Self.makeWorld {
            Self.HidingFileManager(hiding: ["Tax/2013/Forms/Refund"], over: $0)
        }
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }

        let outcome = await world.manager.applyPlan(
            world.manifest, now: Date(timeIntervalSince1970: 1_756_500_000))

        #expect(outcome.refusal == nil, "the landing itself must still run")
        #expect(outcome.foldersMovedWhole == 1, "Refund really was carried")
        #expect(outcome.verifierMismatches.contains { $0.contains("Tax/2013/Forms/Refund") },
                "the verifier must name the folder it could not find: \(outcome.verifierMismatches)")

        let store = try #require(world.manager.restructureStore)
        let record = try #require(store.applied.first {
            $0.manifest.manifestId == world.manifest.manifestId
        })
        #expect(record.verifiedOK == false, "the card's verdict must carry the mismatch")
        #expect(record.verifierNote?.isEmpty == false)
        // And the folder really is on disk — the hole is in the probe, not in the tree, so this
        // is a test of the reporting path rather than of a broken landing.
        #expect(FileManager.default.fileExists(
            atPath: world.root.appendingPathComponent("Tax/2013/Forms/Refund").path))
    }
}
