import AppKit
import Foundation
import Testing
import Settings
import Sync
@testable import SyncCloud

/// TE290 step 4b: the chat's undo of settings changes, and the panel window sending Edit ▸ Undo
/// to it.
@MainActor
@Suite struct AskClaudeSettingsUndoTests {

    /// An in-memory store the stack reads and writes, so nothing touches his preferences.
    private final class Store {
        var values: [String: SettingValue] = [:]
    }

    private func stack(_ store: Store) -> AskClaudeSettingsUndo {
        let undo = AskClaudeSettingsUndo()
        undo.read = { store.values[$0.id] }
        undo.write = { key, value in store.values[key.id] = value; return true }
        return undo
    }

    /// A card's change, as the app records it: written, then stepped.
    private func change(_ undo: AskClaudeSettingsUndo, _ store: Store, card: UUID = UUID(), _ id: String,
                        to value: SettingValue, name: String, cardOnly: Bool = false) -> UUID {
        let key = AskClaudeSettingsLedger.Key(id: id, target: nil)
        let before = store.values[id]!
        store.values[id] = value
        undo.record(AskClaudeSettingsStep(card: card, rows: [0], changes: [.init(key: key, before: before, after: value,
                                                                                token: undo.token(key))],
                                          name: name, cardOnly: cardOnly))
        return card
    }

    @Test func undoPutsTheValueBackAndRedoReappliesIt() {
        let store = Store(); store.values["appearance.theme"] = .string("system")
        let undo = stack(store)
        _ = change(undo, store, "appearance.theme", to: .string("dark"), name: "Theme")

        #expect(undo.undoTitle == "Undo Theme")
        undo.undo()
        #expect(store.values["appearance.theme"] == .string("system"))
        #expect(undo.redoTitle == "Redo Theme")
        undo.redo()
        #expect(store.values["appearance.theme"] == .string("dark"))
        #expect(undo.canUndo)
    }

    @Test func anUndoNeverOverwritesALaterChange() {
        let store = Store(); store.values["appearance.theme"] = .string("system")
        let undo = stack(store)
        let card = change(undo, store, "appearance.theme", to: .string("dark"), name: "Theme")
        #expect(undo.offersUndo(card, row: 0))

        // Settings, the View menu or another card changes it after this card did.
        store.values["appearance.theme"] = .string("light")

        #expect(!undo.offersUndo(card, row: 0))
        #expect(!undo.canUndo)
        undo.undo()
        undo.undoCard(card, row: 0)
        #expect(store.values["appearance.theme"] == .string("light"))
    }

    @Test func editUndoPassesOverAStepOnlyItsCardTakesBack() {
        let store = Store()
        store.values["appearance.theme"] = .string("system")
        store.values["intelligence.readsFiles"] = .bool(true)
        let undo = stack(store)
        _ = change(undo, store, "appearance.theme", to: .string("dark"), name: "Theme")
        // Claude turned reading off; undoing that would turn it back on.
        let reading = change(undo, store, "intelligence.readsFiles", to: .bool(false), name: "Let Claude read files", cardOnly: true)

        #expect(undo.undoTitle == "Undo Theme")
        undo.undo()
        #expect(store.values["appearance.theme"] == .string("system"))
        #expect(store.values["intelligence.readsFiles"] == .bool(false))

        undo.undoCard(reading, row: 0)
        #expect(store.values["intelligence.readsFiles"] == .bool(true))
    }

    @Test func newChatClearsTheStepsAndKeepsTheChanges() {
        let d = UserDefaults(suiteName: "AskClaudeSettingsUndoTests.newChat")!
        defer { wipeDefaultsSuite("AskClaudeSettingsUndoTests.newChat") }
        let chat = AskClaudeChat(defaults: d, readKey: { "k" })
        let store = Store(); store.values["appearance.theme"] = .string("system")
        chat.settingsUndo.read = { store.values[$0.id] }
        chat.settingsUndo.write = { key, value in store.values[key.id] = value; return true }
        _ = change(chat.settingsUndo, store, "appearance.theme", to: .string("dark"), name: "Theme")

        chat.startOver()

        #expect(!chat.settingsUndo.canUndo)
        #expect(store.values["appearance.theme"] == .string("dark"))
    }

    @Test func thePanelSendsEditUndoToTheSettingsWhenNoDraftIsTyped() {
        let store = Store(); store.values["appearance.theme"] = .string("system")
        let undo = stack(store)
        _ = change(undo, store, "appearance.theme", to: .string("dark"), name: "Theme")
        let saved = AskClaudePanelWindow.settingsUndo
        AskClaudePanelWindow.settingsUndo = { undo }
        defer { AskClaudePanelWindow.settingsUndo = saved }
        let window = AskClaudePanelWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                                          styleMask: [.borderless], backing: .buffered, defer: true)

        let item = NSMenuItem(title: "Undo", action: #selector(AskClaudePanelWindow.undo(_:)), keyEquivalent: "z")
        #expect(window.validateUserInterfaceItem(item))
        #expect(item.title == "Undo Theme")
        window.undo(nil)
        #expect(store.values["appearance.theme"] == .string("system"))

        let redo = NSMenuItem(title: "Redo", action: #selector(AskClaudePanelWindow.redo(_:)), keyEquivalent: "Z")
        #expect(window.validateUserInterfaceItem(redo))
        #expect(redo.title == "Redo Theme")
    }
}
