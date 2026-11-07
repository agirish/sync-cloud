import SwiftUI
import AppKit

// MARK: - Liquid Glass Design (macOS 26–inspired)
// Native Liquid Glass (`.glassEffect`) for the glass levels, with materials, rounded corners and
// soft shadows around it.

/// Popular hue options for the liquid glass background gradient.
public enum LiquidGlassHue: String, CaseIterable, Identifiable, Sendable {
    /// No accent: no hue wash anywhere, and controls follow the system accent colour. In light the
    /// background whitens toward paper (`LiquidGlass.noneLightVeil`), so "no accent" reads as clean
    /// white rather than a material gray close to Graphite's faint wash at low Tint. Dark keeps the
    /// stock deep neutral ground.
    case none
    case blue
    case cyan
    case teal
    case green
    case amber
    case coral
    case rose
    case purple
    case indigo
    /// A true neutral gray, the monochrome accent. Unlike `.none` (white ground in light, controls
    /// follow the system accent), Graphite washes the surfaces in a colourless gray, through the
    /// same machinery as every hue.
    case graphite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .teal: return "Teal"
        case .green: return "Green"
        case .amber: return "Amber"
        case .coral: return "Coral"
        case .rose: return "Rose"
        case .purple: return "Purple"
        case .indigo: return "Indigo"
        case .graphite: return "Graphite"
        }
    }

    /// Accent color used for the hue selector swatch.
    public var accentColor: Color {
        switch self {
        // The system accent, so controls keep the user's macOS accent colour. Read from AppKit, not
        // as SwiftUI's `Color.accentColor`, which resolves to the environment's accent: under a
        // window root's `nativeControlAccent` that is the window's hue, and the None swatch would
        // draw it.
        case .none: return Color(nsColor: .controlAccentColor)
        case .blue: return Color(red: 0.2, green: 0.5, blue: 1.0)
        case .cyan: return Color(red: 0.25, green: 0.75, blue: 1.0)
        case .teal: return Color(red: 0.2, green: 0.65, blue: 0.65)
        case .green: return Color(red: 0.2, green: 0.7, blue: 0.5)
        case .amber: return Color(red: 0.95, green: 0.6, blue: 0.2)
        case .coral: return Color(red: 1.0, green: 0.45, blue: 0.4)
        case .rose: return Color(red: 0.95, green: 0.4, blue: 0.55)
        case .purple: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .indigo: return Color(red: 0.4, green: 0.35, blue: 0.9)
        case .graphite: return Color(red: 0.53, green: 0.54, blue: 0.56)
        }
    }

    /// Three gradient stop colors (topLeading → bottomTrailing) for the app background.
    public var gradientColors: [Color] {
        switch self {
        case .none:
            // No color wash at all — the background is just the neutral material.
            return [.clear, .clear, .clear]
        case .blue:
            return [
                Color(red: 0.25, green: 0.75, blue: 1.0),
                Color(red: 0.15, green: 0.45, blue: 1.0),
                Color(red: 0.05, green: 0.25, blue: 0.85)
            ]
        case .cyan:
            return [
                Color(red: 0.35, green: 0.85, blue: 1.0),
                Color(red: 0.2, green: 0.7, blue: 0.95),
                Color(red: 0.1, green: 0.5, blue: 0.85)
            ]
        case .teal:
            return [
                Color(red: 0.25, green: 0.8, blue: 0.8),
                Color(red: 0.15, green: 0.6, blue: 0.65),
                Color(red: 0.08, green: 0.4, blue: 0.5)
            ]
        case .green:
            return [
                Color(red: 0.3, green: 0.85, blue: 0.6),
                Color(red: 0.2, green: 0.65, blue: 0.5),
                Color(red: 0.1, green: 0.45, blue: 0.4)
            ]
        case .amber:
            return [
                Color(red: 1.0, green: 0.75, blue: 0.35),
                Color(red: 0.95, green: 0.6, blue: 0.2),
                Color(red: 0.8, green: 0.45, blue: 0.1)
            ]
        case .coral:
            return [
                Color(red: 1.0, green: 0.55, blue: 0.5),
                Color(red: 0.95, green: 0.4, blue: 0.4),
                Color(red: 0.8, green: 0.25, blue: 0.35)
            ]
        case .rose:
            return [
                Color(red: 1.0, green: 0.5, blue: 0.65),
                Color(red: 0.9, green: 0.35, blue: 0.55),
                Color(red: 0.7, green: 0.2, blue: 0.5)
            ]
        case .purple:
            return [
                Color(red: 0.6, green: 0.45, blue: 1.0),
                Color(red: 0.45, green: 0.35, blue: 0.9),
                Color(red: 0.3, green: 0.2, blue: 0.75)
            ]
        case .indigo:
            return [
                Color(red: 0.45, green: 0.4, blue: 0.95),
                Color(red: 0.35, green: 0.3, blue: 0.85),
                Color(red: 0.2, green: 0.2, blue: 0.7)
            ]
        case .graphite:
            // A neutral gray triad — no hue, so the wash reads as a true colorless monochrome.
            return [
                Color(red: 0.6, green: 0.61, blue: 0.63),
                Color(red: 0.45, green: 0.46, blue: 0.48),
                Color(red: 0.29, green: 0.3, blue: 0.32)
            ]
        }
    }

    /// What a solid accent surface actually fills with: `accentColor` deepened until a white label
    /// on it clears WCAG AA (see `AccentFill`). Half the hues are already dark enough and come back
    /// untouched; the light ones (Amber, Cyan, Green, Coral, Rose, Teal) get materially deeper.
    ///
    /// Buttons, selected chips and filled pills take this, not `accentColor`. `accentColor` stays
    /// right for a tint wash, a hairline or accent-coloured text, which carry no white label and
    /// would go muddy if deepened.
    public var accentFillColor: Color { AccentFill.deepened(accentColor) }

    /// Text and glyph colour for content drawn on this hue's `accentFillColor`: the one place that
    /// pairing is decided, so a chip, pill or button can't drift to a local literal.
    ///
    /// Always white. White on the raw accent is illegible on the light hues (2.68:1 on Green,
    /// 2.20:1 on Amber), and flipping the label to near-black there would split the filled controls
    /// into two button families. So the label stays white and the fill deepens instead
    /// (`accentFillColor`), at 4.5:1 or better on every hue; `AccentLabelColorTests` measures that over
    /// every hue, so it holds when a hue is added. Not `@MainActor`: it doesn't resolve the system
    /// accent.
    public var onAccentLabelColor: Color { .white }
}

