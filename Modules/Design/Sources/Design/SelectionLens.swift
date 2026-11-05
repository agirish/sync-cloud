import SwiftUI

// MARK: - Selection lens
//
// One marker that moves, made of the appearance you chose, for every control that marks one
// choice among siblings: the workspace bar, a pane's tabs, Organize's rail, the capsules, rails,
// chips, tiles and swatches. Solid draws the control's own marker and motion untouched: no lens,
// and the stops publish nothing (`SelectionLensTodayMarker`). Frosted and Clear draw one lens per
// control, a flat fill of the marker's colour (`SelectionLensRule.lensFill`) whose strength
// follows the Tint slider (`SelectionLensRule.fillStrength`). It glides between choices on
// springs, its leading edge arriving first so it stretches a little, and settles once. Only
// Increase Contrast gives it an edge. The search field (`ExpandingSearch`) and Organize's counts
// (`SelectionLensArrival`) arrive on the same motion.
//
// `selectionLensAppearance` defaults to Solid and the window roots set it from the stored settings
// (`selectionLensAppearanceFromDefaults()`), so a control rendered on its own, as in every render
// test, draws today's marker, and a root that forgot the modifier fails safe to it.

/// What the app's appearance settings say about selection markers, carried down the view tree.
public struct SelectionLensAppearance: Equatable, Sendable {
    public var level: GlassLevel
    public var hue: LiquidGlassHue
    /// The Tint slider, 0...1 (`LiquidGlass.tintKey`).
    public var tint: Double
    /// A test seam. Glass draws nothing into an offscreen `cacheDisplay` capture, so with this set
    /// Frosted and Clear both draw a flat ``SelectionLensRule/probeColor`` shape in the lens's place
    /// (same geometry, motion, ring and rule), and chrome glass draws ``ChromeGlass/probeColor``.
    /// The probe draws no rim; the rim is drawn outside the glass, so tests read it at real Clear.
    public var drawsProbe: Bool

    public init(level: GlassLevel, hue: LiquidGlassHue, tint: Double, drawsProbe: Bool = false) {
        self.level = level
        self.hue = hue
        self.tint = tint
        self.drawsProbe = drawsProbe
    }

    /// What a view sees when no window root has set anything: Solid, so the control draws its own
    /// marker. Blue and Tint 0 are the stored settings' own defaults, and are unused at Solid.
    public static let today = SelectionLensAppearance(level: .solid, hue: defaultHue, tint: defaultTint)

    /// The stored settings' defaults — the values every `@AppStorage` reader of these keys in the
    /// app falls back to. Named once here, so `SelectionLensAppearanceFromDefaults` and
    /// `stored(in:)` cannot drift apart.
    public static let defaultLevel: GlassLevel = .frosted
    public static let defaultHue: LiquidGlassHue = .blue
    public static let defaultTint: Double = 0
}

/// What a selection lens is drawn in.
public enum SelectionLensMaterial: Equatable, Sendable {
    /// No lens: the control draws today's marker itself.
    case today
    /// Frosted Liquid Glass (`Glass.regular`).
    case frosted
    /// Clear Liquid Glass (`Glass.clear`).
    case clear
    /// The render-test stand-in — see ``SelectionLensAppearance/drawsProbe``.
    case probe
}

/// The decisions, as pure functions, so a test asserts what the views actually call.
public enum SelectionLensRule {

    /// Which material an appearance asks for.
    ///
    /// Reduce Transparency draws today's marker. Apple's glass turns more opaque under the setting
    /// by itself, but the lens's fill is this app's own translucency, so the honest answer to "less
    /// transparency" is the opaque marker Solid already draws.
    public static func material(for appearance: SelectionLensAppearance,
                                reduceTransparency: Bool) -> SelectionLensMaterial {
        if reduceTransparency { return .today }
        switch appearance.level {
        case .solid: return .today
        case .frosted: return appearance.drawsProbe ? .probe : .frosted
        case .clear: return appearance.drawsProbe ? .probe : .clear
        }
    }

    /// The chosen one's fill at Tint 0, and at accent None at every Tint. It is what marks the
    /// choice, since Frosted and Clear draw no rim, so it never reaches 0, accent None included.
    public static let chosenFillFloor: Double = 0.18

    /// The chosen one's fill at Tint 100, still a soft wash: the lens has a `.primary` label in
    /// light mode, and a flat fill at the full accent would be Solid's opaque marker with the wrong
    /// ink on it.
    public static let chosenFillCeiling: Double = 0.35

    /// How strong the lens's fill is for a marker that carries its full colour: the Tint slider on
    /// the window background's ramp (`LiquidGlass.tintRamp`), from ``chosenFillFloor`` to
    /// ``chosenFillCeiling``, the same for every hue. Accent None stays at the floor, having no hue
    /// for the slider to strengthen.
    public static func fillStrength(hue: LiquidGlassHue, tint: Double) -> Double {
        hue == .none ? chosenFillFloor
            : chosenFillFloor + (chosenFillCeiling - chosenFillFloor) * LiquidGlass.tintRamp(tint)
    }

    /// The opacity the lens fills its marker colour at: ``fillStrength(hue:tint:)``, but never more
    /// than the marker's own opacity, so a wash is never stronger than itself and a halo (opacity 0,
    /// a ring around a colour) stays unfilled.
    public static func tintOpacity(markerOpacity: Double, hue: LiquidGlassHue, tint: Double) -> Double {
        min(max(0, min(1, markerOpacity)), fillStrength(hue: hue, tint: tint))
    }

    /// The rim Increase Contrast draws, in the marker's colour.
    public static let increasedContrastRimWidth: CGFloat = 2.5

