import AppKit
import Design
import SwiftUI

/// The three overlay modes — swipe, onion, difference — drawn from two rendered rasters.
///
/// One view for all three because they are one picture with three reveals: the same two rasters,
/// aligned in the same frame, differing only in what decides which pixels of the top one show. A
/// view per mode would give three chances for the alignment to drift apart.
struct VisualPairModeView: View {

    let mode: ComparePairMode
    let left: CGImage?
    let right: CGImage?
    /// Whether the rasters are still coming or are never going to. Without it a pane with no image
    /// spins for ever on a file that cannot be rendered — see ``PairRenderOutcome``.
    let outcome: PairRenderOutcome
    /// The two file names, for a message that says which copy could not be read.
    let leftName: String
    let rightName: String
    /// The precomputed per-channel distance, for `.difference`. Passed in rather than computed
    /// here: it is the same arithmetic the page strip's verdict comes from, and computing it twice
    /// is how two numbers about one page start disagreeing.
    let difference: CGImage?
    /// The changed regions in the difference raster's pixel coordinates, drawn as callouts over
    /// it. Empty where there is nothing to outline — including the over-the-cap case, which
    /// ``ChangedRegionCallouts/maxDrawn`` decides and the mode bar's caption discloses.
    var changedRegions: [CGRect] = []
    @Binding var swipeFraction: Double
    @Binding var onionOpacity: Double

    /// The divider's position WHILE it is being dragged.
    ///
    /// **The committed fraction lives in the surface, and this is the frame-by-frame one.** A drag
    /// that wrote straight to the binding re-ran the whole compare surface's body on every pointer
    /// event — its facts strip, its mode bar, its verdict — for a line that only this view draws.
    /// Written back on release, so the position still survives a mode switch, which is why it is
    /// held up there in the first place (the same reason the PDF zoom is).
    @State private var liveSwipeFraction: Double?

    /// The rasters wrapped for drawing, rebuilt only when a raster actually arrives.
    ///
    /// **`Image(nsImage: NSImage(cgImage:size:))` in a `body` is a new wrapper per render**, and
    /// this body re-runs on every frame of a divider drag and on every publish of the manager the
    /// host observes. The `CGImage`s themselves are immutable and shared; only the wrapper was
    /// being rebuilt, and only their identity decides when it has to be.
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
                    // Drawn by the typed pair viewer and the text pane respectively — this view
                    // owns only the three modes that composite two rasters.
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

