import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SyncCloud

/// Up and Down in Ask Claude's box: the questions typed before, then back to the unsent draft.
@MainActor
@Suite struct AskClaudePromptHistoryTests {

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

    @Test func aSendStartsTheWalkAgainFromAnEmptyDraft() {
        var history = Self.history(["one", "two"])
        _ = history.older(than: "draft")
        history.record("three")
        #expect(history.position == nil)
        #expect(history.older(than: "") == "three")
        #expect(history.newer(than: "three") == "")
    }

    // MARK: The chat keeps it

    @Test func theChatKeepsTypedQuestionsAcrossLaunchesAndNewChat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AskClaudePromptHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prompts.json")
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

    /// The arrows reach the panel's handler past the field editor, which would otherwise take them
    /// as caret moves.
    @Test func theArrowsInThePanelsBoxRecallAndComeBackToTheDraft() async throws {
        let chat = AskClaudeChat(readKey: { nil })
        chat.rememberSent("which are big?")
        chat.rememberSent("open the receipts")
        let container = CGSize(width: 1000, height: 800)
        let panel = AskClaudePanel(chat: chat, place: AskClaudePanelHandleTests.place, accent: .blue, accentFill: .blue, onAccent: .white,
                                   onAsk: { _ in }, onClose: {}, onOpenSettings: {}, container: container)
        let host = NSHostingView(rootView: panel)
        host.frame = NSRect(origin: .zero, size: container)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func field(in view: NSView) -> NSTextField? { (view as? NSTextField) ?? view.subviews.lazy.compactMap(field).first }
        let composer = try #require(field(in: host))

        func settle() async {
            for _ in 0..<50 {
                await Task.yield()
                host.layoutSubtreeIfNeeded()
            }
        }
        // The box, in front with its field editor. A window that can't be key loses it when SwiftUI
        // next reconciles focus, which other suites' windows make happen at any await; in the app
        // the panel's window is key while he types, so it holds.
        func focusedEditor() async throws -> NSTextView {
            if let editor = window.firstResponder as? NSTextView { return editor }
            #expect(window.makeFirstResponder(composer))
            await settle()
            return try #require(window.firstResponder as? NSTextView)
        }
        await settle()
        let editor = try await focusedEditor()
        editor.insertText("half typed", replacementRange: editor.selectedRange())
        await settle()

        func press(_ up: Bool) async throws -> String {
            _ = try await focusedEditor()
            window.sendEvent(arrow(up, in: window))
            await settle()
            return composer.stringValue
        }
        var shown: [String] = []
        for up in [true, true, false, false] { shown.append(try await press(up)) }
        #expect(shown == ["open the receipts", "which are big?", "open the receipts", "half typed"])
        withExtendedLifetime(window) {}
    }
}
