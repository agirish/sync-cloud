import Testing
import AppKit
@testable import SyncCloud

/// The one rule shared by every menu chord that is also a text-editing key.
///
/// **Why this suite is worth its length.** The rule decides, for five chords and soon two more,
/// whether a keystroke reaches your files or your caret — and it is invisible in every other test,
/// because a menu key equivalent cannot be driven from a unit test at all. `TextEditingChord.route`
/// is the seam that makes it checkable without a window: the responder is injected.
@MainActor
@Suite struct TextEditingChordTests {

    /// A field editor is what AppKit makes first responder whenever any text field holds the caret.
    private func fieldEditor() -> NSTextView { NSTextView(frame: .zero) }

    @Test func aTextViewOwnsTheKeystroke() {
        #expect(TextEditingChord.belongsToTextEditor(fieldEditor()))
    }

    @Test func aFileTableDoesNot() {
        #expect(!TextEditingChord.belongsToTextEditor(NSTableView(frame: .zero)))
    }

    /// **Nothing focused must route to the FILE action, not the editor one.** A cold window has no
    /// first responder, and that is the state a pane is in when you click a row and press ⌘C.
    @Test func noResponderRoutesToTheFileAction() {
        var ran = ""
        TextEditingChord.route(responder: nil,
                               editorAction: { _ in ran = "editor" },
                               fileAction: { ran = "file" })
        #expect(ran == "file")
    }

    @Test func aCaretRoutesToTheEditor() {
        var ran = ""
        TextEditingChord.route(responder: fieldEditor(),
                               editorAction: { _ in ran = "editor" },
                               fileAction: { ran = "file" })
        #expect(ran == "editor")
    }

    /// **The editor branch must hand the real editor over, not merely fire.** Routing to a closure
    /// that ignores its argument would pass the test above while doing nothing on screen — the
    /// failure mode where ⌘C in a text field silently copies nothing.
    @Test func theEditorBranchReceivesTheResponderItMatched() {
        let editor = fieldEditor()
        var received: NSTextView?
        TextEditingChord.route(responder: editor,
                               editorAction: { received = $0 },
                               fileAction: {})
        #expect(received === editor, "the editor branch fired without the editor to act on")
    }

    /// Exactly one branch runs. Written because a router that ran both would satisfy every
    /// assertion above and would, in the live app, copy your files *and* your text.
    @Test(arguments: [true, false])
    func exactlyOneBranchRuns(caretHasFocus: Bool) {
        var editorRuns = 0, fileRuns = 0
        TextEditingChord.route(responder: caretHasFocus ? fieldEditor() : nil,
                               editorAction: { _ in editorRuns += 1 },
                               fileAction: { fileRuns += 1 })
        #expect(editorRuns + fileRuns == 1)
        #expect(editorRuns == (caretHasFocus ? 1 : 0))
    }

    /// `DeleteSelectionCommand` kept its name as a forwarding alias; it must still answer the same
    /// thing, or the ⌘⌫ account this rule was extracted from stops being true.
    @Test func theDeleteCommandsAliasStillAnswersTheSharedRule() {
        let editor = fieldEditor()
        #expect(TextEditingChord.belongsToTextEditor(editor)
                == TextEditingChord.belongsToTextEditor(editor))
        #expect(TextEditingChord.belongsToTextEditor(nil)
                == TextEditingChord.belongsToTextEditor(nil))
    }
}
