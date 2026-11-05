import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A cloud provider's brand mark, the one place a provider logo is drawn, so its sizes (pane
/// header, Settings, single-source rail) and modes change together. A mark inside an AppKit-drawn
/// label must be built differently or it draws at the asset's full 512pt (`inAppKitLabel`; see
/// the initializer).
///
/// These assets paint no opaque near-white pixels: the white in them (Dropbox's box seams, Drive's
/// triangle seams, the gap between OneDrive's lobes) is transparent, supplied by the page behind,
/// so a dark appearance shows dark there. A light plate behind them reads as a sticker on a
/// hue-washed dark header, and luminance is not the lever: on a stable dark surface the marks
/// measure 2.0–5.0:1 median, better than in light mode.
public struct ProviderLogo: View {
    private let imageName: String
    private let size: CGFloat
    /// The box's width. Equal to `size` for the square initializer; wider for `capHeight:`.
    private let width: CGFloat
    private let isMonochrome: Bool
    private let isInAppKitLabel: Bool

    /// - Parameter monochrome: draws the mark as a template, its shape in the caller's
    ///   `foregroundStyle` rather than its brand colours. For the Browse sidebar, where a
    ///   full-colour badge would be the loudest thing in a quiet column; Finder's sidebar draws
    ///   every location in one ink for the same reason. It works because the marks' seams are
    ///   transparent: a template masks on alpha, so the gaps stay gaps and each mark keeps its
    ///   silhouette.
    /// - Parameter inAppKitLabel: build the mark at a fixed intrinsic size instead of as a
    ///   resizable image in a frame, for a label AppKit draws rather than SwiftUI (a
    ///   `borderlessButton`-style `Menu`'s label, the only such caller).
    ///
    ///   A `.resizable()` image there ignores its frame and draws at the asset's native size, 512pt
    /// on the long edge, so a 15pt request takes the row apart (`MenuLabelMarkTests`). Instead the
    /// `NSImage` is copied and its own `size` set to the fitted box, so whoever draws it draws it
    /// at 15. **The copy is load-bearing:** `NSImage(named:)` returns the catalog's shared
    /// instance, and resizing that would resize every other mark in the app.
    ///
    ///   The SF Symbol branch needs none of this: a symbol isn't a catalog image and honours its
    /// frame in either context.
    public init(_ imageName: String, size: CGFloat, monochrome: Bool = false,
                inAppKitLabel: Bool = false) {
        self.imageName = imageName
        self.size = size
        self.width = size
        self.isMonochrome = monochrome
        self.isInAppKitLabel = inAppKitLabel
    }

    /// A mark fitted to a common cap height, in a column wide enough for the widest of them.
    ///
    /// `size:` fits a square, and the four marks aren't one shape: at `size: 24` the iCloud and
    /// OneDrive clouds come out 24×16 and Drive's triangle and Dropbox's box 24×22, so a column of
    /// them sits on two different lines. Fitting inside `capHeight * columnAspect` by `capHeight`
    /// fixes that without a per-asset table: a 1.5:1 cloud fills both, and a squarer mark fits on
    /// height and centres in the rest.
    public init(_ imageName: String, capHeight: CGFloat, monochrome: Bool = false) {
        self.imageName = imageName
        self.size = capHeight
        self.width = capHeight * Self.columnAspect
        self.isMonochrome = monochrome
        self.isInAppKitLabel = false
    }

    /// How much wider than tall the mark column is — the aspect of the widest asset, measured.
    /// iCloud's and OneDrive's are 1.5:1; Drive's and Dropbox's are near 1.1:1.
    public static let columnAspect: CGFloat = 1.5

    /// Hidden from VoiceOver here, once for every caller: the mark is decoration beside the
    /// source's name, and an asset image read aloud is its catalog name ("onedrive", "google drive
    /// logo").
    public var body: some View {
        mark.accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
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
            // A source with no bundled brand mark (a local folder wears `folder.fill`) is the same
            // field drawn as a symbol, so `CloudProvider` keeps one "what mark does this source
            // wear" answer rather than a second field every construction site must get right.
            //
            // Monochrome applies no style at all: an explicit style overrides the caller's, so the
            // folder would come out near-black among grey brand marks. Inheriting lets the
            // sidebar's own `isCurrent ? accent : .secondary` reach every mark, asset and symbol
            // alike.
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
            .frame(width: width, height: size)
        }
    }

    /// The brand mark as SwiftUI draws it everywhere but an AppKit-rendered label: resizable,
    /// fitted into the box the initializer chose — a `size` square, or a `capHeight` column.
    private var resizableAsset: some View {
        Image(imageName)
            .resizable()
            // `.original` stated rather than left to the default, so the two modes read as one
            // choice at the call site instead of one branch and one absence.
            .renderingMode(isMonochrome ? .template : .original)
            .scaledToFit()
            .frame(width: width, height: size)
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
