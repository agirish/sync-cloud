import Testing
import AppKit
import Sync
@testable import FileExplorer

/// Coverage for the Filing lens's pure helpers: confidence grouping (the High/Medium/Low sections
/// the results list is split into) and the Filing-specific glyph vocabulary.
@Suite struct FilingLensTests {

    private func suggestion(_ name: String, _ confidence: FilingConfidence?) -> FilingSuggestion {
        let candidates = confidence.map {
            [FilingDestination(path: "/root/Home", confidence: $0, reasons: [], newSegments: [])]
        } ?? []
        return FilingSuggestion(filePath: "/root/Downloads/\(name)", fileName: name,
                                size: 1, modificationDate: nil, candidates: candidates)
    }

    @Test func tierMirrorsBestConfidence() {
        #expect(FilingConfidenceTier.of(suggestion("a", .high)) == .high)
        #expect(FilingConfidenceTier.of(suggestion("b", .medium)) == .medium)
        #expect(FilingConfidenceTier.of(suggestion("c", .low)) == .low)
        // No candidate ("Pick a home" on the card) is a decision the user still owes → low tier.
        #expect(FilingConfidenceTier.of(suggestion("d", nil)) == .low)
    }

    @Test func sectionsAreOrderedHighMediumLowAndDropEmptyTiers() {
        let sections = FilingSuggestionGrouping.sections([
            suggestion("low1", .low),
            suggestion("high1", .high),
            suggestion("med1", .medium),
            suggestion("high2", .high),
            suggestion("none", nil),
        ])
        #expect(sections.map { $0.tier } == [.high, .medium, .low])
        // Within a tier, the engine's original order is preserved (not re-sorted).
        #expect(sections[0].suggestions.map { $0.fileName } == ["high1", "high2"])
        #expect(sections[1].suggestions.map { $0.fileName } == ["med1"])
        #expect(sections[2].suggestions.map { $0.fileName } == ["low1", "none"])
    }

    @Test func emptyInputYieldsNoSections() {
        #expect(FilingSuggestionGrouping.sections([]).isEmpty)
    }

    @Test func singleTierYieldsOneSection() {
        let sections = FilingSuggestionGrouping.sections([suggestion("a", .high), suggestion("b", .high)])
        #expect(sections.count == 1)
        #expect(sections[0].tier == .high)
        #expect(sections[0].suggestions.count == 2)
    }

    // MARK: G5 — confidence meter + legend

    @Test func filledBarsScaleStrictlyWithConfidence() {
        #expect(FilingConfidenceTier.high.filledBars == 3)
        #expect(FilingConfidenceTier.medium.filledBars == 2)
        #expect(FilingConfidenceTier.low.filledBars == 1)
        // Never an empty meter — even the weakest tier lights one bar.
        #expect(FilingConfidenceTier.allCases.allSatisfy { (1...3).contains($0.filledBars) })
        // Strictly increasing, so "more bars" always reads as "surer".
        #expect(FilingConfidenceTier.high.filledBars > FilingConfidenceTier.medium.filledBars)
        #expect(FilingConfidenceTier.medium.filledBars > FilingConfidenceTier.low.filledBars)
    }

    @Test func tierFromRawConfidenceAgreesWithSuggestionKeying() {
        #expect(FilingConfidenceTier.of(FilingConfidence.high) == .high)
        #expect(FilingConfidenceTier.of(FilingConfidence.medium) == .medium)
        #expect(FilingConfidenceTier.of(FilingConfidence.low) == .low)
        // No candidate ("Pick a home") is the low tier — same default as the card's chip.
        #expect(FilingConfidenceTier.of(nil as FilingConfidence?) == .low)
        // The confidence overload and the suggestion overload must never disagree (chip == meter).
        #expect(FilingConfidenceTier.of(suggestion("a", .high)) == FilingConfidenceTier.of(FilingConfidence.high))
        #expect(FilingConfidenceTier.of(suggestion("d", nil)) == FilingConfidenceTier.of(nil as FilingConfidence?))
    }

    @Test func everyTierHasADistinctNonEmptyGloss() {
        for tier in FilingConfidenceTier.allCases {
            #expect(!tier.gloss.isEmpty, "\(tier) needs a legend gloss")
        }
        let glosses = FilingConfidenceTier.allCases.map { $0.gloss }
        #expect(Set(glosses).count == glosses.count, "each tier's gloss should read differently")
    }

    // MARK: G2 — remember-on-override predicate

    @Test func overrideIsTrueOnlyWhenChosenDiffersFromSuggestedHome() {
        let s = suggestion("invoice", .high)   // best candidate path == "/root/Home"
        // Accepting the suggested home is not an override — nothing new to learn.
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/Home") == false)
        // Path-normalized: a trailing slash or a dot segment is still the same home.
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/Home/") == false)
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/./Home") == false)
        // A different folder is the correction worth remembering.
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/Taxes") == true)
    }

    @Test func pickingIsAlwaysAnOverrideWhenThereWasNoSuggestion() {
        // No candidate — the user always had to pick, so any choice teaches where these files go.
        let s = suggestion("mystery", nil)
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/Anywhere") == true)
    }

    @Test func filingGlyphsAreDistinctFromDuplicatesAndResolve() {
        // Filing's own vocabulary must never borrow the duplicate finder's symbols.
        let duplicateGlyphs: Set<String> = ["wand.and.stars", "checkmark.seal.fill"]
        let filingGlyphs = [FilingGlyph.lens, FilingGlyph.allFiled, FilingGlyph.nothingLoose]
        for glyph in filingGlyphs {
            #expect(!duplicateGlyphs.contains(glyph), "\(glyph) collides with the duplicate finder's glyphs")
        }
        #expect(Set(filingGlyphs).count == filingGlyphs.count, "Filing glyphs should be distinct from each other")
        // A typo'd symbol renders blank at runtime; pin that every name (plus the section dot) resolves.
        for glyph in filingGlyphs + ["circle.fill"] {
            #expect(NSImage(systemSymbolName: glyph, accessibilityDescription: nil) != nil, "missing SF Symbol \(glyph)")
        }
    }
}
