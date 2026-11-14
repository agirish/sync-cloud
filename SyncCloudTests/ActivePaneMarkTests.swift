@testable import SyncCloud
import Design
import SwiftUI
import Testing
import AppKit

/// The mark on the pane the sidebar opens into. The `Left | Right` control in the sidebar's header
/// says which pane is armed; this shows the answer on the destination itself, so confirming needs
/// no look away from the panes. Its design hangs on one constraint: it may not take layout.
@MainActor @Suite struct ActivePaneMarkTests {

    private static let subject = CGSize(width: 260, height: 120)

    private func laidOut(_ isFocused: Bool, style: SurfaceStyle = .unified) -> CGSize {
        let view = Color.clear
            .frame(width: Self.subject.width, height: Self.subject.height)
            .modifier(ActivePaneMark(isFocused: isFocused,
                                             accent: LiquidGlassHue.blue.accentColor,
                                             surfaceStyle: style))
        return NSHostingView(rootView: AnyView(view)).fittingSize
    }

    /// The same card, bordered and not — `strokeBorder` draws inside the shape, so the accent
    /// replaces the hairline in place instead of growing the card into its gutter.
    private func card(_ accent: Color?) -> CGSize {
        let view = Color.clear
            .frame(width: Self.subject.width, height: Self.subject.height)
            .surfaceCard(.solid, accentBorder: accent)
        return NSHostingView(rootView: AnyView(view)).fittingSize
    }

    /// Decoration, never layout. Both of `PaneHeader`'s rows are pinned by measurement
    /// (`PaneHeaderHeightTests`, `PaneBarLadderTests`), so a label in either row would burst a
    /// rung. This keeps the mark free if someone later reaches for a chip with a word in it.
    @Test func markingAPaneCostsItNoSpace() {
        #expect(laidOut(true) == laidOut(false),
                "the destination mark changed the pane's size — it must be decoration, or it will burst a header rung that is pinned by measurement")
        #expect(laidOut(true) == Self.subject)
        // In both styles: `.unified` has no per-pane card, so the column ring is its only mark.
        #expect(laidOut(true, style: .cards) == Self.subject)
    }

    /// The border has a floor and a ceiling. Thicker than the `.quaternary` hairline it replaces,
    /// or it reads as ordinary chrome (dark cards carry a light specular hairline of their own, so
    /// 1pt is too thin). Quieter than the full accent, because a pane already wears accent-coloured
    /// chrome and three full-strength outlines around it read as an alarm.
    @Test func theBorderIsThickerThanAHairlineAndQuieterThanTheAccent() {
        #expect(LiquidGlass.activeCardBorderWidth > 1)
        #expect(LiquidGlass.activeCardBorderOpacity < 0.6,
                "the active-pane border is back at full-strength accent — it was reported as far too loud there")
        #expect(LiquidGlass.activeCardBorderOpacity > 0.25,
                "the border is faint enough to be ambiguous, and it is the only thing saying which pane Copy and Move act on")
    }

    /// The cards get the dimmed accent, not the raw one. Both come from one function, so the
    /// `.cards` borders and the `.unified` ring cannot drift into different blues.
    @Test func theCardsAreHandedTheDimmedAccent() throws {
        let raw = LiquidGlassHue.blue.accentColor
        let handed = try #require(ActivePaneMark.cardAccent(isFocused: true, accent: raw,
                                                                   surfaceStyle: .cards))
        let alpha = { (c: Color) in NSColor(c).usingColorSpace(.sRGB)?.alphaComponent ?? -1 }
        #expect(alpha(handed) < alpha(raw),
                "the card border is handed the accent at full strength")
        #expect(abs(alpha(handed) - LiquidGlass.activeCardBorderOpacity) < 0.01)
    }

    /// A bordered card is exactly the size of an unbordered one: `markingAPaneCostsItNoSpace` for
    /// the mechanism that draws the mark in `.cards`. `stroke` instead of `strokeBorder` would spill
    /// half the width into the gutter; a `.border`/`.padding` pair would grow the card.
    @Test func borderingACardCostsItNoSpace() {
        #expect(card(LiquidGlassHue.blue.accentColor) == card(nil),
                "the accent border changed the card's size — it must draw inside the shape")
    }

    // MARK: - The two styles are marked by different mechanisms

    /// `.cards` is bordered per card, so the column-level modifier must draw nothing there, or the
    /// pane would wear both a ring and three borders.
    @Test func theColumnRingIsUnifiedOnly() {
        #expect(ActivePaneMark.cardAccent(isFocused: true,
                                                 accent: LiquidGlassHue.blue.accentColor,
                                                 surfaceStyle: .unified) == nil,
                "Unified handed a card accent, where paneCardIfNeeded is a no-op — it would be silently discarded")
    }

    /// A pane that is not the destination is unmarked in both styles. The pane that stays silent is
    /// half of what makes the marked one legible.
    @Test func anUndestinedPaneIsUnmarkedInEitherStyle() {
        for style in SurfaceStyle.allCases {
            #expect(ActivePaneMark.cardAccent(isFocused: false,
                                                     accent: LiquidGlassHue.blue.accentColor,
                                                     surfaceStyle: style) == nil,
                    "a non-destination pane took a border in \(style)")
        }
    }
}