/// How much the glass surfaces obscure what is behind them: the material half of the Appearance
/// model. Orthogonal to `SurfaceStyle`, which controls shape; any level combines with any shape.
///
/// Every case but `.solid` is Liquid Glass. `.frosted` is `.regular`, the standard system material
/// (Control Center, the menu bar, Finder's sidebar): translucent and blurred, with content on top
/// legible. `.clear` is glass with no frost, for surfaces over the window's gradient rather than
/// over content. Three discrete cases, because the API has no continuum between them. Stored via
/// `LiquidGlass.levelKey`.
public enum GlassLevel: String, CaseIterable, Identifiable, Sendable {
    /// Glass with no frost: the background reads straight through.
    case clear
    /// Standard Liquid Glass — translucent and blurred, legible on top.
    case frosted
    /// Opaque panels. The only case with no translucency at all.
    case solid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .frosted: return "Frosted"
        case .solid: return "Solid"
        }
    }

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .clear:
            return "Glass with no frost — the window’s background reads through every surface."
        case .frosted:
            return "Standard Liquid Glass: translucent and blurred, with content on top staying legible."
        case .solid:
            return "Opaque panels for maximum readability, with no translucency."
        }
    }

    /// The level overlay cards render at: surfaces over dense app content rather than the window's
    /// own background (Settings, Help, first run, the operation banner). Clear glass over text is
    /// two layers of text competing, so `.clear` resolves to `.frosted` and the others pass
    /// through. Only `glassCardStyle` uses it: bars take the level verbatim and frost their
    /// controls instead (see `needsChromeFrosting`). Apple draws the same line: Control Center is
    /// glass, alerts are not.
    public var flooredForChrome: GlassLevel {
        self == .clear ? .frosted : self
    }

    /// Whether chrome on a card that takes the level verbatim (buttons, pills) needs a material of
    /// its own. A button's fill is a thin tint wash, so on see-through glass it has nothing to read
    /// against and stops looking like a control. `chromeButtonStyle` and the chrome escalation key
    /// off this, and the tests pin it, so a new level decides its chrome treatment here rather than
    /// in scattered `== .clear` checks.
    public var needsChromeFrosting: Bool {
        self == .clear
    }

    /// Backdrop dimming behind an overlay. At Clear it lightens to the destination picker's 0.20:
    /// every scrimmed card is a `groundedGlassCard` at the level's face value, whose own ground
    /// keeps its text legible, so the scrim only has to focus it, and a heavy scrim would grey the
    /// window and make Clear look like it did nothing.
    ///
    /// Light at Clear takes none: black over a near-white window reads as grey, not depth, even at
    /// 0.05. The card's shadow and edge set it off instead. Dark keeps 0.20, which reads as depth
    /// over the deep base. `OverlayScrim` draws it, reading the scheme itself.
    public func overlayScrimOpacity(dark: Bool) -> Double {
        guard self == .clear else { return 0.35 }
        return dark ? 0.20 : 0
    }

    /// How opaque `groundedGlassCard`'s ground is under the card's content: 0.85 for Frosted and
    /// Solid, since below about 0.6 the content behind stays legible through the card.
    ///
    /// Clear takes 0.90, a shade more, because nothing else under the card blurs: the card is clear
    /// glass in both schemes (`floatingPanelGlass`), so the ground alone decides how much of the
    /// window reads through. 0.90 leaves the rows behind a faint trace in each scheme.
    public var groundedBackingOpacity: Double {
        self == .clear ? 0.90 : 0.85
    }

    /// Strength of the app background gradient, 0...1. `.frosted` is 0.65, the default look.
    /// `.clear` drops the wash (nothing frosts it, so it would read as flat colour; see
    /// `clearAccentStrength`), and `.solid` maxes it, since only the window edges show it.
    public var backgroundIntensity: Double {
        switch self {
        case .clear: return 0.0
        case .frosted: return 0.65
        case .solid: return 1.0
        }
    }

    /// Whether this level must draw its own hairline edge and drop shadow. Native Liquid Glass
    /// draws both itself; an opaque panel has neither, nor does the pre-macOS 26 material fallback.
    public var needsExplicitChrome: Bool {
        if self == .solid { return true }
        if #available(macOS 26.0, *) { return false }
        return true
    }
}

// MARK: - Clear glass tuning
//
// What obscures the window at `.clear` is almost entirely the behind-window
// `NSVisualEffectView`, not the washes over it. Measured on an empty pane in light, the luminance
// spread that survives from behind the window was 2.3 with the layer at full strength, 3.5 with
// the washes halved or a thinner material, and 52.0 with no layer. Swapping materials or
// lightening the wash changes the tint; only the layer's own opacity changes how see-through the
// app is.
//
// So Clear fades that layer slightly rather than removing it. 95% keeps the frost unmistakable,
// with what's behind the window reading as depth, not legible content, while parting company
// with Frosted. Below about 90%, text in the window behind becomes readable through the app.

public extension LiquidGlass {
    /// How much of the behind-window vibrancy layer Clear composites, 0...1. The knob that decides
    /// how see-through the app is; see the note above for why it is this and not the material.
    static let clearVibrancyAlpha: Double = 0.95

    /// Clear's whitening wash in light. It can't go to zero: without it the see-through panes read
    /// as flat system gray, since the vibrancy layer is all that's behind them.
    static let clearLightVeil: Double = 0.225

    /// The same job from the other end in dark — how opaque the deep near-black base is.
    static let clearDarkVeil: Double = 0.53

    /// The accent wash Clear paints over that veil, so the background carries the chosen hue rather
    /// than reading gray-white. It is strongest where nothing covers it: the gutters between cards
    /// and the toolbar band.
    static let clearAccentVeil: Double = 0.12

    /// Extra accent painted into the top strip at Clear, fading out over `clearTitlebarBoostHeight`.
    ///
    /// The titlebar and toolbar band is a translucent AppKit material above the app background, and
    /// no window or toolbar API turns it off (`titlebarAppearsTransparent`, `.hiddenTitleBar` and
    /// `.toolbarBackground(.hidden)` are no-ops here). It passes about three quarters of the colour
    /// beneath it, so without this the band reads a third weaker than the gutters below it; with
    /// it, the band lands within a couple of points of the content.
    ///
    /// It fades rather than stopping at the band's edge, so no seam appears if macOS changes the
    /// band's height.
    static let clearTitlebarBoost: Double = 0.11
    static let clearTitlebarBoostHeight: CGFloat = 86

    /// The accent-diagonal strength Clear uses, standing in for `backgroundIntensity` (which stays
    /// 0 there because it also sets the material, and Clear has none). Near Frosted's 0.65, so the
    /// background reads as the accent at any level; the levels differ in how much shows through,
    /// not in colour.
    static let clearAccentStrength: Double = 0.5

    /// How much of the accent diagonal a floating panel's dark ground takes (`glassPanelGround`).
    /// The window sees its diagonal through a material; a panel's ground doesn't, and the full
    /// diagonal plus the glow would make it several times as bright as charcoal, costing the Go To
    /// results' file-type glyphs contrast. 0.4 is the most the hue can take without a glyph reading
    /// worse than on charcoal (0.5 drops the worst glyph below it); `FileTypeGlyphContrastTests`
    /// holds it there.
    static let panelGroundAccentScale: Double = 0.4

    /// The dark deep base's top stop, the brightest point of the window's dark ground before its
    /// accent — and of a panel's ground (`glassPanelGround`). Its bottom stop is `darkBaseBottom`.
    static let darkBaseTop = (red: 0.065, green: 0.082, blue: 0.115)
    static let darkBaseBottom = (red: 0.02, green: 0.027, blue: 0.043)

    /// The accent diagonal's three stop opacities, before the Tint scale (`backgroundHueStrength`)
    /// and a panel's `panelGroundAccentScale`. `accentT` is the level's accent strength.
    static func accentDiagonalOpacities(dark: Bool, accentT: Double) -> [Double] {
        dark
            ? [0.19 + 0.28 * accentT, 0.15 + 0.23 * accentT, 0.10 + 0.16 * accentT]
            : [0.06 + 0.16 * accentT, 0.05 + 0.14 * accentT, 0.04 + 0.10 * accentT]
    }
}

// MARK: - The "None" white ground

public extension LiquidGlass {
    /// The white film painted over the background material in light when the accent is "None".
    ///
    /// Without it, None's background is the bare material, a light gray within a few points of
    /// Graphite's faint wash at low Tint, so the two accents would differ only by their swatches.
    /// White is what "no accent" should look like in light: visibly no wash.
    ///
    /// A constant, not Tint-scaled: None has no hue for the slider to strengthen, and it opts out
    /// of every accent paint in the background (`BackgroundHuePaintsScaleTests` polices hue paints
    /// only; this is deliberately not one). Light only: white over dark's deep base would gray it,
    /// and dark None already reads apart from dark Graphite, which keeps its wash and glow.
    ///
    /// It applies at every light level, `.clear` included: at Clear the background is the vibrancy
    /// plus `clearLightVeil`, which reads as the same flat gray, and the film whitens it while the
    /// blur still reads as depth. Clear takes less (`clearNoneLightVeil`).
    ///
    /// `NoneHueWhitenessRenderTests` renders the real modifier and asserts the separation from
    /// Graphite. 0.7 closes about three quarters of the gap between the bare material and pure
    /// white while the material still supplies texture; 0.5 leaves a lighter gray, not white.
    static let noneLightVeil: Double = 0.7

