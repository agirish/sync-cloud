import Testing
import Foundation
@testable import Sync

/// Manager-level coverage for Filing: the end-to-end scan (real folders) and the apply path
/// (real move, creating new folders, undoable).
@Suite struct FileSyncManagerFilingTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilingTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func write(_ url: URL, bytes: Int = 5000, fill: UInt8 = 0x41) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    @MainActor
    @Test func findFilingSuggestionsFindsHomesInYourFolders() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)   // existing Vehicles folder
        try write(root.appendingPathComponent("Downloads/Tesla Auto Policy.pdf"))
        try write(root.appendingPathComponent("Downloads/zxqw9.bin"))

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)

        #expect(manager.hasSuggestedFiling)
        let tesla = manager.filingSuggestions.first { $0.fileName.hasPrefix("Tesla") }
        #expect(tesla?.best?.path.hasSuffix("Documents/Vehicles/Tesla/Insurance") == true)
        #expect(tesla?.best?.newSegments == ["Tesla", "Insurance"])
        // The unrecognized file appears but with no confident home.
        let junk = manager.filingSuggestions.first { $0.fileName == "zxqw9.bin" }
        #expect(junk?.hasConfidentHome == false)
    }

    @MainActor
    @Test func applyFilingMovesFileAndCreatesNewFolders() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        let srcPath = root.appendingPathComponent("Downloads/Tesla Policy.pdf")
        try write(srcPath)

        let manager = FileSyncManager()
        let suggestion = FilingSuggestion(filePath: srcPath.path, fileName: "Tesla Policy.pdf",
                                          size: 5000, modificationDate: nil, candidates: [])
        let dest = FilingDestination(path: root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance").path,
                                     confidence: .medium, reasons: [], newSegments: ["Tesla", "Insurance"])
        manager.filingSuggestions = [suggestion]

        let ok = await manager.applyFilingSuggestion(suggestion, to: dest)

        let movedPath = root.appendingPathComponent("Documents/Vehicles/Tesla/Insurance/Tesla Policy.pdf").path
        #expect(ok)
        #expect(FileManager.default.fileExists(atPath: movedPath))          // moved, new folders created
        #expect(!FileManager.default.fileExists(atPath: srcPath.path))      // gone from Downloads
        #expect(manager.filingSuggestions.isEmpty)                          // dropped from the list
        #expect(manager.banner?.severity == .success)
    }

    @MainActor
    @Test func applyRecommendedFilesConfidentOnlyLeavesTheRest() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Documents/Vehicles/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/Tesla Policy.pdf"))
        let junkPath = root.appendingPathComponent("Downloads/zxqw9.bin")
        try write(junkPath)

        let manager = FileSyncManager()
        await manager.findFilingSuggestions(folder: root.appendingPathComponent("Downloads"), providerRoot: root)
        #expect(manager.filingSuggestions.count == 2)

        await manager.applyRecommendedFiling()

        // The Tesla file moved; the unrecognized one stays put and stays in the list.
        #expect(FileManager.default.fileExists(atPath: junkPath.path))
        #expect(manager.filingSuggestions.count == 1)
        #expect(manager.filingSuggestions.first?.fileName == "zxqw9.bin")
    }

    @MainActor
    @Test func clearFilingResetsState() {
        let manager = FileSyncManager()
        manager.filingSuggestions = [FilingSuggestion(filePath: "/a/x", fileName: "x", size: 1,
                                                      modificationDate: nil, candidates: [])]
        manager.filingScanFolder = "/a"
        manager.hasSuggestedFiling = true

        manager.clearFiling()

        #expect(manager.filingSuggestions.isEmpty)
        #expect(manager.filingScanFolder == nil)
        #expect(manager.hasSuggestedFiling == false)
    }
}
