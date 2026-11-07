import AppKit
import SwiftUI
import Testing
import Design
import Sync
@testable import FileExplorer

/// The card's action row shrinks for a narrow workspace: every button when there is room, and File
/// Here and Choose a Folder… with the rest in ⋯ below it. The pinned Ask Claude column leaves To
/// File anywhere from 340 to 640 pt.
@MainActor
@Suite struct FilingCardActionsTests {

    private func card() -> FilingSuggestionCard {
        let suggestion = FilingSuggestion(
            filePath: "/root/Inbox/Invoice 2026-04.pdf", fileName: "Invoice 2026-04.pdf",
            size: 4096, modificationDate: nil,
            candidates: [FilingDestination(path: "/root/Receipts/2026", confidence: .high,
                                           reasons: ["Receipt, filed by year"], newSegments: [])],
            providerRoot: "/root")
        return FilingSuggestionCard(
            suggestion: suggestion, densityMetrics: ListDensity.comfortable.metrics,
            onFileHere: { _ in }, onChooseFolder: {}, onReveal: {}, onNotHere: {},
            onPreview: {}, onTryAnother: {}, onReadScan: {})
    }

    /// The width a row takes unconstrained.
    private func natural(_ row: some View) -> CGFloat {
        NSHostingView(rootView: row.fixedSize()).fittingSize.width
    }

    @Test func theFullRowIsWiderThanTheCompactRow() {
        let c = card()
        let full = natural(c.actionRow(compact: false))
        let compact = natural(c.actionRow(compact: true))
        #expect(compact < full, "compact \(compact) is not narrower than full \(full)")
    }

    /// The compact row has to fit the narrowest workspace: 340 pt less the card's own insets, with
    /// the file icon's column beside it. The width itself is printed in the failure.
    @Test func theCompactRowFitsTheNarrowestWorkspace() {
        let compact = natural(card().actionRow(compact: true))
        #expect(compact <= 300, "the compact row takes \(compact) pt")
    }
}
