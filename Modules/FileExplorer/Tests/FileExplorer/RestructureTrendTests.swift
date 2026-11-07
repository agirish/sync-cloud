import AppKit
import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// "Is the tree getting better?", from counts the detectors already produced. The chart's three
/// rules (which points to draw, where they sit, what the caption says) are tested without a view;
/// the `Canvas` closure is unreachable from a test, which is why the geometry lives outside it.
@MainActor
@Suite struct RestructureTrendTests {

    private static func stored(_ totals: [Int], landings: Set<Int> = [])
        -> [RestructureStore.TrendPoint] {
        totals.enumerated().map { index, total in
            RestructureStore.TrendPoint(at: "2026-08-2\(index)T09:00:00",
                                        profileId: "p\(index)",
                                        countsByKind: ["shape": total],
                                        landing: landings.contains(index))
        }
    }

    private static func points(_ totals: [Int], landings: Set<Int> = [])
        -> [RestructureTrendChart.Point] {
        totals.enumerated().map {
            RestructureTrendChart.Point(total: $0.element, landing: landings.contains($0.offset))
        }
    }

    // MARK: Which points are worth a line

    /// One survey is a dot, not a trend: a chart over one point claims a history that doesn't exist.
    @Test func aSingleSurveyDrawsNoLine() {
        #expect(RestructureTrendChart.points(from: []) == nil)
        #expect(RestructureTrendChart.points(from: Self.stored([33])) == nil)
        #expect(RestructureTrendChart.points(from: Self.stored([33, 19]))?.count == 2)
    }

    /// The newest window, not the whole history: a line squeezing years into 200 points shows only
    /// its own ends.
    @Test func theWindowKeepsTheNewestPoints() throws {
        let many = Self.stored(Array(1...60))
        let drawn = try #require(RestructureTrendChart.points(from: many, limit: 40))
        #expect(drawn.count == 40)
        #expect(drawn.first?.total == 21, "the window starts 40 back from the newest")
        #expect(drawn.last?.total == 60)
    }

    /// The total sums every kind: a tree that traded five shape findings for five echo ones hasn't
    /// improved, and the line must not say it has.
    @Test func theTotalSumsEveryKind() {
        let point = RestructureStore.TrendPoint(
            at: "t", profileId: "p", countsByKind: ["shape": 4, "echoName": 3, "backlog": 1],
            landing: false)
        #expect(point.total == 8)
        #expect(RestructureStore.TrendPoint(at: "t", profileId: "p", countsByKind: [:],
                                            landing: false).total == 0)
    }

    // MARK: Where the points sit

    /// y is the count, the conventional reading, so a falling line means fewer findings and the
    /// chart needs no legend.
    @Test func theHighestCountSitsAtTheTopOfTheRange() throws {
        let positions = RestructureTrendChart.unitPositions(Self.points([10, 30, 20]))
        #expect(positions.count == 3)
        #expect(positions[1].y == 1, "30 is the most in this window")
        #expect(positions[0].y == 0, "10 is the fewest")
        #expect(positions[2].y == 0.5, "20 is halfway between them")
        // x spreads evenly end to end, so the line fills the width it is given.
        #expect(positions.map(\.x) == [0, 0.5, 1])
    }

    /// A flat line sits in the middle. Dividing by a zero span would crash, and the floor would
    /// claim "as low as it has ever been" for a tree that merely didn't change.
    @Test func anUnchangedTreeDrawsThroughTheMiddle() {
        let positions = RestructureTrendChart.unitPositions(Self.points([19, 19, 19]))
        #expect(positions.allSatisfy { $0.y == 0.5 })
    }

    // MARK: The caption

    /// The two ends as numbers, not a direction word: "fewer findings" must be taken on trust, and
    /// numbers can be checked against the line.
    @Test func theCaptionStatesBothEndsAndTheLandings() throws {
        #expect(RestructureTrendChart.caption(for: Self.points([33, 27, 19], landings: [1, 2]))
                    == "33 → 19 findings · 2 landings")
        #expect(RestructureTrendChart.caption(for: Self.points([33, 19], landings: [1]))
                    == "33 → 19 findings · 1 landing")
        #expect(RestructureTrendChart.caption(for: Self.points([33, 19]))
                    == "33 → 19 findings", "no landings, nothing about landings")
    }

    /// An unchanged trend says so rather than printing "19 → 19", which reads like a change that
    /// came to nothing.
    @Test func anUnchangedTrendSaysUnchanged() throws {
        let caption = try #require(RestructureTrendChart.caption(for: Self.points([19, 19, 19])))
        #expect(caption == "19 findings, unchanged across 3 surveys")
        // One finding is one, not "1 findings".
        #expect(RestructureTrendChart.caption(for: Self.points([1, 1])) == "1 finding, unchanged across 2 surveys")
    }

    // MARK: It is drawn

    /// The line and the dots reach the pixels, with the caption held constant: `caption(for:)`
    /// appends "· N landings", so both arms have the same number of landings at different
    /// positions, and every differing pixel is a dot that moved. Deleting the dot loop must fail.
    @Test func theChartDrawsItsLineAndItsLandingDots() throws {
        func chart(landings: Set<Int>) -> RestructureTrendChart {
            RestructureTrendChart(points: Self.points([33, 27, 19], landings: landings),
                                  accent: .blue)
        }
        let atStart = try #require(RestructureRender.raster(chart(landings: [0]),
                                                            width: 240, height: 60))
        let atEnd = try #require(RestructureRender.raster(chart(landings: [2]),
                                                          width: 240, height: 60))
        #expect(RestructureTrendChart.caption(for: Self.points([33, 27, 19], landings: [0]))
                == RestructureTrendChart.caption(for: Self.points([33, 27, 19], landings: [2])),
                "a positive control: the two arms' captions are the same string")
        #expect(RestructureRender.differingPixels(atStart, atEnd) > 20,
                "the dot is drawn where the landing is, not just somewhere")

        // And the line is drawn, measured inside the canvas band alone: the caption inks over a
        // hundred pixels by itself, so an ink floor over the whole view proves nothing.
        let band = try #require(RestructureRender.raster(
            RestructureTrendChart(points: Self.points([33, 27, 19]), accent: .blue)
                .frame(height: RestructureTrendChart.height),
            width: 240, height: RestructureTrendChart.height))
        #expect(RestructureRender.inkedPixels(band) > 100, "the line itself is stroked")
    }
}
