import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer
import FileExplorerTestSupport

/// **⌘Z after switching Source, Split and Preview reverts what is on screen** (TE67.0, F7).
///
/// The defect: `surfaces(for:)` mounts the Source text view from a different `switch` arm in each
/// mode and none in Preview, so every switch builds a new `NSTextView`. The undo manager is shared
/// across that rebuild, but an `NSTextView` registers each undo action against the text storage it
/// was made in. So the ⌘Z after a switch reverted the discarded view's storage: nothing on screen
/// moved, the buffer kept the typing, and the step was used up.
///
/// **The real workspace, mounted** — `EditorWorkspaceView.fixture` in a window, with the root
/// swapped to change mode, the way `aCaretOnAListItemLightsBulletedListInTheMountedBar` does. One
/// wrapper for every mode, so the swap is a mode change and not a new workspace.
@MainActor
@Suite(.serialized) struct EditorUndoAcrossModesTests {

    @MainActor
    final class Rig {
        let document: EditorDocument
        /// The app's per-document stacks and storages, moved the way `EditorDocumentLoad` moves
        /// them — `nil` for a rig that holds one stack of its own.
        let store: EditorUndoStore?
        private let ownUndo = UndoManager()
        private(set) var mode: EditorMode
        let probe: ProbeRig<AnyView>

        /// The stack the text view is handed: the store's current one, or the rig's own.
        var undo: UndoManager { store?.current ?? ownUndo }

        init(_ text: String, mode: EditorMode, store: EditorUndoStore? = nil) throws {
            document = try TestTextFiles.document(named: "Undo.md", text: text)
            self.store = store
            self.mode = mode
            if let store {
                store.activate(path: document.path, text: document.text)
                document.buffer.follow(store.source)
            }
            probe = ProbeRig(Self.root(document, store?.current ?? ownUndo, mode),
                             size: CGSize(width: 900, height: 400))
        }

        /// Opens `path` the way the app does: settle the outgoing buffer by writing it (autosave's
        /// flush), then `EditorDocumentLoad.run`'s order — remember, load, activate, follow — and
        /// re-render. (The app's own copy of that order is pinned in the app target.)
        func open(_ path: String) async throws {
            let store = try #require(store, "a file switch needs the store")
            document.markSaved(stamp: try EditorFileStore.write(document))
            store.remember(text: document.text)
            EditorFileStore.load(path: path, into: document)
            store.activate(path: document.path, text: document.text)
            document.buffer.follow(store.source)
            probe.host.rootView = Self.root(document, undo, mode)
            _ = await LayoutPumpWait.pump(probe.window, upTo: 5) {
                mode == .preview || textView?.textStorage === document.buffer.source.textStorage
            }
        }

        static func root(_ document: EditorDocument, _ undo: UndoManager, _ mode: EditorMode) -> AnyView {
            AnyView(EditorWorkspaceView.fixture(document: document, mode: mode, undoManager: undo)
                .frame(width: 900, height: 400, alignment: .topLeading))
        }

        /// The Source text view on screen, or nil in Preview.
        var textView: NSTextView? {
            var found: NSTextView?
            func walk(_ v: NSView) {
                if found == nil, let text = v as? NSTextView,
                   text.enclosingScrollView?.identifier == EditorDocumentSurface.identifier { found = text }
                v.subviews.forEach(walk)
            }
            walk(probe.host)
            return found
        }

        /// Switches mode and waits for the workspace to settle on it — a NEW text view in Source and
        /// Split (the rebuild is the whole point), none in Preview.
        func switchTo(_ mode: EditorMode) async throws {
            let before = textView
            self.mode = mode
            probe.host.rootView = Self.root(document, undo, mode)
            let settled = await LayoutPumpWait.pump(probe.window, upTo: 5) {
                let now = textView
                return mode == .preview ? now == nil : (now != nil && now !== before)
            }
            try #require(settled.held, "the workspace never settled on \(mode)")
        }

        /// Types `text` at `location` the way a keystroke does, then lets the event end.
        func type(_ text: String, at location: Int) async throws {
            let view = try #require(textView, "no text view to type into")
            probe.window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.insertText(text, replacementRange: NSRange(location: location, length: 0))
            await endOfEvent()
        }

        /// Waits for the run loop to close the event's undo group, which is what makes two edits two
        /// steps. **Never closed by hand**: the main run loop does turn under this harness, and its
        /// observer then finds no group to close and throws `endUndoGrouping called with no
        /// matching begin` — measured, it takes the test process down.
        func endOfEvent() async {
            _ = await LayoutPumpWait.pump(probe.window, upTo: 2) { undo.groupingLevel == 0 }
        }

