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
    /// color, and a selected row under it, drawn in the window's hue, is not taken for more of it.
    static func wash(dark: Bool) -> Double { dark ? 0.22 : 0.14 }

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

    /// The shade for whichever appearance it is drawn in.
    static func nsColor(_ tint: VaultTint) -> NSColor {
        NSColor(name: nil) { appearance in
            let parts = rgb(tint, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return NSColor(srgbRed: parts.red, green: parts.green, blue: parts.blue, alpha: 1)
        }
    }

    /// A small round swatch for a menu line: a menu draws an item's image, never a SwiftUI shape.
    /// Nil is "no color", an empty ring.
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
    var color: Color { Color(nsColor: VaultTintPalette.nsColor(self)) }
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

// MARK: - Choosing a card's color

/// The Color choices for one card: its group's color, one of its own, or none. Used in the menu
/// on a card's title and beside Kind in the chosen ID's details; plain values, so it is hosted
/// and read in a test without the panel.
struct VaultColorMenu: View {
    /// The color chosen for this card alone; nil follows its group.
    let own: VaultCardColor?
    let groupName: String
    /// Card colors as a whole (Customize Groups).
    let isOn: Bool
    let pick: (VaultCardColor?) -> Void
    let turnOn: () -> Void

    var body: some View {
        if isOn {
            Toggle("Same as \(groupName)", isOn: chosen(nil))
            Divider()
            ForEach(VaultTint.allCases, id: \.self) { tint in
                Toggle(isOn: chosen(.tint(tint))) {
                    Label {
                        Text(tint.title)
                    } icon: {
                        Image(nsImage: VaultTintPalette.swatch(tint))
                    }
                }
            }
            Divider()
            Toggle("No Color", isOn: chosen(.plain))
        } else {
            Text("Card Colors Are Off")
            Button("Turn On Card Colors", action: turnOn)
        }
    }

    /// A tick on the current choice; choosing a line sets it, and choosing the ticked one keeps it.
    private func chosen(_ color: VaultCardColor?) -> Binding<Bool> {
        Binding(get: { own == color }, set: { _ in pick(color) })
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
