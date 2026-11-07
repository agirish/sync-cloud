import Testing
import SwiftUI
@testable import Design

/// `SizePreset` is a shortcut over two settings that stay the sources of truth, so what these pin
/// is mostly what it must NOT do: invent a third stored value, claim a pairing the user did not
/// choose, or reorder itself into something that stops reading as a ladder.
@Suite struct SizePresetTests {

    @Test func theDefaultPresetIsTheShippingLook() {
        // If the two settings' defaults move, or a reorder makes another entry the identity pairing,
        // this fails rather than quietly changing what the Settings caption calls "Default".
        #expect(SizePreset.default.fontSize == FontSize.medium)
        #expect(SizePreset.default.density == ListDensity.comfortable)
        #expect(SizePreset.medium.scale == 1, "the default preset must be the unscaled rendering")
        #expect(SizePreset.all.contains(SizePreset.default),
                "the default pairing is not reachable from the row")
    }

    @Test func theLadderIsMonotonicInBothHalves() {
        // What makes five tiles legible without a legend: every step right reads bigger and shows
        // less, and neither half moves backwards. It also fixes the density flip between entries 2
        // and 3.
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
        // Large text with compact rows: the pairing the ladder doesn't offer, and why the fine
        // controls stay.
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

    // MARK: - The slider's detent labels

    /// The detent rail maps a percentage onto the track the same way the slider does. Pure
    /// arithmetic, the half that can be wrong silently: a mis-scaled mapping puts every label under
    /// the wrong tick and still looks tidy. `knobInset`, half a knob SwiftUI doesn't expose, is
    /// settled by rendering the tab and looking.
    @Test func theDetentRailMapsThePercentagesOntoTheTrack() {
        #expect(FontSizeDetentLabels.position(FontSize.minimumPercent) == 0)
        #expect(FontSizeDetentLabels.position(FontSize.maximumPercent) == 1)

        let positions = FontSize.allCases.map { FontSizeDetentLabels.position($0.percent) }
        #expect(positions == positions.sorted())
        #expect(Set(positions).count == positions.count, "two detents share a position")

        // Default sits at 10/45 of the way along, not a third, so an evenly spaced layout replacing
        // the value-derived one fails. The four sizes are not evenly spaced.
        let expected = CGFloat(FontSize.medium.percent - FontSize.minimumPercent)
            / CGFloat(FontSize.maximumPercent - FontSize.minimumPercent)
        #expect(abs(FontSizeDetentLabels.position(FontSize.medium.percent) - expected) < 0.0001)
    }

    // MARK: - The specimen tile (the setup form's face)

    /// The drawn stack never exceeds the fixed face, at any preset. SwiftUI doesn't clip, it
    /// centres, so an overflow bleeds over the tile border toward the percentage below while the
    /// frame still reports the size it claims, invisible to geometry.
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

    /// A tighter row spacing has to show more rows in the same space, or the picture is decoration
    /// and the setup form's two 100% tiles, same percentage and no words, look the same.
    @Test func compactFitsMoreRowsThanComfortableAtTheSameTextSize() {
        let compact = SizePreset(fontSize: .medium, density: .compact)
        let comfortable = SizePreset(fontSize: .medium, density: .comfortable)
        #expect(SizePresetSpecimen.rowCount(for: compact)
                > SizePresetSpecimen.rowCount(for: comfortable),
                """
                Compact draws \(SizePresetSpecimen.rowCount(for: compact)) rows and comfortable \
                \(SizePresetSpecimen.rowCount(for: comfortable)) — the two 100% tiles do not tell \
                themselves apart, which is the one thing this face has to do.
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
