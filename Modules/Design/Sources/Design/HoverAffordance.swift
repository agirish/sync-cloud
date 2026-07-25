import SwiftUI

// MARK: - Hover affordance
//
// `.plain` and `.borderless` buttons draw their own chrome, so AppKit contributes no hover
// state to them at all — which left ~46 controls in the window with nothing to say they were
// clickable. This is the one place that answers it: a `ButtonStyle` that washes the hit shape
// in the app hue on hover and sinks it slightly on press.
//
// The numbers live in `HoverAffordanceMetrics` rather than inline in the view so they can be
// asserted directly — the style's job is only to paint what the metrics resolve to.

/// Which hover treatment a control wears. The variant picks the numbers *and* the default hit
/// shape; a caller whose control isn't the usual shape for its variant overrides `shape`.
public enum HoverAffordanceVariant: String, CaseIterable, Sendable {
    /// A bare icon with no chrome of its own — toolbar glyphs, inspector toggles, row actions.
    case glyph
    /// A chip or tab that fills when selected: hover previews the fill it would take.
    case segment
    /// A control that already carries a solid fill. No wash (there's nothing to wash over) —
    /// a hairline ring and a 1pt lift instead.
    case filled
    /// A round floating control, like the seam's swap button.
    case circular
    /// A full-width list row whose whole area is the target. Quieter wash: it covers far more
    /// pixels than a glyph does, so the same alpha would shout.
    case row
    /// A small dismiss glyph riding inside a field or chip. Washes in *ink*, not the accent —
    /// these clear or remove something, and an inviting accent bloom misreads the action.
    case inline
    /// A button keeping its **system** chrome — `.glass` or `.bordered`. See `ChromeHoverModifier`
    /// for why this one can't be a `ButtonStyle`, and why its numbers are so much louder than
    /// `.filled`'s: a macOS 26 glass capsule is nearly *transparent* at rest, so there is no fill
    /// underneath to deepen — the wash has to supply the whole signal itself.
    case chrome
}

/// The hit shape the wash is drawn in. Deliberately a small closed enum rather than a generic
/// `some Shape`: a `ButtonStyle` carrying a generic shape parameter can't be stored in the
/// `static func` shorthand that makes call sites readable.
public enum HoverAffordanceShape: Equatable, Sendable {
    case capsule
    case circle
    case roundedRect(CGFloat)

    /// What each variant wears unless the call site says otherwise.
    public static func `default`(for variant: HoverAffordanceVariant) -> HoverAffordanceShape {
        switch variant {
        case .glyph: return .roundedRect(8)
        case .segment: return .capsule
        case .filled: return .capsule
        case .circular: return .circle
        case .row: return .roundedRect(7)
        case .inline: return .circle
        // Unused — `chromeHover` never draws a shape, precisely because it can't know one.
        case .chrome: return .capsule
        }
    }
}

/// Where a hover-affordance button currently is. Published into the environment so a label's
/// own subviews — a chevron that slides, a fill that deepens — can react in step with the
/// wash the style paints behind them.
public enum HoverAffordancePhase: Sendable {
    case rest, hover, pressed

    /// True for anything the pointer is engaged with, which is what most call sites branch on.
    public var isEngaged: Bool { self != .rest }
}

// MARK: - Metrics

/// The resolved appearance for one variant in one phase. Every number the style paints comes
/// from here, so the whole affordance is assertable without rendering a view.
public struct HoverAffordanceMetrics: Equatable, Sendable {
    /// Alpha of the wash filling the hit shape.
    public var wash: Double
    /// Alpha of the hairline ring around the hit shape.
    public var ring: Double
    /// Vertical offset, in points. Negative lifts.
    public var lift: CGFloat
    /// Uniform scale. 1 is untouched.
    public var scale: CGFloat
    /// Alpha of the soft tinted shadow under a lifted control.
    public var shadow: Double

