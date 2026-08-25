@testable import SyncCloud
import Design
import SwiftUI
import Testing
import AppKit

/// **The mark on the pane the sidebar opens into.**
///
/// The `Left | Right` control says which pane is armed and lives in the sidebar's header, so
/// confirming meant looking away from the panes to a corner that was not part of the work. This is
/// the other half — the answer on the destination — and its whole design is constrained by one
/// thing: it may not take layout.
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

    /// **Decoration, never layout — the constraint the whole design hangs on.**
    ///
    /// Both of `PaneHeader`'s rows are pinned by measurement: `PaneHeaderHeightTests` holds the
    /// header to `LiquidGlass.headerHeight`, and `PaneBarLadderTests` measures the top row
    /// overflowing a 250pt pane by 10.5pt in the state nothing tested. A label in either row would
    /// burst a rung — which is exactly what that file records happening to the search field. So the
    /// mark has to be free, and this is the assertion that keeps it free when someone later reaches
    /// for a chip with a word in it.
    @Test func markingAPaneCostsItNoSpace() {
        #expect(laidOut(true) == laidOut(false),
                "the destination mark changed the pane's size — it must be decoration, or it will burst a header rung that is pinned by measurement")
        #expect(laidOut(true) == Self.subject)
    }

    /// A pane that is not the destination gets nothing at all — not a transparent bar, not a
    /// zero-height one. Half of "which pane" is the pane that is silent.
    @Test func anUnmarkedPaneIsUntouched() {
        #expect(laidOut(false) == Self.subject)
    }

    /// **The border has a floor and a ceiling, and it has been at both.**
    ///
    /// Thicker than the card chrome it stands in for (a `.quaternary` hairline) or it reads as
    /// ordinary chrome — and dark cards carry a light specular hairline of their own, which is what
    /// stopped this going to 1pt. Quieter than the full accent or it shouts: a pane is surrounded
    /// by accent-coloured chrome already (source chip, view-mode button, breadcrumb, every folder
    /// icon), and at full strength three outlines around all of that read as an alarm. It shipped
    /// at 2pt/100% for one build and was reported from the running app the same day.
    @Test func theBorderIsThickerThanAHairlineAndQuieterThanTheAccent() {
        #expect(LiquidGlass.activeCardBorderWidth > 1)
        #expect(LiquidGlass.activeCardBorderOpacity < 0.6,
                "the active-pane border is back at full-strength accent — it was reported as far too loud there")
        #expect(LiquidGlass.activeCardBorderOpacity > 0.25,
                "the border is faint enough to be ambiguous, and it is the only thing saying which pane Copy and Move act on")
    }

    /// **The colour the cards get is the dimmed one**, not the raw accent — the two are one
    /// function, so the `.cards` borders and the `.unified` ring cannot drift into different blues.
    @Test func theCardsAreHandedTheDimmedAccent() throws {
        let raw = LiquidGlassHue.blue.accentColor
        let handed = try #require(ActivePaneMark.cardAccent(isFocused: true, accent: raw,
                                                                   surfaceStyle: .cards))
        let alpha = { (c: Color) in NSColor(c).usingColorSpace(.sRGB)?.alphaComponent ?? -1 }
        #expect(alpha(handed) < alpha(raw),
                "the card border is handed the accent at full strength")
        #expect(abs(alpha(handed) - LiquidGlass.activeCardBorderOpacity) < 0.01)
    }

    /// **A bordered card is exactly the size of an unbordered one**, which is the same constraint
    /// as `markingAPaneCostsItNoSpace` applied to the mechanism that actually draws the mark in
    /// `.cards`. `stroke` instead of `strokeBorder` would spill half the width outward and shrink
    /// the gutter; a `.border`/`.padding` pair would grow the card into its neighbour.
    @Test func borderingACardCostsItNoSpace() {
        #expect(card(LiquidGlassHue.blue.accentColor) == card(nil),
                "the accent border changed the card's size — it must draw inside the shape")
    }

    // MARK: - The two styles are marked by different mechanisms

    /// **`.cards` is bordered per card, so the column-level modifier must draw nothing there** —
    /// otherwise the pane would wear both a ring and three borders.
    @Test func theColumnRingIsUnifiedOnly() {
        #expect(ActivePaneMark.cardAccent(isFocused: true,
                                                 accent: LiquidGlassHue.blue.accentColor,
                                                 surfaceStyle: .cards) != nil,
                "a destination pane in Cards has no border colour, so its cards cannot mark themselves")
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

    /// **`.unified` really does get the ring**, measured rather than asserted from the source: it
    /// has no per-pane card, so if this modifier drew nothing there the style would be unmarked
    /// altogether. Size is unchanged either way — presence is what is at stake, not cost.
    @Test func unifiedIsStillMarkedAndStillFree() {
        #expect(laidOut(true, style: .unified) == Self.subject)
        #expect(laidOut(true, style: .cards) == Self.subject)
    }
}