/// Which pane wears the mark, read from the app source with comments stripped.
@Suite struct PaneIsDestinationTests {

    static func source() throws -> String { sourceCodeOnly(try macAppFile("ContentView+FolderSidebar.swift")) }

    /// The mark shows only in Compare (a one-pane workspace needs no answer), and its side comes
    /// from the same rule as the click, or the border and the click disagree. It must not be gated
    /// on the sidebar being open: ⌘F, Copy, Move and every lens scan act on the focused pane either
    /// way, so hiding the mark then would hide the answer when it is still needed.
    @Test func theMarkIsGatedOnCompareAloneAndTakesTheOneRule() throws {
        let code = try Self.source()
        #expect(code.contains("guard selectedWorkspace == .compare else { return false }"),
                "the mark is not gated to Compare")
        #expect(!code.contains("selectedWorkspace == .compare, folderSidebarIsShowing"),
                "the mark is gated on the sidebar being open again — it names the focused pane now, which Copy and ⌘F act on with the column closed")
        #expect(code.contains("return isLeft == folderSidebarTargetIsLeft"),
                "the mark resolves its side some way other than the rule the click uses — they can disagree")
    }

    /// The mark is applied to the pane column, and to the pane column only. Applied deeper it would
    /// land inside the header's measured rows; applied higher it would cover both panes.
    @Test func theMarkIsAppliedToThePaneColumn() throws {
        // Counted inside `paneColumn`'s body, not across the file: a surface elsewhere adopting
        // the spelling while a pane card lost it would keep a file-wide count at three.
        let column = try declarationBody(of: "func paneColumn(isLeft: Bool) -> some View {",
                                         in: macAppFile("ContentView.swift"))
        #expect(column.contains("ActivePaneMark(isFocused: paneIsFocusedPane(isLeft: isLeft)"),
                "the pane column does not carry the mark")
        // Every card in the column, not some of them: a stack with one bordered card reads as that
        // card being active rather than the pane.
        #expect(column.components(separatedBy: "accentBorder: paneCardAccent(isLeft: isLeft)").count - 1 == 3,
                "the column's three cards do not all take the accent border")
    }

    /// Every click in a pane moves the focus to it. A list of the ways to click a pane goes stale
    /// as soon as a control is added, so the question is asked once, where every press is visible.
    @Test func everyClickInAPaneMovesTheFocus() throws {
        let code = try macAppFile("ContentView.swift")
        #expect(code.contains("PaneClickReporter {"),
                "the pane column no longer reports clicks, so focus moves only on a row selection again")
        #expect(code.contains("noteFocusedPane(isLeft: isLeft, because: \"a click in this pane\")"),
                "the reporter does not move the focused side, or moves it to the wrong pane")
    }
}

/// The reporter watches without intercepting, which is what makes it safe to lay over a pane full
/// of controls.
@MainActor @Suite struct PaneClickReporterTests {

