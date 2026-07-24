import SwiftUI
import AppKit

// MARK: - Liquid Glass Design (macOS 26–inspired)
// Uses materials + rounded corners + soft shadows on macOS 15.
// When targeting macOS 26+, consider switching to .glassEffect() for native Liquid Glass.

/// Popular hue options for the liquid glass background gradient.
public enum LiquidGlassHue: String, CaseIterable, Identifiable {
    /// No accent: neutral materials only, following the system accent color — the stock macOS look.
    case none
    case blue
    case cyan
    case teal
    case green
    case amber
    case coral
    case rose
    case purple
    case indigo
    case slate
    /// A true neutral gray — the monochrome accent. Unlike `.none` (no wash, controls follow the
    /// system accent) and `.slate` (a cool blue-gray), Graphite washes the surfaces in a colorless
    /// gray, for a fully monochrome-but-still-tinted look using the same machinery as every hue.
    case graphite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .teal: return "Teal"
        case .green: return "Green"
        case .amber: return "Amber"
        case .coral: return "Coral"
        case .rose: return "Rose"
        case .purple: return "Purple"
        case .indigo: return "Indigo"
        case .slate: return "Slate"
        case .graphite: return "Graphite"
        }
    }

    /// Accent color used for the hue selector swatch.
    public var accentColor: Color {
        switch self {
        // Defer to the system accent so controls keep the user's macOS accent color.
        case .none: return Color.accentColor
        case .blue: return Color(red: 0.2, green: 0.5, blue: 1.0)
        case .cyan: return Color(red: 0.25, green: 0.75, blue: 1.0)
        case .teal: return Color(red: 0.2, green: 0.65, blue: 0.65)
        case .green: return Color(red: 0.2, green: 0.7, blue: 0.5)
        case .amber: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .coral: return Color(red: 1.0, green: 0.45, blue: 0.4)
        case .rose: return Color(red: 0.95, green: 0.4, blue: 0.55)
        case .purple: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .indigo: return Color(red: 0.4, green: 0.35, blue: 0.9)
        case .slate: return Color(red: 0.4, green: 0.45, blue: 0.55)
        case .graphite: return Color(red: 0.53, green: 0.54, blue: 0.56)
        }
    }

    /// Three gradient stop colors (topLeading → bottomTrailing) for the app background.
    public var gradientColors: [Color] {
        switch self {
        case .none:
            // No color wash at all — the background is just the neutral material.
            return [.clear, .clear, .clear]
        case .blue:
            return [
                Color(red: 0.25, green: 0.75, blue: 1.0),
                Color(red: 0.15, green: 0.45, blue: 1.0),
                Color(red: 0.05, green: 0.25, blue: 0.85)
            ]
        case .cyan:
            return [
                Color(red: 0.35, green: 0.85, blue: 1.0),
                Color(red: 0.2, green: 0.7, blue: 0.95),
                Color(red: 0.1, green: 0.5, blue: 0.85)
            ]
        case .teal:
            return [
                Color(red: 0.25, green: 0.8, blue: 0.8),
                Color(red: 0.15, green: 0.6, blue: 0.65),
                Color(red: 0.08, green: 0.4, blue: 0.5)
            ]
        case .green:
            return [
                Color(red: 0.3, green: 0.85, blue: 0.6),
                Color(red: 0.2, green: 0.65, blue: 0.5),
                Color(red: 0.1, green: 0.45, blue: 0.4)
            ]
        case .amber:
            return [
                Color(red: 1.0, green: 0.75, blue: 0.35),
                Color(red: 0.95, green: 0.6, blue: 0.2),
                Color(red: 0.8, green: 0.45, blue: 0.1)
            ]
        case .coral:
            return [
                Color(red: 1.0, green: 0.55, blue: 0.5),
                Color(red: 0.95, green: 0.4, blue: 0.4),
                Color(red: 0.8, green: 0.25, blue: 0.35)
            ]
        case .rose:
            return [
                Color(red: 1.0, green: 0.5, blue: 0.65),
                Color(red: 0.9, green: 0.35, blue: 0.55),
                Color(red: 0.7, green: 0.2, blue: 0.5)
            ]
        case .purple:
            return [
                Color(red: 0.6, green: 0.45, blue: 1.0),
                Color(red: 0.45, green: 0.35, blue: 0.9),
                Color(red: 0.3, green: 0.2, blue: 0.75)
            ]
        case .indigo:
            return [
                Color(red: 0.45, green: 0.4, blue: 0.95),
                Color(red: 0.35, green: 0.3, blue: 0.85),
                Color(red: 0.2, green: 0.2, blue: 0.7)
            ]
        case .slate:
            return [
                Color(red: 0.5, green: 0.55, blue: 0.65),
                Color(red: 0.4, green: 0.45, blue: 0.55),
                Color(red: 0.25, green: 0.3, blue: 0.4)
            ]
        case .graphite:
            // A neutral gray triad — no hue, so the wash reads as a true colorless monochrome.
            return [
                Color(red: 0.6, green: 0.61, blue: 0.63),
                Color(red: 0.45, green: 0.46, blue: 0.48),
                Color(red: 0.29, green: 0.3, blue: 0.32)
            ]
        }
    }
}

