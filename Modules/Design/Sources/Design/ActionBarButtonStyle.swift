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
    public static let font: ScaledFont = .system(size: 13)
}

// MARK: - Style

/// The action bar's button surface: a capsule in one of three weights, with the hover treatment
/// its weight borrows from `HoverAffordance`.
public struct ActionBarButtonStyle: ButtonStyle {
    let weight: ActionBarWeight
    let tint: Color
    /// Label colour on a `.primary` fill. Callers pass `LiquidGlassHue.onAccentLabelColor`, which is
    /// now white for every hue — because `fill` deepens the tint until white clears 4.5:1 on it. The
    /// parameter stays rather than collapsing to a literal: a caller filling with something other
    /// than the app accent (the destructive red) still has to name its own pairing.
    let onTint: Color
    /// Renders a square (so, capsule-clipped, circular) control for a bare glyph.
    let isIconOnly: Bool

    public func makeBody(configuration: Configuration) -> some View {
        ActionBarButtonBody(weight: weight, tint: tint, onTint: onTint,
                            isIconOnly: isIconOnly, configuration: configuration)
    }
}

/// The button's own body: everything that needs a live `Button` — the pressed flag from the
/// configuration and the hover state that only a pointer can set — resolved into one phase and
/// handed to `ActionBarButtonSurface`, which draws it.
///
/// The split is what lets the surface be reached without a `Button` (`actionBarButtonSurface`).
/// This layer stays thin on purpose: nothing here paints.
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

/// The action-bar control's visual, for one phase — the whole capsule, with no `Button` in it.
///
/// Parameterised by the phase rather than reading a `ButtonStyle.Configuration`, so the same paint
/// serves both callers: `ActionBarButtonStyle` drives it from a real button's pressed/hover state,
/// and `actionBarButtonSurface` pins it at `.rest` to render a picture of a control. Everything the
/// weights are drawn from lives here; the style above owns no paint of its own.
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

    private var hover: HoverAffordanceMetrics {
        .resolve(variant: weight.hoverVariant, phase: phase,
                 isEnabled: isEnabled, reduceMotion: reduceMotion)
    }

    /// The label reads against whatever the weight fills with — on light. On dark it reads against
    /// a hue-washed surface instead, where the accent and `.secondary` both lose (see `ChromeInk`);
    /// `.primary` is exempt because its label is already `onTint`, white on a deepened fill built
    /// to carry it.
    private var labelColor: Color {
        switch weight {
        case .primary: return onTint
        case .quiet: return ChromeInk.label(colorScheme, light: tint)
        case .outline: return ChromeInk.label(colorScheme, light: .secondary)
        }
    }

    /// Hover adds to the resting fill rather than replacing it, so a quiet button warms toward
    /// the primary instead of flashing a different colour.
    ///
    /// `.primary` fills with the DEEPENED tint, the other two with the raw one. That split is the
    /// point rather than an inconsistency: only `.primary` puts a white label on its fill, so only
    /// `.primary` has a contrast floor to meet. Deepening a 14% wash would just muddy it, and
    /// `.quiet` draws its label IN the tint, where a deeper value would read as a different colour
    /// from the pill beside it. A hovered `.quiet` therefore warms toward the raw accent, not toward
    /// the primary's fill — the two are the same hue at different depths.
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
    /// The resting action-bar control surface, applied to any view — a picture of a button, with
    /// no `Button` under it.
    ///
    /// The same paint `.actionBar(_:tint:onTint:)` puts on a real button, pinned at `.rest`: no
    /// pressed state to report and no `onHover` to move it, because the caller has no action to
    /// fire. Use it where a control has to be SHOWN rather than offered — the Appearance tab's
    /// accent preview strip, which samples what the chosen hue actually paints.
    ///
    /// That is a structural guarantee rather than a convenience, and it is the reason this exists:
    /// an inert `Button` has to be talked out of three separate input paths (`allowsHitTesting`,
    /// `accessibilityElement(children:)`, `.focusable(false)`), and the third is a modifier whose
    /// behaviour can only be checked by hand, since an offscreen `NSHostingView` has no key window
    /// to walk focus through. A view that was never a button has none of those paths to close.
    /// `semanticCapsuleSurface(_:)` is the same move for the count pill beside it.
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
