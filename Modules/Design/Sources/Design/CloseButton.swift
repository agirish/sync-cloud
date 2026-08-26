import SwiftUI

/// The one dismiss affordance (C4): a plain secondary xmark glyph, semibold at 11pt, with a
/// comfortable 26x26 hit target. Overlays, banners, and inspectors all close through this so
/// the glyph weight and target size can't drift per surface. Callers attach their own
/// `.help`, `.accessibilityLabel`, and `.keyboardShortcut` — those are per-site semantics.
public struct CloseButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .scaledFont(.system(size: 11, weight: .semibold))
                .hoverInk()
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.glyph))
        // **No `accessibilityLabel` here, deliberately** — see the type's doc comment. A generic
        // "Close" inside this view would sit under the specific names two call sites already give
        // it ("Close Help", "Close notification"), and which of the two a VoiceOver user hears
        // then depends on how SwiftUI resolves a label applied at both depths. That is not
        // something to leave to chance for the sake of naming a control the callers already name;
        // the four sites carry their own, which is also how each gets to say what it closes.
    }
}

public extension View {
    /// The one search-field chrome (C4): a radius-8 continuous rect washed quaternary at 0.6.
    /// Settings and Help wrap their magnifier + plain TextField rows in this so the two search
    /// boxes read as the same control.
    func searchFieldSurface() -> some View {
        background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
