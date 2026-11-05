import Design
import SwiftUI

/// The frame every setup screen is drawn in: a crumb strip and the text-size control above, the
/// content and its Why panel in the middle, the lock line and the buttons below.
///
/// One card, ten screens. The chrome is identical on every screen so only the question changes as
/// the user moves: a container that resizes under a form draws the eye to the container.
struct SetupScreenCard<Content: View, Why: View>: View {
    /// The crumb strip's screens, or empty for a screen that shows a title instead.
    var crumbs: [SetupFlow.Screen] = []
    var current: SetupFlow.Screen
    /// The title shown where the crumb strip would be, on Welcome and Summary.
    var title: String?
    @Binding var fontSize: FontSize
    var tint: Color
    /// Whether Back is offered, and what it does.
    var onBack: (() -> Void)?
    var skipTitle: String?
    var onSkip: (() -> Void)?
    /// A second way forward beside the primary: Learn Again, over a reading already in hand.
    var secondaryTitle: String? = nil
    var onSecondary: (() -> Void)? = nil
    var isSecondaryDisabled = false
    var primaryTitle: String
    var onPrimary: () -> Void
    /// Set when the screen's primary action can't be taken yet: Learn with no folder chosen, or
    /// Save while the last press is still writing.
    var isPrimaryDisabled = false
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var why: () -> Why

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appFontScale) private var fontScale

    /// The card's own geometry moves by `chromeScale`, not by the text scale; see its doc comment.
    private var scale: CGFloat { SetupSheetMetrics.chromeScale(fontScale) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 0) {
                // The content column scrolls, and the chrome doesn't. The card is one fixed height,
                // but Locations draws a row per location and People a chip per name. Without a
                // scroll view a VStack taller than its frame is centred and clipped at both ends,
                // so the crumb strip at the top and the primary button at the bottom, the way out
                // of the screen, go first.
                //
                // `.basedOnSize` so a screen that fits doesn't rubber-band: bounce on a card with
                // nothing to scroll reads as a broken window.
                //
                // `minHeight` makes the screens' own `Spacer`s work. A `ScrollView` proposes `nil`
                // height, so a `VStack` inside is exactly as tall as its subviews and a trailing
                // `Spacer(minLength: 0)` has nothing to expand into: each screen's closing line
                // would ride up under its controls while the Why panel beside it closes at the
                // bottom of its column. `minHeight` is a floor, so a screen taller than the card
                // still grows past it and scrolls.
                GeometryReader { proxy in
                    ScrollView(.vertical) {
                        content()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, SetupSheetMetrics.inset(scale: scale))
                            .padding(.vertical, 18 * scale)
                            .frame(minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                why()
            }
            .frame(maxHeight: .infinity)
            Divider().opacity(0.5)
            footer
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 10) {
            if let title {
                Text(title)
                    .scaledFont(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                // The strip's capsule inset is cancelled on the leading edge so the first crumb's
                // text lands on the card's inset rather than 7pt inside it. The capsule keeps its
                // padding; only where the row starts moves.
                SetupCrumbStrip(screens: crumbs, current: current, tint: tint)
                    .padding(.leading, -SetupCrumbStrip.capsuleInset * scale)
            }
            Spacer(minLength: 8)
            TextSizeStepper(size: $fontSize, tint: tint)
            CloseButton { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .shortcutKeycap("esc")
                .help(ShortcutHint.tooltip("Not Now", "esc"))
                .accessibilityLabel("Not Now")
        }
        .padding(.horizontal, SetupSheetMetrics.inset(scale: scale))
        .padding(.vertical, 8 * scale)
    }

    // MARK: - Bottom

    private var footer: some View {
        SetupFooter(onBack: onBack, skipTitle: skipTitle, onSkip: onSkip,
                    secondaryTitle: secondaryTitle, onSecondary: onSecondary,
                    isSecondaryDisabled: isSecondaryDisabled,
                    primaryTitle: primaryTitle, onPrimary: onPrimary,
                    isPrimaryDisabled: isPrimaryDisabled)
    }
}

/// The bar under every screen: Back, the lock line, and at most three buttons (Skip, a secondary,
/// the primary).
///
/// Its own view so a fit test can measure it: `SetupSheetMetrics.contentHeight` subtracts
/// `footerHeight` from the card, so a footer taller than that constant makes every height the sheet
/// computes optimistic, and only laying one out shows it.
struct SetupFooter: View {
    var onBack: (() -> Void)?
    var skipTitle: String?
    var onSkip: (() -> Void)?
    var secondaryTitle: String? = nil
    var onSecondary: (() -> Void)? = nil
    var isSecondaryDisabled = false
    var primaryTitle: String
    var onPrimary: () -> Void
    var isPrimaryDisabled = false
    /// Forces the lock line on or off, for a test's reference render. Nil follows
    /// ``showsPrivacyLine``.
    var privacyLine: Bool? = nil

    @Environment(\.appFontScale) private var fontScale

    /// Whether the centred lock line is drawn: not beside a secondary button. Structure after a
    /// failed Save carries Back, "Continue Without Saving" and "Save and Start Reading", which
    /// reach under the centre, and the line, an overlay that reserves no width, would sit on top of
    /// them.
    var showsPrivacyLine: Bool { privacyLine ?? (secondaryTitle == nil) }

    private var scale: CGFloat { SetupSheetMetrics.chromeScale(fontScale) }

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button("Back", action: onBack)
                    .controlSize(.regular)
            }
            Spacer(minLength: 8)
            if let skipTitle, let onSkip {
                Button(skipTitle, action: onSkip)
            }
            if let secondaryTitle, let onSecondary {
                Button(secondaryTitle, action: onSecondary)
                    .disabled(isSecondaryDisabled)
            }
            Button(primaryTitle, action: onPrimary)
                .keyboardShortcut(.defaultAction)
                .accentedProminent()
                .shortcutKeycap("↩")
                .help(ShortcutHint.tooltip(primaryTitle, "↩"))
                .disabled(isPrimaryDisabled)
        }
        // Centred on the card, not between the buttons: two `Spacer`s would put it at the midpoint
        // of what is left over, sliding it between screens (no Back on Welcome, a long primary
        // title on Structure), and a line that moves reads as meaning something different on each.
        // An overlay reserves no width, so it can't push the buttons around;
        // `theFooterPiecesDoNotCollide` holds them apart.
        .overlay {
            if showsPrivacyLine {
                Label(SetupFlow.privacyFooter, systemImage: "lock")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Everything on this screen stays on this Mac")
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, SetupSheetMetrics.inset(scale: scale))
        .frame(height: SetupSheetMetrics.footerHeight * scale)
    }
}

