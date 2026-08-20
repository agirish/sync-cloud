import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// The Readability tab's preview claims to draw file rows the way the panes do. This is what makes
/// that a checked claim rather than an intention.
///
/// **The two cannot be shared as one expression.** `PaneRowFonts` lives here in FileExplorer and
/// `SizeSpacingPreview` lives in Design, which cannot see this module — so the type is written
/// twice by necessity, and written-twice is exactly how a link comes to mean one thing on one side
/// and something else on the other. It already did: the preview drew plain 11pt and 10pt in the
/// default face while a real row draws 13pt SF **Rounded**, and its own doc said the rows were
/// what the panes draw.
@Suite struct PreviewMatchesPaneTypeTests {

    @Test func thePreviewDrawsTheTypeThePanesDraw() {
        // Compared as resolved `Font` values at a scale, not as descriptions of them: `Font` is
        // opaque, so this is the only comparison that sees the DESIGN as well as the size — and
        // the design is the half that was wrong.
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

    /// And the guard that the comparison above can fail: two genuinely different fonts must not
    /// compare equal through it.
    @Test func theComparisonCanTellTwoFontsApart() {
        let rounded = ScaledFont.system(.body, design: .rounded).resolved(scale: 1)
        let plain = ScaledFont.system(.body).resolved(scale: 1)
        #expect(rounded != plain,
                "resolved Font values compare equal across designs — the check above is vacuous")
    }
}
