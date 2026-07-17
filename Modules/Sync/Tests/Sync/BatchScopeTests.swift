import Testing
import Foundation
@testable import Sync

/// The safety net under "batch actions scope to the filtered set".
///
/// Search now narrows what a Tidy lens shows, and the batch buttons re-label to the narrowed
/// count: a query leaving 3 of 8 eligible groups makes the button read "Trash all 3". The rule
/// that makes that safe is that the number on the button and the collection the action iterates
/// must be the SAME value — never recomputed from an unfiltered source.
///
/// The failure mode this guards is the destructive one: a button reading "Trash all 3" over 3
/// visible rows that actually trashes all 8 would destroy 5 items the user could not see and did
/// not agree to. `applyRecommendedDuplicates`/`applyRecommendedFiling` take their scope as a
/// REQUIRED parameter so that bug is unwriteable; these tests pin that the scope is honoured.
@Suite struct BatchScopeTests {

    // MARK: Duplicates

    /// Same shape as FileSyncManagerDuplicatesTests' helper — a plain keeper/redundant pair.
    private func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 1000, itemCount: 1, modificationDate: nil,
                      uniqueItemCount: keeper ? 0 : 1, depth: path.filter { $0 == "/" }.count,
                      isRecommendedKeeper: keeper)
    }

    private func grp(_ name: String, keeper: String, redundant: [String]) -> DuplicateGroup {
        DuplicateGroup(matchType: .identical, name: name, isDirectory: false,
                       copies: [copy(keeper, keeper: true)] + redundant.map { copy($0, keeper: false) },
                       reclaimableBytes: 1000)
    }

    /// The headline case. Three eligible groups on disk, a query leaving ONE — the button would
    /// read "Trash all 1". Exactly one copy may go to the Trash, and the two groups the search hid
    /// must be untouched and still listed.
    @MainActor
    @Test func duplicatesBatchTrashesOnlyTheFilteredGroups() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let size: [FileAttributeKey: Any] = [.size: 1000]
        for p in ["/a/invoice.pdf", "/b/invoice.pdf", "/a/holiday.jpg", "/b/holiday.jpg", "/a/notes.txt", "/b/notes.txt"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        manager.duplicateGroups = [
            grp("invoice.pdf", keeper: "/a/invoice.pdf", redundant: ["/b/invoice.pdf"]),
            grp("holiday.jpg", keeper: "/a/holiday.jpg", redundant: ["/b/holiday.jpg"]),
            grp("notes.txt", keeper: "/a/notes.txt", redundant: ["/b/notes.txt"]),
        ]
        // What a `kind:pdf` search leaves on screen — one group of the three.
        let filtered = manager.duplicateGroups.filter { $0.name.hasSuffix(".pdf") }
        #expect(filtered.count == 1)

        await manager.applyRecommendedDuplicates(filtered)
        await waitUntil("filtered copy trashed") { mockFM.virtualDisk["/b/invoice.pdf"] == nil }

        // The whole point: ONE copy trashed, not three.
        #expect(mockFM.trashedPaths.count == 1)
        #expect(mockFM.virtualDisk["/b/holiday.jpg"] != nil)   // hidden by the search — must survive
        #expect(mockFM.virtualDisk["/b/notes.txt"] != nil)
        #expect(manager.duplicateGroups.count == 2)            // the other two stay listed
    }

    /// An empty filtered set touches nothing — a query that matches no rows must not fall back to
    /// "well, do all of them", which is exactly what a nil-defaulted scope parameter would invite.
    @MainActor
    @Test func duplicatesEmptyFilteredSetTrashesNothing() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let size: [FileAttributeKey: Any] = [.size: 1000]
        for p in ["/a/x", "/b/x"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        manager.duplicateGroups = [grp("x", keeper: "/a/x", redundant: ["/b/x"])]

        await manager.applyRecommendedDuplicates([])

        #expect(mockFM.trashedPaths.isEmpty)
        #expect(mockFM.virtualDisk["/b/x"] != nil)
        #expect(manager.duplicateGroups.count == 1)
    }

    /// The scope is a scope, not an override: passing a group the batch rules exclude (a versions
    /// group discards genuinely different, older content) still doesn't trash it. Filtering can
    /// only ever narrow what a batch touches, never widen it.
    @MainActor
    @Test func scopeCannotWidenBatchEligibility() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let size: [FileAttributeKey: Any] = [.size: 1000]
        for p in ["/a/r (1).doc", "/a/r.doc"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        let versions = DuplicateGroup(
            matchType: .versions, name: "r.doc", isDirectory: false,
            copies: [copy("/a/r (1).doc", keeper: true), copy("/a/r.doc", keeper: false)],
            reclaimableBytes: 500)
        manager.duplicateGroups = [versions]

        await manager.applyRecommendedDuplicates([versions])   // explicitly handed the ineligible group

        #expect(mockFM.trashedPaths.isEmpty)
        #expect(mockFM.virtualDisk["/a/r.doc"] != nil)
    }

    // MARK: Organize

    private func write(_ url: URL, bytes: Int = 4096) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// Organize's side of the same rule: a filtered "File all N confident" moves only the files
    /// the search left on screen, and the one it hid stays exactly where it was.
    @MainActor
    @Test func filingBatchMovesOnlyTheFilteredSuggestions() async throws {
        let root = try makeCanonicalTempRoot(prefix: "BatchScopeFiling")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Documents/Invoices/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Tesla Policy.pdf"))
        try write(root.appendingPathComponent("Downloads/Invoices Q3.pdf"))

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        let eligible = manager.batchEligibleFilingSuggestions
        try #require(eligible.count == 2, "both files should have a confident, name-derived home")

        // What a `tesla` search leaves on screen.
        let filtered = eligible.filter { $0.fileName.localizedCaseInsensitiveContains("tesla") }
        #expect(filtered.count == 1)

        await manager.applyRecommendedFiling(filtered)

        // The searched-for file moved; the one the search hid did NOT.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Downloads/Tesla Policy.pdf").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Downloads/Invoices Q3.pdf").path))
        #expect(manager.filingSuggestions.count == 1)
    }

    /// Same empty-set guarantee on the filing side.
    @MainActor
    @Test func filingEmptyFilteredSetMovesNothing() async throws {
        let root = try makeCanonicalTempRoot(prefix: "BatchScopeFilingEmpty")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let source = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try write(source)

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        let before = manager.filingSuggestions.count

        await manager.applyRecommendedFiling([])

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(manager.filingSuggestions.count == before)
    }
}
