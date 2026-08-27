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
/// **That consolidation is what makes `inAppKitLabel` worth having as a mode rather than a fourth
/// hand-rolled stack.** A mark inside an AppKit-drawn label has to be built a different way or it
/// draws at the asset's full 512pt — see the initializer. Keeping that here means the fix is one
/// place rather than a rule every future call site has to know.
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
    private let isInAppKitLabel: Bool

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
    /// - Parameter inAppKitLabel: build the brand mark at a **fixed intrinsic size** instead of as a
    ///   resizable image inside a frame, for a label that AppKit rather than SwiftUI draws — the
    ///   label of a `Menu` in the `borderlessButton` style, which is the only such caller today.
    ///
    ///   A `.resizable()` image in one of those **ignores the frame around it and draws at the
    ///   asset's native size**. These assets are 512pt on their long edge, so the mark that asks for
    ///   15 comes out at 512 and takes the row apart around it. Measured on the real catalog
    ///   (`MenuLabelMarkTests`): 531pt of ideal width for a 15pt request, against 34 for this mode.
    ///
    ///   The fix is to leave nothing for the frame to be ignored *of*: the `NSImage` is copied and
    ///   its own `size` set to the fitted box, so the size is carried by the image rather than by a
    ///   modifier, and whoever does the drawing draws it at 15. **The copy is load-bearing** —
    ///   `NSImage(named:)` returns the catalog's shared instance, and resizing that one would resize
    ///   every other mark in the app.
    ///
    ///   The SF-Symbol branch needs none of this and is shared unchanged: a symbol is not a catalog
    ///   image and honours its frame in either context (measured, 37pt both ways).
    public init(_ imageName: String, size: CGFloat, monochrome: Bool = false,
                inAppKitLabel: Bool = false) {
        self.imageName = imageName
        self.size = size
        self.isMonochrome = monochrome
        self.isInAppKitLabel = inAppKitLabel
    }

    public var body: some View {
        if hasBundledAsset {
            #if canImport(AppKit)
            if isInAppKitLabel, let presized = presizedAsset {
                Image(nsImage: presized)
                    .renderingMode(isMonochrome ? .template : .original)
            } else {
                resizableAsset
            }
            #else
            resizableAsset
            #endif
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

    /// The brand mark as SwiftUI draws it everywhere but an AppKit-rendered label: resizable, fitted
    /// into a `size` square.
    private var resizableAsset: some View {
        Image(imageName)
            .resizable()
            // `.original` stated rather than left to the default, so the two modes read as one
            // choice at the call site instead of one branch and one absence.
            .renderingMode(isMonochrome ? .template : .original)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    /// A private copy of the brand asset carrying `size` as its own size, aspect preserved — the
    /// same box `scaledToFit()` into a `size` square produces, so the two modes draw the mark at the
    /// same scale. See `init(_:size:monochrome:inAppKitLabel:)` for why this exists at all, and why
    /// it must never touch the catalog's instance.
    #if canImport(AppKit)
    private var presizedAsset: NSImage? {
        guard let shared = NSImage(named: imageName),
              let copy = shared.copy() as? NSImage else { return nil }
        let native = copy.size
        guard native.width > 0, native.height > 0 else { return nil }
        let scale = size / max(native.width, native.height)
        copy.size = NSSize(width: native.width * scale, height: native.height * scale)
        return copy
    }
    #endif

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
