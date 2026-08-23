import AppKit
import SwiftUI
import Testing
@testable import Design

/// How a folder source is marked, as against a cloud account: a colourless hue rather than a brand
/// one, and an SF Symbol rather than a bundled logo.
@Suite struct FolderSourceMarkTests {

    // MARK: The hue

    /// A folder is called whatever its owner calls it, so the name cannot be classified — the flag
    /// short-circuits the match. This is the assertion with teeth: "Dropbox" and "My Drive" are
    /// ordinary folder names, and painting them in a brand's colours claims an account they aren't.
    @Test func aFolderIsColourlessWhateverItIsCalled() {
        for name in ["Projects", "Dropbox", "My Drive", "iCloud", "OneDrive backup", "", "Box"] {
            #expect(ProviderHue.classify(name, isLocalFolder: true) == .folder,
                    "a folder named \(name) must not be classified as a brand")
        }
    }

    /// The flag defaults off, so every pre-existing call site classifies exactly as it did.
    @Test func theFlagDefaultsOffAndLeavesNameMatchingAlone() {
        #expect(ProviderHue.classify("Dropbox") == .dropbox)
        #expect(ProviderHue.classify("Dropbox", isLocalFolder: false) == .dropbox)
        #expect(ProviderHue.classify("NAS") == .neutral)
    }

    /// Folder must not collapse into neutral. Neutral means "follows the app accent" and is what an
    /// unrecognized CLOUD provider gets; a folder painted the same is indistinguishable from a NAS
    /// someone named "Archive", which is the exact distinction this hue exists to draw.
    @Test func folderIsItsOwnHueDistinctFromNeutralAndEveryBrand() {
        #expect(ProviderHue.folder.tint != ProviderHue.neutral.tint)
        for hue in ProviderHue.allCases where hue != .folder && hue.brand != nil {
            #expect(ProviderHue.folder.tint != hue.tint, "folder shares a tint with \(hue)")
        }
    }

    /// The light column is where the brand hexes deliberately do NOT clear AA (they were picked on
    /// brand, and `ChromeInk` decides where they are allowed to be text). Graphite has no brand to
    /// be faithful to, so it is free to be legible — and being the only colourless one, it is the
    /// one most at risk of being read as disabled if it were any lighter.
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

    /// `ProviderLogo` takes one string and renders it as whichever it is — a bundled brand asset or
    /// an SF Symbol. That is what lets `CloudProvider.imageName` stay one field rather than becoming
    /// two mutually-exclusive ones every construction site would have to get right.
    ///
    /// **Measured in painted pixels, not in laid-out size.** `Image(_:)` on a MISSING asset renders
    /// an empty placeholder rather than failing, and the explicit frame reports the size asked for
    /// either way — so a size assertion here passes with the fallback deleted and nothing on
    /// screen. Only counting ink can tell the difference.
    @MainActor
    @Test(.machinePinned(.pixelSampling)) func aSymbolNameActuallyPaints() throws {
        let painted = try paintedFraction(ProviderLogo("folder.fill", size: 40))
        #expect(painted > 0.05,
                "folder.fill painted \(painted) of the frame — the SF Symbol fallback is not firing")
    }

    /// The other half of the seam: the name a cloud account carries must still paint.
    ///
    /// **This does not prove it took the asset path**, and cannot from here. The brand catalog
    /// lives in the app target, not in this test bundle, so `NSImage(named: "icloud")` is nil under
    /// `swift test` and this name goes down the *symbol* branch — where `icloud` happens to be a
    /// real SF Symbol and paints anyway. What it does pin is that no name a provider can carry
    /// comes out blank, which is the failure the branch could actually introduce. Which branch each
    /// name takes in the shipped app is a question for the app, and is checked there by eye.
    @MainActor
    @Test(.machinePinned(.pixelSampling)) func aCloudAccountsMarkStillPaints() throws {
        let painted = try paintedFraction(ProviderLogo("icloud", size: 40))
        #expect(painted > 0.05, "the icloud mark painted \(painted) of the frame")
    }

    /// The outer frame is the same whichever path is taken — that is what keeps the three call
    /// sites' 16/26/28pt layouts honest when a folder source appears among the cloud accounts.
    @MainActor
    @Test(.machinePinned(.layoutMetrics)) func bothPathsOccupyTheSameOuterFrame() {
        for name in ["folder.fill", "icloud"] {
            let host = NSHostingView(rootView: ProviderLogo(name, size: 26))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize == CGSize(width: 26, height: 26),
                    "\(name) laid out at \(host.fittingSize) instead of 26×26")
        }
    }

    /// The fraction of the frame carrying ink. Rendered through a real window: an `NSHostingView`
    /// with no window backing draws nothing at all, which would make every one of these pass-by-
    /// failing-to-paint.
    @MainActor
    private func paintedFraction(_ view: some View, side: CGFloat = 40) throws -> Double {
        let host = NSHostingView(rootView: AnyView(view.frame(width: side, height: side)))
        host.frame = CGRect(x: 0, y: 0, width: side, height: side)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

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
