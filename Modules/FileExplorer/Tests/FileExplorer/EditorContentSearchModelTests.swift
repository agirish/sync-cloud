import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// Search inside files (RD38): when the window's search asks, what it keeps, what Spotlight is
/// asked, what the results say — and that opening a text result leaves Find holding the word.
@MainActor
@Suite(.serialized) struct EditorContentSearchModelTests {

    /// A model whose text half is a stream this test drives, counting what it was asked.
    private func model() -> (EditorContentSearchModel, Asked) {
        let asked = Asked()
        let model = EditorContentSearchModel()
        model.asksSpotlight = false
        model.typingSettle = .milliseconds(1)
        model.textSearch = { query, folder in
            AsyncStream { continuation in
                asked.queries.append((query, folder))
                asked.continuations.append(continuation)
                continuation.onTermination = { _ in Task { @MainActor in asked.ended += 1 } }
            }
        }
        return (model, asked)
    }

    @MainActor final class Asked {
        var queries: [(String, String)] = []
        var continuations: [AsyncStream<EditorContentSearch.Event>.Continuation] = []
        var ended = 0
    }

    /// The window an ABSENCE is given — a search that should not start, or a hit that should not
    /// be asked for. Never what a positive assertion waits on: that is `waitFor`.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// Waits for what the next assertion needs, bounded by `LayoutPumpWait`'s floor of passes
    /// rather than by seconds, and fails at the caller when it never comes.
    ///
    /// All of it arrives on scheduler turns: the typing settle's task, the scan's events, and a
    /// stream's end, counted by the `Task` its `onTermination` starts. `settle()` was ample alone
    /// and short of it in a loaded CI run (40614524397), where `ended` read 0 where it wanted 1.
    /// See `docs/flaky-tests.md`, "Fixed pumps and fixed sleeps".
    private func waitFor(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
                         until condition: () -> Bool) async {
        let wait = await LayoutPumpWait.poll(upTo: 5, until: condition)
        #expect(wait.held, "\(what), after \(wait.passes) passes", sourceLocation: sourceLocation)
    }

    /// Names asks nothing; Contents with too little typed asks nothing; Contents asks once per
    /// question, however often the same question is put.
    @Test func searchesOnlyOnContentsAndOncePerQuestion() async {
        let (model, asked) = model()
        model.request(folder: "/f", query: "lentils")
        await settle()
        #expect(asked.queries.isEmpty, "the Names side searched contents")

        model.scope = .contents
        model.request(folder: "/f", query: "l")
        await settle()
        #expect(asked.queries.isEmpty, "one letter was searched for")

        model.request(folder: "/f", query: " lentils ")
        await waitFor("the trimmed question was never asked") { !asked.queries.isEmpty }
        model.request(folder: "/f", query: "lentils")
        await settle()
        #expect(asked.queries.map(\.0) == ["lentils"], "asked \(asked.queries)")
        #expect(asked.queries.first?.1 == "/f")
    }

    /// A new query or folder ends the running search before starting its own; Names, or a folded
    /// filter, ends it and empties the results.
    @Test func aNewQuestionEndsTheRunningSearch() async {
        let (model, asked) = model()
        model.scope = .contents
        model.request(folder: "/f", query: "lentils")
        await waitFor("the first search was never asked") { !asked.queries.isEmpty }
        model.request(folder: "/f", query: "lentil soup")
        await waitFor("the new query was not asked, or the first search not ended") {
            asked.queries.count >= 2 && asked.ended >= 1
        }
        #expect(asked.queries.map(\.0) == ["lentils", "lentil soup"])
        #expect(asked.ended == 1, "the first search was not ended")

        model.request(folder: "/g", query: "lentil soup")
        await waitFor("the new folder was not asked, or the second search not ended") {
            asked.queries.count >= 3 && asked.ended >= 2
        }
        #expect(asked.ended == 2)
        #expect(model.key?.folder == "/g")

        model.scope = .names
        model.request(folder: "/g", query: "lentil soup")
        await waitFor("Names did not end the third search") { asked.ended >= 3 }
        #expect(asked.ended == 3)
        #expect(model.key == nil)
        #expect(model.textPhase == .idle)
    }

