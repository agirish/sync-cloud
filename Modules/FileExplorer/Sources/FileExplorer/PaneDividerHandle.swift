import AppKit
import SwiftUI

/// One hairline and the 9pt strip that makes it grabbable: the chrome a pane divider wears. Generic
/// over its gesture; the column dividers wear it, and so does a pane's Info column, so the two read
/// as one kind of edge.
public struct PaneDividerHandle<G: Gesture>: View {
    let gesture: G

    public init(gesture: G) {
        self.gesture = gesture
    }

    public var body: some View {
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
