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

    /// The live share while a drag is in flight; nil at rest.
    @State private var dragFraction: Double?
    /// The share the drag started from, held so the translation is always measured from one place.
    @State private var dragAnchor: Double?

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
                .onChanged { value in
                    let anchor = dragAnchor ?? Self.settled(fraction)
                    if dragAnchor == nil { dragAnchor = anchor }
                    dragFraction = Self.dragged(anchor: anchor, translation: value.translation.height,
                                                room: room)
                }
                .onEnded { _ in
                    if let dragFraction { fraction = dragFraction }
                    dragFraction = nil
                    dragAnchor = nil
                }
        )
        .onTapGesture(count: 2) { fraction = defaultFraction }
        .help("Drag to resize the preview. Double-click to reset it.")
        .accessibilityElement()
        .accessibilityLabel("Preview size")
        .accessibilityValue("\(Int((Self.settled(fraction) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            // A step out of a folded end lands on the first share that stays open; a plain 5%
            // step from 0 would snap straight back shut.
            case .increment:
                fraction = fraction < Self.foldMargin ? Self.foldMargin : Self.settled(fraction + 0.05)
            case .decrement:
                fraction = fraction > 1 - Self.foldMargin ? 1 - Self.foldMargin : Self.settled(fraction - 0.05)
            @unknown default: break
            }
        }
    }
}
