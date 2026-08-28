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
    ///
    /// **`.segment`'s capsule is right for a clear majority — so the rule for overriding it is
    /// written here rather than rediscovered a third time.** Censused 2026-08-27 over all
    /// twenty-six `.segment` call sites: sixteen draw a ground of their own, and **eleven of those
    /// sixteen are genuine capsules** — the suggestion chips in `LogViewer` and `DifferencesView`,
    /// `HelpBook`'s topic chips, all three `SetupSheet` chips, the log level chips, both
    /// `DashboardViews` pills, `RuleOfferPrompt`'s match chips and the workspace bar. The other ten
    /// paint nothing at rest and show only the affordance itself. Flipping this default to a
    /// rounded rect would break eleven correct controls to fix three, which is why it stays a
    /// capsule.
    ///
    /// Of the five that draw a non-capsule ground, **four had shipped wearing a capsule**: the tab
    /// strip (fixed in `153b5ae7`) and all three of the destination picker's rows. Only
    /// `SettingsLayout`'s tab row was written with the override from the start. That is the ratio
    /// the rule below exists to change.
    ///
    /// **Count with the variant, not the call's opening.** Eight of those twenty-six spell it
    /// `isSelected ? .filled : .segment`, so `grep 'hoverAffordance(\.segment'` finds eighteen of
    /// them (plus this comment) and misses two live defects; `grep 'hoverAffordance(' |
    /// grep '\.segment'` finds all twenty-six. Both
    /// arms matter — `.filled` defaults to a capsule too, so a mis-shaped row is wrong selected
    /// (a hairline ring tracing a pill round a rounded rectangle) as well as hovered.
    ///
    /// Override `shape:` when either is true of the control:
    ///
    /// - **It draws a non-capsule ground.** The wash lands *on* that ground, so a capsule over a
    ///   6pt rounded rect pulls its ends in past the corners and leaves the fill showing round the
    ///   outside of the wash. Invisible while the control has no resting ground — which is exactly
    ///   how it hid in the tab strip until `153b5ae7` gave every chip a slab — and visible the
    ///   moment one arrives. `PaneTabStrip` and all three of `DestinationPicker`'s row surfaces are
    ///   this case, and each now names its outline once — `PaneTabStrip.chipShape` and
    ///   `DestinationRowShape` — and draws its ground from the same value it hands this style, so
    ///   the two cannot drift apart again (see `HoverAffordanceOutline`). The picker's hit shapes
    ///   come from it too; the strip's does not, and should not — a tab's target is its whole frame
    ///   including the padding around the chip.
    /// - **It is tall relative to its width**, ground or no ground. A capsule's radius is half the
    ///   short side, so on a squarish or upright control the wash is a lozenge rather than a hint of
    ///   the control's own shape. `SettingsView`'s hue swatch — a disc stacked over its caption — is
    ///   this case, and takes `.roundedRect(8)`.
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

/// The outline a ``HoverAffordanceShape`` names, as a real `InsettableShape`.
///
/// **This is the seam that lets a control have exactly one outline.** The recurring defect here is
/// not that a call site picks the wrong shape, it is that a control states its shape three times —
/// once in the `.background` it fills, once in the `.contentShape` it declares, and once in the
/// `shape:` it hands this style — and nothing makes the three agree. Two of the three are ordinary
/// SwiftUI shapes and the third is an enum case, so they cannot even be compared. Given this type
/// they can all be the *same value*:
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
/// Drawing is delegated to the same three SwiftUI shapes the style used to switch over inline —
/// `Capsule()`, `Circle()`, and a **continuous** `RoundedRectangle` — so this replaced those
/// switches without changing a pixel. `HoverAffordanceOutlineTests` renders every case both
/// ways and compares the bitmaps exactly, filled and `strokeBorder`-ed, because "it draws the same
/// thing" is the one claim that would be worthless taken on trust.
public struct HoverAffordanceOutline: InsettableShape {
    /// Which outline this is. Named `kind` rather than `shape` so `.kind` reads correctly at the
    /// call site that hands it back to `.hoverAffordance(_:tint:shape:)`.
    public var kind: HoverAffordanceShape
    /// How far the outline has been pulled in, which is how `strokeBorder` keeps a stroke inside
    /// the shape instead of straddling its edge.
    public var inset: CGFloat

