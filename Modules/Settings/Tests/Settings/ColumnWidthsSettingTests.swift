import Testing
import AppKit
import Design
import SwiftUI
@testable import Settings

/// Settings ▸ Readability ▸ Column widths — the choice between sizing Columns one column at a time
/// and all together.
///
/// Choosing "All columns" is a promise about what the columns look like, not only about what the next
/// drag does: they are one width. So the choice itself releases every column that was sized on its
/// own; leaving them would draw one wide column under "All columns" until some later drag happened to
/// release it, which reads as the setting not working.
@MainActor
@Suite struct ColumnWidthsSettingTests {

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        var found: [NSSegmentedControl] = []
        func walk(_ v: NSView) {
            if let control = v as? NSSegmentedControl { found.append(control) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// Mounted, and chosen through the control's own action — the binding the picker really has,
    /// rather than a restatement of it. Paired with the opposite choice, which must leave the widths
    /// alone: a setter that cleared on every write would pass the first half.
    @Test func choosingAllColumnsPutsEveryColumnBackToOneWidth() async throws {
        let test = TestDefaults("column-widths-setting")
        test.defaults.set(ColumnResizeMode.eachColumn.rawValue, forKey: ColumnResizeMode.defaultsKey)
        let sized = ColumnWidthOverrides(widths: [1: 400])
        test.defaults.set(sized.rawValue, forKey: PaneViewMode.columnWidthOverridesDefaultsKey)

        let host = NSHostingView(rootView: ReadabilitySettingsTab().defaultAppStorage(test.defaults))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        let control = try #require(
            segmentedControls(in: host).first { $0.segmentCount == 2 && $0.label(forSegment: 1) == "All columns" },
            "no segmented control offering All columns — the setting moved, or the scan cannot see it")
        func choose(_ segment: Int) async {
            control.selectedSegment = segment
            _ = control.sendAction(control.action, to: control.target)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        func stored() -> ColumnWidthOverrides? {
            test.defaults.string(forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
                .flatMap(ColumnWidthOverrides.init(rawValue:))
        }

        await choose(0)
        #expect(stored() == sized, "choosing Each column released the columns sized on their own")

        await choose(1)
        #expect(test.defaults.string(forKey: ColumnResizeMode.defaultsKey) == ColumnResizeMode.allColumns.rawValue,
                "the control's action did not reach the setting — the rest of this test measures nothing")
        #expect(stored()?.widths.isEmpty == true,
                "All columns left a column at its own width: \(String(describing: stored()?.widths))")
    }

    /// **The row fits the narrowest column the sheet can offer, at the largest text size** — the
    /// real control in the real tab, not a copy of it. The segments were kept to two short words for
    /// this column; this is what says they still fit it, whole and unsqueezed, beside their label.
    @Test func theColumnWidthsRowFitsTheNarrowestColumnAtTheLargestText() async throws {
        let test = TestDefaults("column-widths-fit")
        let tinyWindow = CGSize(width: SettingsSheetMetrics.floorSize.width + SettingsSheetMetrics.hostMargin,
                                height: SettingsSheetMetrics.floorSize.height + SettingsSheetMetrics.hostMargin)
        let column = SettingsSheetMetrics.contentWidth(textScale: FontSize.extraLarge.scale, available: tinyWindow)
        let host = NSHostingView(rootView: ReadabilitySettingsTab()
            .appFontSize(.extraLarge)
            .defaultAppStorage(test.defaults))
        host.frame = NSRect(x: 0, y: 0, width: column, height: 1600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        let control = try #require(
            segmentedControls(in: host).first { $0.segmentCount == 2 && $0.label(forSegment: 1) == "All columns" },
            "no Column widths control in the tab")
        let frame = control.convert(control.bounds, to: host)
        #expect(frame.minX >= -0.5 && frame.maxX <= host.bounds.width + 0.5,
                "the Column widths control runs outside a \(column)pt column: \(frame.minX)…\(frame.maxX)")
        #expect(frame.width >= control.intrinsicContentSize.width - 0.5,
                "the Column widths control is squeezed to \(frame.width)pt of the \(control.intrinsicContentSize.width) it needs")
    }
}
