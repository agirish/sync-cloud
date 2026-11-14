import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SyncCloud

/// The Help card's resize rule. The card is centred, so adding the translation to the width is
/// wrong by a factor of two and reads as lag: the grip drifts at half the pointer's speed.
/// `HelpView` can't be built in a test, so the rule is a type of its own.
@Suite struct HelpCardSizeTests {
    static let room = CGSize(width: 2000, height: 1400)

    // MARK: The doubling

    /// `(grip, drag, size)` from 760×520. On a centred card a 10pt drag of an edge is 20pt of size;
    /// opposite edges mirror; a corner moves each axis by its own translation.
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

    /// Every grip moves exactly the axes it names, walked over `allCases` so a new grip needs an
    /// answer here.
    @Test func everyGripMovesTheAxesItsNameClaims() {
        for grip in HelpCardGrip.allCases {
            let start = CGSize(width: 760, height: 520)
            let out = HelpCardSize.resized(from: start, by: CGSize(width: 10, height: 10),
                                           grip: grip, within: Self.room)
            let movedWidth = out.width != start.width
            let movedHeight = out.height != start.height
            #expect(movedWidth == (grip.horizontal != 0), "\(grip) moved width when it should not, or did not when it should")
            #expect(movedHeight == (grip.vertical != 0), "\(grip) moved height wrongly")
            #expect(grip.horizontal != 0 || grip.vertical != 0, "\(grip) moves nothing at all")
        }
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

    /// The first layout pass reports `.zero`; clamping to it would collapse the card on the frame it
    /// appears. Fails if `max(minimum, available)` becomes plain `available`.
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

    /// The card opens at its long-standing default size.
    @Test func theCardStillOpensAtTheSizeItAlwaysHad() {
        #expect(HelpCardSize.initial == CGSize(width: 760, height: 520))
    }

    /// The card's floor fits the window's: a larger minimum would make the clamp fight the window on
    /// every small display.
    @Test func theCardsFloorFitsTheWindowsFloor() throws {
        // The window's own `.frame(minWidth:minHeight:)`, read from `ContentView`, not a copy of it.
        let floors = argumentLists(of: "frame", in: sourceCodeOnly(try macAppFile("ContentView.swift")))
            .map(CallArguments.init).filter { $0.value("minHeight") != nil }
        try #require(floors.count == 1, "ContentView declares \(floors.count) minHeights — which is the window's?")
        let width = try #require(floors[0].value("minWidth").flatMap(Double.init), "the window's minWidth is not a literal")
        let height = try #require(floors[0].value("minHeight").flatMap(Double.init), "the window's minHeight is not a literal")
        #expect(HelpCardSize.minimum.width <= width)
        #expect(HelpCardSize.minimum.height <= height)
    }

    // MARK: The call site

    /// The card actually uses the rule; uncalled, this file would go on passing. Scanned, because
    /// `HelpView` can't be constructed in a test.
    @Test func theCardResolvesItsSizeThroughTheRule() throws {
        let source = try macAppFile("HelpBook.swift")
        let body = try declarationBody(of: "private var baseSize: CGSize", in: source)
        #expect(body.contains("HelpCardSize.clamped"),
                "the card no longer resolves its size through the clamp")
        // No second source of truth for where the drag started: a captured start can outlive an
        // interrupted gesture.
        #expect(!source.contains("dragStart"),
                "a drag-start is being captured again; base every drag on baseSize instead")
        let drag = try declarationBody(of: "private func apply(", in: source)
        #expect(drag.contains("HelpCardSize.resized"),
                "the drag no longer goes through the resize rule")
    }

    /// The card lays out at the rule's size in a live `NSHostingView`. `fittingSize` is worthless
    /// against a `ScrollView`, but the frame is explicit, so this checks the size reaches
    /// `.frame(width:height:)`. `defaultAppStorage` points `@AppStorage` at a scratch suite: the test
    /// host is the app and would otherwise read and write the real preference.
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