    /// `noneLightVeil` at Clear, where None's backdrop is the near-white popover material rather
    /// than the gray `.underWindowBackground` (`clearNoneLightMaterial`). Over the white one, 0.4
    /// reads white while the desktop shows through like every other accent's, and None keeps its
    /// separation from Graphite (`NoneHueWhitenessRenderTests`).
    static let clearNoneLightVeil: Double = 0.4

    /// The behind-window material None takes at Clear in light. `.underWindowBackground` is a
    /// neutral gray there, which every accent tints into its own colour and which None, having no
    /// colour, could only whiten by covering. `.popover` is macOS's near-white popover material:
    /// still blurred, still see-through.
    static let clearNoneLightMaterial: NSVisualEffectView.Material = .popover

    /// Whether a floating panel (Settings and the other `groundedGlassCard`s, Ask Claude, the
    /// Activity window) takes the window's own glass instead of its 0.90 ground: None, in light, at
    /// Clear. There the window is a near-white blur under a white film, and a near-solid white
    /// panel would read as a sheet laid over the glass. So the panel blurs in
    /// `clearNoneLightMaterial` under `clearNoneLightVeil`, the window's recipe, and the desktop
    /// reads through it as through the window. Every accent keeps the ground: its hue is what the
    /// window shows.
    static func panelTakesWindowGlass(level: GlassLevel, hue: LiquidGlassHue, dark: Bool) -> Bool {
        level == .clear && !dark && hue == .none
    }
}

// MARK: - The Tint slider's curve
//
// Tint is the app's one hue-strength knob: every hue paint in the app scales with it, the
// window background, gutters and toolbar band as well as the content surface wash, so Tint 0
// is reachable and 0% and 100% look different.
//
// **That set is not written down here.** An enumerating comment can't notice a new paint, and
// one added at full strength would sit unmoved at Tint 0 while every numeric test passed.
// `BackgroundHuePaintsScaleTests` derives the set from `LiquidGlassBackground`'s own source, so
// whatever it paints is what gets checked. Two curves, one input:
//
//   - `tintRamp` — 0 at Tint 0, 1 at Tint 100. Drives the surface wash, which starts at nothing:
//     at 0% a pane is the background, not a wash over it.
//   - `backgroundHueStrength` — `tintFloor` at Tint 0, 1 at Tint 100. The background never goes
//     colourless: the app is still recognisably the chosen hue at 0%, just faintly.
//
// Both curves return exactly 1 at Tint 100, so every constant here paints at full strength
// there; the slider only redistributes the range below it.

public extension LiquidGlass {
    /// How much of the background's accent paint survives at Tint 0, as a fraction of what it
    /// paints at Tint 100.
    ///
    /// Not 0: a colourless floor would make every hue "None" at the bottom of the slider, and the
    /// accent picker and the slider would disagree about what colour the app is. A quarter names
    /// the hue at a glance and stays far short of a wash.
    static let tintFloor: Double = 0.25

    /// The exponent on the slider's travel. Above 1, so the bottom of the range moves slowly and
    /// the top fast: the subtle end is where the choosing happens. Deliberately mild, since a
    /// steeper curve makes the readout lie (50% would paint far less than half).
    static let tintCurve: Double = 1.35

    /// The slider's travel, shaped by `tintCurve` and clamped — 0 at Tint 0, 1 at Tint 100.
    static func tintRamp(_ tint: Double) -> Double {
        pow(max(0.0, min(1.0, tint)), tintCurve)
    }

    /// The multiplier every hue paint in the *window background* takes. Floors at `tintFloor`
    /// rather than 0 (see it), and reaches exactly 1 at Tint 100 so the ceiling is untouched.
    static func backgroundHueStrength(forTint tint: Double) -> Double {
        tintFloor + (1.0 - tintFloor) * tintRamp(tint)
    }
}

/// How the content surfaces are shaped against the app's glass background: the other half of the
/// Appearance model, orthogonal to `GlassLevel`. Stored via `LiquidGlass.surfaceStyleKey`. Shape
/// only; an opaque look is `GlassLevel.solid`.
public enum SurfaceStyle: String, CaseIterable, Identifiable {
    /// Everything under the toolbar is one outlined region, its areas divided by hairlines.
    case unified
    /// Each area floats as its own card on the background, a gutter apart.
    case cards

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .unified: return "Unified"
        case .cards: return "Cards"
        }
    }

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .unified:
            return "Everything in the window reads as one surface, divided by hairlines."
        case .cards:
            return "Each area of the window floats as its own card on the background."
        }
    }
}

public enum LiquidGlass {
    /// Corner radius for cards and floating panels: the `Radius` scale's top stop, under the name
    /// most sites use.
    public static let cardCornerRadius: CGFloat = Radius.card
    /// The gap between any two floating cards in Cards mode, and between a card and the window
    /// edge. One number for every gap on screen.
    ///
    /// Each card pads itself by `cardInset`, half the gap, so two adjacent cards add up to exactly
    /// `cardGutter`, and the content root supplies the matching half at the window edge. Don't add
    /// per-container padding: two touching cards would show twice the gap a window edge does.
    public static let cardGutter: CGFloat = 5

    /// The gutter two neighbouring areas leave between them in `style`: `cardGutter` in `.cards`,
    /// none in `.unified`, where they sit flush and meet at a hairline. For layout arithmetic that
    /// reserves room for a gap (the sidebar's slot, say); a Cards gutter reserved in Unified leaves
    /// a blank strip of exactly that width.
    public static func gutter(_ style: SurfaceStyle) -> CGFloat {
        style == .cards ? cardGutter : 0
    }

    /// The width and strength of the accent border marking the active pane.
    ///
    /// Quiet, because a pane is never alone: the source chip, view-mode button, breadcrumb and
    /// folder icons are already accent-coloured, so a saturated outline reads as an alarm rather
    /// than a state. 45% at 1.5pt is the quietest pairing that still reads in both themes; 1pt at
    /// 55% is softer in light, but in dark it blends with the card's own specular hairline
    /// (`DarkBoldCardChrome`). The border is the only thing saying which pane Copy, Move and Delete
    /// act on, so it may recede but never become ambiguous.
    public static let activeCardBorderWidth: CGFloat = 1.5

    /// How much of the accent the border carries. See `activeCardBorderWidth`.
    public static let activeCardBorderOpacity: Double = 0.45

    /// The accent at border strength, in one place so the `.cards` borders and the `.unified` ring
    /// can't drift into two different blues.
    public static func activeBorder(_ accent: Color) -> Color {
        accent.opacity(activeCardBorderOpacity)
    }

    /// What one card insets itself by, and what the content root pads by: half a gutter each, so
    /// every pairing (card↔card, card↔window edge) sums to `cardGutter`.
    public static var cardInset: CGFloat { cardGutter / 2 }

    /// The resting visible height of a header. The file panes' `PaneHeader` and the lens
    /// workspaces' `LensHeaderCard` both land here, so the pane's header↔list boundary and the lens
    /// card's bottom edge sit on the same rule across the window.
    ///
    /// Both headers inset themselves by `cardInset`, so each occupies `headerHeight + 2 *
    /// cardInset` in its parent and its bottom edge falls at `cardInset + headerHeight`, 83.5. That
    /// shared line is the point of the constant. `LensHeaderMetrics` derives its rows to match, and
    /// both are asserted against the laid-out `fittingSize`, not against each other: a constant
    /// agreeing with itself proves nothing.
    ///
    /// Edit's document header (`EditorWorkspaceView.headerCard`) is pinned here too, so it shares a
    /// bottom edge with the source pane's toolbar card beside it and the text starts where the list
    /// does. `EditHeaderMatchesPaneHeaderTests` compares the two real views at every text size.
    public static let headerHeight: CGFloat = 81
    /// Corner radius for smaller elements (badges, buttons, inputs): the `Radius` scale's `well`
    /// stop under its older name.
    public static let smallCornerRadius: CGFloat = Radius.well

