import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SyncCloud

/// Up and Down in Ask Claude's box: the questions typed before, then back to the unsent draft.
///
/// Serialized: two panels hosted at once, in windows that can't be key, take the keyboard focus
/// from each other at every await (measured: either test alone passes, the pair side by side fails).
@MainActor
@Suite(.serialized) struct AskClaudePromptHistoryTests {

    private static func history(_ sent: [String]) -> AskClaudePromptHistory {
        var history = AskClaudePromptHistory()
        for question in sent { history.record(question) }
        return history
    }

    @Test func upWalksBackNewestFirstAndStopsAtTheOldest() {
        var history = Self.history(["one", "two", "three"])
        #expect(history.older(than: "") == "three")
        #expect(history.older(than: "three") == "two")
        #expect(history.older(than: "two") == "one")
        #expect(history.older(than: "one") == nil)
        #expect(history.position == 0)
    }

    @Test func downComesBackToTheDraftTypedAndNotSent() {
        var history = Self.history(["one", "two"])
        #expect(history.older(than: "half a quest") == "two")
        #expect(history.older(than: "two") == "one")
        #expect(history.newer(than: "one") == "two")
        #expect(history.newer(than: "two") == "half a quest")
        #expect(history.position == nil)
        #expect(history.newer(than: "half a quest") == nil)
    }

    @Test func nothingSentYetLeavesTheBoxAlone() {
        var history = AskClaudePromptHistory()
        #expect(history.older(than: "typing") == nil)
        #expect(history.newer(than: "typing") == nil)
    }

    @Test func aChangeToARecalledQuestionSurvivesTheWalkAndGoesAtTheNextSend() {
        var history = Self.history(["one", "two"])
        _ = history.older(than: "")
        #expect(history.older(than: "two, changed") == "one")
        #expect(history.newer(than: "one") == "two, changed")
        history.record("two, changed")
        #expect(history.entries == ["one", "two", "two, changed"])
        #expect(history.older(than: "") == "two, changed")
        #expect(history.older(than: "two, changed") == "two")
    }

    @Test func keepsTheLastTenEachOnceAndNoBlanks() {
        var history = Self.history((1...12).map { "q\($0)" })
        #expect(history.entries == (3...12).map { "q\($0)" })
        history.record("q5")
        history.record("   ")
        history.record("  q12\n")
        #expect(history.entries.count == 10)
        #expect(history.entries.suffix(2) == ["q5", "q12"])
        #expect(history.entries.filter { $0 == "q5" }.count == 1)
    }

    @Test func aFileEditedByHandBringsBackNoBlanksRepeatsOrMore() {
        let history = AskClaudePromptHistory(entries: ["a", "  ", "b", " a ", ""] + (1...10).map { "q\($0)" })
        #expect(history.entries == (1...10).map { "q\($0)" })
        #expect(AskClaudePromptHistory(entries: ["a", "  ", "b", " a\n"]).entries == ["b", "a"])
    }

    @Test func aSendStartsTheWalkAgainFromAnEmptyDraft() {
        var history = Self.history(["one", "two"])
        _ = history.older(than: "draft")
        history.record("three")
        #expect(history.position == nil)
        #expect(history.older(than: "") == "three")
        #expect(history.newer(than: "three") == "")
    }

    // MARK: The chat keeps it

