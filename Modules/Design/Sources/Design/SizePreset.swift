import SwiftUI

/// A named pairing of `FontSize` and `ListDensity`: one click that answers "how much do you want on
/// screen?" instead of asking it twice.
///
/// A shortcut over the two orthogonal settings, never a replacement. "Large text, compact rows" is
/// a real combination and deliberately not on this list; the Settings panel keeps both controls
/// underneath, and ``matching(fontSize:density:)`` answers nil for anything off the list, so the
/// row shows nothing selected.
///
/// Nothing here is persisted. `FontSize.defaultsKey` and `ListDensity.defaultsKey` stay the two
/// sources of truth: a preset is read back from them and writes both when chosen. A third stored
/// key could disagree with the two it summarises.
public struct SizePreset: Hashable, Identifiable, Sendable {
    public let fontSize: FontSize
    public let density: ListDensity

    public init(fontSize: FontSize, density: ListDensity) {
        self.fontSize = fontSize
        self.density = density
    }

    /// The presets, in the one order that reads as a row: every step shows less and reads bigger.
    /// That is why five can sit in a strip without labels explaining it, and why the density flip
    /// sits between the second and third, the only place neither half of the pair moves backwards.
    public static let all: [SizePreset] = [
        SizePreset(fontSize: .small, density: .compact),
        SizePreset(fontSize: .medium, density: .compact),
        SizePreset(fontSize: .medium, density: .comfortable),
        SizePreset(fontSize: .large, density: .comfortable),
        SizePreset(fontSize: .extraLarge, density: .comfortable),
    ]

    /// The preset a fresh install sits on, and the one the Settings caption calls "Default".
    /// `theDefaultPresetIsTheShippingLook` pins it against the two settings' own defaults, so a
    /// reordered list fails instead of quietly moving what "Default" means.
    public static let `default` = SizePreset(fontSize: .medium, density: .comfortable)

    public var id: String { "\(fontSize.percent)-\(density.rawValue)" }

    /// The preset matching a pair of live settings, or nil when the user has moved off the list.
    public static func matching(fontSize: FontSize, density: ListDensity) -> SizePreset? {
        all.first { $0.fontSize == fontSize && $0.density == density }
    }

    /// What row spacing this preset sets, in words. The second line of a `.named` tile, where it
    /// tells the two 100% tiles apart; a `.specimen` tile draws the result instead (see
    /// `SizePresetRow`). Both styles say it in their accessibility label and tooltip.
    public var densityName: String { density.displayName }

    /// The caption under the whole row, describing where the two settings stand. Answers for any
    /// pair, because the fine controls can leave the panel where no preset covers, and "Custom" is
    /// the honest readout there.
    public static func caption(fontSize: FontSize, density: ListDensity) -> String {
        let pair = "\(fontSize.percent)% text, \(density.displayName.lowercased()) rows"
        guard let preset = matching(fontSize: fontSize, density: density) else {
            return "Custom — \(pair)."
        }
        return preset == .default ? "Default — \(pair)." : "\(pair.prefix(1).uppercased())\(pair.dropFirst())."
    }
}
