import Testing
import Foundation
import Sync
@testable import FileExplorer

/// A name typed into "Create as" belongs to the destination it was typed for. The list holds it
/// (so File All files under it), keyed on the file and its home, and the card clears it when "Try
/// another" replaces `best` under the same card; otherwise the old name would apply to the new
/// destination.
///
/// A source scan: `@State` cannot be driven without mounting the card in a host that serves a second
/// destination. It checks the reset exists, is keyed on the destination, and that the button still
/// reads the field: a reset that fired on every render would make the field useless.
@Suite struct FilingCardTypedNameScopeTests {

    private static func cardSource() throws -> String { try SourceText.fileExplorer("FilingSuggestionCard.swift") }

    @Test func theTypedNameIsClearedWhenTheProposedFolderChanges() throws {
        let source = try Self.cardSource()

        // Non-vacuity: the field and the state it edits are still here.
        #expect(source.contains("private var editedFolderName: String { folderName.wrappedValue }"),
                "the state was renamed — this scan is measuring nothing")
        #expect(source.contains("TextField(leaf, text: folderName)"),
                "the Create-as field no longer edits that state")

        #expect(source.contains(".onChange(of: best?.newSegments.last) { _, _ in folderName.wrappedValue = \"\" }"),
                "nothing clears the typed name when the destination changes, so it carries to the next one")

        // The button must still use the field, or the reset would be protecting nothing.
        #expect(source.contains("onFileHere(best.renamingNewFolder(to: editedFolderName))"),
                "File here stopped applying the typed name — the field is decorative")

        // Keyed on the destination: an unkeyed `onChange`, or one on something that moves every
        // render, would clear the field as the user typed.
        let resets = source.components(separatedBy: "folderName.wrappedValue = \"\"").count - 1
        #expect(resets == 1, "expected exactly one place to clear the typed name, found \(resets)")
        #expect(!source.contains(".onAppear { folderName.wrappedValue = \"\" }"),
                "clearing on appear would wipe the field on every scroll through a lazy list")
    }
}

@Suite struct FilingTypedNameKeyTests {
    /// The list's key changes with the home, so a name typed for one home never reaches the next,
    /// even for a card not on screen to clear it.
    @MainActor @Test func aNewHomeGetsAFreshKey() {
        func s(_ path: String) -> FilingSuggestion {
            FilingSuggestion(filePath: "/D/TODO/r.pdf", fileName: "r.pdf", size: 1, modificationDate: nil,
                             candidates: [FilingDestination(path: path, confidence: .high, reasons: [], newSegments: ["X"])])
        }
        #expect(LensWorkspaceView.typedNameKey(s("/D/A/X")) != LensWorkspaceView.typedNameKey(s("/D/B/X")))
        #expect(LensWorkspaceView.typedNameKey(s("/D/A/X")) == LensWorkspaceView.typedNameKey(s("/D/A/X")))
    }
}