/// **Which pane wears it**, which is three questions and not one.
@Suite struct PaneIsDestinationTests {

    static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView+FolderSidebar.swift — this scan would be vacuous")
        try #require(raw.count > 3000, "the file is implausibly short — the scan is vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    @Test func theScanCanSeeAKnownSymbol() throws {
        #expect(try Self.source().contains("func paneIsFocusedPane"))
    }

    /// **Compare, and then the side — two conditions, where there used to be three.**
    ///
    /// Marking a pane in a workspace that has one answers a question nobody asked, so Compare
    /// stays. The side has to come from the one rule that decides it, or the border and the click
    /// disagree.
    ///
    /// **The third condition is required to be ABSENT.** The mark was gated on the folder column
    /// being on screen, which was right while it named a sidebar destination and is wrong now that
    /// it names the focused pane: ⌘F, Copy, Move and every lens scan act on that pane whether or
    /// not the sidebar is showing, and hiding the answer in that state is exactly the gap
    /// `focusedPaneSide` has always had. A restored gate would make this a resting indicator that
    /// does not rest, and nothing else in the suite would notice.
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
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8))
        // Counted inside `paneColumn`'s own body, not across the file: a fourth surface elsewhere
        // adopting the spelling while a pane card lost it would keep a file-wide count at three —
        // the assertion is about the column the test names.
        let start = try #require(code.range(of: "func paneColumn"),
                                 "paneColumn is gone — the mark has no home to be asserted in")
        let rest = String(code[start.upperBound...])
        // Member indentation only (4–5 spaces): a looser `\s*` would stop at the first LOCAL
        // `var` inside the body and truncate the slice above the cards it is counting.
        let end = rest.range(of: #"\n {4,5}(private )?(func|var) "#, options: .regularExpression)
        let column = end.map { String(rest[..<$0.lowerBound]) } ?? rest
        #expect(column.contains("ActivePaneMark(isFocused: paneIsFocusedPane(isLeft: isLeft)"),
                "the pane column does not carry the mark")
        // Every card in the column, not some of them: a stack with one bordered card reads as that
        // card being active rather than the pane.
        #expect(column.components(separatedBy: "accentBorder: paneCardAccent(isLeft: isLeft)").count - 1 == 3,
                "the column's three cards do not all take the accent border")
    }

    /// **Every click in a pane reports it, and the reporter never takes the click.**
    ///
    /// The focused side used to move on three things — ⌃⇥, a row selection, a tab verb — and
    /// `noteWorkingIn`'s own comment enumerates four gaps found one bug report at a time. An
    /// enumeration of the ways to click a pane goes stale the moment a control is added, so the
    /// question is asked once, where every press is visible.
    @Test func everyClickInAPaneMovesTheFocus() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8))
        #expect(code.contains("PaneClickReporter {"),
                "the pane column no longer reports clicks, so focus moves only on a row selection again")
        #expect(code.contains("noteFocusedPane(isLeft: isLeft, because: \"a click in this pane\")"),
                "the reporter does not move the focused side, or moves it to the wrong pane")
    }
}

/// **The reporter watches without intercepting**, which is the only thing that makes it safe to lay
/// over a pane full of controls.
@MainActor @Suite struct PaneClickReporterTests {

    /// A press is working in a pane; hover is not. `hitTest` is called for far more than presses —
    /// tracking areas and layout ask too — and a focus move on hover would re-aim ⌘W and Delete at
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

