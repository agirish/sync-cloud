import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

@Suite struct DifferenceGlyphTests {

    private static let allTypes: [FileDifference.DifferenceType] = [
        .missingOnRight, .missingOnLeft, .differentDates, .nameConflict,
    ]

    @Test func testDirectionIsEncodedInShapeNotJustColor() {
        // Both surfaces must stay distinguishable without color (colorblind users).
        #expect(DifferenceGlyph.symbol(for: .missingOnRight, filled: true) == "arrow.right.circle.fill")
        #expect(DifferenceGlyph.symbol(for: .missingOnLeft, filled: true) == "arrow.left.circle.fill")
        #expect(DifferenceGlyph.symbol(for: .differentDates, filled: true) == "arrow.triangle.2.circlepath")

        #expect(DifferenceGlyph.symbol(for: .missingOnRight, filled: false) == "arrow.right.circle")
        #expect(DifferenceGlyph.symbol(for: .missingOnLeft, filled: false) == "arrow.left.circle")
        #expect(DifferenceGlyph.symbol(for: .differentDates, filled: false) == "arrow.triangle.2.circlepath")

        #expect(DifferenceGlyph.symbol(for: .nameConflict, filled: true) == "exclamationmark.triangle.fill")
        #expect(DifferenceGlyph.symbol(for: .nameConflict, filled: false) == "exclamationmark.triangle")

        #expect(DifferenceGlyph.color(for: .missingOnRight) == .blue)
        #expect(DifferenceGlyph.color(for: .missingOnLeft) == .purple)
        #expect(DifferenceGlyph.color(for: .differentDates) == .orange)
        #expect(DifferenceGlyph.color(for: .nameConflict) == .yellow)

        // The direction tints (fed into color(for:) above) must match the badge colors.
        #expect(DifferenceGlyph.color(toRight: true) == .blue)
        #expect(DifferenceGlyph.color(toRight: false) == .purple)
    }

    @Test func testSymbolNamesExistInSFSymbols() {
        // A typo'd symbol name renders as a blank icon at runtime; pin that every name resolves.
        for type in Self.allTypes {
            for filled in [true, false] {
                let symbol = DifferenceGlyph.symbol(for: type, filled: filled)
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                        "missing SF Symbol \(symbol)")
            }
        }
    }
}
