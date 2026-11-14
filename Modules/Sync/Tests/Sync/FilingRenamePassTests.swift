import Combine
import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// Manager-level coverage for the rename pass: the scan that finds drifted folders, the apply path
/// that fixes them, and the two invariants that make applying safe: one grouped undo, and every
/// claim re-derived against the disk at apply time.
@Suite struct FilingRenamePassTests {


    /// A profile marking `rel` as an `ordinal-month` year bucket.
    private func profile(root: String, rel: String, year: String) -> FolderProfile {
        FolderProfile(profileId: "t", root: root,
                      folders: [rel: FolderProfileEntry(path: rel, role: .yearBucket,
                                                        naming: "ordinal-month", anchors: [],
                                                        acceptsNewFiles: true, fileCount: 0,
                                                        subfolderCount: 0, axes: ["year": year])],
                      personTokens: [])
    }

    /// Writes `n. m <year>.pdf` for each `(n, m)` into `root/rel`, whose last component is the year.
    private func writeBucket(_ root: URL, _ rel: String, _ months: [(String, String)]) throws -> URL {
        let bucket = root.appendingPathComponent(rel)
        for (n, m) in months {
            try writeBytes(bucket.appendingPathComponent("\(n). \(m) \(bucket.lastPathComponent).pdf"), bytes: 8)
        }
        return bucket
    }

    /// `PGE/2025` holding January to March, numbered.
    private func pgeTree(_ root: URL) throws -> URL {
        try writeBucket(root, "PGE/2025", [("01", "Jan"), ("02", "Feb"), ("03", "Mar")])
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    /// The plan the pass derives for the year bucket `rel`, holding `files`, at `folder`.
    @MainActor
    private func plan(_ rel: String, _ files: [String], _ folder: String,
                      _ manager: FileSyncManager) -> RenamePlan {
        RenamePlanner.plan(folderPath: folder, relativePath: rel,
                           files: files.map { FolderFile(path: "\(folder)/\($0)", name: $0) },
                           entry: manager.filingFolderProfile?.folders[rel])
    }

    /// A file stub with its size and date stated: an attribute-less stub is synthesized as size 0
    /// with no date, so bare stubs would be indistinguishable.
    private static func stub(_ size: Int = 12) -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false,
                                 attributes: [.size: NSNumber(value: size),
                                              .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                 contents: nil)
    }

    /// A mock disk holding `/prov` and `folder`, with `names` in it.
    private func mockBucket(_ folder: String, _ names: [String]) throws -> MockFileManager {
        let fm = MockFileManager()
        for dir in ["/prov", folder] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        for name in names { fm.virtualDisk["\(folder)/\(name)"] = Self.stub() }
        return fm
    }

    // MARK: Scan