/// How much the glass surfaces obscure what is behind them — the *material* half of the
/// Appearance model. Orthogonal to `SurfaceStyle`, which controls *shape*: any level can be
/// combined with any shape.
///
/// All three cases are Liquid Glass on macOS 26 except `.solid`. `.frosted` is `.regular`, the
/// standard system material (Control Center, the menu bar, Finder's sidebar) — translucent and
/// blurred, but content on top stays legible. `.clear` is the specialist variant: glass with no
/// frost, for surfaces sitting over the window's gradient rather than over content.
///
/// Replaces the old `liquidGlassIntensity` Double, which presented a 0–100% continuum over an
/// API that only has two states — every value below 0.33 rendered identically, as did every
/// value above it. Stored in UserDefaults via `LiquidGlass.levelKey`.
public enum GlassLevel: String, CaseIterable, Identifiable {
    /// Glass with no frost: the background reads straight through.
    case clear
    /// Standard Liquid Glass — translucent and blurred, legible on top.
    case frosted
    /// Opaque panels. The only case with no translucency at all.
    case solid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .frosted: return "Frosted"
        case .solid: return "Solid"
        }
    }

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .clear:
            return "Glass with no frost — the window's background reads through every surface."
        case .frosted:
            return "Standard Liquid Glass: translucent and blurred, with content on top staying legible."
        case .solid:
            return "Opaque panels for maximum readability, with no translucency."
        }
    }

    /// The level *overlay* cards render at — surfaces that sit over dense app content rather than
    /// the window's own background (Settings, Help, first-run, the operation banner). Clear glass
    /// over text is two layers of text competing — the Settings panel rendered at ~9% opacity
    /// before this floor existed. `.clear` resolves to `.frosted`; the others pass through, so
    /// applying it is a no-op everywhere except Clear. Only `glassCardStyle` consumes it: bars
    /// take the level verbatim and instead frost their *controls* (see `needsChromeFrosting`).
    ///
    /// Apple draws the same line: Control Center is glass but alerts are not.
    public var flooredForChrome: GlassLevel {
        self == .clear ? .frosted : self
    }

    /// Whether individual chrome elements — buttons and pills sitting on a card that takes the
    /// level verbatim — need a material of their own. A button's fill is a thin tint wash, so on
    /// see-through glass it has nothing to read against and stops looking like a control; the
    /// desktop showing through a `.clear` card is exactly that backdrop. `chromeButtonStyle` and
    /// `chromePillFrost` both key off this (and the tests pin it), so a level added later decides
    /// its chrome treatment here, in one place, rather than in scattered `== .clear` checks.
    public var needsChromeFrosting: Bool {
        self == .clear
    }

    /// Backdrop dimming behind an overlay. `.clear` deepens it so the app recedes further and the
    /// floored-to-frosted card reads cleanly against it — Apple's documented advice for `.clear`
    /// glass is to pair it with a dimming layer.
    public var overlayScrimOpacity: Double {
        self == .clear ? 0.55 : 0.35
    }

    /// Strength of the app background gradient, 0...1. `.frosted` keeps 0.65 — the old intensity
    /// slider's default — so migrating installs see an unchanged background. `.clear` drops the
    /// wash (nothing frosts it, so it would read as flat color), `.solid` maxes it (only the
    /// window edges show it at all).
    public var backgroundIntensity: Double {
        switch self {
        case .clear: return 0.0
        case .frosted: return 0.65
        case .solid: return 1.0
        }
    }

    /// Whether this level must draw its own hairline edge and drop shadow. Native Liquid Glass
    /// draws both itself; an opaque panel has neither, and so does the macOS 15 material fallback.
    public var needsExplicitChrome: Bool {
        if self == .solid { return true }
        if #available(macOS 26.0, *) { return false }
        return true
    }
}