    private func historyFile() -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AskClaudePromptHistoryTests-\(UUID().uuidString)")
        return (dir, dir.appendingPathComponent("prompts.json"))
    }

    /// Kept across a relaunch, and through the chat's own fresh starts (an hour away, a hidden
    /// folder, a changed setting), which come as a question is sent.
    @Test func theChatKeepsTypedQuestionsAcrossLaunchesAndItsOwnFreshStarts() throws {
        let (dir, file) = historyFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = AskClaudeChat(historyURL: file)
        for n in 1...11 { first.rememberSent("question \(n)") }
        first.startOver()
        #expect(first.recallOlder(than: "") == "question 11")

        let again = AskClaudeChat(historyURL: file)
        var seen: [String] = []
        var shown = "unsent"
        while let older = again.recallOlder(than: shown) { seen.append(older); shown = older }
        #expect(seen == (2...11).reversed().map { "question \($0)" })
        while let newer = again.recallNewer(than: shown) { shown = newer }
        #expect(shown == "unsent")
    }

    /// New Chat, the button, forgets them, on disk too.
    @Test func newChatClearsTheTypedQuestions() throws {
        let (dir, file) = historyFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chat = AskClaudeChat(historyURL: file)
        chat.rememberSent("which are big?")
        #expect(FileManager.default.fileExists(atPath: file.path))
        chat.newChat()
        #expect(chat.recallOlder(than: "typing") == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(AskClaudeChat(historyURL: file).recallOlder(than: "") == nil)
        chat.rememberSent("open the receipts")
        #expect(AskClaudeChat(historyURL: file).recallOlder(than: "") == "open the receipts")
    }

    // MARK: Where the caret is

    /// A box three lines tall, in a window, so the text view lays out and answers `firstRect`.
    private func box(_ text: String) -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = text
        window.contentView = view
        return (window, view)
    }

    @Test func upAndDownRecallOnlyFromTheEdgeLines() {
        let (window, view) = box("first line\nmiddle line\nlast line")
        defer { window.close() }
        let length = (view.string as NSString).length

        view.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(AskClaudeComposerCaret.isOnEdgeLine(of: view, up: true))
        #expect(!AskClaudeComposerCaret.isOnEdgeLine(of: view, up: false))

        view.setSelectedRange(NSRange(location: 15, length: 0))
        #expect(!AskClaudeComposerCaret.isOnEdgeLine(of: view, up: true))
        #expect(!AskClaudeComposerCaret.isOnEdgeLine(of: view, up: false))

        view.setSelectedRange(NSRange(location: length - 2, length: 0))
        #expect(!AskClaudeComposerCaret.isOnEdgeLine(of: view, up: true))
        #expect(AskClaudeComposerCaret.isOnEdgeLine(of: view, up: false))
    }

    @Test func aOneLineQuestionRecallsBothWaysFromAnywhere() {
        let (window, view) = box("which are big?")
        defer { window.close() }
        view.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(AskClaudeComposerCaret.isOnEdgeLine(of: view, up: true))
        #expect(AskClaudeComposerCaret.isOnEdgeLine(of: view, up: false))
    }

    // MARK: Through the real box

    private func arrow(_ up: Bool, in window: NSWindow) -> NSEvent {
        let characters = up ? "\u{F700}" : "\u{F701}"
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: up ? 126 : 125)!
    }

    /// The panel in a window with its box in front, and a way to press an arrow in it.
    private final class Box {
        let window: NSWindow
        let host: NSHostingView<AskClaudePanel>
        let composer: NSTextField

        init(_ chat: AskClaudeChat) throws {
            let container = CGSize(width: 1000, height: 800)
            host = NSHostingView(rootView: AskClaudePanel(chat: chat, place: AskClaudePanelHandleTests.place, accent: .blue,
                                                          accentFill: .blue, onAccent: .white, onAsk: { _ in }, onClose: {},
                                                          onOpenSettings: {}, container: container,
                                                          settingsBridge: .keySaved))
            host.frame = NSRect(origin: .zero, size: container)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            func field(in view: NSView) -> NSTextField? { (view as? NSTextField) ?? view.subviews.lazy.compactMap(field).first }
            composer = try #require(field(in: host))
        }

        func settle() async {
            for _ in 0..<50 {
                await Task.yield()
                host.layoutSubtreeIfNeeded()
            }
        }

        /// The box, in front with its field editor and SwiftUI aware of it. The window can't be
        /// key, and SwiftUI then gives the focus up at its next reconcile whenever other suites'
        /// windows stir it, at any await; and it learns of a `makeFirstResponder` a turn late, so a
        /// key sent before then skips its handlers. So: focus, let it settle, and try again if it
        /// went. In the app the panel's window is key while he types, and the focus holds.
        /// A field taking focus selects all its text, so the caret is put back where it was.
        func editor() async throws -> NSTextView {
            for _ in 0..<20 {
                if let editor = window.firstResponder as? NSTextView { return editor }
                _ = window.makeFirstResponder(composer)
                await settle()
                if let editor = window.firstResponder as? NSTextView, let caret {
                    editor.setSelectedRange(NSRange(location: min(caret, (editor.string as NSString).length), length: 0))
                }
            }
            return try #require(window.firstResponder as? NSTextView)
        }
        private var caret: Int?

        /// What the box holds after the press, and where its caret is, read before any await: the
        /// handler writes both at once, and the focus could go at the next await.
        func press(_ up: Bool) async throws -> String {
            let editor = try await editor()
            let characters = up ? "\u{F700}" : "\u{F701}"
            window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: characters,
                                              charactersIgnoringModifiers: characters, isARepeat: false, keyCode: up ? 126 : 125)!)
            caret = editor.selectedRange().location
            let shown = "\(editor.string)@\(editor.selectedRange().location)"
            await settle()
            return shown
        }
    }

    /// The arrows reach the panel's handler past the field editor, which would otherwise take them
    /// as caret moves.
    @Test func theArrowsInThePanelsBoxRecallAndComeBackToTheDraft() async throws {
        let chat = AskClaudeChat(readKey: { nil })
        chat.rememberSent("which are big?")
        chat.rememberSent("open the receipts")
        let box = try Box(chat)
        defer { box.window.close() }
        await box.settle()
        let editor = try await box.editor()
        editor.insertText("half typed", replacementRange: editor.selectedRange())
        await box.settle()

        var shown: [String] = []
        for up in [true, true, false, false] { shown.append(try await box.press(up)) }
        #expect(shown == ["open the receipts@0", "which are big?@0", "open the receipts@17", "half typed@10"])
        #expect(chat.draft == "half typed")   // the binding heard it, so a closed panel brings it back
    }

    /// Up leaves the caret at a recalled question's start and Down at its end, so pressing on goes
    /// to the next question; turning back walks this one's lines first, as in any text.
    @Test func throughQuestionsOfSeveralLinesTheSameKeyGoesOn() async throws {
        let chat = AskClaudeChat(readKey: { nil })
        chat.rememberSent("one\ntwo\nthree")
        chat.rememberSent("alpha\nbeta")
        let box = try Box(chat)
        defer { box.window.close() }
        await box.settle()
        _ = try await box.editor()

        var shown: [String] = []
        for up in [true, true, false, false, false, false] { shown.append(try await box.press(up)) }
        #expect(shown == ["alpha\nbeta@0", "one\ntwo\nthree@0",
                          "one\ntwo\nthree@4", "one\ntwo\nthree@8",   // down its lines
                          "alpha\nbeta@10", "@0"])
    }
}
