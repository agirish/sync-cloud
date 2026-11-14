import AppKit
import SwiftUI
import Testing
@testable import Design

/// The SwiftUI fact behind where Organize's rail measures its width: a geometry proxy answers "how
/// big am I", never "how much was I offered". A card whose row can't compress reports its drawn
/// width, so fed to `OrganizeRailMetrics.style(...)` the rail would never shed its labels. Hence
/// `LensWorkspaceView` measures a zero-height `Color.clear` probe, which takes the width proposed.
/// This pins the mechanism, and fails if a SwiftUI release starts clamping.
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

        // The probe `LensWorkspaceView` measures instead: a zero-height, width-flexible sibling in
        // the same stack, which takes the proposal and can't be widened by what the card draws.
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

    /// Row 2 keeps the width it is offered, however wide its `.fixedSize()` readouts want to be;
    /// otherwise the parent centres the oversized card and draws chips off both edges. The readouts
    /// yield, not the trailing controls. A `layoutPriority` can't do this: it decides who is asked
    /// to shrink, not who is able to.
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
            // Far wider than the card is offered: a run of pills that won't compress.
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

    /// Where there is room, the readouts are drawn whole and take nothing from the trailing run.
    /// Getting the slack wrong scrolls pills out of sight or stretches the trailing prose, neither of
    /// which an overflow test can see.
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
            // Flexible, like the survey report on To File's row 2, which would stretch to fill the
            // slack if it and the summary competed for it as equals.
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
