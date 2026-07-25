import SwiftUI

/// How loud an action-bar control is. The three weights are a strict ladder — a bar shows at most
/// one `.primary`, any number of `.quiet`, and everything else `.outline`.
///
/// Every weight is drawn here, from a fill and a hairline we own. That is the point of the type,
/// not an implementation detail: `.bordered` / `.glass` capsules desaturate when the window stops
/// being key, and the header used to carry its hierarchy in exactly that difference — prominent vs.
/// bordered — so the ordering it computed survived only while the app was frontmost. `ContentView`
/// pins `controlActiveState` to `.active` for the same reason, but the pin reaches materials, not
/// the AppKit-backed button styles. Painting the weights ourselves is what makes the bar say the
/// same thing focused and unfocused.
public enum ActionBarWeight: String, CaseIterable, Sendable {
    /// The filled capsule. At most one per bar, and it should be the action a hurried user is
    /// most likely to want — never the merely-largest one (see `DifferencesView`'s fixed direction).
    case primary
    /// A real action at second billing: the tint wash and hairline `Pill` already uses, so the
    /// quiet weight is the count-pill recipe in button form rather than a fourth surface.
    case quiet
    /// Present, quiet, uncoloured: a neutral hairline and a secondary label.
    case outline

    /// Which hover treatment the weight borrows from `HoverAffordance`. The two tinted weights
    /// already have a fill, so they take `.filled`'s ring-and-lift; `.outline` has nothing to ring,
    /// so it takes `.segment`'s wash and gets something to show for the pointer.
    public var hoverVariant: HoverAffordanceVariant {
        self == .outline ? .segment : .filled
    }

    /// Opacity of the tint fill behind the label.
    public var fillOpacity: Double {
        switch self {
        case .primary: return 1
        case .quiet: return PillVariant.fillOpacity
        case .outline: return 0
        }
    }

    /// Opacity of the resting hairline. `.primary` has none — a stroke on a full-strength fill
    /// only muddies its edge.
    public var strokeOpacity: Double {
        switch self {
        case .primary: return 0
        case .quiet: return PillVariant.strokeOpacity
        case .outline: return ActionBarMetrics.outlineStrokeOpacity
        }
    }

    /// Whether the hairline is drawn in neutral ink rather than the tint. Only `.outline` is:
    /// tinting its border would make it read as a third coloured weight next to `.quiet`.
    public var strokesInInk: Bool { self == .outline }
}

/// Every number the action bar's controls are built from, in one table so a test can assert the
/// design directly instead of through a rendered pixel (the `HoverAffordanceMetrics` pattern).
public enum ActionBarMetrics {
    /// Capsule height. Also the width of an icon-only control, which is therefore a circle.
    public static let height: CGFloat = 28
    /// Leading/trailing padding on a control with a text label.
    public static let horizontalPadding: CGFloat = 12
    /// Height of the hairline that separates two zones. Deliberately shorter than the capsules:
    /// a full-height rule would read as a border around the group rather than a seam between two.
    public static let dividerHeight: CGFloat = 18
    /// Neutral-ink hairline opacity for the `.outline` weight and `ActionBarDivider`.
    public static let outlineStrokeOpacity: Double = 0.16
    /// Hairline width, matching `PillVariant.strokeWidth` so a quiet button and a pill sitting
    /// beside it have the same edge.
    public static let strokeWidth: CGFloat = PillVariant.strokeWidth
    /// A disabled control keeps its shape and loses its conviction.
    public static let disabledOpacity: Double = 0.4
    /// Label font. Pinned rather than inherited: the bar sits inside a card that sets its own
    /// font, and a control that changes size with the surrounding text would break the row.
    public static let font: Font = .system(size: 13)
}

// MARK: - Style

/// The action bar's button surface: a capsule in one of three weights, with the hover treatment
/// its weight borrows from `HoverAffordance`.
public struct ActionBarButtonStyle: ButtonStyle {
    let weight: ActionBarWeight
    let tint: Color
    /// Label colour on a `.primary` fill. Callers pass `LiquidGlassHue.onAccentLabelColor` — never
    /// `.white`, which is under WCAG's 3:1 floor on seven of the eleven hues.
    let onTint: Color
    /// Renders a square (so, capsule-clipped, circular) control for a bare glyph.
    let isIconOnly: Bool

