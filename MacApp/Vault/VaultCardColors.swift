import AppKit
import Design
import SwiftUI
import Sync

/// The Vault's card colors as the panel draws them (``VaultTint``): one hue each, in a shade for
/// light and a lighter one for dark, so a symbol in the color reads on either ground.
enum VaultTintPalette {
    /// The hue, in degrees round the color wheel.
    static func hue(_ tint: VaultTint) -> Double {
        switch tint {
        case .blue: return 220
        case .teal: return 188
        case .green: return 150
        case .olive: return 85
        case .clay: return 28
        case .rose: return 345
        case .plum: return 300
        case .violet: return 268
        }
    }

    /// How light the shade is, of 1: darker on a light ground, lighter on a dark one.
    static func lightness(dark: Bool) -> Double { dark ? 0.68 : 0.42 }
    static let saturation = 0.5

    /// How strong the wash behind a card's title is. Soft: the title over it stays in the text
    /// color.
    static func wash(dark: Bool) -> Double { dark ? 0.22 : 0.14 }

    /// How strong the wash under a card's rows is: the whole card is in its color, the title bar
    /// more than the rows, so the bar still reads as the card's head and the rows' words, pills
    /// and the lifted chosen row keep their contrast.
    static func bodyWash(dark: Bool) -> Double { dark ? 0.11 : 0.07 }

