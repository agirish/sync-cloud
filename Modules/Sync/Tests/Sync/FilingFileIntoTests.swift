import Foundation
import Testing
@testable import Sync

/// To File reads loose files from one folder and files them into another tree: where it
/// files into (``FilingDestinationRoot``), the scan's record of files only in the cloud, and
/// Download and Read, which fetches those and places them from page 1.
@Suite struct FilingDestinationRootTests {

    private static let folders: Set<String> = ["/U/Cloud/Documents", "/U/Chosen", "/C/Docs", "/U"]
    private static func isDirectory(_ path: String) -> Bool { folders.contains(path) }

    private func resolve(local: Bool, anchor: String = "/C/Docs", survey: String? = "/U/Cloud/Documents",
                         stored: [String: String] = [:]) -> String {
        FilingDestinationRoot.resolve(sourceId: "src", sourceIsLocalFolder: local, sourceAnchor: anchor,
                                      surveyRoot: survey, stored: stored, isDirectory: Self.isDirectory)
    }

    /// Rows: (local, anchor, survey, stored, expected).
    @Test(arguments: [
        // A cloud source keeps its own tree, even with a survey of another one loaded.
        (false, "/C/Docs", "/U/Cloud/Documents", [:], "/C/Docs"),
        // A folder source files into the survey's root, not its own, which for the Home folder is
        // 400,000 entries the scan stops to ask about.
        (true, "/U", "/U/Cloud/Documents", [:], "/U/Cloud/Documents"),
        // No survey, or one whose folder is gone: the folder's own tree is the only one there is.
        (true, "/U", nil, [:], "/U"),
        (true, "/U", "", [:], "/U"),
        (true, "/U", "/U/Gone", [:], "/U"),
        // A stored choice wins while its folder is there; another source's choice is not this one's.
        (false, "/C/Docs", "/U/Cloud/Documents", ["src": "/U/Chosen"], "/U/Chosen"),
        (true, "/U", "/U/Cloud/Documents", ["src": "/U/Chosen"], "/U/Chosen"),
        (false, "/C/Docs", "/U/Cloud/Documents", ["other": "/U/Chosen"], "/C/Docs"),
        // A chosen folder renamed or unplugged falls back: the scan would walk it as empty.
        (false, "/C/Docs", "/U/Cloud/Documents", ["src": "/U/Unplugged"], "/C/Docs"),
        (true, "/U", "/U/Cloud/Documents", ["src": "/U/Unplugged"], "/U/Cloud/Documents"),
    ] as [(Bool, String, String?, [String: String], String)])
    func theDestinationRootResolves(local: Bool, anchor: String, survey: String?,
                                    stored: [String: String], expected: String) {
        #expect(resolve(local: local, anchor: anchor, survey: survey, stored: stored) == expected)
    }

    /// Picking the default again clears the choice, so the source follows its default from then on.
    @Test func choosingTheDefaultClearsTheChoice() {
        let set = FilingDestinationRoot.encode(["other": "/X"], setting: "src", to: "/U/Chosen", default: "/C/Docs")
        #expect(FilingDestinationRoot.decode(set) == ["other": "/X", "src": "/U/Chosen"])
        let cleared = FilingDestinationRoot.encode(FilingDestinationRoot.decode(set), setting: "src",
                                                   to: "/C/Docs/", default: "/C/Docs")
        #expect(FilingDestinationRoot.decode(cleared) == ["other": "/X"])
    }

    @Test func anUnreadableStoreIsNoChoice() {
        #expect(FilingDestinationRoot.decode("").isEmpty)
        #expect(FilingDestinationRoot.decode("{not json").isEmpty)
        #expect(FilingDestinationRoot.decode("[1,2]").isEmpty)
    }

    /// "Documents (iCloud)" — named after the source that holds it most closely, not the Home
    /// folder source that also contains it.
    @Test func theLabelNamesTheClosestSource() {
        let sources: [(name: String, root: String)] = [("Home folder", "/U"), ("iCloud", "/U/Cloud")]
        #expect(FilingDestinationRoot.label(for: "/U/Cloud/Documents", sources: sources) == "Documents (iCloud)")
        #expect(FilingDestinationRoot.label(for: "/U/Downloads", sources: sources) == "Downloads (Home folder)")
        #expect(FilingDestinationRoot.label(for: "/U/Cloud", sources: sources) == "iCloud")
        #expect(FilingDestinationRoot.label(for: "/Volumes/Drive/Taxes", sources: sources) == "Taxes")
    }
}

@Suite @MainActor struct FilingDownloadAndReadTests {

