import Testing
import Foundation
import AppKit
@testable import FileExplorer
import FileExplorerTestSupport

/// An import that wrote nothing takes back the Images folder it made: the one case where the folder
/// was already made, and only `importImages`' closing `rmdir` puts it back. The write fails on a `/`
/// in the pasted image's extension, standing in for any failure once the folder exists (a full
/// disk, a permission revoked mid-import).
@Suite(.serialized) struct EditorImageImportRollbackTests {

    private let fm = FileManager.default

    private func listing(_ path: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    @Test func aWriteThatFailsAfterTheFolderWasMadeLeavesNoFolder() throws {
        let note = try TestTextFiles.write("# Pasta\n", named: "Pasta.md")
        let folder = (note as NSString).deletingLastPathComponent
        let images = (folder as NSString).appendingPathComponent(EditorImageImport.folderName)
        let before = listing(folder)
        try #require(!fm.fileExists(atPath: images), "the Images folder was there already — nothing to make")

        let report = EditorImageImport.importImages([.data(EditorTestRigs.png(), extension: "png/unwritable")], forNote: note)

        guard case .refused(let reason) = report else {
            Issue.record("not refused: \(report)")
            return
        }
        #expect(reason.contains("couldn’t be saved"), "the refusal does not say the save failed: \(reason)")
        #expect(!fm.fileExists(atPath: images), "the Images folder made for the import was left behind")
        #expect(listing(folder) == before)
    }

    /// The control: the same import with a name it can write lands, in the folder it made, so the
    /// test above is about the failed write and not a folder that was never made.
    @Test func theSameImportWithAWritableNameMakesTheFolder() throws {
        let note = try TestTextFiles.write("# Pasta\n", named: "Pasta.md")
        let images = ((note as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(EditorImageImport.folderName)
        let report = EditorImageImport.importImages([.data(EditorTestRigs.png(), extension: "png")], forNote: note)
        #expect(report == .wrote(files: [images + "/Pasta-1.png"], madeFolder: images, linked: ["Images/Pasta-1.png"]))
    }
}
