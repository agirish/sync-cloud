import AppKit
import SwiftUI
import Testing
import Design
@testable import SyncCloud

/// Every provider's mark draws at the same cap height, so a column of them sits on one line.
///
/// **In the app target rather than in Design**, which is where the assertion has to live: the four
/// brand assets are in `MacApp/Assets.xcassets`, so from the `Design` test target `NSImage(named:)`
/// finds none of them, `ProviderLogo` falls through to its SF Symbol branch, and every measurement
/// here would be of something else.
///
/// **Measured, because the numbers are the whole argument.** `ProviderLogo(_:size:)` fits each mark
/// inside a square, and these four assets are not one shape: at `size: 24` iCloud's cloud and
/// OneDrive's come out **24×16** while Drive's triangle and Dropbox's box come out **24×22**. The
/// clouds are half again as wide as they are tall, so they meet the box's width first and stop 6pt
/// short of its height, 3pt below its top edge. A list carrying all four draws two marks at one
/// size and two at another, on two different lines — which is exactly what it looked like.
@MainActor
@Suite struct ProviderMarkColumnTests {

    static let assets = ["icloud", "googledrive", "dropbox", "onedrive"]

    /// The ink box of one mark, in points, rendered in a generous frame so nothing is cropped.
    private func ink(_ view: some View, box: CGSize) throws -> (width: CGFloat, height: CGFloat) {
        let host = NSHostingView(rootView: view.frame(width: box.width, height: box.height))
        host.frame = CGRect(origin: .zero, size: box)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                               "the mark would not render — this measurement would be vacuous")
        host.cacheDisplay(in: host.bounds, to: rep)
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        try #require(maxX >= 0, "the mark drew no ink at all")
        let scale = CGFloat(rep.pixelsWide) / box.width
        return (CGFloat(maxX - minX + 1) / scale, CGFloat(maxY - minY + 1) / scale)
    }

    /// The cap-height mode puts every mark on one line.
    @Test func everyMarkSharesACapHeight() throws {
        let cap: CGFloat = 24
        let box = CGSize(width: cap * ProviderLogo.columnAspect + 20, height: cap + 20)
        var heights: [CGFloat] = []
        for asset in Self.assets {
            heights.append(try ink(ProviderLogo(asset, capHeight: cap), box: box).height)
        }
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        #expect(spread <= 1,
                "the four marks measure \(heights.map { ($0 * 10).rounded() / 10 }) — they do not share a line")
        #expect((heights.min() ?? 0) > cap * 0.9,
                "the marks measure \(heights) against a \(cap)pt cap — something is fitting on width")
    }

    /// **The control**: the square mode really does draw them at two different sizes, so the test
    /// above is measuring the fix rather than a property both modes already had.
    @Test func theSquareModeIsWhereTheyDisagree() throws {
        let size: CGFloat = 24
        let box = CGSize(width: size + 20, height: size + 20)
        var heights: [CGFloat] = []
        for asset in Self.assets {
            heights.append(try ink(ProviderLogo(asset, size: size), box: box).height)
        }
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
        #expect(spread >= 4,
                "the square mode measures \(heights) — if these now agree, the assets changed and the cap-height mode may no longer be needed")
    }

    /// The column is wide enough for the widest mark, so nothing overflows into its neighbour.
    @Test func theColumnHoldsTheWidestMark() throws {
        let cap: CGFloat = 24
        let box = CGSize(width: cap * ProviderLogo.columnAspect + 20, height: cap + 20)
        for asset in Self.assets {
            let width = try ink(ProviderLogo(asset, capHeight: cap), box: box).width
            #expect(width <= cap * ProviderLogo.columnAspect + 0.5,
                    "\(asset) draws \(width)pt wide in a \(cap * ProviderLogo.columnAspect)pt column")
        }
    }
}