    /// Which files are still only in the cloud, flipped by the stub downloader.
    final class Cloud: @unchecked Sendable {
        private let lock = NSLock()
        private var cloudOnly: Set<String>
        private(set) var asked: [String] = []
        let lands: Bool
        init(_ paths: Set<String>, lands: Bool = true) { cloudOnly = paths; self.lands = lands }
        func isCloudOnly(_ p: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cloudOnly.contains(p) }
        func download(_ p: String) {
            lock.lock(); defer { lock.unlock() }
            asked.append(p)
            if lands { cloudOnly.remove(p) }
        }
    }

    struct Refused: Error {}

    static let target = "Documents/Home/Leases"

    /// One cloud-only PDF and one downloaded scan with no text layer, filed against a survey that
    /// knows where leases go. The snippet extractor refuses a cloud-only file, as the app's does.
    static func makeScan(lands: Bool = true, refuses: Bool = false, rule: AutomationRule? = nil) async throws
        -> (FileSyncManager, URL, Cloud, String) {
        let root = try makeCanonicalTempRoot(prefix: "FilingDownloadRead")
        try writeBytes(root.appendingPathComponent("\(target)/.keep"), bytes: 1)
        let ticket = root.appendingPathComponent("Downloads/rental agreement.pdf").path
        try writeBytes(URL(fileURLWithPath: ticket))
        try writeBytes(root.appendingPathComponent("Downloads/scanned.pdf"))
        let cloud = Cloud([ticket], lands: lands)
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("FilingDownloadRead-\(UUID().uuidString)")
        if let rule { m.upsertAutomationRule(rule) }
        m.filingContentExtractor = { _ in [] }
        m.filingSnippetExtractor = { p in
            cloud.isCloudOnly(p) || p.hasSuffix("scanned.pdf") ? nil : "lease tenancy landlord rent"
        }
        m.filingTokensFromText = { Set(FilingRouter.tokenize($0)) }
        m.filingStatFlags = { p in cloud.isCloudOnly(p) ? MaterializationStatus.datalessFlag : 0 }
        m.filingDownloader = { p in
            if refuses { throw Refused() }
            cloud.download(p)
        }
        m.filingDownloadWait = (3, .zero)
        m.filingFolderProfile = FilingScanRouterWiringTests.profile([target], root: root.path)
        m.filingMemory = FilingScanRouterWiringTests.memory(target, ["lease", "tenancy", "landlord"])
        m.filingClassifier = { _, _, _ in [:] }
        await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        return (m, root, cloud, ticket)
    }

    /// The scan records the cloud-only file and offers it no Read Scan, since rendering it would
    /// download it. The real scan with no text layer beside it is still offered one, which is what
    /// lets the first half fail.
    @Test func theScanRecordsCloudOnlyFilesAndOffersThemNoReadScan() async throws {
        let (m, root, cloud, ticket) = try await Self.makeScan()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(m.filingNotDownloaded == [ticket])
        #expect(!m.filingUnreadableScans.contains(ticket))
        #expect(m.filingUnreadableScans.contains(root.appendingPathComponent("Downloads/scanned.pdf").path))
        #expect(cloud.asked.isEmpty, "the scan downloaded a file it was only meant to record")
        m.clearFiling()
        #expect(m.filingNotDownloaded.isEmpty)
    }

    /// Download and Read: the file is fetched once, page 1 places it, and the card stops saying
    /// "placed by name".
    @Test func downloadAndReadPlacesTheFileFromItsPage() async throws {
        let (m, root, cloud, ticket) = try await Self.makeScan()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try #require(m.filingSuggestions.first { $0.filePath == ticket })
        #expect(card.best?.path != root.appendingPathComponent(Self.target).path,
                "the fixture needs a card the name alone did not place in Leases")