    /// The rim a lens draws in its marker's colour: only under Increase Contrast, which asks for
    /// edges, and never when the style has a ring of its own (two concentric strokes read as a
    /// double border). Otherwise the fill marks the choice (``chosenFillFloor``).
    public static func rimWidth(material: SelectionLensMaterial, hasRing: Bool, increasedContrast: Bool) -> CGFloat {
        guard !hasRing, increasedContrast else { return 0 }
        switch material {
        case .clear, .frosted: return increasedContrastRimWidth
        case .today, .probe: return 0
        }
    }

    /// Which Liquid Glass a material draws — nil where it draws none.
    public enum GlassVariant: Equatable, Sendable { case regular, clear }

    public static func glassVariant(_ material: SelectionLensMaterial) -> GlassVariant? {
        switch material {
        case .frosted: .regular
        case .clear: .clear
        case .today, .probe: nil
        }
    }

    /// What a lens is made of.
    public enum LensFill: Equatable, Sendable {
        /// A flat fill of the marker's colour at this opacity, edge to edge.
        case flat(Double)
        /// Untinted Liquid Glass — only for a marker that carries no colour (the accent swatch's halo).
        case glass(GlassVariant)
        /// The render-test stand-in.
        case probe
        /// No lens: `.today` draws the control's own marker.
        case none
    }

    /// A coloured lens is a flat fill, not tinted glass. Tinted glass keeps its own specular light,
    /// and at an 18% tint the bright bands along its top and bottom edges outshine the tint, so the
    /// choice reads as a pale stripe between two white ones. Glass stays only where there is no
    /// colour to carry: the halo, whose ring is the mark.
    public static func lensFill(material: SelectionLensMaterial, tintOpacity: Double) -> LensFill {
        switch material {
        case .today: return .none
        case .probe: return .probe
        case .frosted, .clear:
            if tintOpacity > 0 { return .flat(tintOpacity) }
            return glassVariant(material).map { .glass($0) } ?? .none
        }
    }

    /// Everything a host hands its lens beyond the stops: what it is drawn in, how much of the
    /// marker's colour it carries, and its rim. One function, so a test asserts what the host
    /// actually passes, not the parts.
    public struct LensSpec: Equatable, Sendable {
        public var material: SelectionLensMaterial
        public var tintOpacity: Double
        public var rimWidth: CGFloat
    }

    public static func lensSpec(style: SelectionLensStyle, appearance: SelectionLensAppearance,
                                reduceTransparency: Bool, increasedContrast: Bool) -> LensSpec {
        let material = material(for: appearance, reduceTransparency: reduceTransparency)
        return LensSpec(
            material: material,
            tintOpacity: tintOpacity(markerOpacity: style.markerOpacity, hue: appearance.hue, tint: appearance.tint),
            rimWidth: rimWidth(material: material, hasRing: style.ring != nil, increasedContrast: increasedContrast))
    }

    /// The hover style of one choice in a lens control: `.filled` for the chosen one at Solid; under
    /// a lens the chosen one takes `unselected`, having no fill of its own for `.filled`'s lift and
    /// shadow to belong to. See `selectionLensChoiceButtonStyle`.
    public static func choiceVariant(isSelected: Bool, material: SelectionLensMaterial,
                                     unselected: HoverAffordanceVariant) -> HoverAffordanceVariant {
        isSelected && material == .today ? .filled : unselected
    }

    /// The tint that style takes: `filledTint` where it is `.filled` and one is given — the on-fill
    /// colour a ring on a fill is drawn in — and `tint` everywhere else, the chosen one under a lens
    /// included: a white wash on glass is no hover at all.
    public static func choiceTint(variant: HoverAffordanceVariant, tint: Color, filledTint: Color?) -> Color {
        variant == .filled ? (filledTint ?? tint) : tint
    }

    /// The probe's colour: pure magenta, which no marker, glass or hue in the app paints, so a
    /// render test can count exactly its pixels.
    public static let probeColor = Color(red: 1, green: 0, blue: 1)
}

/// The motion, as pure geometry: where the lens is a given time into a move.
///
/// Each of the lens's four edges is its own damped spring. The edge leading the move is a touch
/// quicker and bouncier, so it arrives first and settles once; the edge behind is critically damped
/// and glides in after it; the two across follow without overshoot. The stretch between them is
/// the only "liquid" in it. A spring keeps position and speed continuous, so a second click mid-move
/// carries the speed on (`velocity(from:velocity:to:elapsed:)`) instead of stopping dead.
///
/// The springs use SwiftUI's own parameters (`Animation.spring(duration:bounce:)`).
public enum SelectionLensMotion {

    /// A damped spring, as `Animation.spring(duration:bounce:)` defines one: `duration` is the
    /// perceptual duration (the undamped period), `bounce` 0 is critically damped and higher values
    /// overshoot.
    public struct Spring: Equatable, Sendable {
        public let duration: Double
        public let bounce: Double

        public init(duration: Double, bounce: Double) {
            self.duration = duration
            self.bounce = bounce
        }

        /// Where a value starting at `x0` with speed `v0` (points per second) is `t` seconds into
        /// its spring towards `target`, and how fast it is going there.
        public func step(from x0: Double, velocity v0: Double, to target: Double,
                         at t: Double) -> (value: Double, velocity: Double) {
            let omega = 2 * Double.pi / duration
            let zeta = 1 - min(max(bounce, 0), 0.95)
            let d0 = x0 - target
            if zeta >= 1 {
                let c2 = v0 + omega * d0
                let decay = exp(-omega * t)
                return (target + (d0 + c2 * t) * decay, decay * (v0 - omega * t * c2))
            }
            let a = zeta * omega
            let omegaD = omega * (1 - zeta * zeta).squareRoot()
            let c1 = d0
            let c2 = (v0 + a * c1) / omegaD
            let decay = exp(-a * t)
            let cosine = cos(omegaD * t), sine = sin(omegaD * t)
            let value = target + decay * (c1 * cosine + c2 * sine)
            let velocity = decay * ((-a * c1 + omegaD * c2) * cosine + (-a * c2 - omegaD * c1) * sine)
            return (value, velocity)
        }

