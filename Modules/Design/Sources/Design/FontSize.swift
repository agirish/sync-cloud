import SwiftUI

/// The app-wide text size, orthogonal to `ListDensity`: density decides how tightly rows *pack*,
/// this decides how large the type *is*. Stored in UserDefaults via `FontSize.defaultsKey`,
/// mirroring the other appearance options in `LiquidGlass`.
///
/// macOS has no Dynamic Type, so none of the system levers move SwiftUI text here: an app-wide
/// `.dynamicTypeSize` — even `.accessibility3` — renders byte-identical on macOS 15 (verified by
/// measuring `NSHostingView.fittingSize` across every `DynamicTypeSize` case; all 113×73).
/// `.environment(\.font,)` only supplies a *default* for views that set no font of their own, and
/// nearly every text view in SyncCloud sets one explicitly. So the size has to be threaded through
/// the app's own font call sites, which is what `ScaledFont` and `View.scaledFont(_:)` are for.
///
/// The steps are deliberately few and bounded rather than a free slider — both ends have to stay
/// legible, and the picker matches the segmented controls the rest of the Appearance tab uses.
///
/// KNOWN LIMIT — AppKit-drawn controls do not follow this. A `Button` on `.bordered`,
/// `.borderedProminent` or the default style is rendered by AppKit, which takes its label font
/// from the control size and ignores the SwiftUI font entirely: measured, such a button lays out
/// at 55×20 whether or not a 17pt font is applied, while the same label under a SwiftUI-drawn
/// style goes 40×16 → 51×20. Nothing outside the control can change that (`.controlSize` is
/// AppKit's own lever, and the call sites that set it mean it), and reaching around system chrome
/// from outside is a known dead end in this codebase — see `HoverAffordanceStyle`. SyncCloud draws
/// nearly all of its own chrome, so this affects only a handful of controls, which keep the
/// system's metrics while everything around them scales.
public enum FontSize: String, CaseIterable, Identifiable, Sendable {
    case small
    /// The app's unchanged default — every font renders exactly as it did before this setting
    /// existed (see `ScaledFont.resolved(scale:)`).
    case medium
    case large
    case extraLarge

    /// UserDefaults key for the selected size (raw value of `FontSize`). Read via `@AppStorage`
    /// by the Settings Appearance tab and by the root of every window — one shared constant so
    /// the setting has a single source of truth.
    public static let defaultsKey = "fontSize"

    /// The point size below which text stops being comfortably readable. Scaling *down* never
    /// takes a font past this (see `scaledPointSize(_:scale:)`), which is what keeps the small
    /// end legible no matter how small the original font was.
    public static let legibilityFloor: CGFloat = 9

    /// The persisted size, defaulting to `.medium` for a fresh install and for an unrecognized
    /// stored value.
    public static func resolved(_ defaults: UserDefaults = .standard) -> FontSize {
        FontSize(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .medium
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Larger"
        }
    }

    /// Multiplier applied to every font's point size.
    ///
    /// The range is chosen against the type actually in the app rather than picked round: the
    /// smallest fonts SyncCloud draws are 8–9pt badge glyphs and the workhorse sizes are 11–13pt,
    /// so 0.9 is as far down as the body text can go before the 11pt rows start to strain (and
    /// the floor protects the badges), while 1.3 lifts 11pt to 14.3pt and 13pt to 16.9pt — a
    /// clearly larger UI that still fits the fixed chrome. Anything past those ends stops being
    /// a readability setting and starts breaking layouts.
    public var scale: CGFloat {
        switch self {
        case .small: return 0.9
        case .medium: return 1.0
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .small: return "Slightly smaller text throughout SyncCloud, to fit more on screen."
        case .medium: return "The standard text size."
        case .large: return "Larger text throughout SyncCloud, for easier reading."
        case .extraLarge: return "The largest text size — noticeably bigger type everywhere."
        }
    }