/// How the content surfaces are *shaped* against the app's glass background — the other half of
/// the Appearance model, orthogonal to `GlassLevel`. Stored via `LiquidGlass.surfaceStyleKey`.
///
/// Formerly carried a third `solid` case, which was a material answer inside a shape control: it
/// silently overrode the glass setting, so "Solid" meant two different things in two pickers.
/// That case is now `GlassLevel.solid`; `LiquidGlass.migrateLegacyAppearance` moves stored values
/// across.
public enum SurfaceStyle: String, CaseIterable, Identifiable {
    /// The panes and the bottom workspace read as one continuous surface.
    case unified
    /// Each pane and the bottom workspace float as separate cards on the background.
    case cards

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unified: return "Unified"
        case .cards: return "Cards"
        }
    }

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .unified:
            return "The panes and the Differences area read as one continuous surface."
        case .cards:
            return "Each pane and the Differences area float as separate cards on the background."
        }
    }
}

public enum LiquidGlass {
    /// Corner radius for cards and floating panels.
    public static let cardCornerRadius: CGFloat = 14
    /// The gap between any two floating cards in Cards mode, and between a card and the window
    /// edge. One number for every gap on screen.
    ///
    /// It used to be the padding each card applied to *itself*, which made the gaps non-uniform by
    /// construction: two touching cards each contributed their own padding and so showed 2×, while
    /// a window edge showed 1×, and the bottom stack hard-coded a third value. At the old 3pt all
    /// three were too small to tell apart; raising it made every mismatch visible at once.
    ///
    /// Now `cardInset` is what a card pads itself by — half the gap — so two adjacent cards add up
    /// to exactly `cardGutter`, and the content root supplies the matching half at the window edge.
    /// Don't reintroduce per-container padding: that's what broke it.
    public static let cardGutter: CGFloat = 5

    /// What one card insets itself by, and what the content root pads by — half a gutter each, so
    /// every pairing (card↔card, card↔window edge) sums to `cardGutter`.
    public static var cardInset: CGFloat { cardGutter / 2 }

    /// The resting VISIBLE height of a header — the file panes' `PaneHeader` and the Tidy
    /// workspace's `LensHeaderCard` both land here, so the pane's header↔list boundary and the
    /// lens card's bottom edge sit on the same rule across the window.
    ///
    /// Both headers inset themselves by `cardInset`, so each occupies `headerHeight + 2 *
    /// cardInset` in its parent and its bottom edge falls at `cardInset + headerHeight` — 83.5.
    /// That shared line is the whole point of the constant; it was a coincidence of two intrinsic
    /// layouts before, which is why it kept drifting.
    ///
    /// `LensHeaderMetrics` derives its row geometry to match this, and both are asserted against
    /// the LAID-OUT `fittingSize` rather than against each other — a constant agreeing with
    /// itself proves nothing (see `4b1f611`).
    public static let headerHeight: CGFloat = 81
    /// Corner radius for smaller elements (badges, buttons, inputs).
    public static let smallCornerRadius: CGFloat = 10