    public init(kind: HoverAffordanceShape, inset: CGFloat = 0) {
        self.kind = kind
        self.inset = inset
    }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        switch kind {
        case .capsule:
            // Spelled exactly as the style spelled it. Not because the alternative would look
            // different — `Capsule(style: .continuous)` renders byte-identically at every size
            // measured, a capsule's corner being a full semicircle with nothing left to smooth —
            // but because keeping the spelling is what makes the equivalence obvious to read as
            // well as asserted. The render test cannot pin this one either way.
            return Capsule().path(in: r)
        case .circle:
            return Circle().path(in: r)
        case .roundedRect(let radius):
            // The corner tightens with the inset, which is what keeps an inset rounded rect
            // concentric with the one it came from rather than square-shouldered inside it. This
            // is `RoundedRectangle.inset(by:)`'s own behaviour, and the render test is what says
            // so — it is not documented anywhere that binds.
            return RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous)
                .path(in: r)
        }
    }

    public func inset(by amount: CGFloat) -> HoverAffordanceOutline {
        HoverAffordanceOutline(kind: kind, inset: inset + amount)
    }
}

public extension HoverAffordanceShape {
    /// This shape as something drawable — see ``HoverAffordanceOutline``.
    var outline: HoverAffordanceOutline { HoverAffordanceOutline(kind: self) }
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

    /// Whether this variant can ever draw a shadow — i.e. whether the style needs to isolate its
    /// content into a compositing group at all.
    ///
    /// A shadow is applied to whatever the group flattens, so `.compositingGroup()` is what keeps
    /// the label, its wash and its ring casting ONE shadow instead of three. But it also forces an
    /// offscreen layer, and the style used to take that cost on every control it decorates —
    /// including `.glyph` and `.row`, which are by far the most numerous and whose shadow alpha is
    /// zero in every phase of the table above.
    ///
    /// Keyed on the VARIANT, deliberately, and not on `metrics.shadow > 0`. The variant is fixed
    /// for the lifetime of a button, so this predicate picks one branch and stays there; branching
    /// on the live phase would swap `_ConditionalContent` arms on hover, which destroys and
    /// rebuilds the caller's label — losing any `@State` inside it and restarting the very
    /// animation the affordance exists to run.
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
        // The group + shadow only exist for the variants that can actually cast one — see
        // `HoverAffordanceMetrics.castsShadow(variant:)` for why this branches on the variant
        // (fixed per button) rather than on the live phase.
        shadowed(configuration.label.background(washShape).overlay(ringShape))
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

    /// Flattens `content` into one layer and drops the lift shadow under it — for the variants
    /// that lift. Everything else is handed straight back, so no offscreen layer is allocated for
    /// a shadow that is transparent in every phase.
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

    // Both of these used to switch over `shape` inline, which meant the wash the style paints and
    // the ground a call site draws were two independent spellings of "the same" outline with
    // nothing holding them together. They go through `HoverAffordanceOutline` now so a call site
    // can hand its ground and this style one shared value.
    private var washShape: some View {
        shape.outline.fill(washColor.opacity(metrics.wash))
    }

    private var ringShape: some View {
        shape.outline.strokeBorder(tint.opacity(metrics.ring), lineWidth: 0.75)
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

    /// Tints a glyph with `color` while its enclosing hover-affordance control is engaged, and
    /// leaves its resting appearance **completely untouched** otherwise.
    ///
    /// Unlike `hoverInk` this names no resting color, so it can be dropped onto a control whose
    /// rest colour comes from somewhere else — a system button style, say — without disturbing it.
    func hoverTint(_ color: Color) -> some View {
        modifier(HoverTintModifier(color: color))
    }
}

/// See `View.hoverTint(_:)`.
public struct HoverTintModifier: ViewModifier {
    let color: Color
    @Environment(\.hoverAffordancePhase) private var phase

    public func body(content: Content) -> some View {
        // Deliberately applies nothing at rest rather than re-stating a resting color — restating
        // one would override whatever the enclosing button style had chosen.
        if phase.isEngaged {
            content.foregroundStyle(color)
        } else {
            content
        }
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
            // Published so the label can answer too. On Liquid Glass the wash has to survive a
            // translucent chrome sampling its own backdrop, and that is exactly the kind of thing
            // that quietly renders as nothing; a glyph taking the accent depends on none of it.
            .environment(\.hoverAffordancePhase, isHovering && isEnabled ? .hover : .rest)
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
            .scaledFont(.caption)
            .foregroundStyle(phase.isEngaged ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
            .offset(x: (phase.isEngaged && !reduceMotion) ? 2 : 0)
            // Matched to the style's own asymmetric timing so the chevron and the wash behind it
            // arrive and leave together instead of chasing each other.
            .animation(.easeOut(duration: phase == .rest ? 0.18 : 0.12), value: phase)
    }
}
