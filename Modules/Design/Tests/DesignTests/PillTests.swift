import Testing
import Foundation
@testable import Design

/// Pins the two pill geometries (C1). Call sites across FileExplorer/Dashboard build on these
/// constants; a drive-by tweak here silently restyles every badge in the app, so treat the
/// numbers as a stable design contract.
@Suite struct PillTests {

    @Test func standardGeometryMatchesTheStatPillSpec() {
        let v = PillVariant.standard
        #expect(v.horizontalPadding == 10)
        #expect(v.verticalPadding == 4)
        #expect(v.hasStroke)
    }

    @Test func miniGeometryIsTheInlineBadgeSpec() {
        let v = PillVariant.mini
        #expect(v.horizontalPadding == 8)
        #expect(v.verticalPadding == 2)
        #expect(!v.hasStroke)
    }

    @Test func sharedSurfaceConstantsAreStable() {
        #expect(PillVariant.fillOpacity == 0.14)
        #expect(PillVariant.strokeOpacity == 0.45)
        #expect(PillVariant.strokeWidth == 0.5)
        // The icon/number/label gap — the exact number whose unpinned change once forced a
        // snapshot re-record. Hand-assembled mirrors (the Log level chips) bake it in too.
        #expect(Pill.contentSpacing == 5)
    }
}
