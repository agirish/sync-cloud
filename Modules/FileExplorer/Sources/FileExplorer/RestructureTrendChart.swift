import Design
import SwiftUI
import Sync

/// "Is the tree getting better?", answered from counts the detectors already produced.
///
/// Nothing here is invented: every point is a finding count a lens displayed when it was
/// stamped, and the caption states both ends in words so the picture can be checked against a
/// number. No score, no target, no per-kind breakdown: a small chart carries the shape and the
/// endpoints honestly, and no more.
struct RestructureTrendChart: View {
    let points: [Point]
    let accent: Color

    /// One stamped survey, reduced to what the drawing needs. Not the store's `TrendPoint`: the
    /// view has no use for profile ids, and the rule that builds these is what tests check.
    struct Point: Equatable {
        let total: Int
        /// A landing produced this survey — the dots, and the only cause the line can show.
        let landing: Bool
    }

    /// The points worth drawing, and nil when there is no line to draw.
    ///
    /// Two is the floor: one point is a dot, not a trend, and would claim a history that doesn't
    /// exist yet. The cap keeps the newest window, since a line squeezing years into a few hundred
    /// pixels shows nothing but its ends.
    static func points(from trend: [RestructureStore.TrendPoint], limit: Int = 40) -> [Point]? {
        guard trend.count >= 2 else { return nil }
        return trend.suffix(limit).map { Point(total: $0.total, landing: $0.landing) }
    }

    /// The caption: the two ends, and what happened between them.
    ///
    /// The numbers themselves rather than a direction word like "fewer", so it can be checked
    /// against the line above it.
    static func caption(for points: [Point]) -> String? {
        guard let first = points.first, let last = points.last else { return nil }
        let landings = points.filter(\.landing).count
        let head: String
        if first.total == last.total {
            head = "\(last.total == 1 ? "1 finding" : "\(last.total.formatted()) findings"), unchanged across \(points.count) surveys"
        } else {
            head = "\(first.total) → \(last.total) findings"
        }
        guard landings > 0 else { return head }
        return head + " · \(landings) landing\(landings == 1 ? "" : "s")"
    }

    /// The drawing's geometry, as a rule: each point's position in a unit square where y is the
    /// count (1 the most findings this window held, 0 the fewest), so a falling line means fewer
    /// findings and needs no legend.
    ///
    /// A rule, not arithmetic inside the `Canvas` closure, because a wrongly drawn chart looks
    /// plausible and a `Canvas` body can't be reached from a test.
    static func unitPositions(_ points: [Point]) -> [CGPoint] {
        guard points.count > 1 else { return points.isEmpty ? [] : [CGPoint(x: 0, y: 0.5)] }
        let totals = points.map(\.total)
        let low = totals.min() ?? 0
        let high = totals.max() ?? 0
        // A flat line sits in the middle: a zero span can't be divided by, and drawing it at the
        // floor would claim "as low as it has ever been" for a tree that didn't change.
        let span = high - low
        return points.enumerated().map { index, point in
            CGPoint(x: CGFloat(index) / CGFloat(points.count - 1),
                    y: span == 0 ? 0.5 : CGFloat(point.total - low) / CGFloat(span))
        }
    }

    static let height: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let unit = Self.unitPositions(points)
                let inset: CGFloat = 3
                let plot = { (p: CGPoint) in
                    CGPoint(x: inset + p.x * (size.width - inset * 2),
                            y: inset + (1 - p.y) * (size.height - inset * 2))
                }
                var line = Path()
                for (index, position) in unit.enumerated() {
                    let point = plot(position)
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                context.stroke(line, with: .color(accent.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                                  lineJoin: .round))
                for (index, position) in unit.enumerated() where points[index].landing {
                    let point = plot(position)
                    let dot = Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5,
                                                     width: 5, height: 5))
                    context.fill(dot, with: .color(accent))
                }
            }
            .frame(height: Self.height)
            .accessibilityHidden(true)
            if let caption = Self.caption(for: points) {
                Text(caption)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.caption(for: points) ?? "Structure trend")
    }
}
