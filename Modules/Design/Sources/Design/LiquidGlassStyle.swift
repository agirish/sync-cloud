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

    /// The level overlay chrome actually renders at. Settings, Help, the first-run card and the
    /// operation banner are the only surfaces with dense app content behind them rather than the
    /// window's gradient, and clear glass over text is two layers of text competing — so `.clear`
    /// resolves to `.frosted` there. Apple draws the same line: Control Center is glass, alerts
    /// and sheets are not. `.frosted` and `.solid` pass through untouched.
    public var flooredForOverlay: GlassLevel {
        self == .clear ? .frosted : self
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
    /// Gutter around each floating card in Cards mode. The gap between two adjacent cards is 2×
    /// this; outer edges (sidebar side, window edge) show 1×. Shared by `surfaceCard` (panes) and
    /// the bottom-workspace padding so the top pane cards and the bottom cards line up.
    /// At the previous 3pt this sat below the threshold where a gap reads as separation, which
    /// made Cards nearly indistinguishable from Unified — the 14pt radius needs room to register.
    public static let cardGutter: CGFloat = 8
    /// Corner radius for smaller elements (badges, buttons, inputs).
    public static let smallCornerRadius: CGFloat = 10

    /// Soft shadow for glass cards to add depth without heaviness.
    public static let cardShadow = (color: Color.black.opacity(0.06), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(4))
    /// Lighter shadow for inline elements.
    public static let subtleShadow = (color: Color.black.opacity(0.04), radius: CGFloat(6), x: CGFloat(0), y: CGFloat(2))

    /// UserDefaults key for the selected `GlassLevel` (raw value).
    public static let levelKey = "glassLevel"

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
    @ViewBuilder
    func liquidGlassAppBackground(level: GlassLevel, hue: LiquidGlassHue = .blue) -> some View {
        let t = level.backgroundIntensity
        let colors = hue.gradientColors
        let opacities: [Double] = [0.06 + 0.16 * t, 0.05 + 0.14 * t, 0.04 + 0.10 * t]
        let gradientColors = zip(colors, opacities).map { $0.0.opacity($0.1) }

        self.background {
            ZStack {
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // Keep a base material so content remains readable in light/dark.
                Color.clear
                    .background(.thinMaterial.opacity(0.45 + 0.20 * t))
                    .ignoresSafeArea()
            }
        }
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
    /// the operation banner). Applies `flooredForOverlay`, so a `.clear` app never produces an
    /// unreadable dialog — these are the only surfaces with live content behind them.
    @ViewBuilder
    func glassCardStyle(level: GlassLevel) -> some View {
        let resolved = level.flooredForOverlay
        let shape = RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous)
        if resolved.needsExplicitChrome {
            self
                .glassSurface(resolved, cornerRadius: LiquidGlass.cardCornerRadius)
                .clipShape(shape)
                .shadow(
                    color: LiquidGlass.cardShadow.color,
                    radius: LiquidGlass.cardShadow.radius,
                    x: LiquidGlass.cardShadow.x,
                    y: LiquidGlass.cardShadow.y
                )
        } else {
            self.glassSurface(resolved, cornerRadius: LiquidGlass.cardCornerRadius)
        }
    }

    /// Lighter glass style for bars and inline panels. These sit over the window's own background
    /// rather than over content, so they take the level verbatim — no floor.
    @ViewBuilder
    func glassBarStyle(level: GlassLevel) -> some View {
        self.glassSurface(level, cornerRadius: LiquidGlass.smallCornerRadius)
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
    @ViewBuilder
    func surfaceCard(_ level: GlassLevel, cornerRadius: CGFloat = LiquidGlass.cardCornerRadius) -> some View {
        // Clip the content to the card shape first — the pane's contentSurface tint wash is a
        // square fill, and without this it pokes past the rounded corners into the gutters
        // (bottomSectionCard already clips the same way).
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let filled = self.clipShape(shape).glassSurface(level, cornerRadius: cornerRadius)
        if level.needsExplicitChrome {
            filled
                .overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 3)
                .padding(LiquidGlass.cardGutter)
        } else {
            filled.padding(LiquidGlass.cardGutter)
        }
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
                .overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
                .padding(LiquidGlass.cardGutter)
        }
    }

    /// One section of the bottom workspace (the toolbar, or the table / Details) as a
    /// self-contained card: applies the tint wash, then frames it — a floating card for `.cards`,
    /// or a clipped hairline-outlined region for `.unified`. Sections are stacked with a gap so
    /// the toolbar reads separately from the data.
    @ViewBuilder
    func bottomSectionCard(_ style: SurfaceStyle, level: GlassLevel, hue: LiquidGlassHue = .blue, tint: Double = 0) -> some View {
        let radius = LiquidGlass.cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let filled = self
            .contentSurface(hue: hue, tint: tint)
            .clipShape(shape)
        switch style {
        case .cards:
            let glassed = filled.glassSurface(level, cornerRadius: radius)
            if level.needsExplicitChrome {
                glassed
                    .overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 3)
            } else {
                glassed
            }
        case .unified:
            // Unified blends into the window glass, so only `.solid` contributes a fill here.
            let based = level == .solid
                ? AnyView(filled.glassSurface(.solid, cornerRadius: radius))
                : AnyView(filled)
            based.overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
        }
    }
}
