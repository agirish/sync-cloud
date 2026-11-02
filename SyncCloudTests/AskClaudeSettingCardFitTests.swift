import AppKit
import Foundation
import SwiftUI
import Testing
import Design
import Settings
import Sync
@testable import SyncCloud

/// TE290 step 4a: a settings card fits the panel at its narrowest. Inside a card at a 300 pt panel
/// there are 256 pt, and about 240 pt when macOS shows scroll bars all the time.
@MainActor
@Suite struct AskClaudeSettingCardFitTests {

    /// The width the card asks for when offered 240 pt, each layout measured on its own.
    private func fittingWidth(_ card: AskClaudeSettingCard, values: [String: SettingValue] = [:]) -> CGFloat {
        let bridge = AskClaudeSettingsBridge(read: { entry, _ in values[entry.id] ?? entry.defaultValue })
        // No frame of its own: a control too wide for the offer makes the card report its width.
        let view = AskClaudeSettingCardView(itemID: UUID(), card: card, bridge: bridge, accent: .blue, hue: .blue)
        let host = NSHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 240, height: 2_000)).width
    }

    @Test(arguments: [
        "intelligence.monthlyLimit",      // six-item menu and a Use button
        "intelligence.askClaudeModel",    // the longest menu labels
        "sync.whenFileExists",
        "appearance.theme",               // segmented, three
        "readability.columnWidths",       // segmented, two long labels
        "readability.textSize",           // stepper beside the name
        "sync.confirmTransfer",           // switch beside the name, long help text
        "appearance.tint",                // slider
        "appearance.accent",              // twelve swatches, a suggestion ringed
    ])
    func everyKindOfCardFits240(id: String) throws {
        let entry = try #require(SettingsCatalog.entry(id))
        let pick: String? = switch entry.control {
        case .menu(let choices), .segmented(let choices), .swatches(let choices): choices.last?.value.stored
        default: nil
        }
        let card = AskClaudeSettingCard(rows: [.init(id: id, pick: pick)])
        // Every choice as the current value: the widest one on show is the case that matters.
        let currents: [SettingValue?] = switch entry.control {
        case .menu(let choices), .segmented(let choices), .swatches(let choices): choices.map(\.value)
        default: [nil]
        }
        for current in currents {
            let values = current.map { [id: $0] } ?? [:]
            #expect(fittingWidth(card, values: values) <= 240, "\(id) at \(current?.stored ?? "its default") asks for more than 240 pt")
        }
    }

    /// TE290 step 4c: Claude's own change says so, with the longest "was" and a raising Undo.
    @Test(arguments: [
        ("intelligence.monthlyLimit", "0.0", SettingValue.double(5)),
        ("intelligence.readsFiles", "true", SettingValue.bool(false)),
        ("readability.columnWidths", "each", SettingValue.string("all")),
        // Two badges on their own line: ↑ Raises and Next launch.
        ("general.showHiddenByDefault", "false", SettingValue.bool(true)),
    ])
    func aChangeClaudeMadeFits240(id: String, was: String, now: SettingValue) {
        let card = AskClaudeSettingCard(rows: [.init(id: id, changedFrom: was, byClaude: true)])
        let bridge = AskClaudeSettingsBridge(read: { entry, _ in entry.id == id ? now : entry.defaultValue },
                                             offersUndo: { _, _ in true })
        let host = NSHostingController(rootView: AskClaudeSettingCardView(itemID: UUID(), card: card, bridge: bridge,
                                                                          accent: .blue, hue: .blue))
        #expect(host.sizeThatFits(in: CGSize(width: 240, height: 2_000)).width <= 240)
    }

    /// TE290 step 6: the at-limit card, raised, with Ask Again and its badge line.
    @Test func theAtLimitCardFits240() {
        var card = AskClaudeSettingCard.atLimit(spent: 25.4, limit: 25, resets: Date(), question: "which folders changed most?")
        card.rows[0].changedFrom = "25.0"
        let bridge = AskClaudeSettingsBridge(read: { entry, _ in entry.id == "intelligence.monthlyLimit" ? .double(100) : entry.defaultValue },
                                             offersUndo: { _, _ in true }, canAskAgain: { true })
        let host = NSHostingController(rootView: AskClaudeSettingCardView(itemID: UUID(), card: card, bridge: bridge,
                                                                          accent: .blue, hue: .blue))
        #expect(host.sizeThatFits(in: CGSize(width: 240, height: 2_000)).width <= 240)
    }

    /// TE290 step 7: the API key card, with a key saved, and a caught message with its buttons.
    @Test(arguments: [false, true])
    func theKeyCardsFit240(caught: Bool) {
        let message = "here’s my new key sk-ant-api03-" + String(repeating: "x", count: 30) + " for Refine and Ask Claude both"
        let card = caught ? AskClaudeSettingCard.caughtKey(in: message) : AskClaudeSettingCard(rows: [.init(id: "intelligence.apiKey")])
        let bridge = AskClaudeSettingsBridge(keyIsSaved: { true }, hasCaughtKey: { _ in caught })
        let host = NSHostingController(rootView: AskClaudeSettingCardView(itemID: UUID(), card: card, bridge: bridge,
                                                                          accent: .blue, hue: .blue))
        #expect(host.sizeThatFits(in: CGSize(width: 240, height: 2_000)).width <= 240)
    }

    @Test func aCardOfSeveralWithATitleFits240() {
        let card = AskClaudeSettingCard(title: "Hide Identical Files in Compare", rows: [
            .init(id: "sync.verifySameSize", pick: "true"),
            .init(id: "sync.dateTolerance", pick: "2.0", changedFrom: "1.0"),
        ])
        #expect(fittingWidth(card, values: ["sync.dateTolerance": .double(2)]) <= 240)
    }

    /// Accent color's choices are every hue, so its card draws the swatch grid; a swatch choice
    /// that isn't a hue turns the row back into a menu rather than losing the choice.
    @Test func accentDrawsSwatchesAndAnUnknownChoiceFallsBackToAMenu() throws {
        let entry = try #require(SettingsCatalog.entry("appearance.accent"))
        guard case .swatches(let choices) = entry.control else {
            Issue.record("Accent color is no longer swatches")
            return
        }
        #expect(AskClaudeSettingCardView.hues(choices) == LiquidGlassHue.allCases)
        #expect(AskClaudeSettingCardView.hues(choices + [SettingChoice(.string("chartreuse"), "Chartreuse")]) == nil)
    }
}
