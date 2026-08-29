import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// §5.1's era strip: the eras of a year-named shape family drawn in order, and — just as
/// important — nothing at all for a family that is not about years.
@MainActor
@Suite struct RestructureEraStripTests {

    private static func scheme(_ vocabulary: [String], _ members: [String])
        -> StructureFinding.Scheme {
        .init(vocabulary: vocabulary, members: members)
    }

    /// The flagship shape: two eras that each hold a contiguous run of years, in year order,
    /// with the run labelled by its own ends.
    @Test func contiguousRunsOfOneSchemeBecomeOneSegment() throws {
        let segments = try #require(RestructureLens.eraSegments(
            schemes: [Self.scheme(["forms"], ["2013", "2014", "2015"]),
                      Self.scheme(["federal tax"], ["2016", "2017"])],
            drift: []))
        #expect(segments.map(\.label) == ["2013–2015", "2016–2017"])
        #expect(segments.map(\.count) == [3, 2])
        #expect(segments.map(\.scheme) == [0, 1])
    }

    /// Members arrive in profile order, not year order — the strip's whole claim is chronology,
    /// so it sorts. With the input already sorted this test could not fail.
    @Test func theStripIsInYearOrderWhateverOrderTheMembersArriveIn() throws {
        let segments = try #require(RestructureLens.eraSegments(
            schemes: [Self.scheme(["a"], ["2019", "2013"]),
                      Self.scheme(["b"], ["2016"])],
            drift: []))
        #expect(segments.map(\.label) == ["2013", "2016", "2019"])
        #expect(segments.map(\.scheme) == [0, 1, 0],
                "an era that resumes after another gets a second segment, not a merged one")
    }

    /// Drift is a segment with no scheme — drawn hollow, because "no two agree on one shape" is
    /// the absence of an era rather than another one.
    @Test func driftIsItsOwnUnschemedSegment() throws {
        let segments = try #require(RestructureLens.eraSegments(
            schemes: [Self.scheme(["a"], ["2013", "2014"])],
            drift: ["2015"]))
        #expect(segments.map(\.scheme) == [0, nil])
        #expect(segments.last?.label == "2015")
        #expect(RestructureLens.eraStripLabel(segments,
                                             schemes: [Self.scheme(["forms"], ["2013", "2014"])])
                    == "Eras: 2013–2014, forms; 2015, drift")
    }

    /// A fiscal span is a year token the profile already accepts, so it takes part and sorts by
    /// the year it opens. The label must not smuggle its inner dash into the run's own.
    @Test func aFiscalSpanSortsByTheYearItOpens() throws {
        let segments = try #require(RestructureLens.eraSegments(
            schemes: [Self.scheme(["a"], ["2014-2015", "2013", "2016"])],
            drift: []))
        #expect(segments.count == 1)
        #expect(segments[0].label == "2013–2016",
                "the run is labelled by its own ends, not by the span inside it")
        #expect(segments[0].count == 3)
    }

    /// **The common, correct answer for most families.** A family of category names has no order
    /// to draw, and inventing one would be worse than the text rows the strip sits above.
    @Test func aFamilyThatIsNotAboutYearsGetsNoStrip() {
        #expect(RestructureLens.eraSegments(
            schemes: [Self.scheme(["photos"], ["Naming Ceremony", "Birthday"]),
                      Self.scheme([], ["Graduation"])],
            drift: []) == nil)
        #expect(RestructureLens.eraSegments(schemes: [], drift: []) == nil)
    }

    /// The bar is 80%, so one oddly-named member among many years does not suppress the strip —
    /// and a mostly-unnamed family does not get one. Both sides, or the threshold is a constant.
    @Test func theYearBarIsCrossedFromBothSides() {
        // The VALUE, not just a band: 0.9 and 0.5 alone left anything in (0.5, 0.9] passing, and
        // a 4-of-7 family would have gained a strip.
        let sevenWithFour = RestructureLens.eraSegments(
            schemes: [.init(vocabulary: ["a"],
                            members: ["2013", "2014", "2015", "2016", "A", "B", "C"])],
            drift: [])
        #expect(sevenWithFour == nil, "four of seven is not a family about years")
        let tenWithEight = RestructureLens.eraSegments(
            schemes: [.init(vocabulary: ["a"],
                            members: (2013...2020).map(String.init) + ["A", "B"])],
            drift: [])
        #expect(tenWithEight != nil, "eight of ten is")

        let nineYearsAndOne = RestructureLens.eraSegments(
            schemes: [Self.scheme(["a"], (2013...2021).map(String.init) + ["Archive"])],
            drift: [])
        #expect(nineYearsAndOne != nil, "9 of 10 are years — the strip still reads")

        let halfAndHalf = RestructureLens.eraSegments(
            schemes: [Self.scheme(["a"], ["2013", "2014", "Archive", "Reference"])],
            drift: [])
        #expect(halfAndHalf == nil)
    }

    /// One segment is the text row again with extra machinery.
    @Test func aSingleYearFamilyGetsNoStrip() {
        #expect(RestructureLens.eraSegments(
            schemes: [Self.scheme(["a"], ["2013"])], drift: []) == nil)
    }

    /// The strip is a picture, so it carries the sentence it makes — and it names each scheme
    /// by its VOCABULARY, the way the rows below name them. An ordinal ("shape 1") is a number
    /// nothing else on the card establishes, so a listener has nothing to map it onto.
    @Test func theStripSpeaksItsErasForVoiceOver() {
        let segments = [RestructureLens.EraSegment(scheme: 0, label: "2013–2015", count: 3),
                        RestructureLens.EraSegment(scheme: 1, label: "2016", count: 1)]
        let schemes = [Self.scheme(["forms", "payments"], ["2013"]),
                       Self.scheme(["federal tax"], ["2016"])]
        #expect(RestructureLens.eraStripLabel(segments, schemes: schemes)
                    == "Eras: 2013–2015, forms and payments; 2016, federal tax")
        #expect(!RestructureLens.eraStripLabel(segments, schemes: schemes).contains("shape 1"),
                "an ordinal names nothing the card shows")
    }

    /// Shapeless members are members: leaving them out of the bar's denominator let a family of
    /// four years and ten unnamed folders draw "the eras across a shape family" over a third
    /// of itself.
    @Test func shapelessMembersCountAgainstTheYearBar() {
        let schemes = [Self.scheme(["a"], ["2013", "2014", "2015", "2016"])]
        #expect(RestructureLens.eraSegments(schemes: schemes, drift: []) != nil)
        #expect(RestructureLens.eraSegments(schemes: schemes, drift: [],
                                            shapeless: (1...10).map { "Folder \($0)" }) == nil,
                "four of fourteen members is not a family about years")
    }

    /// Every scheme's fill has to read as filled — the fourth step was faint enough to pass for
    /// the hollow drift treatment it must be distinguishable from — and no two may match.
    @Test func everySchemeFillIsDistinctAndVisible() {
        let opacities = RestructureLens.schemeOpacities
        #expect(opacities.count == 4)
        #expect(Set(opacities).count == opacities.count, "two eras would look like one")
        #expect(opacities.allSatisfy { $0 >= 0.17 },
                "a fainter fill reads as the hollow drift segment")
    }

    /// A fiscal member carries an ASCII hyphen and the run label joins with an EN DASH, so
    /// splitting on the wrong one produced "2014-2015–2016".
    @Test func aRunLabelDoesNotSwallowAFiscalMembersOwnHyphen() throws {
        let segments = try #require(RestructureLens.eraSegments(
            schemes: [Self.scheme(["a"], ["2014-2015", "2016", "2017"])], drift: []))
        #expect(segments.count == 1)
        #expect(segments[0].label == "2014-2015–2017")
        #expect(segments[0].label.hasPrefix("2014-2015"),
                "the member's own hyphen survives inside the run's label")
    }

    /// **Proportional is the strip's whole claim**, and it is the one thing a render comparison
    /// cannot check: two families with different member counts also carry different LABELS, so
    /// their images differ either way. (That test was written first, and passed with the widths
    /// mutated back to equal — a fixture whose expected value equals the fallback.) So the share
    /// is a rule, and the call site is pinned below.
    @Test func widthsFollowMemberCounts() {
        let segments = [RestructureLens.EraSegment(scheme: 0, label: "2013–2015", count: 3),
                        RestructureLens.EraSegment(scheme: 1, label: "2016–2022", count: 7),
                        RestructureLens.EraSegment(scheme: nil, label: "2023–2024", count: 2)]
        let widths = RestructureLens.eraSegmentWidths(segments, available: 206)
        // 206 less two 3pt gaps is 200, shared 3:7:2 across twelve members.
        #expect(widths.map { ($0 * 100).rounded() / 100 } == [50, 116.67, 33.33])
        #expect(abs(widths.reduce(0, +) - 200) < 0.001, "the whole row is used")
        #expect(widths[1] > widths[0], "the era covering more folders draws wider")

        let even = [RestructureLens.EraSegment(scheme: 0, label: "a", count: 2),
                    RestructureLens.EraSegment(scheme: 1, label: "b", count: 2)]
        let evenWidths = RestructureLens.eraSegmentWidths(even, available: 103)
        #expect(evenWidths == [50, 50])
    }

    /// A strip narrower than its gaps must not produce negative frames.
    @Test func aStripWithNoRoomProducesNoNegativeWidths() {
        let segments = [RestructureLens.EraSegment(scheme: 0, label: "a", count: 1),
                        RestructureLens.EraSegment(scheme: 1, label: "b", count: 1)]
        #expect(RestructureLens.eraSegmentWidths(segments, available: 0)
                    .allSatisfy { $0 >= 0 })
        #expect(RestructureLens.eraSegmentWidths([], available: 100) == [])
    }

    /// The rule is one revert away from being unused — which is exactly how the strip drew wrong
    /// in the first place.
    @Test func theStripActuallyAsksForThoseWidths() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructureLens.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("widths: Self.eraSegmentWidths(segments, available: geo.size.width)"))
        // And that they REACH a frame. Pinning only the call left
        // `.frame(maxWidth: .infinity)` free to ignore them, with `eraSegmentWidths` correct and
        // unused — which is the same defect in a new disguise.
        #expect(text.contains(".frame(maxWidth: widths.map { $0[index] } ?? .infinity)"),
                "the computed width has to be the frame's width")
        #expect(!text.contains(".layoutPriority(Double(segment.count))"),
                "layoutPriority decides who gets space first, not how much")
    }

    /// The card renders with the strip and without it, and neither crashes offscreen.
    @Test func shapeCardsRenderWithAndWithoutTheStrip() throws {
        for finding in [
            StructureFinding(family: "Finance/US/Income Tax",
                             schemes: [Self.scheme(["forms"], ["2013", "2014"]),
                                       Self.scheme(["federal"], ["2016"])],
                             drift: ["2015"]),
            StructureFinding(family: "Family/Events",
                             schemes: [Self.scheme(["photos"], ["Birthday", "Naming"])]),
        ] {
            let lens = RestructureLens(findings: [finding], hasProfile: true, folderCount: 10,
                                       accent: .blue, onReveal: { _ in }, hasReviewed: true)
            // An ink floor, not a width: `fittingSize.width > 0` is true of an empty
            // `VStack`, so it passed with the subject of this test deleted.
            let rep = try #require(RestructureRender.raster(lens, width: 640, height: 300))
            #expect(RestructureRender.inkedPixels(rep) > 1000)
        }
    }
}