extension SetupScreenCard where Why == EmptyView {
    /// A screen with no Why panel: Welcome, Structure and Summary, which are their own explanation.
    init(crumbs: [SetupFlow.Screen] = [],
         current: SetupFlow.Screen,
         title: String? = nil,
         fontSize: Binding<FontSize>,
         tint: Color,
         onBack: (() -> Void)? = nil,
         skipTitle: String? = nil,
         onSkip: (() -> Void)? = nil,
         primaryTitle: String,
         onPrimary: @escaping () -> Void,
         isPrimaryDisabled: Bool = false,
         onDismiss: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(crumbs: crumbs, current: current, title: title, fontSize: fontSize, tint: tint,
                  onBack: onBack, skipTitle: skipTitle, onSkip: onSkip,
                  primaryTitle: primaryTitle, onPrimary: onPrimary,
                  isPrimaryDisabled: isPrimaryDisabled, onDismiss: onDismiss,
                  content: content, why: { EmptyView() })
    }
}

// MARK: - The crumb strip

/// Where the user is, in one line.
///
/// One accessibility element, not eight: read crumb by crumb it is eight unlabelled words before
/// the question; read as "Step 3 of 8, You" it is the sentence a person would say.
struct SetupCrumbStrip: View {
    let screens: [SetupFlow.Screen]
    let current: SetupFlow.Screen
    let tint: Color

