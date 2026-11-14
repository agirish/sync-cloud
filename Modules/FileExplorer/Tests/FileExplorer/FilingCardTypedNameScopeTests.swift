import Testing
import Foundation
@testable import FileExplorer

/// A name typed into "Create as" belongs to the destination it was typed for.
/// `FilingSuggestionCard.editedFolderName` is `@State` and the card's identity is the suggestion, so
/// "Try another" replaces `best` under the same card; without a reset the old name would apply to
/// the new destination.
///
/// A source scan: `@State` cannot be driven without mounting the card in a host that serves a second
/// destination. It checks the reset exists, is keyed on the destination, and that the button still
/// reads the field: a reset that fired on every render would make the field useless.
@Suite struct FilingCardTypedNameScopeTests {

    private static func cardSource() throws -> String { try SourceText.fileExplorer("FilingSuggestionCard.swift") }

    @Test func theTypedNameIsClearedWhenTheProposedFolderChanges() throws {
        let source = try Self.cardSource()

        // Non-vacuity: the field and the state it edits are still here.
        #expect(source.contains("@State private var editedFolderName"),
                "the state was renamed — this scan is measuring nothing")
        #expect(source.contains("TextField(leaf, text: $editedFolderName)"),
                "the Create-as field no longer edits that state")

        #expect(source.contains(".onChange(of: best?.newSegments.last) { _, _ in editedFolderName = \"\" }"),
                "nothing clears the typed name when the destination changes, so it carries to the next one")

        // The button must still use the field, or the reset would be protecting nothing.
        #expect(source.contains("onFileHere(best.renamingNewFolder(to: editedFolderName))"),
                "File here stopped applying the typed name — the field is decorative")

        // Keyed on the destination: an unkeyed `onChange`, or one on something that moves every
        // render, would clear the field as the user typed.
        let resets = source.components(separatedBy: "editedFolderName = \"\"").count - 1
        #expect(resets == 1, "expected exactly one place to clear the typed name, found \(resets)")
        #expect(!source.contains(".onAppear { editedFolderName = \"\" }"),
                "clearing on appear would wipe the field on every scroll through a lazy list")
    }
}
