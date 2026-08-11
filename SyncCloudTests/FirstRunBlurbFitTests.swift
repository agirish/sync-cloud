import Testing
import AppKit
@testable import SyncCloud

/// How many lines each tour blurb wraps to at the card's real width.
///
/// The welcome card holds its page header at `headerMinHeight` so that stepping through pages does
/// not move the dots or the button row. That floor can only pad a SHORT page — a page whose content
/// is taller than the floor pushes everything below it down, and the card visibly jumps as you
/// arrive on it. So a blurb one line longer than its budget is a layout regression, and it is
/// invisible to every other test here: the copy is still correct, the page still renders, and the
/// suite stays green. It shipped that way — "Let Organize do the filing" wrapped to four lines with
/// "Settings." alone on the last one.
///
/// **This measures at the DEFAULT text size.** The app scales its own type (Settings ▸ Text size),
/// and at a larger setting every blurb wraps further; the budget below is the floor case, not a
/// guarantee for all settings. It is worth having anyway — the regression this caught was at the
/// default, which is what almost every first run uses.
@Suite struct FirstRunBlurbFitTests {

    /// Lays a blurb out exactly as the card does: `.callout`, centred, word-wrapped, at the card's
    /// width minus both insets — read from `FirstRunOverlay` rather than restated, so a card that
    /// changes width takes this with it instead of leaving it measuring a width nothing uses.
    static func lineCount(_ text: String) -> Int {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let width = FirstRunOverlay.cardWidth - FirstRunOverlay.cardPadding * 2
        let attributed = NSAttributedString(string: text,
                                            attributes: [.font: font, .paragraphStyle: style])
        let rect = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return Int((rect.height / font.boundingRectForFont.height).rounded())
    }

    /// The positive control, and it is the actual regression rather than an invented string.
    ///
    /// Every assertion below is an upper bound, so all of them would pass against a measurement
    /// that always returned 1 — a wrong width, a font that failed to resolve, a rounding slip. This
    /// is the blurb that shipped wrapping to four lines in a 460pt card; if the measurement no
    /// longer sees four here, it cannot see the bug and nothing below is evidence.
    @Test func testTheMeasurementSeesTheBlurbThatBroke() {
        let shipped = "Organize puts loose files in the folders where they belong, proposes "
            + "better names, and can turn a choice you keep making into a rule. It reads content "
            + "signals on your Mac — or uses AI, when you turn it on in Settings."
        #expect(Self.lineCount(shipped) == 4,
                "the measurement no longer reproduces the four-line wrap it exists to catch")
    }

    /// Three lines is what the header floor can absorb on a page with no pill under it.
    @Test func testEveryBlurbFitsThreeLines() {
        for page in FirstRunWelcome.pages {
            let lines = Self.lineCount(page.blurb)
            #expect(lines <= 3, "“\(page.title)” wraps to \(lines) lines; the budget is 3")
        }
    }

    /// The last page gets two, because it is the only one carrying the provider pill (or the
    /// choose-providers hint) between its blurb and the Scan button.
    ///
    /// Keyed off `pages.last` rather than a hardcoded index or title, so reordering the tour moves
    /// the tighter budget onto whichever page inherits the pill.
    @Test func testTheLastPageFitsTwoLinesBecauseItCarriesThePill() throws {
        let last = try #require(FirstRunWelcome.pages.last)
        let lines = Self.lineCount(last.blurb)
        #expect(lines <= 2,
                "“\(last.title)” is the last page, so it carries the pill — \(lines) lines is one too many")
    }
}
