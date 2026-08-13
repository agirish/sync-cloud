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
}