    /// The point size `base` renders at under `scale`.
    ///
    /// Scaling up is a plain multiply. Scaling *down* is floored at `legibilityFloor`, so no font
    /// is ever shrunk into illegibility — that's the whole guarantee of the small end. The floor
    /// is `min(base, legibilityFloor)`, not `legibilityFloor` flat, because a font that already
    /// starts below the floor (the 8pt badge glyphs) must be left at its own size rather than
    /// *grown*: a "Small" setting that renders some text bigger than "Default" would be absurd.
    public static func scaledPointSize(_ base: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale != 1 else { return base }
        return max(base * scale, min(base, legibilityFloor))
    }
}

// MARK: - Environment

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

public extension EnvironmentValues {
    /// The multiplier `View.scaledFont(_:)` applies. Defaults to 1 (unscaled), so any view tree
    /// that never opts in — a test host, a preview — renders exactly as it always did.
    ///
    /// A custom environment value is what makes this work inside a SwiftUI `Table`, where the
    /// *built-in* text levers do not reach: `defaultMinListRowHeight`, `controlSize` and the
    /// ambient `\.font` are all dropped at the Table boundary (see `listDensity(_:)`), but a
    /// custom key propagates into the cell views normally — verified by reading it back from
    /// inside a realized `TableColumn` cell.
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

public extension View {
    /// Publishes `size`'s scale to this subtree, so every `scaledFont(_:)` beneath it resizes.
    ///
    /// Applied at the root of each window rather than once app-wide because SwiftUI environment
    /// flows down a view tree, not across scenes — the main window, Activity Log, Sync History,
    /// Keyboard Shortcuts and Settings each need it.
    func appFontSize(_ size: FontSize) -> some View {
        environment(\.appFontScale, size.scale)
            // Also supply a scaled *default* font, for the text that never names one — a plain
            // `Label` in a button, a `TextField`'s contents. Those have no `.scaledFont(_:)` call
            // site to migrate, so without this they would sit at 13pt while everything around
            // them grew (the Tidy card's action row did exactly that).
            //
            // Only when actually scaling. At the default size the environment font is left
            // untouched — writing even `.body` into it would replace SwiftUI's own implicit
            // default for every unstyled control in the app, which is precisely the kind of
            // silent shift the default size must not have.
            .transformEnvironment(\.font) { font in
                guard size.scale != 1 else { return }
                font = ScaledFont.body.resolved(scale: size.scale)
            }
    }

    /// Publishes the *persisted* size to this subtree, tracking changes live.
    ///
    /// The one line each window root adds. Unlike `AppAppearance`, this cannot be set once on
    /// `NSApp` and inherited — it rides the SwiftUI environment, so every scene has to opt in:
    /// the main window, Activity Log, Sync History and Keyboard Shortcuts. (Settings is an
    /// in-window overlay, so it inherits from the main window's root.)
    func appFontSizeFromSettings() -> some View {
        modifier(PersistedAppFontSize())
    }
}

/// Bridges the `@AppStorage` default into the environment. A modifier rather than a call at each
/// root so the storage is observed once per window and the picker takes effect immediately.
private struct PersistedAppFontSize: ViewModifier {
    @AppStorage(FontSize.defaultsKey) private var raw: String = FontSize.medium.rawValue

    func body(content: Content) -> some View {
        content.appFontSize(FontSize(rawValue: raw) ?? .medium)
    }
}

// MARK: - ScaledFont

/// A `Font` that has not been resolved yet, carrying enough of its own specification to be
/// re-created at another point size.
///
/// It exists because `Font` is opaque — there is no way to read a point size back out of one, so
/// a scaled variant cannot be derived from a `Font` value after the fact. `ScaledFont` therefore
/// keeps both the original `Font` *and* the parts it was built from.
///
/// The API deliberately mirrors `Font`'s own (`.caption`, `.system(size:weight:design:)`,
/// `.weight(_:)`, `.monospaced()`), which is what let the app's ~290 existing call sites migrate
/// as a pure `.font(` → `.scaledFont(` rename with the compiler checking every one: the argument
/// expressions type-check against `ScaledFont` exactly as they did against `Font`.
public struct ScaledFont: Sendable {
    /// The exact `Font` the pre-scaling code used. Returned verbatim at scale 1 so the default
    /// size is not merely equivalent to the old rendering but literally the same value.
    private let base: Font
    /// Point size of `base`, the number the scale multiplies.
    private let pointSize: CGFloat
    /// Weight to re-apply when synthesizing. Carries the *semantic* weight of a text style —
    /// `.headline` is bold and `.caption2` is medium (both measured, not assumed), and a scaled
    /// headline that came back regular would be a visible regression.
    private let weight: Font.Weight
    private let design: Font.Design
    /// Whether `.monospacedDigit()` was applied; re-applied after synthesis.
    private let usesMonospacedDigits: Bool