    /// The right page over the left, revealed left-of-divider. The divider is dragged, and it is
    /// also the only control: a swipe with a slider somewhere else would put the reader's hand and
    /// their eye in two places.
    @ViewBuilder
    private func swipe(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            page(left, side: .left)
            page(right, side: .right)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, size.width * shownSwipeFraction))
                }
            Rectangle()
                .fill(Color.accentColor)
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

    /// The distance image on black, plus the caveat. **The caveat is part of the mode, not a
    /// tooltip**: two scans of the same sheet of paper glow everywhere from scanner noise, and a
    /// reader who has not been told that reads the glow as content.
    @ViewBuilder
    private func differenceView(in available: CGSize) -> some View {
        ZStack {
            Color.black
            if let difference, let drawable = wrapped.difference {
                let size = CGSize(width: difference.width, height: difference.height)
                Image(nsImage: drawable)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                // **The callouts are laid out against the same fitted rect the image gets**,
                // recomputed rather than inferred from a container — an outline that is plausibly
                // near the change rather than on it looks like a working feature.
                ForEach(Array(ChangedRegionCallouts.drawable(regions: changedRegions,
                                                             imageSize: size,
                                                             in: available).enumerated()),
                        id: \.offset) { _, rect in
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            } else if let message = differenceMessage {
                // Light on black, like the mode itself — a message here is read against the same
                // ground the picture would have been.
                unrenderable(message, onDark: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        // One element: the outlines are a visual index of the same finding the caption states, and
        // reading out a dozen unlabelled rectangles would be worse than the sentence.
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

/// One dot per page, coloured by what the diff found — and no dot at all until it has found
/// something.
///
/// **A page with no dot is a page nothing has claimed anything about.** The strip is read as a map
/// of where the two documents differ, so a marker that appears before its comparison has run reads
/// as "checked, and unremarkable" — a claim nobody made, on a surface whose next button trashes a
/// file. An earlier design gave `.pending` a grey dot; the number alone turned out to be the
/// honest resting state, and a dot appearing is then a real event. `PageDiffState.dot` is where
/// that rule lives.
struct PageStrip: View, Equatable {

    let pairing: PagePairing
    let states: [Int: PageDiffState]
    let current: Int
    let accent: Color
    /// Whether a ↑/↓ search is walking pages right now. The caption says so, because on a document
    /// whose next difference is twenty pages away the key otherwise looks dead until it lands.
    var isSearching: Bool = false
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Page")
                .scaledFont(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                // **Lazy, because the strip is one chip per PAGE.** A 300-page report built 300
                // buttons — each with its own label, capsule and help string — on every render of
                // the surface, for the dozen the scroll view can show.
                LazyHStack(spacing: 3) {
                    // `Array(0..<n)`, not `0..<n`: SwiftUI's range `ForEach` is the CONSTANT-range
                    // initializer, and a strip whose length changes when the page counts land
                    // would be re-identifying a range it promised would not move.
                    ForEach(Array(0..<pairing.stripLength), id: \.self) { index in
                        chip(index)
                    }
                }
                .padding(.vertical, 1)
            }
            // How much of the pair has actually been judged — "of N compared", never "of N
            // pages": only visited and searched pages have verdicts, and a count phrased against
            // the document's length would claim the whole of it had been checked. The same
            // over-claim the strip refuses when it withholds a dot from a pending page.
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

    /// One page.
    ///
    /// **The dot is drawn only once its comparison has resolved.** A grey dot under every page is
    /// what the strip looked like in side-by-side mode, where no diff is computed at all — a row
    /// of markers that mean nothing, which is worse than no markers: they read as "checked, and
    /// unremarkable". The number alone is the honest resting state, and a dot appearing is then a
    /// real event.
    private func chip(_ index: Int) -> some View {
        let state = states[index] ?? .pending
        let pinned = pairing.leftIsPinned(at: index) || pairing.rightIsPinned(at: index)
        let isCurrent = index == current
        return Button { onSelect(index) } label: {
            HStack(spacing: 4) {
                Text("\(index + 1)")
                    .scaledFont(.system(size: 10.5, weight: isCurrent ? .semibold : .regular,
                                        design: .monospaced))
                    .foregroundStyle(isCurrent ? accent : Color.secondary)
                if let dot = state.dot {
                    Circle().fill(color(for: dot)).frame(width: 5, height: 5)
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

    /// The paint for a dot's meaning. Whether there IS a dot is `PageDiffState.dot`'s decision,
    /// where a test can call it; this only colours what that returns.
    private func color(for dot: PageDiffState.Dot) -> Color {
        switch dot {
        case .same: return .green
        case .changed: return .orange
        case .oneSided: return .blue
        case .unrenderable: return .red.opacity(0.6)
        }
    }

    /// Compared on everything it DRAWS, so `.equatable()` can hold a redraw off.
    ///
    /// **The closure is the one member left out, and it has to be.** A `(Int) -> Void` is not
    /// comparable at all, and this one is `{ page = $0 }` written at the single call site — it
    /// closes over a `@State` projection that does not move. Everything the strip renders from is
    /// above it, so a difference the reader could see is a difference this reports.
    /// `nonisolated`, because `Equatable` is: a `View` is `@MainActor`, and every member read here
    /// is an immutable `let` of a Sendable type, which is what makes that safe to say.
    nonisolated static func == (lhs: PageStrip, rhs: PageStrip) -> Bool {
        lhs.pairing == rhs.pairing && lhs.states == rhs.states && lhs.current == rhs.current
            && lhs.accent == rhs.accent && lhs.isSearching == rhs.isSearching
    }

    /// The dot's meaning in words — the whole vocabulary in one place, so the colour and the
    /// sentence cannot drift, and so a reader who cannot separate green from orange gets the same
    /// answer.
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
        case .unrenderable: return "This page couldn't be rendered on one side"
        }
    }
}
