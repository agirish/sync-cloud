import SwiftUI
import AppKit

// MARK: - Liquid Glass Design (macOS 26–inspired)
// Uses materials + rounded corners + soft shadows on macOS 15.
// When targeting macOS 26+, consider switching to .glassEffect() for native Liquid Glass.

/// Popular hue options for the liquid glass background gradient.
public enum LiquidGlassHue: String, CaseIterable, Identifiable {
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

/// How the bottom workspace (Differences / Details) surfaces sit against the app's glass
/// background. The three cases differ only in translucency, so the panel can blend into the
/// window glass like the file panes, or read as a distinct, opaque panel for legibility.
/// Stored in UserDefaults via `LiquidGlass.surfaceStyleKey`.
public enum SurfaceStyle: String, CaseIterable, Identifiable {
    /// No fill: the window's glass shows straight through — one continuous surface.
    case unified
    /// Each pane and the Differences area float as separate frosted cards on the background.
    case cards
    /// Flat, fully opaque panels for maximum legibility.
    case solid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unified: return "Unified"
        case .cards: return "Cards"
        case .solid: return "Solid"
        }
    }

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .unified:
            return "The panes and Differences area blend into the window's glass as one continuous surface."
        case .cards:
            return "Each pane and the Differences area float as separate cards on the background."
        case .solid:
            return "The panes and Differences area use opaque panels for maximum readability."
        }
    }
}

public enum LiquidGlass {
    /// Corner radius for cards and floating panels.
    public static let cardCornerRadius: CGFloat = 14
    /// Corner radius for smaller elements (badges, buttons, inputs).
    public static let smallCornerRadius: CGFloat = 10

    /// Soft shadow for glass cards to add depth without heaviness.
    public static let cardShadow = (color: Color.black.opacity(0.06), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(4))
    /// Lighter shadow for inline elements.
    public static let subtleShadow = (color: Color.black.opacity(0.04), radius: CGFloat(6), x: CGFloat(0), y: CGFloat(2))

    /// Global user-tunable intensity, stored in UserDefaults.
    /// 0.0 = very subtle (less glass), 1.0 = very glassy (more transparency).
    public static let intensityKey = "liquidGlassIntensity"

    /// UserDefaults key for the selected liquid glass hue (raw value of `LiquidGlassHue`).
    public static let hueKey = "liquidGlassHue"

    /// UserDefaults key for the content surface style (raw value of `SurfaceStyle`).
    public static let surfaceStyleKey = "contentSurfaceStyle"

    /// UserDefaults key for the accent-color tint strength applied to surfaces (Double, 0...1).
    public static let tintKey = "contentSurfaceTint"
}

// MARK: - View Extensions

public extension View {
    /// Applies an app-level background that makes Liquid Glass visible by providing subtle color/content behind it.
    /// - Parameters:
    ///   - intensity: 0.0 = very subtle, 1.0 = very glassy.
    ///   - hue: The color theme for the gradient (defaults to `.blue` if invalid).
    @ViewBuilder
    func liquidGlassAppBackground(intensity: Double, hue: LiquidGlassHue = .blue) -> some View {
        let t = max(0.0, min(1.0, intensity))
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
    
    /// Applies a frosted glass card style: material background, rounded corners, soft shadow.
    @ViewBuilder
    func glassCardStyle(material: Material = .regularMaterial, intensity: Double = 0.65) -> some View {
        let t = max(0.0, min(1.0, intensity))
        if #available(macOS 26.0, *) {
            self
                .glassEffect(t > 0.33 ? .regular : .clear, in: .rect(cornerRadius: LiquidGlass.cardCornerRadius))
        } else {
            self
                .background(material.opacity(0.55 + 0.35 * t))
                .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous))
                .shadow(
                    color: LiquidGlass.cardShadow.color,
                    radius: LiquidGlass.cardShadow.radius,
                    x: LiquidGlass.cardShadow.x,
                    y: LiquidGlass.cardShadow.y
                )
        }
    }
    
    /// Lighter glass style for bars and inline panels.
    @ViewBuilder
    func glassBarStyle(intensity: Double = 0.65) -> some View {
        let t = max(0.0, min(1.0, intensity))
        if #available(macOS 26.0, *) {
            self
                .glassEffect(t > 0.33 ? .regular : .clear, in: .rect(cornerRadius: LiquidGlass.smallCornerRadius))
        } else {
            self
                .background(.ultraThinMaterial.opacity(0.55 + 0.35 * t))
                .clipShape(RoundedRectangle(cornerRadius: LiquidGlass.smallCornerRadius, style: .continuous))
        }
    }

    /// Fills a region (a file pane or the Differences/Details workspace) per the selected surface
    /// style, plus an optional accent-color wash driven by the Tint slider (`tint`, 0...1) that
    /// applies to every style. `.unified` and `.cards` add no base fill (unified shows the app
    /// glass directly; cards get their fill from `surfaceCard`); `.solid` is a flat opaque panel.
    /// Apply it ONCE per region (don't stack it on nested views, or fills compound).
    @ViewBuilder
    func contentSurface(_ style: SurfaceStyle, intensity: Double = 0.65, hue: LiquidGlassHue = .blue, tint: Double = 0) -> some View {
        // A transparent wash at tint 0, up to a clear-but-legible accent at tint 1.
        let wash = hue.accentColor.opacity(max(0.0, min(1.0, tint)) * 0.32)
        switch style {
        case .unified, .cards:
            self.background(wash)
        case .solid:
            // Opaque base, then the accent wash on top so Solid can tint too.
            self.background(wash).background(Color(nsColor: .controlBackgroundColor))
        }
    }

    /// Frosted floating-card decoration for the `.cards` style: material fill, rounded corners,
    /// hairline border, soft shadow, and an outer gutter so the background shows between cards.
    func surfaceCard(cornerRadius: CGFloat = LiquidGlass.cardCornerRadius) -> some View {
        self
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 3)
            // Gutter between cards. Half of this shows on outer edges and a full gap (2×) shows
            // between two adjacent cards, so keep it small to match the sidebar-side spacing.
            .padding(3)
    }

    /// Wraps a file pane as a floating card for `.cards`; leaves it untouched otherwise.
    @ViewBuilder
    func paneCardIfNeeded(_ style: SurfaceStyle) -> some View {
        if style == .cards { self.surfaceCard() } else { self }
    }

    /// One section of the bottom workspace (the toolbar, or the table / Details) as a self-contained
    /// card: applies the surface fill, then frames it — a floating frosted card for `.cards`, or a
    /// clipped hairline-outlined region for `.unified`/`.solid`. Sections are stacked with a gap so
    /// the toolbar reads separately from the data.
    @ViewBuilder
    func bottomSectionCard(_ style: SurfaceStyle, intensity: Double = 0.65, hue: LiquidGlassHue = .blue, tint: Double = 0) -> some View {
        let radius = LiquidGlass.cardCornerRadius
        let filled = self
            .contentSurface(style, intensity: intensity, hue: hue, tint: tint)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        if style == .cards {
            filled
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.6)
                )
                .shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 3)
        } else {
            filled
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
        }
    }
}