    /// How far the current crumb's capsule reaches past its text, at the default text size. Named
    /// because the top bar cancels exactly this much on the leading edge to put the text on the
    /// card's inset.
    static let capsuleInset: CGFloat = 7

    @Environment(\.appFontScale) private var fontScale

    private var scale: CGFloat { SetupSheetMetrics.chromeScale(fontScale) }

    /// The gaps between and inside the crumbs, at the current text size.
    ///
    /// The padding scales with the type. Eight crumbs carry about 186pt of fixed gaps and insets,
    /// so with fixed padding, smaller text in a card that shrinks with it would give the words'
    /// width to the padding and truncate the crumbs ("Locat…", "Count…") at the size chosen to fit
    /// more on screen.
    private var gap: CGFloat { 6 * scale }
    private var inset: CGFloat { Self.capsuleInset * scale }

    var body: some View {
        HStack(spacing: gap) {
            ForEach(screens, id: \.self) { screen in
                let isCurrent = screen == current
                HStack(spacing: 4 * scale) {
                    if let number = screen.number {
                        Text("\(number)")
                            .scaledFont(.caption2.weight(.semibold))
                            .monospacedDigit()
                            // Label colour, as the name beside it: the tint is the current step's
                            // wash, and a number in the tint on it would be a coloured word on its
                            // own wash.
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    Text(screen.displayName)
                        .scaledFont(.caption.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                }
                .padding(.horizontal, inset)
                .padding(.vertical, 2 * scale)
                .background {
                    if isCurrent { Capsule().fill(tint.opacity(0.14)) }
                }
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenPosition)
    }

    private var spokenPosition: String {
        guard let index = screens.firstIndex(of: current) else { return current.displayName }
        return "Step \(index + 1) of \(screens.count), \(current.displayName)"
    }
}

// MARK: - The Why panel

/// The column on the right of a question screen: why SyncCloud is asking, and what happens if the
/// user changes nothing.
///
/// Tinted with the accent rather than papered: the app has no paper colour, and inventing one would
/// put a surface in the window that nothing else shares. The accent at 9% over the card follows the
/// Accent setting and both appearance modes, so the panel reads as part of this app, and picking a
/// colour on the Appearance screen shows here at once.
struct SetupWhyPanel<Content: View>: View {
    var title = "Why SyncCloud asks"
    /// The closing line: what happens if the user changes nothing, or skips.
    var footnoteLead: String?
    var footnote: String?
    let hue: LiquidGlassHue
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appFontScale) private var fontScale

    private var scale: CGFloat { SetupSheetMetrics.chromeScale(fontScale) }

    /// How much of the accent the panel's ink carries.
    ///
    /// Lower in dark mode: the blend that reads as tinted body text on white reads as a coloured
    /// stripe on black, where the accent is the lighter of the two.
    static var inkBlend: Double { 0.55 }
    static var inkBlendDark: Double { 0.40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(ink)
            content()
            Spacer(minLength: 0)
            if let footnote {
                // A rule, because on a short screen the gap above it is tall. The footnote is
                // pinned to the column's foot on purpose (it answers the question above), but with
                // nothing between them the space reads as a hole rather than as the panel's
                // structure.
                Divider().opacity(0.35)
                VStack(alignment: .leading, spacing: 2) {
                    if let footnoteLead {
                        Text(footnoteLead)
                            .scaledFont(.caption2.weight(.semibold))
                            .foregroundStyle(ink)
                    }
                    Text(footnote)
                        .scaledFont(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // The panel's text column is its width less the card's inset, so the last word on this side
        // ends where the ✕ and the primary button do.
        .frame(width: SetupWhyMetrics.textWidth(scale: scale), alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, SetupSheetMetrics.inset(scale: scale))
        .padding(.vertical, 14 * scale)
        .background(hue.accentColor.opacity(SetupWhyMetrics.wash))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var ink: Color {
        let blend = colorScheme == .dark ? Self.inkBlendDark : Self.inkBlend
        return hue.accentColor.mix(with: colorScheme == .dark ? .white : .black, by: 1 - blend)
    }
}

enum SetupWhyMetrics {
    /// The whole column the panel occupies at the default text size, tint included. Wide enough for
    /// a diagram and two short paragraphs, and no wider: the question is the screen, and a Why
    /// panel that took a third of the card would be arguing with it.
    static let baseWidth: CGFloat = 250
    /// The column at a given text size.
    ///
    /// A share of the card, not a constant; see `SetupSheetMetrics.whyWidth(scale:)` for what a
    /// constant does to the panel's prose at large text sizes.
    static func width(scale: CGFloat) -> CGFloat {
        baseWidth * SetupSheetMetrics.chromeScale(scale)
    }
    /// What is left for the words once the card's inset is taken off both sides.
    static func textWidth(scale: CGFloat) -> CGFloat {
        width(scale: scale) - SetupSheetMetrics.inset(scale: scale) * 2
    }
    /// The accent's share of the panel's ground.
    static let wash: Double = 0.09
}

// MARK: - More options

/// The disclosure that holds what Settings already offers for this screen's subject.
///
/// Closed by default, and it says what is inside before it is opened. The subtitle makes it a
/// decision rather than a mystery: a chevron labelled only "More options" is a thing to click to
/// find out, which a setup screen should not need.
struct SetupMoreOptions<Content: View>: View {
    /// The disclosure's own name: "More options" for the Settings rows it usually holds; the
    /// suggestion screens name what is inside instead ("6 names SyncCloud found").
    var title = "More options"
    let subtitle: String
    /// Whether it starts open. People and Countries put the answer first and the candidates behind
    /// this, but on a first run there is no answer yet and the candidates are all there is, so a
    /// closed disclosure would leave the question with nothing under it. Open when nothing is
    /// chosen, closed once something is.
    var startsOpen = false
    @ViewBuilder var content: () -> Content

    @State private var isOpen: Bool?

    private var open: Bool { isOpen ?? startsOpen }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isOpen = !open
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title).scaledFont(.caption.weight(.medium))
                    Text("· \(subtitle)")
                        .scaledFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.inline))
            .accessibilityLabel(open ? "Hide \(title)" : "Show \(title), \(subtitle)")

            if open {
                VStack(alignment: .leading, spacing: 8, content: content)
                    .padding(.leading, 4)
            }
        }
    }
}

// MARK: - Small shared pieces

/// The sheet's vertical rhythm.
///
/// One number for every screen, so the gap between a heading and the first control doesn't change
/// as the user moves through a card that is deliberately the same size on all ten. This is the gap
/// between a screen's top-level blocks; `groupSpacing` is the gap inside one.
enum SetupRhythm {
    /// Between a screen's own blocks: heading, controls, note.
    static let blockSpacing: CGFloat = 16
    /// Inside one block: a label and the control it names.
    static let groupSpacing: CGFloat = 7
}

/// A screen's heading and its one line of explanation.
struct SetupHeading: View {
    let title: String
    let blurb: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(blurb)
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A quiet boxed note: the empty states and the refusals.
struct SetupNote: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage).scaledFont(.caption).foregroundStyle(.secondary)
            }
            Text(text)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Color.secondary.opacity(0.07)))
    }
}

