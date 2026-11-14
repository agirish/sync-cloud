import SwiftUI

/// The app-wide text size, independent of `ListDensity`: density decides how tightly rows pack,
/// this decides how large the type is. Stored under `FontSize.defaultsKey`.
///
/// macOS has no Dynamic Type: an app-wide `.dynamicTypeSize`, even `.accessibility3`, renders
/// identically, and `.environment(\.font,)` only reaches views that set no font, while nearly
/// every text view here sets one. So the size is threaded through the app's own font call sites,
/// via `ScaledFont` and `View.scaledFont(_:)`. The range is bounded so both ends stay legible.
///
/// Known limit: AppKit-drawn controls don't follow this. A `Button` on `.bordered`,
/// `.borderedProminent` or the default style takes its label font from the control size and
/// ignores the SwiftUI font, and nothing outside the control can change that (see
/// `HoverAffordanceStyle`). The app draws nearly all its own chrome, so only a few controls keep
/// the system's metrics.
public struct FontSize: Hashable, Identifiable, Sendable {

    /// The percentage this size applies at and below the `knee`, 90 through 135. The stored value,
    /// an integer so the readout's 115% is exactly what is persisted.
    public let percent: Int

    /// The smallest selectable size. Below it, the 9–11pt fonts already sit on `legibilityFloor`,
    /// so going further would shrink only the large text and flatten the hierarchy.
    public static let minimumPercent = 90

    /// The largest selectable size, and a hard constraint. A line of system text is 18pt tall up to
    /// 14.85pt and 19pt from 15pt, and header chrome fits 11pt text into pinned 28pt rows with
    /// exactly 18pt to spare (the count pill's inset age capsule would reach 29). So `knee`-sized
    /// text must stay under 15pt; 136% reaches 14.96, 137% 15.07, and 135 is the round number
    /// under. `everySelectablePercentKeepsChromeUnderTheCliff` sweeps the whole range.
    public static let maximumPercent = 135

    /// The slider's increment: a 1% change moves 11pt row text by 0.11pt, which nobody chooses on
    /// purpose. `init(percent:)` clamps but doesn't round, so the step constrains the control, not
    /// the value.
    public static let step = 5

    /// Clamps to the selectable range. Doesn't snap to `step`, so a value restored from disk is
    /// honoured as written.
    public init(percent: Int) {
        self.percent = Swift.min(Swift.max(percent, Self.minimumPercent), Self.maximumPercent)
    }

    // MARK: - The named presets

    /// The four sizes that carry names: the slider's detents and the vocabulary Help uses.
    /// Everything between them is reachable but unnamed.
    public static let small = FontSize(percent: 90)
    /// The default: every font renders at its own size (see `ScaledFont.resolved(scale:)`).
    public static let medium = FontSize(percent: 100)
    public static let large = FontSize(percent: 125)
    public static let extraLarge = FontSize(percent: 135)

    /// The named presets in ascending order: the sizes the UI offers by name.
    public static let allCases: [FontSize] = [.small, .medium, .large, .extraLarge]

    /// Every value the slider can land on, ascending.
    ///
    /// Derived, not listed. The control takes a range and step; this lets the guards ask about
    /// the whole set: `everySelectablePercentKeepsChromeUnderTheCliff` sweeps it, and
    /// `everyPresetIsDistinctAndReachable` checks the presets are on it.
    public static var selectablePercents: [Int] {
        Array(stride(from: minimumPercent, through: maximumPercent, by: step))
    }

    // MARK: - Stepping from the keyboard

    /// The next selectable size up, or `nil` at the top, which disables View ▸ Text Size ▸ Bigger.
    ///
    /// Through `selectablePercents`, never `percent + step`, so the keyboard lands only on the
    /// slider's stops, the range the Settings rail's version line was measured against (RELEASE.md,
    /// "The version line has a width budget"). A stored value between stops (`102`) steps to the
    /// nearest stop in that direction, not to `107`.
    public var bigger: FontSize? {
        Self.selectablePercents.first { $0 > percent }.map(FontSize.init(percent:))
    }

