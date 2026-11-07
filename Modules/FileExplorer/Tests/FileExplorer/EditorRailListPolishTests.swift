import Testing
import Foundation
import SwiftUI
import AppKit
@testable import FileExplorer
import FileExplorerTestSupport

/// The Files and Outline lists' finer points: the keyboard, the Outline tab only for Markdown, a
/// greyed filter button, VoiceOver's untitled heading, and the Download a refused cloud file
/// offers. The row menu's own items are `EditorRailRowMenuTests`'.
@MainActor
@Suite struct EditorRailListPolishTests {

    // MARK: TE110 — the keyboard

    /// ↑ and ↓ walk the drawn order and stop at the ends; from nowhere, ↓ starts at the top and ↑ at
    /// the bottom. A cursor on a row the filter has hidden counts as nowhere. Mutation: wrapping at
    /// the ends, or starting ↑ at the top, must fail a line.
    @Test func theArrowsWalkTheRowsAndStopAtTheEnds() {
        let rows = ["a", "b", "c"]
        #expect(EditorRailKeyboard.step(from: "a", in: rows, by: 1) == "b")
        #expect(EditorRailKeyboard.step(from: "b", in: rows, by: -1) == "a")
        #expect(EditorRailKeyboard.step(from: "c", in: rows, by: 1) == "c", "↓ on the last row wrapped")
        #expect(EditorRailKeyboard.step(from: "a", in: rows, by: -1) == "a", "↑ on the first row wrapped")
        #expect(EditorRailKeyboard.step(from: nil, in: rows, by: 1) == "a")
        #expect(EditorRailKeyboard.step(from: nil, in: rows, by: -1) == "c")
        #expect(EditorRailKeyboard.step(from: "gone", in: rows, by: 1) == "a")
        #expect(EditorRailKeyboard.step(from: "a", in: [String](), by: 1) == nil)
        #expect(EditorRailKeyboard.delta(for: .upArrow) == -1 && EditorRailKeyboard.delta(for: .downArrow) == 1)
        #expect(EditorRailKeyboard.commit == [.return, .keypadEnter], "one of the two ⏎ keys does not open")
    }

    /// ↩ in the filter opens the first match as drawn (a text file before a PDF, since the list
    /// draws Text Files above PDFs), and nothing when nothing matches. Mutation: taking the first of
    /// the unsorted filter result must fail it.
    @Test func returnInTheFilterOpensTheFirstMatchAsDrawn() {
        let entries = [EditorRailEntry(path: "/n/Trip.pdf", name: "Trip.pdf", size: 10, isCloudOnly: false, kind: .pdf),
                       EditorRailEntry(path: "/n/Trip budget.md", name: "Trip budget.md", size: 10, isCloudOnly: false),
                       EditorRailEntry(path: "/n/Plan.md", name: "Plan.md", size: 10, isCloudOnly: false)]
        #expect(EditorFileRailView.firstMatch(entries, filter: "trip")?.name == "Trip budget.md")
        #expect(EditorFileRailView.firstMatch(entries, filter: "zz") == nil)
    }

