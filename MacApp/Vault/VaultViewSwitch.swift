import AppKit
import Design
import SwiftUI
import Sync

/// Cards, List or People: a segmented control whose segments carry a symbol and a word each.
///
/// SwiftUI's segmented `Picker` gives a segment its words or its image, never both: a `Label`
/// loses its icon whatever its style, and an image inside the words comes out as an empty
/// attachment box (checked against the `NSSegmentedControl` it builds). So this is that control,
/// built here with both, which keeps AppKit's keyboard and VoiceOver behaviour; the selection takes
/// the same accent `accentedSegments` gives every other segmented picker.
struct VaultViewSwitch: NSViewRepresentable {
    @Binding var layout: VaultLayout
    let hue: LiquidGlassHue

    static let segments: [(layout: VaultLayout, title: String, symbol: String, help: String)] = [
        (.cards, "Cards", "square.grid.2x2", "One card per kind of ID"),
        (.list, "List", "list.bullet", "Every ID in one list"),
        (.people, "People", "person.2", "Each person’s IDs together, with their name as documents print it"),
    ]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = Self.segments.count
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        control.controlSize = .small
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        for (index, segment) in Self.segments.enumerated() {
            control.setLabel(segment.title, forSegment: index)
            control.setImage(NSImage(systemSymbolName: segment.symbol, accessibilityDescription: nil),
                             forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setToolTip(segment.help, forSegment: index)
        }
        control.setAccessibilityLabel("Cards, list or people")
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.layout = $layout
        control.selectedSegment = Self.segments.firstIndex { $0.layout == layout } ?? 0
        control.selectedSegmentBezelColor = NSColor(SegmentedAccent.tint(for: hue))
    }

    func makeCoordinator() -> Coordinator { Coordinator(layout: $layout) }

    @MainActor final class Coordinator: NSObject {
        var layout: Binding<VaultLayout>
        init(layout: Binding<VaultLayout>) { self.layout = layout }

        @objc func changed(_ control: NSSegmentedControl) {
            guard VaultViewSwitch.segments.indices.contains(control.selectedSegment) else { return }
            layout.wrappedValue = VaultViewSwitch.segments[control.selectedSegment].layout
        }
    }
}
