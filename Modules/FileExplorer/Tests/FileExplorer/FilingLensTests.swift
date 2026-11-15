import Testing
import AppKit
import Sync
@testable import FileExplorer

/// The Filing lens's pure helpers: its sections (Matched, Check first, Needs your pick), the
/// confidence tier a search matches, and the Filing-specific glyph vocabulary.
@Suite struct FilingLensTests {

    private func suggestion(_ name: String, _ confidence: FilingConfidence?) -> FilingSuggestion {
        let candidates = confidence.map {
            [FilingDestination(path: "/root/Home", confidence: $0, reasons: [], newSegments: [])]
        } ?? []
        return FilingSuggestion(filePath: "/root/Downloads/\(name)", fileName: name,
                                size: 1, modificationDate: nil, candidates: candidates)
    }

    /// Both overloads map to the same tiers, so the card's pill and a search's chip cannot disagree.
    @Test func tierMirrorsBestConfidence() {
        #expect(FilingConfidenceTier.of(suggestion("a", .high)) == .high)
        #expect(FilingConfidenceTier.of(suggestion("b", .medium)) == .medium)
        #expect(FilingConfidenceTier.of(suggestion("c", .low)) == .low)
        // No candidate ("Pick a home" on the card) is a decision the user still owes, so low tier.
        #expect(FilingConfidenceTier.of(suggestion("d", nil)) == .low)
        #expect(FilingConfidenceTier.of(FilingConfidence.high) == .high)
        #expect(FilingConfidenceTier.of(FilingConfidence.medium) == .medium)
        #expect(FilingConfidenceTier.of(FilingConfidence.low) == .low)
        #expect(FilingConfidenceTier.of(nil as FilingConfidence?) == .low)
    }

    private func statement(_ name: String, _ confidence: FilingConfidence = .high, account root: String = "/root/IRA 7863",
                           fromAI: Bool = false) -> FilingSuggestion {
        let acct = FilingAccount(root: root, ending: "7863", institution: "schwab", archived: false, kind: .statement)
        return FilingSuggestion(filePath: "/root/TODO/\(name)", fileName: name, size: 1, modificationDate: nil,
                                candidates: [FilingDestination(path: root, confidence: confidence, reasons: [], newSegments: [],
                                                               fromContent: true, fromAI: fromAI, account: acct)])
    }

    /// Sections by what the card asks: Matched (what File All files), Check first, Needs your
    /// pick, in that order, empty ones dropped, the engine's order kept, statements grouped.
    @Test func sectionsAreMatchedCheckFirstAndNeedsYourPick() {
        let model = FilingSuggestion(filePath: "/root/TODO/model.pdf", fileName: "model.pdf", size: 1, modificationDate: nil,
                                 candidates: [FilingDestination(path: "/root/Health", confidence: .high, reasons: [],
                                                                newSegments: [], fromAI: true)])
        let sections = FilingCardSections.sections([
            suggestion("low1", .low),
            statement("01.pdf"),
            suggestion("byname", .high),
            statement("new.pdf", .medium),
            statement("02.pdf"),
            model,
            suggestion("none", nil),
        ])
        #expect(sections.map(\.kind) == [.matched, .checkFirst, .needsPick])
        guard sections.count == 3, case .group(let g) = sections[0].items.first else { Issue.record("expected a group first"); return }
        #expect(g.members.map(\.fileName) == ["01.pdf", "02.pdf"], "the two statements share a card where the first stood")
        #expect(sections[0].items.dropFirst().map(\.id) == ["/root/Downloads/byname"], "the name-placed file follows")
        #expect(sections[0].fileCount == 3)
        #expect(sections[1].items.map(\.id) == ["/root/TODO/new.pdf", "/root/TODO/model.pdf"],
                "a Medium and a model's High both need a look first")
        #expect(sections[2].items.map(\.id) == ["/root/Downloads/low1", "/root/Downloads/none"])
    }

    @Test func emptyInputYieldsNoSections() {
        #expect(FilingCardSections.sections([]).isEmpty)
    }

    /// "210 matched, in 21 accounts": accounts while every Matched file has one, folders otherwise,
    /// and only what moves.
    @Test func theReadoutCountsWhatMovesAndWhere() {
        let filed = statement("03.pdf").alreadyFiled(at: ["IRA 7863"])
        let accounts = FilingCardSections.matchedPlaces([statement("01.pdf"), statement("02.pdf", account: "/root/Roth 4657"), filed])
        #expect(accounts.files == 2 && accounts.places == 2 && accounts.accounts)
        let mixed = FilingCardSections.matchedPlaces([statement("01.pdf"), suggestion("byname", .high), suggestion("m", .medium)])
        #expect(mixed.files == 2 && mixed.places == 2 && !mixed.accounts)
    }

    // MARK: G2 — remember-on-override predicate

    @Test func overrideIsTrueOnlyWhenChosenDiffersFromSuggestedHome() {
        let s = suggestion("invoice", .high)   // best candidate path == "/root/Home"
        // Accepting the suggested home is not an override: nothing new to learn.
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/Home") == false)
        // Path-normalized: a trailing slash or a dot segment is still the same home.
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/Home/") == false)
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/./Home") == false)
        // A different folder is the correction worth remembering.
        #expect(FilingOverride.isOverride(s, chosenPath: "/root/Taxes") == true)
    }

    @Test func pickingIsAlwaysAnOverrideWhenThereWasNoSuggestion() {
        // No candidate: the user always had to pick, so any choice teaches where these files go.
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
        // A mistyped symbol renders blank; every name (plus the section dot) must resolve.
        for glyph in filingGlyphs + ["circle.fill"] {
            #expect(NSImage(systemSymbolName: glyph, accessibilityDescription: nil) != nil, "missing SF Symbol \(glyph)")
        }
    }
}
