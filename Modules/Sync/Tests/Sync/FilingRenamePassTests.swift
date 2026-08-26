import Combine
import Testing
import Foundation
import Events
@testable import Sync

/// Manager-level coverage for the rename pass: the scan that finds drifted folders, the apply path
/// that fixes them, and the two invariants that make applying safe — **one grouped undo**, and
/// **every claim re-derived against the disk at apply time**.
@Suite struct FilingRenamePassTests {

    private func write(_ url: URL, bytes: Int = 8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// A profile marking `rel` as an `ordinal-month` year bucket.
    private func profile(root: String, rel: String, year: String) -> FolderProfile {
        FolderProfile(profileId: "t", root: root,
                      folders: [rel: FolderProfileEntry(path: rel, role: .yearBucket,
                                                        naming: "ordinal-month", anchors: [],
                                                        acceptsNewFiles: true, fileCount: 0,
                                                        subfolderCount: 0, axes: ["year": year])],
                      personTokens: [])
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: Scan

    @MainActor
    @Test func theFilingScanFindsFoldersThatDriftedFromTheirConvention() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("Utilities/PGE/2021")
        for (n, m) in [(1, "Mar"), (2, "Apr"), (10, "Dec")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2021.pdf"))
        }
        try write(root.appendingPathComponent("Inbox/.keep"))

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
        let bucket = root.appendingPathComponent("Utilities/PGE/2021")
        for (n, m) in [("01", "Mar"), ("02", "Apr")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2021.pdf"))
        }
        try write(root.appendingPathComponent("Inbox/.keep"))

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
        let bucket = root.appendingPathComponent("2021")
        for (n, m) in [(1, "Mar"), (2, "Apr"), (3, "May")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2021.pdf"))
        }

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = RenamePlanner.plan(
            folderPath: bucket.path, relativePath: "2021",
            files: try names(in: bucket).map { FolderFile(path: bucket.appendingPathComponent($0).path, name: $0) },
            entry: manager.filingFolderProfile?.folders["2021"])
        #expect(plan.steps.count == 3)

        await manager.applyRenamePlans([plan])

        #expect(try names(in: bucket) == ["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf"])
        // ONE grouped undo for the whole pass: a single ⌘Z puts all three back, not just the last.
        #expect(undo.canUndo)
        // **The ⌘Z sentence and the `undoable:` flag must agree.** The flag is what
        // `invalidateUndoableBanner` reads to retire the offer once another operation registers
        // its own undo; defaulted to false, this banner outlived its step and kept telling the
        // user to press ⌘Z after that shortcut had come to mean the OTHER operation. Asserting the
        // prose alone would pass on the broken version, so both are checked.
        let banner = try #require(manager.banner)
        #expect(banner.message.contains("⌘Z"))
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
        let bucket = root.appendingPathComponent("2021")
        for (n, m) in [(1, "Mar"), (2, "Apr")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2021.pdf"))
        }
        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = RenamePlanner.plan(
            folderPath: bucket.path, relativePath: "2021",
            files: try names(in: bucket).map { FolderFile(path: bucket.appendingPathComponent($0).path, name: $0) },
            entry: manager.filingFolderProfile?.folders["2021"])
        #expect(plan.steps.count == 2)

        // The tree is edited while the plan is open — somebody renames March by hand, and the name
        // the plan wanted for it is now occupied by a different file.
        try FileManager.default.moveItem(at: bucket.appendingPathComponent("1. Mar 2021.pdf"),
                                         to: bucket.appendingPathComponent("01. Mar 2021.pdf"))

        await manager.applyRenamePlans([plan])

        // April still gets its padding; March's step is dropped rather than applied onto the file
        // that now holds its target — and nothing was overwritten.
        #expect(try names(in: bucket) == ["01. Mar 2021.pdf", "02. Apr 2021.pdf"])
        // The banner says so rather than reporting a clean pass over a plan it only half applied.
        #expect(manager.banner?.message.contains("had already changed") == true)
    }

    /// What stops the clobber here is the **re-derivation**, not the uniquify beneath it: the fresh
    /// plan sees the occupant, refuses the contended target, and the step never runs. The
    /// `generateUniqueURL` fallback in the apply loop covers only the window between that re-derive
    /// and the move itself, which no deterministic test can open — it is a backstop, and this suite
    /// deliberately does not claim to exercise it.
    @MainActor
    @Test func applyLeavesAFileSittingOnTheTargetUntouched() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("2021")
        try write(bucket.appendingPathComponent("1. Mar 2021.pdf"), bytes: 8)
        try write(bucket.appendingPathComponent("2. Apr 2021.pdf"), bytes: 8)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = RenamePlanner.plan(
            folderPath: bucket.path, relativePath: "2021",
            files: try names(in: bucket).map { FolderFile(path: bucket.appendingPathComponent($0).path, name: $0) },
            entry: manager.filingFolderProfile?.folders["2021"])

        // A DIFFERENT file lands on March's target between the plan and the apply — 20 bytes, so a
        // clobber is visible in the size and not only in the listing.
        try write(bucket.appendingPathComponent("01. Mar 2021.pdf"), bytes: 20)
        await manager.applyRenamePlans([plan])

        let survivor = try #require(try FileManager.default.attributesOfItem(
            atPath: bucket.appendingPathComponent("01. Mar 2021.pdf").path)[.size] as? Int)
        #expect(survivor == 20, "the occupant must still be there, untouched")
    }

    @MainActor
    @Test func applyPerformsAWholeCascadeAndUndoesItInOneStep() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("2021")
        for (n, m) in [("01", "Mar"), ("02", "Apr"), ("03", "May")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2021.pdf"))
        }
        try write(bucket.appendingPathComponent("9829custbill02182021.pdf"))

        let manager = FileSyncManager()
        let undo = UndoManager()
        manager.undoManager = undo
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = RenamePlanner.plan(
            folderPath: bucket.path, relativePath: "2021",
            files: try names(in: bucket).map { FolderFile(path: bucket.appendingPathComponent($0).path, name: $0) },
            entry: manager.filingFolderProfile?.folders["2021"])
        #expect(plan.renumbered == 3)

        await manager.applyRenamePlans([plan])

        // February took slot 01 and the three months after it each moved up one. Every rename in
        // the folder happened, or the numbering would be incoherent.
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
        let bucket = root.appendingPathComponent("2021")
        for (n, m) in [("01", "Mar"), ("02", "Apr"), ("03", "May")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2021.pdf"))
        }
        try write(bucket.appendingPathComponent("9829custbill02182021.pdf"))

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "2021", year: "2021")
        let plan = RenamePlanner.plan(
            folderPath: bucket.path, relativePath: "2021",
            files: try names(in: bucket).map { FolderFile(path: bucket.appendingPathComponent($0).path, name: $0) },
            entry: manager.filingFolderProfile?.folders["2021"])
        #expect(plan.steps.count == 4)

        // May is renamed by hand while the plan is open — to a slot it keeps, so it does not free
        // `03.` for anyone. Three of the four steps still describe the folder exactly and would
        // apply; the fourth cannot. Letting the three through puts February AND May both on slot
        // 01, which is precisely the corruption a cascade is supposed to prevent.
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
        let bucket = root.appendingPathComponent("Utilities/PGE/2021")
        for (n, m) in [(1, "Mar"), (2, "Apr")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2021.pdf"))
        }
        try write(root.appendingPathComponent("Inbox/.keep"))

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "Utilities/PGE/2021", year: "2021")
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Inbox"),
                                            providerRoot: root)
        #expect(!manager.renamePlans.isEmpty)

        manager.clearFiling()

        // The backlog is that scan's finding and shares its scope: `clearFiling` also drops
        // `filingLastProviderRoot`, which is what the backlog's chip names. Kept, the finding
        // outlived the only thing that said which tree it was about.
        #expect(manager.renamePlans.isEmpty)
        #expect(manager.filingLastProviderRoot == nil)
    }

    // MARK: A case-only tidy

    /// `07. jul 2016.pdf` → `07. Jul 2016.pdf` is a rename the tidy pass proposes for real: the body
    /// is a bare month and year, so ``OrdinalMonthName`` respells it, and the only thing that
    /// changes is one letter's case.
    ///
    /// On the default (case-INSENSITIVE) macOS volume the apply loop's never-overwrite guard used to
    /// fire on it. `fileExists("07. Jul 2016.pdf")` is TRUE — it is the source itself, case-collapsed
    /// — and `standardizedFileURL` resolves `..` and trailing slashes but never case, so the two
    /// paths compared unequal and the guard "resolved" a collision that did not exist. The file
    /// landed as `07. Jul 2016 2.pdf`: a duplicate marker invented out of nothing, which the next
    /// scan then reads as part of the name and preserves forever.
    ///
    /// The irony worth keeping: `safeMoveItem` handles a case-only rename correctly on its own
    /// (``isCaseOnlyRenaming``). The guard above it pre-empted it, so the two disagreed about what
    /// "the destination exists" means — which is why the guard now asks the same question.
    @MainActor
    @Test func aCaseOnlyTidyLandsAtTheCasedNameRatherThanInventingADuplicate() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        // Stated, not assumed: on a case-SENSITIVE volume `07. jul` and `07. Jul` are two ordinary
        // distinct names and this fixture would be exercising nothing. A skip would be silent about
        // that; a required precondition names it.
        try #require(!FileSyncManager.volumeSupportsCaseSensitiveNames(for: root),
                     "this fixture only means anything on a case-INSENSITIVE volume")

        let bucket = root.appendingPathComponent("2016")
        for (n, m) in [("07", "jul"), ("08", "Aug"), ("09", "Sep")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2016.pdf"))
        }

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "2016", year: "2016")
        let plan = RenamePlanner.plan(
            folderPath: bucket.path, relativePath: "2016",
            files: try names(in: bucket).map { FolderFile(path: bucket.appendingPathComponent($0).path, name: $0) },
            entry: manager.filingFolderProfile?.folders["2016"])
        // The fixture's whole point: exactly one step, and it changes nothing but case.
        #expect(plan.steps.map(\.proposedName) == ["07. Jul 2016.pdf"])
        #expect(plan.steps.first?.currentName == "07. jul 2016.pdf")

        await manager.applyRenamePlans([plan])

        #expect(try names(in: bucket) == ["07. Jul 2016.pdf", "08. Aug 2016.pdf", "09. Sep 2016.pdf"])
        // Named in the negative too — " 2" is the specific wrong answer, and the one a later scan
        // would then carry as though a user had typed it.
        #expect(!(try names(in: bucket).contains("07. Jul 2016 2.pdf")))
        #expect(manager.banner?.message == "Renamed 1 file. Press ⌘Z to undo")
    }

    /// The mover underneath the pass, on a REAL case-insensitive volume.
    ///
    /// The apply loop's guard was only half the defect. `safeMoveItem` is documented as handling a
    /// case-only rename on its own, and against the case-SENSITIVE test double it does — but on the
    /// default macOS volume it threw `identicalSourceAndDestination` before it moved anything,
    /// because `validateFileOperation` compares paths that have been through
    /// `resolvingSymlinksInPath`, and realpath hands every component back the way the directory
    /// spells it. Both spellings resolved to the one on disk.
    ///
    /// So this suite cannot pin the pass without pinning the primitive: fix only the guard and the
    /// tidy stops fabricating `… 2` but never lands the cased name either.
    @Test func theMoverPerformsACaseOnlyRenameOnACaseInsensitiveVolume() throws {
        let root = try makeCanonicalTempRoot(prefix: "RenameCase")
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(!FileSyncManager.volumeSupportsCaseSensitiveNames(for: root),
                     "this fixture only means anything on a case-INSENSITIVE volume")
        let lower = root.appendingPathComponent("07. jul 2016.pdf")
        let cased = root.appendingPathComponent("07. Jul 2016.pdf")
        try write(lower)

        #expect(try FileSyncManager.safeMoveItem(at: lower, to: cased,
                                                 fileManager: FileManager.default) == nil)
        #expect(try names(in: root) == ["07. Jul 2016.pdf"])

        // The other direction of the same guard: a path identical to itself is still refused, so
        // the exemption did not widen into "any source equals any destination".
        #expect(throws: FileSyncManager.FileOperationError.identicalSourceAndDestination) {
            try FileSyncManager.validateFileOperation(source: cased, destination: cased,
                                                      caseSensitiveVolume: false)
        }
    }

    /// The discriminating half of the guard, both directions, without needing two volumes to run on.
    ///
    /// Folding case is only right where the volume folds it. On a case-SENSITIVE volume `07. jul`
    /// and `07. Jul` are two files, and a rename landing on the second one is a genuine collision
    /// the pass must step around rather than overwrite.
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
        // Nor is a same-named file in a DIFFERENT folder — that is a move onto somebody else.
        #expect(!FileSyncManager.isCaseOnlyRenaming(
            source: src, destination: URL(fileURLWithPath: "/prov/2017/07. Jul 2016.pdf"),
            caseSensitiveVolume: false))
    }

    // MARK: A cohort that fails half way

    /// A renumbering is all-or-nothing, and until this that promise was kept only at re-derive time.
    ///
    /// Once the loop was executing, a thrown `safeMoveItem` — a busy iCloud placeholder is routine —
    /// counted one failure and carried straight on with the REST of the cohort. Inserting February
    /// into `01. Mar · 02. Apr · 03. May` with April's move failing left `02. Mar` and `02. Apr`
    /// both sitting on slot 02: precisely the state the cohort machinery exists to prevent. Nothing
    /// is lost — but the folder ends worse numbered than it started, and the banner called it a
    /// partial success.
    ///
    /// The end state must be one of the two coherent ones. This pins the original.
    @MainActor
    @Test func aCohortThatFailsPartWayIsRolledBackToTheNumberingItStartedWith() async throws {
        let fm = MockFileManager()
        for dir in ["/prov", "/prov/2021"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        let original = ["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf",
                        "9829custbill02182021.pdf"]
        for name in original {
            fm.virtualDisk["/prov/2021/\(name)"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [.size: NSNumber(value: 12),
                             .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                contents: nil)
        }

        let manager = FileSyncManager(fileManager: fm)
        let undo = UndoManager()
        manager.undoManager = undo
        manager.filingFolderProfile = profile(root: "/prov", rel: "2021", year: "2021")
        let plan = RenamePlanner.plan(
            folderPath: "/prov/2021", relativePath: "2021",
            files: original.map { FolderFile(path: "/prov/2021/\($0)", name: $0) },
            entry: manager.filingFolderProfile?.folders["2021"])
        // February takes slot 01 and the three months after it each move up — ONE cohort of four.
        #expect(plan.steps.count == 4)
        #expect(Set(plan.steps.map(\.cohort)).count == 1)
        #expect(plan.steps.first(where: { $0.cohort == 0 }) == nil)

        // The SECOND member of the cohort fails, mid-flight: armed the moment the loop stats
        // April's target, and one-shot so nothing else in the pass inherits it. Both flags are
        // needed — the plain move throws EXDEV, and `safeMoveItem`'s cross-volume fallback then
        // stages through a `.tmp_` that must fail too, or the move would simply succeed.
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

        // Nothing stands, so there is nothing for ⌘Z to take back — and the banner says the
        // renumbering was abandoned rather than reporting a partial success.
        #expect(!undo.canUndo)
        let message = try #require(manager.banner?.message)
        #expect(message.contains("renumbering"), "banner was: \(message)")
        #expect(await log.holds(.warning, containing: "renumbering of 4 file(s) in 2021"))
    }

    /// The one way a half-applied renumbering can still be on disk when the pass returns — and it
    /// must not be silent.
    ///
    /// The rollback refuses to move a file back onto a name something else has taken since: putting
    /// March back would overwrite the stranger sitting on `01. Mar 2021.pdf`, and a file stranded
    /// under a new name is recoverable where a clobbered stranger is not. So March stays where the
    /// pass put it, the banner names the count, the log names the folder, and the file stays in the
    /// undo group because ⌘Z is the user's remaining way back.
    @MainActor
    @Test func aRollbackThatCannotPutAFileBackSaysSoRatherThanOverwriting() async throws {
        let fm = MockFileManager()
        for dir in ["/prov", "/prov/2021"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        func stub(_ size: Int) -> MockFileManager.FileStub {
            MockFileManager.FileStub(
                isDirectory: false,
                attributes: [.size: NSNumber(value: size),
                             .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                contents: nil)
        }
        let original = ["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf",
                        "9829custbill02182021.pdf"]
        for name in original { fm.virtualDisk["/prov/2021/\(name)"] = stub(12) }

        let manager = FileSyncManager(fileManager: fm)
        let undo = UndoManager()
        manager.undoManager = undo
        manager.filingFolderProfile = profile(root: "/prov", rel: "2021", year: "2021")
        let plan = RenamePlanner.plan(
            folderPath: "/prov/2021", relativePath: "2021",
            files: original.map { FolderFile(path: "/prov/2021/\($0)", name: $0) },
            entry: manager.filingFolderProfile?.folders["2021"])
        #expect(plan.steps.count == 4)

        // At the moment the loop stats April's target: fail April's move, AND drop a stranger onto
        // the name March has just vacated — 20 bytes, so a clobber shows in the size and not only
        // in the listing. `onFileExists` is the seam built for exactly this (it plants AFTER the
        // stat returns, so the reading that sees the stranger is a later one — the rollback's).
        var armed = false
        fm.onFileExists = { path in
            guard !armed, path == "/prov/2021/03. Apr 2021.pdf" else { return }
            armed = true
            fm.shouldFailMove = true
            fm.shouldFailMoveOnTempRename = true
            fm.virtualDisk["/prov/2021/01. Mar 2021.pdf"] = stub(20)
        }

        let log = LogCapture()
        await manager.applyRenamePlans([plan])

        let survivor = try #require(
            try fm.attributesOfItem(atPath: "/prov/2021/01. Mar 2021.pdf")[.size] as? NSNumber)
        #expect(survivor.intValue == 20, "the stranger must still be there, untouched")
        #expect(fm.virtualDisk["/prov/2021/02. Mar 2021.pdf"] != nil,
                "March stays where the pass put it rather than overwriting the stranger")
        #expect(manager.banner?.message
                == "Renamed 1 file. Press ⌘Z to undo. A renumbering of 4 files failed part-way "
                 + "and 1 file couldn't be put back — check the folder.")
        // Still undoable: the stranded file is the whole reason it has to be.
        #expect(undo.canUndo)
        #expect(await log.holds(.error, containing: "is occupied again in /prov/2021"))
    }

    /// The discriminating half: a step that stands ALONE is still applied on its own terms.
    ///
    /// The rollback must be a statement about cohorts, not about failures. Padding fixes carry
    /// cohort 0 precisely because each is right whether or not its neighbours move — undoing the
    /// two that worked because a third failed would make the pass useless on the bulk of the
    /// backlog (567 one-digit ordinals tree-wide, none of them in a cohort).
    @MainActor
    @Test func anIndependentStepThatFailsTakesNothingElseWithIt() async throws {
        let fm = MockFileManager()
        for dir in ["/prov", "/prov/2021"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        let original = ["1. Mar 2021.pdf", "2. Apr 2021.pdf", "3. May 2021.pdf"]
        for name in original {
            fm.virtualDisk["/prov/2021/\(name)"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [.size: NSNumber(value: 12),
                             .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                contents: nil)
        }

        let manager = FileSyncManager(fileManager: fm)
        manager.filingFolderProfile = profile(root: "/prov", rel: "2021", year: "2021")
        let plan = RenamePlanner.plan(
            folderPath: "/prov/2021", relativePath: "2021",
            files: original.map { FolderFile(path: "/prov/2021/\($0)", name: $0) },
            entry: manager.filingFolderProfile?.folders["2021"])
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
        // Reported as one failure, and NOT as an abandoned renumbering — there was none.
        #expect(manager.banner?.message == "Renamed 2 files; 1 couldn't be renamed. Press ⌘Z to undo")
    }

    /// Accumulates every entry the shared Logger publishes, from construction onward.
    ///
    /// **`Logger.shared.entries` is capped at 1000 and this package runs 2,848 tests across 261
    /// suites in parallel, so a whole-buffer read is a race with every other suite's logging.**
    /// These two assertions lost it twice on CI — the v4.4 release run and `61d8dfc5` here — both
    /// times passing 3/3 in isolation on the same tree, which is the signature of mechanism 12 in
    /// `docs/flaky-tests.md` ("A log assertion reading a window that has already rolled").
    ///
    /// The rules there — an opening marker plus a `#require` — make an evicted window *report* as
    /// eviction instead of as a missing line, which is the right diagnosis and still a red. This
    /// removes the race instead: an entry is captured at the moment it is published, so a later
    /// trim cannot take it away. Every entry appears in at least the publish that appended it
    /// (`flushPendingEntries` appends and then trims, and both mutations publish), so accumulating
    /// across publishes sees everything. Deduplicated by `LogEntry.id`, since each publish carries
    /// the whole array.
    @MainActor
    private final class LogCapture {
        private var seen: [LogEntry] = []
        private var ids: Set<UUID> = []
        private var cancellable: AnyCancellable?

        init() {
            // **`dropFirst()` because a `@Published` publisher replays its CURRENT value on
            // subscribe**, so without it the capture opens already holding the whole buffer — and
            // a capture that means "since I started" must not include what came before. The
            // contamination it rules out is a sibling's identical sentence satisfying the
            // assertion before the call under test has run. Recorded honestly: that was NOT
            // reproduced. Deleting `dropFirst()`, removing the production line, and running the
            // whole package still fails, because no sibling happens to write these two sentences.
            // It is kept as the correct semantics for a capture, not as a proven guard.
            cancellable = Logger.shared.$entries.dropFirst().sink { [weak self] published in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for entry in published where !self.ids.contains(entry.id) {
                        self.ids.insert(entry.id)
                        self.seen.append(entry)
                    }
                }
            }
        }

        /// True when anything captured since construction is at `level` and contains `fragment`.
        ///
        /// The awaited `debug` is the visibility half of mechanism 12's rule 1: `Logger.log` is
        /// `nonisolated` and hands the entry to a FIFO queue a `@MainActor` task drains, so without
        /// it a line written by the call under test may simply not have been published yet.
        func holds(_ level: LogLevel, containing fragment: String) async -> Bool {
            await Logger.shared.debug("rename-pass-test flush marker").value
            return seen.contains { $0.level == level && $0.message.contains(fragment) }
        }
    }

    // MARK: The outcome sentence

    @MainActor
    @Test func theOutcomeSentenceStaysHonestAboutWhatItDidNotDo() {
        #expect(FileSyncManager.renameOutcome(renamed: 3, stale: 0, failed: 0)
                == "Renamed 3 files. Press ⌘Z to undo")
        #expect(FileSyncManager.renameOutcome(renamed: 1, stale: 0, failed: 0)
                == "Renamed 1 file. Press ⌘Z to undo")
        // A pass that renamed something AND skipped something must say both — a bare success
        // sentence over a partial pass is the report this feature most needs not to make.
        #expect(FileSyncManager.renameOutcome(renamed: 2, stale: 1, failed: 0)
                == "Renamed 2 files; 1 had already changed. Press ⌘Z to undo")
        #expect(FileSyncManager.renameOutcome(renamed: 0, stale: 4, failed: 0)
                == "4 files had already changed — nothing renamed.")
        #expect(FileSyncManager.renameOutcome(renamed: 0, stale: 0, failed: 2)
                == "Couldn't rename 2 files.")

        // An abandoned renumbering is a statement about a GROUP, and it is the one the user has to
        // hear even when everything else went fine: the folder they asked to renumber is unchanged.
        // It is not folded into `failed` — one member threw, and calling that four failures is as
        // dishonest as calling it one.
        #expect(FileSyncManager.renameOutcome(renamed: 0, stale: 0, failed: 0, abandoned: 4)
                == "A renumbering of 4 files couldn't be completed, so the folder was left as it was.")
        #expect(FileSyncManager.renameOutcome(renamed: 2, stale: 0, failed: 0, abandoned: 3)
                == "Renamed 2 files. Press ⌘Z to undo. A renumbering of 3 files couldn't be "
                 + "completed, so the folder was left as it was.")
        // The loud one. A file the rollback could not put back is the ONLY way a half-applied
        // renumbering survives the pass, so the sentence names it and sends the user to look.
        #expect(FileSyncManager.renameOutcome(renamed: 0, stale: 0, failed: 0, abandoned: 4, stranded: 1)
                == "A renumbering of 4 files failed part-way and 1 file couldn't be put back — "
                 + "check the folder.")
    }

    // MARK: Naming a file on the way in

    @MainActor
    @Test func theQueueProposesTheNameAFileWouldTakeWhereItIsGoing() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("PGE/2025")
        for (n, m) in [("01", "Jan"), ("02", "Feb"), ("03", "Mar")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2025.pdf"))
        }
        try write(root.appendingPathComponent("Inbox/PGE DetailedBillApr2025.pdf"))

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "PGE/2025", year: "2025")
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Inbox"),
                                            providerRoot: root)

        let bill = try #require(manager.filingSuggestions.first { $0.fileName.hasPrefix("PGE") })
        let home = try #require(bill.candidates.first { $0.path == bucket.path })
        #expect(home.proposedName == "04. Apr 2025.pdf")
        // EVERY candidate is asked, not just the best one — and the parent `PGE/` container, which
        // numbers nothing, correctly proposes no rename. That asymmetry is what shows the name is a
        // property of the destination rather than of the file.
        let container = try #require(bill.candidates.first { $0.path == root.appendingPathComponent("PGE").path })
        #expect(container.proposedName == nil)
    }

    @MainActor
    @Test func filingTheFileActuallyLandsUnderTheProposedName() async throws {
        let root = try makeCanonicalTempRoot(prefix: "RenamePass")
        defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("PGE/2025")
        for (n, m) in [("01", "Jan"), ("02", "Feb"), ("03", "Mar")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2025.pdf"))
        }
        let loose = root.appendingPathComponent("Inbox/DetailedBillApr2025.pdf")
        try write(loose)

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
        let bucket = root.appendingPathComponent("PGE/2025")
        for (n, m) in [("01", "Jan"), ("02", "Feb"), ("03", "Mar")] {
            try write(bucket.appendingPathComponent("\(n). \(m) 2025.pdf"))
        }
        let loose = root.appendingPathComponent("Inbox/DetailedBillApr2025.pdf")
        try write(loose)

        let manager = FileSyncManager()
        manager.filingFolderProfile = profile(root: root.path, rel: "PGE/2025", year: "2025")
        // A destination carrying NO proposal — what every path that mints a candidate outside the
        // scan produces. The move was the only thing the user was shown, so the move is all they get.
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

        // The walk reports a permission-denied or depth-capped folder as `children: []` WITH
        // `isUnexplored` — identical in shape to an empty one. Read as empty it proposes slot 01
        // for a folder that may already hold twelve months.
        let unexplored = [FileNode(id: root.appendingPathComponent("PGE").path, name: "PGE",
                                   isDirectory: true,
                                   children: [FileNode(id: bucket.path, name: "2025",
                                                       isDirectory: true, children: [],
                                                       isUnexplored: true)])]
        let named = FileSyncManager.namingSuggestions([suggestion], taxonomy: unexplored,
                                                      rootPath: root.path,
                                                      profile: manager.filingFolderProfile)
        #expect(named.first?.best?.proposedName == nil)

        // The discriminating half: the same folder walked properly and genuinely empty DOES propose.
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
        // Same file, same shape of folder — but the profile calls this one `descriptive`, so there
        // is no slot to take. Without this the pass would rename into folders that never numbered
        // anything, which is the failure mode that gets a rename feature switched off.
        let bucket = root.appendingPathComponent("Manuals")
        try write(bucket.appendingPathComponent("Thermostat.pdf"))
        let loose = root.appendingPathComponent("Inbox/DetailedBillApr2025.pdf")
        try write(loose)

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

    /// `liveFiles` documents a promise — "a folder that cannot be listed falls back to the file's
    /// own name, never to a stale slot number" — that it could not keep. Its `guard let enumerator
    /// … else { return nil }` never fired, because the enumerator is non-nil and simply yields
    /// nothing for a directory it cannot read. So an unreadable numbered folder arrived at the
    /// planner as an EMPTY folder, and the empty folder's answer is slot 01.
    ///
    /// The two halves are one test because the fix is the difference between them: the same file,
    /// the same folder, the same profile, and the only change is whether the folder can be read.
    @Test func anUnreadableDestinationOffersNoSlotRatherThanTheFirstOne() throws {
        let fm = MockFileManager()
        for dir in ["/prov", "/prov/Bills"] {
            try fm.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        // Sizes and dates stated: an attribute-less stub is synthesized as size 0 with no date, so
        // two bare stubs would be indistinguishable from each other.
        for name in ["01. Mar 2021.pdf", "02. Apr 2021.pdf", "03. May 2021.pdf"] {
            fm.virtualDisk["/prov/Bills/\(name)"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [.size: NSNumber(value: 12), .modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                contents: nil)
        }
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
        // Named in the negative too: 01 is the specific wrong answer — the slot an EMPTY folder
        // hands out — and it would have collided with the March bill already sitting on it.
        #expect(blocked != "01. Jun 2021.pdf")
    }
}

/// **The rollback's occupancy probe folds case, and the rollback tests could not see it.**
///
/// Putting a cohort member back asks `fileExists` at the name it came from and strands the file
/// when something is there. On a case-INSENSITIVE volume — which is every default macOS install,
/// and the one this ships on — a member whose forward move was case-only is its own "occupant":
/// after `07. jul 2016.pdf` → `07. Jul 2016.pdf`, `fileExists("07. jul 2016.pdf")` is **true**.
/// Measured on this machine, and pinned below so the premise cannot quietly stop holding.
///
/// The rollback suites all drive `MockFileManager`, whose virtual disk is case-SENSITIVE, so none
/// of them could distinguish the fix from the bug — the same blind spot `validateFileOperation`'s
/// own comment records ("It read as covered because the only tests that exercise it drive a
/// case-SENSITIVE test double").
///
/// Not reachable through the planner today, and the reason is a planner property rather than
/// anything the apply loop enforces: a step whose ordinal does not move keeps cohort 0
/// (`RenamePlanner.swift`), cohort-0 steps are never rolled back, and a step whose ordinal DOES
/// move is not a case-only rename. So this pins the guard rather than a live defect — which is why
/// it is stated on the decision, where it is provable, instead of through a plan the planner cannot
/// produce.
@Suite struct RenameRollbackOccupancyTests {

    private func makeDir() throws -> URL {
        try makeCanonicalTempRoot(prefix: "RollbackOccupancy")
    }

    /// The measured premise, on the real volume: a case-only rename leaves the old spelling
    /// answering `fileExists` — so the bare probe cannot tell "somebody took it" from "this is the
    /// file I am putting back".
    @Test func aCaseOnlyRenameLeavesTheOldSpellingAnsweringFileExists() throws {
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
    }

    /// The guard itself: the file being put back is not a stranger occupying its own old name.
    @Test func aCaseOnlyMemberIsNotItsOwnOccupant() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lower = dir.appendingPathComponent("07. jul 2016.pdf")
        let upper = dir.appendingPathComponent("07. Jul 2016.pdf")
        try Data("x".utf8).write(to: lower)
        try FileManager.default.moveItem(at: lower, to: upper)
        guard !FileSyncManager.volumeSupportsCaseSensitiveNames(for: dir) else { return }

        #expect(FileSyncManager.rollbackTargetIsOccupied(
            movedTo: upper, puttingBackTo: lower,
            fileManager: FileManager.default, caseSensitiveVolume: false) == false,
                "the file was declared occupied by itself, and would be stranded under its new name")
    }

    /// The other direction, so the exemption cannot become "never refuse": a genuine stranger on
    /// the old name still strands the member, which is the whole point of the probe.
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

    /// And on a case-SENSITIVE volume the case variant is a different file, so it occupies. Driven
    /// through the flag rather than a volume, which is the seam the whole pass already uses.
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
