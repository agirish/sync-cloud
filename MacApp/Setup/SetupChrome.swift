import Design
import SwiftUI

/// The frame every setup screen is drawn in: a crumb strip and the text-size control above, the
/// content and its Why panel in the middle, the lock line and the buttons below.
///
/// **One card, ten screens.** The chrome is identical on every screen so that only the question
/// changes as the user moves — the form this replaces changed the shape of its card between steps,
/// and a container that resizes under a form draws the eye to the container.
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
    var primaryTitle: String
    var onPrimary: () -> Void
    /// Set when the screen's primary action cannot be taken yet — Learn with no folder chosen, or
    /// Save while the last press is still writing.
    var isPrimaryDisabled = false
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var why: () -> Why

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appFontScale) private var fontScale

    /// The card's own geometry moves by `chromeScale`, not by the text scale — see its doc comment.
    private var scale: CGFloat { SetupSheetMetrics.chromeScale(fontScale) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 0) {
                // **The content column scrolls, and the chrome does not.** The card is one fixed
                // height for every screen — that is the whole point of it — but two of the screens
                // grow with the user's own data: Locations draws a row per location, and People a
                // chip per name. Without a scroll view a VStack taller than its frame is not
                // clipped at the bottom, it is *centred and clipped at both ends*, so the first
                // thing to go is the crumb strip at the top and the primary button at the bottom —
                // the two things a person needs to get out of the screen. Nine locations at 110%
                // text is enough to do it.
                //
                // `.basedOnSize` so a screen that fits does not rubber-band: bounce on a card that
                // has nothing to scroll reads as a broken window.
                //
                // **`minHeight` is what makes the screens' own `Spacer`s work.** A `ScrollView`
                // proposes `nil` height to its content, so a `VStack` inside one is exactly as tall
                // as its subviews and a `Spacer(minLength: 0)` in it gets nothing to expand into —
                // every screen here ends in one, and adding the scroll view quietly made all ten
                // inert. What that costs is composition: the closing line each screen means to sit
                // at the foot of the card rode up under the controls instead, while the Why panel
                // beside it went on closing at the bottom of *its* column, so the two halves of one
                // card disagreed about where the floor was.
                //
                // Giving the content at least the column's own height restores it, and costs the
                // overflow case nothing: `minHeight` is a floor, so a screen taller than the card
                // still grows past it and still scrolls.
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
                // The strip's own capsule inset is cancelled on the leading edge so the first
                // crumb's *text* lands on the card's inset rather than 7pt inside it. The capsule
                // still has its padding; what moves is where the row starts.
                SetupCrumbStrip(screens: crumbs, current: current, tint: tint)
                    .padding(.leading, -SetupCrumbStrip.capsuleInset * scale)
            }
            Spacer(minLength: 8)
            TextSizeStepper(size: $fontSize, tint: tint)
            CloseButton { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .shortcutKeycap("esc")
                .help(ShortcutHint.tooltip("Not now", "esc"))
                .accessibilityLabel("Not now")
        }
        .padding(.horizontal, SetupSheetMetrics.inset(scale: scale))
        .padding(.vertical, 8 * scale)
    }

    // MARK: - Bottom

    private var footer: some View {
        SetupFooter(onBack: onBack, skipTitle: skipTitle, onSkip: onSkip,
                    primaryTitle: primaryTitle, onPrimary: onPrimary,
                    isPrimaryDisabled: isPrimaryDisabled)
    }
}

/// The bar under every screen: Back, the lock line, and at most two buttons.
///
/// **Its own view so a fit test can measure it.** `SetupSheetMetrics.contentHeight` subtracts
/// `footerHeight` from the card, so a real footer taller than that constant makes every height the
/// sheet computes optimistic by the difference — and the only way to know is to lay one out.
struct SetupFooter: View {
    var onBack: (() -> Void)?
    var skipTitle: String?
    var onSkip: (() -> Void)?
    var primaryTitle: String
    var onPrimary: () -> Void
    var isPrimaryDisabled = false

