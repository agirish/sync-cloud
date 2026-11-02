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
    ])
    func everyKindOfCardFits240(id: String) throws {
        let entry = try #require(SettingsCatalog.entry(id))
        let pick: String? = switch entry.control {
        case .menu(let choices), .segmented(let choices): choices.last?.value.stored
        default: nil
        }
        let card = AskClaudeSettingCard(rows: [.init(id: id, pick: pick)])
        // Every choice as the current value: the widest one on show is the case that matters.
        let currents: [SettingValue?] = switch entry.control {
        case .menu(let choices), .segmented(let choices): choices.map(\.value)
        default: [nil]
        }
        for current in currents {
            let values = current.map { [id: $0] } ?? [:]
            #expect(fittingWidth(card, values: values) <= 240, "\(id) at \(current?.stored ?? "its default") asks for more than 240 pt")
        }
    }

    @Test func aCardOfSeveralWithATitleFits240() {
        let card = AskClaudeSettingCard(title: "Hide Identical Files in Compare", rows: [
            .init(id: "sync.verifySameSize", pick: "true"),
            .init(id: "sync.dateTolerance", pick: "2.0", changedFrom: "1.0"),
        ])
        #expect(fittingWidth(card, values: ["sync.dateTolerance": .double(2)]) <= 240)
    }
}
