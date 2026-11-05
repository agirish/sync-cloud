import SwiftUI

// MARK: - Chrome glass
//
// Finder's toolbar look for the app's bar and toolbar buttons, in Frosted and Clear: each sits in a
// glass capsule of its own, as macOS 26 draws Finder's, and Back and Forward share one. Solid is
// unchanged. Bar and toolbar buttons only: not push buttons, chips, or icons inside rows and
// fields.
//
// Our capsule with glass as its material, not the system's `.buttonStyle(.glass)`, which sizes each
// pill from its own label, ignores an outer colour and frame, and renders nothing offscreen. Here
// the button keeps its own size, hover and disabled look; only the ground changes. The one
// exception, `chromeGlassBorderedButtonStyle`, is for buttons that were system-drawn already.
//
// The pieces:
// - `chromeGlassGround(_:outset:rim:when:)` — the glass, behind the button.
// - `ChromeGlassTodayGround` — wraps what the button draws at rest at Solid, and draws it only when
//   no glass is drawn, so Solid is pixel-identical by construction.
// - `ChromeGlassOnly` — the complement: what a button paints ON its glass (a hover wash).
// - `chromeGlassGroup(_:outset:)` — one capsule around several buttons; its members draw none.
// - `chromeGlassGlyphButton(tint:shape:outset:enabled:)` — a bare-glyph bar button, whose hover
//   wash takes the glass's shape so it never pokes past it.
// - `chromeGlassTrack()` — the track a segmented control sits in.
// - `chromeGlassBorderedButtonStyle()` — a small `.bordered` header button, made system glass.
//
// **Always on the button, after its style, never inside the label.** The lifting hover styles
// (`.filled`, `.circular`, `.actionBar`) flatten their label into a compositing group, which Liquid
// Glass renders nothing through; and every hover style paints its wash as the label's background,
// so glass inside the label would blur the wash away.
//
// The material follows `SelectionLensRule.material`: Solid and Reduce Transparency draw the Solid
// ground, and the probe test seam draws a flat cyan shape (the lens's is magenta), since glass
// renders nothing offscreen. Clear adds a hairline rim, stronger under Increase Contrast; a button
// with its own edge passes `rim: false` to avoid a double border. The glass is never hit-testable
// or read by VoiceOver, so an outset capsule can't take the button's clicks.
//
// Never tinted: a bar button has no colour of its own. The selection lens carries colour.

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

    /// What a bar button's ground is drawn in: the selection lens's rule, so a bar's buttons and
    /// its selected control can't disagree about whether the window is glass.
    public static func material(appearance: SelectionLensAppearance,
                                reduceTransparency: Bool) -> SelectionLensMaterial {
        SelectionLensRule.material(for: appearance, reduceTransparency: reduceTransparency)
    }

    /// How far a small bar's glass grows past an 18pt glyph button (Edit's header and rail): to
    /// 22pt, level with the 23pt mode track beside it, leaving 4pt between capsules at 6pt spacing.
    public static let smallGlyphOutset: CGFloat = 2

    /// The least room between two glass capsules side by side on a bar — what ``smallGlyphOutset``
    /// leaves at a 6pt row spacing beside a capsule with no outset.
    public static let minimumCapsuleGap: CGFloat = 4

    /// The extra room an outset capsule needs beside another outset one on a row of `rowSpacing`
    /// to keep ``minimumCapsuleGap``, since both outsets eat into the spacing.
    /// `View.chromeGlassClearance(_:rowSpacing:)` pads by this.
    public static func clearance(rowSpacing: CGFloat, outset: CGFloat = smallGlyphOutset) -> CGFloat {
        max(0, minimumCapsuleGap - (rowSpacing - 2 * outset))
    }

    /// Clear's hairline, and Increase Contrast's stronger one. Neutral ink, since a bar button has
    /// no colour (the lens's rim takes its marker's). None for a button with an edge of its own.
    public static func rim(material: SelectionLensMaterial, increasedContrast: Bool,
                           ownEdge: Bool = false) -> (width: CGFloat, opacity: Double) {
        guard material == .clear, !ownEdge else { return (0, 0) }
        return increasedContrast ? (1.5, 0.45) : (0.75, 0.22)
    }
}

