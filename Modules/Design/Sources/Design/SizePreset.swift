import SwiftUI

/// A named pairing of `FontSize` and `ListDensity` — one click that answers "how much do you want
/// on screen?" instead of asking it twice.
///
/// The two settings are orthogonal and stay that way; this is a **shortcut over them, never a
/// replacement for them**. "Large text, compact rows" is a real combination — it is what somebody
/// with a 5K display and a four-thousand-file duplicate set actually wants — and it is deliberately
/// not on this list. The Settings panel keeps both controls underneath, so a preset is a starting
/// point rather than a cage; ``matching(fontSize:density:)`` answers nil for anything off the list
/// and the row simply shows nothing selected.
///
/// **Nothing here is persisted.** `FontSize.defaultsKey` and `ListDensity.defaultsKey` remain the
/// two sources of truth: a preset is read back out of them to decide which one is lit, and writes
/// both when chosen. A third stored key would be a value that could disagree with the two it
/// summarises, and the first thing to disagree with it would be the fine controls sitting directly
/// below.
public struct SizePreset: Hashable, Identifiable, Sendable {
    public let fontSize: FontSize
    public let density: ListDensity

    public init(fontSize: FontSize, density: ListDensity) {
        self.fontSize = fontSize
        self.density = density
    }

    /// The presets, in the one order that makes them legible as a row: **every step shows less
    /// and reads bigger.**
    ///
    /// That monotonicity is the whole reason five of them can sit in a strip without labels
    /// explaining the strip. It also fixes where the density flip goes — between the second and
    /// third, the only position where neither half of the pair ever moves backwards. Put it
    /// anywhere else and the row stops being a ladder and becomes a menu, which is what the
    /// five-dot rail this replaced actually was.
    public static let all: [SizePreset] = [
        SizePreset(fontSize: .small, density: .compact),
        SizePreset(fontSize: .medium, density: .compact),
        SizePreset(fontSize: .medium, density: .comfortable),
        SizePreset(fontSize: .large, density: .comfortable),
        SizePreset(fontSize: .extraLarge, density: .comfortable),
    ]

    /// The preset a fresh install sits on, and the one the Settings caption calls "Default".
    /// Derived rather than written down twice — `theDefaultPresetIsTheShippingLook` pins it
    /// against the two settings' own defaults, so a preset list reordered without thinking fails
    /// instead of quietly moving what "Default" means.
    public static let `default` = SizePreset(fontSize: .medium, density: .comfortable)

    public var id: String { "\(fontSize.percent)-\(density.rawValue)" }

    /// The preset matching a pair of live settings, or nil when the user has moved off the list.
    public static func matching(fontSize: FontSize, density: ListDensity) -> SizePreset? {
        all.first { $0.fontSize == fontSize && $0.density == density }
    }

    /// What row spacing this preset sets, in words.
    ///
    /// **Not printed on the tile** — the tile draws a specimen instead, because the words do not
    /// fit the narrowest settings column and mean nothing on the setup form (see `SizePresetRow`).
    /// This is what the tile's accessibility label and tooltip say, which is where a name is worth
    /// more than a picture.
    public var densityName: String { density.displayName }

    /// The caption under the whole row, describing where the two settings currently stand.
    ///
    /// Answers for *any* pair, not just the presets, because the fine controls below can put the
    /// panel in a state no preset covers — and "Custom" is the honest readout there. A row that
    /// lit its nearest neighbour instead would be claiming a setting the user did not choose.
    public static func caption(fontSize: FontSize, density: ListDensity) -> String {
        let pair = "\(fontSize.percent)% text, \(density.displayName.lowercased()) rows"
        guard let preset = matching(fontSize: fontSize, density: density) else {
            return "Custom — \(pair)."
        }
        return preset == .default ? "Default — \(pair)." : "\(pair.prefix(1).uppercased())\(pair.dropFirst())."
    }
}
