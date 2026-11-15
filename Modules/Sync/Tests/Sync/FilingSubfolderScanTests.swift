import Testing
import Foundation
import EventsTestSupport
@testable import Sync

/// A picked inbox whose files sit in subfolders (`TODO/Finance/<Bank>/<Account>/<Year>`) used to
/// read as empty: the scan read only the folder's own files. A scan the user starts now asks first
/// whether to read the subfolders too, and only for a place files wait in, never for a folder
/// already filed into.
@MainActor
@Suite struct FilingSubfolderScanTests {

    private func makeInbox(_ prefix: String) throws -> (root: URL, inbox: URL) {
        let root = try makeCanonicalTempRoot(prefix: prefix)
        try writeBytes(root.appendingPathComponent("Documents/Finance/Statements/.keep"), bytes: 1)
        let inbox = root.appendingPathComponent("TODO")
        try writeBytes(inbox.appendingPathComponent("Finance/Schwab/IRA 7863/2026/01. Jan 2026.pdf"), bytes: 64)
        try writeBytes(inbox.appendingPathComponent("Finance/Schwab/IRA 7863/2026/02. Feb 2026.pdf"), bytes: 64)
        try writeBytes(inbox.appendingPathComponent("Finance/Chase/Credit 2809/2026/01. Jan 2026.pdf"), bytes: 64)
        // A package is one item, never a pile of files to file.
        try writeBytes(inbox.appendingPathComponent("Tools/Helper.app/Contents/Info.plist"), bytes: 64)
        // Finder leaves one in every folder it opens; it is not a loose file.
        try writeBytes(inbox.appendingPathComponent(".DS_Store"), bytes: 64)
        try writeBytes(inbox.appendingPathComponent("Finance/.DS_Store"), bytes: 64)
        return (root, inbox)
    }

    /// A scan the user starts, as the app does, and waited out: the question, or the scan.
    private func userScan(_ m: FileSyncManager, _ folder: URL, into: URL,
                          asking: FilingSubfolderAsking = .always) async {
        m.startFindFilingSuggestions(folder: folder, providerRoot: into, asking: asking)
        await m.filingScanTask?.value
    }