    private init(base: Font, pointSize: CGFloat, weight: Font.Weight,
                 design: Font.Design, usesMonospacedDigits: Bool = false) {
        self.base = base
        self.pointSize = pointSize
        self.weight = weight
        self.design = design
        self.usesMonospacedDigits = usesMonospacedDigits
    }

    /// The concrete `Font` for a given scale.
    ///
    /// Scale 1 short-circuits to the original `Font` rather than synthesizing an equivalent one.
    /// That is the correctness guarantee this whole type is built around: at the default setting
    /// the app cannot have shifted, because it is handing SwiftUI the identical value it did
    /// before. Synthesis only ever runs when the user has actually chosen another size, so a
    /// text style's slightly different leading is a cost paid only by the non-default sizes.
    public func resolved(scale: CGFloat) -> Font {
        guard scale != 1 else { return base }
        let font = Font.system(size: FontSize.scaledPointSize(pointSize, scale: scale),
                               weight: weight, design: design)
        return usesMonospacedDigits ? font.monospacedDigit() : font
    }
}

public extension ScaledFont {
    // MARK: Constructors mirroring `Font`

    /// `weight` and `design` are optional, and forwarded as given, precisely because `Font`
    /// distinguishes "unspecified" from "explicitly the default": `.system(size: 11)` and
    /// `.system(size: 11, weight: .regular, design: .default)` render identically but are not
    /// `==`. Passing them straight through is what makes `resolved(scale: 1)` return the very
    /// same `Font` value the pre-scaling call site built, not merely an equivalent one.
    static func system(size: CGFloat, weight: Font.Weight? = nil,
                       design: Font.Design? = nil) -> ScaledFont {
        ScaledFont(base: .system(size: size, weight: weight, design: design),
                   pointSize: size, weight: weight ?? .regular, design: design ?? .default)
    }

    static func system(_ style: Font.TextStyle, design: Font.Design? = nil,
                       weight: Font.Weight? = nil) -> ScaledFont {
        let metrics = Self.metrics(for: style)
        return ScaledFont(base: .system(style, design: design, weight: weight),
                          pointSize: metrics.size, weight: weight ?? metrics.weight,
                          design: design ?? .default)
    }

    // MARK: Text styles

    static let largeTitle = style(.largeTitle, base: .largeTitle)
    static let title = style(.title, base: .title)
    static let title2 = style(.title2, base: .title2)
    static let title3 = style(.title3, base: .title3)
    static let headline = style(.headline, base: .headline)
    static let subheadline = style(.subheadline, base: .subheadline)
    static let body = style(.body, base: .body)
    static let callout = style(.callout, base: .callout)
    static let footnote = style(.footnote, base: .footnote)
    static let caption = style(.caption, base: .caption)
    static let caption2 = style(.caption2, base: .caption2)

    // MARK: Modifiers mirroring `Font`

    func weight(_ weight: Font.Weight) -> ScaledFont {
        ScaledFont(base: base.weight(weight), pointSize: pointSize, weight: weight,
                   design: design, usesMonospacedDigits: usesMonospacedDigits)
    }

    func bold() -> ScaledFont { weight(.bold) }

    func monospaced() -> ScaledFont {
        ScaledFont(base: base.monospaced(), pointSize: pointSize, weight: weight,
                   design: .monospaced, usesMonospacedDigits: usesMonospacedDigits)
    }

    func monospacedDigit() -> ScaledFont {
        ScaledFont(base: base.monospacedDigit(), pointSize: pointSize, weight: weight,
                   design: design, usesMonospacedDigits: true)
    }
}

/// Internal, not private, so `FontSizeTests` can pin the metrics table against the live system
/// fonts — the numbers below are the one part of this type that an OS update could invalidate.
extension ScaledFont {
    /// Builds a text-style `ScaledFont` from the semantic style and its measured metrics.
    static func style(_ style: Font.TextStyle, base: Font) -> ScaledFont {
        let metrics = metrics(for: style)
        return ScaledFont(base: base, pointSize: metrics.size, weight: metrics.weight,
                          design: .default)
    }

