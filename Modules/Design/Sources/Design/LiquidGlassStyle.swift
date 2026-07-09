import SwiftUI

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
    /// Barely-there material: the window's tinted glass shows through, matching the file panes.
    case unified
    /// A soft translucent panel — present but still glassy. The balanced default.
    case framed
    /// A denser, near-opaque panel for maximum legibility of long lists.
    case solid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unified: return "Unified"
        case .framed: return "Framed"
        case .solid: return "Solid"
        }
    }

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .unified:
            return "The Differences and Details areas blend into the window's glass, matching the file panes."
        case .framed:
            return "The Differences and Details areas sit in a soft translucent panel."
        case .solid:
            return "The Differences and Details areas use an opaque panel for maximum readability."
        }
    }

    /// Base material for the bottom-pane card. Used on macOS 15; macOS 26 draws native glass and
    /// ignores this, so the per-content `contentSurface` fill is what varies the look there.
    public var cardMaterial: Material {
        switch self {
        case .unified: return .ultraThinMaterial
        case .framed: return .thinMaterial
        case .solid: return .regularMaterial
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

    /// Fills the bottom workspace (Differences / Details) with the user-selected surface style.
    /// The styles differ only in translucency — `.unified` lets the window glass show through to
    /// match the panes, `.solid` reads as an opaque panel — and intensity nudges the opacity
    /// within each. Applied on every OS (unlike the glass helpers) because the flat look comes
    /// from these raw material fills, which macOS 26's native glass does not replace.
    @ViewBuilder
    func contentSurface(_ style: SurfaceStyle, intensity: Double = 0.65) -> some View {
        let t = max(0.0, min(1.0, intensity))
        switch style {
        case .unified:
            self.background(.ultraThinMaterial.opacity(0.18 + 0.14 * t))
        case .framed:
            self.background(.thinMaterial.opacity(0.42 + 0.24 * t))
        case .solid:
            self.background(.regularMaterial.opacity(0.82 + 0.16 * t))
        }
    }
}
