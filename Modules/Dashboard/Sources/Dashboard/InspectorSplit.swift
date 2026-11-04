import SwiftUI

/// The Info inspector's two halves — the picture over the details — with a bar between them to
/// drag (TE318 B).
///
/// `fraction` is the picture's share of the room, written only when a drag ends, so the stored
/// preference changes once per drag rather than once per frame. Within `foldMargin` of either end a
/// drag snaps shut: dragged to the top, the picture folds away and is not built at all (no Quick
/// Look extension for a preview nobody can see); dragged to the bottom, the details do. A
/// double-click puts it back at `defaultFraction`.
struct InspectorSplit<Upper: View, Lower: View>: View {
    @Binding var fraction: Double
    let defaultFraction: Double
    @ViewBuilder let upper: Upper
    @ViewBuilder let lower: Lower

    /// The live share while a drag is in flight; nil at rest. Gesture state, so a drag the system
    /// cancels — with no `onEnded` — puts it back by itself rather than leaving the split stuck at the
    /// drag's share. The drag is measured from the stored share, which does not move until it ends.
    @GestureState private var dragFraction: Double?

    static var handleHeight: CGFloat { 9 }
    static var foldMargin: Double { 0.12 }

    /// A share as the split draws it: snapped shut near either end, clamped to 0…1 otherwise.
    static func settled(_ share: Double) -> Double {
        let clamped = min(1, max(0, share))
        if clamped < foldMargin { return 0 }
        if clamped > 1 - foldMargin { return 1 }
        return clamped
    }

    /// Where a drag of `translation` points from `anchor` lands, in a split with `room` points to share.
    static func dragged(anchor: Double, translation: CGFloat, room: CGFloat) -> Double {
        guard room > 0 else { return anchor }
        return settled(anchor + Double(translation / room))
    }

    /// One VoiceOver step from `share`, up (`grows`) or down. A step out of a folded end lands on the
    /// first share that stays open, and a step toward an end stops at the edge of its fold — the
    /// next step is the one that folds. A plain 5% step would snap straight back shut out of a fold,
    /// and fold a half away entirely from anywhere within 5% of its margin.
    static func stepped(_ share: Double, grows: Bool) -> Double {
        let current = settled(share)
        let low = foldMargin, high = 1 - foldMargin
        if grows {
            if current < low { return low }
            if current >= high { return 1 }
            return min(current + 0.05, high)
        }
        if current > high { return high }
        if current <= low { return 0 }
        return max(current - 0.05, low)
    }

    var body: some View {
        GeometryReader { geo in
            let room = max(0, geo.size.height - Self.handleHeight)
            let share = dragFraction ?? Self.settled(fraction)
            let upperHeight = (room * share).rounded()
            VStack(spacing: 0) {
                if upperHeight >= 1 {
                    upper
                        .frame(maxWidth: .infinity)
                        .frame(height: upperHeight)
                        .clipped()
                }
                handle(room: room)
                if room - upperHeight >= 1 {
                    lower
                        .frame(maxWidth: .infinity)
                        .frame(height: room - upperHeight)
                        .clipped()
                }
            }
        }
    }

    private func handle(room: CGFloat) -> some View {
        ZStack {
            Divider()
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.handleHeight)
        .contentShape(Rectangle())
        .pointerStyle(.rowResize)
        // `.global`, as the inspector's own width handle reads it: this bar moves as the picture
        // grows, so in its own frame the translation would feed back on itself.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($dragFraction) { value, state, _ in
                    state = Self.dragged(anchor: Self.settled(fraction), translation: value.translation.height,
                                         room: room)
                }
                .onEnded { value in
                    fraction = Self.dragged(anchor: Self.settled(fraction), translation: value.translation.height,
                                            room: room)
                }
        )
        .onTapGesture(count: 2) { fraction = defaultFraction }
        .help("Drag to resize the preview. Double-click to reset it.")
        .accessibilityElement()
        .accessibilityLabel("Preview size")
        .accessibilityValue("\(Int((Self.settled(fraction) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: fraction = Self.stepped(fraction, grows: true)
            case .decrement: fraction = Self.stepped(fraction, grows: false)
            @unknown default: break
            }
        }
    }
}
