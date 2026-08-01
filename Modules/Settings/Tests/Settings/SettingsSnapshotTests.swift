import AppKit
import Design
import SwiftUI
import Testing
@testable import Settings

/// Visual snapshot net over the Settings module — the Appearance tab's accent section as it
/// ships. Machine-pinned image comparisons live here, in a `*SnapshotTests` suite, so CI's
/// `--skip SnapshotTests` filter excludes them the same way it excludes the other three
/// packages' snapshot suites (see Modules/Design/Tests/DesignTests/SNAPSHOTS.md for the
/// re-record workflow and the single-machine caveat). The painted-pixel and caption assertions
/// that pin the accent PAIRING stay in `AccentPreviewTests` — they are machine-independent and
/// must keep running on CI.
@MainActor
@Suite(.serialized) struct SettingsSnapshotTests {

    /// The section as it ships: twelve swatches, the preview strip, and the caption — at the real
    /// content width, in both appearances.
    ///
    /// Four hues, chosen so the reference shows the on-accent pairing across the deepening range:
    /// Amber and Cyan are the two lightest accents (the ones `AccentFill` moves furthest, and the
    /// ones where a raw-accent regression would be unmistakable), Indigo and Graphite are dark
    /// enough to come back untouched. `.none` is deliberately absent — it resolves the machine's
    /// system accent, which would make this reference non-portable.
    ///
    /// What this reference does and does not protect, measured rather than assumed (the caveat
    /// `countPillFreshnessStates` records for the same reason): swapping the deepened fill for the
    /// raw accent DOES fail it — the colour change is far past the 0.99/0.98 tolerance. Changing
    /// the strip's internal spacing by 4pt does NOT: one small capsule shifting inside a 583×700
    /// frame is a smaller share of the pixels than the tolerance absorbs. Geometry here is pinned
    /// by `SettingsLayoutTests`' laid-out height and by the size check in `AccentPreviewTests`'
    /// `noneStillPaintsALegibleButton`, not by this image.
    @MainActor
    @Test func accentSectionSnapshot() {
        assertViewSnapshot(
            of: AccentSectionSpecimen(),
            // 700 clears four sections at their measured 163pt pitch plus the page's own padding.
            // Sized deliberately, not generously: the frame is fixed, so a section growing past it
            // would be silently cropped out of the reference rather than failing it.
            size: CGSize(width: SettingsSheetMetrics.contentWidth(textScale: 1), height: 700),
            named: "accent-section")
    }

    private struct AccentSectionSpecimen: View {
        var body: some View {
            // Pitch and padding from the same metrics `SettingsPage` draws with, so the specimen
            // keeps rendering the section in its real habitat instead of a stale copy of it.
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
