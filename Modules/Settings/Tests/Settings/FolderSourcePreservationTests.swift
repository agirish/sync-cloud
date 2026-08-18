import Foundation
import Testing
import Sync
@testable import Settings

/// **The user's curated source list was decoded with `try? … ?? []` — no log, no backup.**
///
/// And the loss was invisible twice over. `init` assigns the property directly, so the `didSet`
/// that persists it does not fire: nothing is written at launch and Settings simply looks like a
/// fresh install. The first add, remove or path edit then fires it and writes the empty-based list
/// over the bytes that were still on disk — so the only copy of a hand-curated list disappears at
/// the moment the user opens the panel to ask where it went.
@MainActor
@Suite struct FolderSourcePreservationTests {

    private func freshDefaults() -> ScratchDefaults { ScratchDefaults("folder-sources") }

    @Test func anUnreadableListIsKeptUnderASiblingKey() throws {
        let defaults = freshDefaults()
        let corrupt = Data("{ half a write".utf8)
        defaults.set(corrupt, forKey: "folderSources")

        let sources = SettingsManager.readFolderSources(from: defaults)

        #expect(sources.isEmpty, "an unreadable list must not be guessed at")
        #expect(defaults.data(forKey: "folderSources.unreadable") == corrupt,
                "the only copy of the user's list was dropped")
    }

    /// **The step that actually destroyed it.** Reading is not what overwrote the bytes — the next
    /// write did. With the payload preserved, that write can no longer be the end of it.
    @Test func aLaterWriteDoesNotDestroyThePreservedCopy() throws {
        let defaults = freshDefaults()
        let corrupt = Data("{ half a write".utf8)
        defaults.set(corrupt, forKey: "folderSources")
        _ = SettingsManager.readFolderSources(from: defaults)

        // What the didSet does on the first add/remove/setPath: write the live (empty-based) list.
        defaults.set(try JSONEncoder().encode([FolderSource]()), forKey: "folderSources")

        #expect(defaults.data(forKey: "folderSources.unreadable") == corrupt)
    }

    /// A first launch has no bytes and must not report anything — absent is not unreadable.
    @Test func anAbsentListIsSimplyEmpty() {
        let defaults = freshDefaults()
        #expect(SettingsManager.readFolderSources(from: defaults).isEmpty)
        #expect(defaults.data(forKey: "folderSources.unreadable") == nil,
                "a fresh install wrote a backup of nothing")
    }

    /// And a readable list still decodes — the guard must not be reached for ordinary data.
    @Test func aReadableListStillDecodes() throws {
        let defaults = freshDefaults()
        let sources = [FolderSource.new(path: "~/Archive")]
        defaults.set(try JSONEncoder().encode(sources), forKey: "folderSources")
        #expect(SettingsManager.readFolderSources(from: defaults).map(\.path) == ["~/Archive"])
        #expect(defaults.data(forKey: "folderSources.unreadable") == nil)
    }

    /// A re-launch on a still-corrupt store must not rewrite the same payload every time — the
    /// backup is the bytes, not a log of attempts.
    @Test func rereadingDoesNotRewriteTheBackup() throws {
        let defaults = freshDefaults()
        defaults.set(Data("{ half".utf8), forKey: "folderSources")
        _ = SettingsManager.readFolderSources(from: defaults)
        let firstWrite = defaults.data(forKey: "folderSources.unreadable")
        // A different value under the backup key would mean the second read overwrote it.
        _ = SettingsManager.readFolderSources(from: defaults)
        #expect(defaults.data(forKey: "folderSources.unreadable") == firstWrite)
    }
}
