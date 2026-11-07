import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// Text & Spacing's preview claims to draw file rows the way the panes do; this makes that a
/// checked claim rather than an intention.
///
/// The two can't share one expression: `PaneRowFonts` lives in FileExplorer and
/// `SizeSpacingPreview` lives in Design, which can't see this module. Written twice, they can drift
/// apart in face as well as size (a real row draws SF Rounded).
@Suite struct PreviewMatchesPaneTypeTests {

    @Test func thePreviewDrawsTheTypeThePanesDraw() {
        // Compared as resolved `Font` values at a scale: `Font` is opaque, so this is the only
        // comparison that sees the design as well as the size.
        for scale in [FontSize.small.scale, FontSize.medium.scale, FontSize.extraLarge.scale] {
            let pane = PaneRowFonts(scale: scale)

            #expect(SizeSpacingPreview.nameFont.resolved(scale: scale) == pane.name,
                    """
                    The preview's file-name type is not what a pane row draws at scale \(scale) — \
                    the preview is showing the user a row the app will not give them.
                    """)
            #expect(SizeSpacingPreview.detailFont.resolved(scale: scale) == pane.secondary,
                    "The preview's size-and-date type is not what a pane row draws at scale \(scale).")
        }
    }

    /// Guards that the comparison above can fail: two different fonts must not compare equal
    /// through it.
    @Test func theComparisonCanTellTwoFontsApart() {
        let rounded = ScaledFont.system(.body, design: .rounded).resolved(scale: 1)
        let plain = ScaledFont.system(.body).resolved(scale: 1)
        #expect(rounded != plain,
                "resolved Font values compare equal across designs — the check above is vacuous")
    }
}
