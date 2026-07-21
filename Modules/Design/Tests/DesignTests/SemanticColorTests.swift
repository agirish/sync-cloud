import SwiftUI
import Testing
@testable import Design

/// Pins the semantic color table (C3). These assignments are a design contract — Sync History
/// once painted move = orange (colliding with warning) and copy = accent, which is exactly the
/// drift this table exists to prevent. A hue change here restyles every meaning-colored view
/// in the app, so it should have to touch this test.
@Suite struct SemanticColorTests {

    @Test func semanticTableIsPinned() {
        #expect(SemanticColor.success == .green)
        #expect(SemanticColor.info == .blue)
        #expect(SemanticColor.warning == .orange)
        // The judgment tier: softer than warning, never the same hue as it.
        #expect(SemanticColor.caution == .yellow)
        #expect(SemanticColor.error == .red)
        // Deliberately its own hue: distinct from warning-orange AND from the app accent.
        #expect(SemanticColor.move == .purple)
    }

    @Test func meaningsNeverShareAColor() {
        let table = [SemanticColor.success, SemanticColor.info, SemanticColor.warning,
                     SemanticColor.caution, SemanticColor.error, SemanticColor.move]
        for (i, a) in table.enumerated() {
            for b in table.dropFirst(i + 1) {
                #expect(a != b)
            }
        }
    }
}