    /// The point size and weight macOS resolves each text style to.
    ///
    /// Hardcoded rather than read from `NSFont.preferredFont(forTextStyle:)` so the numbers are
    /// deterministic and testable — macOS has no Dynamic Type, so they do not vary per user.
    /// `FontSizeTests.textStyleMetricsMatchTheSystem` pins them against the live `NSFont` values
    /// and against a rendered width per weight, so an OS change fails the suite instead of
    /// silently re-weighting scaled text.
    static func metrics(for style: Font.TextStyle) -> (size: CGFloat, weight: Font.Weight) {
        switch style {
        case .largeTitle: return (26, .regular)
        case .title: return (22, .regular)
        case .title2: return (17, .regular)
        case .title3: return (15, .regular)
        case .headline: return (13, .bold)
        case .subheadline: return (11, .regular)
        case .body: return (13, .regular)
        case .callout: return (12, .regular)
        case .footnote: return (10, .regular)
        case .caption: return (10, .regular)
        case .caption2: return (10, .medium)
        @unknown default: return (13, .regular)
        }
    }
}

/// The AppKit side of a `ScaledFont`, for measuring text without laying it out.
///
/// Kept next to `resolved(scale:)` rather than derived by a caller, and for the same reason the type
/// exists at all: `Font` is opaque, so nothing outside this file can recover the point size and
/// weight a `ScaledFont` was built from. A measurement that restated them would be a second opinion
/// about the font, and would keep agreeing with the drawn text only by luck.
public extension ScaledFont {
    /// The point size this renders at under `scale` — what an `NSImageSymbolConfiguration` needs.
    func pointSize(scale: CGFloat) -> CGFloat {
        FontSize.scaledPointSize(pointSize, scale: scale)
    }

    /// The `NSFont` this resolves to at `scale`.
    ///
    /// Both halves of a font's identity have to survive this, and the trap each time has been that
    /// getting one right silently dropped the other.
    ///
    /// **The digit width.** `monospacedDigitSystemFont` is not a nicety: measured, "1" is 5.93pt in
    /// the proportional face and 7.87pt in the monospaced-digit one, so a count pill measured with
    /// the wrong face is out by 2pt per digit.
    ///
    /// **The face.** `.rounded` had been falling through to `systemFont`, so a rounded font measured
    /// here silently reported the *default* face's width — "Birth Certificate" is 95.729pt in SF Pro
    /// and 92.917pt in SF Rounded, and the 95.7 figure reached a release-notes draft as the width of
    /// a row that draws `PaneRowFonts.name`, which is rounded.
    ///
    /// The fix for that left the same hole one level down, because `Font.monospacedDigit()`
    /// *preserves* the design: a font that was both went out through the digits path above the
    /// design switch and came back in the default face. "1234" at 16pt semibold — the shape the
    /// filing-spend totals draw — is 40.745pt that way against 42.042pt in the rounded face SwiftUI
    /// actually lays out. Hence design and digits are composed here rather than raced:
    ///
    /// - `.monospaced` answers a digit request on its own (the whole face is fixed-pitch), so it
    ///   wins outright. `monospacedDigitSystemFont` would give the *proportional* face with
    ///   equal-width digits — 41.0pt laid out for "1234" where the drawn text is 40.0pt, and the
    ///   wrong glyph for every letter besides. It keeps `NSFont.monospacedSystemFont` rather than
    ///   joining the descriptor transform below, which measures the same to the point that a width
    ///   assertion cannot tell them apart: the difference is object identity. `withDesign` mints a
    ///   font that is `!=` the canonical one at every weight but `.regular`, and `!=` its own
    ///   no-digits sibling at all of them — and `LabelMetrics` keys its caches on `NSFont`, so
    ///   that is a permanent miss rather than a cosmetic difference.
    /// - `.rounded` and `.serif` are a descriptor transform applied *on top of* whichever base the
    ///   digit flag chose. `withDesign` carries the descriptor's number-spacing feature across, so
    ///   the digits stay equal-width through it — measured, "1" and "0" are both 10.510pt in the
    ///   rounded 16pt semibold face. Every combination here was checked against a hosted `Text`.
    /// - `.serif` is in that list on purpose. Nothing in SyncCloud draws it today, so it is latent
    ///   rather than broken — but it is the same silent miss as `.rounded` was, and handling it
    ///   costs one line and measures right (`NewYork-Semibold`, 34.5pt laid out for "1234" against
    ///   38.0pt in the default face). The `default:` below is `.default` and nothing else.
    func nsFont(scale: CGFloat) -> NSFont {
        let size = pointSize(scale: scale)
        let appKitWeight = Self.appKitWeight(weight)
        if case .monospaced = design {
            return NSFont.monospacedSystemFont(ofSize: size, weight: appKitWeight)
        }
        // Digits first, then the design on top. The fallbacks below all return `base`, which is
        // already the digits font — so a face this Mac does not have costs the *design*, never the
        // digit-width guarantee that is the reason this branch exists.
        let base = usesMonospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: appKitWeight)
            : NSFont.systemFont(ofSize: size, weight: appKitWeight)
        guard let systemDesign = Self.systemDesign(design) else { return base }
        // `withDesign` returns nil if the face is unavailable; the base face is the honest fallback.
        guard let descriptor = base.fontDescriptor.withDesign(systemDesign),
              let designed = NSFont(descriptor: descriptor, size: size) else { return base }
        return designed
    }

