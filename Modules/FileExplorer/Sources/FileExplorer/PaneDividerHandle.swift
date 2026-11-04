import AppKit
import SwiftUI

/// One hairline and the 9pt strip that makes it grabbable — the chrome every pane divider wears.
///
/// A view of its own, with the gesture as its generic parameter, from when the pane's preview drew
/// the same seam on its leading edge. The column dividers are its one caller now.
struct PaneDividerHandle<G: Gesture>: View {
    let gesture: G

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(gesture)
            }
    }
}