/// The one chip the sheet draws: a name form, a country, a proposed person, a person on the list.
///
/// One view so every screen's chips share height, ground and glyph rules: they are one idea (this
/// thing is on the list, or it isn't), and differences between screens would be noise. The leading
/// glyph is the one thing that varies, for a reason: a tick says the chip is a switch, a `+` that
/// it is a one-way add onto the list below.
struct SetupChip<Trailing: View>: View {
    /// What the glyph says the chip does.
    enum Mark {
        /// A switch. Ticked or not.
        case tick(Bool)
        /// A one-way add: pressing it puts the name on the list below.
        case add
        /// Already on the list: a statement, not a control.
        case person
    }

    let mark: Mark
    let title: String
    var detail: String?
    /// Whether the chip's ground is the heavier one. The tick's own state, where there is one.
    var isFilled = false
    /// The sheet's accent, for a lit tick and the `+`. Handed in, because a `.tint` nothing set is
    /// the system's.
    var accent: Color = LiquidGlassHue.stored().accentColor
    @ViewBuilder var trailing: () -> Trailing

    /// The chip's metrics, shared so a new caller can't quietly pick its own.
    static var horizontalInset: CGFloat { 9 }
    static var verticalInset: CGFloat { 4 }

    var body: some View {
        HStack(spacing: 5) {
            glyph
            Text(title).scaledFont(.caption.weight(.medium))
            if let detail {
                Text(detail)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            trailing()
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, Self.verticalInset)
        .background(Capsule().fill(Color.secondary.opacity(isFilled ? 0.16 : 0.08)))
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var glyph: some View {
        switch mark {
        case .tick(let on):
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .scaledFont(.caption)
                .foregroundStyle(on ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
        case .add:
            Image(systemName: "plus.circle")
                .scaledFont(.caption)
                .foregroundStyle(accent)
        case .person:
            Image(systemName: "person.crop.circle")
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

extension SetupChip where Trailing == EmptyView {
    init(mark: Mark, title: String, detail: String? = nil, isFilled: Bool = false,
         accent: Color = LiquidGlassHue.stored().accentColor) {
        self.init(mark: mark, title: title, detail: detail, isFilled: isFilled, accent: accent,
                  trailing: { EmptyView() })
    }
}

/// A wrapping row of removable chips.
struct FlowChips: View {
    let items: [String]
    var subtitle: (String) -> String? = { _ in nil }
    /// What a chip's ✕ does. nil draws no ✕: a list that can't be changed offers no way to.
    let onRemove: ((String) -> Void)?

    var body: some View {
        if items.isEmpty {
            // Nothing. The field below is the whole affordance, and "None yet" above it would read
            // as a warning about an empty list rather than an ordinary starting point.
            EmptyView()
        } else {
            WrapLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    if let onRemove {
                        removableChip(item, onRemove: onRemove)
                    } else {
                        SetupChip(mark: .person, title: item, detail: subtitle(item), isFilled: true)
                    }
                }
            }
        }
    }

    private func removableChip(_ item: String, onRemove: @escaping (String) -> Void) -> some View {
        SetupChip(mark: .person, title: item, detail: subtitle(item), isFilled: true) {
            Button {
                onRemove(item)
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(.caption2)
                    // `hoverInk` rather than a flat `.foregroundStyle(.secondary)`: the style can't
                    // lift a label's ink from outside, because the label's own modifier is applied
                    // inside it.
                    .hoverInk()
                    // Room for the wash, cancelled below.
                    .padding(3)
            }
            .buttonStyle(.hoverAffordance(.inline))
            .padding(-3)
            .help("Remove \(item) from the list")
            .accessibilityLabel("Remove \(item)")
        }
    }
}

/// Lays subviews out left to right, wrapping onto a new line when the proposed width runs out.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}


/// How much the card's height actually grew, published by the sheet so the one element sized in
/// points, Structure's tree box, can follow the card rather than the type.
///
/// See ``SetupSheetMetrics/cardScale(availableSize:scale:)`` for why the two differ.
private struct SetupCardScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var setupCardScale: CGFloat {
        get { self[SetupCardScaleKey.self] }
        set { self[SetupCardScaleKey.self] = newValue }
    }
}