    public func makeBody(configuration: Configuration) -> some View {
        ActionBarButtonBody(weight: weight, tint: tint, onTint: onTint,
                            isIconOnly: isIconOnly, configuration: configuration)
    }
}

private struct ActionBarButtonBody: View {
    let weight: ActionBarWeight
    let tint: Color
    let onTint: Color
    let isIconOnly: Bool
    let configuration: ButtonStyle.Configuration

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: HoverAffordancePhase {
        guard isEnabled else { return .rest }
        if configuration.isPressed { return .pressed }
        return isHovering ? .hover : .rest
    }

    private var hover: HoverAffordanceMetrics {
        .resolve(variant: weight.hoverVariant, phase: phase,
                 isEnabled: isEnabled, reduceMotion: reduceMotion)
    }

    /// The label reads against whatever the weight fills with.
    private var labelColor: Color {
        switch weight {
        case .primary: return onTint
        case .quiet: return tint
        case .outline: return .secondary
        }
    }

    /// Hover adds to the resting fill rather than replacing it, so a quiet button warms toward
    /// the primary instead of flashing a different colour.
    private var fill: Color {
        tint.opacity(weight.fillOpacity + hover.wash)
    }

    private var stroke: Color {
        let base = weight.strokesInInk ? Color.primary : tint
        return base.opacity(weight.strokeOpacity + hover.ring)
    }

    var body: some View {
        configuration.label
            .font(ActionBarMetrics.font)
            .foregroundStyle(labelColor)
            .lineLimit(1)
            .modifier(ActionBarShape(isIconOnly: isIconOnly))
            .background(Capsule(style: .continuous).fill(fill))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(stroke, lineWidth: ActionBarMetrics.strokeWidth))
            .compositingGroup()
            .opacity(isEnabled ? 1 : ActionBarMetrics.disabledOpacity)
            .shadow(color: tint.opacity(hover.shadow), radius: 5, x: 0, y: 3)
            .offset(y: hover.lift)
            .scaleEffect(hover.scale)
            .contentShape(Capsule(style: .continuous))
            .environment(\.hoverAffordancePhase, phase)
            .onHover { hovering in
                // Same guard as HoverAffordanceStyle: SwiftUI keeps delivering onHover to a
                // disabled button, which would strand it showing a hover it never repaints.
                isHovering = isEnabled && hovering
            }
            .animation(.easeOut(duration: phase == .rest ? 0.18 : 0.12), value: phase)
    }
}

/// Splits the two footprints out of the body so both branches share one `Capsule` background.
private struct ActionBarShape: ViewModifier {
    let isIconOnly: Bool

    func body(content: Content) -> some View {
        if isIconOnly {
            content.frame(width: ActionBarMetrics.height, height: ActionBarMetrics.height)
        } else {
            content
                .padding(.horizontal, ActionBarMetrics.horizontalPadding)
                .frame(height: ActionBarMetrics.height)
        }
    }
}

public extension ButtonStyle where Self == ActionBarButtonStyle {
    /// An action-bar capsule.
    ///
    /// - Parameters:
    ///   - weight: how loud. One `.primary` per bar.
    ///   - tint: the fill and hairline colour — the window's `LiquidGlassHue.accentColor`.
    ///   - onTint: the label colour on a `.primary` fill; pass the hue's `onAccentLabelColor`.
    ///   - iconOnly: renders a circular control sized for a bare glyph.
    static func actionBar(_ weight: ActionBarWeight,
                          tint: Color,
                          onTint: Color,
                          iconOnly: Bool = false) -> ActionBarButtonStyle {
        ActionBarButtonStyle(weight: weight, tint: tint, onTint: onTint, isIconOnly: iconOnly)
    }
}

// MARK: - Divider

/// The hairline between two action-bar zones. Short, neutral, and invisible to VoiceOver — it
/// separates groups for the eye only; the controls' own labels carry the grouping for everyone else.
public struct ActionBarDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(ActionBarMetrics.outlineStrokeOpacity))
            .frame(width: 1, height: ActionBarMetrics.dividerHeight)
            .accessibilityHidden(true)
    }
}
