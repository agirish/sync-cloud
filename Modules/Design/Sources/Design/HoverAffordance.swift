import SwiftUI

// MARK: - Hover affordance
//
// `.plain` and `.borderless` buttons draw their own chrome, so AppKit gives them no hover state
// and nothing says they are clickable. This `ButtonStyle` answers that: it washes the hit shape in
// the app hue on hover and sinks it slightly on press.
//
// The numbers live in `HoverAffordanceMetrics` so they can be asserted directly; the style only
// paints what the metrics resolve to.

/// Which hover treatment a control wears. The variant picks the numbers *and* the default hit
/// shape; a caller whose control isn't the usual shape for its variant overrides `shape`.
public enum HoverAffordanceVariant: String, CaseIterable, Sendable {
    /// A bare icon with no chrome of its own: toolbar glyphs, inspector toggles, row actions.
    case glyph
    /// A chip or tab that fills when selected: hover previews the fill it would take.
    case segment
    /// A control that already carries a solid fill. No wash (nothing to wash over): a hairline ring
    /// and a 1pt lift instead.
    case filled
    /// A round floating control, like the seam's swap button.
    case circular
    /// A full-width list row whose whole area is the target. A quieter wash, since it covers far
    /// more pixels than a glyph.
    case row
    /// A small dismiss glyph inside a field or chip. Washes in ink, not the accent: these clear or
    /// remove something, and an inviting accent bloom misreads the action.
    case inline
    /// A button keeping its system chrome (`.glass` or `.bordered`). See `ChromeHoverModifier` for
    /// why this can't be a `ButtonStyle`. Louder than `.filled`, because a macOS 26 glass capsule
    /// is nearly transparent at rest, so there's no fill to deepen and the wash carries the whole
    /// signal.
    case chrome
}

/// The hit shape the wash is drawn in. A closed enum rather than a generic `some Shape`, which
/// couldn't be carried through the `static func` shorthand call sites use.
public enum HoverAffordanceShape: Equatable, Sendable {
    case capsule
    case circle
    case roundedRect(CGFloat)

    /// What each variant wears unless the call site says otherwise. `.segment`'s capsule suits most
    /// `.segment` controls (chips, pills, the workspace bar), so it stays the default.
    ///
    /// Check both arms of `isSelected ? .filled : .segment`: `.filled` defaults to a capsule too,
    /// so a mis-shaped control is wrong selected (a pill-shaped ring round a rounded rect) as well
    /// as hovered.
    ///
    /// Override `shape:` when either is true of the control:
    ///
    /// - **It draws a non-capsule ground.** The wash lands on that ground, so a capsule over a
    ///   rounded rect pulls its ends in past the corners and leaves the fill showing round the
    ///   wash. Invisible until the control gets a resting ground. Name the outline once and draw
    ///   the ground from the same value you hand this style (`PaneTabStrip.chipShape`,
    ///   `DestinationRowShape`; see `HoverAffordanceOutline`). The hit shape may differ: a tab's
    ///   target is its whole frame.
    /// - **It is tall relative to its width.** A capsule's radius is half the short side, so on a
    ///   squarish control the wash is a lozenge. `SettingsView`'s hue swatch (a disc over its
    ///   caption) takes `.roundedRect(8)`.
    public static func `default`(for variant: HoverAffordanceVariant) -> HoverAffordanceShape {
        switch variant {
        case .glyph: return .roundedRect(8)
        case .segment: return .capsule
        case .filled: return .capsule
        case .circular: return .circle
        case .row: return .roundedRect(7)
        case .inline: return .circle
        // Unused: `chromeHover` never draws a shape, because it can't know one.
        case .chrome: return .capsule
        }
    }
}

/// The outline a ``HoverAffordanceShape`` names, as a real `InsettableShape`.
///
/// This lets a control state its outline once. Otherwise it states it three times (the
/// `.background` it fills, the `.contentShape` it declares, the `shape:` it hands this style), and
/// nothing makes them agree. With this type all three can be the same value:
///
/// ```swift
/// enum DestinationRowShape {
///     static let kind = HoverAffordanceShape.roundedRect(Radius.chip)   // for the style
///     static let outline = kind.outline                                 // for the drawing
/// }
/// // …
/// .background(DestinationRowShape.outline.fill(accent.opacity(PaneSelectionWash.active)))
/// .contentShape(DestinationRowShape.outline)
/// // …
/// .buttonStyle(.hoverAffordance(.segment, tint: accent, shape: DestinationRowShape.kind))
/// ```
///
/// Drawing delegates to `Capsule()`, `Circle()` and a continuous `RoundedRectangle`.
/// `HoverAffordanceOutlineTests` renders every case both ways, filled and `strokeBorder`-ed, and
/// compares the bitmaps exactly.
public struct HoverAffordanceOutline: InsettableShape {
    /// Which outline this is. Named `kind` so `.kind` reads right when handed back to
    /// `.hoverAffordance(_:tint:shape:)`.
    public var kind: HoverAffordanceShape
    /// How far the outline is pulled in, which is how `strokeBorder` keeps a stroke inside the
    /// shape instead of straddling its edge.
    public var inset: CGFloat