        /// The edge leading a move: arrives first, overshoots by about 1% of the trip, settles once.
        public static let lead = Spring(duration: 0.35, bounce: 0.18)
        /// The edge behind it: critically damped, so it glides in without overshooting. The gap
        /// between the two springs is the stretch, chosen to stay slight: an 88pt workspace segment
        /// reaches 103pt mid-move, a 28pt sidebar row moving five rows reaches 50pt, and all are
        /// within 0.3pt of their stops by about 0.53 s.
        public static let trail = Spring(duration: 0.40, bounce: 0)
        /// The two edges across the move — they only change when the stops differ in size.
        public static let across = Spring(duration: 0.38, bounce: 0)
    }

    /// How fast each edge is moving, in points per second.
    public struct EdgeVelocity: Equatable, Sendable {
        public var minX: Double, maxX: Double, minY: Double, maxY: Double

        public init(minX: Double = 0, maxX: Double = 0, minY: Double = 0, maxY: Double = 0) {
            self.minX = minX
            self.maxX = maxX
            self.minY = minY
            self.maxY = maxY
        }

        public static let zero = EdgeVelocity()
    }

    /// How long a move runs before the lens is placed exactly on its stop: by then the slowest
    /// spring is within a fifth of a point of it on a 400pt trip.
    public static let travelDuration: TimeInterval = 0.7
    /// Growing out of nothing (a filter chosen with none before).
    public static let appearDuration: TimeInterval = 0.45
    /// Melting into nothing (a filter cleared, a selection that leaves).
    public static let meltDuration: TimeInterval = 0.25
    /// How long a new lens takes to become fully opaque as it grows.
    static let appearFade: TimeInterval = 0.12

    /// The size a lens grows from and melts to, as a fraction of its stop.
    static let seedScale: CGFloat = 0.4

    /// The lens at one instant.
    public struct Frame: Equatable, Sendable {
        public var rect: CGRect
        public var opacity: Double

        public init(rect: CGRect, opacity: Double) {
            self.rect = rect
            self.opacity = opacity
        }
    }

    /// Whether a change of selection is shown as a move at all.
    ///
    /// No when Reduce Motion is on (the lens arrives without travelling, as the workspace bar's
    /// slide already does under the setting), when there is nothing to move, and — for a host that
    /// scrolls — when either end is off screen: a lens crossing rows the eye is not on says nothing.
    public static func travels(from: CGRect?, to: CGRect?, visibleRect: CGRect?,
                               reduceMotion: Bool) -> Bool {
        if reduceMotion { return false }
        if from == nil && to == nil { return false }
        if let from, let to, from == to { return false }
        if let visibleRect {
            if let from, !visibleRect.intersects(from) { return false }
            if let to, !visibleRect.intersects(to) { return false }
        }
        return true
    }

    /// Where the lens is `elapsed` seconds into a move from `from` (moving at `velocity`) to `to`.
    /// A nil `from` grows the lens out of the new stop; a nil `to` melts it into the old one. Past
    /// the move's duration it is exactly on its stop.
    ///
    /// `opacity` is how visible the lens was when the move began, below 1 when a click catches it
    /// mid-growth or mid-melt; a travel fades it the rest of the way in rather than jumping to full.
    public static func frame(from: CGRect?, velocity: EdgeVelocity = .zero, opacity: Double = 1,
                             to: CGRect?, elapsed: TimeInterval) -> Frame? {
        switch (from, to) {
        case (nil, nil):
            return nil
        case (nil, let to?):
            if elapsed >= appearDuration { return Frame(rect: to, opacity: 1) }
            let rect = edges(from: scaled(to, by: seedScale), velocity: .zero, to: to,
                             springs: .all(.lead), elapsed: elapsed).rect
            return Frame(rect: rect, opacity: min(1, max(0, elapsed) / appearFade))
        case (let from?, nil):
            // From however visible it already was: a melt that catches a growth part-way fades on
            // from there, rather than flashing to full first.
            let opacity = clamp(opacity) * (1 - max(0, elapsed) / meltDuration)
            guard opacity > 0 else { return nil }
            let rect = edges(from: from, velocity: velocity, to: scaled(from, by: seedScale),
                             springs: .all(.trail), elapsed: elapsed).rect
            return Frame(rect: rect, opacity: opacity)
        case (let from?, let to?):
            if elapsed >= travelDuration { return Frame(rect: to, opacity: 1) }
            let start = clamp(opacity)
            return Frame(rect: edges(from: from, velocity: velocity, to: to,
                                     springs: .travel(from: from, to: to), elapsed: elapsed).rect,
                         opacity: min(1, start + (1 - start) * max(0, elapsed) / appearFade))
        }
    }

    /// How fast each edge is moving `elapsed` seconds into the same move: what a second click
    /// mid-move carries into the next one. A growth and a melt carry theirs too.
    public static func velocity(from: CGRect?, velocity: EdgeVelocity = .zero, to: CGRect?,
                                elapsed: TimeInterval) -> EdgeVelocity {
        guard elapsed < travelDuration else { return .zero }
        switch (from, to) {
        case (nil, nil):
            return .zero
        case (nil, let to?):
            guard elapsed < appearDuration else { return .zero }
            return edges(from: scaled(to, by: seedScale), velocity: .zero, to: to,
                         springs: .all(.lead), elapsed: elapsed).velocity
        case (let from?, nil):
            guard elapsed < meltDuration else { return .zero }
            return edges(from: from, velocity: velocity, to: scaled(from, by: seedScale),
                         springs: .all(.trail), elapsed: elapsed).velocity
        case (let from?, let to?):
            return edges(from: from, velocity: velocity, to: to,
                         springs: .travel(from: from, to: to), elapsed: elapsed).velocity
        }
    }