    /// Typing fast is one search: each keystroke inside the settle replaces the last.
    @Test func typingFastIsOneSearch() async {
        let (model, asked) = model()
        model.typingSettle = .milliseconds(80)
        model.scope = .contents
        for prefix in ["le", "len", "lent", "lenti"] { model.request(folder: "/f", query: prefix) }
        await waitFor("the last keystroke was never searched") { asked.queries.contains { $0.0 == "lenti" } }
        await settle()
        #expect(asked.queries.map(\.0) == ["lenti"])
    }

    /// Files read out of order are listed in the walk's order, and the phase follows the events.
    @Test func hitsAreListedInWalkOrderWhateverOrderTheyArrive() async {
        let (model, asked) = model()
        model.scope = .contents
        model.request(folder: "/f", query: "word")
        await waitFor("the search was never asked") { !asked.continuations.isEmpty }
        let stream = try! #require(asked.continuations.first)
        func hit(_ name: String) -> EditorContentHit {
            EditorContentHit(path: "/f/" + name, name: name, subfolder: "", kind: .text, lineCount: 1)
        }
        stream.yield(.hit(hit("c.md"), order: 2))
        stream.yield(.hit(hit("a.md"), order: 0))
        stream.yield(.progress(.init(read: 2, found: 3, walked: true)))
        stream.yield(.hit(hit("b.md"), order: 1))
        await waitFor("the hits were not all taken") { model.textHits.count >= 3 }
        #expect(model.textHits.map(\.name) == ["a.md", "b.md", "c.md"])
        #expect(model.textPhase == .searching(.init(read: 2, found: 3, walked: true)))
        var summary = EditorContentSearch.Summary()
        summary.read = 3
        stream.yield(.finished(summary))
        await waitFor("the end was not taken") {
            if case .finished = model.textPhase { true } else { false }
        }
        #expect(model.textPhase == .finished(summary))
        #expect(model.firstResult?.hit.name == "a.md")
    }

    // MARK: Spotlight

    /// Every word a prefix, case- and accent-blind, word-wise; syntax typed in is searched for, not
    /// read; and the string is one Spotlight takes.
    @Test func theSpotlightQueryIsOneSpotlightAccepts() throws {
        let string = try #require(EditorContentSpotlight.queryString(for: "red lentils"))
        #expect(string.hasPrefix(#"(kMDItemTextContent == "red*"cdw) && (kMDItemTextContent == "lentils*"cdw) && ("#))
        #expect(string.contains(#"kMDItemContentTypeTree == "com.adobe.pdf""#))
        #expect(string.contains(#"kMDItemContentTypeTree == "org.openxmlformats.wordprocessingml.document""#))
        #expect(NSPredicate(fromMetadataQueryString: string) != nil)

        let hostile = try #require(EditorContentSpotlight.queryString(for: #"a"b\c*"#))
        #expect(hostile.hasPrefix(#"(kMDItemTextContent == "a\"b\\c\**"cdw)"#), "got \(hostile)")
        #expect(NSPredicate(fromMetadataQueryString: hostile) != nil)

        #expect(EditorContentSpotlight.queryString(for: "  \n ") == nil)
    }

