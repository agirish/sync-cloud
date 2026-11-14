import Testing
import AppKit
import PDFKit
import SwiftUI
import Design
@testable import SyncCloud

/// The one rule shared by every menu chord that is also a text-editing key: whether a keystroke
/// reaches your files or your caret. A menu key equivalent cannot be driven from a unit test, so
/// `TextEditingChord.route` takes the responder injected, which makes the rule checkable without a
/// window.
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

    /// Nothing focused routes to the file action, not the editor one. A cold window has no first
    /// responder, which is the state a pane is in when you click a row and press ⌘C.
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

    /// The editor branch hands the real editor over, not merely fires. A route that ignored its
    /// argument would pass the test above while ⌘C in a text field silently copied nothing.
    @Test func theEditorBranchReceivesTheResponderItMatched() {
        let editor = fieldEditor()
        var received: NSTextView?
        TextEditingChord.route(responder: editor,
                               editorAction: { received = $0 },
                               fileAction: {})
        #expect(received === editor, "the editor branch fired without the editor to act on")
    }

    /// Exactly one branch runs. A router that ran both would satisfy every assertion above and
    /// would, in the live app, copy your files *and* your text.
    @Test(arguments: [true, false])
    func exactlyOneBranchRuns(caretHasFocus: Bool) {
        var editorRuns = 0, fileRuns = 0
        TextEditingChord.route(responder: caretHasFocus ? fieldEditor() : nil,
                               editorAction: { _ in editorRuns += 1 },
                               fileAction: { fileRuns += 1 })
        #expect(editorRuns + fileRuns == 1)
        #expect(editorRuns == (caretHasFocus ? 1 : 0))
    }

    // MARK: The PDF reader

    /// A PDF reader takes ⌘C and ⌘A when the item offers it its half, and the reader it matched is
    /// handed over, so the copy is the page's selection rather than the pane's files.
    @Test func aReaderTakesTheChordsThatOfferIt() {
        let reader = PDFView(frame: .zero)
        var ran = "", received: PDFView?
        TextEditingChord.route(responder: reader,
                               editorAction: { _ in ran = "editor" },
                               readerAction: { received = $0; ran = "reader" },
                               fileAction: { ran = "file" })
        #expect(ran == "reader")
        #expect(received === reader, "the reader branch fired without the reader to act on")
    }

    /// A view inside the reader, such as Fill & Sign's overlay while its toolbar is up, is the
    /// reader's, so ⌘C there copies the page's selection, not the pane's file. A view outside any
    /// reader is not one.
    @Test func aViewInsideAReaderTakesTheReadersHalf() {
        let reader = PDFView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let inside = NSView(frame: reader.bounds)
        reader.addSubview(inside)
        var received: PDFView?, ran = ""
        TextEditingChord.route(responder: inside,
                               editorAction: { _ in ran = "editor" },
                               readerAction: { received = $0; ran = "reader" },
                               fileAction: { ran = "file" })
        #expect(ran == "reader" && received === reader)
        ran = ""
        TextEditingChord.route(responder: NSView(frame: .zero),
                               editorAction: { _ in ran = "editor" },
                               readerAction: { _ in ran = "reader" },
                               fileAction: { ran = "file" })
        #expect(ran == "file")
    }

    /// Without a reader half (Cut, Paste, ⌘⌫ and the rest) a reader refuses the chord and never
    /// falls through to the file action, which would cut the open PDF onto the file clipboard on ⌘X
    /// or offer to delete it on ⌘⌫. Checked for the reader and for a view inside it, where Fill &
    /// Sign's overlay sits.
    @Test func aReaderRefusesWhereTheItemOffersNoReaderHalf() {
        let reader = PDFView(frame: .zero)
        let inside = NSView(frame: .zero)
        reader.addSubview(inside)
        for responder: NSResponder in [reader, inside] {
            var ran = ""
            TextEditingChord.route(responder: responder,
                                   editorAction: { _ in ran = "editor" },
                                   readerRefusal: { ran = "refused" },
                                   fileAction: { ran = "file" })
            #expect(ran == "refused", "\(type(of: responder)) ran \(ran)")
        }
    }

    /// The caret still wins, and nothing else becomes a reader: a field editor with a reader half
    /// offered goes to the editor, a file table to the files.
    @Test func theReaderHalfChangesNothingElse() {
        var ran: [String] = []
        for responder: NSResponder? in [NSTextView(frame: .zero), NSTableView(frame: .zero), nil] {
            TextEditingChord.route(responder: responder,
                                   editorAction: { _ in ran.append("editor") },
                                   readerAction: { _ in ran.append("reader") },
                                   fileAction: { ran.append("file") })
        }
        #expect(ran == ["editor", "file", "file"])
    }

    // MARK: Preview's selected words

    /// SwiftUI's own selectable text, the view Preview draws, not a stand-in: the rule leans on how
    /// that private view answers `validateMenuItem(_:)`, no while nothing is selected and yes once
    /// something is.
    @Test func previewsSelectedWordsCopyThemselves() throws {
        let host = NSHostingView(rootView: Text("Weeknight pasta").textSelection(.enabled))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let words = try #require(host.subviews.first { $0.responds(to: #selector(NSText.copy(_:))) },
                                 "SwiftUI no longer draws selectable text as a view that copies")
        #expect(TextEditingChord.selectionCopier(of: words) == nil, "nothing is selected yet")
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: words, from: nil)
        #expect(TextEditingChord.selectionCopier(of: words) === words)
    }

    /// Nothing else copies itself: a field editor is the caret's (it never gets this far), and a
    /// file table, a plain view and no responder leave ⌘C to the file half.
    @Test func onlyAViewWithASelectionCopiesItself() {
        for responder: NSResponder? in [NSTableView(frame: .zero), NSView(frame: .zero), nil] {
            #expect(TextEditingChord.selectionCopier(of: responder) == nil)
        }
    }

    /// ⌘C's file half asks Preview first; ⌘X and ⌘V have nothing to take from read-only words.
    @Test func copyAsksPreviewBeforeTheFile() throws {
        let commands = try macAppFile("ShortcutCommands.swift")
        let copy = CodeText(try declarationBody(of: "struct CopyCommand: View", in: commands))
        #expect(copy.contains("fileAction: { TextEditingChord.copySelection(orElse: { clipboard?.copy?() }) }"))
        for item in ["struct CutCommand: View", "struct PasteCommand: View"] {
            #expect(!CodeText(try declarationBody(of: item, in: commands)).contains("copySelection"))
        }
    }

    // `route` decides through `belongsToTextEditor`, so the predicate tests above pin the shipped
    // rule, and the scans below pin that every colliding chord calls `route`.

    // MARK: Call-site coverage — the routing has to be WIRED, not merely correct

    /// The exact chords NSText also claims: select-all, cut/copy/paste, delete-to-line-start, the
    /// line moves (⌘←/⌘→, ±⇧) and the document moves (⌘↑/⌘↓, ±⇧). Chords, not bare keys: the field
    /// editor does not bind ⇧⌘V, so it needs no routing. The set is a property of AppKit's field
    /// editor, so it stays stable while the app's registry grows.
    private static let textEditorClaimedChords: [AppChord] = [
        AppChord("a", .command), AppChord("x", .command),
        AppChord("c", .command), AppChord("v", .command),
        AppChord(.delete, .command),
        AppChord(.leftArrow, .command), AppChord(.rightArrow, .command),
        AppChord(.leftArrow, [.shift, .command]), AppChord(.rightArrow, [.shift, .command]),
        AppChord(.upArrow, .command), AppChord(.downArrow, .command),
        AppChord(.upArrow, [.shift, .command]), AppChord(.downArrow, [.shift, .command]),
    ]

    /// How each colliding chord is spelled at its registration in `ShortcutCommands.swift`.
    /// Hand-written, so the set-equality test below guards it: a new chord on a text-editing key
    /// fails that test until it is named here, which puts its registration under the routing scan.
    ///
    /// Derived from `AppChord.registry`, so a bare `.keyboardShortcut("c", modifiers: .command)`
    /// literal is invisible here; `ShortcutsReferenceTests`' literal scan forces such a chord into
    /// the reference table instead. A chord built from a variable would evade both.
    private static let collidingRegistrations: [(spelling: String, chords: [AppChord])] = [
        ("AppChord.selectAll.key", [.selectAll]),
        ("AppChord.cut.key", [.cut]),
        ("AppChord.copy.key", [.copy]),
        ("AppChord.paste.key", [.paste]),
        ("AppChord.deleteSelection.key", [.deleteSelection]),
        ("AppChord.transfer(", [.copyToLeft, .copyToRight, .moveToLeft, .moveToRight]),
        ("AppChord.enclosingFolder.key", [.enclosingFolder]),
        ("AppChord.openSelectedFolder.key", [.openSelectedFolder]),
    ]

    @Test func theCollidingSpellingTableMatchesTheRegistry() {
        let claimed = Set(Self.textEditorClaimedChords.map(\.display))
        let colliding = AppChord.registry.filter { claimed.contains($0.display) }
        let tabled = Self.collidingRegistrations.flatMap(\.chords)
        #expect(Set(colliding.map(\.display)) == Set(tabled.map(\.display)),
                """
                the registry's text-editing chords and the spelling table disagree. A chord \
                added on one of NSText's own bindings must be listed in `collidingRegistrations` \
                so the routing scan covers its registration. Registry: \(colliding.map(\.display)); \
                table: \(tabled.map(\.display))
                """)
        // Non-vacuity: the known colliding chords are actually in the derived set.
        #expect(colliding.count >= 9, "the derived colliding set shrank — the filter is broken, not the app")
    }

    /// The file cut into per-command blocks, comments stripped first, since comment text may name
    /// a chord's spelling; only code decides.
    ///
    /// Top-level struct declarations delimit the blocks; nested types are indented and don't
    /// split. Modifiers are normalized so a `private struct` does not merge into the preceding
    /// block, where that block's route call would vouch for a command that lost its own.
    private static func registrationBlocks(of source: String) -> [String] {
        let normalized = sourceCodeOnly(source).replacing(
            #/\n(?:@[A-Za-z]+ )*(?:(?:private|fileprivate|internal|public) )?struct /#,
            with: "\nstruct ")
        return normalized.components(separatedBy: "\nstruct ")
    }

    /// Every registration of a colliding chord hands the keystroke through `TextEditingChord.route`.
    /// Without this, removing the route from ⌘C would ship "⌘C over a caret copies files" with
    /// every other suite green.
    @Test func everyCollidingChordRegistrationRoutesThroughTextEditingChord() throws {
        let source = try shortcutCommandsSource()
        let blocks = Self.registrationBlocks(of: source)
        try #require(blocks.count > 10, "ShortcutCommands.swift split into \(blocks.count) blocks — the scan is broken")

        for (spelling, chords) in Self.collidingRegistrations {
            let registering = blocks.filter { $0.contains(".keyboardShortcut(") && $0.contains(spelling) }
            try #require(!registering.isEmpty,
                         "no block registers \(spelling) — the spelling table is stale, fix the table")
            for block in registering {
                let name = block.prefix(while: { $0 != ":" && $0 != "\n" })
                #expect(block.contains("TextEditingChord.route("),
                        """
                        \(name) registers \(chords.map(\.display).joined(separator: " ")) without \
                        routing through TextEditingChord.route — with the caret in any text field \
                        this chord would act on FILES instead of the text
                        """)
            }
        }
    }

    /// The scan's own failure mode: a matcher that finds nothing fails, never passes. A decoy
    /// spelling that exists nowhere must be reported as stale, proving `#require(!registering
    /// .isEmpty)` really is reachable.
    @Test func theRoutingScanRefusesAStaleSpelling() throws {
        // The same pipeline the real scan uses, or the decoy would prove reachability for a
        // matcher nothing runs.
        let blocks = Self.registrationBlocks(of: try shortcutCommandsSource())
        let registering = blocks.filter { $0.contains(".keyboardShortcut(") && $0.contains("AppChord.decoyNeverRegistered.key") }
        #expect(registering.isEmpty, "the decoy is supposed to match nothing")
    }
}

/// `MacApp/ShortcutCommands.swift` alone, with a truncation guard sized to the file: a partial read
/// would make every `contains` above answer false and every negative vacuously true.
private func shortcutCommandsSource() throws -> String {
    let text = try macAppFile("ShortcutCommands.swift")
    try #require(text.count > 5_000, "ShortcutCommands.swift read as \(text.count) characters — truncated?")
    return text
}
