import Testing
import Foundation
import Sync
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

    /// Two spellings of one provider root reach the same entry. A folder source's path is stored
    /// with its `~` intact, so call sites hand this store either spelling. Raw keys would hide a pin
    /// written under one from a reader holding the other, silently, since "no pins" looks normal.
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
        // The two the ⌘K palette reads: without this, a folder source shows no Pinned or Recent
        // group while typed folder queries keep working, which looks intermittent.
        #expect(store.pinnedPaths(forRoot: expanded) == ["Legal"])
        #expect(store.recentPaths(forRoot: expanded) == ["Legal/2026"])
        // And the other direction, so neither spelling is privileged.
        store.togglePin(root: expanded, relativePath: "Taxes", name: "Taxes")
        #expect(Set(store.pinned(forRoot: tilde).map(\.relativePath)) == ["Legal", "Taxes"])
    }

    /// A trailing slash is the same root too; it arrives from hand-typed Settings paths.
    @Test func aTrailingSlashIsTheSameRoot() {
        let store = FolderJumpStore(defaults: freshDefaults())
        store.togglePin(root: "/Volumes/Data/", relativePath: "Docs", name: "Docs")
        #expect(store.pinned(forRoot: "/Volumes/Data").map(\.relativePath) == ["Docs"])
    }

    /// Pins stored under a raw, unnormalised key are still found, rather than orphaned.
    @Test func pinsPersistedUnderTheOldRawKeyAreStillFound() throws {
        let defaults = freshDefaults()
        let legacy = ["~/Documents": [JumpLocation(relativePath: "Legal", name: "Legal")]]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "folderJumpPinnedByRoot")

        let store = FolderJumpStore(defaults: defaults)
        let expanded = ("~/Documents" as NSString).expandingTildeInPath
        #expect(store.pinned(forRoot: expanded).map(\.relativePath) == ["Legal"])
        #expect(store.pinned(forRoot: "~/Documents").map(\.relativePath) == ["Legal"])
    }

    /// Both raw spellings can hold the same pin (pinned once under each), so merging them by
    /// concatenation would keep a duplicate. Then ⌘K lists the folder twice, and `togglePin`,
    /// which removes the first match, leaves it pinned after an unpin.
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

    /// A `~` root lists its siblings. `URL(fileURLWithPath:)` expands the tilde, but path-based
    /// calls don't:
    ///
    ///     fileExists(atPath: "~/x")            false
    ///     URL(fileURLWithPath: "~/x").path     /Users/<me>/x        <- expanded
    ///     contentsOfDirectory(at: thatURL)     OK
    ///     contentsOfDirectory(atPath: "~/x")   throws, NSFileNoSuchFileError
    ///
    /// Swapping the URL call for `contentsOfDirectory(atPath:)` would look equivalent and empty the
    /// menu's "Nearby folders" section for every folder source.
    @Test func siblingsResolveATildeRoot() throws {
        let fm = FileManager.default
        // A real directory, reached through a spelling that only works if expanded. HOME is the
        // one root a test can name both ways without a fixture outside it.
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
        // The relative paths stay relative to the root, whichever way it was spelled.
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

    /// A folder the root links in from outside. It is listed as a sibling even though macOS flags
    /// the link hidden (hidden means a leading dot, as in the pane), and the folders inside it list
    /// through the link's real target: `contentsOfDirectory(at:)` returns nothing for a URL whose
    /// last component is the link itself.
    @Test func siblingsSeeThroughALinkedFolderAndDoNotHideItByFlag() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("fjl-\(UUID().uuidString)")
        let container = base.appendingPathComponent("container")
        let real = base.appendingPathComponent("outside").appendingPathComponent("Documents")
        try fm.createDirectory(at: container.appendingPathComponent("Word"), withIntermediateDirectories: true)
        try fm.createDirectory(at: real.appendingPathComponent("Family"), withIntermediateDirectories: true)
        try fm.createDirectory(at: real.appendingPathComponent("Legal"), withIntermediateDirectories: true)
        let link = container.appendingPathComponent("Documents")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        // The flag macOS puts on iCloud Drive's two links, which `.skipsHiddenFiles` would honour.
        try fm.setAttributes([.extensionHidden: true], ofItemAtPath: link.path)
        var values = URLResourceValues(); values.isHidden = true
        var flagged = link; try flagged.setResourceValues(values)
        defer { try? fm.removeItem(at: base) }
        let links: PathBoundary.LinkedFolders = [container.path: ["Documents": real.path]]

        // At the root: Word's siblings include the hidden-flagged link, by name.
        #expect(FolderJump.siblings(rootPath: container.path, relativePath: "Word", links: links).map(\.name)
                == ["Documents"])
        // Inside the link: the parent is the real folder, so the listing works and stays relative
        // to the root through the link's name.
        let inside = FolderJump.siblings(rootPath: container.path, relativePath: "Documents/Family", links: links)
        #expect(inside.map(\.name) == ["Legal"])
        #expect(inside.map(\.relativePath) == ["Documents/Legal"])
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

    /// The ⌘K field's empty state is this list, so a session-scoped one would be empty when most
    /// wanted: the first ⌘K after launch.
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

    /// Persisted recents go through the same key normalisation as pins, so the two lists, read side
    /// by side, can't disagree about what a root is.
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

    // MARK: Forgetting one recent (the sidebar's Remove from Recents)

    /// The sidebar row's verb: the entry goes, the rest of the list is untouched, and it stays gone
    /// across a relaunch.
    @Test func forgettingARecentTakesThatOneAndPersists() {
        let defaults = freshDefaults()
        let store = FolderJumpStore(defaults: defaults)
        store.recordVisit(root: "/Volumes/Data", relativePath: "Legal", name: "Legal")
        store.recordVisit(root: "/Volumes/Data", relativePath: "Taxes", name: "Taxes")
        store.recordVisit(root: "/Volumes/Data", relativePath: "Legal/2026", name: "2026")

        store.forgetRecent(root: "/Volumes/Data", relativePath: "Taxes")

        #expect(store.recentPaths(forRoot: "/Volumes/Data") == ["Legal/2026", "Legal"],
                "the wrong entry went, or the order moved")
        #expect(FolderJumpStore(defaults: defaults).recentPaths(forRoot: "/Volumes/Data")
                == ["Legal/2026", "Legal"], "the removal did not survive a relaunch")
    }

    /// Either spelling of the root reaches the entry, as for every other member: the sidebar row
    /// carries a normalised root and the pane the stored `~` form, so a raw key would silently
    /// remove nothing from a folder source.
    @Test func forgettingARecentNormalisesItsRoot() {
        let store = FolderJumpStore(defaults: freshDefaults())
        let tilde = "~/Documents"
        #expect(tilde != (tilde as NSString).expandingTildeInPath)
        // Recorded under the expanded spelling and forgotten under the tilde, so the two meet only
        // if this verb normalises.
        store.recordVisit(root: (tilde as NSString).expandingTildeInPath,
                          relativePath: "Legal", name: "Legal")

        store.forgetRecent(root: tilde, relativePath: "Legal")
        #expect(store.recentPaths(forRoot: tilde).isEmpty)
    }

    /// Forgotten, not suppressed: going back to the folder writes the row again. The list records
    /// visits; Favorites is the curated one.
    @Test func visitingAForgottenFolderRecordsItAgain() {
        let store = FolderJumpStore(defaults: freshDefaults())
        store.recordVisit(root: "/Volumes/Data", relativePath: "Legal", name: "Legal")
        store.forgetRecent(root: "/Volumes/Data", relativePath: "Legal")
        #expect(store.recentPaths(forRoot: "/Volumes/Data").isEmpty)

        store.recordVisit(root: "/Volumes/Data", relativePath: "Legal", name: "Legal")
        #expect(store.recentPaths(forRoot: "/Volumes/Data") == ["Legal"])
    }

    /// Recents and favorites are two lists, and this verb touches one. The sidebar never draws a
    /// recent that is also a favorite (`mostRecentAcrossRoots` subtracts pins), but the store allows
    /// it, and removing the pin would be an act nobody asked for.
    @Test func forgettingARecentLeavesTheFavoriteAlone() {
        let store = FolderJumpStore(defaults: freshDefaults())
        store.recordVisit(root: "/Volumes/Data", relativePath: "Legal", name: "Legal")
        store.togglePin(root: "/Volumes/Data", relativePath: "Legal", name: "Legal")

        store.forgetRecent(root: "/Volumes/Data", relativePath: "Legal")
        #expect(store.isPinned(root: "/Volumes/Data", relativePath: "Legal"))
    }

    /// A root with nothing remembered, and a folder not in the list, are both silent: the row
    /// leaves the screen only on the refresh after a click, so a second click is ordinary.
    @Test func forgettingSomethingThatIsNotThereChangesNothing() {
        let defaults = freshDefaults()
        let store = FolderJumpStore(defaults: defaults)
        store.recordVisit(root: "/Volumes/Data", relativePath: "Legal", name: "Legal")

        store.forgetRecent(root: "/Volumes/Nothing", relativePath: "Legal")
        store.forgetRecent(root: "/Volumes/Data", relativePath: "Taxes")
        #expect(store.recentPaths(forRoot: "/Volumes/Data") == ["Legal"])
    }

    // MARK: A remembered folder that has gone

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

    /// An asleep root keeps its rows; a live root drops what has gone. If this regresses, every
    /// recent and pin goes at once (the root is checked first), and ⌘K's empty-query landing is
    /// that list, so the palette opens blank and "no recents" looks like "drive asleep".
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

    /// The other half: under a root that answered, a folder that is gone can't be reached and must
    /// not be offered.
    @Test func aLiveRootStillDropsWhatHasGone() {
        let present: Set<String> = ["/root", "/root/Legal", "/root/Legal/2026", "/root/Clients"]
        let resolved = FolderJumpStore.reachable(recents: ["Legal", "Gone", "Legal/2026"],
                                                 pinned: ["Clients", "AlsoGone"],
                                                 underRoot: "/root") { present.contains($0) }
        #expect(resolved.rootIsAvailable)
        #expect(resolved.recents == ["Legal", "Legal/2026"], "order is the list's order, and a gone folder is absent")
        #expect(resolved.pinned == ["Clients"])
    }

    /// The root is `stat`ed once for both lists, not once per list: under an unreachable mount
    /// each call can block.
    @Test func theRootIsAskedOnceForBothLists() {
        var rootChecks = 0
        _ = FolderJumpStore.reachable(recents: ["A"], pinned: ["B"], underRoot: "/root") { path in
            if path == "/root" { rootChecks += 1 }
            return true
        }
        #expect(rootChecks == 1, "the root was stat'ed once per list — under a sleeping mount that is one stall per list")
    }

    /// The root's own spellings are refused however the root answered: an asleep root must not let
    /// in a `"."` row a live one would filter.
    @Test func anAsleepRootStillRefusesTheRootsOwnSpellings() {
        let resolved = FolderJumpStore.reachable(recents: ["", ".", "Legal"], pinned: ["."],
                                                 underRoot: "/asleep") { _ in false }
        #expect(resolved.recents == ["Legal"])
        #expect(resolved.pinned.isEmpty)
    }

    /// The root itself is never a row (`emptyQueryRows` skips "" and "."), nor a path to `stat`: a
    /// `"."` under a live root exists, so it would otherwise be offered.
    @Test func reachableRefusesTheRootsOwnSpellings() {
        let kept = FolderJumpStore.reachable(recents: ["", ".", "Legal"], pinned: [],
                                             underRoot: "/root") { _ in true }
        #expect(kept.recents == ["Legal"])
    }

    // MARK: Bytes this build cannot read

    /// An unreadable pins blob is not destroyed by the next pin. If a failed decode started the
    /// store at `[:]`, the first `togglePin` would write that empty map over every curated pin. The
    /// loss is on the write, not the read, so this asserts what the store writes back and that the
    /// original bytes survive it.
    @Test func unreadablePinsSurviveTheNextWrite() throws {
        let defaults = freshDefaults()
        let corrupt = Data("{ this is not the shape it was ".utf8)
        defaults.set(corrupt, forKey: FolderJumpStore.pinnedKey)

        let store = FolderJumpStore(defaults: defaults)
        #expect(store.pinned(forRoot: "/root").isEmpty, "undecodable bytes must not become pins")

        store.togglePin(root: "/root", relativePath: "Legal", name: "Legal")

        let salvage = FolderJumpStore.salvageKey(for: FolderJumpStore.pinnedKey)
        #expect(defaults.data(forKey: salvage) == corrupt, """
                the original pins were not preserved. They are unrecoverable at this point: the \
                write below has already replaced the live key.
                """)
        // …and the store is usable, rather than locked out.
        let written = try #require(defaults.data(forKey: FolderJumpStore.pinnedKey))
        let decoded = try JSONDecoder().decode([String: [JumpLocation]].self, from: written)
        #expect(decoded["/root"]?.map(\.relativePath) == ["Legal"],
                "the new pin did not land — refusing the write is not what this fix does")
    }

    /// Recents get the identical treatment, because the two lists are read side by side.
    @Test func unreadableRecentsArePreservedToo() {
        let defaults = freshDefaults()
        let corrupt = Data("[not a map]".utf8)
        defaults.set(corrupt, forKey: FolderJumpStore.recentsKey)

        let store = FolderJumpStore(defaults: defaults)
        store.recordVisit(root: "/root", relativePath: "Legal", name: "Legal")

        #expect(defaults.data(forKey: FolderJumpStore.salvageKey(for: FolderJumpStore.recentsKey)) == corrupt)
        #expect(store.recentPaths(forRoot: "/root") == ["Legal"])
    }

    /// A second failure must not overwrite the first stash, which holds the real data. A later
    /// launch reads whatever was written since (a nearly empty map, or another corruption), and
    /// stashing that on top would destroy the list one launch later.
    @Test func theFirstStashIsTheOneThatIsKept() {
        let defaults = freshDefaults()
        let salvage = FolderJumpStore.salvageKey(for: FolderJumpStore.pinnedKey)
        let original = Data("the user's real pins".utf8)
        defaults.set(original, forKey: salvage)
        defaults.set(Data("a later, different corruption".utf8), forKey: FolderJumpStore.pinnedKey)

        _ = FolderJumpStore(defaults: defaults)

        #expect(defaults.data(forKey: salvage) == original,
                "a later failure overwrote the stash holding the user's actual pins")
    }

    /// Absent is not unreadable: a fresh install writes no salvage key.
    @Test func anAbsentKeyStashesNothing() {
        let defaults = freshDefaults()
        _ = FolderJumpStore(defaults: defaults)
        #expect(defaults.data(forKey: FolderJumpStore.salvageKey(for: FolderJumpStore.pinnedKey)) == nil)
        #expect(defaults.data(forKey: FolderJumpStore.salvageKey(for: FolderJumpStore.recentsKey)) == nil)
    }

    /// The ordinary case is untouched: readable bytes decode and stash nothing.
    @Test func readablePinsAreUnaffected() {
        let defaults = freshDefaults()
        let seeded = FolderJumpStore(defaults: defaults)
        seeded.togglePin(root: "/root", relativePath: "Legal", name: "Legal")

        let reopened = FolderJumpStore(defaults: defaults)
        #expect(reopened.pinnedPaths(forRoot: "/root") == ["Legal"])
        #expect(defaults.data(forKey: FolderJumpStore.salvageKey(for: FolderJumpStore.pinnedKey)) == nil,
                "a perfectly readable list was treated as unreadable")
    }
}

