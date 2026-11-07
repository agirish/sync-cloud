import Testing
import AppKit
import SwiftUI
@testable import FileExplorer

/// Opening a Contents result, end to end: the real workspace scanning a real folder, ↩ in the
/// filter's field (a genuine `keyDown`, the one input a test window takes), then the text view
/// itself, with the match selected and the find bar up holding the word.
///
/// Two arrivals, because they take different roads: from the empty page the file's text view is
/// built in the same update as the request (which is why the request waits a turn), and from
/// another open file the text view is kept and re-pointed.
@MainActor
@Suite(.serialized) struct EditorContentOpenMountedTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("content-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Mounted {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let model: EditorContentSearchModel
    }

    private func mount(folder: URL, document: EditorDocument, mode: EditorMode = .edit) -> Mounted {
        let model = EditorContentSearchModel()
        model.asksSpotlight = false
        model.typingSettle = .milliseconds(1)
        model.scope = .contents
        let workspace = EditorWorkspaceView(
            document: document, autosavePolicy: EditorAutosavePolicy(), folder: folder.path,
            entries: [], showsRail: true, railIsHidden: false,
            accent: .blue, accentFill: .blue, onAccent: .white,
            mode: .constant(mode), splitFraction: .constant(0.5), isNaming: .constant(false),
            typedName: .constant(""), railFilter: .constant("lentils"), railFilterIsExpanded: .constant(true),
            railTab: .constant(.files), railOutlineAnchors: .constant([:]), undoManager: UndoManager(),
            prefilledName: { "Untitled.md" }, refusal: { _ in nil },
            onOpen: { entry in _ = EditorFileStore.load(path: entry.path, into: document) },
            onCreate: { _ in true }, onRevealInBrowse: { _ in }, location: nil, onLocationDoor: { _ in },
            railRowActions: .inert, onToggleJustTheText: {}, onNewTextFile: nil, onCloseDocument: {},
            contentSearch: model, folderTrail: nil, onGoToFolder: nil)
        let host = NSHostingView(rootView: AnyView(workspace.editorTestDefaults("EditorContentOpenMountedTests")))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return Mounted(window: window, host: host, model: model)
    }

    /// Lets the main actor run until `done`, through `LayoutPumpWait`'s floor of passes: the
    /// search's settle and results are main-actor jobs, and a loaded run hands out fewer turns per
    /// second, not fewer turns (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps").
    @discardableResult
    private func spin(_ window: NSWindow, until done: () -> Bool) async -> Int {
        await LayoutPumpWait.pump(window, upTo: 15, until: done).pumps
    }

    /// ↩ in the filter's field, given the keys in the same breath as focus: text focus is
    /// arbitrated process-wide, and another suite's field can take it in between
    /// (`docs/flaky-tests.md`, "Text-field focus is arbitrated process-wide").
    private func pressReturn(in window: NSWindow) throws {
        let field = try #require(Self.editableField(in: window.contentView), "no filter field mounted")
        try #require(window.makeFirstResponder(field), "the filter's field would not take the keys")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: "\r", charactersIgnoringModifiers: "\r",
                                               isARepeat: false, keyCode: 36) else { continue }
            window.sendEvent(event)
        }
    }

    private static func editableField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let found = editableField(in: sub) { return found } }
        return nil
    }

    private func openFirstResult(folder: URL, document: EditorDocument) async throws -> (NSScrollView, NSTextView, Mounted) {
        let mounted = mount(folder: folder, document: document)
        let pumps = await spin(mounted.window) { !mounted.model.textHits.isEmpty }
        try #require(!mounted.model.textHits.isEmpty, "after \(pumps) passes the search found nothing — key \(String(describing: mounted.model.key)), phase \(mounted.model.textPhase), scope \(mounted.model.scope)")
        try pressReturn(in: mounted.window)
        var found: (NSScrollView, NSTextView)?
        await spin(mounted.window) {
            guard let scroll = EditorTestRigs.markedScroll(in: mounted.host), let view = scroll.documentView as? NSTextView,
                  view.selectedRange().length > 0, scroll.isFindBarVisible else { return false }
            found = (scroll, view)
            return true
        }
        let scroll = try #require(found?.0 ?? EditorTestRigs.markedScroll(in: mounted.host), "no text view mounted")
        let view = try #require(scroll.documentView as? NSTextView)
        return (scroll, view, mounted)
    }

    /// From the empty page, or from another open file: either road opens the file at the match
    /// with Find holding it.
    @Test(arguments: [false, true])
    func theFileOpensAtTheMatchWithFindHoldingIt(fromAnotherFile: Bool) async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = fromAnotherFile ? "Intro\nsome red lentils here\n" : "Intro\nsome red lentils here\nmore LENTILS\n"
        try Data(text.utf8).write(to: folder.appendingPathComponent("soup.md"))
        let document = EditorDocument()
        if fromAnotherFile {
            let other = folder.appendingPathComponent("other.txt")
            try Data("nothing to see\n".utf8).write(to: other)
            _ = EditorFileStore.load(path: other.path, into: document)
        }

        let (scroll, view, mounted) = try await openFirstResult(folder: folder, document: document)
        defer { PlainTextEditor.retireFindBar(of: view) }
        #expect(document.path == folder.appendingPathComponent("soup.md").path)
        #expect(view.selectedRange() == NSRange(location: 15, length: 7), "selected \(view.selectedRange())")
        #expect(scroll.isFindBarVisible, "Find was not seeded")
        _ = mounted
    }

    /// In Preview there is no text to select, so the caret's anchor goes to the match, where Source
    /// puts the caret when switched to.
    @Test func inPreviewTheCaretIsLeftAtTheMatch() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appendingPathComponent("soup.md")
        try Data("Intro\nsome red lentils here\n".utf8).write(to: note)
        let document = EditorDocument()
        let mounted = mount(folder: folder, document: document, mode: .preview)
        await spin(mounted.window) { !mounted.model.textHits.isEmpty }
        try #require(!mounted.model.textHits.isEmpty)
        try pressReturn(in: mounted.window)
        await spin(mounted.window) { document.caretAnchors.offset(for: note.path) != nil }
        #expect(document.path == note.path)
        #expect(document.caretAnchors.offset(for: note.path) == 15)
    }

    /// A PDF result opens with its find holding the word and searching, from a text file: the
    /// workspace has no PDF until the host hands it one, so the workspace must hear the hand-off,
    /// not the text body the PDF replaces.
    @Test func aPDFResultOpensWithItsFindSearchingForTheWord() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let paper = folder.appendingPathComponent("paper.pdf")
        PDFTextFixtures.write(paper.path, pages: [["Page one has a needle in it."], ["So does page two: needle."]])
        let other = folder.appendingPathComponent("other.txt")
        try Data("nothing to see\n".utf8).write(to: other)
        let document = EditorDocument()
        _ = EditorFileStore.load(path: other.path, into: document)
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false })

        let model = EditorContentSearchModel()
        model.typingSettle = .milliseconds(1)
        model.scope = .contents
        model.spotlightSearch = { _, _, answer in
            answer([EditorContentHit(path: paper.path, name: "paper.pdf", subfolder: "", kind: .pdf)])
        }
        let host = NSHostingView(rootView: AnyView(PDFHost(pdf: pdf) { shown in
            EditorWorkspaceView(
                document: document, autosavePolicy: EditorAutosavePolicy(), pdf: shown, folder: folder.path,
                entries: [], showsRail: true, railIsHidden: false,
                accent: .blue, accentFill: .blue, onAccent: .white,
                mode: .constant(.edit), splitFraction: .constant(0.5), isNaming: .constant(false),
                typedName: .constant(""), railFilter: .constant("needle"), railFilterIsExpanded: .constant(true),
                railTab: .constant(.files), railOutlineAnchors: .constant([:]), undoManager: UndoManager(),
                prefilledName: { "Untitled.md" }, refusal: { _ in nil },
                onOpen: { entry in
                    document.close()
                    pdf.open(path: entry.path, log: { _ in })
                },
                onCreate: { _ in true }, onRevealInBrowse: { _ in }, location: nil, onLocationDoor: { _ in },
                railRowActions: .inert, onToggleJustTheText: {}, onNewTextFile: nil, onCloseDocument: {},
                contentSearch: model, folderTrail: nil, onGoToFolder: nil)
        }.editorTestDefaults("EditorContentOpenMountedTests.pdf")))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        await spin(window) { model.firstResult != nil && model.textPhase != .searching(.init()) }
        try #require(model.firstResult?.hit.kind == .pdf, "no PDF result to open")
        try pressReturn(in: window)
        // Paced by the PDFKit lane the open and each page's search queue in, not by seconds: under
        // load a seconds budget runs out with pages still queued. See `LaneWait`.
        let (searched, passes) = await LaneWait.pump(window) { pdf.find.isShown && pdf.find.phase == .done }
        try #require(searched, "the find never finished (\(passes) lane passes, \(pdf.find.matches.count) matches so far)")
        #expect(pdf.path == paper.path)
        #expect(pdf.find.query == "needle", "the PDF's find holds “\(pdf.find.query)”")
        #expect(pdf.find.isShown)
        #expect(pdf.find.matches.count == 2, "found \(pdf.find.matches.count) matches")
        pdf.close()
    }
}

/// The host's rule for the workspace's PDF: handed in only while one is open.
private struct PDFHost<Content: View>: View {
    @ObservedObject var pdf: EditorPDFDocument
    let content: (EditorPDFDocument?) -> Content
    var body: some View { content(pdf.path == nil ? nil : pdf) }
}
