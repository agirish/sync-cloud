import Design
import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// **A risky name is often risky for a reason you cannot see, and the row has to show it.**
///
/// `NameNormalizer` reports a name when its sanitized form differs from itself, and sanitize's
/// first layer runs for *every* provider: zero-width and BOM scalars dropped, non-standard
/// whitespace folded, NFC applied. So "report.pdf → report.pdf", identical to the eye and differing
/// by a scalar with no width, is an ordinary finding here rather than an exotic one — on iCloud and
/// a plain folder as much as on OneDrive.
///
/// The retired standalone lens drew every risky name through ``InvisibleNameMarking``. When the
/// findings moved into `RenamePassLens`'s to-fix section (v4.0 polish P10) they arrived as a plain
/// `Text`, and that whole class of finding went back to being invisible in the one view whose job
/// is showing it. These pin the marking and the call site that uses it.
@Suite struct RiskyNameMarkingTests {

    private func markerCount(_ name: String) -> Int {
        RenamePassLens.marked(name).runs.filter { $0.foregroundColor == SemanticColor.error }.count
    }

    /// The invisible cases — the ones the row exists for.
    ///
    /// Written as counts of *marked runs* rather than of glyphs: adjacent markers coalesce into one
    /// run when they carry identical attributes, which is why the two-space case asserts on the
    /// rendered text as well. What matters to a reader is that the trailing whitespace is visible
    /// at all, and that both spaces of a double are, since "one trailing space" and "two" are
    /// different names that a plain `Text` draws identically.
    @Test func everyInvisibleScalarIsMarked() {
        #expect(markerCount("Reports ") == 1, "a trailing space drew no marker")
        #expect(markerCount("a\u{200B}b") == 1, "a zero-width space drew no marker")
        #expect(markerCount("a\u{00A0}b") == 1, "a no-break space drew no marker")
        // Both spaces of a run, not just the outermost: "Swimming  " ends in two, and marking one
        // leaves the name reading as though it ended in one.
        #expect(String(RenamePassLens.marked("Swimming  ").characters) == "Swimming␣␣")
        #expect(String(RenamePassLens.marked("a\u{200B}b").characters) == "a◌b")
    }

    /// **And a name with nothing invisible is left alone**, or the marker stops meaning anything.
    ///
    /// The fixture matters: both of these are genuinely risky names — a trailing period breaks
    /// Dropbox, a colon breaks OneDrive — so this is "visible problems draw no marker", not
    /// "clean names draw no marker", which no row would ever ask.
    @Test func aVisibleProblemDrawsNoMarker() {
        #expect(markerCount("Reports.") == 0, "a trailing period is visible and was marked anyway")
        #expect(markerCount("Tax: 2024.pdf") == 0, "a forbidden character is visible and was marked anyway")
        #expect(String(RenamePassLens.marked("Tax: 2024.pdf").characters) == "Tax: 2024.pdf",
                "an ordinary name came back altered")
        // An interior space is already visible by the text either side of it, so only the affix one
        // is marked. Both are present here on purpose: a fixture carrying only the trailing space
        // would pass just as well against a rule that marked every space in the name.
        #expect(markerCount("Tax 2024 .pdf ") == 1, "the interior space was marked, or the affix one was not")
        #expect(String(RenamePassLens.marked("Tax 2024 .pdf ").characters) == "Tax 2024 .pdf␣")
    }

    /// The tint is this section's, not the kept-names list's.
    ///
    /// Settings ▸ Organize marks the same scalars in **caution** — a name you chose to keep — while
    /// these are names that are still broken, so they wear the error tier the rest of the section
    /// wears. One rule, two tints, decided by the caller.
    @Test func markersWearTheSectionsErrorTier() throws {
        let marked = RenamePassLens.marked("Reports ")
        let marker = try #require(marked.runs.first { $0.foregroundColor == SemanticColor.error })
        #expect(marker.backgroundColor == SemanticColor.error.opacity(PillVariant.fillOpacity),
                "the marker lost its wash — the glyph alone is easy to miss at 13pt")
        #expect(marked.runs.contains { $0.foregroundColor == nil },
                "every run is tinted — the name's own characters are being drawn as markers")
    }

    /// **The call site, because a rule nothing calls is the state this bug was already in.**
    ///
    /// `marked` is `static` so it can be pinned above without mounting anything, and that is
    /// exactly what makes it possible for the row to stop calling it while every assertion here
    /// stays green — which is the shape of the original defect: the rule existed, in Sync, fully
    /// tested, and the row that needed it drew a plain `Text`.
    ///
    /// A source scan rather than a render: this section's rows are `List` content, and a `List`'s
    /// lazy rows do not render in an offscreen host — only section headers do — so a pixel probe
    /// here would measure nothing and pass. The paint is confirmed in the installed app.
    @Test func theToFixRowDrawsTheMarkedName() throws {
        let source = try OrganizeScopeCallSiteTests.source("RenamePassLens.swift")
        let body = try OrganizeScopeCallSiteTests.body(of: "private var toFixSection: some View {",
                                                       in: source)
        #expect(body.contains("Text(Self.marked(risky.currentName))"),
                "the to-fix row is drawing the raw name again — an invisible hazard shows nothing")
    }
}
