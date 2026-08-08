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
}
