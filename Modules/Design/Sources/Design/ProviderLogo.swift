import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A cloud provider's brand mark — the one place a provider logo is drawn.
///
/// Currently a plain image, and the value is the consolidation, not the drawing: this replaced
/// three hand-rolled `Image`+`resizable`+`scaledToFit`+`frame` stacks at three sizes (pane header
/// 28, Settings 26, single-source rail 16), which had to be edited in lockstep every time the mark's
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
    private let isMonochrome: Bool

    /// - Parameter monochrome: draws the mark as a template — its **shape** in whatever colour the
    ///   caller's `foregroundStyle` supplies, rather than its brand colours.
    ///
    ///   For the Browse sidebar, where a row is a line of text with a glyph and a full-colour badge
    ///   halfway down a quiet column would be the loudest thing on screen — Finder's own sidebar
    ///   draws every location in one ink for the same reason.
    ///
    ///   **The seams survive, which is what makes this worth doing at all.** These marks carry no
    ///   opaque near-white pixels (measured, all four): Dropbox's folded-box seams, Drive's triangle
    ///   joins and the gap between OneDrive's lobes are all *transparent*, supplied by the page
    ///   behind. A template render masks on alpha, so those gaps stay gaps and each mark keeps its
    ///   silhouette instead of flattening into a blob — the failure that would make this idea not
    ///   work. The same property is why a light plate was needed in dark mode; here it pays.
    public init(_ imageName: String, size: CGFloat, monochrome: Bool = false) {
        self.imageName = imageName
        self.size = size
        self.isMonochrome = monochrome
    }

    public var body: some View {
        if hasBundledAsset {
            Image(imageName)
                .resizable()
                // `.original` stated rather than left to the default, so the two modes read as one
                // choice at the call site instead of one branch and one absence.
                .renderingMode(isMonochrome ? .template : .original)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            // A source with no bundled brand mark — a local folder wears `folder.fill`. Rendering
            // the same field as a symbol (rather than adding a second, mutually-exclusive field to
            // `CloudProvider` that every construction site would have to get right) keeps one
            // "what mark does this source wear" answer, at all three call sites and all three
            // sizes.
            //
            // **Monochrome applies no style at all, rather than a different one.** The first cut
            // passed `.foreground` here and it was wrong in a way only rendering showed: an
            // explicit style *overrides* the caller's, so a `folder.fill` came out near-black in a
            // row of grey brand marks. Inheriting means the sidebar's own
            // `isCurrent ? accent : .secondary` reaches every mark, brand asset and symbol alike.
            let symbol = Image(systemName: imageName)
                .resizable()
                .scaledToFit()
                .fontWeight(.regular)
            Group {
                if isMonochrome {
                    symbol
                } else {
                    // A folder has no brand, and the app accent is spoken for — `ProviderHue.folder`
                    // uses it for the name, and two accents in one row read as one smear.
                    symbol.foregroundStyle(.secondary)
                }
            }
            // A symbol fills its frame edge-to-edge where a logo asset carries its own padding; at
            // 0.82 the folder sits on the same optical rung as the brand marks.
            .frame(width: size * 0.82, height: size * 0.82)
            .frame(width: size, height: size)
        }
    }

    /// Whether `imageName` names a bundled brand asset rather than an SF Symbol.
    ///
    /// `Image(_:)` on a missing asset renders an empty placeholder rather than failing, so the
    /// choice has to be made against the catalog before building the view. Resolved per render,
    /// which costs an `NSImage(named:)` lookup — the asset catalog memoizes those.
    private var hasBundledAsset: Bool {
        #if canImport(AppKit)
        NSImage(named: imageName) != nil
        #else
        true
        #endif
    }
}
