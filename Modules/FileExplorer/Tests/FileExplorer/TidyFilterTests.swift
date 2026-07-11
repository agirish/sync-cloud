import Testing
import AppKit
import Sync
@testable import FileExplorer

/// Coverage for TidyFilter.matches — the predicate driving which duplicate groups the Tidy list
/// shows, and the match-type styling that reads status without color.
@Suite struct TidyFilterTests {

    private func group(_ type: DuplicateMatchType) -> DuplicateGroup {
        let a = DuplicateCopy(id: "/a", name: "n", isDirectory: false, size: 1, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let b = DuplicateCopy(id: "/b", name: "n", isDirectory: false, size: 1, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false)
        return DuplicateGroup(matchType: type, name: "n", isDirectory: false, copies: [a, b], reclaimableBytes: 1)
    }

    @Test func allAcceptsEveryKind() {
        for t: DuplicateMatchType in [.identical, .overlapping(sharedFraction: 0.8), .nameOnly, .versions] {
            #expect(TidyFilter.all.matches(group(t)))
        }
    }

    @Test func kindFiltersDiscriminate() {
        #expect(TidyFilter.identical.matches(group(.identical)))
        #expect(!TidyFilter.identical.matches(group(.nameOnly)))

        #expect(TidyFilter.overlapping.matches(group(.overlapping(sharedFraction: 0.75))))
        #expect(!TidyFilter.overlapping.matches(group(.identical)))

        #expect(TidyFilter.nameOnly.matches(group(.nameOnly)))
        #expect(TidyFilter.versions.matches(group(.versions)))
        #expect(!TidyFilter.versions.matches(group(.overlapping(sharedFraction: 0.9))))
    }

    @Test func overlapLabelShowsPercent() {
        #expect(TidyMatchStyle.label(.overlapping(sharedFraction: 0.92)) == "Overlapping · 92%")
        #expect(TidyMatchStyle.label(.identical) == "Identical")
    }

    @Test func tidySymbolNamesExistInSFSymbols() {
        // A typo'd symbol renders blank at runtime; pin every name Tidy uses (mirrors
        // DifferenceGlyphTests.testSymbolNamesExistInSFSymbols).
        var symbols: [String] = [
            // match-type badges
            TidyMatchStyle.symbol(.identical), TidyMatchStyle.symbol(.overlapping(sharedFraction: 0.5)),
            TidyMatchStyle.symbol(.nameOnly), TidyMatchStyle.symbol(.versions),
        ]
        // Fixed symbols hardcoded across TidyView / TidyGroupCard.
        symbols += [
            "internaldrive", "line.3.horizontal.decrease.circle", "checkmark.circle.fill",
            "wand.and.stars", "arrow.clockwise", "folder.badge.gearshape", "doc.on.doc",
            "exclamationmark.triangle", "square.on.square",
            "chevron.down", "chevron.right", "checkmark", "trash", "arrow.triangle.merge",
            "circle.slash", "largecircle.fill.circle", "circle", "info.circle",
            "magnifyingglass", "lock",
        ]
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbol)")
        }
    }
}
