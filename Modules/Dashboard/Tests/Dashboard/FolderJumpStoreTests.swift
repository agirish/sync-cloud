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

    private func freshDefaults() -> ScratchDefaults {
        ScratchDefaults("fj-test")
    }

    // MARK: One spelling of a root

    /// Two spellings of one provider root must reach the same entry.
    ///
    /// A folder source's path is stored with its `~` intact, so the app holds two spellings of the
    /// same root and hands whichever one a call site happens to have to this store. They were used
    /// raw as dictionary keys on both sides, so a pin written under one was invisible to a reader
    /// holding the other — and nothing said so, because "no pins" is what an unpinned provider
    /// looks like too.
    @Test func aTildeRootAndItsExpandedFormAreOneKey() {
        let store = FolderJumpStore(defaults: freshDefaults())
        let tilde = "~/Documents"
        let expanded = (tilde as NSString).expandingTildeInPath
        // The fixture only means something if the two really are different strings.
        #expect(tilde != expanded)

        store.togglePin(root: tilde, relativePath: "Legal", name: "Legal")
        store.recordVisit(root: tilde, relativePath: "Legal/2026", name: "2026")

        #expect(store.pinned(forRoot: expanded).map(\.relativePath) == ["Legal"],
                "a pin written under the tilde spelling is invisible to the expanded one")
        #expect(store.recents(forRoot: expanded).map(\.relativePath) == ["Legal/2026"])
        #expect(store.isPinned(root: expanded, relativePath: "Legal"))
        // The two the ⌘K palette actually reads — this line carries the symptom the report named:
        // no Pinned and no Recent group under a folder source, surviving relaunch, while typed
        // folder queries kept working and made it look intermittent rather than broken.
        #expect(store.pinnedPaths(forRoot: expanded) == ["Legal"])
        #expect(store.recentPaths(forRoot: expanded) == ["Legal/2026"])
        // And the other direction, so neither spelling is privileged.
        store.togglePin(root: expanded, relativePath: "Taxes", name: "Taxes")
        #expect(Set(store.pinned(forRoot: tilde).map(\.relativePath)) == ["Legal", "Taxes"])
    }

    /// A trailing slash is the same root too — it arrives from hand-typed Settings paths.
    @Test func aTrailingSlashIsTheSameRoot() {
        let store = FolderJumpStore(defaults: freshDefaults())
        store.togglePin(root: "/Volumes/Data/", relativePath: "Docs", name: "Docs")
        #expect(store.pinned(forRoot: "/Volumes/Data").map(\.relativePath) == ["Docs"])
    }

    /// Pins already on disk under the old raw key must survive the change that normalised keys.
    /// Silently orphaning them would be this fix losing the very data it exists to make reachable.
    @Test func pinsPersistedUnderTheOldRawKeyAreStillFound() throws {
        let defaults = freshDefaults()
        let legacy = ["~/Documents": [JumpLocation(relativePath: "Legal", name: "Legal")]]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "folderJumpPinnedByRoot")

        let store = FolderJumpStore(defaults: defaults)
        let expanded = ("~/Documents" as NSString).expandingTildeInPath
        #expect(store.pinned(forRoot: expanded).map(\.relativePath) == ["Legal"])
        #expect(store.pinned(forRoot: "~/Documents").map(\.relativePath) == ["Legal"])
    }

    /// A `~` root already works here, and this pins that it keeps working.
    ///
    /// **Written to reproduce a reported defect, which it disproved.** The report was that
    /// `parentAbsolute = rootPath + "/" + parentRelative` handed to `URL(fileURLWithPath:)`
    /// resolves `~/…` against the working directory, so the listing throws and the menu's "Nearby
    /// folders" section never appears under a folder source. Measured on this machine, with the
    /// working directory somewhere else entirely:
    ///
    ///     fileExists(atPath: "~/x")            false
    ///     URL(fileURLWithPath: "~/x").path     /Users/<me>/x        <- expanded
    ///     contentsOfDirectory(at: thatURL)     OK
    ///     contentsOfDirectory(atPath: "~/x")   throws, NSFileNoSuchFileError
    ///
    /// So `URL(fileURLWithPath:)` expands the tilde and only the PATH-based calls do not. The walk
    /// is correct as written; this test exists so that stays true — swapping the URL call for
    /// `contentsOfDirectory(atPath:)` would look equivalent and would break exactly the folder
    /// sources the report was about.
    @Test func siblingsResolveATildeRoot() throws {
        let fm = FileManager.default
        // A real directory, reached through a spelling that only works if it is expanded. HOME is
        // the one root a test can name both ways without inventing a fixture outside it.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let base = home.appendingPathComponent(".synccloud-jump-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        for name in ["Legal", "Taxes", "Receipts"] {
            try fm.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        let tildeRoot = "~/" + base.lastPathComponent
        // The fixture is only meaningful if the unexpanded spelling really is unusable as a path.
        try #require(!fm.fileExists(atPath: tildeRoot))

        let siblings = FolderJump.siblings(rootPath: tildeRoot, relativePath: "Legal", showHidden: true)
        #expect(siblings.map(\.name) == ["Receipts", "Taxes"],
                "the tilde root was not expanded, so the parent listing threw and the section vanished")
        // The relative paths stay relative to the ROOT, whichever way it was spelled.
        #expect(siblings.map(\.relativePath) == ["Receipts", "Taxes"])
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

    @Test func siblingsHonorShowHiddenSetting() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fjh-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("Projects")
        try fm.createDirectory(at: parent.appendingPathComponent("2026"), withIntermediateDirectories: true)
        try fm.createDirectory(at: parent.appendingPathComponent(".secret"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Hidden off: the hidden sibling is filtered (and 2026 is the current folder) → nothing.
        #expect(FolderJump.siblings(rootPath: root.path, relativePath: "Projects/2026", showHidden: false).isEmpty)
        // Hidden on: it appears, matching what the pane would show.
        #expect(FolderJump.siblings(rootPath: root.path, relativePath: "Projects/2026", showHidden: true).map(\.name) == [".secret"])
    }
}