    /// The next selectable size down, or `nil` at the bottom: View ▸ Text Size ▸ Smaller's gate.
    public var smaller: FontSize? {
        Self.selectablePercents.last { $0 < percent }.map(FontSize.init(percent:))
    }

    // MARK: - Storage

    /// UserDefaults key for the selected size, read via `@AppStorage` by the Settings Appearance
    /// tab, the setup form and every window root.
    ///
    /// The key name predates the percentage type and must stay: a new key would silently reset
    /// every existing user's size. It holds an `Int` percentage; builds 4.2 through 7.0
    /// rewrote the old string values at launch.
    public static let defaultsKey = "fontSize"

    // MARK: - Identity and copy

    public var id: Int { percent }

    /// The name this size carries, or nil for a value between the presets.
    public var presetName: String? {
        switch percent {
        case Self.small.percent: return "Small"
        case Self.medium.percent: return "Default"
        case Self.large.percent: return "Large"
        // "Largest": the slider stops here, so the name explains the ceiling. The small end is
        // "Small", not "Compact", which names a row spacing one control below.
        case Self.extraLarge.percent: return "Largest"
        default: return nil
        }
    }

    /// What the control shows: the percentage, with the preset name when there is one.
    public var displayName: String {
        guard let presetName else { return "\(percent)%" }
        return "\(percent)% · \(presetName)"
    }

    /// Multiplier applied at and below the `knee`; above it growth is damped and then clamped
    /// (see `scaledPointSize(_:scale:)`), so this is a small-text boost, not a uniform zoom.
    ///
    /// The hard-to-read type is the 9–11pt secondary text and 10pt captions, so the boost goes
    /// there: at 1.25 a caption reaches 12.5pt and 13pt body only 14.75pt, while titles barely
    /// move. A flat 1.25 would push titles past 21pt and break the fixed chrome. Below 100% the
    /// multiply is flat, guarded by `legibilityFloor`.
    ///
    /// Exactly 1 at 100%, so `scaledPointSize(_:scale:)`'s `scale != 1` short-circuit keeps the
    /// default size byte-identical.
    public var scale: CGFloat { CGFloat(percent) / 100 }

    /// The point size below which text stops being comfortably readable. Scaling down never takes
    /// a font past it (see `scaledPointSize(_:scale:)`).
    public static let legibilityFloor: CGFloat = 9

    /// The base point size up to which the full multiplier applies when scaling up. 11pt, the
    /// app's row size: everything at or below it is the text the larger settings exist for. Above
    /// it each base point adds only `surplusSlope`, so titles get a token lift.
    public static let knee: CGFloat = 11

    /// How much of each base point above `knee` survives scaling up. Past the crossover (16.5pt at
    /// Large, 18.7pt at Largest) the clamp in `scaledPointSize(_:scale:)` keeps the font at its
    /// default size. Below 1 to compress the type ramp rather than magnify it; the clamp keeps
    /// every curve monotonic, so the hierarchy can't invert.
    public static let surplusSlope: CGFloat = 0.5

    /// The point size `base` renders at under `scale`.
    ///
    /// Scaling down is a multiply floored at `min(base, legibilityFloor)`: no font shrinks into
    /// illegibility, and one already below the floor (the 8pt badge glyphs) stays at its own size
    /// rather than growing, so Small never renders text bigger than Default.
    ///
    /// Scaling up is knee-shaped, since a flat multiply grows the text that needs it least: the
    /// full multiplier through `knee`, the surplus above at `surplusSlope`, and an outer `max` so
    /// no font renders below its default. The pieces meet continuously and never decrease in
    /// `base`, so the hierarchy can't invert.
    public static func scaledPointSize(_ base: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale != 1 else { return base }
        guard scale > 1 else { return max(base * scale, min(base, legibilityFloor)) }
        guard base > knee else { return base * scale }
        return max(base, knee * scale + (base - knee) * surplusSlope)
    }