    /// The shade's sRGB parts, from its hue, ``saturation`` and ``lightness(dark:)``.
    static func rgb(_ tint: VaultTint, dark: Bool) -> (red: Double, green: Double, blue: Double) {
        let (h, s, l) = (hue(tint) / 360, saturation, lightness(dark: dark))
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func part(_ t: Double) -> Double {
            let t = t < 0 ? t + 1 : t > 1 ? t - 1 : t
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (part(h + 1.0 / 3), part(h), part(h - 1.0 / 3))
    }

    /// The shade for whichever appearance it is drawn in, one per tint, made once: a dynamic
    /// color resolves at each draw, so the same one serves both appearances.
    static func nsColor(_ tint: VaultTint) -> NSColor { colors[tint]! }

    static let swiftUIColors = Dictionary(uniqueKeysWithValues: VaultTint.allCases.map { ($0, Color(nsColor: colors[$0]!)) })

    private static let colors = Dictionary(uniqueKeysWithValues: VaultTint.allCases.map { ($0, makeColor($0)) })

    private static func makeColor(_ tint: VaultTint) -> NSColor {
        NSColor(name: nil) { appearance in
            let parts = rgb(tint, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return NSColor(srgbRed: parts.red, green: parts.green, blue: parts.blue, alpha: 1)
        }
    }

    /// A small round swatch for a menu line: a menu draws an item's image, never a SwiftUI shape.
    /// Nil is "no color", an empty ring. A new image per draw, on purpose: SwiftUI keeps an
    /// `Image(nsImage:)` it has drawn and never draws a held one again when the appearance
    /// changes, so a swatch made once would keep the other appearance's shade (VT78).
    static func swatch(_ tint: VaultTint?) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if let tint {
                nsColor(tint).setFill()
                circle.fill()
            } else {
                NSColor.tertiaryLabelColor.setStroke()
                circle.lineWidth = 1
                circle.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension VaultTint {
    var color: Color { VaultTintPalette.swiftUIColors[self]! }
}

// MARK: - A card's title bar

/// A card's title bar: the chevron that folds it, its kind's symbol, its name and how many IDs it
/// holds; folded, what is inside in one line.
///
/// With a tint the symbol takes the card's color and the bar a soft wash of it, edge to edge, so
/// a kind is found by its color. Nothing else on the card is colored: a row's selection stays in
/// the window's hue, and the title stays in the text color. Without `washes` (Increase Contrast
/// is on), the wash is left out and the symbol alone carries the color.
struct VaultCardHeader: View {
    let title: String
    let symbol: String
    let count: Int
    let isFolded: Bool
    let foldedSummary: String
    /// The card's color; nil draws the symbol in `accent`, the window's hue, with no wash.
    let tint: VaultTint?
    let accent: Color
    /// Whether a tint also washes the bar. The panel passes false under Increase Contrast.
    var washes = true

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ink = tint?.color ?? accent
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .scaledFont(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isFolded ? 0 : 90))
                .frame(width: 10)
            Image(systemName: symbol)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(ink)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(ink.opacity(tint == nil ? 0.14 : 0.2)))
            Text(title)
                .scaledFont(.subheadline.weight(.semibold))
            Text(count.formatted())
                .scaledFont(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if isFolded {
                Text(foldedSummary)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        // Folded, the bar is the whole card: it takes the card's foot, so the wash reaches it.
        .padding(.bottom, isFolded ? 10 : 6)
        .background {
            if let tint, washes {
                tint.color.opacity(VaultTintPalette.wash(dark: scheme == .dark))
            }
        }
        // A hairline closes the bar where the rows begin, so a selected first row never reads as
        // more of it.
        .overlay(alignment: .bottom) {
            if let tint, !isFolded, washes {
                tint.color.opacity(0.3).frame(height: 0.5)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - A card's rows

/// The ground under a card's rows: a lighter wash of the card's color than its title bar's, or
/// nothing for a card with no color.
struct VaultCardBodyWash: View {
    let tint: VaultTint?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let tint {
            tint.color.opacity(VaultTintPalette.bodyWash(dark: scheme == .dark))
        }
    }
}

/// The chosen row's ground, never a fill in the window's hue: on a card washed in its own color
/// that would be a second color beside the first.
///
/// On a washed card it is a light lift off the card, as a chosen segment is lifted off its
/// control: near white, with a soft shadow. On plain ground (a card with no color, the List and
/// People layouts, Increase Contrast) white would not show, so it is a quiet grey instead.
struct VaultRowLift: ViewModifier {
    let isChosen: Bool
    /// Whether the row lies on a card's wash.
    let onColor: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// The lift's fill on a washed card: near white on a light one, a lighter step on a dark one.
    static func lift(dark: Bool) -> Color { Color.white.opacity(dark ? 0.16 : 0.92) }
    /// The fill on plain ground: the text color, faintly.
    static func plain(dark: Bool) -> Color { Color.primary.opacity(dark ? 0.13 : 0.075) }

    func body(content: Content) -> some View {
        content.background {
            if isChosen {
                let shape = RoundedRectangle(cornerRadius: Radius.chip)
                let dark = scheme == .dark
                if onColor {
                    shape.fill(Self.lift(dark: dark))
                        .shadow(color: .black.opacity(dark ? 0.35 : 0.16), radius: 1.5, y: 0.5)
                        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                } else {
                    shape.fill(Self.plain(dark: dark))
                        .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0)))
                }
            }
        }
    }
}

// MARK: - A card title's menu

/// A card title's right-click menu: fold it, fold them all, and its color.
///
/// Flat on purpose. A submenu SwiftUI builds is shut whenever the Vault's rows change under the
/// open menu, and Refresh changes them as the Vault opens: with the colors in a Color submenu, it
/// closed before one could be picked (2026-11-20). Color opens ``VaultColorPopover`` instead.
/// Plain values, so it is hosted and read in a test without the panel.
struct VaultCardTitleMenu: View {
    let isFolded: Bool
    let allFolded: Bool
    let toggle: () -> Void
    let toggleAll: () -> Void
    /// Nil where cards have no color (Other Finds).
    let color: (() -> Void)?

    var body: some View {
        Button(isFolded ? "Expand" : "Collapse", action: toggle)
        Button(allFolded ? "Expand All Cards" : "Collapse All Cards", action: toggleAll)
        if let color {
            Divider()
            Button("Color…", action: color)
        }
    }
}

// MARK: - Choosing a color

/// The Color choice for one card, opened from its title's menu and beside Kind in an ID's details.
///
/// Two rows of the same colors, each under what it colors: this card alone, and its whole group.
/// A card follows its group until it is given a color of its own, so the first row opens on
/// "Same as Group" and the second shows the color the card is drawn in. It stays open while
/// colors are tried: each pick shows on the cards behind it at once.
struct VaultColorPopover: View {
    let choice: VaultColorChoice
    /// The window's hue, for the chosen "Same as Group".
    let accent: Color
    let pickCard: (VaultCardColor?) -> Void
    let pickGroup: (VaultCardColor) -> Void
    let turnOn: () -> Void

    static let width: CGFloat = 310
    /// A swatch's diameter and the gap to the next: nine fit the width.
    static let swatch: CGFloat = 20
    static let gap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if choice.isOn {
                VStack(alignment: .leading, spacing: 8) {
                    heading("This Card", choice.title)
                    if choice.group != nil { followsGroup }
                    swatches(chosen: choice.own, of: "\(choice.title) card") { pickCard($0) }
                }
                if let name = choice.groupName, let color = choice.groupColor {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        heading("Its Group", name)
                        swatches(chosen: color, of: "group \(name)", pick: pickGroup)
                        Text(choice.reach)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Card colors are off.")
                    .scaledFont(.callout)
                Button("Turn On Card Colors", action: turnOn)
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
    }

    private func heading(_ what: String, _ name: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(what)
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(name)
                .scaledFont(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }

    /// The card's first choice: no color of its own. Chosen, no swatch in its row is ringed.
    private var followsGroup: some View {
        let chosen = choice.own == nil
        return Button {
            pickCard(nil)
        } label: {
            HStack(spacing: 5) {
                if chosen {
                    Image(systemName: "checkmark")
                        .scaledFont(.caption2.weight(.bold))
                }
                Text("Same as Group")
                    .scaledFont(.callout)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(chosen ? accent.opacity(0.16) : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(chosen ? accent.opacity(0.7) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("No color of its own: the card takes its group’s")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func swatches(chosen: VaultCardColor?, of what: String, pick: @escaping (VaultCardColor) -> Void) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(VaultTint.allCases, id: \.self) { tint in
                swatch(.tint(tint), chosen: chosen == .tint(tint), of: what, pick: pick)
            }
            swatch(.plain, chosen: chosen == .plain, of: what, pick: pick)
        }
    }

    private func swatch(_ color: VaultCardColor, chosen: Bool, of what: String, pick: @escaping (VaultCardColor) -> Void) -> some View {
        let name: String = { if case .tint(let tint) = color { return tint.title } else { return "No Color" } }()
        return Button {
            pick(color)
        } label: {
            ZStack {
                if case .tint(let tint) = color {
                    Circle().fill(tint.color)
                } else {
                    // No color: an empty ring with a stroke through it.
                    Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1)
                    Rectangle().fill(Color.secondary.opacity(0.7)).frame(width: Self.swatch - 4, height: 1).rotationEffect(.degrees(-45))
                }
            }
            .frame(width: Self.swatch, height: Self.swatch)
            // The chosen one: a ring round it, in the text color so it reads over any shade.
            .overlay(Circle().strokeBorder(Color.primary.opacity(chosen ? 0.85 : 0), lineWidth: 2).padding(-4))
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("\(name), color of the \(what)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A color popup for Customize Groups: the tints with their swatches, and none; with
/// `followsGroup`, also "Group’s" for a card that has no color of its own.
struct VaultColorPicker: View {
    /// The choice: a ``VaultCardColor/key``, or "group".
    @Binding var key: String
    var followsGroup = false
    let accessibilityLabel: String

    static let groupKey = "group"

    var body: some View {
        Picker(accessibilityLabel, selection: $key) {
            if followsGroup {
                Text("Group’s").tag(Self.groupKey)
                Divider()
            }
            ForEach(VaultTint.allCases, id: \.self) { tint in
                Label {
                    Text(tint.title)
                } icon: {
                    Image(nsImage: VaultTintPalette.swatch(tint))
                }
                .tag(tint.rawValue)
            }
            Divider()
            Text("No Color").tag(VaultCardColor.plain.key)
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Where the Color choice hangs from: a card's title, or Color beside Kind in an ID's details.
enum VaultColorAnchor: Equatable {
    case title(VaultCardID)
    case detail(VaultCardID)
}
