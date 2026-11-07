import Testing
import Foundation
@testable import Sync

/// Batch actions scope to the filtered set. Search narrows an Organize lens and the batch button
/// counts what is left ("Trash all 3"), so the action must iterate that same set, never an
/// unfiltered one: otherwise it trashes items the user couldn't see and didn't agree to.
/// `applyRecommendedDuplicates` and `applyRecommendedFiling` take the scope as a required
/// parameter; these tests pin that it is honoured.
@Suite struct BatchScopeTests {

    // MARK: Duplicates

    /// Same shape as FileSyncManagerDuplicatesTests' helper — a plain keeper/redundant pair.
    private func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
        .stub(path, keeper: keeper, unique: keeper ? 0 : 1, depth: path.filter { $0 == "/" }.count)
    }

    private func grp(_ name: String, keeper: String, redundant: [String]) -> DuplicateGroup {
        .stub([copy(keeper, keeper: true)] + redundant.map { copy($0, keeper: false) }, name: name, reclaimable: 1000)
    }

    /// Three eligible groups, a query leaving one ("Trash all 1"): exactly one copy goes to the
    /// Trash, and the two hidden groups stay untouched and listed.
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

        // One copy trashed, not three.
        #expect(mockFM.trashedPaths.count == 1)
        #expect(mockFM.virtualDisk["/b/holiday.jpg"] != nil)   // hidden by the search — must survive
        #expect(mockFM.virtualDisk["/b/notes.txt"] != nil)
        #expect(manager.duplicateGroups.count == 2)            // the other two stay listed
    }

    /// A group with nothing to remove is not counted as resolved. `allSatisfy` over an empty
    /// removal list is vacuously true, so a group whose only redundant copy is protected (inside a
    /// folder another group keeps) would be dropped and its bytes credited as reclaimed while every
    /// copy is still on disk. Re-aiming such a group's keeper produces this case.
    @MainActor
    @Test func aGroupWithNothingToRemoveIsNotReportedAsResolved() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        let size: [FileAttributeKey: Any] = [.size: 1000]
        for p in ["/a/x", "/b/x", "/a/y", "/kept/F1/y"] {
            mockFM.virtualDisk[p] = MockFileManager.FileStub(isDirectory: false, attributes: size, contents: nil)
        }
        let protectedOnly = DuplicateGroup.stub(
            [copy("/a/y", keeper: true), .stub("/kept/F1/y", keeper: false, unique: 1, depth: 3, protected: true)],
            reclaimable: 1000)
        #expect(protectedOnly.recommendedRemovalPaths.isEmpty)
        // Batched alongside a normal group, so the run gets past the "no paths at all" early exit.
        let normal = grp("x", keeper: "/a/x", redundant: ["/b/x"])
        manager.duplicateGroups = [normal, protectedOnly]

        await manager.applyRecommendedDuplicates(manager.duplicateGroups)
        await waitUntil("the removable copy is trashed") { mockFM.virtualDisk["/b/x"] == nil }

        #expect(mockFM.trashedPaths.count == 1)
        #expect(mockFM.virtualDisk["/kept/F1/y"] != nil, "the protected copy must still be on disk")
        #expect(manager.duplicateGroups.map(\.name) == ["y"],
                "and its group must stay listed rather than vanish as though it had been resolved")
    }

    /// An empty filtered set touches nothing: a query matching no rows must not fall back to all of
    /// them, as a nil-defaulted scope parameter would invite.
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
        let versions = DuplicateGroup.stub(
            [copy("/a/r (1).doc", keeper: true), copy("/a/r.doc", keeper: false)],
            matchType: .versions, name: "r.doc", reclaimable: 500)
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
        // Two words in common with each folder: one alone is Medium, and the batch takes only High.
        try write(root.appendingPathComponent("Documents/Tesla Policy/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Documents/Invoices Q3/.keep"), bytes: 1)
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
