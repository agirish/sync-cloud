import Design
import SwiftUI
import Sync

/// "Is the tree getting better?", answered from counts the detectors already produced
/// (proposal O16).
///
/// **Nothing here is invented.** Every point is a finding count a lens displayed at the time it
/// was stamped, and the caption states the two ends of the line in words so a reader can check the
/// picture against a number. There is no score, no target, and no per-kind breakdown — the shape
/// and the two endpoints are what a small chart can carry honestly.
struct RestructureTrendChart: View {
    let points: [Point]
    let accent: Color

    /// One stamped survey, reduced to what the drawing needs. A struct rather than the store's
    /// `TrendPoint` because the view has no business with profile ids, and because the rule that
    /// builds these is where the testable decisions live.
    struct Point: Equatable {
        let total: Int
        /// A landing produced this survey — the dots, and the only cause the line can show.
        let landing: Bool
    }

    /// The points worth drawing, and nil when there is no line to draw.
    ///
    /// **Two is the floor.** One point is a dot, not a trend, and a chart captioned "33 → 33"
    /// over a single survey claims a history that does not exist yet. The cap keeps the newest
    /// window: a line that squeezed two years into 200 pixels shows nothing but its own ends.
    static func points(from trend: [RestructureStore.TrendPoint], limit: Int = 40) -> [Point]? {
        guard trend.count >= 2 else { return nil }
        return trend.suffix(limit).map { Point(total: $0.total, landing: $0.landing) }
    }

    /// The caption: the two ends, and what happened between them.
    ///
    /// Stated as the numbers themselves rather than a direction word, so it is checkable against
    /// the line above it — "fewer findings" would be a claim the reader has to take on trust, and
    /// an equal pair would make it false.
    static func caption(for points: [Point]) -> String? {
        guard let first = points.first, let last = points.last else { return nil }
        let landings = points.filter(\.landing).count
        let head: String
        if first.total == last.total {
            head = "\(last.total) findings, unchanged across \(points.count) surveys"
        } else {
            head = "\(first.total) → \(last.total) findings"
        }
        guard landings > 0 else { return head }
        return head + " · \(landings) landing\(landings == 1 ? "" : "s")"
    }

    /// The drawing's own geometry, as a rule: each point's position in a unit square where
    /// **y is the count** — 1 is the most findings this window held, 0 the fewest. The
    /// conventional reading, so a falling line means fewer findings and needs no legend.
    ///
    /// A rule rather than arithmetic inside the `Canvas` closure, because a chart drawn wrong is
    /// the kind of defect that looks plausible, and a `Canvas` body is not reachable from a test.
    static func unitPositions(_ points: [Point]) -> [CGPoint] {
        guard points.count > 1 else { return points.isEmpty ? [] : [CGPoint(x: 0, y: 0.5)] }
        let totals = points.map(\.total)
        let low = totals.min() ?? 0
        let high = totals.max() ?? 0
        // A flat line sits in the MIDDLE. Dividing by a zero span is the crash; drawing it at the
        // floor would be worse than a crash, because "as low as it has ever been" is a claim, and
        // the tree that produced it simply did not change.
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