    public init(kind: HoverAffordanceShape, inset: CGFloat = 0) {
        self.kind = kind
        self.inset = inset
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        switch kind {
        case .capsule:
            // Plain `Capsule()`. `Capsule(style: .continuous)` renders identically (a capsule's
            // corner is a full semicircle with nothing to smooth), so the render test can't pin the
            // spelling.
            return Capsule().path(in: r)
        case .circle:
            return Circle().path(in: r)
        case .roundedRect(let radius):
            // The corner tightens with the inset, keeping an inset rounded rect concentric with its
            // original rather than square-shouldered. That is `RoundedRectangle.inset(by:)`'s
            // behaviour, undocumented; the render test pins it.
            return RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous)
                .path(in: r)
        }
    }

    public func inset(by amount: CGFloat) -> HoverAffordanceOutline {
        HoverAffordanceOutline(kind: kind, inset: inset + amount)
    }
}

public extension HoverAffordanceShape {
    /// This shape as something drawable; see ``HoverAffordanceOutline``.
    var outline: HoverAffordanceOutline { HoverAffordanceOutline(kind: self) }
}

/// Where a hover-affordance button currently is. Published into the environment so a label's
/// subviews (a chevron that slides, a fill that deepens) react in step with the style's wash.
public enum HoverAffordancePhase: Sendable {
    case rest, hover, pressed

    /// True for anything the pointer is engaged with, which is what most call sites branch on.
    public var isEngaged: Bool { self != .rest }
}

// MARK: - Metrics

/// The resolved appearance for one variant in one phase. Every number the style paints comes
/// from here, so the whole affordance is assertable without rendering a view.
public struct HoverAffordanceMetrics: Equatable, Sendable {
    /// The same metrics for a control seated on glass (a chrome glass ground, or a selection lens
    /// under its label). The glass doesn't move, so neither may the label: no lift and no shadow,
    /// or its wash and ring would rise off the capsule. Wash, ring and press scale stay.
    public func seated(_ onGlass: Bool) -> HoverAffordanceMetrics {
        guard onGlass else { return self }
        var m = self
        m.lift = 0
        m.shadow = 0
        return m
    }

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

    /// Everything off: a control at rest, or a disabled one in any phase.
    public static let none = HoverAffordanceMetrics()

    /// Standard intensity. Hover is a wash plus, on the two variants that float, a 1pt lift; press
    /// deepens the wash and sinks the control. Nothing grows on hover: a target that widens under
    /// the pointer invites misclicks, so the only scale is the sub-1 press.
    public static func resolve(variant: HoverAffordanceVariant,
                               phase: HoverAffordancePhase,
                               isEnabled: Bool = true,
                               reduceMotion: Bool = false) -> HoverAffordanceMetrics {
        // A disabled control must look inert whatever the pointer does. SwiftUI still delivers
        // `onHover` to a disabled button, so this guard is load-bearing.
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

        // A real wash, like every other variant. Effects that light the control from outside (a
        // halo, a saturation filter) are invisible here: a macOS 26 glass button is nearly
        // transparent at rest, and a filter pass over glass can render nothing at all. See
        // `PaneNavMetrics` for the measured outlines.
        case (.chrome, .hover):   m = .init(wash: 0.22, ring: 0.30, lift: -1, shadow: 0.20)
        case (.chrome, .pressed): m = .init(wash: 0.30, ring: 0.30)
        }

