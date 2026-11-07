import Testing
import Foundation
import Sync
import Settings
@testable import Dashboard

/// Coverage for FileActionHandler's pure string logic: relative-path derivation in focusFolder,
/// provider root matching (incl. the "/" prefix boundary), and AppleScript escaping.
@Suite struct FileActionHandlerHelperTests {

    /// Which panes a drill into a left-pane folder moves.
    ///
    /// Unlinked, the default: a fresh scratch suite has no value for the key, and the right pane
    /// stays put. Linked but suppressed: the single-source rail reuses the left pane's plumbing but
    /// has no visible sibling, so with 🔗 on, drilling the rail must not drag the hidden right pane
    /// along, growing its history, overwriting its saved focus and recording Recents the user never
    /// visited (the rail's delegate passes `suppressLinkedNavigation`). Linked: drilling into a
    /// folder from the file list moves the sibling to the same relative path, not only breadcrumb
    /// clicks.
    @MainActor
    @Test(arguments: [(false, false, ""), (true, true, ""), (true, false, "Projects/Sync")])
    func testFocusFolderMovesTheSiblingOnlyWhenLinkedAndNotSuppressed(linked: Bool, suppress: Bool,
                                                                      right: String) {
        let defaults = ScratchDefaults("FileActionHandlerHelperTests")
        if linked { defaults.set(true, forKey: PaneLinkPreference.defaultsKey) }
        let manager = FileSyncManager()
        let settings = scratchSettings() // seeded iCloud provider only
        let handler = FileActionHandler(syncManager: manager, settings: settings, defaults: defaults,
                                        pasteboard: scratchPasteboard("focus-\(linked)-\(suppress)"))

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud",
                            suppressLinkedNavigation: suppress)
        #expect(manager.leftRelativePath == "Projects/Sync")
        #expect(manager.rightRelativePath == right)
    }

    @MainActor
    @Test func testFocusFolderOnRootYieldsEmptyRelativePath() {
        let manager = FileSyncManager()
        let settings = scratchSettings()
        let handler = FileActionHandler(syncManager: manager, settings: settings,
                                        defaults: ScratchDefaults("FileActionHandler"), pasteboard: scratchPasteboard())

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: root, name: "root", isDirectory: true)

        handler.focusFolder(node, isLeft: false, leftProviderId: "iCloud", rightProviderId: "iCloud", suppressLinkedNavigation: false)
        #expect(manager.rightRelativePath == "")
    }

    @MainActor
    @Test func testProviderDisplayNameMatchesRootAndRespectsBoundary() {
        let settings = scratchSettings()
        let handler = FileActionHandler(syncManager: FileSyncManager(), settings: settings,
                                        defaults: ScratchDefaults("FileActionHandler"), pasteboard: scratchPasteboard())
        let root = settings.rootPath(for: "iCloud")

        // Exact root and a real subpath resolve to the provider.
        #expect(handler.providerDisplayName(forPath: root) == "iCloud")
        #expect(handler.providerDisplayName(forPath: "\(root)/sub/file.txt") == "iCloud")
        // A sibling that only shares the root as a string prefix must not match (the "/" boundary).
        #expect(handler.providerDisplayName(forPath: "\(root)Extra") == "the other pane")
    }

    @MainActor
    @Test func testEscapeForAppleScriptEscapesBackslashThenQuote() {
        // Backslash must be escaped before the quote, else the quote's backslash gets doubled.
        #expect(FileActionHandler.escapeForAppleScript(#"a"b\c"#) == #"a\"b\\c"#)
        #expect(FileActionHandler.escapeForAppleScript("plain") == "plain")
    }
}
