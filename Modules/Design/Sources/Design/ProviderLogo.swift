import SwiftUI

/// A cloud provider's brand mark — the one place a provider logo is drawn.
///
/// Currently a plain image, and the value is the consolidation, not the drawing: this replaced
/// three hand-rolled `Image`+`resizable`+`scaledToFit`+`frame` stacks at three sizes (pane header
/// 28, Settings 26, Tidy rail 16), which had to be edited in lockstep every time the mark's
/// presentation was tried.
///
/// It has been tried. These four assets share a property that only bites on a dark appearance:
/// measured at their rendered size, **not one of them paints a single opaque near-white pixel**
/// (0 of 113k-156k opaque, all four). The white in them — Dropbox's folded-box seams, Drive's
/// triangle seams, the gap between OneDrive's lobes — is transparent, supplied by the page behind.
/// Light mode supplies it; dark mode supplies nothing.
///
/// A light plate here was the obvious answer and was rejected on sight (`d9e9698`, reverted): a
/// near-white chip punched into a hue-washed dark header reads as a sticker stuck on the surface,
/// whatever it does for the seams. Note for whatever is tried next: **luminance is not the lever.**
/// Against a stable dark surface these marks measure 2.0-5.0:1 median, *better* than they do in
/// light mode, so brightening the artwork treats a symptom that was never there.
public struct ProviderLogo: View {
    private let imageName: String
    private let size: CGFloat

    public init(_ imageName: String, size: CGFloat) {
        self.imageName = imageName
        self.size = size
    }

    public var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
