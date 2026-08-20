import Testing
import SwiftUI
@testable import Design

/// `SizePreset` is a shortcut over two settings that stay the sources of truth, so what these pin
/// is mostly what it must NOT do: invent a third stored value, claim a pairing the user did not
/// choose, or reorder itself into something that stops reading as a ladder.
@Suite struct SizePresetTests {

    @Test func theDefaultPresetIsTheShippingLook() {
        // Derived, not restated: if the two settings' own defaults move, or the list is reordered
        // so that another entry becomes the identity pairing, this fails rather than quietly
        // changing what the Settings caption calls "Default".
        #expect(SizePreset.default.fontSize == FontSize.medium)
        #expect(SizePreset.default.density == ListDensity.comfortable)
        #expect(SizePreset.medium.scale == 1, "the default preset must be the unscaled rendering")
        #expect(SizePreset.all.contains(SizePreset.default),
                "the default pairing is not reachable from the row")
    }

    @Test func theLadderIsMonotonicInBothHalves() {
        // The property that makes five tiles legible without a legend: every step to the right
        // reads bigger and shows less, and neither half ever moves backwards. It is also what
        // fixes where the density flip goes — anywhere but between entries 2 and 3 breaks this.
        for (earlier, later) in zip(SizePreset.all, SizePreset.all.dropFirst()) {
            #expect(earlier.fontSize.percent <= later.fontSize.percent,
                    "text size goes backwards at \(earlier.id) → \(later.id)")
            #expect(!(earlier.density == .comfortable && later.density == .compact),
                    "row spacing goes backwards at \(earlier.id) → \(later.id)")
        }
        // And it genuinely moves in both dimensions, so the sweep above is not vacuous.
        #expect(Set(SizePreset.all.map(\.fontSize)).count > 1)
        #expect(Set(SizePreset.all.map(\.density)).count == 2)
    }

    @Test func everyPresetIsDistinctAndReachable() {
        #expect(Set(SizePreset.all.map(\.id)).count == SizePreset.all.count,
                "two presets share an id — the row would light both")
        for preset in SizePreset.all {
            #expect(FontSize.selectablePercents.contains(preset.fontSize.percent),
                    "\(preset.id) sits on a percentage the slider cannot reach")
            #expect(SizePreset.matching(fontSize: preset.fontSize, density: preset.density) == preset)
        }
    }

    @Test func aCombinationOffTheLadderMatchesNothing() {
        // The combination this design deliberately does not offer, and the reason the fine
        // controls have to survive the fold: large text with compact rows.
        #expect(SizePreset.matching(fontSize: .extraLarge, density: .compact) == nil)
        #expect(SizePreset.matching(fontSize: FontSize(percent: 115), density: .comfortable) == nil)
    }

    @Test func theCaptionSaysCustomOnlyWhenItIsCustom() {
        // A row that lit its nearest neighbour instead of saying Custom would be claiming a
        // setting the user did not choose.
        let custom = SizePreset.caption(fontSize: FontSize(percent: 115), density: .comfortable)
        #expect(custom.hasPrefix("Custom"), "an off-ladder pair must say so: \(custom)")
        #expect(custom.contains("115%"))

        let standard = SizePreset.caption(fontSize: .medium, density: .comfortable)
        #expect(standard.hasPrefix("Default"), "the shipping look must read as Default: \(standard)")

        // A preset that is neither default nor custom names its values without either word.
        let plain = SizePreset.caption(fontSize: .large, density: .comfortable)
        #expect(!plain.hasPrefix("Custom") && !plain.hasPrefix("Default"), "\(plain)")
        #expect(plain.contains("125%") && plain.lowercased().contains("comfortable"))
    }

    @Test func everyPresetCaptionNamesBothSettings() {
        // The tile's own label is only the percentage and a word; the caption is where the pair
        // is spelled out, so it has to actually carry both.
        for preset in SizePreset.all {
            let caption = SizePreset.caption(fontSize: preset.fontSize, density: preset.density)
            #expect(caption.contains("\(preset.fontSize.percent)%"), "\(caption)")
            #expect(caption.lowercased().contains(preset.density.displayName.lowercased()), "\(caption)")
        }
    }

    /// What the tiles and the preview claim about row spacing has to be what row spacing does.
    ///
    /// The tile says the word and `SizeSpacingPreview` draws the consequence; both are only worth
    /// anything if these metrics really differ, and a density whose two cases converged would make
    /// the whole section a decorative choice between identical outcomes.
    @Test func densityReallyChangesWhatARowShows() {
        #expect(ListDensity.comfortable.metrics.showsSecondaryDetail)
        #expect(!ListDensity.compact.metrics.showsSecondaryDetail)
        #expect(ListDensity.compact.metrics.treeIconSize < ListDensity.comfortable.metrics.treeIconSize)
        #expect(ListDensity.compact.metrics.flatRowVerticalPadding
                < ListDensity.comfortable.metrics.flatRowVerticalPadding)
    }

    /// Compact's caption has to say the size-and-date line disappears, because nobody choosing
    /// from the word "Compact" alone would guess it.
    @Test func theCompactCaptionAdmitsWhatItHides() {
        let detail = ListDensity.compact.detail.lowercased()
        #expect(detail.contains("hides") || detail.contains("hidden"), "\(ListDensity.compact.detail)")
        #expect(detail.contains("date"), "\(ListDensity.compact.detail)")
        #expect(ListDensity.comfortable.detail.lowercased().contains("date"))
    }
}

private extension SizePreset {
    /// Reads through to the font size, so the default-preset test can assert the identity scale
    /// without restating which half carries it.
    static var medium: FontSize { SizePreset.default.fontSize }
}
