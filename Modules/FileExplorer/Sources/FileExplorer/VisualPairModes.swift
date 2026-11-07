import AppKit
import Design
import SwiftUI

/// The three overlay modes — swipe, onion, difference — drawn from two rendered rasters.
///
/// One view for all three: the same two rasters in the same frame, differing only in which pixels
/// of the top one show, so the alignment can't drift between modes.
struct VisualPairModeView: View {

    let mode: ComparePairMode
    let left: CGImage?
    let right: CGImage?
    /// Whether the rasters are still coming or never will, so a file that can't be rendered
    /// doesn't spin for ever. See ``PairRenderOutcome``.
    let outcome: PairRenderOutcome
    /// The two file names, for a message that says which copy could not be read.
    let leftName: String
    let rightName: String
    /// The precomputed per-channel distance, for `.difference`. Passed in because the page strip's
    /// verdict comes from the same arithmetic, and computing it twice could disagree.
    let difference: CGImage?
    /// The app's accent, for the swipe divider and the changed-region outlines. Handed in because
    /// `Color.accentColor` here is the system accent, which ignores the hue the user picked.
    let accent: Color
    /// The changed regions in the difference raster's pixel coordinates, drawn as callouts over
    /// it. Empty when there is nothing to outline, including past ``ChangedRegionCallouts/maxDrawn``,
    /// which the mode bar's caption discloses.
    var changedRegions: [CGRect] = []
    @Binding var swipeFraction: Double
    @Binding var onionOpacity: Double

    /// The divider's position while it is being dragged. Writing the binding per pointer event
    /// would re-run the whole compare surface's body for a line only this view draws. Written back
    /// on release, so the position survives a mode switch.
    @State private var liveSwipeFraction: Double?

    /// The rasters wrapped for drawing, rebuilt only when a raster's identity changes. Wrapping in
    /// `body` would build new `NSImage`s on every frame of a divider drag.
    @State private var wrapped: (left: NSImage?, right: NSImage?, difference: NSImage?) = (nil, nil, nil)

    /// Which three rasters ``wrapped`` was built from. Identity, not equality: a `CGImage` is
    /// immutable, so the same object is the same picture.
    private struct RasterIdentity: Equatable {
        var left: ObjectIdentifier?
        var right: ObjectIdentifier?
        var difference: ObjectIdentifier?
    }

    private var rasterIdentity: RasterIdentity {
        RasterIdentity(left: left.map(ObjectIdentifier.init),
                       right: right.map(ObjectIdentifier.init),
                       difference: difference.map(ObjectIdentifier.init))
    }

    private func rewrap() {
        func wrap(_ image: CGImage?) -> NSImage? {
            image.map { NSImage(cgImage: $0, size: CGSize(width: $0.width, height: $0.height)) }
        }
        wrapped = (wrap(left), wrap(right), wrap(difference))
    }