    /// The AppKit design `design` names, or nil when there is no face to switch to.
    ///
    /// `.monospaced` is handled by `nsFont` before this is reached — it needs the whole face, not a
    /// transform of the digits font — but it is listed so this stays a total answer to the question
    /// it asks. `.default` and any design a future SDK adds return nil, which measures in the
    /// default face rather than guessing at a mapping.
    private static func systemDesign(_ design: Font.Design) -> NSFontDescriptor.SystemDesign? {
        switch design {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        default: return nil
        }
    }

    /// The symbol weight an `Image(systemName:)` drawn in this font renders at. No `scale`
    /// parameter: scaling changes a symbol's point size, never its weight.
    var symbolWeight: NSFont.Weight { Self.appKitWeight(weight) }

    /// `Font.Weight` is not enumerable, so this compares against its static members. Anything
    /// unrecognised falls back to `.regular`, which is what an unspecified weight renders as.
    private static func appKitWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

public extension View {
    /// Applies `font`, resized to the ambient `appFontScale`.
    ///
    /// The direct replacement for `.font(_:)` throughout SyncCloud. At the default size this is
    /// exactly `.font(_:)` with the same value (see `ScaledFont.resolved(scale:)`).
    func scaledFont(_ font: ScaledFont) -> some View {
        modifier(ScaledFontModifier(font: font))
    }
}

public extension Text {
    /// Applies `font` at `scale` while staying a `Text`.
    ///
    /// For the handful of labels that feed AppKit-backed chrome — a `Menu`'s label above all.
    /// Those render their label themselves and only honor a *plain* `Text`: wrapping it in a
    /// modifier (which `View.scaledFont(_:)` necessarily does, to read the environment) makes
    /// AppKit drop the caller's font AND foreground style and substitute its own. The pane
    /// header's provider name lost both its weight and its accent color exactly that way.
    ///
    /// The scale has to be passed in because a `Text` method cannot read the environment. Callers
    /// hold it with `@Environment(\.appFontScale)` and hand it over.
    func scaledFont(_ font: ScaledFont, scale: CGFloat) -> Text {
        self.font(font.resolved(scale: scale))
    }
}

/// Reads the scale from the environment so the font re-resolves when the setting changes —
/// a plain `.font(font.resolved(scale:))` at the call site could not, since the call sites are
/// not all views that observe the environment.
private struct ScaledFontModifier: ViewModifier {
    @Environment(\.appFontScale) private var scale
    let font: ScaledFont

    func body(content: Content) -> some View {
        content.font(font.resolved(scale: scale))
    }
}
