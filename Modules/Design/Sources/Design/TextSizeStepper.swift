import SwiftUI

/// `A  A  A` — the text size, steppable from wherever it is in the way.
///
/// **A stepper, not three stops.** The small `A` and the large `A` walk
/// ``FontSize/smaller`` and ``FontSize/bigger``, which move through
/// ``FontSize/selectablePercents`` — ten stops from 90% to 135% — so this control reaches every
/// size View ▸ Text Size ▸ Bigger/Smaller and the Readability slider can reach. A control hard-wired
/// to the four *named* sizes would strand the six percentages between them, and the app would have
/// two disagreeing ideas of where the stops are.
///
/// The middle cell shows the size the app is at, drawn at that size, so the control is its own
/// specimen. It says nothing about row spacing — that is the Appearance screen's tiles, which set
/// both together.
public struct TextSizeStepper: View {
    @Binding var size: FontSize
    /// Drawn in the chrome of a card, so the tint comes from the caller rather than the environment.
    var tint: Color

    public init(size: Binding<FontSize>, tint: Color = .accentColor) {
        self._size = size
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 2) {
            step(to: size.smaller, glyph: 10, label: "Smaller text")
            Text("A")
                .font(.system(size: currentGlyphSize, weight: .semibold))
                .foregroundStyle(tint)
                .frame(minWidth: 20)
                .accessibilityHidden(true)
            step(to: size.bigger, glyph: 15, label: "Bigger text")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text size")
        .accessibilityValue("\(size.percent) percent")
    }

    /// The middle `A`, drawn at the size it names — bounded so the chrome cannot grow with it.
    ///
    /// The range is the control's, not the app's: 90% through 135% of a 13pt glyph is 11.7 to 17.6,
    /// and the top of that is what the card's top bar was measured for.
    private var currentGlyphSize: CGFloat {
        13 * CGFloat(size.percent) / 100
    }

    @ViewBuilder
    private func step(to destination: FontSize?, glyph: CGFloat, label: String) -> some View {
        Button {
            if let destination { size = destination }
        } label: {
            Text("A")
                .font(.system(size: glyph, weight: .medium))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: tint))
        .disabled(destination == nil)
        .help(label)
        .accessibilityLabel(label)
    }
}
