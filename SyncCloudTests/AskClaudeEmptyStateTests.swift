import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// An empty chat: set up first with no API key saved, and a few questions that fit the screen once
/// one is. The key is asked about through the bridge, never read, and never touched here: these
/// panels are given a key state of their own.
///
/// Serialized: panels hosted side by side take the keyboard focus from each other.
@MainActor
@Suite(.serialized) struct AskClaudeEmptyStateTests {

    /// Set from the test; the panel asks it as it would ask the Keychain.
    final class KeyState { var saved: Bool; init(_ saved: Bool) { self.saved = saved } }

    private static let place = AskClaudePlace(source: "iCloud", folder: "Documents/Taxes", itemCount: 4, isHidden: false,
                                              isOnScreen: true, workspace: "Browse", openFile: nil)

    private func host(_ key: KeyState, chat: AskClaudeChat? = nil,
                      onAsk: @escaping (String) -> Void = { _ in },
                      saveSetupKey: @escaping (String) -> String? = { _ in nil }) -> (NSWindow, NSView) {
        let chat = chat ?? AskClaudeChat(defaults: ScratchDefaults("AskClaudePanelTests"), readKey: { nil })
        var bridge = AskClaudeSettingsBridge()
        bridge.keyIsSaved = { key.saved }
        bridge.saveSetupKey = saveSetupKey
        let rig = AskClaudePanelRig(chat: chat, bridge: bridge, place: Self.place, onAsk: onAsk,
                                    topLeading: true, panelWindow: true)
        return (rig.window, rig.host)
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? views(type, in: $0) }
    }

    private func keyFields(in view: NSView) -> [NSSecureTextField] { views(NSSecureTextField.self, in: view) }

    /// Clicks down the thread's left side, as a person would, until something is sent: the first
    /// starter, since nothing above it sends. SwiftUI's bordered buttons are no `NSButton`s here,
    /// so a click is the only way to find one. Stops above the composer, whose Send would send
    /// the draft. Never run over the setup, whose Console link would open the browser.
    private func clickFirstStarter(_ window: NSWindow, _ host: NSView, sent: () -> Bool) async -> Bool {
        // Ordered in, never made key: a key window here takes key from other suites' panels,
        // and ⌘K's palette closes when it loses key (`CommandPalettePanelTests`).
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for y in stride(from: 60.0, through: 320.0, by: 4) {
            let point = NSPoint(x: 60, y: host.bounds.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(10))
            if sent() { return true }
        }
        return false
    }

    /// Lets the panel's appear and its notification land, then lays it out again.
    private func settle(_ host: NSView) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(10))
            host.layoutSubtreeIfNeeded()
        }
    }

    @Test func withNoKeyTheEmptyPanelSetsUpWithTheKeyCard() async throws {
        let (window, host) = host(KeyState(false))
        await settle(host)
        #expect(keyFields(in: host).count == 1, "the setup's API key field")
        // The box stays usable: its own field is still there beside the key's.
        #expect(views(NSTextField.self, in: host).contains { !($0 is NSSecureTextField) && $0.isEditable })
        _ = window
    }

    /// A save macOS refuses keeps the setup up and says why on its card. The key typed goes to
    /// the save and nowhere else. The panel's height is the test host's saved one, so the reason
    /// is found by drawing: before typing and after the save, with the caret in the field both
    /// times, only the reason's line differs (and at most a caret blink).
    @Test func aRefusedSaveKeepsTheSetupAndSaysWhy() async throws {
        var saved: [String] = []
        let (window, host) = host(KeyState(false),
                                  saveSetupKey: { saved.append($0); return "Couldn’t save the key: macOS refused it (status -25308). The old key stays." })
        // Never ordered in or made key: typing and Return reach a field in a window that isn't.
        await settle(host)
        let field = try #require(keyFields(in: host).first)
        var editor: NSTextView?
        for _ in 0..<20 where editor == nil {
            _ = window.makeFirstResponder(field)
            await settle(host)
            editor = window.firstResponder as? NSTextView
        }
        let typing = try #require(editor, "the key field never took the caret")
        let before = try snapshot(host)
        typing.insertText("sk-ant-api03-refused", replacementRange: typing.selectedRange())
        await settle(host)
        window.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                       charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        await settle(host)
        #expect(saved == ["sk-ant-api03-refused"])
        #expect(keyFields(in: host).count == 1, "the setup gave way after a refused save")
        let changed = differingPixels(before, try snapshot(host))
        #expect(changed > 300, "no reason appeared on the card: \(changed) pixels changed")
    }

    /// Saved anywhere (the setup's card, Settings), the Keychain announces it and the setup gives
    /// way to the starters; a key removed brings it back.
    @Test func aKeySavedGivesWayToTheStartersAndOneRemovedBringsTheSetupBack() async throws {
        let key = KeyState(false)
        var asked: [String] = []
        let (window, host) = host(key, onAsk: { asked.append($0) })
        await settle(host)
        try #require(keyFields(in: host).count == 1)
        key.saved = true
        NotificationCenter.default.post(name: AnthropicKeychain.didChange, object: nil)
        await settle(host)
        #expect(keyFields(in: host).isEmpty)
        #expect(await clickFirstStarter(window, host) { !asked.isEmpty }, "no starter took a click")
        key.saved = false
        NotificationCenter.default.post(name: AnthropicKeychain.didChange, object: nil)
        await settle(host)
        #expect(keyFields(in: host).count == 1)
    }

    /// A click sends the question as typed: to the same send, into the remembered questions, and
    /// what's being typed stays in the box.
    @Test func aStarterSendsItsQuestionExactlyAsTyped() async throws {
        let chat = AskClaudeChat(defaults: ScratchDefaults("AskClaudePanelTests"), readKey: { nil })
        chat.draft = "half a question"
        var asked: [String] = []
        let (window, host) = host(KeyState(true), chat: chat, onAsk: { asked.append($0) })
        await settle(host)
        #expect(keyFields(in: host).isEmpty)
        try #require(await clickFirstStarter(window, host) { !asked.isEmpty }, "no starter took a click")
        #expect(asked == [AskClaudeStarters.questions(for: Self.place.starterScreen)[0]])
        #expect(chat.recallOlder(than: "") == asked.first)
        #expect(chat.draft == "half a question")
    }
}

extension AskClaudeSettingsBridge {
    /// For a panel test about something other than the first run: a key is saved, so the empty
    /// chat shows its opening note and starters rather than the setup.
    static var keySaved: Self {
        var bridge = Self()
        bridge.keyIsSaved = { true }
        return bridge
    }
}