    /// Soft shadow for glass cards to add depth without heaviness.
    public static let cardShadow = (color: Color.black.opacity(0.06), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(4))
    /// Lighter shadow for inline elements.
    public static let subtleShadow = (color: Color.black.opacity(0.04), radius: CGFloat(6), x: CGFloat(0), y: CGFloat(2))

    /// UserDefaults key for the selected `GlassLevel` (raw value).
    public static let levelKey = "glassLevel"

    /// UserDefaults key for the selected `AppearanceMode` (raw value) — light/dark/system.
    public static let appearanceModeKey = "appearanceMode"

    /// UserDefaults key for the retired `liquidGlassIntensity` Double. Read only by
    /// `migrateLegacyAppearance`, which clears it.
    public static let intensityKey = "liquidGlassIntensity"

    /// UserDefaults key for the selected liquid glass hue (raw value of `LiquidGlassHue`).
    public static let hueKey = "liquidGlassHue"

    /// UserDefaults key for the content surface style (raw value of `SurfaceStyle`).
    public static let surfaceStyleKey = "contentSurfaceStyle"

    /// UserDefaults key for the accent-color tint strength applied to surfaces (Double, 0...1).
    public static let tintKey = "contentSurfaceTint"

    /// Moves a pre-`GlassLevel` install onto the new two-control model. Idempotent: once
    /// `levelKey` is set this is a no-op, so it can run on every launch.
    ///
    /// Every stored intensity maps to `.frosted` rather than being read as a number. The old
    /// value can't be honored faithfully because it never had one meaning: `surfaceCard`
    /// hard-coded `.regular` and ignored it entirely, so the panes — the app's dominant surface —
    /// rendered frosted at *every* setting. Mapping to `.frosted` preserves what installs
    /// actually looked like, and matches the old slider's own 0.65 default.
    ///
    /// A stored `SurfaceStyle.solid` was a material choice, so it becomes `GlassLevel.solid` with
    /// the shape reset to `.unified` — which is what those installs already rendered, since the
    /// opaque fill hid whether cards were floating underneath.
    public static func migrateLegacyAppearance(_ defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: levelKey) == nil else { return }

        var level = GlassLevel.frosted
        if defaults.string(forKey: surfaceStyleKey) == "solid" {
            level = .solid
            defaults.set(SurfaceStyle.unified.rawValue, forKey: surfaceStyleKey)
        }
        defaults.set(level.rawValue, forKey: levelKey)
        defaults.removeObject(forKey: intensityKey)
    }
}

// MARK: - View Extensions

public extension View {
    /// Applies an app-level background that makes Liquid Glass visible by providing subtle
    /// color/content behind it.
    ///
    /// Routed through `LiquidGlassBackground` so it can read `@Environment(\.colorScheme)`: the
    /// shared light-tuned constants collapse to a flat gray slab on a dark appearance, so dark
    /// gets a deep graded near-black base *under* the material and a soft accent glow *over* it,
    /// and the accent diagonal lifts its opacity to survive the darker base. Light is unchanged.
    func liquidGlassAppBackground(level: GlassLevel, hue: LiquidGlassHue = .blue) -> some View {
        modifier(LiquidGlassBackground(level: level, hue: hue))
    }