    /// A reporter mounted in a host, with the event in flight injected — see
    /// `ClickReportingView.currentEventType` for why that seam has to exist.
    /// **Mounted in the RIGHT half of its host, not filling it.** A reporter at its superview's
    /// origin makes local and superview coordinates identical, which hides a member reading the
    /// point as local — substituting `bounds.contains(point)` passed a fixture built that way. This
    /// is the geometry Compare actually has: two panes, and the right one never starts at zero.
    private func mounted(_ event: NSEvent.EventType?) -> (PaneClickReporter.ClickReportingView, () -> Int) {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let reporter = PaneClickReporter.ClickReportingView(
            frame: CGRect(x: 100, y: 0, width: 100, height: 200))
        host.addSubview(reporter)
        final class Count { var n = 0 }
        let count = Count()
        reporter.onClick = { count.n += 1 }
        reporter.currentEventType = { event }
        // Delivery made synchronous so these tests assert the REPORTING rule (which presses, at
        // which points) without also spinning a runloop. The deferral itself is pinned by
        // `theReportLeavesTheClicksOwnRoutingWindow`, which keeps the production `deliver`.
        reporter.deliver = { $0() }
        return (reporter, { count.n })
    }

    /// **The report arrives OUTSIDE the click's own routing window.** `hitTest` runs while the
    /// event is being routed, and the report is a `@Published` write the clicked List is bound
    /// to — delivered synchronously it is the `aa9d407` two-clicks-to-select ordering, pending
    /// inside the table's mouse-down tracking loop. This pins the production `deliver`: nothing
    /// fires inside `hitTest`, and the report lands on the next `.default`-mode turn.
    @Test func theReportLeavesTheClicksOwnRoutingWindow() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let reporter = PaneClickReporter.ClickReportingView(
            frame: CGRect(x: 100, y: 0, width: 100, height: 200))
        host.addSubview(reporter)
        final class Count { var n = 0 }
        let count = Count()
        reporter.onClick = { count.n += 1 }
        reporter.currentEventType = { .leftMouseDown }
        #expect(reporter.hitTest(CGPoint(x: 150, y: 100)) == nil)
        #expect(count.n == 0,
                "the report published inside the click's own routing window — the ordering aa9d407 exists to forbid")
        // Bounded: spin `.default` until the deferred report lands or the budget is spent.
        let deadline = Date().addingTimeInterval(2)
        while count.n == 0, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        #expect(count.n == 1, "the deferred report never arrived — the click would no longer move focus at all")
    }

    /// **It answers nil to every hit test**, so the press continues to whatever lies beneath. A
    /// reporter that returned itself would swallow the first click on every button it covers —
    /// which is the whole pane.
    ///
    /// **Asserted along the path that reports**, which is the correction. Written without the seam
    /// this took the guard's early exit on every input — `NSApp.currentEvent` is nil in a test
    /// process — so it passed unchanged with `return self` substituted for `return nil`: the one
    /// mutation it exists to catch.
    @Test func itNeverTakesTheClick() {
        let (reporting, reported) = mounted(.leftMouseDown)
        #expect(reporting.hitTest(CGPoint(x: 150, y: 100)) == nil,
                "the reporter claimed a click it had just reported")
        #expect(reported() == 1, "this case did not reach the reporting path — the assertion above is vacuous")

        let (quiet, ignored) = mounted(.mouseMoved)
        #expect(quiet.hitTest(CGPoint(x: 150, y: 100)) == nil)
        #expect(ignored() == 0)
    }

    /// **Only presses inside the pane count.** The point arrives in the superview's coordinates, so
    /// a member reading it as local would report clicks landing outside itself — and Compare's
    /// right pane never sits at its superview's origin, which is where that would show.
    @Test func aPressOutsideThePaneIsNotWorkingInIt() {
        // (50, 100) is in the host's LEFT half — outside this reporter, but inside its `bounds`
        // once you forget to convert, which is precisely the substitution being guarded.
        let (beside, notReported) = mounted(.leftMouseDown)
        #expect(beside.hitTest(CGPoint(x: 50, y: 100)) == nil)
        #expect(notReported() == 0,
                "a click in the OTHER pane moved the focus here — the point is being read as local")

        let (far, alsoNot) = mounted(.leftMouseDown)
        #expect(far.hitTest(CGPoint(x: 500, y: 500)) == nil)
        #expect(alsoNot() == 0, "a click outside the window moved the focus into this pane")
    }
}
