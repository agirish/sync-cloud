import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// A risky name is often risky for a reason you can't see, and the row has to show it.
///
/// `NameNormalizer` reports a name when its sanitized form differs from itself, and sanitize's
/// first layer runs for every provider: zero-width and BOM scalars dropped, non-standard
/// whitespace folded, NFC applied. So "report.pdf → report.pdf", identical to the eye, is an
/// ordinary finding on iCloud and a plain folder as much as on OneDrive. `RenamePassLens`'s to-fix
/// section must draw it through ``InvisibleNameMarking``, not a plain `Text`; these pin the marking
/// and its call site.
@Suite struct RiskyNameMarkingTests {

    private static let errorWash = SemanticColor.error.opacity(PillVariant.fillOpacity)

    private func markerCount(_ name: String) -> Int {
        // A marker is the run with the error wash; its glyph is the name's own ink.
        RenamePassLens.marked(name).runs.filter { $0.backgroundColor == Self.errorWash }.count
    }

    /// The invisible cases, the ones the row exists for. Counted as marked runs, not glyphs:
    /// adjacent markers with identical attributes coalesce into one run, so the two-space case
    /// asserts on the rendered text too. One trailing space and two are different names that a
    /// plain `Text` draws identically.
    @Test func everyInvisibleScalarIsMarked() {
        #expect(markerCount("Reports ") == 1, "a trailing space drew no marker")
        #expect(markerCount("a\u{200B}b") == 1, "a zero-width space drew no marker")
        #expect(markerCount("a\u{00A0}b") == 1, "a no-break space drew no marker")
        // Both spaces of a run, not just the outermost: "Swimming  " ends in two, and marking one
        // would read as though it ended in one.
        #expect(String(RenamePassLens.marked("Swimming  ").characters) == "Swimming␣␣")
        #expect(String(RenamePassLens.marked("a\u{200B}b").characters) == "a◌b")
    }

    /// And a name with nothing invisible is left alone, or the marker stops meaning anything. Both
    /// fixtures are really risky (a trailing period breaks Dropbox, a colon breaks OneDrive), so
    /// this checks that visible problems draw no marker, which is what a to-fix row meets.
    @Test func aVisibleProblemDrawsNoMarker() {
        #expect(markerCount("Reports.") == 0, "a trailing period is visible and was marked anyway")
        #expect(markerCount("Tax: 2024.pdf") == 0, "a forbidden character is visible and was marked anyway")
        #expect(String(RenamePassLens.marked("Tax: 2024.pdf").characters) == "Tax: 2024.pdf",
                "an ordinary name came back altered")
        // An interior space is visible by the text either side, so only the affix one is marked.
        // Both are present on purpose: a trailing space alone would pass against a rule that
        // marked every space.
        #expect(markerCount("Tax 2024 .pdf ") == 1, "the interior space was marked, or the affix one was not")
        #expect(String(RenamePassLens.marked("Tax 2024 .pdf ").characters) == "Tax 2024 .pdf␣")
    }

    /// The tint is this section's, not the kept-names list's. Settings ▸ Organize marks the same
    /// scalars in caution (a name you chose to keep); these names are still broken, so they wear
    /// the section's error tier. One rule, two tints, decided by the caller.
    @Test func markersWearTheSectionsErrorTier() throws {
        let marked = RenamePassLens.marked("Reports ")
        let marker = try #require(marked.runs.first { $0.backgroundColor == Self.errorWash },
                                  "the marker lost its error wash — the glyph alone is easy to miss at 13pt")
        // The glyph in the name's own ink, the colour only in the wash: a red ␣ on a red wash is
        // the coloured-word-on-its-own-wash pairing the design rules out.
        #expect(marker.foregroundColor == nil, "the marker's glyph is tinted: \(String(describing: marker.foregroundColor))")
        #expect(marked.runs.contains { $0.backgroundColor == nil },
                "every run is washed — the name's own characters are being drawn as markers")
    }

    /// The call site. `marked` is `static` so it can be pinned without mounting anything, which
    /// also lets the row stop calling it while every assertion above stays green.
    ///
    /// A source scan, not a render: this section's rows are `List` content, and a `List`'s lazy
    /// rows don't render in an offscreen host (only section headers do), so a pixel probe would
    /// measure nothing and pass. The paint is confirmed in the installed app.
    @Test func theToFixRowDrawsTheMarkedName() throws {
        let source = try OrganizeScopeCallSiteTests.source("RenamePassLens.swift")
        let body = try OrganizeScopeCallSiteTests.body(of: "private var toFixSection: some View {",
                                                       in: source)
        #expect(body.contains("Text(Self.marked(risky.currentName))"),
                "the to-fix row is drawing the raw name again — an invisible hazard shows nothing")
    }
}
