import Testing
import Foundation
@testable import FileExplorer

/// **A name typed into "Create as" belongs to the destination it was typed for.**
///
/// `FilingSuggestionCard.editedFolderName` is `@State`, and the card's identity is the SUGGESTION —
/// so "Try another" replaces `best` underneath the same card and the field keeps its contents. A
/// name meant for `Finance › HDFC › <new>` was then applied to whatever came back next, creating
/// `Health › Kaiser › 2026 Statements`. The only clue was the field showing the old name against
/// the new folder's placeholder.
///
/// A scan, and honest about its reach: `@State` cannot be driven from here without mounting the
/// card inside a host that can serve it a second destination, and the mounted-view harnesses in
/// this target drive tables rather than lens cards. What is checkable is that the reset exists, is
/// keyed on the destination, and that the button still reads the field — a reset that fired on
/// every render would "fix" this by making the field useless, and that would pass a one-sided test.
@Suite struct FilingCardTypedNameScopeTests {

    private static func cardSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/Tests/FileExplorer
            .deletingLastPathComponent()      // …/Tests
            .deletingLastPathComponent()      // …/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/FilingSuggestionCard.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func theTypedNameIsClearedWhenTheProposedFolderChanges() throws {
        let source = try Self.cardSource()

        // Non-vacuity: the field and the state it edits are still here.
        #expect(source.contains("@State private var editedFolderName"),
                "the state was renamed — this scan is measuring nothing")
        #expect(source.contains("TextField(leaf, text: $editedFolderName)"),
                "the Create-as field no longer edits that state")

        #expect(source.contains(".onChange(of: best?.newSegments.last) { _, _ in editedFolderName = \"\" }"),
                "nothing clears the typed name when the destination changes, so it carries to the next one")
    }

    /// The button must still USE the field, or the reset above would be protecting nothing.
    @Test func fileHereStillAppliesTheTypedName() throws {
        let source = try Self.cardSource()
        #expect(source.contains("onFileHere(best.renamingNewFolder(to: editedFolderName))"),
                "File here stopped applying the typed name — the field is decorative")
    }

    /// And the reset is keyed on the destination, not fired unconditionally: an `onChange` with no
    /// key, or one on something that moves every render, would clear the field as the user typed.
    @Test func theResetIsKeyedOnTheDestinationRatherThanFiringAlways() throws {
        let source = try Self.cardSource()
        let resets = source.components(separatedBy: "editedFolderName = \"\"").count - 1
        #expect(resets == 1, "expected exactly one place to clear the typed name, found \(resets)")
        #expect(!source.contains(".onAppear { editedFolderName = \"\" }"),
                "clearing on appear would wipe the field on every scroll through a lazy list")
    }
}
