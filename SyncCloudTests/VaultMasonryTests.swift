import CoreGraphics
import Testing
@testable import SyncCloud

/// The Vault's cards packed into columns, each under the shortest so far.
@Suite struct VaultMasonryTests {
    let layout = VaultMasonry(minColumnWidth: 270, spacing: 12)

    @Test func asManyColumnsAsFitSharingTheWidth() {
        #expect(layout.columns(for: 300).count == 1)
        #expect(layout.columns(for: 552).count == 2, "two at exactly 270 each and the gap")
        let three = layout.columns(for: 900)
        #expect(three.count == 3 && abs(three.width - 292) < 0.001)
    }

    /// SwiftUI asks a scroll view's content for its size with no bound on the width; that once
    /// trapped, converting infinity to a column count, the moment the Vault opened.
    @Test func aWidthWithoutBoundIsOneColumn() {
        #expect(layout.columns(for: .infinity) == (1, 270))
        #expect(layout.columns(for: .nan) == (1, 270))
        #expect(layout.columns(for: 0) == (1, 270))
        #expect(layout.placements(width: .infinity, heights: [100, 50]).origins.map(\.x) == [0, 0])
    }

    @Test func eachCardGoesUnderTheShortestColumnLeavingNoGap() {
        // Passports (tall), I-94 (short), Cases (medium), then licenses: under the short I-94s,
        // not on a new row below the tallest card as a grid would.
        let (origins, height) = layout.placements(width: 900, heights: [600, 200, 400, 150, 100])
        let columnX = origins.map(\.x)
        #expect(columnX[0] == 0 && columnX[1] == 304 && columnX[2] == 608, "the first row left to right")
        #expect(origins[3] == CGPoint(x: 304, y: 212), "under the shortest, the I-94s")
        #expect(origins[4] == CGPoint(x: 304, y: 374), "still the shortest after it")
        #expect(height == 600)
    }

    @Test func aTieGoesToTheLeftmostAndOneColumnStacksInOrder() {
        let (origins, height) = layout.placements(width: 300, heights: [100, 50, 70])
        #expect(origins.map(\.y) == [0, 112, 174])
        #expect(height == 244)
        #expect(layout.placements(width: 900, heights: []).height == 0)
        let tie = layout.placements(width: 552, heights: [100, 100, 10]).origins
        #expect(tie[2].x == 0, "both columns as tall: the left one")
    }
}