    /// A press is working in a pane; hover is not. `hitTest` is called for far more than presses
    /// (tracking areas and layout ask too), and a focus move on hover would re-aim ⌘W and Delete at
    /// whatever pane the pointer last crossed.
    @Test func onlyPressesCount() {
        #expect(PaneClickReporter.shouldReport(.leftMouseDown))
        #expect(PaneClickReporter.shouldReport(.rightMouseDown),
                "a right-click does not count as working in a pane — but its context menu acts on that pane")
        for ignored: NSEvent.EventType in [.mouseMoved, .mouseEntered, .mouseExited,
                                           .leftMouseUp, .leftMouseDragged, .keyDown] {
            #expect(!PaneClickReporter.shouldReport(ignored),
                    "\(ignored) moved the focused pane")
        }
        #expect(!PaneClickReporter.shouldReport(nil), "focus moved with no event in flight at all")
    }

    /// A reporter mounted in a host, with the event in flight injected (see
    /// `ClickReportingView.currentEventType` for why that seam exists). It sits in the right half
    /// of its host, as Compare's right pane does: at the origin, local and superview coordinates
    /// match, which would hide a member reading the point as local.
    private func mounted(_ event: NSEvent.EventType?,
                         deliverNow: Bool = true) -> (PaneClickReporter.ClickReportingView, () -> Int) {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let reporter = PaneClickReporter.ClickReportingView(
            frame: CGRect(x: 100, y: 0, width: 100, height: 200))
        host.addSubview(reporter)
        final class Count { var n = 0 }
        let count = Count()
        reporter.onClick = { count.n += 1 }
        reporter.currentEventType = { event }
        // Synchronous delivery, so these tests check the reporting rule without spinning a run
        // loop. `theReportLeavesTheClicksOwnRoutingWindow` keeps the production `deliver`.
        if deliverNow { reporter.deliver = { $0() } }
        return (reporter, { count.n })
    }

    /// The report arrives outside the click's own routing window. `hitTest` runs while the event is
    /// routed, and the report is a `@Published` write the clicked List is bound to: delivered
    /// synchronously, inside the table's mouse-down tracking loop, the first click would not
    /// select. Nothing fires inside `hitTest`; the report lands on the next `.default`-mode turn.
    @Test func theReportLeavesTheClicksOwnRoutingWindow() {
        let (reporter, reported) = mounted(.leftMouseDown, deliverNow: false)
        #expect(reporter.hitTest(CGPoint(x: 150, y: 100)) == nil)
        #expect(reported() == 0,
                "the report published inside the click's own routing window — the ordering aa9d407 exists to forbid")
        // Bounded: spin `.default` until the deferred report lands or the budget is spent.
        let deadline = Date().addingTimeInterval(2)
        while reported() == 0, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        #expect(reported() == 1, "the deferred report never arrived — the click would no longer move focus at all")
    }

    /// It answers nil to every hit test, so the press goes on to whatever lies beneath; returning
    /// itself would swallow the first click on every button in the pane. Asserted along the path
    /// that reports, so `return self` in place of `return nil` must fail it.
    @Test func itNeverTakesTheClick() {
        let (reporting, reported) = mounted(.leftMouseDown)
        #expect(reporting.hitTest(CGPoint(x: 150, y: 100)) == nil,
                "the reporter claimed a click it had just reported")
        #expect(reported() == 1, "this case did not reach the reporting path — the assertion above is vacuous")

        let (quiet, ignored) = mounted(.mouseMoved)
        #expect(quiet.hitTest(CGPoint(x: 150, y: 100)) == nil)
        #expect(ignored() == 0)
    }

    /// Only presses inside the pane count. The point arrives in the superview's coordinates, so a
    /// member reading it as local would report clicks outside itself, which shows in Compare's right
    /// pane.
    @Test func aPressOutsideThePaneIsNotWorkingInIt() {
        // (50, 100) is in the host's left half: outside this reporter, but inside its `bounds` if
        // the point is not converted.
        let (beside, notReported) = mounted(.leftMouseDown)
        #expect(beside.hitTest(CGPoint(x: 50, y: 100)) == nil)
        #expect(notReported() == 0,
                "a click in the OTHER pane moved the focus here — the point is being read as local")

        let (far, alsoNot) = mounted(.leftMouseDown)
        #expect(far.hitTest(CGPoint(x: 500, y: 500)) == nil)
        #expect(alsoNot() == 0, "a click outside the window moved the focus into this pane")
    }
}
