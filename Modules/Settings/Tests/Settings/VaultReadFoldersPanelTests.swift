import AppKit
import Testing
@testable import Settings

/// The panel behind the Vault's Add Folder… and Settings' Add… beside Folders to Read. Asked of the
/// built panel, never of `add`, whose `runModal()` would park the test on a modal session.
@Suite @MainActor struct VaultReadFoldersPanelTests {

    /// Folders only, several at once, under "Read for IDs"; the Vault's message over it, Settings'
    /// none.
    @Test func itChoosesFoldersToReadWithTheCallersMessage() {
        let vault = VaultReadFoldersPanel.panel(message: "Choose the folders that hold your passport scans.")
        let settings = VaultReadFoldersPanel.panel(message: nil)
        for panel in [vault, settings] {
            #expect(panel.canChooseDirectories)
            #expect(!panel.canChooseFiles)
            #expect(panel.allowsMultipleSelection)
            #expect(panel.prompt == "Read for IDs")
        }
        #expect(vault.message == "Choose the folders that hold your passport scans.")
        #expect(settings.message == NSOpenPanel().message, "no message of its own")
    }
}