    @MainActor
    @Test func theFilingScanFindsFoldersThatDriftedFromTheirConvention() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try writeBucket(root, "Utilities/PGE/2021", [("1", "Mar"), ("2", "Apr"), ("10", "Dec")])
        try writeBytes(root.appendingPathComponent("Inbox/.keep"), bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "Utilities/PGE/2021", year: "2021")
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Inbox"),
                                            providerRoot: root)

        let plan = try #require(manager.renamePlans.first { $0.relativePath == "Utilities/PGE/2021" })
        #expect(plan.steps.count == 2)          // the two one-digit ordinals; `10.` was already fine
        #expect(plan.tidied == 2)
        #expect(Set(plan.steps.map(\.proposedName)) == ["01. Mar 2021.pdf", "02. Apr 2021.pdf"])
    }

    @MainActor
    @Test func aFolderAlreadyKeepingItsConventionIsNotReported() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try writeBucket(root, "Utilities/PGE/2021", [("01", "Mar"), ("02", "Apr")])
        try writeBytes(root.appendingPathComponent("Inbox/.keep"), bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "Utilities/PGE/2021", year: "2021")
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Inbox"),
                                            providerRoot: root)
        #expect(manager.renamePlans.isEmpty)
    }

    // MARK: Apply

    @MainActor
    @Test func applyRenamesTheFolderAndRegistersOneGroupedUndo() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try writeBucket(root, "2021", [("1", "Mar"), ("2", "Apr"), ("3", "May")])

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = self.plan("2021", try names(in: bucket), bucket.path, manager)
        #expect(plan.steps.count == 3)

        await manager.applyRenamePlans([plan])

        #expect(try names(in: bucket) == ["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf"])
        // One grouped undo for the whole pass: a single ⌘Z puts all three back, not just the last.
        #expect(undo.canUndo)
        // The `undoable:` flag shows the banner's Undo button, which wears the ⌘Z keycap (so the
        // sentence doesn't repeat it), and lets `invalidateUndoableBanner` retire the offer once
        // another operation registers its own undo; unflagged, the banner would offer ⌘Z for the
        // wrong operation.
        let banner = try #require(manager.banner)
        #expect(!banner.message.contains("⌘Z"), "the Undo button says ⌘Z; the sentence repeats it: \(banner.message)")
        #expect(banner.isUndoable, "the ⌘Z offer is not flagged, so nothing retires it: \(banner.message)")

        undo.undo()
        await waitUntil("all three names restored") {
            ((try? names(in: bucket)) ?? []) == ["1. Mar 2021.pdf", "2. Apr 2021.pdf", "3. May 2021.pdf"]
        }
    }

    @MainActor
    @Test func applyReDerivesAgainstTheDiskAndSkipsWhatChangedUnderIt() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try writeBucket(root, "2021", [("1", "Mar"), ("2", "Apr")])
        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = self.plan("2021", try names(in: bucket), bucket.path, manager)
        #expect(plan.steps.count == 2)

        // The tree changes while the plan is open: March is renamed by hand onto the name the plan
        // wanted for it.
        try FileManager.default.moveItem(at: bucket.appendingPathComponent("1. Mar 2021.pdf"),
                                         to: bucket.appendingPathComponent("01. Mar 2021.pdf"))

        await manager.applyRenamePlans([plan])

        // April still gets its padding; March's step is dropped rather than applied onto the file
        // now holding its target, and nothing is overwritten.
        #expect(try names(in: bucket) == ["01. Mar 2021.pdf", "02. Apr 2021.pdf"])
        // The banner says so rather than reporting a clean pass.
        #expect(manager.banner?.message.contains("had already changed") == true)
    }

    /// The re-derivation stops the clobber here, not the uniquify beneath it: the fresh plan sees
    /// the occupant and the step never runs. The `generateUniqueURL` fallback covers only the window
    /// between re-derive and move, which no deterministic test can open; this suite doesn't
    /// exercise it.
    @MainActor
    @Test func applyLeavesAFileSittingOnTheTargetUntouched() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("2021")
        try writeBytes(bucket.appendingPathComponent("1. Mar 2021.pdf"), bytes: 8)
        try writeBytes(bucket.appendingPathComponent("2. Apr 2021.pdf"), bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = self.plan("2021", try names(in: bucket), bucket.path, manager)

        // A different file lands on March's target between plan and apply, 20 bytes so a clobber
        // shows in the size, not only the listing.
        try writeBytes(bucket.appendingPathComponent("01. Mar 2021.pdf"), bytes: 20)
        await manager.applyRenamePlans([plan])

        let survivor = try #require(try FileManager.default.attributesOfItem(
            atPath: bucket.appendingPathComponent("01. Mar 2021.pdf").path)[.size] as? Int)
        #expect(survivor == 20, "the occupant must still be there, untouched")
    }

    @MainActor
    @Test func applyPerformsAWholeCascadeAndUndoesItInOneStep() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try writeBucket(root, "2021", [("01", "Mar"), ("02", "Apr"), ("03", "May")])
        try writeBytes(bucket.appendingPathComponent("9829custbill02182021.pdf"), bytes: 8)

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = self.plan("2021", try names(in: bucket), bucket.path, manager)
        #expect(plan.renumbered == 3)

        await manager.applyRenamePlans([plan])

        // February took slot 01 and the three months after it each moved up one. Every rename
        // happened, or the numbering would be incoherent.
        #expect(try names(in: bucket) == ["01. Feb 2021.pdf", "02. Mar 2021.pdf",
                                          "03. Apr 2021.pdf", "04. May 2021.pdf"])
        #expect(undo.canUndo)
        undo.undo()
        await waitUntil("the whole cascade reverted in one step") {
            ((try? names(in: bucket)) ?? []) == ["01. Mar 2021.pdf", "02. Apr 2021.pdf",
                                                 "03. May 2021.pdf", "9829custbill02182021.pdf"]
        }
    }

    @MainActor
    @Test func aCascadeIsAbandonedWholeWhenTheFolderMovedUnderIt() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try writeBucket(root, "2021", [("01", "Mar"), ("02", "Apr"), ("03", "May")])
        try writeBytes(bucket.appendingPathComponent("9829custbill02182021.pdf"), bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = self.plan("2021", try names(in: bucket), bucket.path, manager)
        #expect(plan.steps.count == 4)

        // May is renamed by hand to slot 01 while the plan is open. Three of the four steps would
        // still apply, but letting them through would put February and May both on slot 01, the
        // corruption a cascade must prevent.
        try FileManager.default.moveItem(at: bucket.appendingPathComponent("03. May 2021.pdf"),
                                         to: bucket.appendingPathComponent("01. May 2021.pdf"))

        await manager.applyRenamePlans([plan])

        #expect(try names(in: bucket) == ["01. Mar 2021.pdf", "01. May 2021.pdf",
                                          "02. Apr 2021.pdf", "9829custbill02182021.pdf"],
                "no partial cascade may reach the disk")
        #expect(manager.banner?.message.contains("had already changed") == true)
    }

    @MainActor
    @Test func clearingTheFilingScanClearsTheBacklogItProduced() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try writeBucket(root, "Utilities/PGE/2021", [("1", "Mar"), ("2", "Apr")])
        try writeBytes(root.appendingPathComponent("Inbox/.keep"), bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "Utilities/PGE/2021", year: "2021")
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Inbox"),
                                            providerRoot: root)
        #expect(!manager.renamePlans.isEmpty)

        manager.clearFiling()

        // The backlog is that scan's finding and shares its scope: `clearFiling` also drops
        // `filingLastProviderRoot`, which the backlog's chip names, so a kept backlog couldn't say
        // which tree it was about.
        #expect(manager.renamePlans.isEmpty)
        #expect(manager.filingLastProviderRoot == nil)
    }

    // MARK: A case-only tidy

    /// `07. jul 2016.pdf` → `07. Jul 2016.pdf` is a real tidy: ``OrdinalMonthName`` respells the
    /// month, changing only case. On a case-insensitive volume (the macOS default),
    /// `fileExists("07. Jul 2016.pdf")` is true because it is the source itself, and
    /// `standardizedFileURL` never folds case. The never-overwrite guard must ask
    /// ``isCaseOnlyRenaming``, as `safeMoveItem` does, or it invents `07. Jul 2016 2.pdf`, which
    /// later scans keep as part of the name.
    @MainActor
    @Test func aCaseOnlyTidyLandsAtTheCasedNameRatherThanInventingADuplicate() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        // Required, not assumed: on a case-sensitive volume the two names are distinct and this
        // fixture tests nothing. A precondition says so where a skip would be silent.
        try #require(!FileSyncManager.volumeSupportsCaseSensitiveNames(for: root),
                     "this fixture only means anything on a case-INSENSITIVE volume")

        let bucket = try writeBucket(root, "2016", [("07", "jul"), ("08", "Aug"), ("09", "Sep")])

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "2016", year: "2016")
        let plan = self.plan("2016", try names(in: bucket), bucket.path, manager)
        // Exactly one step, changing nothing but case.
        #expect(plan.steps.map(\.proposedName) == ["07. Jul 2016.pdf"])
        #expect(plan.steps.first?.currentName == "07. jul 2016.pdf")

        await manager.applyRenamePlans([plan])

        #expect(try names(in: bucket) == ["07. Jul 2016.pdf", "08. Aug 2016.pdf", "09. Sep 2016.pdf"])
        // Named in the negative too: " 2" is the specific wrong answer, which a later scan would
        // keep as though a user had typed it.
        #expect(!(try names(in: bucket).contains("07. Jul 2016 2.pdf")))
        #expect(manager.banner?.message == "Renamed 1 file")
    }

    /// The mover underneath the pass, on a real case-insensitive volume. `validateFileOperation`
    /// compares paths after `resolvingSymlinksInPath`, which returns each component as the
    /// directory spells it, so both spellings resolve to the one on disk. Unless it allows a
    /// case-only rename, `safeMoveItem` throws `identicalSourceAndDestination` and the tidy never
    /// lands the cased name. The case-sensitive test double can't show this.
    @Test func theMoverPerformsACaseOnlyRenameOnACaseInsensitiveVolume() throws {
        let root = try makeCanonicalTempRoot(prefix: "RenameCase")
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(!FileSyncManager.volumeSupportsCaseSensitiveNames(for: root),
                     "this fixture only means anything on a case-INSENSITIVE volume")
        let lower = root.appendingPathComponent("07. jul 2016.pdf")
        let cased = root.appendingPathComponent("07. Jul 2016.pdf")
        try writeBytes(lower, bytes: 8)

        #expect(try FileSyncManager.safeMoveItem(at: lower, to: cased,
                                                 fileManager: FileManager.default) == nil)
        #expect(try names(in: root) == ["07. Jul 2016.pdf"])

        // The other direction: a path identical to itself is still refused, so the exemption
        // didn't widen to any source equal to its destination.
        #expect(throws: FileSyncManager.FileOperationError.identicalSourceAndDestination) {
            try FileSyncManager.validateFileOperation(source: cased, destination: cased,
                                                      caseSensitiveVolume: false)
        }
    }

    /// The guard in both directions, without needing two volumes. Folding case is right only where
    /// the volume folds it: on a case-sensitive volume `07. jul` and `07. Jul` are two files, and a
    /// rename onto the second is a real collision the pass must step around, not overwrite.
    @Test func theNeverOverwriteGuardFoldsCaseOnlyWhereTheVolumeDoes() {
        let src = URL(fileURLWithPath: "/prov/2016/07. jul 2016.pdf")
        let cased = URL(fileURLWithPath: "/prov/2016/07. Jul 2016.pdf")
        let other = URL(fileURLWithPath: "/prov/2016/08. Aug 2016.pdf")

        #expect(FileSyncManager.isCaseOnlyRenaming(source: src, destination: cased,
                                                  caseSensitiveVolume: false))
        #expect(!FileSyncManager.isCaseOnlyRenaming(source: src, destination: cased,
                                                   caseSensitiveVolume: true))
        // A different name is never a case-only rename, on either kind of volume.
        #expect(!FileSyncManager.isCaseOnlyRenaming(source: src, destination: other,
                                                   caseSensitiveVolume: false))
        // Nor is a same-named file in a different folder: that is a move onto somebody else.
        #expect(!FileSyncManager.isCaseOnlyRenaming(
            source: src, destination: URL(fileURLWithPath: "/prov/2017/07. Jul 2016.pdf"),
            caseSensitiveVolume: false))
    }

    // MARK: A cohort that fails half way

    /// A renumbering is all-or-nothing, during the moves as well as at re-derive. A move can throw
    /// mid-cohort (a busy iCloud placeholder is routine); carrying on would leave two files on one
    /// slot, `02. Mar` and `02. Apr`. The end state must be one of the two coherent ones; here, the
    /// original.
    @MainActor
    @Test func aCohortThatFailsPartWayIsRolledBackToTheNumberingItStartedWith() async throws {
        let original = ["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf",
                        "9829custbill02182021.pdf"]
        let fm = try mockBucket("/prov/2021", original)

        let manager = FileSyncManager(fileManager: fm)
        let undo = UndoManager()
        manager.undoManager = undo
        manager.filingFolderProfile = profile(root: "/prov", rel: "2021", year: "2021")
        let plan = self.plan("2021", original, "/prov/2021", manager)
        // February takes slot 01 and the three months after it each move up: one cohort of four.
        #expect(plan.steps.count == 4)
        #expect(Set(plan.steps.map(\.cohort)).count == 1)
        #expect(plan.steps.first(where: { $0.cohort == 0 }) == nil)

        // The cohort's second member fails mid-flight: armed when the loop stats April's target,
        // one-shot so nothing else inherits it. Both flags are needed: the plain move throws EXDEV,
        // and `safeMoveItem`'s cross-volume fallback stages through a `.tmp_` that must fail too.
        var armed = false
        fm.onFileExists = { path in
            guard !armed, path == "/prov/2021/03. Apr 2021.pdf" else { return }
            armed = true
            fm.shouldFailMove = true
            fm.shouldFailMoveOnTempRename = true
        }

        let log = LogCapture()
        await manager.applyRenamePlans([plan])

        let after = fm.virtualDisk.keys.filter { $0.hasPrefix("/prov/2021/") }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { !$0.hasPrefix(".") }.sorted()
        #expect(after == original.sorted(), "a half-applied renumbering must not be reachable")
        // Named in the negative: two files on slot 02 is the specific corruption.
        #expect(after.filter { $0.hasPrefix("02.") }.count <= 1)

        // Nothing stands, so there is nothing for ⌘Z to take back, and the banner says the
        // renumbering was abandoned rather than reporting a partial success.
        #expect(!undo.canUndo)
        let message = try #require(manager.banner?.message)
        #expect(message.contains("renumbering"), "banner was: \(message)")
        #expect(await log.holds(.warning, containing: "renumbering of 4 file(s) in 2021"))
    }

    /// The one way a half-applied renumbering survives the pass, and it must not be silent. The
    /// rollback won't move a file back onto a name something else has taken since: a stranded file
    /// is recoverable, a clobbered stranger is not. So March stays put, the banner names the count,
    /// the log names the folder, and the file stays in the undo group as the user's way back.
    @MainActor
    @Test func aRollbackThatCannotPutAFileBackSaysSoRatherThanOverwriting() async throws {
        let original = ["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf",
                        "9829custbill02182021.pdf"]
        let fm = try mockBucket("/prov/2021", original)

        let manager = FileSyncManager(fileManager: fm)
        let undo = UndoManager()
        manager.undoManager = undo
        manager.filingFolderProfile = profile(root: "/prov", rel: "2021", year: "2021")
        let plan = self.plan("2021", original, "/prov/2021", manager)
        #expect(plan.steps.count == 4)

        // When the loop stats April's target: fail April's move and drop a 20-byte stranger onto
        // the name March just vacated, so a clobber shows in the size. `onFileExists` plants after
        // the stat returns, so the rollback's later read is the one that sees the stranger.
        var armed = false
        fm.onFileExists = { path in
            guard !armed, path == "/prov/2021/03. Apr 2021.pdf" else { return }
            armed = true
            fm.shouldFailMove = true
            fm.shouldFailMoveOnTempRename = true
            fm.virtualDisk["/prov/2021/01. Mar 2021.pdf"] = Self.stub(20)
        }

        let log = LogCapture()
        await manager.applyRenamePlans([plan])

        let survivor = try #require(
            try fm.attributesOfItem(atPath: "/prov/2021/01. Mar 2021.pdf")[.size] as? NSNumber)
        #expect(survivor.intValue == 20, "the stranger must still be there, untouched")
        #expect(fm.virtualDisk["/prov/2021/02. Mar 2021.pdf"] != nil,
                "March stays where the pass put it rather than overwriting the stranger")
        #expect(manager.banner?.message
                == "Renamed 1 file. A renumbering of 4 files failed part-way "
                 + "and 1 file couldn’t be put back — check the folder.")
        // Still undoable, because of the stranded file.
        #expect(undo.canUndo)
        #expect(await log.holds(.error, containing: "is occupied again in /prov/2021"))
    }

    /// A step that stands alone is applied on its own terms: the rollback is about cohorts, not
    /// failures. Padding fixes carry cohort 0 because each is right whether or not its neighbours
    /// move, and they are most of a real backlog.
    @MainActor
    @Test func anIndependentStepThatFailsTakesNothingElseWithIt() async throws {
        let original = ["1. Mar 2021.pdf", "2. Apr 2021.pdf", "3. May 2021.pdf"]
        let fm = try mockBucket("/prov/2021", original)

        let manager = FileSyncManager(fileManager: fm)
        manager.filingFolderProfile = profile(root: "/prov", rel: "2021", year: "2021")
        let plan = self.plan("2021", original, "/prov/2021", manager)
        // Three widenings, nothing arriving: no slot moves, so nothing is in a cohort.
        #expect(plan.steps.count == 3)
        #expect(plan.steps.allSatisfy { $0.cohort == 0 })

        var armed = false
        fm.onFileExists = { path in
            guard !armed, path == "/prov/2021/02. Apr 2021.pdf" else { return }
            armed = true
            fm.shouldFailMove = true
            fm.shouldFailMoveOnTempRename = true
        }

        await manager.applyRenamePlans([plan])

        let after = fm.virtualDisk.keys.filter { $0.hasPrefix("/prov/2021/") }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .filter { !$0.hasPrefix(".") }.sorted()
        #expect(after == ["01. Mar 2021.pdf", "03. May 2021.pdf", "2. Apr 2021.pdf"])
        // Reported as one failure, not as an abandoned renumbering: there was none.
        #expect(manager.banner?.message == "Renamed 2 files; 1 couldn’t be renamed")
    }


    // MARK: The outcome sentence

    @MainActor
    @Test func theOutcomeSentenceStaysHonestAboutWhatItDidNotDo() {
        #expect(FileSyncManager.renameOutcome(renamed: 3, stale: 0, failed: 0)
                == "Renamed 3 files")
        #expect(FileSyncManager.renameOutcome(renamed: 1, stale: 0, failed: 0)
                == "Renamed 1 file")
        // A pass that renamed something and skipped something must say both, never a bare success.
        #expect(FileSyncManager.renameOutcome(renamed: 2, stale: 1, failed: 0)
                == "Renamed 2 files; 1 had already changed")
        #expect(FileSyncManager.renameOutcome(renamed: 0, stale: 4, failed: 0)
                == "4 files had already changed — nothing renamed.")
        #expect(FileSyncManager.renameOutcome(renamed: 0, stale: 0, failed: 2)
                == "Couldn’t rename 2 files.")

        // An abandoned renumbering is about a group, and the user must hear it even when the rest
        // went fine. It isn't folded into `failed`: one member threw, and calling that four
        // failures is as wrong as calling it one.
        #expect(FileSyncManager.renameOutcome(renamed: 0, stale: 0, failed: 0, abandoned: 4)
                == "A renumbering of 4 files couldn’t be completed, so the folder was left as it was.")
        #expect(FileSyncManager.renameOutcome(renamed: 2, stale: 0, failed: 0, abandoned: 3)
                == "Renamed 2 files. A renumbering of 3 files couldn’t be "
                 + "completed, so the folder was left as it was.")
        // The loud one: a file the rollback couldn't put back is the only way a half-applied
        // renumbering survives, so the sentence names it and sends the user to look.
        #expect(FileSyncManager.renameOutcome(renamed: 0, stale: 0, failed: 0, abandoned: 4, stranded: 1)
                == "A renumbering of 4 files failed part-way and 1 file couldn’t be put back — "
                 + "check the folder.")
    }

    // MARK: Naming a file on the way in

    @MainActor
    @Test func theQueueProposesTheNameAFileWouldTakeWhereItIsGoing() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try pgeTree(root)
        try writeBytes(root.appendingPathComponent("Inbox/PGE DetailedBillApr2025.pdf"), bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "PGE/2025", year: "2025")
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Inbox"),
                                            providerRoot: root)

        let bill = try #require(manager.filingSuggestions.first { $0.fileName.hasPrefix("PGE") })
        let home = try #require(bill.candidates.first { $0.path == bucket.path })
        #expect(home.proposedName == "04. Apr 2025.pdf")
        // Every candidate is asked, not just the best, and the `PGE/` container, which numbers
        // nothing, proposes no rename: the name belongs to the destination, not the file.
        let container = try #require(bill.candidates.first { $0.path == root.appendingPathComponent("PGE").path })
        #expect(container.proposedName == nil)
    }

    @MainActor
    @Test func filingTheFileActuallyLandsUnderTheProposedName() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try pgeTree(root)
        let loose = root.appendingPathComponent("Inbox/DetailedBillApr2025.pdf")
        try writeBytes(loose, bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "PGE/2025", year: "2025")
        let suggestion = FilingSuggestion(
            filePath: loose.path, fileName: loose.lastPathComponent, size: 8, modificationDate: nil,
            candidates: [FilingDestination(path: bucket.path, confidence: .high, reasons: [],
                                           newSegments: [], proposedName: "04. Apr 2025.pdf")],
            providerRoot: root.path)
        manager.publishFilingSuggestions([suggestion])

        _ = await manager.applyFilingSuggestion(suggestion, to: try #require(suggestion.best))

        #expect(try names(in: bucket).contains("04. Apr 2025.pdf"))
        #expect(!FileManager.default.fileExists(atPath: loose.path))
    }

    @MainActor
    @Test func filingDoesNotRenameWhenTheCardOfferedNoName() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = try pgeTree(root)
        let loose = root.appendingPathComponent("Inbox/DetailedBillApr2025.pdf")
        try writeBytes(loose, bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "PGE/2025", year: "2025")
        // A destination with no proposal, as every candidate minted outside the scan has. The user
        // was shown only the move, so the move is all they get.
        let suggestion = FilingSuggestion(
            filePath: loose.path, fileName: loose.lastPathComponent, size: 8, modificationDate: nil,
            candidates: [FilingDestination(path: bucket.path, confidence: .high, reasons: [],
                                           newSegments: [])],
            providerRoot: root.path)
        manager.publishFilingSuggestions([suggestion])

        _ = await manager.applyFilingSuggestion(suggestion, to: try #require(suggestion.best))

        #expect(try names(in: bucket).contains("DetailedBillApr2025.pdf"))
        #expect(!(try names(in: bucket).contains("04. Apr 2025.pdf")),
                "a move the user asked for must not silently become a move-and-rename")
    }

    @MainActor
    @Test func aFolderTheWalkCouldNotListProposesNoName() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("PGE/2025")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "PGE/2025", year: "2025")
        let suggestion = FilingSuggestion(
            filePath: root.appendingPathComponent("Inbox/DetailedBillApr2025.pdf").path,
            fileName: "DetailedBillApr2025.pdf", size: 8, modificationDate: nil,
            candidates: [FilingDestination(path: bucket.path, confidence: .high, reasons: [],
                                           newSegments: [])],
            providerRoot: root.path)

        // The walk reports a permission-denied or depth-capped folder as `children: []` with
        // `isUnexplored`. Read as empty, it would propose slot 01 for a folder that may hold twelve
        // months.
        let unexplored = [FileNode(id: root.appendingPathComponent("PGE").path, name: "PGE",
                                   isDirectory: true,
                                   children: [FileNode(id: bucket.path, name: "2025",
                                                       isDirectory: true, children: [],
                                                       isUnexplored: true)])]
        let named = FileSyncManager.namingSuggestions([suggestion], taxonomy: unexplored,
                                                      rootPath: root.path,
                                                      profile: manager.filingFolderProfile)
        #expect(named.first?.best?.proposedName == nil)

        // Control: the same folder walked properly and genuinely empty does propose.
        let listed = [FileNode(id: root.appendingPathComponent("PGE").path, name: "PGE",
                               isDirectory: true,
                               children: [FileNode(id: bucket.path, name: "2025",
                                                   isDirectory: true, children: [])])]
        #expect(FileSyncManager.namingSuggestions([suggestion], taxonomy: listed,
                                                  rootPath: root.path,
                                                  profile: manager.filingFolderProfile)
                    .first?.best?.proposedName == "01. Apr 2025.pdf")
    }

    @MainActor
    @Test func aDestinationWithNoConventionLeavesTheNameAlone() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        // The profile calls this folder `descriptive`, so there is no slot to take. The pass must
        // not rename into folders that never numbered anything.
        let bucket = root.appendingPathComponent("Manuals")
        try writeBytes(bucket.appendingPathComponent("Thermostat.pdf"), bytes: 8)
        let loose = root.appendingPathComponent("Inbox/DetailedBillApr2025.pdf")
        try writeBytes(loose, bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = FolderProfile(
            profileId: "t", root: root.path,
            folders: ["Manuals": FolderProfileEntry(path: "Manuals", role: .destination,
                                                    naming: "descriptive", anchors: [],
                                                    acceptsNewFiles: true, fileCount: 1,
                                                    subfolderCount: 0, axes: [:])],
            personTokens: [])
        let name = FileSyncManager.liveIncomingName(
            for: "DetailedBillApr2025.pdf", destination: bucket.path, providerRoot: root.path,
            profile: manager.filingFolderProfile, fileManager: FileManager.default)
        #expect(name == nil)
    }

    // MARK: A destination folder that cannot be listed

    /// A destination that can't be listed falls back to the file's own name, never to slot 01. An
    /// enumerator is non-nil and yields nothing for an unreadable directory, so `liveFiles` must
    /// tell it from an empty one. One test, two halves: same file, folder and profile, differing
    /// only in whether the folder can be read.
    @Test func anUnreadableDestinationOffersNoSlotRatherThanTheFirstOne() throws {
        let fm = try mockBucket("/prov/Bills", ["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf"])
        let bills = URL(fileURLWithPath: "/prov/Bills")
        let profile = profile(root: "/prov", rel: "Bills", year: "2021")

        // Readable: three months are there, so a June bill appends as slot 04.
        let readable = FileSyncManager.liveFiles(in: bills, fileManager: fm)
        #expect(readable?.count == 3)
        #expect(FileSyncManager.liveIncomingName(
            for: "9829custbill06182021.pdf", destination: bills.path, providerRoot: "/prov",
            profile: profile, fileManager: fm) == "04. Jun 2021.pdf")

        // The identical folder, now unlistable.
        fm.unlistableDirectories = ["/prov/Bills"]

        #expect(FileSyncManager.liveFiles(in: bills, fileManager: fm) == nil,
                "a folder that could not be listed is not a folder holding no files")
        let blocked = FileSyncManager.liveIncomingName(
            for: "9829custbill06182021.pdf", destination: bills.path, providerRoot: "/prov",
            profile: profile, fileManager: fm)
        #expect(blocked == nil, "the caller must fall back to the file's own name")
        // Named in the negative too: 01, the slot an empty folder hands out, would collide with the
        // March bill already on it.
        #expect(blocked != "01. Jun 2021.pdf")
    }
}

