import Testing
import SwiftUI
import AppKit
import Design
@testable import SyncCloud

/// A provider mark drawn as a shape rather than a brand, so the Browse sidebar tells clouds apart
/// without a column of brand colours (Finder draws its Locations in one ink too). The mark must
/// lose its colour and keep its silhouette.
///
/// In the app target, not `Design`'s, because the brand assets live in `MacApp/Assets.xcassets`:
/// from a package test `NSImage(named:)` finds nothing and `ProviderLogo` falls back to an SF
/// Symbol. The first test makes that failure loud.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct ProviderLogoMonochromeTests {

    static let marks = ["icloud", "dropbox", "googledrive", "onedrive"]

    private func render(_ name: String, monochrome: Bool) throws -> NSBitmapImageRep {
        try renderInSRGBWindow(ProviderLogo(name, size: 32, monochrome: monochrome)
                                   .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.4))
                                   .frame(width: 32, height: 32)
                                   .background(Color.white),
                               size: CGSize(width: 32, height: 32), scheme: .light)
    }

    /// The largest gap between any pixel's colour channels — 0 for grey, large for a brand colour.
    private func maxChroma(_ rep: NSBitmapImageRep) -> CGFloat {
        var worst: CGFloat = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let channels = [c.redComponent, c.greenComponent, c.blueComponent]
                worst = max(worst, channels.max()! - channels.min()!)
            }
        }
        return worst
    }

    /// Pixels differing from the white ground — the mark's own ink.
    private func inked(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent < 0.9 || c.greenComponent < 0.9 || c.blueComponent < 0.9 { count += 1 }
            }
        }
        return count
    }

    /// Every mark renders in one ink in monochrome mode; the brand colours are gone.
    @Test func aMonochromeMarkCarriesNoColour() throws {
        for name in Self.marks {
            let rep = try render(name, monochrome: true)
            #expect(maxChroma(rep) < 0.06,
                    "\(name) still carries colour in monochrome mode (max channel spread \(maxChroma(rep)))")
        }
    }

    /// The control: the same marks in colour are coloured, so the check above measures the mode,
    /// not artwork that was grey all along.
    @Test func theSameMarksInColourAreColoured() throws {
        for name in Self.marks where name != "icloud" {
            let rep = try render(name, monochrome: false)
            #expect(maxChroma(rep) > 0.2,
                    "\(name) has no colour even in colour mode — the monochrome assertion is vacuous")
        }
    }

    /// The silhouette survives. The marks' inner gaps (Dropbox's seams, Drive's joins, OneDrive's
    /// lobes) are transparent, and a template render masks on alpha, so they stay gaps instead of
    /// filling in to a blob. Asserted as ink well under the 32×32 box and well above zero.
    @Test func aMonochromeMarkKeepsItsShapeRatherThanFillingItsBox() throws {
        let box = 32 * 32 * 4   // 2× backing store
        for name in Self.marks {
            let rep = try render(name, monochrome: true)
            let ink = inked(rep)
            #expect(ink > box / 20, "\(name) rendered almost nothing (\(ink) of \(box) px)")
            #expect(ink < box * 3 / 4,
                    "\(name) fills \(ink) of \(box) px — its interior gaps closed up, so the mark is a blob")
        }
    }

    /// The caller's tint reaches the mark, which lets the sidebar accent the current row. An
    /// explicit style inside the monochrome branch would override the caller's instead.
    @Test func theCallersTintReachesBothKindsOfMark() throws {
        for name in Self.marks + ["folder.fill"] {
            let rep = try render(name, monochrome: true)
            var darkest: CGFloat = 1
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    darkest = min(darkest, c.redComponent)
                }
            }
            // The tint is 0.4 grey; a mark drawing its own style comes out far darker (~0.1).
            #expect(darkest > 0.25,
                    "\(name) drew darker than the 0.4 tint it was given (\(darkest)) — it is overriding the caller's style")
        }
    }
}