    /// How far along a move from `from` to `to` the lens at `rect` is, 0...1, by its centre. A
    /// move that only resizes the lens is already there.
    public static func progress(from: CGRect, to: CGRect, at rect: CGRect) -> Double {
        let span = hypot(to.midX - from.midX, to.midY - from.midY)
        guard span > 0.5 else { return 1 }
        return clamp(hypot(rect.midX - from.midX, rect.midY - from.midY) / span)
    }

    /// Which way a move goes: along the axis it covers more distance on.
    public static func isVertical(from: CGRect, to: CGRect) -> Bool {
        abs(to.midY - from.midY) > abs(to.midX - from.midX)
    }

    /// One spring per edge.
    struct EdgeSprings: Equatable {
        var minX: Spring, maxX: Spring, minY: Spring, maxY: Spring

        static func all(_ spring: Spring) -> EdgeSprings {
            EdgeSprings(minX: spring, maxX: spring, minY: spring, maxY: spring)
        }

        /// The edge facing the move leads, the one behind it trails, the two across it follow.
        static func travel(from: CGRect, to: CGRect) -> EdgeSprings {
            if isVertical(from: from, to: to) {
                let down = to.midY >= from.midY
                return EdgeSprings(minX: .across, maxX: .across,
                                   minY: down ? .trail : .lead, maxY: down ? .lead : .trail)
            }
            let right = to.midX >= from.midX
            return EdgeSprings(minX: right ? .trail : .lead, maxX: right ? .lead : .trail,
                               minY: .across, maxY: .across)
        }
    }

    static func edges(from: CGRect, velocity v: EdgeVelocity, to: CGRect, springs: EdgeSprings,
                      elapsed: TimeInterval) -> (rect: CGRect, velocity: EdgeVelocity) {
        let t = max(0, elapsed)
        let minX = springs.minX.step(from: from.minX, velocity: v.minX, to: to.minX, at: t)
        let maxX = springs.maxX.step(from: from.maxX, velocity: v.maxX, to: to.maxX, at: t)
        let minY = springs.minY.step(from: from.minY, velocity: v.minY, to: to.minY, at: t)
        let maxY = springs.maxY.step(from: from.maxY, velocity: v.maxY, to: to.maxY, at: t)
        // Never inside out — a lens melting fast enough could cross its own edges.
        let left = min(minX.value, maxX.value), right = max(minX.value, maxX.value)
        let top = min(minY.value, maxY.value), bottom = max(minY.value, maxY.value)
        return (CGRect(x: left, y: top, width: right - left, height: bottom - top),
                EdgeVelocity(minX: minX.velocity, maxX: maxX.velocity,
                             minY: minY.velocity, maxY: maxY.velocity))
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    static func scaled(_ r: CGRect, by s: CGFloat) -> CGRect {
        let w = r.width * s, h = r.height * s
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }
}

/// How one control's marker looks, so its lens can look like it.
///
/// Built from what the control draws today (shape, colour, opacity), so a control's lens and its
/// Solid marker can't become two designs. The selection signature carries into the lens: a filled
/// control's lens is filled, a ringed one keeps its ring, the tab strip keeps its rule.
public struct SelectionLensStyle: Equatable {
    /// A stroke drawn around the lens, in full colour — Organize's 2pt ring, a tile's border, a
    /// swatch's halo.
    public struct Ring: Equatable {
        public var color: Color
        public var width: CGFloat
        public init(color: Color, width: CGFloat) {
            self.color = color
            self.width = width
        }
    }

    /// A short bar along the lens's bottom edge — the tab strip's 2pt rule.
    public struct Rule: Equatable {
        public var color: Color
        public var height: CGFloat
        public var inset: CGFloat
        public init(color: Color, height: CGFloat, inset: CGFloat) {
            self.color = color
            self.height = height
            self.inset = inset
        }
    }

    public var shape: HoverAffordanceShape
    /// The marker's colour today — `accentFillColor` for a fill, the accent for a wash.
    public var color: Color
    /// The opacity the marker paints `color` at today: 1 for a fill, 0.10–0.22 for a wash, 0 for a
    /// ring that carries no fill. The lens never fills stronger than this.
    public var markerOpacity: Double
    public var ring: Ring?
    public var rule: Rule?
    /// How far the lens extends past its stop — a halo drawn around a swatch rather than on it.
    public var outset: CGFloat
    /// How much of the lens shows: below 1 for a choice the control draws dimmed (a folder that
    /// can't be opened, a place that stopped answering), so the lens dims with the row as today's
    /// marker, drawn inside it, does.
    public var opacity: Double

    public init(shape: HoverAffordanceShape, color: Color, markerOpacity: Double,
                ring: Ring? = nil, rule: Rule? = nil, outset: CGFloat = 0, opacity: Double = 1) {
        self.shape = shape
        self.color = color
        self.markerOpacity = markerOpacity
        self.ring = ring
        self.rule = rule
        self.outset = outset
        self.opacity = opacity
    }

    /// A solid marker: the workspace bar, the capsules, the Settings and Help rails.
    public static func fill(_ shape: HoverAffordanceShape, color: Color) -> SelectionLensStyle {
        SelectionLensStyle(shape: shape, color: color, markerOpacity: 1)
    }

