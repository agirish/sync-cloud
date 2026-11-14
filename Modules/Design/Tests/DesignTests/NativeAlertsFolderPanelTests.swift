import AppKit
import Testing
@testable import Design

/// `NativeAlerts.folderPanel`, the one-folder chooser behind `chooseFolder`. Asked of the built
/// panel, never of `chooseFolder`, whose `runModal()` would park the test on a modal session.
@Suite @MainActor struct NativeAlertsFolderPanelTests {

    /// One folder, never a file or several, whatever the caller passes.
    @Test func itChoosesOneFolderOnly() {
        for panel in [NativeAlerts.folderPanel(),
                      NativeAlerts.folderPanel(prompt: "Choose", message: "Where", canCreateDirectories: true)] {
            #expect(!panel.canChooseFiles, "the folder panel lets a file be chosen")
            #expect(panel.canChooseDirectories, "the folder panel can't choose a folder")
            #expect(!panel.allowsMultipleSelection, "the folder panel lets several be chosen")
        }
    }

    /// Each argument lands in its own field.
    @Test func everyArgumentPassedIsSet() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let panel = NativeAlerts.folderPanel(prompt: "File Here", message: "Choose a folder for “a.pdf”",
                                             startingAt: home, canCreateDirectories: true)
        #expect(panel.prompt == "File Here")
        #expect(panel.message == "Choose a folder for “a.pdf”")
        #expect(panel.directoryURL?.standardizedFileURL.path == home.standardizedFileURL.path)
        #expect(panel.canCreateDirectories)
        #expect(!NativeAlerts.folderPanel(canCreateDirectories: false).canCreateDirectories)
    }

    /// An argument left out leaves the panel's own default, as the sites that never set it had.
    @Test func anArgumentLeftOutKeepsThePanelsDefault() {
        let built = NativeAlerts.folderPanel()
        let plain = NSOpenPanel()
        #expect(built.prompt == plain.prompt, "an omitted prompt replaced the panel's own")
        #expect(built.message == plain.message, "an omitted message replaced the panel's own")
        #expect(built.directoryURL == plain.directoryURL, "an omitted start moved the panel")
        #expect(built.canCreateDirectories == plain.canCreateDirectories,
                "an omitted canCreateDirectories replaced the panel's own")
    }
}
