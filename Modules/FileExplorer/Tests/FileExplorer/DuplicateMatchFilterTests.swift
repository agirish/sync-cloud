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
        for t: DuplicateMatchType in [.identical, .overlapping(sharedFraction: 0.8), .nameOnly, .versions] {
            #expect(DuplicateMatchFilter.all.matches(group(t)))
        }
    }

    @Test func kindFiltersDiscriminate() {
        #expect(DuplicateMatchFilter.identical.matches(group(.identical)))
        #expect(!DuplicateMatchFilter.identical.matches(group(.nameOnly)))

        #expect(DuplicateMatchFilter.overlapping.matches(group(.overlapping(sharedFraction: 0.75))))
        #expect(!DuplicateMatchFilter.overlapping.matches(group(.identical)))

        #expect(DuplicateMatchFilter.nameOnly.matches(group(.nameOnly)))
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
            DuplicateMatchStyle.symbol(.nameOnly), DuplicateMatchStyle.symbol(.versions),
        ]
        // Fixed symbols hardcoded across LensWorkspaceView / DuplicateGroupCard.
        symbols += [
            "internaldrive", "line.3.horizontal.decrease.circle", "checkmark.circle.fill",
            "wand.and.stars", "arrow.clockwise", "folder.badge.gearshape", "doc.on.doc",
            "exclamationmark.triangle", "square.on.square",
            "chevron.down", "chevron.right", "checkmark", "trash", "arrow.triangle.merge",
            "circle.slash", "largecircle.fill.circle", "circle", "info.circle",
            RevealGlyph.inFinder, "lock",
            // Filing suggestion card (incl. F3 "Remembered" + AI badges) + rescan / preview / retry
            "arrow.turn.down.right", "arrow.right.circle", "folder", "xmark", "memories",
            "eye", "folder.badge.gearshape", "wand.and.stars", "sparkles", "arrow.triangle.2.circlepath",
            "cloud",   // Filing spend row
        ]
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(symbol)")
        }
    }
}
