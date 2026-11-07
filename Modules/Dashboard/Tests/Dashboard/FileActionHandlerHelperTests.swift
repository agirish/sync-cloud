import Testing
import Foundation
import Sync
import Settings
@testable import Dashboard

/// Coverage for FileActionHandler's pure string logic: relative-path derivation in focusFolder,
/// provider root matching (incl. the "/" prefix boundary), and AppleScript escaping.
@Suite struct FileActionHandlerHelperTests {

    @MainActor
    @Test func testFocusFolderDerivesRelativePathFromProviderRoot() {
        let manager = FileSyncManager()
        let settings = scratchSettings() // seeded iCloud provider only
        let handler = FileActionHandler(syncManager: manager, settings: settings,
                                        defaults: ScratchDefaults("FileActionHandler"), pasteboard: scratchPasteboard())

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud", suppressLinkedNavigation: false)
        #expect(manager.leftRelativePath == "Projects/Sync")
    }

    @MainActor
    @Test func testFocusFolderMovesOnlyTargetPaneWhenUnlinked() {
        // Default (unlinked): drilling into the left pane must not disturb the right pane.
        // A fresh scratch suite has no value for the key, which is the unlinked default.
        let defaults = ScratchDefaults("FileActionHandlerHelperTests")
        let manager = FileSyncManager()
        let settings = scratchSettings()
        let handler = FileActionHandler(syncManager: manager, settings: settings, defaults: defaults,
                                        pasteboard: scratchPasteboard())

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud", suppressLinkedNavigation: false)
        #expect(manager.leftRelativePath == "Projects/Sync")
        #expect(manager.rightRelativePath == "")
    }

    @MainActor
    @Test func testFocusFolderNeverDrivesTheSiblingFromTheSingleSourceRail() {
        // The single-source rail reuses the left pane's plumbing but has no visible sibling: with
        // 🔗 linked, drilling the rail must not drag the hidden right pane along, growing its
        // history, overwriting its saved focus and recording Recents the user never visited. The
        // rail's delegate passes suppressLinkedNavigation.
        let defaults = ScratchDefaults("FileActionHandlerHelperTests")
        defaults.set(true, forKey: PaneLinkPreference.defaultsKey)
        let manager = FileSyncManager()
        let settings = scratchSettings()
        let handler = FileActionHandler(syncManager: manager, settings: settings, defaults: defaults,
                                        pasteboard: scratchPasteboard())

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud",
                            suppressLinkedNavigation: true)
        #expect(manager.leftRelativePath == "Projects/Sync")
        #expect(manager.rightRelativePath == "")   // the hidden pane stayed put
    }

    @MainActor
    @Test func testFocusFolderMovesBothPanesWhenLinked() {
        // With "Link both panes" on, drilling into a folder from the file list moves the sibling
        // pane to the same relative path, not only breadcrumb clicks.
        let defaults = ScratchDefaults("FileActionHandlerHelperTests")
        defaults.set(true, forKey: PaneLinkPreference.defaultsKey)
        let manager = FileSyncManager()
        let settings = scratchSettings()
        let handler = FileActionHandler(syncManager: manager, settings: settings, defaults: defaults,
                                        pasteboard: scratchPasteboard())

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud", suppressLinkedNavigation: false)
        #expect(manager.leftRelativePath == "Projects/Sync")
        #expect(manager.rightRelativePath == "Projects/Sync")
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

    /// Settings on a scratch suite, so the seed is iCloud and nothing else. The standard domain
    /// under `swift test` is a plist every test process shares, holding whatever
    /// `lastKnownAccountFolders` and root overrides other runs left there.
    @MainActor
    private func scratchSettings() -> SettingsManager {
        SettingsManager(autoDiscover: false, userDefaults: ScratchDefaults("FileActionHandlerHelperTests"))
    }
}
