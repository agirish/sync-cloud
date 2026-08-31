import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SyncCloud

/// The Help card's resize rule.
///
/// The card is centred in its overlay, which is what makes this worth a type of its own: the
/// obvious "add the translation to the width" is wrong by a factor of two, and wrong in a way that
/// reads as lag rather than as a bug — the grip drifts at half the pointer's speed and nothing
/// about the code looks incorrect. `HelpView` is a SwiftUI `View` with `@State` and `@AppStorage`
/// and cannot be built in a test, so a clamp written inline there would be a clamp nothing could
/// flip.
@Suite(.machinePinned(.layoutMetrics)) struct HelpCardSizeTests {

    static let room = CGSize(width: 2000, height: 1400)

    // MARK: The doubling

    /// Dragging the trailing edge 10pt right moves that edge 10pt right — which, on a centred
    /// card, is 20pt of width.
    @Test func aDragMovesTheGripItHasHoldOf() {
        let size = HelpCardSize.resized(from: CGSize(width: 760, height: 520),
                                        by: CGSize(width: 10, height: 0),
                                        grip: .trailing, within: Self.room)
        #expect(size.width == 780)
        #expect(size.height == 520, "a horizontal grip moved the height")
    }

    /// The leading edge is the mirror: dragging it right makes the card narrower.
    @Test func theTwoSidesMoveInOppositeDirections() {
        let start = CGSize(width: 760, height: 520)
        let out = HelpCardSize.resized(from: start, by: CGSize(width: 10, height: 0),
                                       grip: .leading, within: Self.room)
        #expect(out.width == 740)
    }

    /// Same for top against bottom.
    @Test func theTopAndBottomMoveInOppositeDirections() {
        let start = CGSize(width: 760, height: 520)
        let down = CGSize(width: 0, height: 10)
        #expect(HelpCardSize.resized(from: start, by: down, grip: .bottom, within: Self.room).height == 540)
        #expect(HelpCardSize.resized(from: start, by: down, grip: .top, within: Self.room).height == 500)
    }

    /// A corner moves both, and each axis by its own translation.
    @Test func aCornerMovesBothAxes() {
        let size = HelpCardSize.resized(from: CGSize(width: 760, height: 520),
                                        by: CGSize(width: 10, height: 20),
                                        grip: .bottomTrailing, within: Self.room)
        #expect(size.width == 780)
        #expect(size.height == 560)
    }

    /// **Every grip moves exactly the axes it names.** Written as a walk over `allCases` rather
    /// than as eight assertions, so a ninth grip cannot be added without an answer here.
    @Test func everyGripMovesTheAxesItsNameClaims() {
        for grip in HelpCardGrip.allCases {
            let start = CGSize(width: 760, height: 520)
            let out = HelpCardSize.resized(from: start, by: CGSize(width: 10, height: 10),
                                           grip: grip, within: Self.room)
            let movedWidth = out.width != start.width
            let movedHeight = out.height != start.height
            #expect(movedWidth == (grip.horizontal != 0), "\(grip) moved width when it should not, or did not when it should")
            #expect(movedHeight == (grip.vertical != 0), "\(grip) moved height wrongly")
        }
    }

    /// The control for the walk above: it would notice a grip that moved nothing at all.
    @Test func theGripWalkWouldNoticeADeadGrip() {
        let moving = HelpCardGrip.allCases.filter { $0.horizontal != 0 || $0.vertical != 0 }
        #expect(moving.count == HelpCardGrip.allCases.count)
        #expect(HelpCardGrip.allCases.count == 8)
    }

    // MARK: The bounds

    @Test func theCardCannotBeDraggedBelowItsFloor() {
        let size = HelpCardSize.resized(from: HelpCardSize.minimum,
                                        by: CGSize(width: -500, height: -500),
                                        grip: .bottomTrailing, within: Self.room)
        #expect(size == HelpCardSize.minimum)
    }

    @Test func theCardCannotBeDraggedPastWhatTheWindowCanShow() {
        let available = CGSize(width: 900, height: 600)
        let size = HelpCardSize.resized(from: CGSize(width: 760, height: 520),
                                        by: CGSize(width: 900, height: 900),
                                        grip: .bottomTrailing, within: available)
        #expect(size == available)
    }

    /// **The first layout pass reports `.zero`, and clamping straight to it would collapse the
    /// card on the frame it appears.** This is the branch that stops that, and it is live rather
    /// than defensive — mutate `max(minimum, available)` to plain `available` and this fails.
    @Test func aWindowThatHasNotBeenMeasuredYetDoesNotCollapseTheCard() {
        #expect(HelpCardSize.clamped(HelpCardSize.initial, within: .zero) == HelpCardSize.minimum)
    }

    /// A remembered size from a larger display comes back clamped, not honoured.
    @Test func aRememberedSizeIsHeldToTodaysWindow() {
        let available = CGSize(width: 800, height: 560)
        #expect(HelpCardSize.clamped(CGSize(width: 1600, height: 1200), within: available) == available)
    }

    /// The floor is a real constraint on the default, not a number below every possible size.
    @Test func theFloorIsSmallerThanWhatTheCardOpensAt() {
        #expect(HelpCardSize.minimum.width < HelpCardSize.initial.width)
        #expect(HelpCardSize.minimum.height < HelpCardSize.initial.height)
    }

    /// The card still opens at the size it was fixed at before it could be resized — the whole
    /// claim that this change adds a feature without changing the default view.
    @Test func theCardStillOpensAtTheSizeItAlwaysHad() {
        #expect(HelpCardSize.initial == CGSize(width: 760, height: 520))
    }

    /// **The window's own floor can show the card's floor.** If the minimum were larger than the
    /// smallest window the app allows, the clamp would fight the window on every small display.
    @Test func theCardsFloorFitsTheWindowsFloor() {
        // `ContentView.chromedContent` pins the window to 810×560.
        let windowFloor = CGSize(width: 810, height: 560)
        #expect(HelpCardSize.minimum.width <= windowFloor.width)
        #expect(HelpCardSize.minimum.height <= windowFloor.height)
    }

    // MARK: The call site

    /// The rule is the one the card actually uses.
    ///
    /// A pure clamp with nobody calling it is one revert from being decoration, and this file
    /// would go on passing. Source-scanned because `HelpView` cannot be constructed in a test.
    @Test func theCardResolvesItsSizeThroughTheRule() throws {
        let source = try String(contentsOf: macAppDirectory().appendingPathComponent("HelpBook.swift"),
                                encoding: .utf8)
        let body = try declarationBody(of: "private var baseSize: CGSize", in: source)
        #expect(body.contains("HelpCardSize.clamped"),
                "the card no longer resolves its size through the clamp")
        // And the drag has no second source of truth for where it started — the defect the
        // derived base replaced was a captured start that outlived an interrupted gesture.
        #expect(!source.contains("dragStart"),
                "a drag-start is being captured again; base every drag on baseSize instead")
        let drag = try declarationBody(of: "private func apply(", in: source)
        #expect(drag.contains("HelpCardSize.resized"),
                "the drag no longer goes through the resize rule")
    }

    /// **The card really lays out at the size the rule gives it** — driven through a live
    /// `NSHostingView` rather than asserted about the rule alone.
    ///
    /// `fittingSize` is worth nothing against a `ScrollView`, which accepts any height it is
    /// offered — and this card is two of them. It means something here precisely because the frame
    /// is explicit: what is being checked is that the resolved size reaches `.frame(width:height:)`
    /// at all, which is the one step between the tested rule and the pixels.
    ///
    /// `defaultAppStorage` redirects the card's two `@AppStorage` values into a scratch suite. The
    /// test host IS the app, so without it this would read — and the commit path would write — the
    /// real preference of whoever is running the tests.
    @MainActor
    @Test func theCardLaysOutAtTheSizeTheRuleGivesIt() {
        let store = TestDefaults()
        defer { store.wipe() }
        store.defaults.set(1200.0, forKey: HelpCardSize.widthDefaultsKey)
        store.defaults.set(900.0, forKey: HelpCardSize.heightDefaultsKey)

        // Roomy: the remembered size is honoured as-is.
        let roomy = NSHostingView(rootView: HelpView(available: CGSize(width: 2000, height: 1400),
                                                     onClose: {})
            .defaultAppStorage(store.defaults))
        #expect(roomy.fittingSize == CGSize(width: 1200, height: 900))

        // Cramped: the same remembered size is held to what the window can show.
        let cramped = NSHostingView(rootView: HelpView(available: CGSize(width: 820, height: 600),
                                                       onClose: {})
            .defaultAppStorage(store.defaults))
        #expect(cramped.fittingSize == CGSize(width: 820, height: 600))

        // Smaller than the floor: the floor wins, and the card overflows rather than vanishing.
        let tiny = NSHostingView(rootView: HelpView(available: CGSize(width: 100, height: 100),
                                                    onClose: {})
            .defaultAppStorage(store.defaults))
        #expect(tiny.fittingSize == HelpCardSize.minimum)
    }

    /// And the grips are all wired, not just declared. A `HelpCardGrip` case with no handle is a
    /// side of the card that silently cannot be dragged.
    @Test func everyGripHasAHandleOnTheCard() throws {
        let source = try String(contentsOf: macAppDirectory().appendingPathComponent("HelpBook.swift"),
                                encoding: .utf8)
        let handles = try declarationBody(of: "private var resizeHandles: some View", in: source)
        for grip in HelpCardGrip.allCases {
            #expect(handles.contains(".\(grip)"), "no handle draws the \(grip) grip")
        }
    }
}
