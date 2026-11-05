import SwiftUI

/// How loud an action-bar control is. A strict ladder: at most one `.primary` per bar, any number
/// of `.quiet`, everything else `.outline`.
///
/// Every weight is painted here from our own fill and hairline, because `.bordered` / `.glass`
/// capsules desaturate when the window stops being key, which would erase the hierarchy whenever
/// the app is in the background. `ContentView`'s `controlActiveState` pin reaches materials, not
/// the AppKit-backed button styles.
public enum ActionBarWeight: String, CaseIterable, Sendable {
    /// The filled capsule. At most one per bar: the action a hurried user most likely wants, not
    /// the merely largest (see `DifferencesView`'s fixed direction).
    case primary
    /// A real action at second billing: `Pill`'s tint wash and hairline in button form, not a
    /// fourth surface.
    case quiet
    /// Present, quiet, uncoloured: a neutral hairline and a secondary label.
    case outline

    /// Which hover treatment the weight borrows from `HoverAffordance`. The tinted weights have a
    /// fill, so they take `.filled`'s ring-and-lift; `.outline` has nothing to ring and takes
    /// `.segment`'s wash.
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

    /// Opacity of the resting hairline. `.primary` has none: a stroke on a full fill only muddies
    /// its edge.
    public var strokeOpacity: Double {
        switch self {
        case .primary: return 0
        case .quiet: return PillVariant.strokeOpacity
        case .outline: return ActionBarMetrics.outlineStrokeOpacity
        }
    }

    /// Whether the hairline is neutral ink rather than the tint. Only `.outline`'s is: tinted, it
    /// would read as a third coloured weight next to `.quiet`.
    public var strokesInInk: Bool { self == .outline }
}

/// Every number the action bar's controls are built from, in one table so tests can check the
/// design without rendering (the `HoverAffordanceMetrics` pattern).
public enum ActionBarMetrics {
    /// Capsule height. Also the width of an icon-only control, which is therefore a circle.
    public static let height: CGFloat = 28
    /// Leading/trailing padding on a control with a text label.
    public static let horizontalPadding: CGFloat = 12
    /// Height of the hairline between two zones. Shorter than the capsules, so it reads as a seam,
    /// not a border around the group.
    public static let dividerHeight: CGFloat = 18
    /// Neutral-ink hairline opacity for the `.outline` weight and `ActionBarDivider`.
    public static let outlineStrokeOpacity: Double = 0.16
    /// Hairline width, matching `PillVariant.strokeWidth` so a quiet button and a pill sitting
    /// beside it have the same edge.
    public static let strokeWidth: CGFloat = PillVariant.strokeWidth
    /// A disabled control keeps its shape and loses its conviction.
    public static let disabledOpacity: Double = 0.4
    /// Label font. Pinned, not inherited: the bar sits in a card with its own font, and controls
    /// that resized with it would break the row.
    public static let font: ScaledFont = .system(size: 13)
}

// MARK: - Style

/// The action bar's button surface: a capsule in one of three weights, with the hover treatment
/// its weight borrows from `HoverAffordance`.
public struct ActionBarButtonStyle: ButtonStyle {
    let weight: ActionBarWeight
    let tint: Color
    /// Label colour on a `.primary` fill. Callers pass `LiquidGlassHue.onAccentLabelColor`, white
    /// for every hue since `fill` deepens the tint to carry it. A parameter, not a literal, so a
    /// caller with another fill (the destructive red) names its own pairing.
    let onTint: Color
    /// Renders a square (so, capsule-clipped, circular) control for a bare glyph.
    let isIconOnly: Bool

    public func makeBody(configuration: Configuration) -> some View {
        ActionBarButtonBody(weight: weight, tint: tint, onTint: onTint,
                            isIconOnly: isIconOnly, configuration: configuration)
    }
}

/// The button's own body: resolves the pressed flag and pointer hover into one phase and hands it
/// to `ActionBarButtonSurface`. Nothing here paints, so the surface can also be drawn without a
/// `Button` (`actionBarButtonSurface`).
private struct ActionBarButtonBody: View {
    let weight: ActionBarWeight
    let tint: Color
    let onTint: Color
    let isIconOnly: Bool
    let configuration: ButtonStyle.Configuration

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var phase: HoverAffordancePhase {
        guard isEnabled else { return .rest }
        if configuration.isPressed { return .pressed }
        return isHovering ? .hover : .rest
    }