        #expect(await m.downloadAndReadFiling(m.filingSuggestions) == 1)
        #expect(cloud.asked == [ticket], "only the cloud-only file is fetched, once")
        let after = try #require(m.filingSuggestions.first { $0.filePath == ticket }?.best)
        #expect(after.path == root.appendingPathComponent(Self.target).path)
        #expect(after.fromContent)
        #expect(m.filingNotDownloaded.isEmpty)
        #expect(m.banner?.severity == .success)
        #expect(m.banner?.message == "Downloaded and read 1 file; 1 has a home from the page.")
        #expect(!m.isDownloadingFilingFiles)
    }

    /// A saved rule decides where the downloaded page goes, as in the scan: a rule that needed
    /// the page to match is not overruled by the router's best.
    @Test func downloadAndReadFollowsASavedRuleOverTheRouter() async throws {
        let rule = AutomationRule(name: "Rentals", conditions: [.mentionsAny(["tenancy"])],
                                  destinationTemplate: "Documents/Home/Rentals")
        let (m, root, _, ticket) = try await Self.makeScan(rule: rule)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(m.filingSuggestions.first { $0.filePath == ticket }?.best?.remembered != true,
                "premise: the rule can't match a file whose page wasn't read")

        #expect(await m.downloadAndReadFiling(m.filingSuggestions) == 1)
        let after = try #require(m.filingSuggestions.first { $0.filePath == ticket }?.best)
        #expect(after.path == root.appendingPathComponent("Documents/Home/Rentals").path,
                "the router's Leases replaced the rule's folder")
        #expect(after.remembered)
    }

    /// A download still on its way when the wait runs out is left marked and said, so a second
    /// click picks it up — not routed from an empty page.
    @Test func aFileStillDownloadingStaysMarkedAndIsSaid() async throws {
        let (m, root, cloud, ticket) = try await Self.makeScan(lands: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = m.filingSuggestions.first { $0.filePath == ticket }?.best
        #expect(await m.downloadAndReadFiling(m.filingSuggestions) == 0)
        #expect(cloud.asked == [ticket])
        #expect(m.filingNotDownloaded == [ticket])
        #expect(m.filingSuggestions.first { $0.filePath == ticket }?.best == before)
        #expect(m.banner?.severity == .warning)
        #expect(m.banner?.message == "1 file still downloading — try Download and Read again in a moment.")
    }

    @Test func aRefusedDownloadIsSaid() async throws {
        let (m, root, _, ticket) = try await Self.makeScan(refuses: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await m.downloadAndReadFiling(m.filingSuggestions) == 0)
        #expect(m.filingNotDownloaded == [ticket])
        #expect(m.banner?.message == "Couldn’t download 1 file — open it in Finder to download.")
    }

    /// Read Scan's stale-cache guard: cards from one scan, the index and root of another. Routing
    /// would put the file in the other tree; it is refused, said, and nothing is downloaded.
    @Test func aCacheFromAnotherScanIsRefused() async throws {
        let (m, root, cloud, _) = try await Self.makeScan()
        defer { try? FileManager.default.removeItem(at: root) }
        m.filingLastProviderRoot = "/elsewhere"
        #expect(await m.downloadAndReadFiling(m.filingSuggestions) == 0)
        #expect(cloud.asked.isEmpty)
        #expect(m.banner?.message.contains("Scan this folder again") == true)
    }

    /// Only the rows passed in are fetched — the button counts the rows on screen.
    @Test func onlyTheRowsOnScreenAreFetched() async throws {
        let (m, root, cloud, ticket) = try await Self.makeScan()
        defer { try? FileManager.default.removeItem(at: root) }
        let others = m.filingSuggestions.filter { $0.filePath != ticket }
        #expect(!others.isEmpty)
        #expect(await m.downloadAndReadFiling(others) == 0)
        #expect(cloud.asked.isEmpty)
        #expect(m.filingNotDownloaded == [ticket])
    }

    @Test func theBannerCountsEachOutcome() {
        let mixed = FileSyncManager.downloadAndReadBanner(asked: 5, landed: 3, homed: 1, stillDownloading: 1, refused: 1)
        #expect(mixed.severity == .warning)
        #expect(mixed.message == "Downloaded and read 3 files; 1 has a home from the page; 1 still downloading — try again in a moment; 1 couldn’t be downloaded.")
        let none = FileSyncManager.downloadAndReadBanner(asked: 2, landed: 2, homed: 0, stillDownloading: 0, refused: 0)
        #expect(none.severity == .success)
        #expect(none.message == "Downloaded and read 2 files; none matched a folder.")
    }
}

/// When To File files into a tree that is not the scanned source, the walk of that tree must not
/// answer Names and Renames for the source.
@Suite @MainActor struct FilingTreeFindingsTests {

    @Test func aScanIntoAnotherTreeReportsNoNamesFromIt() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FilingTreeFindings")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBytes(root.appendingPathComponent("Documents/Notes*2026/.keep"), bytes: 1)
        try writeBytes(root.appendingPathComponent("Downloads/a.txt"))
        func scan(_ reports: Bool) async -> FileSyncManager {
            let m = FileSyncManager()
            m.filingClassifier = { _, _, _ in [:] }
            await m.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"),
                                          providerRoot: root.appendingPathComponent("Documents"),
                                          nameProvider: .oneDrive, reportsTreeFindings: reports)
            return m
        }
        // The control: the same tree, as its own source, does report the name OneDrive refuses.
        #expect(!(await scan(true)).riskyNames.isEmpty)
        #expect((await scan(false)).riskyNames.isEmpty)
    }
}