    /// The material fill for one content surface. This is the single place the level → appearance
    /// decision is made: panes, the bottom workspace, bars and overlay chrome all route through
    /// it, so they can't drift apart the way they did when each call site mapped a raw intensity
    /// itself (the panes ignored it, the bottom workspace and the modals didn't).
    @ViewBuilder
    func glassSurface(_ level: GlassLevel, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch level {
        case .solid:
            self.background(Color(nsColor: .controlBackgroundColor), in: shape)
        case .clear, .frosted:
            if #available(macOS 26.0, *) {
                self.glassEffect(level == .frosted ? .regular : .clear, in: .rect(cornerRadius: cornerRadius))
            } else {
                self.background(level == .frosted ? Material.thinMaterial : Material.ultraThinMaterial, in: shape)
            }
        }
    }

    /// Frosted glass card style for floating overlay chrome (Settings, Help, the first-run card,
    /// the operation banner). Applies `flooredForChrome`, so a `.clear` app never produces an
    /// unreadable dialog — these are the only surfaces with live content behind them.
    ///
    /// The border + shadow route through `OverlayCardChrome` so dark can go bold: a top-lit white
    /// specular hairline and a deeper, larger shadow that lifts the card off the dimmed backdrop
    /// (the light-tuned `cardShadow` is nearly invisible on a dark scrim). Light keeps exactly its
    /// old chrome — the soft `cardShadow` on the explicit-chrome path, and nothing on native glass.
    @ViewBuilder
    func glassCardStyle(level: GlassLevel) -> some View {
        let resolved = level.flooredForChrome
        let radius = LiquidGlass.cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let chrome = OverlayCardChrome(cornerRadius: radius, lightShadow: resolved.needsExplicitChrome)
        // `.glassEffect` shapes only the effect, not the view's own backgrounds, and every caller
        // stacks `contentSurface`'s square tint wash under this — so clip either way, or it pokes
        // past the rounded corners at any Tint above zero (surfaceCard/bottomSectionCard do the
        // same). The explicit-chrome path clips *after* filling; native glass clips first. Kept as
        // two `@ViewBuilder` branches rather than an `AnyView` so the subtree keeps its structural
        // identity (an erased card re-renders whole on every parent update — e.g. the banner tick).
        if resolved.needsExplicitChrome {
            self.glassSurface(resolved, cornerRadius: radius).clipShape(shape).modifier(chrome)
        } else {
            self.clipShape(shape).glassSurface(resolved, cornerRadius: radius).modifier(chrome)
        }
    }

    /// Lighter glass style for bars and inline panels. These sit over the window's own background
    /// rather than over content, so they take the level verbatim — no floor. Dark adds a top-lit
    /// specular hairline (via `GlassBarStyle`) so the bar reads as distinct glass chrome against
    /// the deep background; light is unchanged.
    func glassBarStyle(level: GlassLevel) -> some View {
        modifier(GlassBarStyle(level: level))
    }

    /// The button style for a bar of controls, resolved from the level.
    ///
    /// At `.clear` the card behind these buttons is see-through to the desktop, and a bordered
    /// button's fill is too faint to survive that — the control stops reading as a control. Native
    /// Liquid Glass gives each button its own material instead, so the *card* stays clear and only
    /// the buttons frost. Everywhere else `.bordered` is untouched.
    ///
    /// Deliberately per-control rather than a frosted band behind the whole bar: a band would make
    /// the bar opaque, which is the transparency the level asked for being taken back.
    @ViewBuilder
    func chromeButtonStyle(_ level: GlassLevel) -> some View {
        if level.needsChromeFrosting, #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Gives a non-button chrome element (a status pill, a count badge) its own material at
    /// `.clear`, for the same reason as `chromeButtonStyle`: its fill is a thin tint wash, and on
    /// a see-through card there's nothing behind it to read against. No-op otherwise.
    @ViewBuilder
    func chromePillFrost(_ level: GlassLevel) -> some View {
        if level.needsChromeFrosting {
            self.background(.regularMaterial, in: Capsule(style: .continuous))
        } else {
            self
        }
    }

    /// The accent-color wash driven by the Tint slider (`tint`, 0...1). Applies to every shape and
    /// level. Apply it ONCE per region (don't stack it on nested views, or washes compound).
    ///
    /// The opaque base for `.solid` is no longer applied here — that moved to `GlassLevel`, which
    /// is where a material decision belongs. `SurfaceStyle` now only answers "one surface, or
    /// floating cards".
    @ViewBuilder
    func contentSurface(hue: LiquidGlassHue = .blue, tint: Double = 0) -> some View {
        // A transparent wash at tint 0, up to a clear-but-legible accent at tint 1. "None" gets no
        // wash at any tint: its accentColor falls back to the system accent (for controls), which
        // would repaint the surfaces with it here.
        let wash = hue == .none ? Color.clear : hue.accentColor.opacity(max(0.0, min(1.0, tint)) * 0.32)
        self.background(wash)
    }

    /// Floating-card decoration for the `.cards` shape: the level's fill, rounded corners, and an
    /// outer gutter so the background shows between cards. Native Liquid Glass draws its own edge
    /// and shadow; `.solid` and the macOS 15 fallback draw theirs explicitly.
    ///
    /// The hairline + shadow route through `DarkBoldCardChrome`: dark swaps the faint `.quaternary`
    /// edge for a top-lit white specular hairline and deepens the shadow so each card lifts off the
    /// deep background. Light is unchanged — the explicit-chrome path keeps its `.quaternary`
    /// hairline + soft shadow, native glass keeps neither.
    func surfaceCard(_ level: GlassLevel, cornerRadius: CGFloat = LiquidGlass.cardCornerRadius) -> some View {
        // Clip the content to the card shape first — the pane's contentSurface tint wash is a
        // square fill, and without this it pokes past the rounded corners into the gutters
        // (bottomSectionCard already clips the same way).
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let explicit = level.needsExplicitChrome
        return self.clipShape(shape)
            .glassSurface(level, cornerRadius: cornerRadius)
            .modifier(DarkBoldCardChrome(
                cornerRadius: cornerRadius,
                lightBorder: explicit, lightShadow: explicit, darkShadow: true))
            .padding(LiquidGlass.cardInset)
    }

    /// Wraps a file pane as a floating card for `.cards`; leaves it untouched otherwise.
    @ViewBuilder
    func paneCardIfNeeded(_ style: SurfaceStyle, level: GlassLevel) -> some View {
        if style == .cards { self.surfaceCard(level) } else { self }
    }

    /// Frames the whole panes region (both flush panes) so the top of the window reads as a
    /// bounded container — matching the clipped, hairline-outlined sections of the bottom
    /// workspace (`bottomSectionCard`). Applies to `.unified` only; in `.cards` each pane is
    /// already its own floating card (`paneCardIfNeeded`), so this is a no-op.
    ///
    /// The level supplies the fill: `.solid` needs an opaque base here (the panes' own
    /// `contentSurface` only paints the tint wash), while glass levels let the window background
    /// through, which is what "unified" means.
    @ViewBuilder
    func panesRegionFrame(_ style: SurfaceStyle, level: GlassLevel) -> some View {
        let radius = LiquidGlass.cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .cards:
            self
        case .unified:
            let based = level == .solid
                ? AnyView(self.glassSurface(.solid, cornerRadius: radius))
                : AnyView(self)
            based
                .clipShape(shape)
                .modifier(DarkBoldCardChrome(
                    cornerRadius: radius,
                    lightBorder: true, lightShadow: false, darkShadow: false))
                .padding(LiquidGlass.cardInset)
        }
    }

    /// One section of the bottom workspace (the toolbar, or the table / Details) as a
    /// self-contained card: applies the tint wash, then frames it — a floating card for `.cards`,
    /// or a clipped hairline-outlined region for `.unified`. Sections are stacked with a gap so
    /// the toolbar reads separately from the data.
    ///
    /// Like `surfaceCard` and `panesRegionFrame`, this insets itself by `cardInset` — half a
    /// gutter — so two stacked sections come to exactly one `cardGutter` between them and line up
    /// with the pane cards at the window edge. Callers stack these at `spacing: 0` and add no
    /// padding of their own.
    ///
    /// Every section takes the level verbatim, toolbars included — a toolbar's *card* is as clear
    /// as the table's. Its buttons get their own material via `chromeButtonStyle` instead, so the
    /// bar doesn't turn into an opaque band across a window the user asked to see through.
    @ViewBuilder
    func bottomSectionCard(
        _ style: SurfaceStyle,
        level: GlassLevel,
        hue: LiquidGlassHue = .blue,
        tint: Double = 0
    ) -> some View {
        let radius = LiquidGlass.cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let filled = self
            .contentSurface(hue: hue, tint: tint)
            .clipShape(shape)
        switch style {
        case .cards:
            let explicit = level.needsExplicitChrome
            filled.glassSurface(level, cornerRadius: radius)
                .modifier(DarkBoldCardChrome(
                    cornerRadius: radius,
                    lightBorder: explicit, lightShadow: explicit, darkShadow: true))
                .padding(LiquidGlass.cardInset)
        case .unified:
            // Unified blends into the window glass, so only `.solid` contributes a fill here.
            let based = level == .solid
                ? AnyView(filled.glassSurface(.solid, cornerRadius: radius))
                : AnyView(filled)
            based
                .modifier(DarkBoldCardChrome(
                    cornerRadius: radius,
                    lightBorder: true, lightShadow: false, darkShadow: false))
                .padding(LiquidGlass.cardInset)
        }
    }
}

