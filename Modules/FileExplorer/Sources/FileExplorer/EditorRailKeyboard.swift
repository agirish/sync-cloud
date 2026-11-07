import SwiftUI
import Design

/// The keyboard in the rail's Files and Outline lists: the list takes focus (a click on a row, or
/// Tab), then ↑ and ↓ move a cursor through its rows and ↩ opens the file, or goes to the heading,
/// under it.
///
/// A cursor, not the selection: in Edit opening a file is the selection, and a PDF or a long note
/// costs a read, so ↓ through a folder must not open every file it passes. The arrows move a mark
/// and ↩ commits, as in a menu. No chord switches tabs: ⌃⌘1–3 are the view modes', and nothing else
/// free reads as "Files" and "Outline".
enum EditorRailKeyboard {

    /// The row a press of ↑ (`by: -1`) or ↓ (`by: 1`) lands on, in drawn order.
    ///
    /// Stops at the ends rather than wrapping, as Finder's lists do. With no cursor yet, or one on a
    /// row the filter has since hidden, ↓ starts at the first row and ↑ at the last.
    static func step<ID: Equatable>(from current: ID?, in order: [ID], by delta: Int) -> ID? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return delta < 0 ? order.last : order.first
        }
        return order[min(max(index + delta, 0), order.count - 1)]
    }

    /// The arrow keys, as `onKeyPress` spells them.
    static let arrows: Set<KeyEquivalent> = [.upArrow, .downArrow]
    /// Both ⏎ keycaps: the main row's and the keypad's (`KeyEquivalent.keypadEnter`).
    static let commit: Set<KeyEquivalent> = [.return, .keypadEnter]

    /// The step a key takes: −1 for ↑, 1 for ↓.
    static func delta(for key: KeyEquivalent) -> Int { key == .upArrow ? -1 : 1 }
}

/// The ring a focused rail list wears, in the window's hue so the rail's focus reads as part of the
/// rail. Drawn, because the system's ring uses the system accent and hugs the scroll view's edge.
struct EditorRailFocusRing: View {
    let isOn: Bool
    let accent: Color

    static let lineWidth: CGFloat = 3
    static let opacity: Double = 0.45

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.control)
            .strokeBorder(accent.opacity(Self.opacity), lineWidth: Self.lineWidth)
            .padding(.horizontal, 2)
            .opacity(isOn ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The mark on the row the keyboard is on, while its list has focus: the row's own outline,
/// stroked in the hue. The open row already wears the fill, so this marks a row that is not it.
struct EditorRailKeyedRowMark: View {
    let isOn: Bool
    let accent: Color

    var body: some View {
        EditorFileRailView.rowOutline
            .strokeBorder(accent.opacity(0.8), lineWidth: 1.5)
            .opacity(isOn ? 1 : 0)
            .allowsHitTesting(false)
    }
}
