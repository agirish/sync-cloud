import Testing
import Foundation
@testable import Design

/// Pins the list-density setting (H7): the stored key, the two values, and — most importantly —
/// that Comfortable's metrics equal the app's pre-H7 constants, so the default look is
/// unchanged by construction and only Compact opts into tighter rows.
@Suite struct ListDensityTests {

    // MARK: Stored format

    @Test func defaultsKeyIsStable() {
        // The key is persisted in UserDefaults; changing it silently resets everyone to
        // Comfortable. Treat it as a stable format.
        #expect(ListDensity.defaultsKey == "listDensity")
    }

    @Test func rawValuesAreStable() {
        #expect(ListDensity.comfortable.rawValue == "comfortable")
        #expect(ListDensity.compact.rawValue == "compact")
        #expect(ListDensity.allCases == [.comfortable, .compact])
    }

    @Test func unknownRawValueFailsSoItCanFallBackToComfortable() {
        // Call sites decode with `ListDensity(rawValue:) ?? .comfortable`; a garbage stored
        // value must produce nil, not trap or match.
        #expect(ListDensity(rawValue: "cozy") == nil)
    }

    @Test func displayNamesAreSentenceCase() {
        #expect(ListDensity.comfortable.displayName == "Comfortable")
        #expect(ListDensity.compact.displayName == "Compact")
    }

    // MARK: Metrics

    @Test func comfortableMetricsMatchThePreH7Constants() {
        // These are the literals the views used before the setting existed (Tidy header 12,
        // copy rows 11, card lists spacing 10 / padding 12, no table row-height override,
        // secondary detail shown). Comfortable must stay pixel-identical to that look.
        let m = ListDensity.comfortable.metrics
        #expect(m.cardHeaderVerticalPadding == 12)
        #expect(m.cardRowVerticalPadding == 11)
        #expect(m.cardListSpacing == 10)
        #expect(m.cardListPadding == 12)
        #expect(m.tableMinRowHeight == nil)
        #expect(m.showsSecondaryDetail)
    }

    @Test func comfortableFlatRowMetricsMatchThePreDensityConstants() {
        // These are the literals the flat lists used before density reached them (file rows /
        // log rows / history rows padding 6, file-row icon 17, log-window LazyVStack spacing 6).
        // Comfortable must stay pixel-identical to that look.
        let m = ListDensity.comfortable.metrics
        #expect(m.flatRowVerticalPadding == 6)
        #expect(m.treeIconSize == 17)
        #expect(m.logListSpacing == 6)
    }

    @Test func compactFlatRowMetricsArePinned() {
        // Pinned, not just "smaller": these numbers are the compact design (row padding 2,
        // icon 14, log spacing 2) — a drive-by tweak should have to touch this test.
        let m = ListDensity.compact.metrics
        #expect(m.flatRowVerticalPadding == 2)
        #expect(m.treeIconSize == 14)
        #expect(m.logListSpacing == 2)
    }

    @Test func compactIsStrictlyTighterThanComfortable() {
        let compact = ListDensity.compact.metrics
        let comfortable = ListDensity.comfortable.metrics
        #expect(compact.cardHeaderVerticalPadding < comfortable.cardHeaderVerticalPadding)
        #expect(compact.cardRowVerticalPadding < comfortable.cardRowVerticalPadding)
        #expect(compact.cardListSpacing < comfortable.cardListSpacing)
        #expect(compact.cardListPadding < comfortable.cardListPadding)
        #expect(compact.tableMinRowHeight != nil)
        #expect(!compact.showsSecondaryDetail)
        #expect(compact.flatRowVerticalPadding < comfortable.flatRowVerticalPadding)
        #expect(compact.treeIconSize < comfortable.treeIconSize)
        #expect(compact.logListSpacing < comfortable.logListSpacing)
    }

    @Test func compactPaddingsStayUsable() {
        // Compact is tighter, not degenerate: rows keep a little breathing room and the
        // table override stays a plausible row height.
        let m = ListDensity.compact.metrics
        #expect(m.cardHeaderVerticalPadding >= 4)
        #expect(m.cardRowVerticalPadding >= 4)
        #expect((m.tableMinRowHeight ?? 0) >= 16)
    }
}
