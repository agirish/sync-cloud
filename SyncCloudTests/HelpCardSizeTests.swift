import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SyncCloud

/// The Help card's resize rule. The card is centred in its overlay, so "add the translation to the
/// width" is wrong by a factor of two, and reads as lag rather than a bug: the grip drifts at half
/// the pointer's speed. `HelpView` can't be built in a test, so the rule is a type of its own
/// rather than an untestable clamp inline.
@Suite struct HelpCardSizeTests {

    static let room = CGSize(width: 2000, height: 1400)

    // MARK: The doubling

    /// `(grip, drag, size)` from 760×520. Dragging the trailing edge 10pt right moves that edge
    /// 10pt right, which on a centred card is 20pt of width; the leading edge is the mirror, and
    /// top against bottom the same; a corner moves both, each axis by its own translation.
    @Test(arguments: [
        (HelpCardGrip.trailing, CGSize(width: 10, height: 0), CGSize(width: 780, height: 520)),
        (.leading, CGSize(width: 10, height: 0), CGSize(width: 740, height: 520)),
        (.bottom, CGSize(width: 0, height: 10), CGSize(width: 760, height: 540)),
        (.top, CGSize(width: 0, height: 10), CGSize(width: 760, height: 500)),
        (.bottomTrailing, CGSize(width: 10, height: 20), CGSize(width: 780, height: 560)),
    ])
    func aDragMovesTheGripItHasHoldOf(grip: HelpCardGrip, by drag: CGSize, expected: CGSize) {
        #expect(HelpCardSize.resized(from: CGSize(width: 760, height: 520), by: drag,
                                     grip: grip, within: Self.room) == expected)
    }

    /// Every grip moves exactly the axes it names. A walk over `allCases`, not eight assertions, so
    /// a ninth grip can't be added without an answer here.
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

    /// The first layout pass reports `.zero`, and clamping straight to it would collapse the card on
    /// the frame it appears. Changing `max(minimum, available)` to plain `available` must fail it.
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

    /// The card opens at its long-standing default size, so resizing doesn't change the default
    /// view.
    @Test func theCardStillOpensAtTheSizeItAlwaysHad() {
        #expect(HelpCardSize.initial == CGSize(width: 760, height: 520))
    }

    /// The window's own floor can show the card's floor. A minimum larger than the smallest window
    /// the app allows would make the clamp fight the window on every small display.
    @Test func theCardsFloorFitsTheWindowsFloor() {
        // `ContentView.chromedContent` pins the window to 760×560.
        let windowFloor = CGSize(width: 760, height: 560)
        #expect(HelpCardSize.minimum.width <= windowFloor.width)
        #expect(HelpCardSize.minimum.height <= windowFloor.height)
    }

    // MARK: The call site

    /// The rule is the one the card actually uses; uncalled, this file would go on passing. Scanned,
    /// because `HelpView` can't be constructed in a test.
    @Test func theCardResolvesItsSizeThroughTheRule() throws {
        let source = try macAppFile("HelpBook.swift")
        let body = try declarationBody(of: "private var baseSize: CGSize", in: source)
        #expect(body.contains("HelpCardSize.clamped"),
                "the card no longer resolves its size through the clamp")
        // The drag has no second source of truth for where it started: a captured start can
        // outlive an interrupted gesture.
        #expect(!source.contains("dragStart"),
                "a drag-start is being captured again; base every drag on baseSize instead")
        let drag = try declarationBody(of: "private func apply(", in: source)
        #expect(drag.contains("HelpCardSize.resized"),
                "the drag no longer goes through the resize rule")
    }

    /// The card really lays out at the size the rule gives it, in a live `NSHostingView`.
    /// `fittingSize` is worthless against a `ScrollView`, and the card holds two, but the frame is
    /// explicit, so this checks that the resolved size reaches `.frame(width:height:)` at all.
    /// `defaultAppStorage` redirects the card's `@AppStorage` into a scratch suite: the test host is
    /// the app, and would otherwise read and write the real preference.
    @MainActor
    @Test(.machinePinned(.layoutMetrics)) func theCardLaysOutAtTheSizeTheRuleGivesIt() {
        let store = TestDefaults()
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

    /// Every grip is wired, not just declared: a `HelpCardGrip` case with no handle is a side of the
    /// card that silently can't be dragged.
    @Test func everyGripHasAHandleOnTheCard() throws {
        let source = try macAppFile("HelpBook.swift")
        let handles = try declarationBody(of: "private var resizeHandles: some View", in: source)
        for grip in HelpCardGrip.allCases {
            #expect(handles.contains(".\(grip)"), "no handle draws the \(grip) grip")
        }
    }
}