    /// The size a box drawn around a scaled glyph should be at `scale`: `box` (the frame at the
    /// default size) held in the same proportion to its `basePoint` glyph as at 100%.
    ///
    /// A hard `.frame` around a `.scaledFont` glyph doesn't clip, so at larger sizes the glyph
    /// silently draws past its box. Through `scaledPointSize`, not `box * scale`: above `knee` the
    /// ramp clamps, and a flat multiply would grow a box whose glyph had stopped growing. Returns
    /// `box` exactly at `scale == 1`.
    ///
    /// - Note: This sizes a box around a glyph, not a hit target. A pointer doesn't grow with the
    ///   text size, so a frame whose job is to be clickable is right to be a constant, as long as
    ///   it still holds its glyph's ink at Largest.
    public static func scaledBox(_ box: CGFloat, basePoint: CGFloat, scale: CGFloat) -> CGFloat {
        guard basePoint > 0 else { return box }
        return box * scaledPointSize(basePoint, scale: scale) / basePoint
    }
}

// MARK: - Environment

private struct AppFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

public extension EnvironmentValues {
    /// The multiplier `View.scaledFont(_:)` applies. Defaults to 1, so a view tree that never opts
    /// in (a test host, a preview) renders unscaled.
    ///
    /// A custom key because it reaches inside a SwiftUI `Table`, where `defaultMinListRowHeight`,
    /// `controlSize` and the ambient `\.font` are dropped at the boundary (see `listDensity(_:)`).
    var appFontScale: CGFloat {
        get { self[AppFontScaleKey.self] }
        set { self[AppFontScaleKey.self] = newValue }
    }
}

public extension View {
    /// Publishes `size`'s scale to this subtree, so every `scaledFont(_:)` beneath it resizes.
    ///
    /// Applied at the root of each window, because the SwiftUI environment flows down a view tree,
    /// not across scenes.
    func appFontSize(_ size: FontSize) -> some View {
        environment(\.appFontScale, size.scale)
            // Also a scaled default font, for text that names none (a plain `Label` in a button, a
            // `TextField`'s contents), which would otherwise stay at 13pt while the rest grew.
            //
            // Only when scaling: writing even `.body` at the default size would replace SwiftUI's
            // implicit default for every unstyled control in the app.
            .transformEnvironment(\.font) { font in
                guard size.scale != 1 else { return }
                font = ScaledFont.body.resolved(scale: size.scale)
            }
    }

    /// Publishes the *persisted* size to this subtree, tracking changes live.
    ///
    /// The one line each window root adds. Unlike `AppAppearance` it can't be set once on `NSApp`:
    /// it rides the SwiftUI environment, so every scene opts in (the main window, Activity Log,
    /// Keyboard Shortcuts). Settings is an in-window overlay and inherits it.
    func appFontSizeFromSettings() -> some View {
        modifier(PersistedAppFontSize())
    }
}

/// Bridges the `@AppStorage` value into the environment, observed once per window so the picker
/// takes effect immediately.
private struct PersistedAppFontSize: ViewModifier {
    /// The default is a constant, deliberately: a tree pointed at a scratch suite must not pick up
    /// the developer's own size from `UserDefaults.standard`.
    @AppStorage(FontSize.defaultsKey) private var percent: Int = FontSize.medium.percent

    func body(content: Content) -> some View {
        content.appFontSize(FontSize(percent: percent))
    }
}

// MARK: - ScaledFont

/// A `Font` that has not been resolved yet, carrying enough of its own specification to be
/// re-created at another point size. `Font` is opaque (no point size can be read back out), so this
/// keeps both the original `Font` and the parts it was built from.
///
/// The API mirrors `Font`'s (`.caption`, `.system(size:weight:design:)`, `.weight(_:)`,
/// `.monospaced()`), so `.font(` → `.scaledFont(` is a rename the compiler checks.
public struct ScaledFont: Sendable {
    /// The exact `Font` the call site asked for, returned verbatim at scale 1, so the default size
    /// is literally the same value, not merely equivalent.
    private let base: Font
    /// Point size of `base`, the number the scale multiplies.
    private let pointSize: CGFloat
    /// Weight to re-apply when synthesizing: the text style's semantic weight (`.headline` is bold,
    /// `.caption2` medium), so a scaled headline doesn't come back regular.
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
    /// Scale 1 short-circuits to the original `Font`, so the default setting hands SwiftUI the
    /// identical value. Synthesis runs only at other sizes, which alone pay for a text style's
    /// slightly different leading.
    public func resolved(scale: CGFloat) -> Font {
        guard scale != 1 else { return base }
        let font = Font.system(size: FontSize.scaledPointSize(pointSize, scale: scale),
                               weight: weight, design: design)
        return usesMonospacedDigits ? font.monospacedDigit() : font
    }
}