// MARK: - Appearance-aware chrome (the dark-mode "bold" re-tune)
//
// The Liquid Glass surfaces above were tuned once, for light: a single set of constants that reads
// as a flat gray slab on a dark appearance. These modifiers give each surface a bold dark variant —
// a deep graded base + accent glow behind the app, top-lit white specular hairlines on the cards and
// bars, and deeper shadows that lift chrome off the dark ground. Every one is a `ViewModifier` (not
// a free function) purely so it can read `@Environment(\.colorScheme)`; the light branch of each
// reproduces the original rendering exactly, so only dark changes.

/// The app background. **Light** reproduces the original exactly: the accent diagonal gradient over a
/// `.thinMaterial` base at `0.45 + 0.20·t`. **Dark** adds the two things the flat slab was missing —
/// a deep, faintly-cool near-black gradient *under* the material so the ground grades with depth, and
/// a soft pool of the accent hue at the top edge *over* the material so the accent actually reads —
/// and thins the material so that deep base shows through. The accent diagonal also lifts its opacity
/// in dark to survive the darker base. `.clear` stays see-through — it skips the opaque material,
/// but in dark still takes a translucent veil of that base plus a toned-down glow, so it reads as
/// deep moody glass over the desktop rather than a pale wash.
private struct LiquidGlassBackground: ViewModifier {
    let level: GlassLevel
    let hue: LiquidGlassHue
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let t = level.backgroundIntensity
        // `.clear` keeps the window see-through: the opaque material stays off, and in dark the deep
        // base drops to a translucent veil (below) rather than a solid ground.
        let seeThrough = level == .clear

