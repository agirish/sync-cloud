import SwiftUI

// MARK: - Liquid Glass Design (macOS 26–inspired)
// Uses materials + rounded corners + soft shadows on macOS 15.
// When targeting macOS 26+, consider switching to .glassEffect() for native Liquid Glass.

public enum LiquidGlass {
    /// Corner radius for cards and floating panels.
    public static let cardCornerRadius: CGFloat = 14
    /// Corner radius for smaller elements (badges, buttons, inputs).
    public static let smallCornerRadius: CGFloat = 10
    /// Corner radius for large hero areas (banners, headers).
    public static let bannerCornerRadius: CGFloat = 16
    
    /// Soft shadow for glass cards to add depth without heaviness.
    public static let cardShadow = (color: Color.black.opacity(0.06), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(4))
    /// Lighter shadow for inline elements.
    public static let subtleShadow = (color: Color.black.opacity(0.04), radius: CGFloat(6), x: CGFloat(0), y: CGFloat(2))
    
    /// Global user-tunable intensity, stored in UserDefaults.
    /// 0.0 = very subtle (less glass), 1.0 = very glassy (more transparency).
    public static let intensityKey = "liquidGlassIntensity"
}

// MARK: - View Extensions

public extension View {
    /// Applies an app-level background that makes Liquid Glass visible by providing subtle color/content behind it.
    @ViewBuilder
    func liquidGlassAppBackground(intensity: Double) -> some View {
        let t = max(0.0, min(1.0, intensity))
        
        self.background {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.25, green: 0.75, blue: 1.0).opacity(0.06 + 0.16 * t), // cyan
                        Color(red: 0.15, green: 0.45, blue: 1.0).opacity(0.05 + 0.14 * t), // blue
                        Color(red: 0.05, green: 0.25, blue: 0.85).opacity(0.04 + 0.10 * t)  // deep blue
                    ],
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
    
    /// Rounded continuous corner clip only (no shadow), for use inside already-shadowed containers.
    func glassClip() -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: LiquidGlass.cardCornerRadius, style: .continuous))
    }
}

public struct AdaptiveGlass: ViewModifier {
    public let cornerRadius: CGFloat
    public let intensity: Double
    public let baseMaterial: Material
    
    public init(cornerRadius: CGFloat, intensity: Double, baseMaterial: Material) {
        self.cornerRadius = cornerRadius
        self.intensity = intensity
        self.baseMaterial = baseMaterial
    }
    
    public func body(content: Content) -> some View {
        let t = max(0.0, min(1.0, intensity))
        if #available(macOS 26.0, *) {
            content
                .glassEffect(t > 0.33 ? .regular : .clear, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(baseMaterial.opacity(0.55 + 0.35 * t))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
