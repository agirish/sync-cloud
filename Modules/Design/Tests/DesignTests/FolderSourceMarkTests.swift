import AppKit
import SwiftUI
import Testing
@testable import Design

/// How a folder source is marked, as against a cloud account: a colourless hue rather than a brand
/// one, and an SF Symbol rather than a bundled logo.
@Suite struct FolderSourceMarkTests {

    // MARK: The hue

    /// A folder is called whatever its owner calls it, so the flag skips name matching. "Dropbox"
    /// and "My Drive" are ordinary folder names, and painting them in a brand's colours claims an
    /// account they aren't.
    @Test func aFolderIsColourlessWhateverItIsCalled() {
        for name in ["Projects", "Dropbox", "My Drive", "iCloud", "OneDrive backup", "", "Box"] {
            #expect(ProviderHue.classify(name, isLocalFolder: true) == .folder,
                    "a folder named \(name) must not be classified as a brand")
        }
    }

    /// The flag defaults off, so a call site that doesn't pass it keeps matching by name.
    @Test func theFlagDefaultsOffAndLeavesNameMatchingAlone() {
        #expect(ProviderHue.classify("Dropbox") == .dropbox)
        #expect(ProviderHue.classify("Dropbox", isLocalFolder: false) == .dropbox)
        #expect(ProviderHue.classify("NAS") == .neutral)
    }

    /// Folder must not collapse into neutral. Neutral follows the app accent and is what an
    /// unrecognized cloud provider gets; a folder painted the same can't be told from a NAS someone
    /// named "Archive", the very distinction this hue exists to draw.
    @Test func folderIsItsOwnHueDistinctFromNeutralAndEveryBrand() {
        #expect(ProviderHue.folder.tint != ProviderHue.neutral.tint)
        for hue in ProviderHue.allCases where hue != .folder && hue.brand != nil {
            #expect(ProviderHue.folder.tint != hue.tint, "folder shares a tint with \(hue)")
        }
    }

    /// The brand hexes don't all clear AA in light (they follow the brand, and `ChromeInk` decides
    /// where they may be text). Graphite has no brand to follow, so it can be legible, and as the
    /// only colourless hue it would read as disabled if it were any lighter.
    @Test func theFolderHueClearsAAAsTextInBothAppearances() {
        func contrast(_ a: ProviderHue.RGB, _ b: ProviderHue.RGB) -> Double {
            let (hi, lo) = (max(a.relativeLuminance, b.relativeLuminance),
                            min(a.relativeLuminance, b.relativeLuminance))
            return (hi + 0.05) / (lo + 0.05)
        }
        let brand = try! #require(ProviderHue.folder.brand)
        let onWhite = contrast(brand.light, ProviderHue.RGB(1, 1, 1))
        let onDark = contrast(brand.dark, ProviderHue.RGB(0.110, 0.118, 0.133))
        #expect(onWhite >= 4.5, "folder light tint is only \(onWhite):1 on white")
        #expect(onDark >= 4.5, "folder dark tint is only \(onDark):1 on the dark surface")
    }

    /// Colourless means colourless: the three channels stay within a hair of each other, or it has
    /// quietly become a hue and starts reading as one more brand.
    @Test func theFolderHueIsAchromatic() {
        for rgb in [ProviderHue.folder.brand!.light, ProviderHue.folder.brand!.dark] {
            #expect(max(rgb.r, rgb.g, rgb.b) - min(rgb.r, rgb.g, rgb.b) < 0.06,
                    "\(rgb) has a visible cast")
        }
    }

    // MARK: The mark

    /// `ProviderLogo` takes one string and renders it as whichever it is, a bundled brand asset or
    /// an SF Symbol, so `CloudProvider.imageName` stays one field instead of two exclusive ones.
    ///
    /// Measured in painted pixels, not laid-out size: `Image(_:)` on a missing asset renders an
    /// empty placeholder, and the explicit frame reports the requested size either way, so a size
    /// check would pass with the fallback deleted. Only counting ink tells the difference.
    @MainActor
    @Test(.machinePinned(.pixelSampling)) func aSymbolNameActuallyPaints() throws {
        let painted = try paintedFraction(ProviderLogo("folder.fill", size: 40))
        #expect(painted > 0.05,
                "folder.fill painted \(painted) of the frame — the SF Symbol fallback is not firing")
    }

    /// The other half: the name a cloud account carries must still paint.
    ///
    /// This can't prove the asset path was taken. The brand catalog lives in the app target, so
    /// under `swift test` `NSImage(named: "icloud")` is nil and the name goes down the symbol
    /// branch, where `icloud` is a real SF Symbol. It does pin that no provider's name comes out
    /// blank. Which branch each name takes in the shipped app is checked there by eye.
    @MainActor
    @Test(.machinePinned(.pixelSampling)) func aCloudAccountsMarkStillPaints() throws {
        let painted = try paintedFraction(ProviderLogo("icloud", size: 40))
        #expect(painted > 0.05, "the icloud mark painted \(painted) of the frame")
    }

    /// The outer frame is the same on either path, which keeps the call sites' 16/26/28pt layouts
    /// steady when a folder source appears among the cloud accounts.
    @MainActor
    @Test(.machinePinned(.layoutMetrics)) func bothPathsOccupyTheSameOuterFrame() {
        for name in ["folder.fill", "icloud"] {
            let host = NSHostingView(rootView: ProviderLogo(name, size: 26))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize == CGSize(width: 26, height: 26),
                    "\(name) laid out at \(host.fittingSize) instead of 26×26")
        }
    }

    /// The fraction of the frame carrying ink. Rendered through a real window, because an
    /// `NSHostingView` with no window draws nothing at all.
    @MainActor
    private func paintedFraction(_ view: some View, side: CGFloat = 40) throws -> Double {
        let rep = try #require(offscreenBitmap(AnyView(view.frame(width: side, height: side)),
                                               size: CGSize(width: side, height: side), appearance: nil, sRGB: false))

        var painted = 0
        var total = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                total += 1
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 { painted += 1 }
            }
        }
        return total == 0 ? 0 : Double(painted) / Double(total)
    }
}