        let opacities: [Double] = dark
            ? [0.19 + 0.28 * t, 0.15 + 0.23 * t, 0.10 + 0.16 * t]
            : [0.06 + 0.16 * t, 0.05 + 0.14 * t, 0.04 + 0.10 * t]
        let gradientColors = zip(hue.gradientColors, opacities).map { $0.0.opacity($0.1) }

        content.background {
            ZStack {
                BehindWindowGlass(isEnabled: seeThrough)
                    .ignoresSafeArea()

                // Dark deep base: a near-black, faintly-cool gradient. When the window is opaque
                // (`.frosted`/`.solid`) it's the full ground the material sits on. At `.clear` it
                // drops to a translucent veil over the behind-window vibrancy — the desktop still
                // reads through, but as deep, moody glass rather than a pale wash (Clear made bolder
                // without giving up see-through).
                if dark {
                    LinearGradient(
                        colors: [Color(red: 0.065, green: 0.082, blue: 0.115),
                                 Color(red: 0.02, green: 0.027, blue: 0.043)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .opacity(seeThrough ? 0.55 : 1)
                    .ignoresSafeArea()
                }

                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if !seeThrough {
                    // Base material so content stays readable. Dark thins it so the deep base reads
                    // through instead of flattening back to system gray.
                    Color.clear
                        .background(.thinMaterial.opacity((dark ? 0.27 : 0.45) + 0.20 * t))
                        .ignoresSafeArea()
                } else if !dark {
                    // Clear in light mode read as flat system gray (the behind-window vibrancy alone).
                    // A translucent white veil warms it toward a frosted white glass while keeping the
                    // desktop showing through — "whiter and more transparent" without an opaque slab.
                    Color.white.opacity(0.20)
                        .ignoresSafeArea()
                }

                // Dark accent glow: a soft pool of the hue at the top so the accent reads. Fires at
                // every dark level now, `.clear` included — there at a lower strength, since it sits
                // over the veil + desktop rather than an opaque material. `.none` opts out (it defers
                // to the system accent).
                if dark && hue != .none {
                    RadialGradient(
                        colors: [hue.accentColor.opacity(seeThrough ? 0.18 : 0.26 + 0.10 * t), .clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: 700
                    )
                    .blendMode(.plusLighter)
                    .ignoresSafeArea()
                }
            }
        }
    }
}

/// Border + shadow for a floating overlay card (Settings, Help, the operation banner, the ⌘K
/// palette) sitting over a dimmed backdrop. Dark draws a top-lit white specular hairline and a
/// deeper, larger shadow so the card lifts off the scrim — the light-tuned `cardShadow` is nearly
/// invisible on a dark backdrop. Light keeps the original: no border either way, and the soft
/// `cardShadow` only where the explicit-chrome path drew it (native glass drew its own edge/shadow).
private struct OverlayCardChrome: ViewModifier {
    let cornerRadius: CGFloat
    let lightShadow: Bool
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if scheme == .dark {
            content
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 34, y: 12)
        } else if lightShadow {
            content.shadow(
                color: LiquidGlass.cardShadow.color,
                radius: LiquidGlass.cardShadow.radius,
                x: LiquidGlass.cardShadow.x,
                y: LiquidGlass.cardShadow.y)
        } else {
            content
        }
    }
}

