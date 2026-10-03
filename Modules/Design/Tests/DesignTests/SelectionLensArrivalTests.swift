import Testing
import AppKit
import SwiftUI
@testable import Design

/// RD46.11 — the path a count takes when it arrives, and in reverse when it melts: from a seed at
/// the item's leading side, a little short of its place. Rendered at fixed points along the path,
/// so the shape is pinned without timing anything.
@MainActor
@Suite struct SelectionLensArrivalTests {

    static let canvas = CGSize(width: 120, height: 40)
    /// The badge stand-in: 40 × 20 at (40, 10), opaque magenta so its pixels can be counted.
    static let badge = CGRect(x: 40, y: 10, width: 40, height: 20)

    static func box(progress: Double) -> CGRect? {
        let view = ZStack(alignment: .topLeading) {
            Color.white
            Rectangle().fill(SelectionLensRule.probeColor)
                .frame(width: badge.width, height: badge.height)
                .modifier(SelectionLensArrival.Effect(progress: progress))
                .offset(x: badge.minX, y: badge.minY)
        }
        .frame(width: canvas.width, height: canvas.height)
        // Any pink at all — part-way, the badge is half transparent over white.
        return ProbeRig(view, size: canvas).box { r, g, b in r > 229 && b > 229 && g < 204 }
    }

    static func near(_ a: CGRect?, _ b: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(Pixel.same(a, b), "\(String(describing: a)) is not \(b)", sourceLocation: sourceLocation)
    }

    @Test(.machinePinned(.pixelSampling))
    func atRestTheBadgeIsWhereItAlwaysWas() {
        Self.near(Self.box(progress: 1), Self.badge)
    }

    @Test(.machinePinned(.pixelSampling))
    func atTheSeedItIsGone() {
        #expect(Self.box(progress: 0) == nil)
    }

    @Test(.machinePinned(.pixelSampling))
    func halfwayItIsSmallerAndShortOfItsPlaceGrowingFromItsLeadingEdge() {
        // Scale 0.7 about the leading edge, 5pt short: a fade alone would be the full 40 × 20.
        let s = SelectionLensMotion.seedScale + (1 - SelectionLensMotion.seedScale) * 0.5
        let w = Self.badge.width * s, h = Self.badge.height * s
        Self.near(Self.box(progress: 0.5),
                  CGRect(x: Self.badge.minX + SelectionLensArrival.seedOffset * 0.5,
                         y: Self.badge.midY - h / 2, width: w, height: h))
    }

    @Test func itMovesOnTheLensesClock() {
        #expect(SelectionLensArrival.change(reduceMotion: true) == nil)
        #expect(SelectionLensArrival.change(reduceMotion: false) != nil)
    }
}
