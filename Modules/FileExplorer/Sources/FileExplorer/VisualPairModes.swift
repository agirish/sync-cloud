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
    /// The precomputed per-channel distance, for `.difference`. Passed in rather than computed
    /// here: it is the same arithmetic the page strip's verdict comes from, and computing it twice
    /// is how two numbers about one page start disagreeing.
    let difference: CGImage?
    @Binding var swipeFraction: Double
    @Binding var onionOpacity: Double

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
                    differenceView
                }
            }
            .contentShape(Rectangle())
        }
    }

    // MARK: Swipe

    /// The right page over the left, revealed left-of-divider. The divider is dragged, and it is
    /// also the only control: a swipe with a slider somewhere else would put the reader's hand and
    /// their eye in two places.
    @ViewBuilder
    private func swipe(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            page(left)
            page(right)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, size.width * swipeFraction))
                }
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1)
                .position(x: size.width * swipeFraction, y: size.height / 2)
                .allowsHitTesting(false)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    swipeFraction = min(1, max(0, value.location.x / max(1, size.width)))
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Swipe compare")
        .accessibilityValue("\(Int(swipeFraction * 100))% of the right copy shown")
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
            page(left)
            page(right).opacity(onionOpacity)
        }
    }

    // MARK: Difference

    /// The distance image on black, plus the caveat. **The caveat is part of the mode, not a
    /// tooltip**: two scans of the same sheet of paper glow everywhere from scanner noise, and a
    /// reader who has not been told that reads the glow as content.
    @ViewBuilder
    private var differenceView: some View {
        ZStack {
            Color.black
            if let difference {
                Image(nsImage: NSImage(cgImage: difference,
                                       size: CGSize(width: difference.width,
                                                    height: difference.height)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func page(_ image: CGImage?) -> some View {
        if let image {
            Image(nsImage: NSImage(cgImage: image,
                                   size: CGSize(width: image.width, height: image.height)))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

// MARK: - The page strip

/// One dot per page, coloured by what the diff found — and grey until it has found anything.
///
/// **A dot that is grey while its render is queued is the point.** The strip is read as a map of
/// where the two documents differ, so a dot that renders "same" before its comparison has run is a
/// claim nobody made, on a surface whose next button trashes a file. `.pending` is its own state
/// and its own colour.
struct PageStrip: View {

    let pairing: PagePairing
    let states: [Int: PageDiffState]
    let current: Int
    let accent: Color
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Page")
                .scaledFont(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    // `Array(0..<n)`, not `0..<n`: SwiftUI's range `ForEach` is the CONSTANT-range
                    // initializer, and a strip whose length changes when the page counts land
                    // would be re-identifying a range it promised would not move.
                    ForEach(Array(0..<pairing.stripLength), id: \.self) { index in
                        chip(index)
                    }
                }
                .padding(.vertical, 1)
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