    /// Soft shadow for glass cards to add depth without heaviness.
    public static let cardShadow = (color: Color.black.opacity(0.06), radius: CGFloat(12), x: CGFloat(0), y: CGFloat(4))
    /// Lighter shadow for inline elements.
    public static let subtleShadow = (color: Color.black.opacity(0.04), radius: CGFloat(6), x: CGFloat(0), y: CGFloat(2))
    /// The deep shadow a panel floating over a dimmed window casts, a step above `cardShadow`,
    /// which lifts a card off the window's own background. Apply it with `.overlayPanelShadow()`
    /// rather than reading the members; every caller wants the whole recipe.
    public static let overlayShadow = (color: Color.black.opacity(0.3), radius: CGFloat(30), x: CGFloat(0), y: CGFloat(8))

    /// UserDefaults key for the selected `GlassLevel` (raw value).
    public static let levelKey = "glassLevel"

    /// UserDefaults key for the selected `AppearanceMode` (raw value): light, dark or system.
    public static let appearanceModeKey = "appearanceMode"

    /// UserDefaults key for the selected liquid glass hue (raw value of `LiquidGlassHue`).
    public static let hueKey = "liquidGlassHue"

    /// Accents no longer offered, each with the one that replaces it. Slate, a cool blue-gray
    /// between Indigo and Graphite, read as neither; Graphite is the nearest that remains.
    static let retiredHues: [String: LiquidGlassHue] = ["slate": .graphite]

    /// Moves a stored accent that is no longer offered onto its replacement, so an install that
    /// chose it keeps a close colour rather than falling back to Blue. Returns the retired raw value
    /// and its replacement when it rewrote one, nil otherwise; a no-op on every launch after.
    @discardableResult
    public static func migrateRetiredHue(_ defaults: UserDefaults = .standard) -> (from: String, to: LiquidGlassHue)? {
        guard let raw = defaults.string(forKey: hueKey), let replacement = retiredHues[raw] else { return nil }
        defaults.set(replacement.rawValue, forKey: hueKey)
        return (raw, replacement)
    }

    /// UserDefaults key for the content surface style (raw value of `SurfaceStyle`).
    public static let surfaceStyleKey = "contentSurfaceStyle"

    /// UserDefaults key for the accent-color tint strength applied to surfaces (Double, 0...1).
    public static let tintKey = "contentSurfaceTint"
}

// MARK: - View Extensions

public extension View {
    /// Applies an app-level background that makes Liquid Glass visible by giving it subtle colour
    /// behind it.
    ///
    /// Routed through `LiquidGlassBackground` so it can read `@Environment(\.colorScheme)`: the
    /// light-tuned constants collapse to a flat gray slab on a dark appearance, so dark gets a deep
    /// graded near-black base under the material, a soft accent glow over it, and a stronger accent
    /// diagonal. `tint` is the Tint slider, 0...1; the background's accent paint scales with it
    /// (down to `LiquidGlass.tintFloor`, never to nothing), so the slider moves the whole window
    /// (see "The Tint slider's curve"). No default: both call sites read the stored value, and a
    /// default would let one sit silently at full strength.
    func liquidGlassAppBackground(level: GlassLevel, hue: LiquidGlassHue = .blue,
                                  tint: Double) -> some View {
        modifier(LiquidGlassBackground(level: level, hue: hue, tint: tint))
    }

