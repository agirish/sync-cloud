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