    public init(wash: Double = 0, ring: Double = 0, lift: CGFloat = 0,
                scale: CGFloat = 1, shadow: Double = 0) {
        self.wash = wash
        self.ring = ring
        self.lift = lift
        self.scale = scale
        self.shadow = shadow
    }

    /// Everything off — a control at rest, or one that's disabled in any phase.
    public static let none = HoverAffordanceMetrics()

    /// Standard intensity. Hover is a wash plus, on the two variants that float, a 1pt lift;
    /// press deepens the wash and sinks the control. Nothing grows on hover: a target that
    /// widens under a pointer already sitting on it is a misclick waiting to happen, so the
    /// only scale in the table is the sub-1 press.
    public static func resolve(variant: HoverAffordanceVariant,
                               phase: HoverAffordancePhase,
                               isEnabled: Bool = true,
                               reduceMotion: Bool = false) -> HoverAffordanceMetrics {
        // A disabled control must look inert no matter what the pointer does. SwiftUI still
        // delivers `onHover` to a disabled button, so this guard is load-bearing, not defensive.
        guard isEnabled else { return .none }

        var m: HoverAffordanceMetrics
        switch (variant, phase) {
        case (_, .rest):
            m = .none

        case (.glyph, .hover):    m = .init(wash: 0.14, ring: 0.17)
        case (.glyph, .pressed):  m = .init(wash: 0.24, ring: 0.17, scale: 0.97)

        case (.segment, .hover):   m = .init(wash: 0.14)
        case (.segment, .pressed): m = .init(wash: 0.24, scale: 0.97)

        // No wash: the caller's own fill already occupies the shape.
        case (.filled, .hover):   m = .init(ring: 0.15, lift: -1, shadow: 0.18)
        case (.filled, .pressed): m = .init(ring: 0.15, scale: 0.97)

        case (.circular, .hover):   m = .init(wash: 0.14, ring: 0.17, lift: -1, shadow: 0.18)
        case (.circular, .pressed): m = .init(wash: 0.24, ring: 0.17, scale: 0.97)

        case (.row, .hover):   m = .init(wash: 0.11)
        case (.row, .pressed): m = .init(wash: 0.15)

        case (.inline, .hover):   m = .init(wash: 0.13)
        case (.inline, .pressed): m = .init(wash: 0.21, scale: 0.97)

        // A real wash, like every other variant. The first two attempts here tried to light
        // the control from outside — a halo, then a saturation filter — on the theory that a
        // shape-free effect was safer than guessing the chrome's outline. Both were invisible:
        // a macOS 26 glass button is close to transparent at rest, so there was nothing for a
        // filter to act on, and forcing a filter pass over glass risks rendering nothing at all.
        // Measuring the controls settled the outline question instead (see `PaneNavMetrics`).
        case (.chrome, .hover):   m = .init(wash: 0.22, ring: 0.30, lift: -1, shadow: 0.20)
        case (.chrome, .pressed): m = .init(wash: 0.30, ring: 0.30)
        }

        // Reduce Motion drops everything that moves and keeps everything that colors, so the
        // affordance survives the accessibility setting instead of disappearing with it.
        if reduceMotion {
            m.lift = 0
            m.scale = 1
        }
        return m
    }
}

// MARK: - Environment

private struct HoverAffordancePhaseKey: EnvironmentKey {
    static let defaultValue: HoverAffordancePhase = .rest
}

public extension EnvironmentValues {
    /// The phase of the nearest enclosing hover-affordance button. `.rest` outside one.
    var hoverAffordancePhase: HoverAffordancePhase {
        get { self[HoverAffordancePhaseKey.self] }
        set { self[HoverAffordancePhaseKey.self] = newValue }
    }
}

// MARK: - Style

/// The shared hover treatment for buttons that draw their own chrome.
///
/// Replaces `.buttonStyle(.plain)` / `.buttonStyle(.borderless)`, which is what those call
/// sites used to reach for — and which is exactly why they had no hover state.
public struct HoverAffordanceStyle: ButtonStyle {
    let variant: HoverAffordanceVariant
    let tint: Color
    let shape: HoverAffordanceShape

