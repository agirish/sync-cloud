import SwiftUI

// MARK: - Chrome glass
//
// **Finder's toolbar look for the app's bar and toolbar buttons, in Frosted and Clear.** Every
// button in a bar — the pane bar's Back/Forward, Sort, Scan, Search, New Folder, Delete, Preview,
// the breadcrumb's source pill, the tab strip's +, the header buttons in Organize, Compare, Edit,
// Settings, Help and the other windows — sits in a glass capsule of its own, the way macOS 26 draws
// Finder's. Back and Forward share one, as Finder's do. Solid draws exactly what it drew before.
// Decided 2026-10-03 (RD46 follow-up): bar and toolbar buttons only — not push buttons, chips, or
// the small icons inside rows and fields.
//
// **Our capsule, glass as its material — not the system's `.buttonStyle(.glass)`.** This app used
// that style for the pane bar in July and dropped it after four attempts (`6bb7bdff`): it sizes
// each pill from its own label, so six glyphs gave six heights; it ignores an outer colour and an
// outer frame; and it renders nothing offscreen, so no test could measure it. Here the button keeps
// its own size, its own hover and its own disabled look, and only the ground under it changes. (The
// one exception, `chromeGlassBorderedButtonStyle`, is for buttons that were system-drawn already.)
//
// The pieces, so a button's Solid look never has to be re-described:
// - `chromeGlassGround(_:tint:markerOpacity:outset:when:)` — the glass, behind the button.
// - `ChromeGlassTodayGround` — wraps whatever the button drew at rest before, and draws it only
//   when no glass is drawn. Solid is pixel-identical by construction.
// - `ChromeGlassOnly` — the complement: what a button paints ON its glass (a hover wash).
// - `chromeGlassGroup(_:outset:)` — one capsule around several buttons; its members draw none.
// - `chromeGlassGlyphButton(tint:shape:outset:enabled:)` — a bare-glyph bar button, whose hover
//   wash takes the glass's shape so it never pokes past it.
// - `chromeGlassTrack()` — the track a segmented control sits in.
// - `chromeGlassBorderedButtonStyle()` — a small `.bordered` header button, made system glass.
//
// **Always on the BUTTON, after its style — never inside the label.** Two measured reasons. The
// lifting hover styles (`.filled`, `.circular`, `.actionBar`) flatten their label into a
// compositing group to cast a shadow, and Liquid Glass renders nothing through one; and every hover
// style paints its wash as the label's background, so glass inside the label would sit ON the wash
// and blur it away. Outside, the glass is the ground and the wash is painted on it.
//
// The material follows the selection lens's rule (`SelectionLensRule.material`): Solid and Reduce
// Transparency draw today's ground, and the probe test seam draws a flat shape in the glass's
// place — cyan, where the lens's is magenta — because glass renders nothing offscreen. Clear gets
// a hairline rim, as the lens does, because clear glass over a busy desktop has no edge of its own;
// Increase Contrast strengthens it. The glass is never hit-testable and never read by VoiceOver: it
// is a ground, and a capsule grown past its button by an outset must not take the button's clicks.

/// Whether the buttons below wear chrome glass. Set by `chromeGlassGround` and `chromeGlassGroup`;
/// read by `ChromeGlassTodayGround` and `ChromeGlassOnly`.
private struct ChromeGlassDrawnKey: EnvironmentKey {
    static let defaultValue = false
}

/// Set by a group, so its members draw no capsule of their own.
private struct ChromeGlassGroupedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var chromeGlassDrawn: Bool {
        get { self[ChromeGlassDrawnKey.self] }
        set { self[ChromeGlassDrawnKey.self] = newValue }
    }

    var chromeGlassGrouped: Bool {
        get { self[ChromeGlassGroupedKey.self] }
        set { self[ChromeGlassGroupedKey.self] = newValue }
    }
}

public enum ChromeGlass {
    /// Chrome glass's own probe colour: cyan, not the lens's magenta, so a render test can tell a
    /// bar button's glass from the selection lens sitting on it.
    public static let probeColor = Color(red: 0, green: 1, blue: 1)

    /// What a bar button's ground is drawn in — the selection lens's own rule, so a bar's buttons and
    /// its selected control can never disagree about whether the window is glass.
    public static func material(appearance: SelectionLensAppearance,
                                reduceTransparency: Bool) -> SelectionLensMaterial {
        SelectionLensRule.material(for: appearance, reduceTransparency: reduceTransparency)
    }