    /// A translucent marker: the folder sidebar, Restructure's chips.
    public static func wash(_ shape: HoverAffordanceShape, color: Color, opacity: Double) -> SelectionLensStyle {
        SelectionLensStyle(shape: shape, color: color, markerOpacity: opacity)
    }
}

/// Names one control's lens, so its stops and its host find each other and only each other. A
/// name, not the host's place in the tree, because one container can hold two lenses (the folder
/// sidebar marks its current source and its current folder).
public struct SelectionLensChannel: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

// MARK: - Environment

private struct SelectionLensAppearanceKey: EnvironmentKey {
    static let defaultValue = SelectionLensAppearance.today
}

private struct SelectionLensMaterialKey: EnvironmentKey {
    static let defaultValue = SelectionLensMaterial.today
}

public extension EnvironmentValues {
    /// The appearance the selection lenses below this point follow. Defaults to Solid; window
    /// roots set it from the stored settings with `selectionLensAppearanceFromDefaults()`.
    var selectionLensAppearance: SelectionLensAppearance {
        get { self[SelectionLensAppearanceKey.self] }
        set { self[SelectionLensAppearanceKey.self] = newValue }
    }

    /// What the nearest selection-lens host is drawing. Set by the host, read by
    /// ``SelectionLensTodayMarker`` and the stops. `.today` — the default, and what any control
    /// outside a host sees — means the control draws its own marker.
    var selectionLensMaterial: SelectionLensMaterial {
        get { self[SelectionLensMaterialKey.self] }
        set { self[SelectionLensMaterialKey.self] = newValue }
    }
}

/// Reads the three stored settings and hands them to every lens below. Applied at each window root.
public struct SelectionLensAppearanceFromDefaults: ViewModifier {
    @AppStorage(LiquidGlass.levelKey) private var levelRaw: String = SelectionLensAppearance.defaultLevel.rawValue
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = SelectionLensAppearance.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var tint: Double = SelectionLensAppearance.defaultTint

    public init() {}

    public func body(content: Content) -> some View {
        content.environment(\.selectionLensAppearance, SelectionLensAppearance(
            level: GlassLevel(rawValue: levelRaw) ?? SelectionLensAppearance.defaultLevel,
            hue: LiquidGlassHue(rawValue: hueRaw) ?? SelectionLensAppearance.defaultHue,
            tint: tint))
    }
}

public extension SelectionLensAppearance {
    /// The stored settings, read as the window roots read them — the same keys, the same defaults.
    static func stored(in defaults: UserDefaults) -> SelectionLensAppearance {
        SelectionLensAppearance(
            level: defaults.string(forKey: LiquidGlass.levelKey).flatMap(GlassLevel.init(rawValue:)) ?? defaultLevel,
            hue: defaults.string(forKey: LiquidGlass.hueKey).flatMap(LiquidGlassHue.init(rawValue:)) ?? defaultHue,
            tint: defaults.object(forKey: LiquidGlass.tintKey) as? Double ?? defaultTint)
    }

    /// One line for `~/sync-cloud.log` saying how the session draws selection and bar buttons:
    /// glass or today's markers, gliding or instant, edged for Increase Contrast or not. Logged at
    /// launch and whenever it would read differently, so a report about the lens can be told apart
    /// from one about Solid or an accessibility setting.
    func logLine(reduceTransparency: Bool, reduceMotion: Bool, increasedContrast: Bool = false) -> String {
        let accent = hue == .none ? "no accent" : "\(hue.displayName) accent"
        let settings = "\(level.displayName), \(accent), Tint \(Int((tint * 100).rounded()))%"
        let material = SelectionLensRule.material(for: self, reduceTransparency: reduceTransparency)
        var drawn: String
        if material == .today {
            drawn = reduceTransparency && level != .solid
                ? "Reduce Transparency is on, so selection and bar buttons as Solid draws them"
                : "selection and bar buttons as Solid draws them"
        } else {
            drawn = reduceMotion
                ? "glass selection and bar buttons; moves are instant (Reduce Motion is on)"
                : "glass selection and bar buttons; moves glide"
            if increasedContrast { drawn += "; edged for Increase Contrast" }
        }
        return "[glass] \(settings) — \(drawn)"
    }
}

public extension View {
    /// Hands the stored Glass effect, accent and Tint to every selection lens below. Apply once,
    /// at a window's root.
    func selectionLensAppearanceFromDefaults() -> some View {
        modifier(SelectionLensAppearanceFromDefaults())
    }

    /// Makes this container the home of one selection lens.
    ///
    /// **A host must sit inside any scoped animation that moves its stops** (a `.transaction` or
    /// `.animation(_:value:)` that springs the control's own items). The lens is drawn in the host's
    /// background, so an animation scoped to the items alone moves them and leaves the lens to snap
    /// to where they end up.
    ///
    /// - Parameters:
    ///   - channel: the name its stops publish under.
    ///   - selected: the chosen stop's id, or nil when nothing is chosen.
    ///   - style: how the marker looks — built from what the control draws today.
    ///   - visibleRegion: for a container inside a scroll view, the part on screen, in the
    ///     container's own coordinates — see ``SelectionLensVisibleRegion``. A move with either
    ///     end outside it switches instantly.
    func selectionLensHost<ID: Hashable>(_ channel: SelectionLensChannel, selected: ID?,
                                         style: SelectionLensStyle,
                                         visibleRegion: SelectionLensVisibleRegion? = nil) -> some View {
        modifier(SelectionLensHost(channel: channel, selected: selected.map(AnyHashable.init),
                                   style: style, visibleRegion: visibleRegion))
    }

    /// Keeps `region` up to date with this scroll view's visible part without re-rendering: the
    /// region is a reference the host reads only when a move starts. A `@State` rect would
    /// re-render the whole scrolling view on every scroll frame, Solid included, for a value read
    /// once per click.
    func selectionLensTracksVisibleRegion(_ region: SelectionLensVisibleRegion) -> some View {
        onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, visible in
            region.rect = visible
        }
    }

