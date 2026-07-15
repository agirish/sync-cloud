import Testing
import Foundation
@testable import Dashboard

/// Coverage for the folder quick-jump store and sibling enumeration behind the pane header's
/// jump menu. @MainActor because the store is.
@MainActor
@Suite struct FolderJumpStoreTests {

    private func loc(_ rel: String) -> JumpLocation {
        JumpLocation(relativePath: rel, name: (rel as NSString).lastPathComponent)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fj-test-\(UUID().uuidString)")!
    }

    // MARK: Recents ordering

    @Test func insertingMovesToFrontDedupesAndCaps() {
        var list: [JumpLocation] = []
        list = FolderJumpStore.inserting(loc("a"), into: list, cap: 3)
        list = FolderJumpStore.inserting(loc("b"), into: list, cap: 3)
        list = FolderJumpStore.inserting(loc("c"), into: list, cap: 3)
        #expect(list.map(\.relativePath) == ["c", "b", "a"])
        // Re-visiting "a" moves it to the front rather than duplicating it.
        list = FolderJumpStore.inserting(loc("a"), into: list, cap: 3)
        #expect(list.map(\.relativePath) == ["a", "c", "b"])
        // A fourth distinct entry evicts the oldest.
        list = FolderJumpStore.inserting(loc("d"), into: list, cap: 3)
        #expect(list.map(\.relativePath) == ["d", "a", "c"])
    }

    @Test func recordVisitIgnoresRootAndScopesByRoot() {
        let store = FolderJumpStore(defaults: freshDefaults())
        store.recordVisit(root: "/R", relativePath: "", name: "")            // the root is never "recent"
        store.recordVisit(root: "/R", relativePath: "Docs", name: "Docs")
        store.recordVisit(root: "/R", relativePath: "Docs/Taxes", name: "Taxes")
        #expect(store.recents(forRoot: "/R").map(\.relativePath) == ["Docs/Taxes", "Docs"])
        #expect(store.recents(forRoot: "/other").isEmpty)
    }

    // MARK: Pins

    @Test func togglePinPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let store = FolderJumpStore(defaults: defaults)
        #expect(store.isPinned(root: "/R", relativePath: "Docs") == false)
        store.togglePin(root: "/R", relativePath: "Docs", name: "Docs")
        #expect(store.isPinned(root: "/R", relativePath: "Docs") == true)
        // A fresh instance reads the persisted pins back.
        let reloaded = FolderJumpStore(defaults: defaults)
        #expect(reloaded.pinned(forRoot: "/R").map(\.relativePath) == ["Docs"])
        // Toggling the same folder removes it.
        reloaded.togglePin(root: "/R", relativePath: "Docs", name: "Docs")
        #expect(reloaded.isPinned(root: "/R", relativePath: "Docs") == false)
        defaults.removePersistentDomain(forName: defaults.description)
    }

    // MARK: Siblings

    @Test func siblingsExcludeCurrentAndFilesSorted() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fj-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("Projects")
        try fm.createDirectory(at: parent.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try fm.createDirectory(at: parent.appendingPathComponent("2025"), withIntermediateDirectories: true)
        try fm.createDirectory(at: parent.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        try "x".write(to: parent.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let siblings = FolderJump.siblings(rootPath: root.path, relativePath: "Projects/2026")
        // Excludes the current folder (2026) and the file; keeps the sibling directories, sorted.
        #expect(siblings.map(\.name) == ["2025", "Archive"])
        #expect(siblings.map(\.relativePath) == ["Projects/2025", "Projects/Archive"])
    }

    @Test func siblingsEmptyAtRootAndOnMissingParent() {
        #expect(FolderJump.siblings(rootPath: "/anything", relativePath: "").isEmpty)
        #expect(FolderJump.siblings(rootPath: "/no/such/root", relativePath: "Docs/Sub").isEmpty)
    }
}