    /// How much of a button's own colour the glass carries: the selection lens's tint rule, the
    /// colour's opacity today times the Tint slider's strength (a quarter at Tint 0, all of it at
    /// Tint 100, none when the accent is None). At Tint 100 the glass carries exactly today's colour.
    public static func tintOpacity(markerOpacity: Double = 1, hue: LiquidGlassHue, tint: Double) -> Double {
        SelectionLensRule.tintOpacity(markerOpacity: markerOpacity, hue: hue, tint: tint)
    }

    /// How far a small bar's glass grows past an 18pt glyph button — Edit's header and rail: to
    /// 22pt, level with the 23pt mode track beside them, leaving 4pt between capsules at those rows'
    /// 6pt spacing (3pt, the first value, crowded them to 3).
    public static let smallGlyphOutset: CGFloat = 2

    /// Clear's hairline, and Increase Contrast's stronger one. Neutral ink, because a bar button has
    /// no colour of its own — unlike the lens's rim, which is drawn in its marker's colour.
    public static func rim(material: SelectionLensMaterial,
                           increasedContrast: Bool) -> (width: CGFloat, opacity: Double) {
        guard material == .clear else { return (0, 0) }
        return increasedContrast ? (1.5, 0.45) : (0.75, 0.22)
    }
}

private struct ChromeGlassGround: ViewModifier {
    let shape: HoverAffordanceShape
    let tint: Color?
    let markerOpacity: Double
    let outset: CGFloat
    let enabled: Bool
    @Environment(\.selectionLensAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chromeGlassGrouped) private var grouped

    func body(content: Content) -> some View {
        let material = enabled
            ? ChromeGlass.material(appearance: appearance, reduceTransparency: reduceTransparency)
            : .today
        content
            .environment(\.chromeGlassDrawn, material != .today)
            .background {
                if !grouped {
                    ChromeGlassShape(material: material, shape: shape, tint: tint,
                                     markerOpacity: markerOpacity, appearance: appearance,
                                     increasedContrast: contrast == .increased)
                        .padding(-outset)
                }
            }
    }
}

private struct ChromeGlassGroupGround: ViewModifier {
    let shape: HoverAffordanceShape
    let outset: CGFloat
    @Environment(\.selectionLensAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let material = ChromeGlass.material(appearance: appearance, reduceTransparency: reduceTransparency)
        content
            // Both flags: members draw no capsule of their own, and a member's today-ground steps
            // aside for the group's glass even if it never declared a ground of its own.
            .environment(\.chromeGlassGrouped, material != .today)
            .environment(\.chromeGlassDrawn, material != .today)
            .background {
                ChromeGlassShape(material: material, shape: shape, tint: nil, markerOpacity: 1,
                                 appearance: appearance, increasedContrast: contrast == .increased)
                    .padding(-outset)
            }
    }
}

/// The glass itself, or nothing at Solid.
private struct ChromeGlassShape: View {
    let material: SelectionLensMaterial
    let shape: HoverAffordanceShape
    let tint: Color?
    let markerOpacity: Double
    let appearance: SelectionLensAppearance
    let increasedContrast: Bool

    var body: some View {
        Group {
            switch material {
            case .today:
                EmptyView()
            case .probe:
                shape.outline.fill(ChromeGlass.probeColor)
            case .frosted, .clear:
                Color.clear.glassEffect(glass, in: shape.outline)
            }
        }
        .overlay {
            let rim = ChromeGlass.rim(material: material, increasedContrast: increasedContrast)
            if rim.width > 0 {
                shape.outline.strokeBorder(Color.primary.opacity(rim.opacity), lineWidth: rim.width)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var glass: Glass {
        let base: Glass = material == .clear ? .clear : .regular
        let opacity = ChromeGlass.tintOpacity(markerOpacity: markerOpacity, hue: appearance.hue,
                                              tint: appearance.tint)
        guard let tint, opacity > 0 else { return base }
        return base.tint(tint.opacity(opacity))
    }
}

/// A bar button's ground as it was before chrome glass: drawn at Solid, under Reduce Transparency
/// and anywhere no `chromeGlassGround` is above it; stepped aside wherever glass is drawn instead.
/// Wrap exactly what the button drew at rest, and Solid stays identical.
public struct ChromeGlassTodayGround<Content: View>: View {
    @Environment(\.chromeGlassDrawn) private var glassDrawn
    private let content: Content

    public init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if !glassDrawn { content }
    }
}

/// The complement of ``ChromeGlassTodayGround``: drawn only where chrome glass is — for what a
/// button paints ON its glass, such as the hover and press wash its own ground used to carry.
public struct ChromeGlassOnly<Content: View>: View {
    @Environment(\.chromeGlassDrawn) private var glassDrawn
    private let content: Content

    public init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if glassDrawn { content }
    }
}

public extension View {
    /// A glass ground in `shape` behind this bar button, in Frosted and Clear; nothing at Solid.
    /// Inside a `chromeGlassGroup` the group's capsule stands in for this one.
    ///
    /// - Parameters:
    ///   - tint: a colour the glass carries, on the Tint slider's curve.
    ///   - markerOpacity: how strongly the button paints `tint` today — 1 for a fill.
    ///   - outset: grows the capsule past the button without moving anything — for a bare glyph
    ///     whose own frame is smaller than a bar button reads at. Negative shrinks it.
    ///   - when: false draws nothing, in every appearance — for a control that is a bar button only
    ///     in some of its states.
    func chromeGlassGround(_ shape: HoverAffordanceShape, tint: Color? = nil, markerOpacity: Double = 1,
                           outset: CGFloat = 0, when enabled: Bool = true) -> some View {
        modifier(ChromeGlassGround(shape: shape, tint: tint, markerOpacity: markerOpacity,
                                   outset: outset, enabled: enabled))
    }