    public func makeBody(configuration: Configuration) -> some View {
        // The hover flag needs `@State`, and a `ButtonStyle` isn't a `View` — hence the nested
        // body type. Standard SwiftUI shape, not a workaround.
        HoverAffordanceBody(variant: variant, tint: tint, shape: shape, configuration: configuration)
    }
}

private struct HoverAffordanceBody: View {
    let variant: HoverAffordanceVariant
    let tint: Color
    let shape: HoverAffordanceShape
    let configuration: ButtonStyle.Configuration

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var phase: HoverAffordancePhase {
        guard isEnabled else { return .rest }
        if configuration.isPressed { return .pressed }
        return isHovering ? .hover : .rest
    }

    private var metrics: HoverAffordanceMetrics {
        .resolve(variant: variant, phase: phase, isEnabled: isEnabled, reduceMotion: reduceMotion)
    }

    /// `.inline` washes in ink; every other variant washes in the app hue.
    private var washColor: Color { variant == .inline ? .primary : tint }

    var body: some View {
        configuration.label
            .background(washShape)
            .overlay(ringShape)
            .compositingGroup()
            .shadow(color: tint.opacity(metrics.shadow),
                    radius: 5, x: 0, y: 3)
            .offset(y: metrics.lift)
            .scaleEffect(metrics.scale)
            .environment(\.hoverAffordancePhase, phase)
            .onHover { hovering in
                // Guarded so a disabled control can't get stuck showing a hover it will never
                // repaint: SwiftUI keeps delivering `onHover` to disabled buttons.
                isHovering = isEnabled && hovering
            }
            // Asymmetric on purpose. Fast in reads as responsive; the slower out keeps a pointer
            // crossing a row of toolbar glyphs from strobing behind it.
            .animation(.easeOut(duration: phase == .rest ? 0.18 : 0.12), value: phase)
    }

    @ViewBuilder
    private var washShape: some View {
        let fill = washColor.opacity(metrics.wash)
        switch shape {
        case .capsule: Capsule().fill(fill)
        case .circle: Circle().fill(fill)
        case .roundedRect(let r): RoundedRectangle(cornerRadius: r, style: .continuous).fill(fill)
        }
    }

    @ViewBuilder
    private var ringShape: some View {
        let stroke = tint.opacity(metrics.ring)
        switch shape {
        case .capsule: Capsule().strokeBorder(stroke, lineWidth: 0.75)
        case .circle: Circle().strokeBorder(stroke, lineWidth: 0.75)
        case .roundedRect(let r):
            RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(stroke, lineWidth: 0.75)
        }
    }
}

public extension ButtonStyle where Self == HoverAffordanceStyle {
    /// The chrome-less button style with a hover state — the replacement for `.plain` and
    /// `.borderless` on any control that draws its own look.
    ///
    /// - Parameters:
    ///   - variant: which treatment to wear; also picks the default hit shape.
    ///   - tint: the wash and ring color, normally the window's `LiquidGlassHue.accentColor`.
    ///           Defaults to the system accent for controls that can't see the hue.
    ///   - shape: overrides the variant's default hit shape.
    static func hoverAffordance(_ variant: HoverAffordanceVariant,
                                tint: Color = .accentColor,
                                shape: HoverAffordanceShape? = nil) -> HoverAffordanceStyle {
        HoverAffordanceStyle(variant: variant, tint: tint,
                             shape: shape ?? .default(for: variant))
    }
}

// MARK: - Label ink

/// Lifts a monochrome glyph to full contrast while its enclosing hover-affordance button is
/// engaged, and returns it to `rest` when the pointer leaves.
///
/// This can't live in the style: the label's own `.foregroundStyle` is applied inside the
/// style's body and would win the cascade. Call sites that want the ink to move opt in here,
/// in place of the flat `.foregroundStyle(.secondary)` they used to carry.
public struct HoverInkModifier: ViewModifier {
    let rest: HierarchicalShapeStyle
    @Environment(\.hoverAffordancePhase) private var phase

