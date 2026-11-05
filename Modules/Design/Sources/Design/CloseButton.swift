import SwiftUI

/// The one dismiss affordance: a plain secondary xmark, semibold at 11pt, with a 26x26 hit
/// target. Overlays, banners and inspectors all close through this so the glyph and target can't
/// drift per surface. Callers attach their own `.help`, `.accessibilityLabel` and
/// `.keyboardShortcut`, which are per-site.
public struct CloseButton: View {
    private let action: () -> Void
    private let chromeGlass: Bool

    /// - Parameter chromeGlass: whether the button wears a bar button's glass circle in Frosted and
    ///   Clear (`ChromeGlass`). True in a panel's title row; false where the × is not a bar button,
    ///   such as the operation banner's, whose neighbours wear none.
    public init(chromeGlass: Bool = true, action: @escaping () -> Void) {
        self.chromeGlass = chromeGlass
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
        // Frosted and Clear: a glass circle like every bar button (`ChromeGlass`), with a round
        // hover wash. `.hoverAffordance(.glyph)` at Solid, and everywhere when `chromeGlass` is
        // off.
        .chromeGlassGlyphButton(enabled: chromeGlass)
        // No `accessibilityLabel` here, deliberately: a generic "Close" inside would sit under the
        // callers' specific names ("Close Help", "Close notification"), and which one VoiceOver
        // reads would depend on how SwiftUI resolves a label at both depths.
    }
}

public extension View {
    /// The one search-field chrome: a continuous rounded rect washed quaternary at 0.6. Settings
    /// and Help wrap their magnifier + plain TextField rows in it so both read as one control.
    func searchFieldSurface() -> some View {
        background { SearchFieldWash() }
    }
}

/// The search-field wash as a view: the one definition `searchFieldSurface()` and the expanding
/// field's at-rest surface both draw, so they can't drift.
struct SearchFieldWash: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(.quaternary.opacity(0.6))
    }
}
