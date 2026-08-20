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

    /// **The two spellings each hold the same pin — which is the state the bug produced.**
    ///
    /// Before the keys were normalised, a folder pinned from the breadcrumb (tilde spelling) read
    /// as unpinned in the pane (expanded spelling), so pinning it again there was the obvious thing
    /// to do — and wrote a second entry for the same folder under the other key. Merging the two
    /// lists by concatenation therefore lands a duplicate on any install that hit the bug, which is
    /// every install the migration exists for.
    ///
    /// Two consequences, and the second is the one a person notices: the ⌘K palette lists the
    /// folder twice, and `togglePin` removed only the FIRST match — so unpinning it left it pinned,
    /// with no way to tell why.
    @Test func aFolderPinnedUnderBothSpellingsMergesToOnePinThatCanBeUnpinned() throws {
        let defaults = freshDefaults()
        let expanded = ("~/Documents" as NSString).expandingTildeInPath
        let legacy = [
            "~/Documents": [JumpLocation(relativePath: "Legal", name: "Legal")],
            expanded: [JumpLocation(relativePath: "Legal", name: "Legal"),
                       JumpLocation(relativePath: "Taxes", name: "Taxes")],
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "folderJumpPinnedByRoot")

        let store = FolderJumpStore(defaults: defaults)
        #expect(store.pinned(forRoot: expanded).map(\.relativePath) == ["Legal", "Taxes"],
                "the merge kept one folder twice; got \(store.pinned(forRoot: expanded).map(\.relativePath))")

        // And one toggle really unpins it, rather than peeling off one of two copies.
        store.togglePin(root: expanded, relativePath: "Legal", name: "Legal")
        #expect(!store.isPinned(root: expanded, relativePath: "Legal"),
                "unpinning removed one duplicate and left the folder pinned")
        #expect(store.pinned(forRoot: "~/Documents").map(\.relativePath) == ["Taxes"])
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

    // MARK: Recents outlive the session (v4.2)

    /// The ⌘K field's empty state IS this list, so a session-scoped one is empty at exactly the
    /// moment it is most wanted — the first ⌘K after launch.
    @Test func recentsSurviveARelaunch() {
        let defaults = freshDefaults()
        let store = FolderJumpStore(defaults: defaults)
        store.recordVisit(root: "/Volumes/Data", relativePath: "Legal", name: "Legal")
        store.recordVisit(root: "/Volumes/Data", relativePath: "Legal/2026", name: "2026")

        // A second store on the same domain is what a relaunch looks like from here.
        let relaunched = FolderJumpStore(defaults: defaults)
        #expect(relaunched.recentPaths(forRoot: "/Volumes/Data") == ["Legal/2026", "Legal"],
                "recents did not survive, or came back in the wrong order — newest leads")
    }

    /// Persisted recents go through the same key normalisation the pins do, so the two lists — read
    /// side by side by the same caller — cannot come to disagree about what a root is.
    @Test func recentsComeBackUnderEitherSpellingOfTheRoot() {
        let defaults = freshDefaults()
        let tilde = "~/Documents"
        let expanded = (tilde as NSString).expandingTildeInPath
        #expect(tilde != expanded)

        FolderJumpStore(defaults: defaults).recordVisit(root: tilde, relativePath: "Legal", name: "Legal")
        let relaunched = FolderJumpStore(defaults: defaults)
        #expect(relaunched.recentPaths(forRoot: expanded) == ["Legal"])
        #expect(relaunched.recentPaths(forRoot: tilde) == ["Legal"])
    }

    /// The cap is a constant that can be lowered. A list written under a larger one must not stay
    /// long forever, so it is applied on the way in as well as on the way out.
    @Test func aLongerStoredListIsCappedOnTheWayIn() throws {
        let defaults = freshDefaults()
        let stored = ["/Volumes/Data": (1...12).map { loc("F\($0)") }]
        // The fixture only means something if it is longer than the cap.
        #expect(stored["/Volumes/Data"]!.count > FolderJumpStore.maxRecents)
        defaults.set(try JSONEncoder().encode(stored), forKey: "folderJumpRecentsByRoot")

        let store = FolderJumpStore(defaults: defaults)
        let back = store.recentPaths(forRoot: "/Volumes/Data")
        #expect(back.count == FolderJumpStore.maxRecents)
        #expect(back.first == "F1" && back.last == "F8", "the cap kept the wrong end of the list")
    }

    // MARK: A remembered folder that has gone

    @Test func reachableKeepsWhatIsThereAndDropsWhatIsGone() {
        let present: Set<String> = ["/root", "/root/Legal", "/root/Legal/2026"]
        let kept = FolderJumpStore.reachable(recents: ["Legal", "Gone", "Legal/2026"], pinned: [],
                                             underRoot: "/root") { present.contains($0) }
        #expect(kept.recents == ["Legal", "Legal/2026"],
                "order is the list's order, and a gone folder is absent")
    }

    /// The root is checked first so an unreachable mount costs ONE stalled `stat`, not one per
    /// remembered folder — which is the whole reason the guard is there rather than relying on
    /// each child answering false.
    @Test func reachableStopsAtAMissingRootAfterASingleCheck() {
        var asked: [String] = []
        let kept = FolderJumpStore.reachable(recents: ["A", "B", "C", "D"], pinned: [],
                                             underRoot: "/asleep") { path in
            asked.append(path)
            return false
        }
        #expect(kept.rootIsAvailable == false)
        #expect(asked == ["/asleep"], "every remembered folder was stat'ed under a root already known to be gone")
    }

    /// Filtered, never pruned: an external drive asleep at the wrong moment must not cost the user
    /// the entries. The list is drawn from the store, and the store is not written back to.
    @Test func filteringDoesNotTouchWhatIsStored() {
        let defaults = freshDefaults()
        let store = FolderJumpStore(defaults: defaults)
        store.recordVisit(root: "/asleep", relativePath: "Legal", name: "Legal")

        let drawn = FolderJumpStore.reachable(recents: store.recentPaths(forRoot: "/asleep"), pinned: [],
                                              underRoot: "/asleep") { _ in false }
        #expect(drawn.rootIsAvailable == false, "the fixture's root answered — nothing here is exercised")
        #expect(store.recentPaths(forRoot: "/asleep") == ["Legal"], "drawing the list pruned the store")
        #expect(FolderJumpStore(defaults: defaults).recentPaths(forRoot: "/asleep") == ["Legal"],
                "the entry did not survive to the next launch — a sleeping drive cost the user their recents")
    }

    // MARK: A root that is merely asleep

    /// **An asleep root keeps its rows; a live root drops what has gone.** The two are different
    /// claims and the single-list signature can only make the first, which is why the two-list one
    /// exists (decided 2026-08-19, ROADMAP_V4 §7).
    ///
    /// The consequence if this regresses is not one missing row: the root is checked first, so
    /// every recent and every pin goes at once — and ⌘K's empty-query landing IS that list, so the
    /// palette opens blank and "I have no recents" cannot be told from "my drive is not awake".
    @Test func anAsleepRootKeepsEverythingRememberedAndSaysSo() {
        var asked: [String] = []
        let resolved = FolderJumpStore.reachable(recents: ["Legal", "Tax"], pinned: ["Clients"],
                                                 underRoot: "/asleep") { path in
            asked.append(path)
            return false
        }
        #expect(resolved.rootIsAvailable == false)
        #expect(resolved.recents == ["Legal", "Tax"], "an asleep drive cost the user their recents")
        #expect(resolved.pinned == ["Clients"], "an asleep drive cost the user their pins")
        #expect(asked == ["/asleep"],
                "a folder was stat'ed under a root already known to be gone — the one stalled call became several")
    }

    /// The other half, and it must still drop: under a root that answered, a folder that is gone
    /// cannot be delivered and must not be offered.
    @Test func aLiveRootStillDropsWhatHasGone() {
        let present: Set<String> = ["/root", "/root/Legal", "/root/Clients"]
        let resolved = FolderJumpStore.reachable(recents: ["Legal", "Gone"], pinned: ["Clients", "AlsoGone"],
                                                 underRoot: "/root") { present.contains($0) }
        #expect(resolved.rootIsAvailable)
        #expect(resolved.recents == ["Legal"])
        #expect(resolved.pinned == ["Clients"])
    }

    /// The root is `stat`ed **once for both lists**, not once per list. Under an unreachable mount
    /// each of those can block, and this is the call site that resolves recents and pins together.
    @Test func theRootIsAskedOnceForBothLists() {
        var rootChecks = 0
        _ = FolderJumpStore.reachable(recents: ["A"], pinned: ["B"], underRoot: "/root") { path in
            if path == "/root" { rootChecks += 1 }
            return true
        }
        #expect(rootChecks == 1, "the root was stat'ed once per list — under a sleeping mount that is one stall per list")
    }

    /// The root's own spellings are refused whichever way the root answered — an asleep root must
    /// not smuggle in a `"."` row that a live one would have filtered.
    @Test func anAsleepRootStillRefusesTheRootsOwnSpellings() {
        let resolved = FolderJumpStore.reachable(recents: ["", ".", "Legal"], pinned: ["."],
                                                 underRoot: "/asleep") { _ in false }
        #expect(resolved.recents == ["Legal"])
        #expect(resolved.pinned.isEmpty)
    }

    /// The root itself is never a row (`emptyQueryRows` skips "" and "."), and neither is it a
    /// path to `stat` — a `"."` under a live root exists, so without this it would be offered.
    @Test func reachableRefusesTheRootsOwnSpellings() {
        let kept = FolderJumpStore.reachable(recents: ["", ".", "Legal"], pinned: [],
                                             underRoot: "/root") { _ in true }
        #expect(kept.recents == ["Legal"])
    }
}