        /// ⌘Z, then a settle: anything the undo set moving through SwiftUI gets its passes.
        func undoAndSettle(expecting expected: String) async {
            undo.undo()
            _ = await LayoutPumpWait.pump(probe.window, upTo: 2) {
                textView?.string == expected && document.text == expected
            }
            print("[undo-modes] screen \((textView?.string ?? "-").debugDescription) · document "
                  + "\(document.text.debugDescription) · canUndo \(undo.canUndo) · canRedo \(undo.canRedo)")
        }
    }

    /// C19 in its Source → Split form: type in Source, switch to Split, ⌘Z.
    @Test func undoAfterSwitchingSourceToSplitRevertsTheVisibleText() async throws {
        let rig = try Rig("Hello world\n", mode: .edit)
        defer { withExtendedLifetime(rig) {} }
        try await rig.type(" there", at: 5)
        #expect(rig.document.text == "Hello there world\n", "typing did not reach the document")

        try await rig.switchTo(.split)
        #expect(rig.textView?.string == "Hello there world\n", "Split did not show the typing")
        await rig.undoAndSettle(expecting: "Hello world\n")

        #expect(rig.textView?.string == "Hello world\n",
                "⌘Z after Source → Split left the typing on screen — it reverted a discarded view")
        #expect(rig.document.text == "Hello world\n",
                "⌘Z after Source → Split left the typing in the document")
    }

    /// C20's round trip: type in Source, look at Preview, come back, ⌘Z.
    @Test func undoAfterAPreviewRoundTripRevertsTheVisibleText() async throws {
        let rig = try Rig("Hello world\n", mode: .edit)
        defer { withExtendedLifetime(rig) {} }
        try await rig.type(" there", at: 5)

        try await rig.switchTo(.preview)
        try await rig.switchTo(.edit)
        #expect(rig.textView?.string == "Hello there world\n", "Source came back without the typing")
        await rig.undoAndSettle(expecting: "Hello world\n")

        #expect(rig.textView?.string == "Hello world\n",
                "⌘Z after Source → Preview → Source left the typing on screen")
        #expect(rig.document.text == "Hello world\n",
                "⌘Z after Source → Preview → Source left the typing in the document")
    }

    /// **⌘Z with no switch at all reaches the document too.** On TextKit 2 an `NSTextView` undo
    /// edits its storage without sending `textDidChange` (measured 2026-10-04 by the markup-verb
    /// session, and again here), and the buffer used to follow `textDidChange` alone — so after ⌘Z
    /// the screen showed the old text while the document, autosave and the dirty dot kept the new.
    @Test func undoWithoutASwitchReachesTheDocument() async throws {
        let rig = try Rig("Hello world\n", mode: .edit)
        defer { withExtendedLifetime(rig) {} }
        try await rig.type(" there", at: 5)
        await rig.undoAndSettle(expecting: "Hello world\n")

        #expect(rig.textView?.string == "Hello world\n", "⌘Z did not revert the text on screen")
        #expect(rig.document.text == "Hello world\n",
                "⌘Z reverted the screen and left the typing in the document — autosave would write it")
    }

    /// **Type, ⌘Z, close: the file holds the undone text.** The close settles the buffer through
    /// autosave's flush, which writes `document.text` — so a buffer left holding the undone typing
    /// wrote it to disk under a screen that no longer showed it.
    @Test func typeUndoThenTheClosingFlushWritesTheUndoneText() async throws {
        let rig = try Rig("Hello world\n", mode: .edit)
        defer { withExtendedLifetime(rig) {} }
        let path = try #require(rig.document.path)
        try await rig.type("foo", at: 0)
        await rig.undoAndSettle(expecting: "Hello world\n")
        _ = EditorAutosave.attempt(rig.document)   // what `settleEditorDocument` runs before a close
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "Hello world\n",
                "the flush wrote typing that ⌘Z had taken off the screen")
    }

    // MARK: Ticking a task (C25)

    /// **A tick is one step ⌘Z takes back, and ⇧⌘Z puts back** — it was a whole-buffer write the
    /// stack never heard of. The buffer follows each step.
    @Test func aTickCanBeUndoneAndRedone() async throws {
        let buffer = EditorBuffer()
        buffer.text = "- [ ] milk\n- [ ] eggs\n"
        let source = EditorSourceStorage(text: buffer.text)
        buffer.follow(source)
        let undo = UndoManager()

        #expect(EditorWorkspaceView.toggleTask(onLine: 2, in: source, undoManager: undo))
        #expect(buffer.text == "- [ ] milk\n- [x] eggs\n")
        #expect(undo.undoActionName == EditorWorkspaceView.taskActionName)
        _ = await LayoutPumpWait.pump(NSView(), upTo: 2) { undo.groupingLevel == 0 }
        undo.undo()
        #expect(buffer.text == "- [ ] milk\n- [ ] eggs\n", "⌘Z did not untick")
        undo.redo()
        #expect(buffer.text == "- [ ] milk\n- [x] eggs\n", "⇧⌘Z did not tick again")
    }

    /// A stale click — the line no longer holds a checkbox — changes nothing and adds no step.
    @Test func aStaleTickChangesNothingAndAddsNoStep() {
        let source = EditorSourceStorage(text: "just words\n")
        let undo = UndoManager()
        #expect(!EditorWorkspaceView.toggleTask(onLine: 1, in: source, undoManager: undo))
        #expect(source.text == "just words\n")
        #expect(!undo.canUndo)
    }

    /// **Typing, then a tick, are two steps in that order** — the tick never joins the typing run
    /// before it. In Split, the mode a checkbox and a caret share.
    @Test func typingThenATickUndoAsTwoStepsInSplit() async throws {
        let rig = try Rig("- [ ] milk\nnotes\n", mode: .split)
        defer { withExtendedLifetime(rig) {} }
        try await rig.type("!", at: 16)
        #expect(EditorWorkspaceView.toggleTask(onLine: 1, in: rig.document.buffer.source, undoManager: rig.undo))
        await rig.endOfEvent()
        #expect(rig.textView?.string == "- [x] milk\nnotes!\n", "the tick did not reach the text on screen")

        await rig.undoAndSettle(expecting: "- [ ] milk\nnotes!\n")
        #expect(rig.textView?.string == "- [ ] milk\nnotes!\n", "the first ⌘Z did not take back exactly the tick")
        #expect(rig.document.text == "- [ ] milk\nnotes!\n")
        await rig.undoAndSettle(expecting: "- [ ] milk\nnotes\n")
        #expect(rig.textView?.string == "- [ ] milk\nnotes\n", "the second ⌘Z did not take back the typing")
        #expect(rig.document.text == "- [ ] milk\nnotes\n")
    }

    /// C25 from Preview: tick there, come back to Source, ⌘Z unticks what is on screen.
    @Test func aTickInPreviewIsUndoneFromSource() async throws {
        let rig = try Rig("- [ ] milk\n", mode: .preview)
        defer { withExtendedLifetime(rig) {} }
        #expect(EditorWorkspaceView.toggleTask(onLine: 1, in: rig.document.buffer.source, undoManager: rig.undo))
        await rig.endOfEvent()
        #expect(rig.document.text == "- [x] milk\n")
        try await rig.switchTo(.edit)
        #expect(rig.textView?.string == "- [x] milk\n")
        await rig.undoAndSettle(expecting: "- [ ] milk\n")
        #expect(rig.textView?.string == "- [ ] milk\n", "⌘Z in Source did not untick a box ticked in Preview")
        #expect(rig.document.text == "- [ ] milk\n")
    }

    /// **The checkbox reaches the undoable tick** — the test above drives the extracted action, and
    /// nothing else connects it to the button. Mutation: put `document.text = rewritten` back.
    @Test func thePreviewsCheckboxGoesThroughTheUndoableTick() throws {
        let code = try EditorFormatBarTests.source("EditorWorkspaceView.swift")
        let start = try #require(code.range(of: "private var taskToggle: ((Int) -> Void)? {"))
        let end = try #require(code.range(of: "static func toggleTask(", range: start.upperBound..<code.endIndex))
        let body = String(code[start.upperBound..<end.lowerBound])
        #expect(body.contains("Self.toggleTask(onLine: line, in: buffer.source, undoManager: undoManager)"),
                "the checkbox no longer ticks through the undoable path")
        #expect(!body.contains("document.text ="), "the checkbox writes the buffer directly again — no undo")
    }

    // MARK: A file switch in between

    /// **The production order end to end**: type in a.md, open b.md, switch mode while there, come
    /// back to a.md, ⌘Z. The store hands back a.md's stack AND the storage its actions edit, and the
    /// rebuilt view shows that storage — so the typing comes off the screen and out of the document.
    @Test func undoAfterAFileRoundTripAndAModeSwitchRevertsTheVisibleText() async throws {
        let rig = try Rig("Hello world\n", mode: .edit, store: EditorUndoStore())
        defer { withExtendedLifetime(rig) {} }
        let a = try #require(rig.document.path)
        try await rig.type(" there", at: 5)
        let b = try TestTextFiles.write("other\n", named: "Other.md")

        try await rig.open(b)
        #expect(rig.textView?.string == "other\n")
        try await rig.switchTo(.split)
        try await rig.open(a)
        #expect(rig.textView?.string == "Hello there world\n", "a.md came back without its typing")
        await rig.undoAndSettle(expecting: "Hello world\n")
        #expect(rig.textView?.string == "Hello world\n", "⌘Z after a file round trip left the typing on screen")
        #expect(rig.document.text == "Hello world\n")
    }
}