        // Reduce Motion drops everything that moves and keeps everything that colours, so the
        // affordance survives the setting.
        if reduceMotion {
            m.lift = 0
            m.scale = 1
        }
        return m
    }

    /// Whether this variant can ever draw a shadow, i.e. whether the style needs a compositing
    /// group.
    ///
    /// `.compositingGroup()` makes the label, wash and ring cast one shadow instead of three, but
    /// it forces an offscreen layer, which `.glyph` and `.row` (the most numerous, never shadowed)
    /// don't need.
    ///
    /// Keyed on the variant, not on `metrics.shadow > 0`: the variant is fixed per button, while
    /// branching on the live phase would swap `_ConditionalContent` arms on hover, rebuilding the
    /// caller's label, losing its `@State` and restarting the animation.
    public static func castsShadow(variant: HoverAffordanceVariant) -> Bool {
        switch variant {
        case .filled, .circular, .chrome: return true
        case .glyph, .segment, .row, .inline: return false
        }
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
/// Replaces `.buttonStyle(.plain)` / `.buttonStyle(.borderless)`, which give no hover state.
public struct HoverAffordanceStyle: ButtonStyle {
    let variant: HoverAffordanceVariant
    /// nil: the hue the user picked, read where the button is drawn (`StoredHueReader`).
    let tint: Color?
    let shape: HoverAffordanceShape

    @ViewBuilder
    public func makeBody(configuration: Configuration) -> some View {
        // The hover flag needs `@State`, and a `ButtonStyle` isn't a `View`, hence the nested body
        // type.
        if let tint {
            HoverAffordanceBody(variant: variant, tint: tint, shape: shape, configuration: configuration)
        } else {
            StoredHueReader { hue in
                HoverAffordanceBody(variant: variant, tint: hue.accentColor, shape: shape,
                                    configuration: configuration)
            }
        }
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
    /// Seated on a bar button's glass (`ChromeGlass`): no lift, no shadow.
    @Environment(\.chromeGlassDrawn) private var onGlass

    private var phase: HoverAffordancePhase {
        guard isEnabled else { return .rest }
        if configuration.isPressed { return .pressed }
        return isHovering ? .hover : .rest
    }

    private var metrics: HoverAffordanceMetrics {
        .resolve(variant: variant, phase: phase, isEnabled: isEnabled, reduceMotion: reduceMotion)
            .seated(onGlass)
    }

    /// `.inline` washes in ink; every other variant washes in the app hue.
    private var washColor: Color { variant == .inline ? .primary : tint }

    var body: some View {
        // The group and shadow exist only for variants that can cast one; see
        // `HoverAffordanceMetrics.castsShadow(variant:)` for why this branches on the variant
        // (fixed per button), not the live phase.
        shadowed(configuration.label.background(washShape).overlay(ringShape))
            .offset(y: metrics.lift)
            .scaleEffect(metrics.scale)
            .environment(\.hoverAffordancePhase, phase)
            .onHover { hovering in
                // Guarded so a disabled control can't get stuck showing a hover it will never
                // repaint: SwiftUI keeps delivering `onHover` to disabled buttons.
                isHovering = isEnabled && hovering
            }
            // Asymmetric on purpose: a fast in reads as responsive, and the slower out keeps a
            // pointer crossing a row of toolbar glyphs from strobing.
            .animation(.easeOut(duration: phase == .rest ? 0.18 : 0.12), value: phase)
    }

    /// Flattens `content` into one layer and drops the lift shadow under it, for the variants that
    /// lift. Everything else is handed straight back, so no offscreen layer is spent on a shadow
    /// that is always transparent.
    @ViewBuilder
    private func shadowed(_ content: some View) -> some View {
        if HoverAffordanceMetrics.castsShadow(variant: variant) {
            content
                .compositingGroup()
                .shadow(color: tint.opacity(metrics.shadow), radius: 5, x: 0, y: 3)
        } else {
            content
        }
    }

    // Both go through `HoverAffordanceOutline`, so a call site can hand its ground and this style
    // one shared outline value.
    private var washShape: some View {
        shape.outline.fill(washColor.opacity(metrics.wash))
    }

    private var ringShape: some View {
        shape.outline.strokeBorder(tint.opacity(metrics.ring), lineWidth: 0.75)
    }
}

public extension ButtonStyle where Self == HoverAffordanceStyle {
    /// The chrome-less button style with a hover state: the replacement for `.plain` and
    /// `.borderless` on any control that draws its own look.
    ///
    /// - Parameters:
    ///   - variant: which treatment to wear; also picks the default hit shape.
    ///   - tint: the wash and ring color, normally the window's `LiquidGlassHue.accentColor`.
    ///           nil, the default, reads the stored hue — never the system accent, which ignores
    ///           the one the user picked.
    ///   - shape: overrides the variant's default hit shape.
    static func hoverAffordance(_ variant: HoverAffordanceVariant,
                                tint: Color? = nil,
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
/// style's body and would win. Call sites that want the ink to move use this instead of a flat
/// `.foregroundStyle(.secondary)`.
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

    /// Tints a glyph with `color` while its enclosing hover-affordance control is engaged, and
    /// leaves its resting appearance untouched.
    ///
    /// Unlike `hoverInk` it names no resting colour, so it can go on a control whose rest colour
    /// comes from elsewhere (a system button style) without disturbing it.
    func hoverTint(_ color: Color) -> some View {
        modifier(HoverTintModifier(color: color))
    }
}

/// See `View.hoverTint(_:)`.
public struct HoverTintModifier: ViewModifier {
    let color: Color
    @Environment(\.hoverAffordancePhase) private var phase

    public func body(content: Content) -> some View {
        // Applies nothing at rest: restating a resting colour would override the enclosing button
        // style's choice.
        if phase.isEngaged {
            content.foregroundStyle(color)
        } else {
            content
        }
    }
}

// MARK: - System-chrome buttons

/// Hover feedback for a button that keeps its system chrome: anything wearing
/// `chromeButtonStyle`, or a bare `.bordered`.
///
/// `HoverAffordanceStyle` can't help here: a `ButtonStyle` replaces the chrome rather than layering
/// on it, and only one applies per button. So this is a view modifier using effects that need no
/// knowledge of the control's outline. A glass capsule and a `.bordered` rounded rect differ in
/// silhouette at every control size, so a drawn ring would trace neither; a shadow traces whatever
/// renders. The ring is therefore a tight zero-offset halo, with the numbers from the `.chrome` row
/// of the same table.
///
/// Apply it **above** any `.disabled(…)` on the button, so it can read `isEnabled`: a greyed-out
/// Back arrow must not lift.
public struct ChromeHoverModifier: ViewModifier {
    /// nil: the hue the user picked, read where the control is drawn (`StoredHueReader`).
    let tint: Color?
    /// Whether a selection lens sits under this control right now (its chosen item). On the lens it
    /// doesn't lift: the lens is drawn by its host, outside the item, and stays put.
    let onLens: Bool

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chromeGlassDrawn) private var onGlass
    @Environment(\.selectionLensMaterial) private var lensMaterial

    private var metrics: HoverAffordanceMetrics {
        .resolve(variant: .chrome,
                 phase: isHovering ? .hover : .rest,
                 isEnabled: isEnabled,
                 reduceMotion: reduceMotion)
            .seated(onGlass || (onLens && lensMaterial != .today))
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let tint {
            hovering(content, tint: tint)
        } else {
            StoredHueReader { hue in hovering(content, tint: hue.accentColor) }
        }
    }

    private func hovering(_ content: Content, tint: Color) -> some View {
        content
            // A drawn wash, sized to the control's frame. Capsule, the macOS 26 Liquid Glass button
            // shape; on `.bordered`'s rounded rect a little shows at the corners, which reads as a
            // glow.
            //
            // **No filters in here**: no `compositingGroup()`, no `.saturation()`. Each forces an
            // offscreen or filter pass, and Liquid Glass renders nothing through one.
            .background(Capsule().fill(tint.opacity(metrics.wash)))
            .shadow(color: tint.opacity(metrics.ring), radius: 3)
            .shadow(color: tint.opacity(metrics.shadow), radius: 5, y: 3)
            .offset(y: metrics.lift)
            // Published so the label can answer too: a wash on translucent glass can render as
            // nothing, but a glyph taking the accent depends on none of that.
            .environment(\.hoverAffordancePhase, isHovering && isEnabled ? .hover : .rest)
            .onHover { isHovering = isEnabled && $0 }
            .animation(.easeOut(duration: isHovering ? 0.12 : 0.18), value: isHovering)
    }
}

public extension View {
    /// See `ChromeHoverModifier`. Press feedback is left to the system style, which already darkens
    /// a bordered or glass button.
    ///
    /// - Parameter onLens: true for a selection-lens control's chosen item, which sits on the lens
    ///   in Frosted and Clear and so must not lift off it. Apply inside the lens's host.
    func chromeHover(tint: Color? = nil, onLens: Bool = false) -> some View {
        modifier(ChromeHoverModifier(tint: tint, onLens: onLens))
    }
}

/// The trailing disclosure chevron on a `.row` button: it takes the tint and slides a couple of
/// points toward the edge while the row is engaged.
///
/// An 11pt chevron at the far end of a wide row is a weak affordance alone; the pointer usually
/// enters far from it. Moving it with the row's wash ties the two ends of the target together.
public struct HoverChevron: View {
    /// nil: the hue the user picked (`StoredHueReader`).
    private let tint: Color?
    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(tint: Color? = nil) {
        self.tint = tint
    }

    @ViewBuilder
    public var body: some View {
        if let tint {
            chevron(tint)
        } else {
            StoredHueReader { hue in chevron(hue.accentColor) }
        }
    }

    private func chevron(_ tint: Color) -> some View {
        Image(systemName: "chevron.right")
            .scaledFont(.caption)
            .foregroundStyle(phase.isEngaged ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
            .offset(x: (phase.isEngaged && !reduceMotion) ? 2 : 0)
            // Matched to the style's asymmetric timing so the chevron and the wash arrive and leave
            // together.
            .animation(.easeOut(duration: phase == .rest ? 0.18 : 0.12), value: phase)
    }
}