    /// The divider's position as drawn: the live drag if there is one, else what was committed.
    private var shownSwipeFraction: Double { liveSwipeFraction ?? swipeFraction }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .textBackgroundColor)
                switch mode {
                case .sideBySide, .textDiff:
                    // Drawn by the typed pair viewer and the text pane; this view owns only the
                    // three modes that composite two rasters.
                    EmptyView()
                case .swipe:
                    swipe(in: proxy.size)
                case .onion:
                    onion
                case .difference:
                    differenceView(in: proxy.size)
                }
            }
            .contentShape(Rectangle())
        }
        .onChange(of: rasterIdentity, initial: true) { _, _ in rewrap() }
    }

    // MARK: Swipe

    /// The right page over the left, revealed left of the divider. The divider is the only
    /// control, so hand and eye stay in one place.
    @ViewBuilder
    private func swipe(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            page(left, side: .left)
            page(right, side: .right)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, size.width * shownSwipeFraction))
                }
            Rectangle()
                .fill(accent)
                .frame(width: 1)
                .position(x: size.width * shownSwipeFraction, y: size.height / 2)
                .allowsHitTesting(false)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    liveSwipeFraction = min(1, max(0, value.location.x / max(1, size.width)))
                }
                .onEnded { value in
                    swipeFraction = min(1, max(0, value.location.x / max(1, size.width)))
                    liveSwipeFraction = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Swipe compare")
        .accessibilityValue("\(Int(shownSwipeFraction * 100))% of the right copy shown")
        .help("Drag to move the divider — the right copy shows to the left of it")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: swipeFraction = min(1, swipeFraction + step)
            case .decrement: swipeFraction = max(0, swipeFraction - step)
            @unknown default: break
            }
        }
    }

    // MARK: Onion

    private var onion: some View {
        ZStack {
            page(left, side: .left)
            page(right, side: .right).opacity(onionOpacity)
        }
    }

    // MARK: Difference

    /// The distance image on black, with changed-region outlines.
    @ViewBuilder
    private func differenceView(in available: CGSize) -> some View {
        ZStack {
            Color.black
            if let difference, let drawable = wrapped.difference {
                let size = CGSize(width: difference.width, height: difference.height)
                Image(nsImage: drawable)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                // Callouts are laid out against the same fitted rect the image gets, recomputed
                // rather than inferred, so an outline sits on the change, not near it.
                ForEach(Array(ChangedRegionCallouts.drawable(regions: changedRegions,
                                                             imageSize: size,
                                                             in: available).enumerated()),
                        id: \.offset) { _, rect in
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(accent.opacity(0.9), lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            } else if let message = differenceMessage {
                // Light on black, the ground the picture would have had.
                unrenderable(message, onDark: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        // One element: the outlines restate the caption's finding, and a dozen unlabelled
        // rectangles would read worse than the sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Difference")
        .accessibilityValue(ChangedRegionCallouts.caption(regionCount: changedRegions.count)
                            ?? "No visible difference")
    }

    /// The line the difference view draws instead of a picture, or nil while it should wait.
    private var differenceMessage: String? {
        outcome.differenceMessage(leftName: leftName, rightName: rightName)
    }

    @ViewBuilder
    private func page(_ image: CGImage?, side: PairSide) -> some View {
        if image != nil, let drawable = side == .left ? wrapped.left : wrapped.right {
            Image(nsImage: drawable)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch outcome.fallback(for: side, name: side == .left ? leftName : rightName) {
            case .spinner:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .message(let text):
                unrenderable(text, onDark: mode == .difference)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The one shape a "this cannot be drawn" message takes here.
    private func unrenderable(_ text: String, onDark: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.large)
            Text(text)
                .scaledFont(.system(size: 11.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(onDark ? AnyShapeStyle(Color.white.opacity(0.75))
                                : AnyShapeStyle(HierarchicalShapeStyle.secondary))
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The page strip

/// One mark per page, shaped and coloured by what the diff found, and no mark at all until it has
/// found something.
///
/// A pending page has no dot. The strip reads as a map of where the documents differ, so a mark
/// before its comparison runs would claim "checked, and unremarkable" on a surface whose next
/// button trashes a file. The number alone is the resting state; `PageDiffState.dot` owns the rule.
struct PageStrip: View, Equatable {

    let pairing: PagePairing
    let states: [Int: PageDiffState]
    let current: Int
    let accent: Color
    /// Whether a ↑/↓ search is walking pages now. The caption says so, or a key whose next
    /// difference is far away would look dead until it lands.
    var isSearching: Bool = false
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Page")
                .scaledFont(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy, because there is one chip per page and the scroll view shows a dozen.
                LazyHStack(spacing: 3) {
                    // `Array(0..<n)`, not `0..<n`: the range `ForEach` is the constant-range
                    // initializer, and this length changes when the page counts land.
                    ForEach(Array(0..<pairing.stripLength), id: \.self) { index in
                        chip(index)
                    }
                }
                .padding(.vertical, 1)
            }
            // "of N compared", never "of N pages": only visited and searched pages have verdicts,
            // and a count against the document's length would claim all of it was checked.
            if let counted = PageDifferenceStepper.caption(states: states,
                                                           stripLength: pairing.stripLength) {
                Text(isSearching ? "still comparing…" : counted)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if let note = pairing.lengthNote {
                Text(note)
                    .scaledFont(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
            }
        }
    }

    /// One page. The dot is drawn only once its comparison has resolved, so in side-by-side mode,
    /// where no diff runs, the strip shows numbers alone.
    private func chip(_ index: Int) -> some View {
        let state = states[index] ?? .pending
        let pinned = pairing.leftIsPinned(at: index) || pairing.rightIsPinned(at: index)
        let isCurrent = index == current
        return Button { onSelect(index) } label: {
            HStack(spacing: 4) {
                Text("\(index + 1)")
                    .scaledFont(.system(size: 10.5, weight: isCurrent ? .semibold : .regular,
                                        design: .monospaced))
                    // Label-colour words; the accent is the current chip's wash.
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                if let dot = state.dot {
                    // Shape and colour both, from the meaning — see `PageDiffState.Dot.symbol`.
                    Image(systemName: dot.symbol)
                        .scaledFont(.system(size: 7, weight: .bold))
                        .foregroundStyle(dot.tint)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(isCurrent ? accent.opacity(0.14) : Color.clear)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help(for: state, pinned: pinned, index: index))
        .accessibilityLabel("Page \(index + 1)")
        .accessibilityValue(help(for: state, pinned: pinned, index: index))
    }

    /// Compared on everything it draws, so `.equatable()` can hold a redraw off. The closure is
    /// left out: it can't be compared, and the one call site's `{ page = $0 }` captures a `@State`
    /// projection that doesn't move.
    /// `nonisolated`, as `Equatable` requires; safe because every member read here is an
    /// immutable value of a Sendable type.
    nonisolated static func == (lhs: PageStrip, rhs: PageStrip) -> Bool {
        lhs.pairing == rhs.pairing && lhs.states == rhs.states && lhs.current == rhs.current
            && lhs.accent == rhs.accent && lhs.isSearching == rhs.isSearching
    }

    /// The dot's meaning in words, the whole vocabulary in one place, so colour and sentence can't
    /// drift and a reader who can't tell green from orange gets the same answer.
    private func help(for state: PageDiffState, pinned: Bool, index: Int) -> String {
        if pinned {
            return "Page \(index + 1) exists on one side only — the shorter document is showing its last page."
        }
        switch state {
        case .pending: return "Not compared yet"
        case .same: return "No visible difference"
        case .changed(let fraction):
            let percent = max(0.1, fraction * 100)
            return String(format: "About %.1f%% of the page differs", percent)
        case .oneSided: return "Only one side has this page"
        case .unrenderable: return "This page couldn’t be rendered on one side"
        }
    }
}

extension PageDiffState.Dot {
    /// The severity table rather than literal hues, so a strip mark means what the same colour
    /// means everywhere else in the app.
    var tint: Color {
        switch self {
        case .same: return SemanticColor.success
        case .changed: return SemanticColor.warning
        case .oneSided: return SemanticColor.info
        case .unrenderable: return SemanticColor.error
        }
    }
}