    @Environment(\.appFontScale) private var fontScale

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
            Button(primaryTitle, action: onPrimary)
                .keyboardShortcut(.defaultAction)
                .shortcutKeycap("return")
                .disabled(isPrimaryDisabled)
        }
        // **Centred on the card, not between the buttons.** Two `Spacer`s put it at the midpoint of
        // whatever was left over, so it slid left on Welcome (no Back) and right on Structure (a
        // long primary title) — a line that moves between screens reads as a line that means
        // something different on each. An overlay reserves no width, so it cannot push the buttons
        // around; `theFooterPiecesDoNotCollide` is what holds them apart.
        .overlay {
            Label(SetupFlow.privacyFooter, systemImage: "lock")
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Everything on this screen stays on this Mac")
                .allowsHitTesting(false)
        }
        .padding(.horizontal, SetupSheetMetrics.inset(scale: scale))
        .frame(height: SetupSheetMetrics.footerHeight * scale)
    }
}

extension SetupScreenCard where Why == EmptyView {
    /// A screen with no Why panel — Welcome, Structure and Summary, which are their own explanation.
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
/// **One accessibility element, not eight.** Read out screen by screen it is eight unlabelled
/// words before the question; read as "Step 3 of 8, You" it is the sentence a person would say.
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
    /// **This is why the strip truncated when the text got SMALLER.** Eight crumbs carry seven
    /// gaps, sixteen capsule insets and eight number-to-name gaps — about 186pt of fixed chrome
    /// against text that shrank to 90% inside a card that shrank with it, so the words gave up the
    /// width the padding kept. Rendered at 90% the strip read "1 Locat… 5 Count… Workspac…
    /// Appeara…": four of the eight steps unreadable, at the size chosen by someone fitting more
    /// on screen. The padding is part of the type here, so it moves with it.
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
                            .foregroundStyle(isCurrent ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
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
/// **Tinted with the accent rather than papered.** The app has no paper colour and inventing one
/// for this panel would put a surface in the window that nothing else shares. The accent at 9% over
/// the card follows the Accent setting and both appearance modes, so the panel is recognisably part
/// of this app rather than a note stuck onto it — and picking a colour on the Appearance screen
/// shows here at once.
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
    /// Lower in dark mode: the same blend that reads as tinted body text on white reads as a
    /// coloured stripe on black, because the accent is the lighter of the two there.
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
                // **A rule, because the gap above it is 400pt on a short screen.** The footnote is
                // pinned to the foot of the column on purpose — it is the answer to the question
                // above it — but with nothing between them the space reads as a hole rather than as
                // the panel's own structure.
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
        // The panel's own text column is what is left of its width after the card's inset, so the
        // last word on this side of the card ends where the ✕ and the primary button do.
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
    /// **A share of the card, not a constant** — see `SetupSheetMetrics.whyWidth(scale:)` for what
    /// the constant did to the panel's own prose at 135%.
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
/// **Closed by default, and it says what is inside before it is opened.** The subtitle is what
/// makes it a decision rather than a mystery: a chevron labelled only "More options" is a thing to
/// click to find out, which is exactly what a setup screen should not need.
struct SetupMoreOptions<Content: View>: View {
    /// The disclosure's own name. "More options" for the Settings rows it usually holds; the
    /// suggestion screens name what is inside instead — "6 names SyncCloud found".
    var title = "More options"
    let subtitle: String
    /// Whether it starts open.
    ///
    /// **The suggestion screens need this, and it is not a decoration.** People and Countries put
    /// the answer first and the candidates behind this — but on a first run there is no answer yet
    /// and the candidates are the only thing on the screen, so a disclosure closed by default would
    /// leave the question with nothing under it. Open when there is nothing chosen, closed once
    /// there is.
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
/// **One number, because the screens had six.** They were written over a week and each picked its
/// own `VStack(spacing:)` — 12 on three screens, 14 on four, and the blocks inside them anywhere
/// from 4 to 8 — so moving between screens the gap between a heading and the first control changed
/// under a card that is deliberately the same size on all ten. The value is the gap between a
/// screen's top-level blocks; `groupSpacing` is the gap inside one.
enum SetupRhythm {
    /// Between a screen's own blocks — heading, controls, note.
    static let blockSpacing: CGFloat = 16
    /// Inside one block — a label and the control it names.
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

/// A quiet boxed note — the empty states and the refusals.
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

/// The one chip the sheet draws — a name form, a country, a proposed person, a person on the list.
///
/// **Extracted because four screens had drawn four of them.** They agreed on nothing that mattered
/// and disagreed on everything that shows: the roster's chips sat 3pt tall against everybody else's
/// 4, on a ground at 14% against 8% and 16%, and the proposed-person chip alone carried a `+` where
/// the two beside it carried a tick. Read down the sheet that is four different controls for one
/// idea — *this thing is on the list, or it is not* — and the differences are all noise, because
/// none of them was a decision anyone made.
///
/// The leading glyph is the one thing that still varies, and it varies for a reason: a tick says
/// the chip is a switch, a `+` says the chip is a one-way add onto the list below it.
struct SetupChip<Trailing: View>: View {
    /// What the glyph says the chip does.
    enum Mark {
        /// A switch. Ticked or not.
        case tick(Bool)
        /// A one-way add: pressing it puts the name on the list below.
        case add
        /// Already on the list — a statement, not a control.
        case person
    }

    let mark: Mark
    let title: String
    var detail: String?
    /// Whether the chip's ground is the heavier one. The tick's own state, where there is one.
    var isFilled = false
    @ViewBuilder var trailing: () -> Trailing

    /// The chip's metrics, shared so a fifth caller cannot quietly pick its own.
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
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        case .add:
            Image(systemName: "plus.circle")
                .scaledFont(.caption)
                .foregroundStyle(.tint)
        case .person:
            Image(systemName: "person.crop.circle")
                .scaledFont(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

extension SetupChip where Trailing == EmptyView {
    init(mark: Mark, title: String, detail: String? = nil, isFilled: Bool = false) {
        self.init(mark: mark, title: title, detail: detail, isFilled: isFilled,
                  trailing: { EmptyView() })
    }
}

/// A wrapping row of removable chips.
struct FlowChips: View {
    let items: [String]
    var subtitle: (String) -> String? = { _ in nil }
    let onRemove: (String) -> Void

    var body: some View {
        if items.isEmpty {
            // Nothing. The field below is the whole affordance, and "None yet" floating above it
            // read as a warning about an empty list rather than as an ordinary starting point.
            EmptyView()
        } else {
            WrapLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    SetupChip(mark: .person, title: item, detail: subtitle(item), isFilled: true) {
                        Button {
                            onRemove(item)
                        } label: {
                            Image(systemName: "xmark")
                                .scaledFont(.caption2)
                                // `hoverInk` rather than a flat `.foregroundStyle(.secondary)`:
                                // the style cannot lift a label's ink from outside, because the
                                // label's own modifier is applied inside it.
                                .hoverInk()
                                // Room for the wash, cancelled below.
                                .padding(3)
                        }
                        .buttonStyle(.hoverAffordance(.inline))
                        .padding(-3)
                        .accessibilityLabel("Remove \(item)")
                    }
                }
            }
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
/// points — Structure's tree box — can follow the card rather than the type.
///
/// See ``SetupSheetMetrics/cardScale(availableSize:scale:)`` for why the two differ.
private struct SetupCardScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var setupCardScale: CGFloat {
        get { self[SetupCardScaleKey.self] }
        set { self[SetupCardScaleKey.self] = newValue }
    }
}
