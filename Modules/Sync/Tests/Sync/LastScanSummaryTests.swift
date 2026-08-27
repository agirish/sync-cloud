import Foundation
import Testing
@testable import Sync

/// What Compare remembers between launches, and — mostly — when it must refuse to speak.
@MainActor
@Suite struct LastScanSummaryTests {

    private static let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", rootPath: "/left", type: .iCloud)
    private static let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", rootPath: "/right", type: .iCloud)

    private func summary(leftPath: String = "/left/Docs", rightPath: String = "/right/Docs",
                         count: Int = 412) -> LastScanSummary {
        LastScanSummary(date: Date(timeIntervalSinceReferenceDate: 0), differenceCount: count,
                        leftProviderID: "l", leftPath: leftPath,
                        rightProviderID: "r", rightPath: rightPath)
    }

    // MARK: Which comparison it describes

    @Test func testItDescribesTheExactPairItWasRecordedFor() {
        #expect(summary().describes(leftProviderID: "l", leftPath: "/left/Docs",
                                    rightProviderID: "r", rightPath: "/right/Docs"))
    }

    /// The gate that keeps the card honest. Each fixture moves exactly ONE of the four fields, so
    /// a rule that compared only some of them cannot pass.
    @Test func testItRefusesEveryOtherComparison() {
        let s = summary()
        #expect(!s.describes(leftProviderID: "other", leftPath: "/left/Docs", rightProviderID: "r", rightPath: "/right/Docs"))
        #expect(!s.describes(leftProviderID: "l", leftPath: "/left/Other", rightProviderID: "r", rightPath: "/right/Docs"))
        #expect(!s.describes(leftProviderID: "l", leftPath: "/left/Docs", rightProviderID: "other", rightPath: "/right/Docs"))
        #expect(!s.describes(leftProviderID: "l", leftPath: "/left/Docs", rightProviderID: "r", rightPath: "/right/Other"))
    }

    /// A↔B is not B↔A. The counts would coincide, but the swap asks the opposite question of each
    /// side and Compare's own actions are directional.
    @Test func testASwappedPairIsADifferentComparison() {
        #expect(!summary().describes(leftProviderID: "r", leftPath: "/right/Docs",
                                     rightProviderID: "l", rightPath: "/left/Docs"))
    }

    /// A provider path is whatever the user typed into Settings, trailing slash and all, and the
    /// scan and the pane normalize it differently. Without the trim the summary would compare
    /// unequal to itself and silently never show — a failure with no symptom but an absence.
    @Test func testATrailingSlashIsNotADifferentFolder() {
        #expect(summary(leftPath: "/left/Docs/").describes(
            leftProviderID: "l", leftPath: "/left/Docs",
            rightProviderID: "r", rightPath: "/right/Docs"))
        #expect(summary().describes(
            leftProviderID: "l", leftPath: "/left/Docs/",
            rightProviderID: "r", rightPath: "/right/Docs"))
        // ...and the root itself survives the trim rather than becoming "".
        #expect(LastScanSummary.normalized("/") == "/")
    }

    // MARK: Persistence

    private func freshDefaults() -> UserDefaults {
        let suite = "LastScanSummaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func testItSurvivesARelaunch() {
        let defaults = freshDefaults()
        let first = FileSyncManager(fileManager: MockFileManager())
        first.persistedUIStateDefaults = defaults
        first.recordLastScanSummary(summary())

        let relaunched = FileSyncManager(fileManager: MockFileManager())
        relaunched.persistedUIStateDefaults = defaults
        relaunched.loadLastScanSummary()

        #expect(relaunched.lastScanSummary == summary())
    }

    /// No injected store means no reads and no writes — the rule every persisted fact on this
    /// manager follows, so the CLI and a bare test manager never touch the user's real defaults.
    @Test func testWithNoStoreItPersistsNothingButStillPublishes() {
        let m = FileSyncManager(fileManager: MockFileManager())
        m.recordLastScanSummary(summary())
        // The session still knows — only persistence is gated.
        #expect(m.lastScanSummary == summary())

        let relaunched = FileSyncManager(fileManager: MockFileManager())
        relaunched.loadLastScanSummary()
        #expect(relaunched.lastScanSummary == nil)
    }

    /// Garbage in the key is dropped, not repaired and not crashed on. The whole feature is one
    /// line of reassurance; there is nothing here worth a migration.
    @Test func testAnUndecodableValueIsIgnored() {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: FileSyncManager.lastScanSummaryKey)
        let m = FileSyncManager(fileManager: MockFileManager())
        m.persistedUIStateDefaults = defaults

        m.loadLastScanSummary()

        #expect(m.lastScanSummary == nil)
    }

    // MARK: Recorded by a real scan

    /// The call site: a completed scan records a summary for the folders IT compared.
    @Test func testACompletedScanRecordsWhatItFound() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/left"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/right"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/left/only.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let m = FileSyncManager(fileManager: mockFM)

        await m.scanDirectories(left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right")

        let recorded = try #require(m.lastScanSummary)
        #expect(recorded.differenceCount == 1)
        #expect(recorded.describes(leftProviderID: "l", leftPath: "/left",
                                   rightProviderID: "r", rightPath: "/right"))
    }

    /// The count is the SCAN's, not the filtered list's. `differences` is `rawDifferences` minus
    /// the hidden/ignored filter and it keeps moving after the scan — toggling hidden files or
    /// ignoring a row would otherwise leave the card disagreeing with a number it never measured.
    @Test func testTheCountIsTheScansOwnNotTheFilteredList() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/left"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/right"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/left/visible.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/left/.hidden.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let m = FileSyncManager(fileManager: mockFM)
        m.showHiddenFiles = false

        await m.scanDirectories(left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right")

        #expect(m.differences.count == 1, "the filter must actually hide one, or this proves nothing")
        #expect(m.lastScanSummary?.differenceCount == 2)
    }
}
