import CryptoKit
import Foundation
import Testing
@testable import Sync

/// §5.5's proof paragraph, as tests: one apply against a real temporary tree in which the disk
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

    /// One content hash over the whole tree — paths and bytes, sorted — so "restored" means
    /// byte-identical, not same-sized (the 6 Aug rule the roadmap cites).
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

    /// The flagship-shaped fixture: an era to converge (rename + merge + a seeded collision), a
    /// keep, a refused folder with its reason, and a Singapore folder for the jurisdiction rule.
    static func makeWorld() async throws -> World {
        let base = try makeCanonicalTempRoot(prefix: "RestructureApply")
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

        let manager = FileSyncManager()
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
        return World(manager: manager, root: root, profiles: profiles, manifest: manifest)
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
        #expect(movedAction.md5?.count == 32)
        #expect(record.summary == outcome.summary)
        #expect(!record.manifest.actions.contains {
            $0.src?.contains("ca-540") == true || $0.src?.contains("Payment/") == true
        }, "skipped actions are not in the landed manifest — its inverse must not reverse them")
    }

    /// Step 6 and 7: the derived profile is active under a fresh id with the chain recorded, the
    /// judgements carried — for a surviving refused folder AND for the renamed one — Singapore
    /// survives via the entries, the corpus key moved without its stamp, and the fingerprint moved.
    @Test func theProfileFollowsTheTreeAndTheJudgementsFollowTheProfile() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let fingerprintBefore = FilingProfileStore.fingerprint(id: "t", in: world.profiles)

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        #expect(outcome.surveyRefreshFailure == nil)
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

    // MARK: - The two undos

    /// ⌘Z restores a byte-identical tree — hash it, do not size it (6 Aug).
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
        let reborn = FileSyncManager()
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

        let blocked = await world.manager.undoReorganisation(
            manifestId: world.manifest.manifestId)
        #expect(blocked.refusal?.contains("later reorganisation") == true)

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
    /// re-derive failed never re-pointed the survey, so an id comparison cannot see it sitting
    /// on top — and the first gate happily undid the older landing straight through it.
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
        #expect(blocked.refusal?.contains("later reorganisation") == true)

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

    /// The same-name-subfolder merge the planner itself derives must land whole: the subfolder
    /// is never a move src — only its files are — and the first veto called it "unlisted" and
    /// skipped its parent, half-landing every merge of this shape with a false sentence.
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

    /// The removal step's "still empty" is recursive: a drained folder whose only remainder is
    /// an equally drained subfolder goes to the Trash whole — the shallow items-count probe
    /// called it "not empty" over an empty subfolder, and both lingered forever.
    @Test func aDrainedFolderWithAnEmptyDrainedSubfolderIsRemovable() async throws {
        let base = try makeCanonicalTempRoot(prefix: "RestructureApplyEmpty")
        defer { try? FileManager.default.removeItem(at: base) }
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
            manifest.actions, root: root.path, fm: FileManager.default)
        #expect(execution.removedEmpty == 1)
        #expect(execution.skipped.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("F/Payment").path))

        // And one visible file anywhere beneath still refuses — no file is ever deleted.
        try Self.write(root.appendingPathComponent("F/Other/Sub/real.pdf"), "real")
        let refused = FileSyncManager.executeRestructureActions(
            [.init(action: .removeEmptyDir, src: "F/Other")], root: root.path,
            fm: FileManager.default)
        #expect(refused.removedEmpty == 0)
        #expect(refused.skipped.contains { $0.contains("still holds 1 file") })

        // A hidden DIRECTORY'S contents are content: `.git/config` refuses the removal even
        // though its container is dotted — `.skipsHiddenFiles` pruned the whole subtree and
        // read a full repository as "still empty". Only dot-named files themselves are junk.
        try Self.write(root.appendingPathComponent("F/Repo/.git/config"), "[core]")
        try Self.write(root.appendingPathComponent("F/Junk/Sub/.DS_Store"), "junk")
        #expect(FileSyncManager.visibleFileCount(
            atPath: root.appendingPathComponent("F/Repo").path, fm: FileManager.default) == 1)
        #expect(FileSyncManager.visibleFileCount(
            atPath: root.appendingPathComponent("F/Junk").path, fm: FileManager.default) == 0)
        let repo = FileSyncManager.executeRestructureActions(
            [.init(action: .removeEmptyDir, src: "F/Repo")], root: root.path,
            fm: FileManager.default)
        #expect(repo.removedEmpty == 0, "a repository is not an empty folder")
    }
}