    /// An accent-tinted glass capsule for small chrome (the selection action bar, status pills). On
    /// macOS 26 it tints the native glass itself, so the surface reads as the accent hue rather
    /// than a neutral gray `Material` with a thin accent wash on top; earlier systems get exactly
    /// that thin material and wash. `strength` is the tint opacity on the glass, `fallbackWash` the
    /// accent opacity on the fallback.
    @ViewBuilder
    func accentGlassCapsule(_ accent: Color, strength: Double = 0.55, fallbackWash: Double = 0.14) -> some View {
        // The accent verbatim, the exact hue picked in Settings, never darkened or remapped.
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(accent.opacity(strength)), in: Capsule())
        } else {
            self.background(Capsule().fill(.thinMaterial).overlay(Capsule().fill(accent.opacity(fallbackWash))))
        }
    }

    /// The material fill for one content surface, and the one place the level → appearance decision
    /// is made: panes, the bottom workspace, bars and overlay chrome all route through it, so they
    /// can't drift apart. A `ViewModifier` because the material depends on the appearance (see
    /// `GlassSurface`).
    func glassSurface(_ level: GlassLevel, cornerRadius: CGFloat) -> some View {
        modifier(GlassSurface(level: level, cornerRadius: cornerRadius))
    }

    /// `glassSurface` for a floating panel (Settings and the other `groundedGlassCard`s, and Ask
    /// Claude), with one difference: Clear in light is clear glass, as in dark, rather than
    /// `glassSurface`'s `.ultraThinMaterial`, whose blur hides the window behind a panel whatever
    /// its ground and makes the panel read as solid. Panes and bars keep `glassSurface`'s material.
    func floatingPanelGlass(_ level: GlassLevel, cornerRadius: CGFloat) -> some View {
        modifier(FloatingPanelGlass(level: level, cornerRadius: cornerRadius))
    }

    /// Frosted glass card style for floating overlay chrome (Settings, Help, the first-run card,
    /// the operation banner). Applies `flooredForChrome`, so a `.clear` app never produces an
    /// unreadable dialog: these are the surfaces with live content behind them.
    ///
    /// The border and shadow route through `OverlayCardChrome` so dark can go bold: a top-lit white
    /// specular hairline and a deeper, larger shadow that lifts the card off the dimmed backdrop
    /// (the light-tuned `cardShadow` is nearly invisible on a dark scrim). Light keeps the soft
    /// `cardShadow` on the explicit-chrome path, and nothing on native glass.
    @ViewBuilder
    func glassCardStyle(level: GlassLevel) -> some View {
        let resolved = level.flooredForChrome
        let radius = LiquidGlass.cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let chrome = OverlayCardChrome(cornerRadius: radius, lightShadow: resolved.needsExplicitChrome)
        // `.glassEffect` shapes only the effect, not the view's own backgrounds, and every caller
        // stacks `contentSurface`'s square tint wash under this, so clip either way or the wash
        // pokes past the rounded corners at any Tint above zero (as in surfaceCard and
        // bottomSectionCard). The explicit-chrome path clips after filling; native glass clips
        // first. Two `@ViewBuilder` branches rather than an `AnyView`, so the subtree keeps its
        // structural identity: an erased card re-renders whole on every parent update, such as the
        // banner's tick.
        if resolved.needsExplicitChrome {
            self.glassSurface(resolved, cornerRadius: radius).clipShape(shape).modifier(chrome)
        } else {
            self.clipShape(shape).glassSurface(resolved, cornerRadius: radius).modifier(chrome)
        }
    }

    /// `glassCardStyle`'s chrome at the level's face value, with a ground under the content instead
    /// of a floor over the level.
    ///
    /// `glassCardStyle`'s `flooredForChrome` makes Clear and Frosted render alike over live
    /// content, which reads, rightly, as the control not working. This keeps the level and puts a
    /// near-opaque ground between the material and the card's text instead: the window stays
    /// visibly behind the card, the level still decides the material's tint, edge and margins, and
    /// the text always has something to sit on.
    ///
    /// `backingOpacity` is the one knob, defaulting to the level's `groundedBackingOpacity`. The
    /// ground is `glassPanelGround`, in the stored accent and Tint.
    func groundedGlassCard(level: GlassLevel, backingOpacity: Double? = nil) -> some View {
        modifier(GroundedGlassCard(level: level,
                                   backingOpacity: backingOpacity ?? level.groundedBackingOpacity))
    }

    /// The ground under a floating panel's text, `opacity` thick, between the text and the panel's
    /// glass (`groundedGlassCard`, Ask Claude).
    ///
    /// In light, and at Solid, `controlBackgroundColor`, the colour `lensCard` fills with. In dark
    /// at Frosted and Clear, the window's own dark ground instead: its deep base plus a share of
    /// its accent diagonal in `hue` at `tint` (`LiquidGlass.panelGroundAccentScale`), because
    /// neutral charcoal reads as a grey panel on an accent-tinted window. Solid's panels are opaque
    /// `controlBackgroundColor`, like the panes there. `lensCard` keeps charcoal in dark: it sits
    /// on a pane, not over the window.
    func glassPanelGround(level: GlassLevel, hue: LiquidGlassHue, tint: Double, opacity: Double,
                          cornerRadius: CGFloat) -> some View {
        modifier(GlassPanelGround(level: level, hue: hue, tint: tint, opacity: opacity,
                                  cornerRadius: cornerRadius))
    }

    /// Lighter glass style for bars and inline panels. These sit over the window's own background
    /// rather than over content, so they take the level verbatim, no floor. Dark adds a top-lit
    /// specular hairline (via `GlassBarStyle`) so the bar reads as glass chrome against the deep
    /// background; light is unchanged.
    func glassBarStyle(level: GlassLevel) -> some View {
        modifier(GlassBarStyle(level: level))
    }

    /// The button style for a bar of controls, resolved from the level.
    ///
    /// At `.clear` the card behind these buttons is see-through to the desktop, and a bordered
    /// button's fill is too faint to survive that, so native Liquid Glass gives each button its own
    /// material: the card stays clear and only the buttons frost. Everywhere else, `.bordered`. Per
    /// control rather than a frosted band behind the bar, which would make the bar opaque and take
    /// back the transparency the level asked for.
    @ViewBuilder
    func chromeButtonStyle(_ level: GlassLevel) -> some View {
        if level.needsChromeFrosting, #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// The accent wash driven by the Tint slider (`tint`, 0...1), for every shape and level. Apply
    /// it once per region; stacked on nested views, washes compound. The opaque base for `.solid`
    /// comes from `GlassLevel`, not here.
    @ViewBuilder
    func contentSurface(hue: LiquidGlassHue = .blue, tint: Double = 0) -> some View {
        // A transparent wash at tint 0, up to a clear but legible accent at tint 1. "None" gets no
        // wash at any tint: its accentColor is the system accent (for controls), which would
        // repaint the surfaces.
        let wash = hue == .none ? Color.clear : hue.accentColor.opacity(LiquidGlass.tintRamp(tint) * 0.32)
        self.background(wash)
    }

    /// Floating-card decoration for the `.cards` shape: the level's fill, rounded corners, and an
    /// outer gutter so the background shows between cards. Native Liquid Glass draws its own
    /// shadow; `.solid` and the pre-macOS 26 fallback draw theirs explicitly.
    ///
    /// The hairline and shadow route through `DarkBoldCardChrome`: dark swaps the faint
    /// `.quaternary` edge for a top-lit white specular hairline and a deeper shadow, so each card
    /// lifts off the deep background. `accentBorder` draws the card's own edge in the accent rather
    /// than adding anything beside it (see `LiquidGlass.activeCardBorderWidth`).
    func surfaceCard(_ level: GlassLevel, cornerRadius: CGFloat = LiquidGlass.cardCornerRadius,
                     accentBorder: Color? = nil) -> some View {
        // Clip the content to the card shape first: the pane's contentSurface tint wash is a square
        // fill, and would poke past the rounded corners into the gutters.
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let explicit = level.needsExplicitChrome
        return self.clipShape(shape)
            .glassSurface(level, cornerRadius: cornerRadius)
            // `lightBorder: true`, not `explicit` (see `CardHairline`): the light edge native glass
            // draws for itself can't be seen.
            .modifier(DarkBoldCardChrome(
                cornerRadius: cornerRadius,
                lightBorder: true, lightShadow: explicit, darkShadow: true))
            // `strokeBorder`, never `stroke`: it draws inside the shape, so the accent replaces the
            // card's hairline in place, where a centred `stroke` would spill half its width into
            // the gutter. Above the chrome so it wins over the hairline, and never a hit target:
            // the content owns every click.
            .overlay {
                if let accentBorder {
                    shape.strokeBorder(accentBorder, lineWidth: LiquidGlass.activeCardBorderWidth)
                        .allowsHitTesting(false)
                }
            }
            .padding(LiquidGlass.cardInset)
    }

    /// Wraps a file pane as a floating card for `.cards`; leaves it untouched otherwise.
    ///
    /// `accentBorder` marks the active pane in `.cards`, where a pane is a stack of cards (tab
    /// strip, header, list) separated by gutters; every card in the stack takes it, so the stack
    /// reads as one active object. `.unified` has no per-pane card, so the caller rings the pane's
    /// bounds there.
    @ViewBuilder
    func paneCardIfNeeded(_ style: SurfaceStyle, level: GlassLevel,
                          accentBorder: Color? = nil) -> some View {
        if style == .cards { self.surfaceCard(level, accentBorder: accentBorder) } else { self }
    }

    // MARK: Unified is one box
    //
    // In `.unified` everything under the toolbar is one outlined region (the sidebar, the panes,
    // the lens panel, Differences, Edit's strip, rail and document, the Info inspector), and the
    // areas in it meet at a hairline (`unifiedSeam`), not a gutter. `.cards` is the opposite: every
    // area floats as its own card, a gutter apart. One region per area would just be Cards drawn
    // with hairlines.
    //
    // So in `.unified` the section frames below draw nothing and inset nothing (the tint wash and a
    // clip are all that's left of them), and `windowRegionFrame`, applied once round the whole
    // content, is the only outline.

    /// The one outlined region `.unified` draws, round everything under the toolbar; a no-op in
    /// `.cards`, where each area is its own card.
    ///
    /// The level supplies the fill: `.solid` needs an opaque base here (the sections' own
    /// `contentSurface` only paints the tint wash), while glass levels let the window background
    /// through, which is what "unified" means. Insets itself by `cardInset`, the window-edge half of
    /// a gutter, so it sits exactly where a card's edge sits in `.cards`.
    @ViewBuilder
    func windowRegionFrame(_ style: SurfaceStyle, level: GlassLevel) -> some View {
        let radius = LiquidGlass.cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .cards:
            self
        case .unified:
            let based = level == .solid
                ? AnyView(self.glassSurface(.solid, cornerRadius: radius))
                : AnyView(self)
            based
                .clipShape(shape)
                .modifier(DarkBoldCardChrome(
                    cornerRadius: radius,
                    lightBorder: true, lightShadow: false, darkShadow: false))
                .padding(LiquidGlass.cardInset)
        }
    }

    /// The hairline where two areas meet inside `.unified`'s one region, drawn over this view's
    /// `edge`; nothing in `.cards`, where the gutter between two cards is the boundary. Costs no
    /// room: it sits on the edge rather than beside it.
    func unifiedSeam(_ style: SurfaceStyle, edge: Edge) -> some View {
        let alignment: Alignment = switch edge {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
        return self.overlay(alignment: alignment) {
            if style == .unified {
                switch edge {
                case .top, .bottom: Divider()
                // An HStack is what turns a `Divider` vertical.
                case .leading, .trailing: HStack(spacing: 0) { Divider() }
                }
            }
        }
    }

    /// The panes (both flush panes, in Compare) as one area: nothing in either style. In `.cards`
    /// each pane is its own floating card (`paneCardIfNeeded`); in `.unified` the panes sit inside
    /// `windowRegionFrame` with everything else, clipped to their own bounds.
    @ViewBuilder
    func panesRegionFrame(_ style: SurfaceStyle, level: GlassLevel) -> some View {
        switch style {
        case .cards: self
        case .unified: self.clipped()
        }
    }

    /// One section of the bottom workspace (the toolbar, or the table / Details) as a
    /// self-contained card: the tint wash, then a frame, a floating card in `.cards` and just the
    /// wash, clipped, in `.unified`, where `windowRegionFrame` is the only frame. A header over
    /// content goes through `columnSectionCard` / `columnRegionFrame` instead, which call this per
    /// section in Cards and once per column in Unified.
    ///
    /// In `.cards` it insets itself by `cardInset`, half a gutter, so two stacked sections are
    /// exactly one `cardGutter` apart and line up with the pane cards at the window edge; callers
    /// stack these at `spacing: 0` with no padding of their own. In `.unified` it insets nothing:
    /// neighbours sit flush and meet at a `unifiedSeam`.
    ///
    /// Every section takes the level verbatim, toolbars included; a toolbar's buttons get their own
    /// material via `chromeButtonStyle`, so the bar doesn't become an opaque band across a window
    /// the user asked to see through.
    @ViewBuilder
    func bottomSectionCard(
        _ style: SurfaceStyle,
        level: GlassLevel,
        hue: LiquidGlassHue = .blue,
        tint: Double = 0
    ) -> some View {
        let radius = LiquidGlass.cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch style {
        case .cards:
            let explicit = level.needsExplicitChrome
            self.contentSurface(hue: hue, tint: tint)
                .clipShape(shape)
                .glassSurface(level, cornerRadius: radius)
                // `lightBorder: true`, as in `surfaceCard` and for the same reason.
                .modifier(DarkBoldCardChrome(
                    cornerRadius: radius,
                    lightBorder: true, lightShadow: explicit, darkShadow: true))
                .padding(LiquidGlass.cardInset)
        case .unified:
            // No fill, outline or inset: `windowRegionFrame` supplies all three, once.
            self.contentSurface(hue: hue, tint: tint)
                .clipped()
        }
    }

    // MARK: A workspace column — a header over its content
    //
    // One rule for every column with a header over content, in both styles: the file pane (toolbar
    // over list), Edit's document (header over text), every Organize lens (lens header over its
    // content, Storage included) and Compare's Differences area (toolbar over table).
    //
    // - `.cards`: each section is its own floating card, and the gutter between them is the
    //   boundary.
    // - `.unified`: the column is one area of the window's one region (`windowRegionFrame`), its
    //   content flush under the header, and a hairline (`columnHeaderRule`) is the boundary.
    //
    // So switching styles changes every column alike, and a lens's content starts level with the
    // file list beside it. The panes keep their own pair (`paneCardIfNeeded` / `panesRegionFrame`)
    // because two panes share one region; every other column uses these three.

    /// One section of a workspace column (its header, or the content under it): its own card in
    /// `.cards`, nothing in `.unified`, where `columnRegionFrame` frames the whole column. Pair the
    /// two on every column; either alone draws a column with no frame (Unified) or a card inside a
    /// card (Cards).
    @ViewBuilder
    func columnSectionCard(
        _ style: SurfaceStyle,
        level: GlassLevel,
        hue: LiquidGlassHue = .blue,
        tint: Double = 0
    ) -> some View {
        switch style {
        case .cards: self.bottomSectionCard(.cards, level: level, hue: hue, tint: tint)
        case .unified: self
        }
    }

    /// The whole workspace column as one area in `.unified` (`bottomSectionCard`'s Unified shape:
    /// the tint wash and a clip, with `windowRegionFrame` outside it as the outline), and a no-op
    /// in `.cards`, where each `columnSectionCard` is the frame.
    @ViewBuilder
    func columnRegionFrame(
        _ style: SurfaceStyle,
        level: GlassLevel,
        hue: LiquidGlassHue = .blue,
        tint: Double = 0
    ) -> some View {
        switch style {
        case .cards: self
        case .unified: self.bottomSectionCard(.unified, level: level, hue: hue, tint: tint)
        }
    }

    /// The hairline under a column's header in `.unified`; nothing in `.cards`, where the gutter
    /// between the two cards is the boundary. Drawn over the header's bottom edge, so it costs no
    /// height and the content still starts at the header's pinned edge.
    ///
    /// `overContent: false` for a header that is momentarily the whole column (Differences folded
    /// to its toolbar): the window region's outline is its bottom edge then, and a rule would draw
    /// that edge twice.
    func columnHeaderRule(_ style: SurfaceStyle, overContent: Bool = true) -> some View {
        self.overlay(alignment: .bottom) {
            if style == .unified, overContent { Divider() }
        }
    }
}

