import AppKit
import SwiftUI
import Testing
@testable import Design

/// The SwiftUI fact that made Organize's rail unable to ever shed its labels.
///
/// A geometry proxy answers "how big am I", never "how much was I offered". A `LensHeaderCard`
/// whose row cannot compress does not shrink into the width it is given — it draws at the width it
/// needs and overflows its container — so a `.onGeometryChange` on the card reports the *drawn*
/// width. `LensWorkspaceView` fed exactly that number to `OrganizeRailMetrics.style(...)`, which then asked
/// "does the width the rail forced hold the rail?", answered yes at every window size, and left the
/// card hanging over the source pane on one side and off the window on the other.
///
/// This pins the mechanism rather than the app: it is the reason the shedding decision is measured
/// on a zero-height `Color.clear` probe (which takes the width it is *proposed*) and not on the
/// card, and it is what fails if that reasoning is ever undone by a SwiftUI release that clamps.
@Suite struct LensHeaderCardOverflowTests {

    @MainActor
    @Test func theCardReportsTheWidthItDrewAtNotTheWidthItWasOffered() {
        let offered: CGFloat = 400
        let rigidTitleWidth: CGFloat = 700
        var cardReported: CGFloat = -1
        var probeReported: CGFloat = -1

        let card = LensHeaderCard(
            searchText: .constant(""), isSearchExpanded: .constant(false),
            searchPlaceholder: "", searchHelp: "", chips: [], onRemoveChip: { _ in },
            accent: .blue, surfaceStyle: .unified, level: .frosted,
            title: { Color.red.frame(width: rigidTitleWidth, height: 20) },
            actions: { EmptyView() }, summary: { EmptyView() }, trailing: { EmptyView() }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardReported = $0 }

        // The probe `LensWorkspaceView` measures instead: a zero-height, width-flexible sibling in the same
        // stack, which takes the proposal and cannot be widened by what the card draws.
        let stack = VStack(spacing: 0) {
            Color.clear.frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { probeReported = $0 }
            card
        }
        let host = NSHostingView(rootView: stack.frame(width: offered))
        host.layoutSubtreeIfNeeded()

        // The premise: both reads really ran. A -1 here would make either claim below fiction.
        #expect(cardReported > 0 && probeReported > 0,
                "a geometry read never fired — card \(cardReported), probe \(probeReported)")

        #expect(cardReported > offered,
                """
                the card now reports \(cardReported) for an offered \(offered) — SwiftUI has started \
                clamping an incompressible row, and the reasoning on `LensWorkspaceView`'s probe (and this \
                test) needs rewriting rather than deleting
                """)
        #expect(probeReported == offered,
                "the probe reported \(probeReported) for an offered \(offered) — it is being widened by its sibling, which is the whole thing it exists not to be")
    }

    /// **Row 2 keeps the width it is offered, however wide its readouts want to be.**
    ///
    /// This is the same mechanism as the test above, on the row that actually carries incompressible
    /// content in production: every lens fills `summary` with `.fixedSize()` pills. Row 2 therefore
    /// insisted, the card reported the insisted width, and the parent centred the oversized card —
    /// so a Duplicates header at 492pt drew its scan-root chip off the leading edge and "Apply 31
    /// recommended" off the trailing one, in the same render. A `layoutPriority` could not fix it:
    /// priority decides who is asked to shrink, not who is able to.
    ///
    /// The second assertion is the half that makes it a fix rather than a squeeze — the row's own
    /// stated rule is that the readouts yield **before** the controls, so the trailing controls must
    /// still measure their full width while the summary is the thing that gave way.
    @MainActor
    @Test func aRigidSummaryYieldsInsteadOfWideningTheCard() {
        let offered: CGFloat = 400
        let trailingWidth: CGFloat = 120
        var cardReported: CGFloat = -1
        var trailingReported: CGFloat = -1

        let card = LensHeaderCard(
            searchText: .constant(""), isSearchExpanded: .constant(false),
            searchPlaceholder: "", searchHelp: "", showsSearch: false,
            chips: [], onRemoveChip: { _ in },
            accent: .blue, surfaceStyle: .unified, level: .frosted,
            title: { Color.clear.frame(width: 40, height: 20) },
            actions: { EmptyView() },
            // Far wider than the card is offered — a run of pills that will not compress.
            summary: { Color.red.frame(width: 900, height: 20) },
            trailing: {
                Color.blue.frame(width: trailingWidth, height: 20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        trailingReported = $0
                    }
            }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardReported = $0 }

        let host = NSHostingView(rootView: card.frame(width: offered))
        host.layoutSubtreeIfNeeded()

        #expect(cardReported > 0 && trailingReported > 0,
                "a geometry read never fired — card \(cardReported), trailing \(trailingReported)")
        #expect(cardReported == offered,
                "the card drew at \(cardReported) for an offered \(offered) — row 2 is insisting again")
        #expect(trailingReported == trailingWidth,
                "the controls were squeezed to \(trailingReported); the readouts are what must yield")
    }

    /// **And where there IS room, the readouts take all of it and none of anyone else's.**
    ///
    /// The other half of the same fix, and the one a "does it still overflow?" test cannot see.
    /// Making the summary flexible puts it in competition for the row's slack: give it too little
    /// and the pills a wide window has ample room for are scrolled out of sight for no reason;
    /// give it too much and it takes width from the trailing prose, which then stretches past its
    /// own ideal. Both were reachable while getting this wrong, and neither looks like an overflow.
    @MainActor
    @Test func aSummaryThatFitsIsDrawnWholeAndTakesNothingFromTheTrailing() {
        let offered: CGFloat = 900
        let summaryWidth: CGFloat = 200
        let trailingWidth: CGFloat = 150
        var summaryReported: CGFloat = -1
        var trailingReported: CGFloat = -1

        let card = LensHeaderCard(
            searchText: .constant(""), isSearchExpanded: .constant(false),
            searchPlaceholder: "", searchHelp: "", showsSearch: false,
            chips: [], onRemoveChip: { _ in },
            accent: .blue, surfaceStyle: .unified, level: .frosted,
            title: { Color.clear.frame(width: 40, height: 20) },
            actions: { EmptyView() },
            summary: {
                Color.red.frame(width: summaryWidth, height: 20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        summaryReported = $0
                    }
            },
            // Flexible, like the survey report on To File's row 2 — the sibling that stretched to
            // fill the slack when the summary and it were left competing for it as equals.
            trailing: {
                Color.blue.frame(maxWidth: trailingWidth, minHeight: 20)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        trailingReported = $0
                    }
            }
        )

        let host = NSHostingView(rootView: card.frame(width: offered))
        host.layoutSubtreeIfNeeded()

        #expect(summaryReported == summaryWidth,
                "the readouts drew \(summaryReported)pt of \(summaryWidth) in a \(offered)pt row — they are being scrolled away where there is room for all of them")
        #expect(trailingReported == trailingWidth,
                "the trailing run drew \(trailingReported)pt against an ideal \(trailingWidth) — the row's slack is going into it instead of between them")
    }
}