    /// A Spotlight path is listed under the folder as the rail spells it; hidden and outside paths
    /// are not listed.
    @Test func aSpotlightPathIsSpelledUnderTheFolder() {
        let direct = EditorContentSpotlight.hit(forPath: "/Users/a/Docs/Tax/2025.pdf", root: "/Users/a/Docs",
                                                resolvedRoot: "/Volumes/x/Docs")
        #expect(direct?.path == "/Users/a/Docs/Tax/2025.pdf")
        #expect(direct?.subfolder == "Tax")
        #expect(direct?.kind == .pdf)

        let linked = EditorContentSpotlight.hit(forPath: "/private/var/f/Docs/plan.docx", root: "/var/f/Docs",
                                                resolvedRoot: "/private/var/f/Docs")
        #expect(linked?.path == "/var/f/Docs/plan.docx")
        #expect(linked?.subfolder == "")
        #expect(linked?.kind == .document)

        #expect(EditorContentSpotlight.hit(forPath: "/Users/a/Docs/.Trash/x.pdf", root: "/Users/a/Docs",
                                           resolvedRoot: "/Users/a/Docs") == nil)
        #expect(EditorContentSpotlight.hit(forPath: "/Users/a/Other/x.pdf", root: "/Users/a/Docs",
                                           resolvedRoot: "/Users/a/Docs") == nil)
        #expect(EditorContentSpotlight.hit(forPath: "/Users/a/DocsMore/x.pdf", root: "/Users/a/Docs",
                                           resolvedRoot: "/Users/a/Docs") == nil,
                "a sibling folder whose name starts with the folder's is not inside it")
    }

    // MARK: What the results say

    @Test func theStatusLineSaysWhereTheSearchIs() {
        typealias C = EditorRailContentCaption
        let key = EditorContentSearchModel.Key(folder: "/f", query: "lentils")
        #expect(C.status(query: "l", folderName: "Recipes", key: nil, text: .idle, spotlight: .idle,
                         textFiles: 0, documents: 0)?.hasPrefix("Type a word") == true)
        #expect(C.status(query: "lentil", folderName: "Recipes", key: key, text: .idle, spotlight: .idle,
                         textFiles: 0, documents: 0) == "Searching…", "a query still settling")
        #expect(C.status(query: "lentils", folderName: "Recipes", key: key,
                         text: .searching(.init(read: 0, found: 0, walked: false)), spotlight: .searching,
                         textFiles: 0, documents: 0) == "Looking through the folders…")
        #expect(C.status(query: "lentils", folderName: "Recipes", key: key,
                         text: .searching(.init(read: 120, found: 475, walked: true)), spotlight: .searching,
                         textFiles: 0, documents: 0) == "Searching 120 of 475 text files…")

        var summary = EditorContentSearch.Summary()
        summary.read = 475
        #expect(C.status(query: "lentils", folderName: "Recipes", key: key, text: .finished(summary),
                         spotlight: .finished, textFiles: 0, documents: 0)
                == "Nothing in “Recipes” or the folders inside it contains “lentils”.")
        #expect(C.status(query: "lentils", folderName: "Recipes", key: key, text: .finished(summary),
                         spotlight: .searching, textFiles: 0, documents: 0) == "475 text files searched.",
                "nothing found is not said while Spotlight is still answering")
        summary.notDownloaded = 3
        summary.tooLarge = 1
        summary.stop = .fileLimit(500)
        let full = C.status(query: "lentils", folderName: "Recipes", key: key, text: .finished(summary),
                            spotlight: .unavailable, textFiles: 500, documents: 0) ?? ""
        #expect(full.contains("475 text files searched."))
        #expect(full.contains("3 not downloaded, so not searched."))
        #expect(full.contains("1 over \(FileSyncManager.formatBytes(BoundedTextRead.maxBytes)), so not searched."))
        #expect(full.contains("Stopped at 500 files"))
        #expect(full.contains("Spotlight couldn’t be asked"))
    }

    @Test func theSpotlightGroupIsNamedForWhatItHolds() {
        typealias C = EditorRailContentCaption
        let pdf = EditorContentHit(path: "/f/a.pdf", name: "a.pdf", subfolder: "", kind: .pdf)
        let word = EditorContentHit(path: "/f/b.docx", name: "b.docx", subfolder: "", kind: .document)
        #expect(C.documentHeading([], phase: .finished) == nil)
        #expect(C.documentHeading([], phase: .unavailable) == nil)
        #expect(C.documentHeading([], phase: .searching) == "PDFs · asking Spotlight…")
        #expect(C.documentHeading([pdf, pdf], phase: .finished) == "PDFs · 2 · from Spotlight")
        #expect(C.documentHeading([pdf, word], phase: .finished) == "PDFs and Office Files · 2 · from Spotlight")
    }

    /// The match is lit in the snippet, and nothing else is.
    @Test func theSnippetLightsTheMatchOnly() {
        let line = EditorContentLine(line: 3, column: 5, length: 7, snippet: "red lentils, rice",
                                     highlight: NSRange(location: 4, length: 7))
        let text = EditorRailContentCaption.snippet(line, accent: .blue)
        let lit = text.runs.filter { $0.backgroundColor != nil }.map { String(text[$0.range].characters) }
        #expect(lit == ["lentils"])
    }

    // MARK: Where it is

    /// The filter opens over rows to filter — or, where it can search inside files, over a folder
    /// of folders, which is where a search of the folders inside is wanted (TE138 greys the rest).
    @Test func theFilterOpensWhereThereIsSomethingToSearch() {
        #expect(EditorFileRailView.filterIsOffered(hasEntries: true, searchesContents: false, hasSubfolders: false))
        #expect(!EditorFileRailView.filterIsOffered(hasEntries: false, searchesContents: false, hasSubfolders: true))
        #expect(EditorFileRailView.filterIsOffered(hasEntries: false, searchesContents: true, hasSubfolders: true))
        #expect(!EditorFileRailView.filterIsOffered(hasEntries: false, searchesContents: true, hasSubfolders: false))
    }

    @Test func theSwitchSaysWhatTheFieldWillDo() {
        #expect(EditorRailFilterScope.allCases.map(\.title) == ["Names", "Contents"])
        #expect(EditorRailFilterScope.names.placeholder == "Filter by name")
        #expect(EditorRailFilterScope.contents.placeholder == "Search inside files")
    }

    // MARK: Opening a text result: Find holds the word

    private func hosted(_ text: String) -> (scroll: NSScrollView, view: NSTextView, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroll.identifier = EditorDocumentSurface.identifier
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.string = text
        return (scroll, view, window)
    }

    /// **The match stays selected, the bar shows it, and ⌘G goes on to the next match** — in a
    /// different case, since the search is the name filter's, case-blind. Measured on a real text
    /// view in a window: the bar's field takes the keyboard when it opens, and an incremental
    /// search could have moved the selection to the first match in the file.
    @Test func seedingFindKeepsTheMatchAndStepsToTheNext() {
        let (scroll, view, window) = hosted("Lentils first\nthen red lentils here\nand LENTILS last\n")
        defer { PlainTextEditor.retireFindBar(of: view) }
        let second = ((view.string as NSString).range(of: "lentils", options: [], range: NSRange(location: 14, length: 30)))
        #expect(second.location == 23)

        PlainTextEditor.seedFind(in: view, selecting: second)

        #expect(scroll.isFindBarVisible, "the find bar did not open")
        #expect(view.selectedRange() == second, "seeding Find moved the selection to \(view.selectedRange())")
        #expect(window.firstResponder === view, "the keys stayed in the find bar")
        let fieldText = Self.fields(in: scroll.findBarView).first?.stringValue
        #expect(fieldText == "lentils", "the find field holds \(fieldText ?? "nothing")")

        EditorDocumentSurface.performFind(.nextMatch, in: window)
        let next = view.selectedRange()
        #expect((view.string as NSString).substring(with: next) == "LENTILS", "⌘G selected \(next)")
    }

    private static func fields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var found: [NSTextField] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField { found.append(field) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// **The editor itself does it, from the request** — the call site, mounted: a request with a
    /// length selects that much and seeds Find; the same request without `seedsFind` leaves the bar
    /// down, so the bar is the request's doing. Asked of a view already up, as the workspace asks:
    /// a request standing when a text view is built is taken as answered (`makeCoordinator`).
    @Test func theEditorSelectsAndSeedsFromTheRequest() throws {
        let text = "one\nred lentils\n"
        let source = EditorSourceStorage(text: text)
        func editor(_ request: EditorScrollRequest?) -> AnyView {
            AnyView(PlainTextEditor(source: source, isEditable: true, fontScale: 1, documentID: "/a/b.md",
                                    undoManager: UndoManager(), scrollRequest: request)
                .editorTestDefaults("EditorContentSearchModelTests"))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: editor(nil))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(Self.markedScroll(in: host), "no text view mounted — this test sees nothing")
        let view = try #require(scroll.documentView as? NSTextView)
        defer { PlainTextEditor.retireFindBar(of: view) }

        host.rootView = editor(EditorScrollRequest(line: 2, token: 1, column: 5, length: 7, seedsFind: false))
        host.layoutSubtreeIfNeeded()
        #expect(view.selectedRange() == NSRange(location: 8, length: 7))
        #expect(!scroll.isFindBarVisible, "the bar opened without being asked")

        host.rootView = editor(EditorScrollRequest(line: 1, token: 2, column: 1, length: 3, seedsFind: true))
        host.layoutSubtreeIfNeeded()
        #expect(view.selectedRange() == NSRange(location: 0, length: 3))
        #expect(scroll.isFindBarVisible, "the request did not seed Find")
        #expect(Self.fields(in: scroll.findBarView).first?.stringValue == "one")
    }

    private static func markedScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.identifier == EditorDocumentSurface.identifier { return scroll }
        for sub in view.subviews { if let found = markedScroll(in: sub) { return found } }
        return nil
    }
}