    /// Marks this view as one stop of a selection lens: the lens sits exactly on its bounds.
    /// Publishes nothing at Solid.
    func selectionLensStop<ID: Hashable>(_ channel: SelectionLensChannel, id: ID) -> some View {
        modifier(SelectionLensStop(key: SelectionLensStopKey(channel: channel, id: AnyHashable(id))))
    }
}

/// The part of a scrolling lens host that is on screen, kept out of the view graph on purpose: the
/// scroll view writes it on every frame (`selectionLensTracksVisibleRegion`) and the host reads it
/// only when a move starts. Hold one in `@State` beside the scroll view.
@MainActor
public final class SelectionLensVisibleRegion {
    public var rect: CGRect?
    public init() {}
}

/// A choice's ground, drawn as one shape in every state, whose selected fill becomes the lens: at
/// Solid it is exactly the control's fill, and under a lens the chosen one paints nothing (the lens
/// is its ground) while the others keep theirs.
///
/// One shape, not a branch per state, so a change of selection tweens one capsule's colour;
/// branches would make it a cross-fade between two capsules, which changes Solid.
public struct SelectionLensGround<S: Shape>: View {
    @Environment(\.selectionLensMaterial) private var material
    private let shape: S
    private let isSelected: Bool
    private let selectedStyle: AnyShapeStyle
    private let unselectedStyle: AnyShapeStyle

    public init(_ shape: S, isSelected: Bool, selected: some ShapeStyle, unselected: some ShapeStyle) {
        self.shape = shape
        self.isSelected = isSelected
        self.selectedStyle = AnyShapeStyle(selected)
        self.unselectedStyle = AnyShapeStyle(unselected)
    }

    public var body: some View {
        shape.fill(isSelected ? (material == .today ? selectedStyle : AnyShapeStyle(Color.clear))
                              : unselectedStyle)
    }
}

public extension View {
    /// The button style of one choice in a control that hosts a selection lens: at Solid, `.filled`
    /// for the chosen one. Under a lens the chosen one has no fill of its own, so it takes
    /// `unselected`: `.filled`'s shadow would be cast by the label alone, and its 1pt lift would
    /// move the stop the lens sits on. Apply inside the host, where the lens material is known.
    ///
    /// - Parameter filledTint: the tint `.filled` takes on the chosen one at Solid when it isn't
    ///   `tint`: the on-fill colour, for a control whose ring sits on its own fill. Under a lens the
    ///   chosen one washes in `tint` like its neighbours: a white wash there is no hover at all.
    func selectionLensChoiceButtonStyle(isSelected: Bool, tint: Color, filledTint: Color? = nil,
                                        unselected: HoverAffordanceVariant = .segment,
                                        shape: HoverAffordanceShape? = nil) -> some View {
        modifier(SelectionLensChoiceButtonStyle(isSelected: isSelected, tint: tint, filledTint: filledTint,
                                                unselected: unselected, shape: shape))
    }

    /// The ink of one choice's label in a control that hosts a selection lens. At Solid the chosen
    /// one sits on the control's opaque fill and takes `onFill`, the white or deepened ink that fill
    /// carries. Under a lens in light mode only the lens's pale fill or glass is behind it, where
    /// white all but vanishes, so it takes `onGlass`: `.primary`, black. In dark mode white reads.
    ///
    /// The rest take `unselected` in every appearance. Apply inside the host, where the lens
    /// material is known; the control's own body sits outside it.
    func selectionLensLabelInk(isSelected: Bool, onFill: some ShapeStyle,
                               unselected: some ShapeStyle) -> some View {
        modifier(SelectionLensLabelInk(isSelected: isSelected, onFill: AnyShapeStyle(onFill),
                                       onGlass: AnyShapeStyle(.primary), unselected: AnyShapeStyle(unselected)))
    }

    /// `selectionLensLabelInk(isSelected:onFill:unselected:)` with the light-mode glass ink given —
    /// for a label's quieter half, such as a count beside a name, which is `.secondary` on glass as
    /// it is on the unselected choices.
    func selectionLensLabelInk(isSelected: Bool, onFill: some ShapeStyle, onGlass: some ShapeStyle,
                               unselected: some ShapeStyle) -> some View {
        modifier(SelectionLensLabelInk(isSelected: isSelected, onFill: AnyShapeStyle(onFill),
                                       onGlass: AnyShapeStyle(onGlass), unselected: AnyShapeStyle(unselected)))
    }
}

private struct SelectionLensChoiceButtonStyle: ViewModifier {
    let isSelected: Bool
    let tint: Color
    let filledTint: Color?
    let unselected: HoverAffordanceVariant
    let shape: HoverAffordanceShape?
    @Environment(\.selectionLensMaterial) private var material

    func body(content: Content) -> some View {
        let variant = SelectionLensRule.choiceVariant(isSelected: isSelected, material: material,
                                                      unselected: unselected)
        content.buttonStyle(.hoverAffordance(variant, tint: SelectionLensRule.choiceTint(
            variant: variant, tint: tint, filledTint: filledTint), shape: shape))
    }
}

private struct SelectionLensLabelInk: ViewModifier {
    let isSelected: Bool
    let onFill: AnyShapeStyle
    let onGlass: AnyShapeStyle
    let unselected: AnyShapeStyle
    @Environment(\.selectionLensMaterial) private var material
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let onLightGlass = material != .today && colorScheme == .light
        content.foregroundStyle(isSelected ? (onLightGlass ? onGlass : onFill) : unselected)
    }
}

/// A control's own marker, drawn only when no lens is: at Solid, under Reduce Transparency, and
/// anywhere outside a host. Wrap exactly what the control drew before, and Solid stays identical.
public struct SelectionLensTodayMarker<Content: View>: View {
    @Environment(\.selectionLensMaterial) private var material
    private let content: Content

    public init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if material == .today {
            content
        }
    }
}

// MARK: - Stops and host

struct SelectionLensStopKey: Hashable {
    let channel: SelectionLensChannel
    let id: AnyHashable
}