/// Backs `glassSurface`: native Liquid Glass in dark, and the `Material` family in light.
///
/// Native Liquid Glass darkens in a light appearance, which inverts the card metaphor. Measured
/// off a real window (light, Cards, Frosted, purple hue, tint 0, macOS 26):
///
/// | surface | luminance |
/// |---|---|
/// | window ground — margins, toolbar band | 237-239 |
/// | gutters between cards | 216-220 |
/// | a section or pane card | 210-213 |
/// | a `lensCard` nested inside one | 206-208 |
///
/// A card sits below the surface it should float on, and nesting drives it lower; a large
/// near-empty card reads as a grey rectangle laid over the window. Nothing in the public API
/// lightens the native material from outside:
///
/// | attempt | card, against a ~234 ground |
/// |---|---|
/// | `Glass.tint(.white.opacity(0.5))` | 211 → 198 — a tint densifies, it does not lighten |
/// | `controlBackgroundColor` ground UNDER `.glassEffect` | 211 → 213, where 235 was predicted |
/// | the same ground stacked OVER the glass in the background layer | no better |
///
/// `.glassEffect` dominates its own subtree, swallowing a fill behind it or stacked on it. So light
/// takes the `Material` branch, the rendering this palette was tuned against. Dark keeps native
/// glass: there it renders lighter than the deep ground, so a card already reads as lifted, and
/// `DarkBoldCardChrome` adds a specular hairline and a deep shadow on top.
private struct GlassSurface: ViewModifier {
    let level: GlassLevel
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch level {
        case .solid:
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        case .clear, .frosted:
            if #available(macOS 26.0, *), scheme == .dark {
                content.glassEffect(level == .frosted ? .regular : .clear,
                                    in: .rect(cornerRadius: cornerRadius))
            } else {
                content.background(level == .frosted ? Material.thinMaterial : Material.ultraThinMaterial,
                                   in: shape)
            }
        }
    }
}

/// Backs `floatingPanelGlass`.
private struct FloatingPanelGlass: ViewModifier {
    let level: GlassLevel
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), level == .clear, scheme != .dark {
            content.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.glassSurface(level, cornerRadius: cornerRadius)
        }
    }
}

// MARK: - Appearance-aware chrome (the dark-mode "bold" re-tune)
//
// The glass surfaces above are tuned for light, and one set of constants reads as a flat gray
// slab on a dark appearance. These modifiers give each surface a bold dark variant: a deep graded
// base and accent glow behind the app, top-lit white specular hairlines on the cards and bars,
// and deeper shadows that lift chrome off the dark ground. Each is a `ViewModifier` so it can read
// `@Environment(\.colorScheme)`; the light branch of each is the light rendering, unchanged.

