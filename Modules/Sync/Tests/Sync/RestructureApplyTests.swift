import Combine
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

    /// A real `FileManager` with a hole in it: one path that `fileExists(atPath:)` denies.
    ///
    /// The landing's verifier re-lists the touched folders through the manager's OWN file
    /// manager, so a hole here is a mismatch the verifier must find and report — which is how a
    /// test can drive the unhappy branch on a tree the executor moves correctly. Everything else
    /// is passed straight through, including the two-argument existence probe the executor uses
    /// for directories, so nothing else in the landing behaves differently.
    final class HidingFileManager: FileManaging, @unchecked Sendable {
        let hidden: Set<String>
        private let inner: FileManager
        init(hiding: Set<String>, over inner: FileManager) {
            hidden = hiding
            self.inner = inner
        }

        func fileExists(atPath path: String) -> Bool {
            hidden.contains(where: { path.hasSuffix($0) }) ? false : inner.fileExists(atPath: path)
        }
        func fileExists(atPath path: String,
                        isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: path, isDirectory: isDirectory)
        }
        func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            try inner.attributesOfItem(atPath: path)
        }
        func setAttributes(_ attributes: [FileAttributeKey: Any],
                           ofItemAtPath path: String) throws {
            try inner.setAttributes(attributes, ofItemAtPath: path)
        }
        func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                             attributes: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: url, withIntermediateDirectories: createIntermediates,
                                      attributes: attributes)
        }
        func copyItem(at srcURL: URL, to dstURL: URL) throws {
            try inner.copyItem(at: srcURL, to: dstURL)
        }
        func moveItem(at srcURL: URL, to dstURL: URL) throws {
            try inner.moveItem(at: srcURL, to: dstURL)
        }
        func trashItem(at url: URL,
                       resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: url, resultingItemURL: outResultingURL)
        }
        func removeItem(at URL: URL) throws { try inner.removeItem(at: URL) }
        func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL,
                         backupItemName: String) throws -> URL? {
            try inner.replaceItem(at: destinationURL, withItemAt: stagedURL,
                                  backupItemName: backupItemName)
        }
        func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                        options mask: FileManager.DirectoryEnumerationOptions,
                        errorHandler handler: ((URL, Error) -> Bool)?)
            -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask,
                             errorHandler: handler)
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
        // **No digest, and that is the point.** The apply used to MD5 every moved file (up to
        // 64 MB each) to fill this field — a gigabyte read for a 500-file merge, inside the
        // window where the landing flag refuses every other scan — and nothing anywhere read the
        // result back; this assertion, checking it had 32 characters, was its only consumer. The
        // field survives on `Action` so ledgers already on disk keep decoding theirs. `bytes`
        // above is the audit fact that stayed, and it comes free from the `attributesOfItem`
        // call the move already makes.
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

    /// **Step 4's verdict reaches the ledger.** The card's sentence is a pure rule with its own
    /// tests; what had none was the write — deleting `$0.verifiedOK = ...` from the finalize left
    /// every card silent about verification with the suite green, because `nil` is also what a
    /// record written before the field existed carries. A clean landing must say so positively.
    @Test func theLedgerRecordsStepFoursVerdict() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)
        #expect(outcome.verifierMismatches.isEmpty, "this fixture lands cleanly")

        let record = try #require(world.manager.restructureStore?.applied.first)
        #expect(record.verifiedOK == true,
                "a clean landing records agreement, not silence")
        #expect(record.verifierNote == nil, "and has nothing to point at")
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

        // The note the record would carry — the card's own rendering of it is the lens's test.
        // One mismatch is stated bare; several add the count and point at the log, so both
        // shapes are checked here rather than only whichever this fixture happens to produce.
        let note = try #require(FileSyncManager.verifierNote(mismatches))
        #expect(note == mismatches[0], "a single disagreement is stated as itself")
        let many = try #require(FileSyncManager.verifierNote(mismatches + ["B/y.pdf is missing"]))
        #expect(many.contains("1 more"), "and several name the count")
        #expect(many.contains("log"), "pointing the reader where the rest is")
    }

    /// **The engine visits the stages in the order the checklist draws them**, and clears the
    /// value when it is done. The suite next door pins the enum's declaration order, which is a
    /// different claim: it would still pass with `applyPlan` publishing `verify` before
    /// `inverse`, or never publishing at all. This subscribes to the real landing.
    @Test func theLandingPublishesItsStagesInOrderAndThenClearsThem() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }

        var seen: [RestructureApplyProgress.Stage] = []
        let sink = world.manager.$restructureApplyProgress.sink { progress in
            if let stage = progress?.stage, seen.last != stage { seen.append(stage) }
        }
        defer { sink.cancel() }

        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)

        #expect(seen == seen.sorted(), "a checklist that went backwards would be unreadable")
        #expect(seen.contains(.inverse))
        #expect(seen.contains(.operations))
        let inverse = try #require(seen.firstIndex(of: .inverse))
        let operations = try #require(seen.firstIndex(of: .operations))
        #expect(inverse < operations,
                "the inverse is announced before the first file moves — the trust §5.5 paid for")
        #expect(world.manager.restructureApplyProgress == nil,
                "and nothing is left showing a checklist over a finished landing")
    }

    /// **A landing stamps O16's line, marked as one.** The store's dedupe and the chart's rules
    /// have their own tests; what neither can see is whether `applyPlan` ever calls the stamp —
    /// deleting the call left a trend that only ever grew at launch, with every landing invisible
    /// on a line whose entire point is showing what caused the drops.
    @Test func aLandingStampsTheTrendAndMarksItself() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let outcome = await world.manager.applyPlan(world.manifest)
        #expect(outcome.refusal == nil)

        // The store the landing produced — the re-derive replaced it, so read it from the
        // manager rather than the one the world handed over.
        let stamped = try #require(world.manager.restructureStore?.trend.last)
        #expect(stamped.landing, "the point a landing produced carries its cause")
        #expect(stamped.profileId == world.manager.filingProfileDirectoryId)
        // **Not `stamped.total == structureFindings.count`.** Both are zero on this fixture —
        // the landing resolves the only finding, which is the right outcome for the landing and
        // a vacuous assertion for a counter. What the counts contain is
        // `RestructureTrendStampTests` next door, against a profile that fires. What only THIS
        // test can say is that the landing produced a point at all, under the profile it
        // produced, marked as a landing.
        #expect(stamped.countsByKind.values.allSatisfy { $0 > 0 },
                "a kind with none is absent, never a zero")
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

    /// What the user made after a landing survives that landing's Undo (FR7). Undo re-points to
    /// the folder the landing started from and re-opens every store there, so a person added, a
    /// verdict given or a finding suppressed afterwards stayed in the produced folder and was
    /// read by nothing. They come back with the survey — the suppression rekeyed through the
    /// renames the undo performed — and the ledger still says the landing is undone.
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

    /// A quit while the survey is re-derived must not take the landing's Undo with it (FR17).
    /// `profiles.json` names the new folder before the corpus replay's seconds-long wait; the
    /// ledger used to reach that folder only inside the wait, and its `producedProfileId` after
    /// it — so the disk at that moment, read the way a relaunch reads it, offered no Undo.
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
    /// the app goes on reading (FR5). The stores used to stay open on the OLD folder until after
    /// that wait — so a person added or a verdict given in it was written there, after the copy
    /// into the new folder had already been taken, and read by nothing afterwards.
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

    /// A stopped document survey can still be carried on after a landing and after a refresh
    /// (FR6). Its progress lived only in the old profile folder: the app moved to a folder with
    /// none, the next survey started from 0, and the retire sweep later deleted the old folder.
    /// A copy would not do either — the checkpoint names its profile and keys what it read by
    /// paths the landing just moved — so it is rekeyed like the corpus.
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

    /// ⌘Q's count sees the re-derive (FR17): no file operation is queued through it, so the
    /// guard's old count read zero and let a quit through in silence.
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

    /// FR17's reorder, followed up: a quit during a survey refresh's corpus replay must not cost
    /// the survey. The index names the new folder before the replay, and the refresh re-points
    /// the undo chain there too, so the folder left behind — the only one holding the corpus and
    /// the memory — is named by no record; its curated files were carried, so the old "only copy"
    /// guard no longer kept it, and the next sweep deleted it, permanently.
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

    /// The same cut for a stopped first survey (FR6): its progress is carried inside the replay,
    /// so at the cut the only copy is in the folder left behind.
    @Test func aQuitDuringASurveyRefreshsReplayKeepsAStoppedSurveysProgress() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let folder = try #require(world.manager.documentSurveyFolder)
        let (disk, left) = try await cutASurveyRefreshBeforeItsReplay(world) { left in
            // A first survey stopped part-way: progress, and no corpus or memory yet.
            try FileManager.default.removeItem(at: FilingSurveyStore.corpusURL(id: left, in: world.profiles))
            try FileManager.default.removeItem(at: FilingSurveyStore.memoryURL(id: left, in: world.profiles))
            try DocumentSurveyCheckpointStore.write(DocumentSurveyCheckpoint(
                profileId: left, rootPath: folder.path, salt: "s",
                plan: ["Tax/Outbound/o.pdf"], nextIndex: 0, read: [:], documentsUnavailable: 0,
                startedAt: Date(timeIntervalSince1970: 1_760_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_760_000_100)), id: left, in: world.profiles)
        }
        let active = try #require(FilingProfileStore.activeProfileId(in: disk))
        try #require(DocumentSurveyCheckpointStore.read(id: active, in: disk).checkpoint == nil,
                     "the cut must be before the progress was carried")

        try sweepAsTheNextReDeriveWould(disk, sparing: left)
        #expect(DocumentSurveyCheckpointStore.read(id: left, in: disk).checkpoint?.profileId == left,
                "the sweep deleted the only copy of the stopped survey's progress")
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

    /// FR16. A landing cut off mid-run is refused by Undo, and the refusal used to send the user to
    /// a log that recorded nothing per action. It names the landing's journal instead when one is
    /// there — and says plainly when none is.
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

    /// A finished landing leaves no running list behind: the ledger record says what ran.
    @Test func aFinishedLandingRemovesItsJournal() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        let profileId = try #require(world.manager.filingProfileDirectoryId)
        let outcome = await world.manager.applyPlan(world.manifest, now: Date(timeIntervalSince1970: 1_756_500_000))
        #expect(outcome.refusal == nil)
        let journal = RestructureLandingJournal.url(manifestId: world.manifest.manifestId,
                                                    profileId: profileId, in: world.profiles)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    /// FR16. The journal goes only once the finalised record is ON DISK. When the finalising
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

    final class LedgerBreakingDisk: FileManaging, @unchecked Sendable {
        private let inner: FileManager
        private let breaker: LedgerBreaker
        init(over inner: FileManager, breaker: LedgerBreaker) {
            self.inner = inner
            self.breaker = breaker
        }
        func fileExists(atPath path: String) -> Bool { inner.fileExists(atPath: path) }
        func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: path, isDirectory: isDirectory)
        }
        func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            try inner.attributesOfItem(atPath: path)
        }
        func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
            try inner.setAttributes(attributes, ofItemAtPath: path)
        }
        func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                             attributes: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: url, withIntermediateDirectories: createIntermediates,
                                      attributes: attributes)
        }
        func copyItem(at srcURL: URL, to dstURL: URL) throws { try inner.copyItem(at: srcURL, to: dstURL) }
        func moveItem(at srcURL: URL, to dstURL: URL) throws {
            breaker.breakOnce()
            try inner.moveItem(at: srcURL, to: dstURL)
        }
        func trashItem(at url: URL,
                       resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: url, resultingItemURL: outResultingURL)
        }
        func removeItem(at URL: URL) throws { try inner.removeItem(at: URL) }
        func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL,
                         backupItemName: String) throws -> URL? {
            try inner.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
        }
        func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                        options mask: FileManager.DirectoryEnumerationOptions,
                        errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
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

    /// The ledger Undo after the person hand-trashed a folder the merge emptied (FR20). The
    /// move-back into the missing folder used to fail, the rename-back after it succeeded, and
    /// every merged file rode it into a folder it never lived in — under a record marked undone.
    /// The missing folder is the one each file came out of, so it is recreated and the tree
    /// comes back byte for byte.
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
            fm: trash)
        #expect(repo.removedEmpty == 0, "a repository is not an empty folder")
    }

    /// A folder holding only dot-files the USER keeps is not empty (FR18): `.env`, `.gitignore`
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

    /// A rename skipped because its destination appeared takes the merges planned INTO that
    /// destination with it (FR19). The skip sentence promises the folder was not "merged
    /// unreviewed"; the merges, which only consulted the unlisted-file veto, landed in it anyway.
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

    /// A vetoed folder is skipped WHOLE, in both directions: the invariant-2 sentence says
    /// "left untouched", and the per-parent veto key alone made it a lie — a one-level-down
    /// merge drained `S/Sub` right after the sentence promised `S/` was untouched, and a later
    /// group's arrivals merged INTO the vetoed folder unreviewed. Delete either
    /// `vetoedAncestor` check and one half of this goes red.
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
            // OUT of the vetoed subtree, one level down — used to drain anyway.
            .init(action: .moveFile, src: "F/S/Sub/g.pdf", dst: "F/T/g.pdf"),
            // INTO the vetoed folder — used to land anyway.
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

    /// **Repeated refreshes stop piling up.** Each one mints a profile directory and, until the
    /// retire step, nothing removed the last — eight profiles and 90 MB accumulated in a single
    /// evening on the real machine. Two refreshes here leave the hand-built fixture and the newest
    /// derived profile, and nothing in between.
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

    /// **A landing that can still be undone pins the profile it was applied under.** Undo
    /// re-points at `appliedUnderProfileId` and `repointActiveProfile` requires that profile to
    /// be on disk, so retiring it would turn a reversible reorganisation into a permanent one —
    /// which is the failure this whole area exists to prevent.
    ///
    /// **It refreshes BEFORE it applies, and that ordering is the entire test.** Applied straight
    /// to the fixture, the undo target is `t` — hand-built, which the store protects on its own
    /// provenance rule — so the ledger's contribution is never exercised and the test passes with
    /// the whole `appliedUnderProfileId` loop deleted. Verified by doing exactly that. One refresh
    /// first makes the undo target a DERIVED profile, superseded by the refresh that follows,
    /// with the ledger the only thing standing between it and retirement.
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

    /// **A re-derivation reads the household file, not the profile's leftovers.**
    ///
    /// `PersonRegistry.seeded(from:)` is `FilingProfileStore.personRegistry`'s FALLBACK for a
    /// machine with no `people.json`. `rederiveProfile` called it directly, so every refresh
    /// recomputed the person axis from whatever aliases the last profile happened to retain
    /// rather than from the curated list beside it — and `carryOver` writes the fresh axis back,
    /// so the loss compounds with each pass. On the real tree that took person-axis agreement
    /// from 0.998 to 0.905 in one evening of refreshes.
    ///
    /// The alias here is deliberately one the profile axis does NOT carry: it can only reach the
    /// re-derived profile by way of `people.json`.
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

    /// **The verifier's verdict reaches the outcome AND the ledger.**
    ///
    /// The verify was two `fileExists` per performed action run synchronously on the main actor —
    /// 2,000 stats for a thousand-action merge, with the landing sheet on screen — and it now runs
    /// through the same serial file-operation queue the executor just used. The queue is ordered,
    /// so it still reads the tree strictly after the moves and strictly before anything else this
    /// app does to it, and the result is awaited. What no test held was that the verdict ARRIVES:
    /// the whole call could be replaced with `[]` and every green-path assertion stayed green,
    /// because a correct landing has nothing to report.
    ///
    /// So this drives the unhappy branch — a file manager with a hole where the carried `Refund/`
    /// lands — and checks the mismatch on the outcome, in the log-bound list, and in the ledger
    /// record the Applied card reads.
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

    /// **The replayed memory is published, not merely written.**
    ///
    /// Step 7 — the corpus decode, the key replay, `flatten`, `buildMemory` and the write — moved
    /// into one detached task, because every part of it ran on the main actor with a landing sheet
    /// on screen. The publish is the half that has to come back: `filingMemory` is what the filing
    /// layer routes on, and a landing that wrote the artifact but left the manager on the old
    /// memory would route against paths that no longer exist.
    @Test func theReplayedMemoryBecomesTheLiveOne() async throws {
        let world = try await Self.makeWorld()
        defer { try? FileManager.default.removeItem(at: world.root.deletingLastPathComponent()) }
        #expect(world.manager.filingMemory == nil, "nothing is published before the landing")

        let outcome = await world.manager.applyPlan(
            world.manifest, now: Date(timeIntervalSince1970: 1_756_500_000))
        let newId = try #require(outcome.producedProfileId)

        let memory = try #require(world.manager.filingMemory,
                                  "the replayed memory never reached the manager")
        #expect(memory.profileId == newId, "and it is the NEW profile's, not the old one's")
        #expect(world.manager.filingSurveyedAt != nil)
    }
}
