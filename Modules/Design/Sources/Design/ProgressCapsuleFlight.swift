import SwiftUI

/// **A capsule message going into Activity** — the fold, the flight and the landing's timing, and
/// the path the ring takes from the capsule to the toolbar's Activity button.
///
/// A message the capsule shows was left there because the reader had moved on (Run Room CG), so
/// when it goes it used to just vanish, from a part of the window nobody was looking at. Recent
/// kept it all along; the flight shows where it went. Pure here, so the path is testable without a
/// window — the app draws it in a panel over its own window (`CapsuleFlight`), because the capsule
/// and the button both live in AppKit's toolbar, where nothing in the window's content can draw.
public enum ProgressCapsuleFlight {
    /// Words and buttons fade and the capsule narrows to its ring.
    public static let foldDuration: Double = 0.22
    /// Ring to button.
    public static let travelDuration: Double = 0.48
    /// The button's bump as the ring arrives.
    public static let landDuration: Double = 0.32

    public static let foldAnimation = Animation.timingCurve(0.4, 0, 0.6, 1, duration: foldDuration)
    public static let travelAnimation = Animation.timingCurve(0.45, 0, 0.2, 1, duration: travelDuration)

    /// How far below the lower of the two ends the path dips, in points. A straight line along the
    /// toolbar would run through every item between the two; a shallow swoop under them reads as
    /// the ring going somewhere rather than sliding along a rail.
    public static let dip: CGFloat = 34
    /// The ring's size at the button, against its size in the capsule.
    public static let endScale: CGFloat = 0.6
    /// The share of the flight after which the ring fades into the button.
    public static let fadeFrom: Double = 0.92

    /// The ring's centre at `t` (0…1) of the flight, in a top-left coordinate space: a quadratic
    /// curve whose control point sits a little past halfway across and ``dip`` below.
    public static func point(at t: Double, from: CGPoint, to: CGPoint) -> CGPoint {
        let t = min(max(t, 0), 1)
        let control = CGPoint(x: from.x + (to.x - from.x) * 0.55, y: max(from.y, to.y) + dip)
        let u = 1 - t
        return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                       y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
    }

    public static func scale(at t: Double) -> CGFloat {
        1 - (1 - endScale) * CGFloat(min(max(t, 0), 1))
    }

    public static func opacity(at t: Double) -> Double {
        t <= fadeFrom ? 1 : max(0, 1 - (t - fadeFrom) / (1 - fadeFrom))
    }
}

/// The ring in flight, drawn in a space whose origin is the top-left of whatever hosts it.
public struct ProgressCapsuleFlightView: View {
    let from: CGPoint
    let to: CGPoint
    let weight: ProgressCapsuleMessage.Weight

    @State private var progress: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(from: CGPoint, to: CGPoint, weight: ProgressCapsuleMessage.Weight) {
        self.from = from
        self.to = to
        self.weight = weight
    }

    public var body: some View {
        Image(systemName: ProgressCapsule.symbol(weight))
            .font(.system(size: 14))
            .foregroundStyle(ProgressCapsule.tint(weight))
            .frame(width: ProgressCapsuleMetrics.ringSide, height: ProgressCapsuleMetrics.ringSide)
            .modifier(AlongFlight(progress: progress, from: from, to: to))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withDesignAnimation(ProgressCapsuleFlight.travelAnimation, reduceMotion: reduceMotion) {
                    progress = 1
                }
            }
    }
}

/// Places the ring at `progress` of the flight. Animatable, so the animation interpolates the
/// progress and the curve is followed — interpolating a position would cut straight across.
private struct AlongFlight: ViewModifier, Animatable {
    var progress: Double
    let from: CGPoint
    let to: CGPoint

    // `nonisolated` because `Animatable` is not main-actor; `progress` is a `Double` held by value,
    // so reading and writing it from there is safe.
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = ProgressCapsuleFlight.point(at: progress, from: from, to: to)
        let side = ProgressCapsuleMetrics.ringSide
        return content
            .scaleEffect(ProgressCapsuleFlight.scale(at: progress))
            .opacity(ProgressCapsuleFlight.opacity(at: progress))
            .offset(x: p.x - side / 2, y: p.y - side / 2)
    }
}