/// The app background. Light is the accent diagonal gradient over a `.thinMaterial` base at
/// `0.45 + 0.20·t`, plus, for "None" only, a white film over the material
/// (`LiquidGlass.noneLightVeil`) so no accent reads white rather than material gray. Dark adds a
/// deep, faintly cool near-black gradient under the material so the ground grades with depth, a
/// soft pool of the accent at the top edge over it so the accent reads, a thinner material so the
/// base shows through, and a stronger accent diagonal. `.clear` stays see-through: it skips the
/// opaque material, but in dark still takes a translucent veil of the base and a toned-down glow,
/// so it reads as deep glass over the desktop rather than a pale wash.
///
/// `panelGround` paints only the window's own dark ground (the deep base, opaque at every level,
/// and the accent diagonal at `LiquidGlass.panelGroundAccentScale`) for `glassPanelGround` to lay
/// under a floating panel's text. Dark only. No glow: it pools at the top, where a panel's first
/// rows sit, and would cost them contrast. Nothing behind-window: `BehindWindowGlass` sets its
/// window's `isOpaque` and `backgroundColor` even when disabled, which squares a borderless
/// panel's corners. No material or Clear veils either: the panel's own glass stands in for those.
private struct LiquidGlassBackground: ViewModifier {
    let level: GlassLevel
    let hue: LiquidGlassHue
    /// The Tint slider, 0...1; scales every accent paint below.
    let tint: Double
    var panelGround = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let t = level.backgroundIntensity
        // `.clear` keeps the window see-through: the opaque material stays off, and in dark the deep
        // base drops to a translucent veil (below) rather than a solid ground.
        let seeThrough = level == .clear

        // The accent diagonal takes its strength from `backgroundIntensity` at every level but
        // Clear, where that is 0 because it also sets the material. Clear needs its own: the
        // gutters and the toolbar band are the only uncovered background, and at 0 they would come
        // out gray-white.
        let accentT = seeThrough ? LiquidGlass.clearAccentStrength : t
        // Every accent paint below is scaled by this one value, resolved once so no two paints can
        // compute their own floor and drift apart at the low end. `BackgroundHuePaintsScaleTests`
        // derives the set from this source and fails any paint that doesn't carry it.
        let hueStrength = LiquidGlass.backgroundHueStrength(forTint: tint)
        let opacities = LiquidGlass.accentDiagonalOpacities(dark: dark, accentT: accentT)
        let gradientColors = zip(hue.gradientColors, opacities)
            .map { $0.0.opacity($0.1 * hueStrength * (panelGround ? LiquidGlass.panelGroundAccentScale : 1)) }

        content.background {
            ZStack {
                if !panelGround {
                    BehindWindowGlass(
                        isEnabled: seeThrough,
                        vibrancyAlpha: seeThrough ? LiquidGlass.clearVibrancyAlpha : 1.0,
                        material: !dark && hue == .none ? LiquidGlass.clearNoneLightMaterial : .underWindowBackground)
                        .ignoresSafeArea()
                }

                // Dark deep base: a near-black, faintly cool gradient. At `.frosted`/`.solid` it's
                // the whole ground the material sits on; at `.clear` it drops to a translucent veil
                // over the behind-window vibrancy, so the desktop reads through as deep glass
                // rather than a pale wash.
                if dark {
                    LinearGradient(
                        colors: [Color(red: LiquidGlass.darkBaseTop.red, green: LiquidGlass.darkBaseTop.green,
                                       blue: LiquidGlass.darkBaseTop.blue),
                                 Color(red: LiquidGlass.darkBaseBottom.red, green: LiquidGlass.darkBaseBottom.green,
                                       blue: LiquidGlass.darkBaseBottom.blue)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .opacity(seeThrough && !panelGround ? LiquidGlass.clearDarkVeil : 1)
                    .ignoresSafeArea()
                }

                // At Clear in light the behind-window vibrancy alone reads as flat system gray. A
                // translucent white veil warms it toward frosted white glass while what's behind
                // still shows through; the panes are see-through, so this veil whitens them too,
                // hence a fairly strong wash.
                //
                // It goes under the accent diagonal, never over it: on top, it buries the hue, and
                // the gutters and toolbar band lose the accent.
                if seeThrough && !dark {
                    Color.white.opacity(LiquidGlass.clearLightVeil)
                        .ignoresSafeArea()
                }

                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if panelGround {
                    // The panel's own glass is its material, and Clear's veils are the window's.
                } else if !seeThrough {
                    // Base material so content stays readable. Dark thins it so the deep base reads
                    // through instead of flattening back to system gray.
                    Color.clear
                        .background(.thinMaterial.opacity((dark ? 0.27 : 0.45) + 0.20 * t))
                        .ignoresSafeArea()
                } else if hue != .none {
                    // An even accent wash over the whole background, so the hue reads as a colour
                    // rather than a diagonal fading out at one corner. `.none` opts out: its
                    // accentColor is the system accent, which would repaint the background in a hue
                    // the user didn't choose.
                    hue.accentColor.opacity(LiquidGlass.clearAccentVeil * hueStrength)
                        .ignoresSafeArea()

                    // Extra accent under the titlebar band, which dilutes what it covers (see
                    // `clearTitlebarBoost`). Anchored to the top and faded out well past the band's
                    // edge, so it reads as part of the background rather than a stripe.
                    VStack(spacing: 0) {
                        LinearGradient(
                            stops: [
                                // Hold the boost flat across the band itself, then fade: a gradient
                                // that starts falling immediately leaves the band's lower edge short
                                // of the content it sits against.
                                .init(color: hue.accentColor.opacity(LiquidGlass.clearTitlebarBoost * hueStrength), location: 0),
                                .init(color: hue.accentColor.opacity(LiquidGlass.clearTitlebarBoost * hueStrength), location: 0.62),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: LiquidGlass.clearTitlebarBoostHeight)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea()
                }

                // The "None" white ground, light only (see `LiquidGlass.noneLightVeil`). Over the
                // material (and at Clear over the vibrancy and `clearLightVeil`), not under, so
                // what it sits on can't dilute it and it lands at every level. The titlebar band
                // passes about three quarters of what is beneath it (see `clearTitlebarBoost`), so
                // it whitens with the rest of the window.
                if !dark && hue == .none {
                    Color.white.opacity(seeThrough ? LiquidGlass.clearNoneLightVeil : LiquidGlass.noneLightVeil)
                        .ignoresSafeArea()
                }

                // Dark accent glow: a soft pool of the hue at the top so the accent reads. At every
                // dark level, `.clear` included, there at a lower strength since it sits over the
                // veil and desktop rather than an opaque material. `.none` opts out (it defers to
                // the system accent), and so does a panel's ground (see `panelGround`).
                if dark && hue != .none && !panelGround {
                    RadialGradient(
                        colors: [hue.accentColor.opacity((seeThrough ? 0.18 : 0.26 + 0.10 * t) * hueStrength), .clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: 700
                    )
                    .blendMode(.plusLighter)
                    .ignoresSafeArea()
                }
            }
        }
    }
}

/// Border and shadow for a floating overlay card (Settings, Help, the operation banner, the ⌘K
/// palette) over a dimmed backdrop. Dark draws a top-lit white specular hairline and a deeper,
/// larger shadow so the card lifts off the scrim, where the light-tuned `cardShadow` is nearly
/// invisible. Light draws the `.quaternary` hairline only where `lightBorder` asks, and the soft
/// `cardShadow` only on the explicit-chrome path (native glass draws its own).
private struct OverlayCardChrome: ViewModifier {
    let cornerRadius: CGFloat
    let lightShadow: Bool
    /// Whether to draw the light-mode `.quaternary` hairline.
    ///
    /// Off by default, so the banner and the ⌘K palette keep their chrome. The full-size panels
    /// (Settings, Help, Welcome, the destination picker) turn it on, because in light this modifier
    /// draws no edge and those cards need one against the scrim. Owning both schemes here keeps the
    /// light hairline and the dark specular one mutually exclusive; a caller's own stroke would
    /// land on top of the dark hairline and draw two borders.
    var lightBorder: Bool = false
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if scheme == .dark {
            content
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 34, y: 12)
        } else {
            content
                .overlay {
                    if lightBorder { shape.strokeBorder(.quaternary, lineWidth: 0.5) }
                }
                .shadow(
                    color: lightShadow ? LiquidGlass.cardShadow.color : .clear,
                    radius: lightShadow ? LiquidGlass.cardShadow.radius : 0,
                    x: lightShadow ? LiquidGlass.cardShadow.x : 0,
                    y: lightShadow ? LiquidGlass.cardShadow.y : 0)
        }
    }
}

/// Bar and panel glass with a dark-only top-lit specular hairline, so a bar reads as distinct glass
/// chrome against the deep dark background. Light takes the level's surface verbatim.
private struct GlassBarStyle: ViewModifier {
    let level: GlassLevel
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: LiquidGlass.smallCornerRadius, style: .continuous)
        content
            .glassSurface(level, cornerRadius: LiquidGlass.smallCornerRadius)
            .overlay {
                if scheme == .dark {
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
            }
    }
}

/// The appearance-aware hairline every content card wears: a top-lit white specular gradient in
/// dark, so the card reads as lit glass on the deep ground, and the faint `.quaternary` rule in
/// light. One definition, so lens cards, pane and section cards and the bottom-workspace sections
/// all edge identically.
///
/// `lightVisible` is true at every content-card call site, native glass included: the edge native
/// glass draws is invisible in light. Measured across a card boundary in `.cards` (light, Frosted,
/// macOS 26), without and with the rule:
///
///     before   211 211 | 244  227 228 228 228 219 218 218  244 | 211 211
///     after    213 213 | 192  233 233 233 233 233 233 232  192 | 213 213
///
/// Without it a card's only visible bound is the material's own darkening, and a card the size of
/// a lens workspace reads as a grey rectangle laid over the window. With it, a `.quaternary`
/// hairline at 192 and a flat gutter between cards. The parameter stays for a surface that wants
/// no light rule; dark ignores it.
struct CardHairline: ViewModifier {
    var cornerRadius: CGFloat = LiquidGlass.cardCornerRadius
    var lightVisible: Bool = true
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.overlay {
            if scheme == .dark {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            } else if lightVisible {
                shape.strokeBorder(.quaternary, lineWidth: 0.5)
            }
        }
    }
}