    public func body(content: Content) -> some View {
        content.foregroundStyle(phase.isEngaged ? AnyShapeStyle(.primary) : AnyShapeStyle(rest))
    }
}

public extension View {
    /// See `HoverInkModifier`. `rest` is the color the glyph wears when untouched.
    func hoverInk(rest: HierarchicalShapeStyle = .secondary) -> some View {
        modifier(HoverInkModifier(rest: rest))
    }
}

// MARK: - System-chrome buttons

/// Hover feedback for a button that **keeps its system chrome** — anything wearing
/// `chromeButtonStyle` (`.glass` on macOS 26, `.bordered` below it) or a bare `.bordered`.
///
/// `HoverAffordanceStyle` can't help here: a `ButtonStyle` replaces the chrome rather than
/// layering on it, and only one applies per button. So this is a plain view modifier, and it
/// reaches for the two effects that need no knowledge of the control's outline — a lift, and
/// shadows. A macOS 26 glass capsule and a `.bordered` rounded rect have different silhouettes
/// at every control size, and a hand-drawn ring would trace neither correctly; a shadow traces
/// whatever is actually rendered.
///
/// So the ring is a tight zero-offset halo rather than a stroke, and the numbers are still
/// `.filled`'s, out of the same table as every other variant.
///
/// Apply it **above** any `.disabled(…)` on the button, so the modifier sits inside that scope
/// and can read `isEnabled` — a greyed-out Back arrow must not lift.
public struct ChromeHoverModifier: ViewModifier {
    let tint: Color

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var metrics: HoverAffordanceMetrics {
        .resolve(variant: .chrome,
                 phase: isHovering ? .hover : .rest,
                 isEnabled: isEnabled,
                 reduceMotion: reduceMotion)
    }

    public func body(content: Content) -> some View {
        content
            // A drawn wash, sized to the control's own frame. Capsule because that is the macOS
            // 26 Liquid Glass button shape; `.bordered`'s rounded rect will show a little of it
            // at the corners, which reads as a glow rather than a mistake.
            //
            // No filters anywhere in here — no `compositingGroup()`, no `.saturation()`. Each
            // forces an offscreen or filter pass, and Liquid Glass renders nothing through one.
            // That is what made the first two versions of this modifier invisible.
            .background(Capsule().fill(tint.opacity(metrics.wash)))
            .shadow(color: tint.opacity(metrics.ring), radius: 3)
            .shadow(color: tint.opacity(metrics.shadow), radius: 5, y: 3)
            .offset(y: metrics.lift)
            .onHover { isHovering = isEnabled && $0 }
            .animation(.easeOut(duration: isHovering ? 0.12 : 0.18), value: isHovering)
    }
}

public extension View {
    /// See `ChromeHoverModifier`. Press feedback is left to the system style, which already
    /// darkens a bordered or glass button convincingly — hover was the missing half.
    func chromeHover(tint: Color = .accentColor) -> some View {
        modifier(ChromeHoverModifier(tint: tint))
    }
}

/// The trailing disclosure chevron on a `.row` button: it takes the tint and slides a couple of
/// points toward the edge while the row is engaged.
///
/// A 11pt chevron parked at the far end of a wide row is a weak affordance on its own — the
/// pointer usually enters hundreds of points away from it. Moving it in step with the row's wash
/// ties the two ends of the target together, so the row reads as one thing.
public struct HoverChevron: View {
    private let tint: Color
    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tint: Color = .accentColor) {
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(phase.isEngaged ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
            .offset(x: (phase.isEngaged && !reduceMotion) ? 2 : 0)
            // Matched to the style's own asymmetric timing so the chevron and the wash behind it
            // arrive and leave together instead of chasing each other.
            .animation(.easeOut(duration: phase == .rest ? 0.18 : 0.12), value: phase)
    }
}
