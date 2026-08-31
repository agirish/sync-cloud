import SwiftUI

/// Which edge or corner of a floating card a drag is pulling.
///
/// **Extracted from the Help card so a second resizable overlay does not re-derive it.** The
/// direction table below is the whole rule — `.leading` grows the card when dragged LEFT, which is
/// the sign error every hand-rolled resize makes once — and two copies of a sign table can only
/// agree by luck. `HelpCardGrip` is now a thin forward to this.
public enum ResizableCardGrip: CaseIterable, Sendable {
    case top, bottom, leading, trailing
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// Whether this grip moves the card's width, and in which direction a positive drag takes it.
    /// `0` for the two grips that only move height.
    public var horizontal: CGFloat {
        switch self {
        case .trailing, .topTrailing, .bottomTrailing: return 1
        case .leading, .topLeading, .bottomLeading: return -1
        case .top, .bottom: return 0
        }
    }

    /// The same for height; `0` for the two that only move width.
    public var vertical: CGFloat {
        switch self {
        case .bottom, .bottomLeading, .bottomTrailing: return 1
        case .top, .topLeading, .topTrailing: return -1
        case .leading, .trailing: return 0
        }
    }

    /// Where in the card's bounds the grip sits.
    public var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// The pointer macOS shows over this grip.
    public var pointer: FrameResizePosition {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    /// True for the four diagonal grips, which take a square hit area rather than a strip.
    public var isCorner: Bool { horizontal != 0 && vertical != 0 }
}

/// The arithmetic behind resizing a CENTRED floating card.
///
/// **Pure, because the views around it cannot be built in a test.** A clamp written inline in a
/// `View` with `@State` and `@AppStorage` is a clamp no test can flip — which is why the Help
/// card's version was extracted, and why the second resizable overlay uses this one rather than a
/// copy of it.
public enum ResizableCardSize {

    /// The new size for a drag of `translation` that started with the card at `start`.
    ///
    /// **The translation is doubled, and that is what keeps the pointer on the grip.** The card is
    /// centred in its overlay, so half of any growth goes to each side: to move the trailing edge
    /// 10pt right, the width has to grow 20. Adding the translation once would leave the edge
    /// drifting at half the pointer's speed, which reads as lag rather than as a rule.
    public static func resized(from start: CGSize, by translation: CGSize,
                               grip: ResizableCardGrip,
                               minimum: CGSize, within available: CGSize) -> CGSize {
        let wanted = CGSize(width: start.width + grip.horizontal * translation.width * 2,
                            height: start.height + grip.vertical * translation.height * 2)
        return clamped(wanted, minimum: minimum, within: available)
    }

    /// A size held to the floor and to what the window can actually show.
    ///
    /// **The `max(minimum, available)` is live, not defensive padding.** `GeometryReader` reports
    /// `.zero` on its first layout pass, and clamping straight to `available` there would collapse
    /// the card to nothing on the frame it appears. Preferring the floor when the window is
    /// smaller than the card also fails in the safer direction: an overflowing card is legible and
    /// a 0×0 one is gone.
    public static func clamped(_ size: CGSize, minimum: CGSize,
                               within available: CGSize) -> CGSize {
        CGSize(width: min(max(minimum.width, size.width), max(minimum.width, available.width)),
               height: min(max(minimum.height, size.height), max(minimum.height, available.height)))
    }
}

/// The eight invisible grips laid over a card's edges and corners.
///
/// **Corners after edges, deliberately.** An edge strip runs the card's whole side, so it sits
/// under both corners at that end; declaring the corners last puts them on top, where a diagonal
/// drag expects to find them.
///
/// **The strips sit OVER the content, so anything they cover stops being clickable.** 6pt strips
/// and 14pt corners here, against the compare surface's 16pt horizontal / 12pt vertical control
/// insets — the close button and the mode picker both clear them. Thickening either without
/// re-measuring those insets would take a control with it.
public struct ResizableCardGrips: View {

    private let onDrag: (CGSize, ResizableCardGrip) -> Void
    private let onCommit: () -> Void
    private let edgeThickness: CGFloat
    private let cornerSide: CGFloat

    public init(edgeThickness: CGFloat = 6, cornerSide: CGFloat = 14,
                onDrag: @escaping (CGSize, ResizableCardGrip) -> Void,
                onCommit: @escaping () -> Void) {
        self.edgeThickness = edgeThickness
        self.cornerSide = cornerSide
        self.onDrag = onDrag
        self.onCommit = onCommit
    }

    public var body: some View {
        ZStack {
            ForEach(Array(ResizableCardGrip.allCases.filter { !$0.isCorner }.enumerated()),
                    id: \.offset) { grip($0.element) }
            ForEach(Array(ResizableCardGrip.allCases.filter(\.isCorner).enumerated()),
                    id: \.offset) { grip($0.element) }
        }
        // The grips are a manipulation of the card, not content in it — VoiceOver reads the card.
        .accessibilityHidden(true)
    }

    private func grip(_ grip: ResizableCardGrip) -> some View {
        Color.clear
            .frame(width: grip.horizontal == 0 ? nil : (grip.isCorner ? cornerSide : edgeThickness),
                   height: grip.vertical == 0 ? nil : (grip.isCorner ? cornerSide : edgeThickness))
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: grip.pointer))
            .gesture(
                // **NEVER `.local`.** The strip moves as the card it resizes grows, so in its own
                // space the gesture feeds back on itself and the drag stutters. Every other
                // resize in this app uses the global space for the same reason.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation, grip) }
                    .onEnded { _ in onCommit() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: grip.alignment)
    }
}