/// How far a glass ground grows past its button, per axis.
struct ChromeGlassOutset: Equatable {
    var horizontal: CGFloat
    var vertical: CGFloat
}

private struct ChromeGlassGround: ViewModifier {
    let shape: HoverAffordanceShape
    let outset: ChromeGlassOutset
    let rim: Bool
    let enabled: Bool
    @Environment(\.selectionLensAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.chromeGlassGrouped) private var grouped
    @Environment(\.chromeGlassDrawn) private var outerDrawn

    func body(content: Content) -> some View {
        let material = enabled
            ? ChromeGlass.material(appearance: appearance, reduceTransparency: reduceTransparency)
            : .today
        content
            // Inside a group, the group's capsule is this button's ground whatever this call says,
            // so its flag stands; otherwise a member with glass off would draw its Solid ground on
            // top of the group's glass.
            .environment(\.chromeGlassDrawn, grouped ? outerDrawn : material != .today)
            .background {
                if !grouped {
                    ChromeGlassShape(material: material, shape: shape, ownEdge: !rim,
                                     increasedContrast: contrast == .increased)
                        .padding(.horizontal, -outset.horizontal)
                        .padding(.vertical, -outset.vertical)
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
    @Environment(\.chromeGlassGrouped) private var grouped

    func body(content: Content) -> some View {
        let material = ChromeGlass.material(appearance: appearance, reduceTransparency: reduceTransparency)
        content
            // Both flags: members draw no capsule, and a member's Solid ground steps aside for the
            // group's glass. A group inside a group is a member: the outer capsule and flags stand.
            .environment(\.chromeGlassGrouped, grouped || material != .today)
            .environment(\.chromeGlassDrawn, grouped || material != .today)
            .background {
                if !grouped {
                    ChromeGlassShape(material: material, shape: shape, ownEdge: false,
                                     increasedContrast: contrast == .increased)
                        .padding(-outset)
                }
            }
    }
}

/// The glass itself, or nothing at Solid.
private struct ChromeGlassShape: View {
    let material: SelectionLensMaterial
    let shape: HoverAffordanceShape
    let ownEdge: Bool
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
            let rim = ChromeGlass.rim(material: material, increasedContrast: increasedContrast, ownEdge: ownEdge)
            if rim.width > 0 {
                shape.outline.strokeBorder(Color.primary.opacity(rim.opacity), lineWidth: rim.width)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var glass: Glass { material == .clear ? .clear : .regular }
}

/// A bar button's Solid ground: drawn at Solid, under Reduce Transparency and anywhere no
/// `chromeGlassGround` is above it; stepped aside wherever glass is drawn. Wrap exactly what the
/// button draws at rest, and Solid stays identical.
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

/// The complement of ``ChromeGlassTodayGround``: drawn only where chrome glass is, for what a
/// button paints on its glass, such as its hover and press wash.
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
    ///   - outset: grows the capsule past the button without moving anything, for a bare glyph
    ///     smaller than a bar button. Negative shrinks it.
    ///   - rim: false for a button that draws an edge of its own, so Clear adds no second one.
    ///   - when: false draws nothing in any appearance, for a control that is a bar button only in
    ///     some states.
    func chromeGlassGround(_ shape: HoverAffordanceShape, outset: CGFloat = 0, rim: Bool = true,
                           when enabled: Bool = true) -> some View {
        modifier(ChromeGlassGround(shape: shape, outset: ChromeGlassOutset(horizontal: outset, vertical: outset),
                                   rim: rim, enabled: enabled))
    }

    /// `chromeGlassGround(_:outset:rim:when:)` grown differently per axis, for a button short of
    /// its row's height whose width already fits, such as an AppKit-sized menu 4pt from a
    /// neighbour.
    func chromeGlassGround(_ shape: HoverAffordanceShape, horizontalOutset: CGFloat, verticalOutset: CGFloat,
                           rim: Bool = true, when enabled: Bool = true) -> some View {
        modifier(ChromeGlassGround(shape: shape,
                                   outset: ChromeGlassOutset(horizontal: horizontalOutset, vertical: verticalOutset),
                                   rim: rim, enabled: enabled))
    }

    /// One glass ground around several bar buttons, like Finder's Back and Forward. Members draw
    /// none of their own; a member's `ChromeGlassTodayGround` steps aside for it.
    func chromeGlassGroup(_ shape: HoverAffordanceShape = .capsule, outset: CGFloat = 0) -> some View {
        modifier(ChromeGlassGroupGround(shape: shape, outset: outset))
    }

    /// A bare-glyph bar button (a close ×, a magnifier, a ＋): `.hoverAffordance(.glyph, tint:)` at
    /// Solid; in Frosted and Clear a glass `shape` behind it, with the hover wash in the same shape
    /// so its corners don't poke past round glass. `enabled: false` keeps the Solid button always.
    func chromeGlassGlyphButton(tint: Color? = nil, shape: HoverAffordanceShape = .circle,
                                outset: CGFloat = 0, enabled: Bool = true) -> some View {
        modifier(ChromeGlassGlyphButton(tint: tint, shape: shape, outset: outset, enabled: enabled))
    }

    /// A header's small `.bordered` icon button (the Activity Log's Copy, Clear and Open, Sync
    /// History's Export and Clear): `.bordered` at Solid, the system glass button in Frosted and
    /// Clear, as Finder's toolbar buttons are.
    ///
    /// The system style fits here, unlike the pane bar: these buttons are system-drawn and sized
    /// from their labels already, and `.bordered` and `.glass` give them the same size. Not
    /// `chromeButtonStyle(_:)`, which gives push buttons system glass at Clear only. Clear uses the
    /// system's clear glass on macOS 26.1 (regular on 26.0, which lacks it). Under the probe seam
    /// it keeps `.bordered` over a cyan capsule, so a render test can tell the branches apart.
    func chromeGlassBorderedButtonStyle() -> some View {
        modifier(ChromeGlassBorderedButtonStyle())
    }

    /// Room on `edges` for a glass capsule beside another outset one on a row of `rowSpacing`
    /// (``ChromeGlass/clearance(rowSpacing:outset:)``), keeping ``ChromeGlass/minimumCapsuleGap``.
    /// Only where glass is drawn: Solid has no capsules to keep apart.
    func chromeGlassClearance(_ edges: Edge.Set, rowSpacing: CGFloat) -> some View {
        modifier(ChromeGlassClearance(edges: edges, rowSpacing: rowSpacing))
    }

    /// The track a segmented control sits in (the View switch, Edit's mode bar and rail tabs,
    /// Storage's sections): a quaternary capsule at Solid, glass in Frosted and Clear.
    func chromeGlassTrack() -> some View {
        background { ChromeGlassTodayGround { Capsule().fill(.quaternary.opacity(0.5)) } }
            .chromeGlassGround(.capsule)
    }
}

private struct ChromeGlassClearance: ViewModifier {
    let edges: Edge.Set
    let rowSpacing: CGFloat
    @Environment(\.selectionLensAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let glass = ChromeGlass.material(appearance: appearance, reduceTransparency: reduceTransparency) != .today
        content.padding(edges, glass ? ChromeGlass.clearance(rowSpacing: rowSpacing) : 0)
    }
}

private struct ChromeGlassGlyphButton: ViewModifier {
    let tint: Color?
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
                .background(Capsule().fill(ChromeGlass.probeColor).allowsHitTesting(false))
        case .frosted:
            content.buttonStyle(.glass)
        case .clear:
            if #available(macOS 26.1, *) {
                content.buttonStyle(.glass(.clear))
            } else {
                content.buttonStyle(.glass)
            }
        }
    }
}
