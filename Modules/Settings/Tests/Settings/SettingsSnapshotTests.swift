import AppKit
import Design
import SwiftUI
import Testing
@testable import Settings

/// Visual snapshot net over the Settings module: Appearance ▸ Look's accent section as it ships.
/// Marked `.machinePinned(.referenceImages)` so CI excludes it like the other packages' snapshot
/// suites (Modules/Design/Tests/DesignTests/SNAPSHOTS.md has the re-record workflow).
///
/// The pixel and caption assertions on the accent pairing live in `AccentPreviewTests`. They
/// sample a live renderer, so they are not machine-independent either and carry
/// `.machinePinned(.pixelSampling)`.
@MainActor
@Suite(.serialized, .machinePinned(.referenceImages)) struct SettingsSnapshotTests {

    /// The section as it ships, swatches and preview strip (no caption but None's, since TE332), at the real content width in
    /// both appearances. Amber and Cyan are the lightest accents, the ones `AccentFill` deepens
    /// most; Indigo and Graphite come back untouched. `.none` is absent: it resolves the machine's
    /// system accent, so the reference would not be portable.
    ///
    /// Swapping the deepened fill for the raw accent fails this; a few points of spacing inside
    /// the strip does not, being under the tolerance. Geometry is pinned by `SettingsLayoutTests`
    /// and `AccentPreviewTests`' `noneStillPaintsALegibleButton`, not by this image.
    @MainActor
    @Test func accentSectionSnapshot() {
        assertViewSnapshot(
            of: AccentSectionSpecimen(),
            // 700 clears four sections at their measured pitch plus the page padding. Not
            // generous on purpose: a section growing past a fixed frame is cropped, not failed.
            size: CGSize(width: SettingsSheetMetrics.contentWidth(textScale: 1), height: 700),
            named: "accent-section")
    }

    private struct AccentSectionSpecimen: View {
        var body: some View {
            // Pitch and padding from the metrics `SettingsPage` draws with, so the specimen stays
            // true to the real page.
            VStack(alignment: .leading, spacing: SettingsSheetMetrics.sectionPitch) {
                ForEach([LiquidGlassHue.amber, .cyan, .indigo, .graphite]) { hue in
                    AccentColorSection(selectedHue: hue, onSelect: { _ in })
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, SettingsSheetMetrics.pagePaddingV)
        }
    }
}