public extension ScaledFont {
    // MARK: Constructors mirroring `Font`

    /// `weight` and `design` are optional and forwarded as given, because `Font` tells
    /// "unspecified" from "explicitly the default": `.system(size: 11)` and
    /// `.system(size: 11, weight: .regular, design: .default)` render alike but aren't `==`.
    /// Forwarding keeps `resolved(scale: 1)` the identical value.
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
/// fonts: these numbers are the part an OS update could invalidate.
extension ScaledFont {
    /// Builds a text-style `ScaledFont` from the semantic style and its measured metrics.
    static func style(_ style: Font.TextStyle, base: Font) -> ScaledFont {
        let metrics = metrics(for: style)
        return ScaledFont(base: base, pointSize: metrics.size, weight: metrics.weight,
                          design: .default)
    }

    /// The point size and weight macOS resolves each text style to. The point size and weight macOS
    /// resolves each text style to.
    ///
    /// Hardcoded rather than read from `NSFont.preferredFont(forTextStyle:)` so they are
    /// deterministic; macOS has no Dynamic Type, so they don't vary per user.
    /// `FontSizeTests.textStyleMetricsMatchTheSystem` pins them against the live `NSFont` values
    /// and a rendered width per weight, so an OS change fails the suite instead of silently
    /// re-weighting scaled text.
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
/// Kept beside `resolved(scale:)` because `Font` is opaque: nothing outside this file can recover
/// the point size and weight a `ScaledFont` was built from, and a measurement that restated them
/// could drift from the drawn text.
public extension ScaledFont {
    /// The point size this renders at under `scale` — what an `NSImageSymbolConfiguration` needs.
    func pointSize(scale: CGFloat) -> CGFloat {
        FontSize.scaledPointSize(pointSize, scale: scale)
    }

    /// The `NSFont` this resolves to at `scale`.
    ///
    /// Both halves of a font's identity must survive, and getting one right can silently drop the
    /// other:
    ///
    /// **The digit width.** "1" is 5.93pt proportional and 7.87pt monospaced-digit, so a count pill
    /// measured in the wrong face is out by 2pt per digit.
    ///
    /// **The face.** A `.rounded` font must not measure in the default face (SF Rounded is narrower
    /// than SF Pro). `Font.monospacedDigit()` preserves the design, so design and digits are
    /// composed here rather than one path winning:
    ///
    /// - `.monospaced` answers a digit request on its own (the whole face is fixed-pitch), so it
    ///   wins outright; `monospacedDigitSystemFont` would give the proportional face with
    ///   equal-width digits. It keeps `NSFont.monospacedSystemFont` rather than the descriptor
    ///   transform below, which measures the same but mints a font that is `!=` the canonical one
    ///   at most weights. `LabelMetrics` keys its caches on `NSFont`, so that would be a permanent
    ///   cache miss.
    /// - `.rounded` and `.serif` are a descriptor transform on top of whichever base the digit flag
    ///   chose. `withDesign` carries the number-spacing feature across, so the digits stay
    ///   equal-width. Every combination was checked against a hosted `Text`.
    /// - `.serif` is drawn nowhere yet, but is handled so it can't miss the way `.rounded` would.
    ///   The `default:` below is `.default` and nothing else.
    func nsFont(scale: CGFloat) -> NSFont {
        let size = pointSize(scale: scale)
        let appKitWeight = Self.appKitWeight(weight)
        if case .monospaced = design {
            return NSFont.checkedMonospacedSystemFont(ofSize: size, weight: appKitWeight)
        }
        // Digits first, then the design on top. Every fallback below returns `base`, already the
        // digits font, so a face this Mac lacks costs the design, never the digit width.
        let base = usesMonospacedDigits
            ? NSFont.checkedMonospacedDigitSystemFont(ofSize: size, weight: appKitWeight)
            : NSFont.systemFont(ofSize: size, weight: appKitWeight)
        guard let systemDesign = Self.systemDesign(design) else { return base }
        // `withDesign` returns nil if the face is unavailable; the base face is the honest fallback.
        guard let descriptor = base.fontDescriptor.withDesign(systemDesign),
              let designed = NSFont(descriptor: descriptor, size: size) else { return base }
        return designed
    }

