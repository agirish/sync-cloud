import Foundation
import Testing
@testable import Sync

/// Folders to Read through the model are its own settings', never the app's (VT74): the panel goes
/// through the model, so a panel drawn in a test lists, adds and lets go of folders in that test's
/// scratch settings alone. (`VaultReadFolders` has no default settings, so the panel cannot reach
/// the app's by leaving them out.)
@Suite @MainActor struct VaultModelReadFoldersTests {

    @Test func theFoldersToReadAreTheModelsOwnSettings() throws {
        let rig = try VaultRig(); defer { rig.cleanUp() }
        let model = rig.model()
        #expect(model.readFolders.isEmpty)

        model.addReadFolders(["/Scans/Passports", "/Scans/Passports/2024", "/Scans/Notices"])
        #expect(model.readFolders == ["/Scans/Passports", "/Scans/Notices"], "a folder inside one listed is not added")
        #expect(VaultReadFolders.folders(in: rig.defaults) == model.readFolders)

        model.removeReadFolder("/Scans/Passports")
        #expect(model.readFolders == ["/Scans/Notices"])
        #expect(VaultReadFolders.folders(in: rig.defaults) == ["/Scans/Notices"])
    }
}
