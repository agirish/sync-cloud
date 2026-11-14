import Testing
import AppKit
import Sync
import Design
@testable import FileExplorer

/// Coverage for DuplicateMatchFilter.matches — the predicate driving which duplicate groups the Duplicates list
/// shows, and the match-type styling that reads status without color.
@Suite struct DuplicateMatchFilterTests {

    private func group(_ type: DuplicateMatchType) -> DuplicateGroup {
        let a = DuplicateCopy(id: "/a", name: "n", isDirectory: false, size: 1, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let b = DuplicateCopy(id: "/b", name: "n", isDirectory: false, size: 1, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false)
        return DuplicateGroup(matchType: type, name: "n", isDirectory: false, copies: [a, b], reclaimableBytes: 1)
    }

    @Test func allAcceptsEveryKind() {
        for t: DuplicateMatchType in [.identical, .overlapping(sharedFraction: 0.8), .versions] {
            #expect(DuplicateMatchFilter.all.matches(group(t)))
        }
    }

    @Test func kindFiltersDiscriminate() {
        #expect(DuplicateMatchFilter.identical.matches(group(.identical)))
        #expect(!DuplicateMatchFilter.identical.matches(group(.sameText)))

        #expect(DuplicateMatchFilter.overlapping.matches(group(.overlapping(sharedFraction: 0.75))))
        #expect(!DuplicateMatchFilter.overlapping.matches(group(.identical)))

        // Every non-identical kind, not one: narrowing the predicate to `== .sameText` would drop
        // overlapping and versions groups, which a single-kind check can't see.
        for kind in DuplicateMatchType.Kind.allCases {
            let g = group(DuplicateSections.representative(kind))
            #expect(DuplicateMatchFilter.needsReview.matches(g) == (kind != .identical),
                    "\(kind) is on the wrong side of \"needs review\"")
        }
        #expect(DuplicateMatchFilter.versions.matches(group(.versions)))
        #expect(!DuplicateMatchFilter.versions.matches(group(.overlapping(sharedFraction: 0.9))))
    }

    @Test func overlapLabelShowsPercent() {
        #expect(DuplicateMatchStyle.label(.overlapping(sharedFraction: 0.92)) == "Overlapping · 92%")
        #expect(DuplicateMatchStyle.label(.identical) == "Identical")
    }

    @Test func lensSymbolNamesExistInSFSymbols() {
        // A typo'd symbol renders blank at runtime; pin every name the lens workspace uses (mirrors
        // DifferenceGlyphTests.testSymbolNamesExistInSFSymbols).
        var symbols: [String] = [
            // match-type badges
            DuplicateMatchStyle.symbol(.identical), DuplicateMatchStyle.symbol(.overlapping(sharedFraction: 0.5)),
            DuplicateMatchStyle.symbol(.versions),
        ]
        // A constant, not a `systemImage:` literal, so the source scan below can't see it.
        symbols.append(RevealGlyph.inFinder)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbol)")
        }
    }

    /// Every `systemImage:` / `systemName:` literal in FileExplorer's sources names a real SF
    /// Symbol: a typo renders blank at runtime. Mutation: `"arrow.triangle.merge"` →
    /// `"arrow.triangle.mergex"` in `DuplicateGroupCard`.
    @Test func everySymbolLiteralInTheSourcesExists() throws {
        let literal = try NSRegularExpression(pattern: #"\b(?:systemImage|systemName):\s*"([^"\\\n]+)""#)
        let files = try AppCopyScan.sourceFiles().filter { $0.path.hasPrefix("Modules/FileExplorer/Sources/") }
        try #require(files.count > 60, "only \(files.count) FileExplorer source files — wrong root?")
        var found = 0
        var missing: [String] = []
        for (path, text) in files {
            let code = SourceText.codeOnly(text)
            for match in literal.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else { continue }
                found += 1
                let name = String(code[range])
                if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                    missing.append("\((path as NSString).lastPathComponent): \(name)")
                }
            }
        }
        #expect(found >= 250, "found only \(found) symbol literals — the scan is not reading the sources")
        #expect(missing.isEmpty, "not SF Symbols: \(missing)")
    }
}