struct SelectionLensStopsKey: PreferenceKey {
    static var defaultValue: [SelectionLensStopKey: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [SelectionLensStopKey: Anchor<CGRect>],
                       nextValue: () -> [SelectionLensStopKey: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct SelectionLensStop: ViewModifier {
    let key: SelectionLensStopKey
    @Environment(\.selectionLensMaterial) private var material

    func body(content: Content) -> some View {
        // Always applied, so a change of appearance never changes this view's identity; it simply
        // publishes nothing while there is no lens to place.
        content.anchorPreference(key: SelectionLensStopsKey.self, value: .bounds) { anchor in
            material == .today ? [:] : [key: anchor]
        }
    }
}

struct SelectionLensHost: ViewModifier {
    let channel: SelectionLensChannel
    let selected: AnyHashable?
    let style: SelectionLensStyle
    let visibleRegion: SelectionLensVisibleRegion?

    @Environment(\.selectionLensAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let spec = SelectionLensRule.lensSpec(style: style, appearance: appearance,
                                              reduceTransparency: reduceTransparency,
                                              increasedContrast: contrast == .increased)
        // One shape of view tree whatever the material, so switching Glass effect in Settings never
        // resets the state of the control inside.
        content
            .environment(\.selectionLensMaterial, spec.material)
            .backgroundPreferenceValue(SelectionLensStopsKey.self) { stops in
                if spec.material != .today {
                    GeometryReader { proxy in
                        SelectionLensLayer(
                            rects: Self.rects(stops, channel: channel, in: proxy),
                            selected: selected,
                            style: style,
                            spec: spec,
                            reduceMotion: reduceMotion,
                            visibleRegion: visibleRegion)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            // This lens's stops stop here: an outer host never sees them.
            .transformPreference(SelectionLensStopsKey.self) { value in
                value = value.filter { $0.key.channel != channel }
            }
    }

    static func rects(_ stops: [SelectionLensStopKey: Anchor<CGRect>], channel: SelectionLensChannel,
                      in proxy: GeometryProxy) -> [AnyHashable: CGRect] {
        var out: [AnyHashable: CGRect] = [:]
        for (key, anchor) in stops where key.channel == channel {
            out[key.id] = proxy[anchor]
        }
        return out
    }
}

/// What the lens was last drawn as — kept out of the view graph, as `SelectionLensVisibleRegion` is:
/// written on every frame the lens draws, read only when a move starts.
@MainActor
final class SelectionLensLastDrawn {
    /// Where, before any outset, or nil when nothing was drawn.
    var rect: CGRect?
    /// The style's opacity it was drawn at — a dimmed row's lens is dimmed with it.
    var styleOpacity: Double = 1
}

/// The lens itself: where it is, and what it is made of.
struct SelectionLensLayer: View {
    let rects: [AnyHashable: CGRect]
    let selected: AnyHashable?
    let style: SelectionLensStyle
    let spec: SelectionLensRule.LensSpec
    let reduceMotion: Bool
    let visibleRegion: SelectionLensVisibleRegion?

    /// One move in progress: where it started, how fast and how visible it already was, which stop
    /// it is heading for, and when.
    ///
    /// No duration of its own. The kind of move (travel, grow, melt) is re-derived every frame from
    /// whether its two stops exist, and a stop can arrive or leave mid-move (a row inserted with the
    /// change that selects it). A fixed duration would end a melt-turned-travel at 0.25 s and jump
    /// the lens the rest of the way, so every leg runs `travelDuration`, the longest, and
    /// `SelectionLensMotion.frame` settles each kind at its own time within it.
    struct Leg: Equatable {
        var from: CGRect?
        var velocity: SelectionLensMotion.EdgeVelocity
        var opacity: Double
        /// The style opacity the lens was drawn at as the move began. A move between a dimmed row
        /// and a bright one dims or brightens as the lens crosses, not at the click.
        var styleOpacity: Double
        var to: AnyHashable?
        var start: Date
    }

    /// The selection the lens is resting on, or heading for. Lags `selected` by exactly the one
    /// render between a change arriving and `onChange` starting the move, so that render still
    /// shows the lens where it was rather than flashing it at the destination.
    @State private var settled: AnyHashable?
    @State private var leg: Leg?
    @State private var hasAppeared = false
    @State private var lastDrawn = SelectionLensLastDrawn()

    var body: some View {
        // The schedule is named in full rather than as `.animation(…)`: it is a frame clock, not the
        // `.animation(_:value:)` modifier `ReduceMotionCoverageScanTests` audits, and Reduce Motion
        // is honoured upstream of it — `begin(from:to:)` starts no move under the setting.
        TimelineView(AnimationTimelineSchedule(minimumInterval: nil, paused: leg == nil)) { context in
            if let frame = frame(at: context.date) {
                lens
                    .frame(width: max(0, frame.rect.width), height: max(0, frame.rect.height))
                    .position(x: frame.rect.midX, y: frame.rect.midY)
                    .opacity(frame.opacity)
            }
        }
        .onAppear {
            settled = selected
            hasAppeared = true
        }
        .onChange(of: selected) { old, new in
            begin(from: old, to: new)
        }
    }

    /// Where the lens is at `date`, outset for a halo, with the style's opacity folded in.
    func frame(at date: Date) -> SelectionLensMotion.Frame? {
        let raw: SelectionLensMotion.Frame?
        let styleOpacity: Double
        if let leg {
            let target = leg.to.flatMap { rects[$0] }
            raw = SelectionLensMotion.frame(from: leg.from, velocity: leg.velocity, opacity: leg.opacity,
                                            to: target, elapsed: date.timeIntervalSince(leg.start))
            switch (leg.from, target) {
            case (nil, _): styleOpacity = style.opacity
            case (_, nil): styleOpacity = leg.styleOpacity
            case (let from?, let to?):
                let p = raw.map { SelectionLensMotion.progress(from: from, to: to, at: $0.rect) } ?? 1
                styleOpacity = leg.styleOpacity + (style.opacity - leg.styleOpacity) * p
            }
        } else {
            let resting = hasAppeared ? settled : selected
            // In the one render between a change and `begin`, the stop the lens rests on may already
            // be gone or moved — a tab strip's chip rung publishes only the active tab's stop, and a
            // compact rung re-windows its chips — so it stays where it was drawn. Only then: at rest
            // with no stop, a row scrolled out of a lazy list, there is no lens to draw.
            let lagging = hasAppeared && settled != selected
            let rect = (lagging ? lastDrawn.rect : nil) ?? resting.flatMap { rects[$0] }
            raw = rect.map { SelectionLensMotion.Frame(rect: $0, opacity: 1) }
            styleOpacity = lagging ? lastDrawn.styleOpacity : style.opacity
        }
        lastDrawn.rect = raw?.rect
        lastDrawn.styleOpacity = styleOpacity
        guard var frame = raw else { return nil }
        frame.opacity *= styleOpacity
        if style.outset != 0 {
            frame.rect = frame.rect.insetBy(dx: -style.outset, dy: -style.outset)
        }
        return frame
    }

    private func begin(from old: AnyHashable?, to new: AnyHashable?) {
        let now = Date()
        // From wherever the lens is right now, at the speed it is going — mid-move included, so a
        // second click while it travels carries it on from there instead of stopping it dead. At
        // rest, from where it was last drawn rather than where the old stop is now: the same update
        // can move that stop (a re-windowed tab strip) or remove it (the chip rung's one stop), and
        // starting there would jump the lens before it glides.
        let current: SelectionLensMotion.Frame?
        var velocity = SelectionLensMotion.EdgeVelocity.zero
        if let leg {
            let elapsed = now.timeIntervalSince(leg.start)
            let target = leg.to.flatMap { rects[$0] }
            current = SelectionLensMotion.frame(from: leg.from, velocity: leg.velocity, opacity: leg.opacity,
                                                to: target, elapsed: elapsed)
            velocity = SelectionLensMotion.velocity(from: leg.from, velocity: leg.velocity, to: target,
                                                    elapsed: elapsed)
        } else {
            current = (lastDrawn.rect ?? old.flatMap { rects[$0] })
                .map { SelectionLensMotion.Frame(rect: $0, opacity: 1) }
        }
        let from = (current?.opacity ?? 0) > 0 ? current?.rect : nil
        let to = new.flatMap { rects[$0] }
        // The lens's own state changes carry no animation of their own — the motion is this layer's
        // frame clock. A selection made inside `withAnimation` would otherwise lend its curve to an
        // "instant" switch (Reduce Motion aside, which zeroes the caller's animation anyway) and
        // slide the lens where it was meant to land at once.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            settled = new
            guard SelectionLensMotion.travels(from: from, to: to, visibleRect: visibleRegion?.rect,
                                              reduceMotion: reduceMotion) else {
                leg = nil
                return
            }
            leg = Leg(from: from, velocity: from == nil ? .zero : velocity,
                      opacity: current?.opacity ?? 0, styleOpacity: lastDrawn.styleOpacity, to: new, start: now)
        }
        guard leg?.start == now else { return }
        // Ends the move, so the frame clock stops. Not `.task(id:)`: a task on a view mid-update can
        // be cancelled at once, and a cancelled sleep would end the move before its first frame,
        // jumping the lens to its stop. An unstructured task can't be cancelled from under it; a
        // later move simply finds the leg isn't its own.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(SelectionLensMotion.travelDuration))
            if leg?.start == now { leg = nil }
        }
    }

    private var outline: HoverAffordanceOutline { style.shape.outline }

    @ViewBuilder
    private var lens: some View {
        switch SelectionLensRule.lensFill(material: spec.material, tintOpacity: spec.tintOpacity) {
        case .flat(let opacity):
            outline.fill(style.color.opacity(opacity))
                .modifier(decorations)
        case .glass(let variant):
            GlassEffectContainer {
                Color.clear.glassEffect(variant == .clear ? .clear : .regular, in: outline)
            }
            .modifier(decorations)
        case .probe:
            outline.fill(SelectionLensRule.probeColor)
                .modifier(decorations)
        case .none:
            // The host draws no layer at all for `.today`; this is never reached.
            EmptyView()
        }
    }

    /// The rim, ring and rule — drawn OUTSIDE the glass container, so the probe draws them too and a
    /// render test can see them; glass itself draws nothing offscreen (a flat fill does).
    private var decorations: SelectionLensDecorations {
        SelectionLensDecorations(outline: outline, rimColor: style.color, rimWidth: spec.rimWidth,
                                 ring: style.ring, rule: style.rule)
    }
}

/// A lens's strokes: Increase Contrast's rim, a ring the control's marker carries, the tab strip's rule.
private struct SelectionLensDecorations: ViewModifier {
    let outline: HoverAffordanceOutline
    let rimColor: Color
    let rimWidth: CGFloat
    let ring: SelectionLensStyle.Ring?
    let rule: SelectionLensStyle.Rule?

    func body(content: Content) -> some View {
        content
            .overlay {
                if rimWidth > 0 {
                    outline.strokeBorder(rimColor, lineWidth: rimWidth)
                }
            }
            .overlay {
                if let ring {
                    outline.strokeBorder(ring.color, lineWidth: ring.width)
                }
            }
            .overlay(alignment: .bottom) {
                if let rule {
                    Capsule(style: .continuous)
                        .fill(rule.color)
                        .frame(height: rule.height)
                        .padding(.horizontal, rule.inset)
                }
            }
    }
}