    /// The AppKit design `design` names, or nil when there is no face to switch to.
    ///
    /// `.monospaced` is handled by `nsFont` before this (it needs the whole face, not a transform
    /// of the digits font) but is listed so this stays a total answer. `.default` and any future
    /// design return nil and measure in the default face.
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
    /// For labels that feed AppKit-backed chrome, a `Menu`'s label above all. These honour only a
    /// plain `Text`: wrapped in a modifier (as `View.scaledFont(_:)` must be, to read the
    /// environment), AppKit drops the caller's font and foreground style for its own.
    ///
    /// The scale is passed in because a `Text` method can't read the environment. Callers hold it
    /// with `@Environment(\.appFontScale)`.
    func scaledFont(_ font: ScaledFont, scale: CGFloat) -> Text {
        self.font(font.resolved(scale: scale))
    }
}

/// Reads the scale from the environment so the font re-resolves when the setting changes, which
/// a plain `.font(font.resolved(scale:))` at the call site couldn't.
private struct ScaledFontModifier: ViewModifier {
    @Environment(\.appFontScale) private var scale
    let font: ScaledFont

    func body(content: Content) -> some View {
        content.font(font.resolved(scale: scale))
    }
}

// MARK: - The monospaced face, checked

public extension NSFont {
    /// `monospacedSystemFont(ofSize:weight:)`, safe for the time it answers nil. AppKit declares it
    /// non-null and Swift trusts that, but it can answer nil: a nil in an attribute dictionary
    /// (such as `CommandPaletteBarMetrics.keycapWidth`'s) makes CoreText throw and the app abort.
    /// The cause is unknown and it is rare. Every `monospacedSystemFont` call outside the tests
    /// goes through here.
    static func checkedMonospacedSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        fallingBack(from: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
                    size: size, weight: weight)
    }

    /// `monospacedDigitSystemFont(ofSize:weight:)`, safe the same way: also declared non-null, and
    /// its answer goes into the same attribute dictionaries, where a nil aborts the app.
    static func checkedMonospacedDigitSystemFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        fallingBackToDigits(from: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
                            size: size, weight: weight)
    }
}

extension NSFont {
    /// `answer`, or the closest face to it when AppKit's non-null answer was nil. Split out so a
    /// test can pass that nil without swizzling AppKit under every suite beside it.
    ///
    /// **The bit-cast is required.** `answer` is non-optional, so `let font: NSFont? = answer` is
    /// `.some` by type and `-O` folds the check away; only the cast sees the nil.
    ///
    /// Fallbacks, closest first: the same face through its descriptor, which measures exactly the
    /// same (under-measuring the keycap folds the toolbar behind its chevron); then the user's
    /// fixed-pitch font, slightly narrower but keeping the editor's columns and the diff gutter's
    /// digits aligned; last the system face, unchecked, with nothing left to fall back to.
    static func fallingBack(from answer: NSFont, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let font = unsafeBitCast(answer, to: NSFont?.self) { return font }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.monospaced),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont.userFixedPitchFont(ofSize: size) ?? base
    }

    /// `answer`, or the system face with equal-width digits asked of its descriptor, when AppKit's
    /// non-null answer was nil, bit-cast to check as ``fallingBack(from:size:weight:)`` is. The
    /// plain system face is last: proportional digits, but it draws.
    static func fallingBackToDigits(from answer: NSFont, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if let font = unsafeBitCast(answer, to: NSFont?.self) { return font }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let digits = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: digits, size: size) ?? base
    }
}