/// Hairline and shadow for content cards (file panes, bottom-workspace sections). The hairline is
/// `CardHairline` (white specular in dark, `.quaternary` in light); this adds depth on top: a deep
/// dark-only lift where `darkShadow`, a soft light shadow where `lightShadow`. `lightBorder`
/// forwards to the hairline's `lightVisible`.
private struct DarkBoldCardChrome: ViewModifier {
    let cornerRadius: CGFloat
    let lightBorder: Bool
    let lightShadow: Bool
    let darkShadow: Bool
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let bordered = content.modifier(CardHairline(cornerRadius: cornerRadius, lightVisible: lightBorder))
        if dark && darkShadow {
            bordered.shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        } else if !dark && lightShadow {
            bordered.shadow(color: .black.opacity(0.12), radius: 7, x: 0, y: 3)
        } else {
            bordered
        }
    }
}

/// Backs `groundedGlassCard`. Mirrors `glassCardStyle`'s structure (same radius, same
/// `OverlayCardChrome`, same two-branch clip order), but takes the level unfloored and draws a
/// ground beneath the content.
private struct GroundedGlassCard: ViewModifier {
    let level: GlassLevel
    let backingOpacity: Double
    @Environment(\.colorScheme) private var scheme
    // The ground's accent and Tint, read here rather than passed: the callers hold only the level,
    // and these are the same keys and defaults every other reader uses.
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = SelectionLensAppearance.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var tint: Double = SelectionLensAppearance.defaultTint

    func body(content: Content) -> some View {
        let radius = LiquidGlass.cardCornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // `lightBorder: true`: this backs the full-size in-window panels, and in light the chrome
        // draws no edge of its own. The chrome owns both schemes, so callers add no stroke and the
        // dark hairline isn't doubled.
        let chrome = OverlayCardChrome(cornerRadius: radius, lightShadow: level.needsExplicitChrome,
                                       lightBorder: true)
        // Drawn under the content and over the material: a background applied first sits nearest
        // the content, so the stack reads text → ground → glass → window.
        let grounded = content
            .glassPanelGround(level: level, hue: LiquidGlassHue(rawValue: hueRaw) ?? SelectionLensAppearance.defaultHue,
                              tint: tint, opacity: backingOpacity, cornerRadius: radius)
        // Same branch order as `glassCardStyle`, and two `@ViewBuilder` arms rather than an erased
        // view for the same reason: an erased card re-renders whole on every parent update.
        if LiquidGlass.panelTakesWindowGlass(level: level, hue: LiquidGlassHue(rawValue: hueRaw) ?? SelectionLensAppearance.defaultHue,
                                             dark: scheme == .dark) {
            content
                .background(Color.white.opacity(LiquidGlass.clearNoneLightVeil))
                .background(WithinWindowGlass(material: LiquidGlass.clearNoneLightMaterial))
                .clipShape(shape).modifier(chrome)
        } else if level.needsExplicitChrome {
            grounded.floatingPanelGlass(level, cornerRadius: radius).clipShape(shape).modifier(chrome)
        } else {
            grounded.clipShape(shape).floatingPanelGlass(level, cornerRadius: radius).modifier(chrome)
        }
    }
}

public extension View {
    /// At Clear, the ground a floating panel's text sits on (`groundedGlassCard`), laid under a
    /// whole window's content: the Activity window, which is its own window over the desktop and
    /// would otherwise show the desktop straight through while Settings beside it reads as a panel.
    /// Every other level passes through, and so does None in light, where panels take the window's
    /// glass (`LiquidGlass.panelTakesWindowGlass`) and this window already is that glass.
    func clearWindowGround(level: GlassLevel) -> some View {
        modifier(ClearWindowGround(level: level))
    }
}

private struct ClearWindowGround: ViewModifier {
    let level: GlassLevel
    @Environment(\.colorScheme) private var scheme
    @AppStorage(LiquidGlass.hueKey) private var hueRaw: String = SelectionLensAppearance.defaultHue.rawValue
    @AppStorage(LiquidGlass.tintKey) private var tint: Double = SelectionLensAppearance.defaultTint

    @ViewBuilder
    func body(content: Content) -> some View {
        let hue = LiquidGlassHue(rawValue: hueRaw) ?? SelectionLensAppearance.defaultHue
        // Not where the window's glass stands in for the ground: this window IS that glass.
        if level == .clear, !LiquidGlass.panelTakesWindowGlass(level: level, hue: hue, dark: scheme == .dark) {
            content.glassPanelGround(level: level, hue: hue, tint: tint, opacity: level.groundedBackingOpacity,
                                     cornerRadius: 0)
        } else {
            content
        }
    }
}

/// The dimming behind a floating panel (Settings, Help, Setup, Compare's overlays) at the level's
/// `overlayScrimOpacity` in the current colour scheme. A view, not a colour, because the opacity
/// depends on the scheme, which only the environment knows; every scrim drawing through this one
/// keeps them from drifting apart. Callers add their own `ignoresSafeArea` and tap.
public struct OverlayScrim: View {
    let level: GlassLevel
    @Environment(\.colorScheme) private var scheme

    public init(level: GlassLevel) {
        self.level = level
    }

    public var body: some View {
        Rectangle()
            .fill(Color.black.opacity(level.overlayScrimOpacity(dark: scheme == .dark)))
            // Light's Clear scrim is fully transparent, and a clear fill takes no clicks, so the
            // shape is the hit area, or clicking away from the card would stop closing it.
            .contentShape(Rectangle())
    }
}

/// Backs `glassPanelGround`.
private struct GlassPanelGround: ViewModifier {
    let level: GlassLevel
    let hue: LiquidGlassHue
    let tint: Double
    let opacity: Double
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if scheme == .dark && level != .solid {
            // Flattened before it is thinned, so the ground fades as one layer rather than each
            // paint fading separately over whatever shows through the panel.
            content.background(
                Color.clear
                    .modifier(LiquidGlassBackground(level: level, hue: hue, tint: tint, panelGround: true))
                    .compositingGroup()
                    .opacity(opacity)
                    .clipShape(shape))
        } else {
            content.background(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(opacity)))
        }
    }
}