    @Test func aUserScanAsksBeforeReadingAnything() async throws {
        let (root, inbox) = try makeInbox("FilingSubfolderAsk")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(inbox.appendingPathComponent("Loose receipt.pdf"), bytes: 64)
        let m = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.ask"))
        await userScan(m, inbox, into: root.appendingPathComponent("Documents"))

        let q = try #require(m.filingSubfolderQuestion)
        #expect(!m.hasSuggestedFiling && m.filingSuggestions.isEmpty && m.filingScanFolder == nil,
                "nothing is scanned before the answer")
        #expect(q.folder == inbox.path && q.looseFiles == 1, "the .DS_Store is not a loose file")
        #expect(q.files == 3, "the app package is not counted as files, got \(q.files)")
        #expect(q.folders == 2, "two year folders hold the files, got \(q.folders)")
        #expect(!q.atLeast && q.total == 4)
        #expect(q.commonPath == ["Finance"] && q.largestGroups == ["Schwab", "Chase"] && q.otherGroups == 0,
                "the largest bank first: \(q.commonPath) \(q.largestGroups)")
    }

    @Test func scanAllReadsEveryFileBelowAndAsksAgainNextTime() async throws {
        let (root, inbox) = try makeInbox("FilingSubfolderScanAll")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let m = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.all"))
        await userScan(m, inbox, into: documents)
        m.scanAllForFilingSubfolderQuestion(always: false)
        #expect(m.filingSubfolderQuestion == nil, "answering retires the question")
        await m.filingScanTask?.value

        let names = m.filingSuggestions.map { $0.fileName }.sorted()
        #expect(names == ["01. Jan 2026.pdf", "01. Jan 2026.pdf", "02. Feb 2026.pdf"],
                "every statement below is a loose file, the package's contents are not: \(names)")
        #expect(m.filingScanReadSubfolders && !m.filingAlwaysScansSubfolders)
        #expect(OrganizeScopeFilter.looseFileScanCovers(subject: inbox.path + "/Finance/Schwab", scannedFolder: inbox.path,
                                                        readSubfolders: true), "a scope below is covered")
        let schwab = try #require(m.filingSuggestions.first { $0.filePath.contains("IRA 7863") })
        #expect(FileSyncManager.sourceHint(forFile: schwab.filePath, scannedFolder: m.filingScanFolder)
                == "Finance/Schwab/IRA 7863/2026")

        // Every new scan the user starts asks again; an automatic one keeps the answer.
        await userScan(m, inbox, into: documents)
        #expect(m.filingSubfolderQuestion != nil, "Rescan asks again")
        m.dismissFilingSubfolderQuestion()
        await userScan(m, inbox, into: documents, asking: .unlessChosen)
        #expect(m.filingSubfolderQuestion == nil && m.filingScanReadSubfolders,
                "an automatic rescan keeps the scope this session chose")
    }

    @Test func onlyTheFolderScansItsOwnFilesAndAutomaticRescansKeepThat() async throws {
        let (root, inbox) = try makeInbox("FilingSubfolderOnly")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(inbox.appendingPathComponent("Loose receipt.pdf"), bytes: 64)
        let documents = root.appendingPathComponent("Documents")
        let m = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.only"))
        // After a launch nothing was chosen, so even an automatic rescan asks.
        await userScan(m, inbox, into: documents, asking: .unlessChosen)
        #expect(m.filingSubfolderQuestion != nil)
        m.scanFolderOnlyForFilingSubfolderQuestion()
        await m.filingScanTask?.value
        #expect(m.filingSuggestions.map { $0.fileName } == ["Loose receipt.pdf"] && !m.filingScanReadSubfolders)

        await userScan(m, inbox, into: documents, asking: .unlessChosen)
        #expect(m.filingSubfolderQuestion == nil, "the automatic rescan doesn't ask again")
        #expect(m.filingSuggestions.map { $0.fileName } == ["Loose receipt.pdf"] && !m.filingScanReadSubfolders)
    }

    @Test func alwaysScanSubfoldersSkipsTheQuestion() async throws {
        let (root, inbox) = try makeInbox("FilingSubfolderAlways")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let defaults = ScratchDefaults("FilingSubfolderScanTests.always")
        let m = FileSyncManager(defaults: defaults)
        await userScan(m, inbox, into: documents)
        m.scanAllForFilingSubfolderQuestion(always: true)
        await m.filingScanTask?.value
        #expect(defaults.bool(forKey: FileSyncManager.alwaysScanSubfoldersDefaultsKey), "the checkbox sets the preference")

        // A new manager on the same settings, as after a launch: no question, subfolders read.
        let next = FileSyncManager(defaults: defaults)
        await userScan(next, inbox, into: documents)
        #expect(next.filingSubfolderQuestion == nil && next.filingSuggestions.count == 3 && next.filingScanReadSubfolders)

        next.setFilingAlwaysScansSubfolders(false)
        await userScan(next, inbox, into: documents)
        #expect(next.filingSubfolderQuestion != nil, "turned off, it asks again")
    }

    @Test func noQuestionWithNothingBelowOrOutsideAPlaceFilesWait() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingSubfolderNone")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        try writeBytes(documents.appendingPathComponent("Finance/Statements/.keep"), bytes: 1)
        let flat = root.appendingPathComponent("TODO")
        try writeBytes(flat.appendingPathComponent("Loose receipt.pdf"), bytes: 64)
        try writeBytes(flat.appendingPathComponent("Empty/.keep"), bytes: 64)
        let filed = root.appendingPathComponent("Taxes")
        try writeBytes(filed.appendingPathComponent("Return.pdf"), bytes: 64)
        try writeBytes(filed.appendingPathComponent("2025/W-2.pdf"), bytes: 64)
        let m = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.none"))

        await userScan(m, flat, into: documents)
        #expect(m.filingSubfolderQuestion == nil && m.filingSuggestions.map { $0.fileName } == ["Loose receipt.pdf"],
                "a hidden file below is nothing to ask about")
        await userScan(m, filed, into: documents)
        #expect(m.filingSubfolderQuestion == nil && m.filingSuggestions.map { $0.fileName } == ["Return.pdf"],
                "a folder of filed documents is never asked about")
        await userScan(m, flat, into: documents, asking: .never)
        #expect(m.filingSubfolderQuestion == nil)
    }

    @Test func notNowScansNothing() async throws {
        let (root, inbox) = try makeInbox("FilingSubfolderNotNow")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.notNow"))
        await userScan(m, inbox, into: root.appendingPathComponent("Documents"))
        #expect(m.filingSubfolderQuestion?.looseFiles == 0)
        m.dismissFilingSubfolderQuestion()
        await m.filingScanTask?.value
        #expect(m.filingSubfolderQuestion == nil && !m.hasSuggestedFiling && m.filingScanFolder == nil)
    }

    @Test func pastTheCountsCapTheQuestionSaysAtLeast() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingSubfolderCap")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appendingPathComponent("TODO")
        try writeBytes(inbox.appendingPathComponent("Near/Statement.pdf"), bytes: 64)
        try writeBytes(inbox.appendingPathComponent("Deep/a/b/c/Statement.pdf"), bytes: 64)
        let m = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.cap"))
        // Three listings: Near, Deep and Deep/a. The walk stops before Deep/a/b.
        let capped = try #require(await m.subfolderQuestion(for: inbox, options: .init(), fileManager: FileManager.default,
                                                           probeBudget: 3))
        #expect(capped.atLeast && capped.files == 1, "a walk stopped early counts what it read, \(capped.files) here")
        let whole = try #require(await m.subfolderQuestion(for: inbox, options: .init(), fileManager: FileManager.default))
        #expect(!whole.atLeast && whole.files == 2)
    }

    @Test func theGroupsNameTheLargestFoldersBelowTheCommonPath() {
        let parents = Array(repeating: "Finance/Schwab/IRA/2026", count: 3)
            + Array(repeating: "Finance/Chase/Credit/2026", count: 2)
            + ["Finance/Amex/Gold/2025", "Finance/Ally/2026", "Finance/Bank of America/2026", "Finance"]
        let g = FilingSubfolderQuestion.groups(parents)
        #expect(g.common == ["Finance"])
        #expect(g.largest == ["Schwab", "Chase", "Ally"], "by count, then by name: \(g.largest)")
        #expect(g.others == 2, "Amex and Bank of America; the file in Finance itself names no group")
        let one = FilingSubfolderQuestion.groups(["Finance/Chase/2026", "Finance/Chase/2026"])
        #expect(one.common == ["Finance", "Chase", "2026"] && one.largest.isEmpty && one.others == 0)
        let apart = FilingSubfolderQuestion.groups(["Finance/2026", "Medical/2026"])
        #expect(apart.common.isEmpty && apart.largest == ["Finance", "Medical"])
    }

    /// Never for a folder already filed into: scanning an account folder's subtree would offer
    /// its filed statements new homes. Inboxes, folders the survey never saw, and folders
    /// outside it are offered.
    @Test func onlyPlacesFilesWaitInAreOffered() {
        func entry(_ path: String, _ role: FolderRole?, accepts: Bool? = nil) -> FolderProfileEntry {
            FolderProfileEntry(path: path, role: role, naming: nil, anchors: [], acceptsNewFiles: accepts,
                               fileCount: 1, subfolderCount: 1, axes: [:])
        }
        let profile = FolderProfile(profileId: "p", root: "/home/Documents", folders: [
            "Finance/US/Investments/Charles Schwab": entry("Finance/US/Investments/Charles Schwab", .destination),
            "Inbox Here": entry("Inbox Here", .inbox),
            "Credit/Chase/TODO": entry("Credit/Chase/TODO", .destination, accepts: false),
            "Credit/Chase/Closed": entry("Credit/Chase/Closed", .destination, accepts: false),
        ], personTokens: [])
        let eligible = { FileSyncManager.subfolderOfferEligible(folder: $0, profile: profile) }
        #expect(!eligible("/home/Documents/Finance/US/Investments/Charles Schwab"), "a filed account folder")
        #expect(!eligible("/home/Documents"), "the survey root itself")
        #expect(eligible("/home/Documents/Inbox Here"), "the profile's inbox role")
        #expect(!eligible("/home/Documents/Credit/Chase/Closed"), "refusing new files is not an inbox")
        #expect(eligible("/home/Documents/Credit/Chase/TODO"), "the inbox name test")
        #expect(!eligible("/home"), "a folder holding the survey would make every filed file loose")
        #expect(!FileSyncManager.subfolderOfferEligible(folder: "/home/Docs", profile: nil, fileInto: "/home/Docs/Finance"),
                "nor one holding File Into")
        #expect(eligible("/home/Documents/TODO"), "the inbox name test, though the survey never saw it")
        #expect(!eligible("/home/Documents/Never Surveyed"),
                "a folder the survey doesn't know may be an account made since: only by its name")
        #expect(eligible("/home/Downloads"), "outside the survey")
        // With no survey, only a place files wait in: a folder of filed documents isn't one.
        #expect(!FileSyncManager.subfolderOfferEligible(folder: "/x/Documents/Taxes", profile: nil))
        #expect(FileSyncManager.subfolderOfferEligible(folder: "/x/Documents/TODO", profile: nil))
        #expect(FileSyncManager.subfolderOfferEligible(folder: "/x/Downloads", profile: nil))
    }
}
