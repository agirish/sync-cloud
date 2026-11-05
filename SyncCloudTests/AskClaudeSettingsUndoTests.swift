import AppKit
import Foundation
import Testing
import Settings
import Sync
@testable import SyncCloud

/// The chat's undo of settings changes, and the panel window sending Edit ▸ Undo to it.
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

    /// Claude's own change goes on the stack as a click's would, once its card is in the chat. Its
    /// tightening comes back only by the card's Undo: that would raise again.
    @Test func claudesOwnChangesAreUndoneLikeAClicks() {
        let store = Store()
        store.values["appearance.theme"] = .string("dark")
        store.values["intelligence.readsFiles"] = .bool(false)
        let undo = stack(store)
        let card = UUID()
        undo.recordClaude([.init(id: "appearance.theme", changedFrom: "system", byClaude: true),
                           .init(id: "intelligence.readsFiles", changedFrom: "true", byClaude: true),
                           .init(id: "sync.confirmTransfer", changedFrom: "true")], card: card)

        #expect(undo.offersUndo(card, row: 0) && undo.offersUndo(card, row: 1))
        #expect(!undo.offersUndo(card, row: 2))
        #expect(undo.undoTitle == "Undo Theme")
        undo.undo()
        #expect(store.values["appearance.theme"] == .string("system"))
        #expect(!undo.canUndo)
        undo.undoCard(card, row: 1)
        #expect(store.values["intelligence.readsFiles"] == .bool(true))
    }

    /// A write that lands only once the sources are rediscovered: once the undone value is there,
    /// `resettle` lets Redo take it again.
    @Test func aWriteThatLandsLaterIsUndoneOnceItHas() {
        let store = Store()
        store.values["sources.name"] = .string("Dropbox (Work)")
        var landed: [String: SettingValue] = [:]
        let undo = AskClaudeSettingsUndo()
        undo.read = { store.values[$0.id] }
        // Each write waits for "discovery" to land.
        undo.write = { key, value in landed[key.id] = value; return true }
        let card = UUID()
        let key = AskClaudeSettingsLedger.Key(id: "sources.name", target: nil)
        undo.record(AskClaudeSettingsStep(card: card, rows: [0],
                                          changes: [.init(key: key, before: .string("Dropbox"), after: .string("Dropbox (Work)"),
                                                          token: undo.token(key))], name: "Source name", cardOnly: false))
        undo.undoCard(card, row: 0)
        #expect(landed["sources.name"] == .string("Dropbox"))
        // Discovery lands the undo: without resettling, the step's token names the old value and
        // Redo is lost.
        store.values["sources.name"] = .string("Dropbox")
        #expect(!undo.canRedo)
        undo.resettle(key)
        #expect(undo.redoTitle == "Redo Source name")
    }

    /// Two changes to one setting on one card, then Undo twice, walks back to the first value: the
    /// value an Undo puts back carries the token the earlier step holds.
    @Test func undoTwiceOnOneSettingWalksBackToTheStart() {
        let store = Store(); store.values["appearance.theme"] = .string("system")
        let undo = stack(store)
        let card = change(undo, store, "appearance.theme", to: .string("light"), name: "Theme")
        _ = change(undo, store, card: card, "appearance.theme", to: .string("dark"), name: "Theme")
        undo.undoCard(card, row: 0)
        #expect(store.values["appearance.theme"] == .string("light"))
        #expect(undo.offersUndo(card, row: 0))
        undo.undo()
        #expect(store.values["appearance.theme"] == .string("system"))
    }

    /// A redo that would raise Claude's access waits for a click, as an undo that would does.
    @Test func aRedoThatRaisesIsntOnTheMenu() {
        let store = Store(); store.values["intelligence.readsFiles"] = .bool(false)
        let undo = stack(store)
        let key = AskClaudeSettingsLedger.Key(id: "intelligence.readsFiles", target: nil)
        store.values["intelligence.readsFiles"] = .bool(true)
        var step = AskClaudeSettingsStep(card: UUID(), rows: [0], changes: [.init(key: key, before: .bool(false), after: .bool(true),
                                                                                  token: undo.token(key))],
                                         name: "Let Claude read files", cardOnly: false)
        step.redoRaises = true
        undo.record(step)
        undo.undo()
        #expect(store.values["intelligence.readsFiles"] == .bool(false))
        #expect(!undo.canRedo)
        undo.redo()
        #expect(store.values["intelligence.readsFiles"] == .bool(false))
    }

    /// An undo whose write is refused keeps its step and says so, rather than losing both.
    @Test func aRefusedUndoKeepsItsStep() {
        let store = Store(); store.values["sources.path"] = .string("/Old")
        let undo = stack(store)
        var refused = 0
        undo.didRefuse = { _ in refused += 1 }
        let card = change(undo, store, "sources.path", to: .string("/New"), name: "Synchronized path")
        undo.write = { _, _ in false }
        undo.undoCard(card, row: 0)
        #expect(refused == 1)
        #expect(undo.offersUndo(card, row: 0))
        #expect(store.values["sources.path"] == .string("/New"))
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
