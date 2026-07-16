import Foundation
import Testing
@testable import FileExplorer

/// Pins the Browse… destination helper: a picked folder becomes a path relative to the preview
/// root, the same root the folder was previewed against — inside → relative subpath, the root
/// itself → empty, anything outside → nil (which the editor turns into a "pick inside" alert).
@Suite struct AutomationRuleEditorTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func insideBaseGivesRelativeSubpath() {
        #expect(AutomationRuleEditor.relativePath(of: url("/base/Documents/Invoices"),
                                                  under: url("/base")) == "Documents/Invoices")
        #expect(AutomationRuleEditor.relativePath(of: url("/base/Docs"), under: url("/base")) == "Docs")
    }

    @Test func sameFolderGivesEmptyString() {
        #expect(AutomationRuleEditor.relativePath(of: url("/base"), under: url("/base")) == "")
        #expect(AutomationRuleEditor.relativePath(of: url("/base/"), under: url("/base")) == "")
    }

    @Test func outsideBaseIsNil() {
        #expect(AutomationRuleEditor.relativePath(of: url("/other/x"), under: url("/base")) == nil)
        // A shared string prefix that isn't a path-component boundary must not count as "inside".
        #expect(AutomationRuleEditor.relativePath(of: url("/basement/x"), under: url("/base")) == nil)
        // A parent of the base is not inside it.
        #expect(AutomationRuleEditor.relativePath(of: url("/"), under: url("/base")) == nil)
    }

    // MARK: Save-time canonicalization of "Mentions the words"

    @Test func mentionsCanonicalizesOnlyAtSave() {
        // Free-typed text (held as one raw element while editing) becomes the engine's canonical
        // tokens: split on every non-alphanumeric, lowercased, sorted — so "Tesla-Model-3, Insurance"
        // saves in exactly the form a filename can match.
        #expect(AutomationRuleEditor.canonicalized(.mentionsAll(["Tesla-Model-3, Insurance"]))
                == .mentionsAll(["insurance", "model", "tesla"]))
        // Non-mentions conditions pass through untouched.
        #expect(AutomationRuleEditor.canonicalized(.contentContains("Final Draft")) == .contentContains("Final Draft"))
    }

    @Test func unmatchableMentionsRowsAreDetected() {
        // Visible text that canonicalizes to NOTHING (stopwords, bare numbers, 1-char fragments)
        // must block Save — silently dropping the condition would broaden an all-of rule.
        #expect(AutomationRuleEditor.isUnmatchableMentions(.mentionsAll(["the, draft, 3"])))
        #expect(AutomationRuleEditor.isUnmatchableMentions(.mentionsAll(["1099"])))   // bare number, not a year
        // Words that survive canonicalization are fine.
        #expect(!AutomationRuleEditor.isUnmatchableMentions(.mentionsAll(["tesla"])))
        // A blank row is plain "incomplete", not a trap — it never looked filled.
        #expect(!AutomationRuleEditor.isUnmatchableMentions(.mentionsAll([""])))
        #expect(!AutomationRuleEditor.isUnmatchableMentions(.mentionsAll([])))
        // Other condition types are never flagged.
        #expect(!AutomationRuleEditor.isUnmatchableMentions(.kindIs(.pdf)))
    }
}