    /// The lists take focus and keys, wear the hue's ring, and open what the cursor is on, read from
    /// the source, because a SwiftUI list's focus and keys can't be driven from `swift test`.
    @Test func bothListsTakeTheKeys() throws {
        for file in ["EditorFileRailView.swift", "EditorRailOutlineList.swift"] {
            let source = try EditorRailRowMenuTests.source(file)
            #expect(source.contains(".focusable()") && source.contains(".focusEffectDisabled()"),
                    "\(file): the list cannot take focus, or draws the system's ring")
            #expect(source.contains(".onKeyPress(keys: EditorRailKeyboard.arrows, phases: [.down, .repeat])")
                        && source.contains(".onKeyPress(keys: EditorRailKeyboard.commit, phases: .down)"),
                    "\(file): the arrows or ↩ are not handled")
            #expect(source.contains("guard press.isPlainKeystroke"), "\(file): a chord moves the cursor")
            #expect(source.contains("EditorRailFocusRing(isOn:"), "\(file): no focus ring in the hue")
        }
        let files = try EditorRailRowMenuTests.source("EditorFileRailView.swift")
        // Both fields' ↩: the name filter's alone, and the one with the Names | Contents switch,
        // whose Names side hands it back here.
        #expect(files.contains(".onSubmit(openFirstMatch)") && files.contains("onSubmitNames: openFirstMatch")
                    && files.contains("Self.firstMatch(entries, filter: filter)"),
                "↩ in the filter does not open the first match")
        // A click opens and leaves the keys in the document: taking them would make typing beep
        // and send ⌘Z to the file operations.
        let click = try #require(files.range(of: "private func row(_ entry: EditorRailEntry)"))
        let action = files[click.upperBound...].prefix(900)
        #expect(action.contains("onOpen(entry)") && !action.contains("filesFocused = true"),
                "a click on a file takes the keys from the document")
    }

    /// The focus ring is drawn, in the hue, only while focused. Rendered both ways: the focused ring
    /// puts the accent on the list's edge, the unfocused one nothing. Mutation: a constant
    /// `opacity(1)` must fail it.
    @Test func theFocusRingIsTheHueAndOnlyWhileFocused() throws {
        let size = CGSize(width: 120, height: 80)
        let on = try #require(Rendered(EditorRailFocusRing(isOn: true, accent: .blue), size: size))
        let off = try #require(Rendered(EditorRailFocusRing(isOn: false, accent: .blue), size: size))
        let whole = CGRect(origin: .zero, size: size)
        #expect(on.accentPixels(in: whole) > 0, "the focused ring drew no hue")
        #expect(off.accentPixels(in: whole) == 0, "an unfocused list wears the ring")
    }

    // MARK: TE111 — Outline only for Markdown

    /// Outline only where there are headings or bookmarks to list: a `.txt` loses it, a note keeps
    /// it with or without headings, a PDF keeps its own rule, and nothing open has none. Mutation:
    /// `[.files, .outline]` for every text file must fail the first line.
    @Test func theOutlineTabIsOfferedForMarkdownAndPDFContentsOnly() {
        #expect(EditorRailTab.shown(pdfIsOpen: false, pdfHasOutline: false, markdownIsOpen: false) == [.files])
        #expect(EditorRailTab.shown(pdfIsOpen: false, pdfHasOutline: false, markdownIsOpen: true) == [.files, .outline])
        #expect(EditorRailTab.shown(pdfIsOpen: true, pdfHasOutline: true, markdownIsOpen: false)
                == [.files, .pages, .outline])
        #expect(EditorRailTab.resolved(.outline, pdfIsOpen: false, pdfHasOutline: false, markdownIsOpen: false) == .files,
                "a remembered Outline drew an empty tab on a .txt")
        #expect(EditorRailTab.resolved(.outline, pdfIsOpen: false, pdfHasOutline: false, markdownIsOpen: true) == .outline,
                "the tab did not come back with a Markdown note")
    }

    /// The workspace says which, from the document: a note that was read, not a `.txt`, a refused
    /// note or nothing. Mutation: `document.isMarkdown` alone (tab kept on a refused note), or the
    /// rail without the argument (tab kept on a `.txt`), must fail it.
    @Test func theWorkspaceTellsTheRailWhetherANoteIsOpen() throws {
        #expect(EditorWorkspaceView.markdownIsOpen(try TestTextFiles.document(named: "plan.md")))
        #expect(!EditorWorkspaceView.markdownIsOpen(try TestTextFiles.document(named: "notes.txt")))
        #expect(!EditorWorkspaceView.markdownIsOpen(EditorDocument()))
        let workspace = try EditorRailRowMenuTests.source("EditorWorkspaceView.swift")
        #expect(workspace.contains("markdownIsOpen: Self.markdownIsOpen(document),"),
                "the rail is not told whether a note is open")
        #expect(workspace.contains("document.isMarkdown && document.refusal == nil"))
    }

    // MARK: TE138 — the filter button greyed

    /// An empty folder's filter button looks greyed, not only refuses the press: `.disabled` leaves
    /// a `.glyph` button drawn at full strength. Rendered with and without files, the button's own
    /// pixels differ. Mutation: dropping its `.foregroundStyle` must fail it.
    @Test func anEmptyFoldersFilterButtonLooksGreyed() throws {
        let entry = EditorRailEntry(path: "/n/a.md", name: "a.md", size: 1, isCloudOnly: false)
        let size = CGSize(width: 232, height: 90)
        let live = try #require(Rendered(EditorRailRowMenuTests.rail([entry], actions: .inert), size: size))
        let empty = try #require(Rendered(EditorRailRowMenuTests.rail([], actions: .inert), size: size))
        let a = try #require(Self.filterRing(live), "no filter button drawn")
        let b = try #require(Self.filterRing(empty), "no filter button drawn in an empty folder")
        #expect(!live.samePixels(a, as: empty, b), "the empty folder's filter button draws as a live one")
    }

    /// The context row's first small button, the filter; the tab segments before it are wide.
    static func filterRing(_ rendered: Rendered) -> CGRect? {
        rendered.rings.filter { $0.width < 40 }.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }.first
    }

    // MARK: TE139 — VoiceOver's untitled heading

    /// An empty `##` reads "Untitled heading" to VoiceOver, as it does on screen, and a heading with
    /// words reads them. Mutation: `entry.title` in the label must fail the first line.
    @Test func voiceOverReadsTheDrawnTitle() {
        let empty = MarkdownOutlineEntry(line: 3, level: 2, depth: 1, title: "")
        let named = MarkdownOutlineEntry(line: 5, level: 1, depth: 0, title: "Budget")
        #expect(EditorRailOutlineList.accessibilityLabel(empty, noun: .heading) == "Heading level 2, Untitled heading")
        #expect(EditorRailOutlineList.accessibilityLabel(named, noun: .heading) == "Heading level 1, Budget")
        #expect(EditorRailOutlineList.accessibilityLabel(empty, noun: .bookmark) == "Bookmark, Untitled bookmark")
    }

    // MARK: TE96 — Download where the file is refused

    /// The refusal a Download answers is the cloud one, read from `BoundedTextRead`'s own sentence;
    /// another refusal, or none, offers nothing. Mutation: answering `true` for any refusal must
    /// fail it.
    @Test func onlyTheCloudRefusalOffersADownload() {
        #expect(EditorWorkspaceView.isNotDownloaded(BoundedTextRead.Outcome.cloudOnly.caption))
        #expect(!EditorWorkspaceView.isNotDownloaded(BoundedTextRead.Outcome.tooLarge(bytes: 10_000_000).caption))
        #expect(!EditorWorkspaceView.isNotDownloaded(nil))
    }

    /// Both cards draw the Download and send it the file's path: the text card under its caption,
    /// the PDF card in place of a sentence sending the reader to a pane. Read from the source, since
    /// a button in a hosted card can't be pressed from `swift test`.
    @Test func bothCardsDrawTheDownload() throws {
        let workspace = try EditorRailRowMenuTests.source("EditorWorkspaceView.swift")
        // The text card's buttons under a refusal: Download first for a cloud refusal.
        #expect(EditorWorkspaceView.refusalButtons(for: try #require(BoundedTextRead.Outcome.cloudOnly.caption),
                                                   canTryAgain: false).first == .download)
        #expect(workspace.contains("caption(refused, refusalButtons: Self.refusalButtons(for: refused, canTryAgain: onTryAgain != nil),")
                    && workspace.contains("Self.downloadButton(accent: accent, action: { railRowActions.download(path) })"),
                "the text card's cloud refusal has no Download, or it downloads something else")
        let pdf = try EditorRailRowMenuTests.source("EditorPDFCard.swift")
        #expect(pdf.contains("} else if reason == EditorPDFDocument.notDownloadedReason, let path = pdf.path {")
                    && pdf.contains("EditorWorkspaceView.downloadButton(accent: accent) { download(path) }"),
                "the PDF card's cloud refusal has no Download")
        #expect(workspace.contains("download: railRowActions.download)"),
                "the PDF card is not handed the host's download")
    }

    /// The text card's Download is drawn: the refused cloud file's card has one more button than
    /// another refusal's. Mutation: dropping the `download:` argument must fail it.
    @Test func theTextCardDrawsTheDownloadButton() throws {
        let cloud = try Self.refusedDocument(BoundedTextRead.Outcome.cloudOnly.caption!)
        let large = try Self.refusedDocument(BoundedTextRead.Outcome.tooLarge(bytes: 10_000_000).caption!)
        let size = CGSize(width: 520, height: 300)
        let a = try #require(Rendered(EditorWorkspaceView.fixture(document: cloud), size: size))
        let b = try #require(Rendered(EditorWorkspaceView.fixture(document: large), size: size))
        #expect(a.rings.count == b.rings.count + 1,
                "the cloud card draws \(a.rings.count) buttons, the too-large one \(b.rings.count)")
    }

    /// A document refused for `reason`, at a real path.
    static func refusedDocument(_ reason: String) throws -> EditorDocument {
        let path = try TestTextFiles.write(named: "refused.md")
        let document = EditorDocument()
        document.open(.refused(reason: reason), at: path)
        return document
    }
}