    /// One glass ground around several bar buttons — Back and Forward, as Finder pairs them. Members
    /// draw none of their own; a member's `ChromeGlassTodayGround` steps aside for it.
    func chromeGlassGroup(_ shape: HoverAffordanceShape = .capsule, outset: CGFloat = 0) -> some View {
        modifier(ChromeGlassGroupGround(shape: shape, outset: outset))
    }

    /// A bare-glyph bar button — a close ×, a magnifier, a ＋: `.hoverAffordance(.glyph, tint:)`
    /// exactly as before at Solid; in Frosted and Clear a glass `shape` behind it, and the hover wash
    /// takes the same shape. Left at `.glyph`'s rounded square, the wash's corners poked up to 2pt
    /// past a round glass on hover. `enabled: false` keeps today's button in every appearance.
    func chromeGlassGlyphButton(tint: Color = .accentColor, shape: HoverAffordanceShape = .circle,
                                outset: CGFloat = 0, enabled: Bool = true) -> some View {
        modifier(ChromeGlassGlyphButton(tint: tint, shape: shape, outset: outset, enabled: enabled))
    }

    /// A header's small `.bordered` icon button — the Activity Log's Copy, Clear and Open, Sync
    /// History's Export and Clear: `.bordered` at Solid, exactly as before, and the system's own
    /// glass button in Frosted and Clear, which is what Finder's toolbar buttons are.
    ///
    /// The system style is right HERE, where it was wrong for the pane bar: these buttons were
    /// already system-drawn and sized from their labels — measured, `.bordered` and `.glass` give
    /// both of them the same size — so nothing about their size or ink is taken from the app.
    /// Not to be confused with the older `chromeButtonStyle(_:)`, which gives the app's push buttons
    /// system glass at Clear only. Under the probe test seam the button keeps `.bordered` over a
    /// cyan capsule, so a render test can tell the two branches apart.
    func chromeGlassBorderedButtonStyle() -> some View {
        modifier(ChromeGlassBorderedButtonStyle())
    }

    /// The track a segmented control sits in — the View switch, Edit's mode bar and rail tabs,
    /// Storage's sections: today's quaternary capsule, and a glass one in Frosted and Clear. One
    /// definition, because the same recipe had been spelled out at each of them.
    func chromeGlassTrack() -> some View {
        background { ChromeGlassTodayGround { Capsule().fill(.quaternary.opacity(0.5)) } }
            .chromeGlassGround(.capsule)
    }
}

private struct ChromeGlassGlyphButton: ViewModifier {
    let tint: Color
    let shape: HoverAffordanceShape
    let outset: CGFloat
    let enabled: Bool
    @Environment(\.selectionLensAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let glass = enabled
            && ChromeGlass.material(appearance: appearance, reduceTransparency: reduceTransparency) != .today
        content
            .buttonStyle(.hoverAffordance(.glyph, tint: tint, shape: glass ? shape : nil))
            .chromeGlassGround(shape, outset: outset, when: enabled)
    }
}

private struct ChromeGlassBorderedButtonStyle: ViewModifier {
    @Environment(\.selectionLensAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch ChromeGlass.material(appearance: appearance, reduceTransparency: reduceTransparency) {
        case .today:
            content.buttonStyle(.bordered)
        case .probe:
            content.buttonStyle(.bordered)
                .background(Capsule().fill(ChromeGlass.probeColor))
        case .frosted, .clear:
            content.buttonStyle(.glass)
        }
    }
}