/// The rollback's occupancy probe must not fold case. Putting a cohort member back strands it when
/// `fileExists` finds something at its old name, and on a case-insensitive volume (the macOS
/// default) a member whose move was case-only is its own "occupant". The rollback suites use
/// `MockFileManager`, which is case-sensitive, so these run on the real volume. The planner can't
/// produce this today (a case-only step keeps cohort 0 and is never rolled back), so the guard is
/// pinned on the decision itself.
@Suite struct RenameRollbackOccupancyTests {

    private func makeDir() throws -> URL {
        try makeCanonicalTempRoot(prefix: "RollbackOccupancy")
    }

    /// The guard itself: the file being put back is not a stranger occupying its own old name. The
    /// premise, on the real volume: after a case-only rename the old spelling still answers
    /// `fileExists`, so the bare probe can't tell a stranger from the file being put back.
    @Test func aCaseOnlyMemberIsNotItsOwnOccupant() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lower = dir.appendingPathComponent("07. jul 2016.pdf")
        let upper = dir.appendingPathComponent("07. Jul 2016.pdf")
        try Data("x".utf8).write(to: lower)
        try FileManager.default.moveItem(at: lower, to: upper)

        guard !FileSyncManager.volumeSupportsCaseSensitiveNames(for: dir) else {
            Issue.record("""
                Skipped: this temp volume distinguishes names by case, so the fold this fixture is \
                about does not happen here and the guard below cannot be exercised.
                """)
            return
        }
        #expect(FileManager.default.fileExists(atPath: lower.path),
                "the old spelling stopped answering — the fold this guard exists for is gone")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["07. Jul 2016.pdf"],
                "fixture: there is exactly one file, under the new spelling")

        #expect(FileSyncManager.rollbackTargetIsOccupied(
            movedTo: upper, puttingBackTo: lower,
            fileManager: FileManager.default, caseSensitiveVolume: false) == false,
                "the file was declared occupied by itself, and would be stranded under its new name")
    }

    /// The other direction, so the exemption can't become "never refuse": a real stranger on the old
    /// name still strands the member.
    @Test func aRealStrangerStillOccupiesTheOldName() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let from = dir.appendingPathComponent("01. Mar 2021.pdf")
        let to = dir.appendingPathComponent("02. Mar 2021.pdf")
        try Data("moved".utf8).write(to: to)
        try Data("stranger".utf8).write(to: from)

        #expect(FileSyncManager.rollbackTargetIsOccupied(
            movedTo: to, puttingBackTo: from,
            fileManager: FileManager.default, caseSensitiveVolume: false),
                "putting the member back would overwrite a file nothing here put there")
    }

    /// On a case-sensitive volume the case variant is a different file, so it occupies. Driven
    /// through the flag, the seam the pass already uses, rather than a second volume.
    @Test func onACaseSensitiveVolumeTheVariantIsAStranger() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lower = dir.appendingPathComponent("07. jul 2016.pdf")
        let upper = dir.appendingPathComponent("07. Jul 2016.pdf")
        try Data("x".utf8).write(to: lower)

        #expect(FileSyncManager.rollbackTargetIsOccupied(
            movedTo: upper, puttingBackTo: lower,
            fileManager: FileManager.default, caseSensitiveVolume: true),
                "a case-sensitive volume was told the two names are one file")
    }
}
