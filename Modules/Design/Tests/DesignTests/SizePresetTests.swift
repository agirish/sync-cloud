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

    /// The specimen tiles are the setup form's whole vocabulary, so the thing they encode has to
    /// be real: a compact preset draws the name bar alone because compact rows genuinely drop the
    /// size-and-date line.
    @Test func theSpecimenReflectsWhatDensityActuallyDoes() {
        #expect(ListDensity.comfortable.metrics.showsSecondaryDetail)
        #expect(!ListDensity.compact.metrics.showsSecondaryDetail)
        #expect(ListDensity.compact.metrics.treeIconSize < ListDensity.comfortable.metrics.treeIconSize)
        #expect(ListDensity.compact.metrics.flatRowVerticalPadding
                < ListDensity.comfortable.metrics.flatRowVerticalPadding)
    }

    /// The drawn stack never exceeds the fixed face, at any preset.
    ///
    /// **The defect this pins was invisible to every other test.** The specimen drew three rows at
    /// a pinned 14pt face, which six comfortable bars at 135% overflow by 7.9pt — and SwiftUI does
    /// not clip, it centres, so the bars bled over the tile border toward the percentage below.
    /// The frame was exactly the size it claimed, so geometry saw nothing; only rendering it and
    /// looking did.
    @Test func theSpecimenNeverOverflowsItsFace() {
        for preset in SizePreset.all {
            let rows = SizePresetSpecimen.rowCount(for: preset)
            #expect(rows >= 1, "\(preset.id) draws no rows at all")
            #expect(rows <= SizePresetSpecimen.maximumRows)
            let drawn = CGFloat(rows) * SizePresetSpecimen.rowHeight(for: preset)
                + CGFloat(rows - 1) * SizePresetSpecimen.rowGap(for: preset)
            #expect(drawn <= SizePresetSpecimen.faceHeight,
                    """
                    \(preset.id) draws \(rows) rows totalling \(drawn)pt into a \
                    \(SizePresetSpecimen.faceHeight)pt face — it will bleed over the tile border.
                    """)
        }
    }

    /// A tighter row spacing has to *show* more rows in the same space — otherwise the picture is
    /// decoration rather than a miniature of the outcome.
    @Test func compactFitsMoreRowsThanComfortableAtTheSameTextSize() {
        let compact = SizePreset(fontSize: .medium, density: .compact)
        let comfortable = SizePreset(fontSize: .medium, density: .comfortable)
        #expect(SizePresetSpecimen.rowCount(for: compact)
                > SizePresetSpecimen.rowCount(for: comfortable),
                """
                Compact draws \(SizePresetSpecimen.rowCount(for: compact)) rows and comfortable \
                \(SizePresetSpecimen.rowCount(for: comfortable)) — the two 100% tiles do not tell \
                themselves apart, which is the one thing this row has to do.
                """)
    }

    /// The bars really do thicken with the text size, or the tile is not showing a text size.
    @Test func theBarsGrowWithTheTextSize() {
        #expect(SizePresetSpecimen.barHeight(for: SizePreset(fontSize: .small, density: .comfortable))
                < SizePresetSpecimen.barHeight(for: SizePreset(fontSize: .extraLarge, density: .comfortable)))
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
