import Testing
import Foundation
import EventsTestSupport
@testable import Sync

/// A picked inbox whose files sit in subfolders (`TODO/Finance/<Bank>/<Account>/<Year>`) used to
/// read as empty: the scan read only the folder's own files. It now offers to read the subfolders,
/// and only for a place files wait in, never for a folder already filed into.
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

    @Test func anInboxWithFilesOnlyInSubfoldersOffersToScanThem() async throws {
        let (root, inbox) = try makeInbox("FilingSubfolderOffer")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.1"))
        await manager.findFilingSuggestions(folder: inbox, providerRoot: root.appendingPathComponent("Documents"))

        #expect(manager.filingSuggestions.isEmpty, "nothing loose in the inbox itself")
        let offer = try #require(manager.filingSubfolderOffer)
        #expect(offer.files == 3, "the app package is not counted as files, got \(offer.files)")
        #expect(offer.folders == 2, "two year folders hold the files, got \(offer.folders)")
        #expect(!offer.hasLooseFiles)
        #expect(offer.summary == "3 files in 2 subfolders")
    }

    @Test func takingTheOfferScansEveryFileBelowAndKeepsTheSourceHint() async throws {
        let (root, inbox) = try makeInbox("FilingSubfolderAccept")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.2"))
        let documents = root.appendingPathComponent("Documents")
        await manager.findFilingSuggestions(folder: inbox, providerRoot: documents)
        manager.acceptFilingSubfolderOffer()
        #expect(manager.filingSubfolderOffer == nil, "taking the offer retires it")
        await manager.findFilingSuggestions(folder: inbox, providerRoot: documents)

        let names = manager.filingSuggestions.map { $0.fileName }.sorted()
        #expect(names == ["01. Jan 2026.pdf", "01. Jan 2026.pdf", "02. Feb 2026.pdf"],
                "every statement below is a loose file, the package's contents are not: \(names)")
        #expect(manager.filingSubfolderOffer == nil, "a recursive scan has nothing more to offer")
        #expect(manager.filingScanReadSubfolders)
        #expect(OrganizeScopeFilter.looseFileScanCovers(subject: inbox.path + "/Finance/Schwab", scannedFolder: inbox.path,
                                                        readSubfolders: true), "a scope below is covered")
        let schwab = try #require(manager.filingSuggestions.first { $0.filePath.contains("IRA 7863") })
        #expect(FileSyncManager.sourceHint(forFile: schwab.filePath, scannedFolder: manager.filingScanFolder)
                == "Finance/Schwab/IRA 7863/2026")
    }

    @Test func aFolderWithLooseFilesAndMoreBelowOffersToAlsoScan() async throws {
        let (root, inbox) = try makeInbox("FilingSubfolderAlso")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(inbox.appendingPathComponent("Loose receipt.pdf"), bytes: 64)
        let manager = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.3"))
        await manager.findFilingSuggestions(folder: inbox, providerRoot: root.appendingPathComponent("Documents"))

        #expect(manager.filingSuggestions.map { $0.fileName } == ["Loose receipt.pdf"])
        let offer = try #require(manager.filingSubfolderOffer)
        #expect(offer.hasLooseFiles && offer.files == 3)
        manager.declineFilingSubfolderOffer()
        await manager.findFilingSuggestions(folder: inbox, providerRoot: root.appendingPathComponent("Documents"))
        #expect(manager.filingSubfolderOffer == nil, "Not Now holds for the session")
    }

    @Test func theChoiceIsRememberedSoAnAutomaticRescanRepeatsIt() throws {
        let defaults = ScratchDefaults("FilingSubfolderRemember")
        let manager = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.4"))
        manager.persistedUIStateDefaults = defaults
        manager.setFilingScansSubfolders(true, for: "/x/TODO")
        // A fresh manager on the same store, as after a relaunch.
        let next = FileSyncManager(defaults: ScratchDefaults("FilingSubfolderScanTests.5"))
        next.persistedUIStateDefaults = defaults
        #expect(next.filingScansSubfolders("/x/TODO"))
        #expect(!next.filingScansSubfolders("/x/Other"))
        next.setFilingScansSubfolders(false, for: "/x/TODO")
        #expect(!next.filingScansSubfolders("/x/TODO"))
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