    var body: some View {
        configuration.label
            .modifier(ActionBarButtonSurface(weight: weight, tint: tint, onTint: onTint,
                                             isIconOnly: isIconOnly, phase: phase))
            .onHover { hovering in
                // Same guard as HoverAffordanceStyle: SwiftUI keeps delivering onHover to a
                // disabled button, which would strand it showing a hover it never repaints.
                isHovering = isEnabled && hovering
            }
    }
}

/// The action-bar control's whole capsule for one phase, with no `Button` in it. Taking a phase
/// rather than a `ButtonStyle.Configuration` lets `ActionBarButtonStyle` drive it from a real
/// button and `actionBarButtonSurface` pin it at `.rest`. All of the weights' paint lives here.
struct ActionBarButtonSurface: ViewModifier {
    let weight: ActionBarWeight
    let tint: Color
    let onTint: Color
    let isIconOnly: Bool
    /// Which of the three states to draw. `.rest` for a still picture.
    let phase: HoverAffordancePhase

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Seated on a bar button's glass (`ChromeGlass`): no lift, no shadow.
    @Environment(\.chromeGlassDrawn) private var onGlass

    private var hover: HoverAffordanceMetrics {
        .resolve(variant: weight.hoverVariant, phase: phase,
                 isEnabled: isEnabled, reduceMotion: reduceMotion)
            .seated(onGlass)
    }

    /// On light the label reads against the weight's fill; on dark, against a hue-washed surface
    /// where the accent and `.secondary` both lose (see `ChromeInk`). `.primary` keeps `onTint`,
    /// white on a fill deepened to carry it.
    private var labelColor: Color {
        switch weight {
        case .primary: return onTint
        case .quiet: return ChromeInk.label(colorScheme, light: tint)
        case .outline: return ChromeInk.label(colorScheme, light: .secondary)
        }
    }

    /// Hover adds to the resting fill rather than replacing it, so a quiet button warms instead of
    /// flashing a different colour.
    ///
    /// Only `.primary` fills with the deepened tint, since only it puts a white label on its fill.
    /// Deepening a 14% wash would muddy it, and `.quiet` draws its label in the tint, where a
    /// deeper value would no longer match the pill beside it.
    private var fill: Color {
        let base = weight == .primary ? AccentFill.deepened(tint) : tint
        return base.opacity(weight.fillOpacity + hover.wash)
    }

    private var stroke: Color {
        let base = weight.strokesInInk ? Color.primary : tint
        return base.opacity(weight.strokeOpacity + hover.ring)
    }

    func body(content: Content) -> some View {
        content
            .scaledFont(ActionBarMetrics.font)
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

public extension View {
    /// The resting action-bar surface on any view: a picture of a button, with no `Button` under
    /// it. The paint `.actionBar(_:tint:onTint:)` uses, pinned at `.rest`, for a control that is
    /// shown rather than offered, such as the Appearance tab's accent preview.
    ///
    /// An inert `Button` would have to be closed off from hit testing, accessibility and focus, and
    /// focus can't be checked offscreen; a view that was never a button has none of those paths.
    /// `semanticCapsuleSurface(_:)` does the same for the count pill.
    ///
    /// - Parameters:
    ///   - weight: how loud — the same ladder the button style takes.
    ///   - tint: the fill and hairline colour.
    ///   - onTint: the label colour on a `.primary` fill.
    ///   - iconOnly: renders a circular control sized for a bare glyph.
    func actionBarButtonSurface(_ weight: ActionBarWeight,
                                tint: Color,
                                onTint: Color,
                                iconOnly: Bool = false) -> some View {
        modifier(ActionBarButtonSurface(weight: weight, tint: tint, onTint: onTint,
                                        isIconOnly: iconOnly, phase: .rest))
    }
}

// MARK: - Divider

/// The hairline between two action-bar zones. Short, neutral, and hidden from VoiceOver: it
/// separates groups for the eye only.
public struct ActionBarDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(ActionBarMetrics.outlineStrokeOpacity))
            .frame(width: 1, height: ActionBarMetrics.dividerHeight)
            .accessibilityHidden(true)
    }
}
