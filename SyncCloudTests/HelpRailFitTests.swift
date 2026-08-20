import AppKit
import Design
import Foundation
import SwiftUI
import Testing
@testable import SyncCloud

/// No topic title needs more than two lines of the rail, at any text size.
///
/// **The rail is fixed at 220pt and does not widen when the card is resized**, so a title too long
/// for it is too long at every card size — there is no window the reader can make bigger to get
/// the word back. The row used to set `lineLimit(1)`, which turned that into a silent ellipsis:
/// measured, five titles were already over the 165pt a row gives them at Default, and "Activity
/// Log and troubleshooting" wanted 213pt at Large. Nothing could have caught it — every other test
/// here reads the copy as data, where the string is whole, and no render draws the rail.
///
/// Two lines rather than one is the bar because that is what the row now does; a third would make
/// a rail row taller than the article's own heading, which is where "too long" really begins.
@Suite struct HelpRailFitTests {

    /// The height one line of the row's own font takes at this size. Measured rather than derived
    /// from a point size: `scaledFont` applies a knee curve, so the line height is not the
    /// percentage applied to a constant.
    @MainActor
    private func lineHeight(scale: CGFloat) -> CGFloat {
        laidOutHeight("X", scale: scale)
    }

    @MainActor
    private func laidOutHeight(_ title: String, scale: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: Text(title)
            .scaledFont(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: HelpCardSize.sidebarTitleWidth)
            .environment(\.appFontScale, scale))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    @Test(arguments: [FontSize.small, .medium, .large, .extraLarge])
    func noTopicTitleNeedsMoreThanTwoRailLines(_ size: FontSize) throws {
        let one = lineHeight(scale: size.scale)
        // Half a line of slack absorbs the rounding a laid-out height carries; three lines is
        // 3× and cannot hide under it.
        let budget = one * 2.5

        var worst: (title: String, lines: CGFloat) = ("", 0)
        for topic in HelpBook.allTopics {
            let height = laidOutHeight(topic.title, scale: size.scale)
            let lines = height / one
            if lines > worst.lines { worst = (topic.title, lines) }
            #expect(height <= budget,
                    """
                    “\(topic.title)” takes \(String(format: "%.1f", lines)) lines of the \
                    \(HelpCardSize.sidebarTitleWidth)pt rail at \(size.displayName) — the rail is \
                    fixed-width, so no card size gets it back.
                    """)
        }
        print("[rail] worst at \(size.displayName): “\(worst.title)” \(String(format: "%.2f", worst.lines)) lines")
    }

    /// The control. A title nobody could fit in two lines must fail, or the measurement above is
    /// decoration — a laid-out height is exactly the kind of number that quietly comes back as one
    /// line for everything.
    @MainActor
    @Test func theRailMeasurementCanActuallyFail() {
        let absurd = "A topic title so long that no fixed sidebar in this application could ever hope to set it in only two lines of running text"
        let one = lineHeight(scale: 1.0)
        #expect(laidOutHeight(absurd, scale: 1.0) > one * 2.5)
        #expect(one > 0, "a line measures zero — nothing here is real")
        // And it really does distinguish one line from two.
        #expect(laidOutHeight("People and names", scale: 1.0) < one * 1.5)
    }

    /// The rail the measurement uses is the rail the card draws.
    ///
    /// A budget derived from constants nobody reads would measure an imaginary sidebar. Source
    /// scan because `HelpView` cannot be built in a test.
    @Test func theMeasuredRailIsTheOneTheCardDraws() throws {
        let source = try String(contentsOf: macAppDirectory().appendingPathComponent("HelpBook.swift"),
                                encoding: .utf8)
        let body = try declarationBody(of: "var body: some View", in: sourceOfHelpView(source))
        #expect(body.contains("HelpCardSize.sidebarWidth"),
                "the rail no longer takes its width from the constant this test measures against")
        let row = try declarationBody(of: "private func topicRow", in: source)
        #expect(!row.contains("lineLimit"),
                "the row limits its lines again — a title over the rail truncates rather than wraps")
        // **The face, too.** The height check above measures a `Text` this file builds, so it is
        // blind to the row changing font: swap `.callout` for `.body` and every title grows in the
        // app while the test goes on measuring the old face and passing.
        #expect(row.contains(".scaledFont(.callout)"),
                "the row's font moved — the fit measurement is now about a face nobody draws")
        #expect(row.contains(".fixedSize(horizontal: false, vertical: true)"),
                "the row no longer lets its title take the height it needs")
    }

    /// `HelpView`'s half of the file — `var body: some View` occurs in more than one type here,
    /// and `declarationBody` requires its declaration to be unique in what it is given.
    private func sourceOfHelpView(_ source: String) -> String {
        guard let start = source.range(of: "struct HelpView: View") else { return source }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n/// Renders one `HelpBook.Article`") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }
}
