import Testing
import SwiftUI
import AppKit
import Design
@testable import SyncCloud

/// **A provider mark drawn as a shape rather than a brand.**
///
/// The Browse sidebar wants each cloud distinguishable at a glance without putting five brand
/// colours down a column whose every other element is quiet — Finder draws its Locations in one ink
/// for the same reason. Two claims hold that up, and neither is visible in a build that compiles:
/// the mark loses its colour, and it *keeps its silhouette*.
///
/// **In the app target, not `Design`'s**, because the brand assets live in `MacApp/Assets.xcassets`:
/// from a package test `NSImage(named:)` finds nothing, `ProviderLogo` takes its SF-Symbol branch,
/// and every assertion below would pass while testing a fallback rather than a brand mark. The first
/// check is there to make that failure loud rather than silent.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct ProviderLogoMonochromeTests {

    static let marks = ["icloud", "dropbox", "googledrive", "onedrive"]

    /// The scan is looking at brand assets. Without this, a catalog that stopped shipping them
    /// would turn every test here into a statement about `folder.fill`.
    @Test func theBrandAssetsAreReachableFromThisTarget() {
        for name in Self.marks {
            #expect(NSImage(named: name) != nil,
                    "\(name) is not in this target's catalog — the tests below would measure an SF Symbol instead")
        }
    }

    private func render(_ name: String, monochrome: Bool) -> NSBitmapImageRep? {
        let size = CGSize(width: 32, height: 32)
        let view = ProviderLogo(name, size: 32, monochrome: monochrome)
            .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.4))
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
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

    /// **Monochrome means monochrome.** Every mark renders in one ink; the brand colours are gone.
    @Test func aMonochromeMarkCarriesNoColour() throws {
        for name in Self.marks {
            let rep = try #require(render(name, monochrome: true))
            #expect(maxChroma(rep) < 0.06,
                    "\(name) still carries colour in monochrome mode (max channel spread \(maxChroma(rep)))")
        }
    }

    /// And the control: the same marks in colour genuinely are coloured, so the check above is
    /// measuring the mode rather than an artwork that was grey all along.
    @Test func theSameMarksInColourAreColoured() throws {
        for name in Self.marks where name != "icloud" {
            let rep = try #require(render(name, monochrome: false))
            #expect(maxChroma(rep) > 0.2,
                    "\(name) has no colour even in colour mode — the monochrome assertion is vacuous")
        }
    }

    /// **The silhouette survives, which is the whole reason this works.** These marks carry no
    /// opaque near-white pixels — Dropbox's folded-box seams, Drive's triangle joins and the gap
    /// between OneDrive's lobes are *transparent*, supplied by the page behind. A template render
    /// masks on alpha, so those gaps stay gaps rather than filling in and flattening each mark to a
    /// blob.
    ///
    /// Asserted as ink coverage well under the full 32×32 box: a filled silhouette would approach
    /// it, and an empty render would be zero.
    @Test func aMonochromeMarkKeepsItsShapeRatherThanFillingItsBox() throws {
        let box = 32 * 32 * 4   // 2× backing store
        for name in Self.marks {
            let rep = try #require(render(name, monochrome: true))
            let ink = inked(rep)
            #expect(ink > box / 20, "\(name) rendered almost nothing (\(ink) of \(box) px)")
            #expect(ink < box * 3 / 4,
                    "\(name) fills \(ink) of \(box) px — its interior gaps closed up, so the mark is a blob")
        }
    }

    /// **The caller's tint reaches the mark**, which is what lets the sidebar accent the current row.
    /// The first cut set an explicit style inside the monochrome branch; rendering it showed a
    /// `folder.fill` coming out near-black in a row of grey brand marks, because an explicit style
    /// overrides the caller's rather than deferring to it.
    @Test func theCallersTintReachesBothKindsOfMark() throws {
        for name in Self.marks + ["folder.fill"] {
            let rep = try #require(render(name, monochrome: true))
            var darkest: CGFloat = 1
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    darkest = min(darkest, c.redComponent)
                }
            }
            // The supplied tint is 0.4 grey. A mark that ignored it and drew its own would come out
            // materially darker — `folder.fill` measured ~0.1 before the fix.
            #expect(darkest > 0.25,
                    "\(name) drew darker than the 0.4 tint it was given (\(darkest)) — it is overriding the caller's style")
        }
    }
}
