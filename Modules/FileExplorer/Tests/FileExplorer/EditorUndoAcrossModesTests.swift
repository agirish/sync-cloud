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
        /// Edit in Preview OFF unless a case asks for it: most of these are about the READ-ONLY
        /// Preview, which mounts no text view, and the setting is on by default (v5.5).
        let defaults = ScratchDefaults("EditorUndoAcrossModesTests")

        /// The stack the text view is handed: the store's current one, or the rig's own.
        var undo: UndoManager { store?.current ?? ownUndo }

        /// Whether Preview is the editable one, with a text view of its own.
        let editsInPreview: Bool

        init(_ text: String, mode: EditorMode, store: EditorUndoStore? = nil, editsInPreview: Bool = false) throws {
            self.editsInPreview = editsInPreview
            defaults.set(editsInPreview, forKey: EditorTextSettings.editsInPreviewKey)
            document = try TestTextFiles.document(named: "Undo.md", text: text)
            self.store = store
            self.mode = mode
            if let store {
                store.activate(path: document.path, text: document.text)
                document.buffer.follow(store.source)
            }
            probe = ProbeRig(Self.root(document, store?.current ?? ownUndo, mode, defaults),
                             size: CGSize(width: 900, height: 400))
        }

        /// Opens `path` the way the app does: settle the outgoing buffer by writing it (autosave's
        /// flush), then `EditorDocumentLoad.run`'s order — remember, load, activate, follow — and
        /// re-render. (The app's own copy of that order is pinned in the app target.)
        ///
        /// `endingComposition`: the settle's first step, which commits a word being composed
        /// (UND-5). `false` stands for a route that skipped it, which the store must survive.
        func open(_ path: String, endingComposition: Bool = true) async throws {
            let store = try #require(store, "a file switch needs the store")
            if endingComposition { document.buffer.source.endComposition() }
            document.markSaved(stamp: try EditorFileStore.write(document))
            store.remember(text: document.text)
            EditorFileStore.load(path: path, into: document)
            store.activate(path: document.path, text: document.text)
            document.buffer.follow(store.source)
            probe.host.rootView = Self.root(document, undo, mode, defaults)
            _ = await LayoutPumpWait.pump(probe.window, upTo: 5) {
                mode == .preview || textView?.textStorage === document.buffer.source.textStorage
            }
        }

        static func root(_ document: EditorDocument, _ undo: UndoManager, _ mode: EditorMode,
                         _ defaults: UserDefaults) -> AnyView {
            AnyView(EditorWorkspaceView.fixture(document: document, mode: mode, undoManager: undo)
                .defaultAppStorage(defaults)
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
        /// Split (the rebuild is the whole point), and in an editable Preview; none in a read-only one.
        func switchTo(_ mode: EditorMode) async throws {
            let before = textView
            self.mode = mode
            probe.host.rootView = Self.root(document, undo, mode, defaults)
            let settled = await LayoutPumpWait.pump(probe.window, upTo: 5) {
                let now = textView
                return mode == .preview && !editsInPreview ? now == nil : (now != nil && now !== before)
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

        // MARK: ⌘Z as AppKit sends it

        /// A stand-in for what `FileSyncManager` registers on the WINDOW's stack — a move.
        final class FileOperations { var undone = 0 }

        /// Puts a stand-in file operation on the window's own undo stack, which in the app is the
        /// file operations' (`ContentView`'s `.rewireUndoManager`), and lets its group close.
        func registerFileOperation() async throws -> FileOperations {
            let operations = FileOperations()
            let manager = try #require(probe.window.undoManager)
            manager.registerUndo(withTarget: operations) { $0.undone += 1 }
            manager.setActionName("Move")
            _ = await LayoutPumpWait.pump(probe.window, upTo: 2) { manager.groupingLevel == 0 }
            return operations
        }

        /// Whatever has the keyboard now.
        var firstResponder: NSResponder? { probe.window.firstResponder }

        /// **⌘Z as AppKit sends it**: `undo:` up the responder chain from the first responder, so
        /// what is undone is whatever AppKit would undo — never `undo.undo()`, which names the stack
        /// the test expects and so cannot see ⌘Z reaching a different one.
        func sendUndo() {
            _ = probe.window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil)
        }

        /// ⇧⌘Z, the same way.
        func sendRedo() {
            _ = probe.window.firstResponder?.tryToPerform(Selector(("redo:")), with: nil)
        }

        /// The Edit menu's Undo item as AppKit would draw it now: validated by the responder that
        /// would receive `undo:`, which sets the title.
        func undoTitle() -> String {
            let item = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            var responder = probe.window.firstResponder
            while let candidate = responder, !candidate.responds(to: Selector(("undo:"))) {
                responder = candidate.nextResponder
            }
            if let validator = responder as? NSMenuItemValidation {
                _ = validator.validateMenuItem(item)
            } else if let validator = responder as? NSUserInterfaceValidations {
                _ = validator.validateUserInterfaceItem(item)
            }
            return item.title
        }

        /// **⌘Z as AppKit sends it** (``sendUndo()``), then a settle — and both the screen and the
        /// document checked against `expected` (UND-10). It was `undo.undo()`, which names the
        /// stack the test expects, so a ⌘Z that reached a different stack — the file operations',
        /// after every mode switch — passed; and a check of the document alone passes on TextKit 2
        /// with the screen still showing the undone text. The screen is Source's text view; Preview
        /// draws a rendering, so there the document is the check.
        func undoAndSettle(expecting expected: String, sourceLocation: SourceLocation = #_sourceLocation) async {
            // A switch hands the keyboard to the new text view a turn after it is built.
            _ = await LayoutPumpWait.pump(probe.window, upTo: 2) { firstResponder !== probe.window }
            sendUndo()
            let showsSource = mode != .preview
            _ = await LayoutPumpWait.pump(probe.window, upTo: 2) {
                document.text == expected && (!showsSource || textView?.string == expected)
            }
            print("[undo-modes] screen \((textView?.string ?? "-").debugDescription) · document "
                  + "\(document.text.debugDescription) · canUndo \(undo.canUndo) · canRedo \(undo.canRedo)")
            #expect(document.text == expected, "⌘Z left the document at \(document.text.debugDescription)",
                    sourceLocation: sourceLocation)
            if showsSource {
                #expect(textView?.string == expected,
                        "⌘Z left the screen at \(String(reflecting: textView?.string))", sourceLocation: sourceLocation)
            }
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

    // MARK: A CRLF file (LF only, 2026-10-05)

    /// **A CRLF file's first edit, a mode switch, ⌘Z: the file's bytes come back** — the conversion
    /// was registered by the Source view the switch dismantled, and is replayed against the storage
    /// every view shares. Through Split and through a Preview round trip.
    @Test func undoAfterASwitchGivesBackACRLFFilesBytes() async throws {
        let text = "Hello\r\nworld\r\n"
        for path in [[EditorMode.split], [.preview, .edit]] {
            let rig = try Rig(text, mode: .edit)
            defer { withExtendedLifetime(rig) {} }
            try await rig.type("!", at: 5)
            #expect(rig.document.text == "Hello!\nworld\n", "the first edit did not convert the file")
            for mode in path { try await rig.switchTo(mode) }
            await rig.undoAndSettle(expecting: text)
            #expect(rig.textView?.string == text, "\(path): ⌘Z after the switch left \(String(reflecting: rig.textView?.string))")
            #expect(rig.document.text == text, "\(path): the document kept \(String(reflecting: rig.document.text))")
        }
    }

    // MARK: Typing straight after a file switch (2026-10-09)

    /// **Typing in b.md the moment it opens is b's own step, never the tail of a.md's.** The text
    /// view is re-pointed at b's storage rather than rebuilt, with the caret at the same offset, and
    /// a run of typing coalesces while the caret stays where the last keystroke left it — so the
    /// question was whether the first keystroke in b extended a's typing action, in a's stack. Typed
    /// at the caret as a key would be, with no selection set in between.
    // MARK: Where ⌘Z goes — the find bar (UND-3)

    /// **⌘Z with the caret in the find bar takes back the document's edit, never a file
    /// operation** — Source's bar and editable Preview's. The bar's field answers with a cell undo
    /// manager that forwards, past the field's own typing, to the responders above it: it used to
    /// reach the window's stack, the file operations', and undo a move while the Replace All it was
    /// pressed for stayed. The Edit menu names the document's step too.
    /// Mutation: `EditorDocumentScrollView.undoManager` returning `super.undoManager`.
    @Test(arguments: [false, true])
    func undoFromTheFindBarTakesBackTheDocumentsEdit(inPreview: Bool) async throws {
        let rig = try Rig("Hello world\n", mode: inPreview ? .preview : .edit, editsInPreview: inPreview)
        defer { withExtendedLifetime(rig) {} }
        let operations = try await rig.registerFileOperation()
        try await rig.type(" there", at: 5)
        #expect(rig.document.text == "Hello there world\n", "fixture: the typing did not reach the document")
        let view = try #require(rig.textView)
        PlainTextEditor.showFindBar(in: view)
        let bar = await LayoutPumpWait.pump(rig.probe.window, upTo: 2) { view.enclosingScrollView?.findBarView != nil }
        try #require(bar.held, "fixture: the find bar never opened")
        var fields: [NSTextField] = []
        func walk(_ v: NSView) { if let f = v as? NSTextField { fields.append(f) }; v.subviews.forEach(walk) }
        if let findBar = view.enclosingScrollView?.findBarView { walk(findBar) }
        let field = try #require(fields.first, "fixture: the find bar has no field")
        rig.probe.window.makeFirstResponder(field)
        try #require(rig.firstResponder !== view, "fixture: the caret is not in the find bar")

        #expect(rig.undoTitle() == rig.undo.undoMenuItemTitle,
                "Edit ▸ Undo names \(rig.undoTitle()), not the document's step")
        rig.sendUndo()
        _ = await LayoutPumpWait.pump(rig.probe.window, upTo: 2) { rig.document.text == "Hello world\n" }
        #expect(operations.undone == 0, "⌘Z in the find bar undid a FILE OPERATION")
        #expect(rig.document.text == "Hello world\n", "⌘Z in the find bar left the document's edit")
        if !inPreview {
            #expect(view.string == "Hello world\n", "⌘Z in the find bar left the edit on screen")
        }
    }

    // MARK: Where ⌘Z goes — nothing has the keyboard (UND-1, UND-2)

    /// **⌘Z straight after a mode switch takes back the typing, never a file operation — and the
    /// new text view has the keyboard.** Each mode builds its own text view, and the one that had
    /// the keyboard went with the old arm, leaving the window as first responder: ⌘Z then undid the
    /// window's own stack, the file operations', and the typing stayed. Through Split, a read-only
    /// Preview round trip, and into an editable Preview, whose own text view takes the keyboard.
    /// Mutation: `claimIfNobodyHasTheKeyboard` returning at once.
    @Test(arguments: [([EditorMode.split], false), ([.preview, .edit], false), ([.preview], true)])
    func undoStraightAfterAModeSwitchTakesBackTheTyping(_ path: [EditorMode], editsInPreview: Bool) async throws {
        let rig = try Rig("Hello world\n", mode: .edit, editsInPreview: editsInPreview)
        defer { withExtendedLifetime(rig) {} }
        let operations = try await rig.registerFileOperation()
        try await rig.type(" there", at: 5)
        for mode in path { try await rig.switchTo(mode) }
        let focused = await LayoutPumpWait.pump(rig.probe.window, upTo: 3) {
            rig.textView != nil && rig.firstResponder === rig.textView
        }
        #expect(focused.held, "\(path): the new text view did not take the keyboard — it is with \(String(describing: rig.firstResponder.map { type(of: $0) }))")
        #expect(rig.undoTitle() == rig.undo.undoMenuItemTitle, "\(path): Edit ▸ Undo names \(rig.undoTitle())")

        rig.sendUndo()
        _ = await LayoutPumpWait.pump(rig.probe.window, upTo: 2) { rig.document.text == "Hello world\n" }
        #expect(operations.undone == 0, "\(path): ⌘Z after the switch undid a FILE OPERATION")
        #expect(rig.document.text == "Hello world\n", "\(path): ⌘Z after the switch left the typing")
        #expect(rig.textView?.string.contains("there") == false, "\(path): ⌘Z after the switch left the typing on screen")
    }

    /// **A box ticked in read-only Preview is taken back by ⌘Z there, and Edit ▸ Undo says so.**
    /// Read-only Preview has no text view: the tick went on the document's stack while ⌘Z went to
    /// the window's, the file operations'. The anchor beside the document holds the keyboard there
    /// and answers with the document's stack; ⇧⌘Z ticks it again.
    /// Mutation: delete `EditorUndoAnchorView.undo(_:)`, and the window answers ⌘Z with its own.
    @Test func undoInReadOnlyPreviewTakesBackATick() async throws {
        let rig = try Rig("- [ ] milk\n", mode: .edit)
        defer { withExtendedLifetime(rig) {} }
        let operations = try await rig.registerFileOperation()
        rig.probe.window.makeFirstResponder(rig.textView)
        try await rig.switchTo(.preview)
        #expect(EditorWorkspaceView.toggleTask(onLine: 1, in: rig.document.buffer.source, undoManager: rig.undo))
        await rig.endOfEvent()
        #expect(rig.document.text == "- [x] milk\n")
        _ = await LayoutPumpWait.pump(rig.probe.window, upTo: 3) { rig.firstResponder is EditorUndoAnchorView }
        #expect(rig.firstResponder is EditorUndoAnchorView, "nothing beside the document took the keyboard in Preview")
        #expect(rig.undoTitle() == "Undo \(EditorWorkspaceView.taskActionName)", "Edit ▸ Undo names \(rig.undoTitle())")

        rig.sendUndo()
        _ = await LayoutPumpWait.pump(rig.probe.window, upTo: 2) { rig.document.text == "- [ ] milk\n" }
        #expect(operations.undone == 0, "⌘Z in Preview undid a FILE OPERATION")
        #expect(rig.document.text == "- [ ] milk\n", "⌘Z in Preview did not take the tick back")
        rig.sendRedo()
        _ = await LayoutPumpWait.pump(rig.probe.window, upTo: 2) { rig.document.text == "- [x] milk\n" }
        #expect(rig.document.text == "- [x] milk\n", "⇧⌘Z in Preview did not tick it again")
    }

    /// **A control with the keyboard keeps it, and ⌘Z there is what it always was** — the file pane
    /// beside a document in Edit undoes the file operations'. Nothing moves the keyboard off a
    /// view that has it. Mutation: claim whenever a text view exists, whoever holds the keyboard.
    @Test func aControlWithTheKeyboardKeepsItAndTheFileOperationsStack() async throws {
        let rig = try Rig("Hello world\n", mode: .edit)
        defer { withExtendedLifetime(rig) {} }
        let operations = try await rig.registerFileOperation()
        try await rig.type(" there", at: 5)
        let pane = Pane(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        rig.probe.host.addSubview(pane)
        rig.probe.window.makeFirstResponder(pane)
        try #require(rig.firstResponder === pane, "fixture: the stand-in pane did not take the keyboard")
        // A new text view arriving — a mode switch — is when the keyboard is handed out; the pane
        // holds it, so it must stay there.
        try await rig.switchTo(.split)
        _ = await LayoutPumpWait.pump(rig.probe.window, upTo: 1) { false }
        #expect(rig.firstResponder === pane, "the keyboard was taken from the file pane")
        #expect(rig.undoTitle() == "Undo Move", "Edit ▸ Undo names \(rig.undoTitle()) with the file pane focused")
        rig.sendUndo()
        _ = await LayoutPumpWait.pump(rig.probe.window, upTo: 2) { operations.undone == 1 }
        #expect(operations.undone == 1, "⌘Z in the file pane did not undo the file operation")
        #expect(rig.document.text == "Hello there world\n", "⌘Z in the file pane reached the document")
    }

    /// A stand-in for the file pane: a view that takes the keyboard and answers no ⌘Z of its own.
    final class Pane: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// **Edit with nothing open, and every other workspace, are as they were**: nothing is mounted
    /// to take the keyboard, the window keeps it, and ⌘Z undoes the file operations'.
    @Test func withNoDocumentOpenTheWindowKeepsTheFileOperationsStack() async throws {
        let defaults = ScratchDefaults("EditorUndoAcrossModesTests-none")
        for (name, root) in [("Edit, nothing open", AnyView(EditorWorkspaceView.fixture().defaultAppStorage(defaults))),
                             ("another workspace", AnyView(Text("Browse")))] {
            let probe = ProbeRig(AnyView(root.frame(width: 900, height: 400)), size: CGSize(width: 900, height: 400))
            defer { withExtendedLifetime(probe) {} }
            let operations = Rig.FileOperations()
            let manager = try #require(probe.window.undoManager)
            manager.registerUndo(withTarget: operations) { $0.undone += 1 }
            manager.setActionName("Move")
            _ = await LayoutPumpWait.pump(probe.window, upTo: 2) { manager.groupingLevel == 0 }
            #expect(probe.window.firstResponder === probe.window, "\(name): something took the keyboard")
            _ = probe.window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil)
            #expect(operations.undone == 1, "\(name): ⌘Z no longer undoes the file operation")
        }
    }

    // MARK: A file switch mid-composition (UND-5)

    /// **Switching file while a word is being composed commits the word first**, so it reaches the
    /// document and the disk, and coming back shows exactly what the document holds — with the
    /// history. The buffer leaves a half-composed word out while the storage holds it: the switch
    /// flushed the file without the word and kept a storage that had it, so on return the screen
    /// showed "Xhelloか" beside a document reading "Xhello", and the next keystroke wrote the word.
    /// Mutation: `endComposition` returning `false` at once.
    @Test func aFileSwitchMidCompositionCommitsTheWordFirst() async throws {
        let rig = try Rig("hello\n", mode: .edit, store: EditorUndoStore())
        defer { withExtendedLifetime(rig) {} }
        let a = try #require(rig.document.path)
        try await rig.type("X", at: 0)
        let view = try #require(rig.textView)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(view.hasMarkedText(), "fixture: no composition in progress")
        try #require(rig.document.text == "Xhello\n", "fixture: the half-composed word is already in the document")

        try await rig.open(try TestTextFiles.write("other\n", named: "Other.md"))
        #expect(rig.textView?.hasMarkedText() == false, "the composition went on into the next file")
        #expect(try String(contentsOfFile: a, encoding: .utf8) == "Xhelloか\n", "the word did not reach the disk")
        try await rig.open(a)
        #expect(rig.textView?.string == "Xhelloか\n")
        #expect(rig.document.text == rig.textView?.string, "the screen shows text the document does not hold")
        await rig.undoAndSettle(expecting: "Xhello\n")
    }

    /// **A route that parts from a document mid-composition without settling first** still never
    /// keeps a storage holding characters its fingerprint does not cover: the store ends the
    /// composition and drops the history, so the file comes back fresh, screen and document alike.
    /// Mutation: keep the entry when `remember` had to end a composition.
    @Test func aStorageStillComposingIsNotKept() async throws {
        let rig = try Rig("hello\n", mode: .edit, store: EditorUndoStore())
        defer { withExtendedLifetime(rig) {} }
        let a = try #require(rig.document.path)
        try await rig.type("X", at: 0)
        let view = try #require(rig.textView)
        view.setSelectedRange(NSRange(location: 6, length: 0))
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let parted = rig.document.buffer.source
        try await rig.open(try TestTextFiles.write("other\n", named: "Other.md"), endingComposition: false)
        try await rig.open(a)
        #expect(rig.document.buffer.source !== parted, "a storage parted from mid-composition was handed back")
        #expect(rig.textView?.string == rig.document.text, "the screen shows text the document does not hold")
        #expect(rig.document.text == (try String(contentsOfFile: a, encoding: .utf8)))
    }

    @Test func typingStraightAfterAFileSwitchIsTheNewFilesOwnStep() async throws {
        let rig = try Rig("Hello world\n", mode: .edit, store: EditorUndoStore())
        defer { withExtendedLifetime(rig) {} }
        let a = try #require(rig.document.path)
        try await rig.type("X", at: 5)
        let b = try TestTextFiles.write("other text\n", named: "Other.md")
        let before = rig.textView
        try await rig.open(b)
        let view = try #require(rig.textView)
        #expect(view === before, "fixture: the view was rebuilt, not re-pointed — the case is not reached")
        #expect(view.selectedRange() == NSRange(location: 6, length: 0), "fixture: the caret is not where a's typing left it")
        view.insertText("Y", replacementRange: view.selectedRange())
        await rig.endOfEvent()
        #expect(rig.document.text == "other Ytext\n")
        #expect(rig.undo.canUndo, "b's first keystroke registered nothing in b's stack")
        await rig.undoAndSettle(expecting: "other text\n")
        #expect(rig.document.text == "other text\n", "⌘Z in b left \(String(reflecting: rig.document.text))")
        try await rig.open(a)
        await rig.undoAndSettle(expecting: "Hello world\n")
        #expect(rig.document.text == "Hello world\n", "a's ⌘Z left \(String(reflecting: rig.document.text))")
    }
}
