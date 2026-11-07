import AppKit
import Design
import Foundation
import SwiftUI
import Testing
@testable import SyncCloud

/// No topic title needs more than two lines of the rail, at any text size. The rail is fixed at
/// 220pt and doesn't widen with the card, so a title too long for it is too long at every card
/// size. Other Help tests read the copy as data, where the string is whole, so only this render
/// sees the rail. Two lines is the bar because the row wraps; a third would make a rail row taller
/// than the article's own heading.
@Suite(.machinePinned(.layoutMetrics)) struct HelpRailFitTests {

    /// The height one line of the row's font takes at this size. Measured, not derived from a point
    /// size: `scaledFont` applies a knee curve, so line height isn't a percentage of a constant.
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
        // Half a line of slack absorbs a laid-out height's rounding; three lines is 3× and can't
        // hide under it.
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

    /// The control: a title nobody could fit in two lines must fail, or the measurement above is
    /// decoration. A laid-out height can quietly come back as one line for everything.
    @MainActor
    @Test func theRailMeasurementCanActuallyFail() {
        let absurd = "A topic title so long that no fixed sidebar in this application could ever hope to set it in only two lines of running text"
        let one = lineHeight(scale: 1.0)
        #expect(laidOutHeight(absurd, scale: 1.0) > one * 2.5)
        #expect(one > 0, "a line measures zero — nothing here is real")
        // And it really does distinguish one line from two.
        #expect(laidOutHeight("People and names", scale: 1.0) < one * 1.5)
    }
}

/// The rail `HelpRailFitTests` measures is the rail the card draws: a source scan, which reads no
/// metrics, so unpinned.
@Suite struct HelpRailSourceTests {

    /// The rail the measurement uses is the rail the card draws; a budget from constants nobody
    /// reads would measure an imaginary sidebar. A source scan, because `HelpView` can't be built in
    /// a test.
    @Test func theMeasuredRailIsTheOneTheCardDraws() throws {
        let source = try macAppFile("HelpBook.swift")
        let body = try declarationBody(of: "var body: some View", in: sourceOfHelpView(source))
        #expect(body.contains("HelpCardSize.sidebarWidth"),
                "the rail no longer takes its width from the constant this test measures against")
        let row = try declarationBody(of: "private func topicRow", in: source)
        #expect(!row.contains("lineLimit"),
                "the row limits its lines again — a title over the rail truncates rather than wraps")
        // The face too: the height check measures a `Text` this file builds, so it is blind to the
        // row changing font, and swapping `.callout` for `.body` would grow every title unseen.
        #expect(row.contains(".scaledFont(.callout)"),
                "the row's font moved — the fit measurement is now about a face nobody draws")
        #expect(row.contains(".fixedSize(horizontal: false, vertical: true)"),
                "the row no longer lets its title take the height it needs")
    }

    /// `HelpView`'s part of the file: `var body: some View` occurs in more than one type here, and
    /// `declarationBody` needs its declaration to be unique in what it is given.
    private func sourceOfHelpView(_ source: String) -> String {
        guard let start = source.range(of: "struct HelpView: View") else { return source }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n/// Renders one `HelpBook.Article`") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }
}
