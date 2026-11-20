import AppKit
import Design
import SwiftUI

/// Cards or List: a segmented control whose segments carry a symbol and a word each.
///
/// SwiftUI's segmented `Picker` gives a segment its words or its image, never both: a `Label`
/// loses its icon whatever its style, and an image inside the words comes out as an empty
/// attachment box (checked against the `NSSegmentedControl` it builds). So this is that control,
/// built here with both, which keeps AppKit's keyboard and VoiceOver behaviour; the selection takes
/// the same accent `accentedSegments` gives every other segmented picker.
struct VaultViewSwitch: NSViewRepresentable {
    @Binding var showsList: Bool
    let hue: LiquidGlassHue

    private static let segments: [(title: String, symbol: String, help: String)] = [
        ("Cards", "square.grid.2x2", "One card per kind of ID"),
        ("List", "list.bullet", "Every ID in one list"),
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
        control.setAccessibilityLabel("Cards or list")
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.required, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.showsList = $showsList
        control.selectedSegment = showsList ? 1 : 0
        control.selectedSegmentBezelColor = NSColor(SegmentedAccent.tint(for: hue))
    }

    func makeCoordinator() -> Coordinator { Coordinator(showsList: $showsList) }

    @MainActor final class Coordinator: NSObject {
        var showsList: Binding<Bool>
        init(showsList: Binding<Bool>) { self.showsList = showsList }
        @objc func changed(_ control: NSSegmentedControl) {
            showsList.wrappedValue = control.selectedSegment == 1
        }
    }
}
