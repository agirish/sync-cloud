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
        let settings = SettingsManager(autoDiscover: false) // seeded iCloud provider only
        let handler = FileActionHandler(syncManager: manager, settings: settings)

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud", suppressLinkedNavigation: false)
        #expect(manager.leftRelativePath == "Projects/Sync")
    }

    @MainActor
    @Test func testFocusFolderMovesOnlyTargetPaneWhenUnlinked() {
        // Default (unlinked): drilling into the left pane must not disturb the right pane.
        UserDefaults.standard.removeObject(forKey: PaneLinkPreference.defaultsKey)
        let manager = FileSyncManager()
        let settings = SettingsManager(autoDiscover: false)
        let handler = FileActionHandler(syncManager: manager, settings: settings)

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud", suppressLinkedNavigation: false)
        #expect(manager.leftRelativePath == "Projects/Sync")
        #expect(manager.rightRelativePath == "")
    }

    @MainActor
    @Test func testFocusFolderNeverDrivesTheSiblingFromTheSingleSourceRail() {
        // The single-source rail reuses the left pane's plumbing but has NO visible sibling: with 🔗
        // linked, drilling the rail must not drag the hidden right pane along (its history
        // grows, its saved focus is overwritten for the next launch, and FolderJumpStore
        // records "Recent" folders the user never visited). The rail's delegate passes
        // suppressLinkedNavigation.
        UserDefaults.standard.set(true, forKey: PaneLinkPreference.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: PaneLinkPreference.defaultsKey) }
        let manager = FileSyncManager()
        let settings = SettingsManager(autoDiscover: false)
        let handler = FileActionHandler(syncManager: manager, settings: settings)

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud",
                            suppressLinkedNavigation: true)
        #expect(manager.leftRelativePath == "Projects/Sync")
        #expect(manager.rightRelativePath == "")   // the hidden pane stayed put
    }

    @MainActor
    @Test func testFocusFolderMovesBothPanesWhenLinked() {
        // With "Link both panes" on, drilling into a folder from the file list must move the
        // sibling pane to the same relative path — the bug where only breadcrumb clicks honored it.
        UserDefaults.standard.set(true, forKey: PaneLinkPreference.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: PaneLinkPreference.defaultsKey) }
        let manager = FileSyncManager()
        let settings = SettingsManager(autoDiscover: false)
        let handler = FileActionHandler(syncManager: manager, settings: settings)

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: "\(root)/Projects/Sync", name: "Sync", isDirectory: true)

        handler.focusFolder(node, isLeft: true, leftProviderId: "iCloud", rightProviderId: "iCloud", suppressLinkedNavigation: false)
        #expect(manager.leftRelativePath == "Projects/Sync")
        #expect(manager.rightRelativePath == "Projects/Sync")
    }

    @MainActor
    @Test func testFocusFolderOnRootYieldsEmptyRelativePath() {
        let manager = FileSyncManager()
        let settings = SettingsManager(autoDiscover: false)
        let handler = FileActionHandler(syncManager: manager, settings: settings)

        let root = settings.rootPath(for: "iCloud")
        let node = FileNode(id: root, name: "root", isDirectory: true)

        handler.focusFolder(node, isLeft: false, leftProviderId: "iCloud", rightProviderId: "iCloud", suppressLinkedNavigation: false)
        #expect(manager.rightRelativePath == "")
    }

    @MainActor
    @Test func testProviderDisplayNameMatchesRootAndRespectsBoundary() {
        let settings = SettingsManager(autoDiscover: false)
        let handler = FileActionHandler(syncManager: FileSyncManager(), settings: settings)
        let root = settings.rootPath(for: "iCloud")

        // Exact root and a real subpath resolve to the provider.
        #expect(handler.providerDisplayName(forPath: root) == "iCloud")
        #expect(handler.providerDisplayName(forPath: "\(root)/sub/file.txt") == "iCloud")
        // A sibling that merely shares the root as a string prefix must NOT match (the "/" boundary guard).
        #expect(handler.providerDisplayName(forPath: "\(root)Extra") == "other pane")
    }

    @MainActor
    @Test func testEscapeForAppleScriptEscapesBackslashThenQuote() {
        // Backslash must be escaped before the quote, else the quote's backslash gets doubled.
        #expect(FileActionHandler.escapeForAppleScript(#"a"b\c"#) == #"a\"b\\c"#)
        #expect(FileActionHandler.escapeForAppleScript("plain") == "plain")
    }
}