/// Bar/panel glass with a dark-only top-lit specular hairline, so a bar reads as distinct glass
/// chrome against the deep dark background. Light takes the level's surface verbatim, unchanged.
private struct GlassBarStyle: ViewModifier {
    let level: GlassLevel
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LiquidGlass.smallCornerRadius, style: .continuous)
        content
            .glassSurface(level, cornerRadius: LiquidGlass.smallCornerRadius)
            .overlay {
                if scheme == .dark {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
            }
    }
}

/// The appearance-aware hairline every content card wears: a top-lit white specular gradient in dark
/// (so the card reads as lit glass on the deep ground) and the faint `.quaternary` rule in light. One
/// definition, so lens cards, pane/section cards and the bottom-workspace sections all edge
/// identically — a card added later can't drift its own edge. `lightVisible` is false only on
/// native-glass content cards, which draw no light border of their own (the glass draws its edge).
struct CardHairline: ViewModifier {
    var cornerRadius: CGFloat = LiquidGlass.cardCornerRadius
    var lightVisible: Bool = true
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.overlay {
            if scheme == .dark {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            } else if lightVisible {
                shape.strokeBorder(.quaternary, lineWidth: 0.5)
            }
        }
    }
}

/// Hairline + shadow for content cards (file panes, bottom-workspace sections). The hairline is
/// `CardHairline` (white specular in dark, `.quaternary` in light); this adds the depth on top — a
/// deep dark-only lift where `darkShadow`, the old soft shadow in light where `lightShadow`.
/// `lightBorder` forwards to the hairline (off on native glass, which draws its own edge).
private struct DarkBoldCardChrome: ViewModifier {
    let cornerRadius: CGFloat
    let lightBorder: Bool
    let lightShadow: Bool
    let darkShadow: Bool
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let bordered = content.modifier(CardHairline(cornerRadius: cornerRadius, lightVisible: lightBorder))
        if dark && darkShadow {
            bordered.shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        } else if !dark && lightShadow {
            bordered.shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 3)
        } else {
            bordered
        }
    }
}
