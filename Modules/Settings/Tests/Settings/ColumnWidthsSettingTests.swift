import Testing
import AppKit
import Design
import SwiftUI
@testable import Settings

/// Settings ▸ Browse ▸ Panes ▸ Column widths — the choice between sizing Columns one column at a time
/// and all together.
///
/// "All columns" promises the columns are one width, not only what the next drag does, so the
/// choice itself releases every column sized on its own. Otherwise one wide column would sit under
/// "All columns" until a later drag released it, which reads as the setting not working.
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

    /// `tab` with the test's defaults, hosted in a titled window at `width`×`height` and laid out.
    /// The caller clears `window.contentView` when done.
    private func mount(_ tab: some View, defaults: UserDefaults, width: CGFloat,
                       height: CGFloat) -> (host: NSView, window: NSWindow) {
        let host = NSHostingView(rootView: tab.defaultAppStorage(defaults)
            .environmentObject(SettingsManager(autoDiscover: false, userDefaults: defaults, cloudStorageLister: { .read([]) })))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// Mounted, and chosen through the control's own action, so it tests the picker's real binding.
    /// Paired with the opposite choice, which must leave the widths alone: a setter that cleared on
    /// every write would pass the first half.
    @Test func choosingAllColumnsPutsEveryColumnBackToOneWidth() async throws {
        let test = TestDefaults("column-widths-setting")
        test.defaults.set(ColumnResizeMode.eachColumn.rawValue, forKey: ColumnResizeMode.defaultsKey)
        let sized = ColumnWidthOverrides(widths: [1: 400])
        test.defaults.set(sized.rawValue, forKey: PaneViewMode.columnWidthOverridesDefaultsKey)

        var asked: [Int] = []
        let (host, window) = mount(BrowseSettingsTab(page: .panes, confirmReleasingColumnWidths: {
            asked.append($0); return true
        }), defaults: test.defaults, width: 520, height: 900)
        defer { window.contentView = nil }

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

        #expect(asked == [1], "All columns did not ask about the one column sized on its own: \(asked)")
    }

    /// Declined, the choice changes nothing, on screen too: the setting and widths stay, and the
    /// picker goes back to "Each column". The setter writes nothing, so without a rebuild the
    /// clicked segment would stay lit over a setting that never moved.
    @Test func decliningAllColumnsLeavesTheSettingTheWidthsAndThePicker() async throws {
        let test = TestDefaults("column-widths-decline")
        test.defaults.set(ColumnResizeMode.eachColumn.rawValue, forKey: ColumnResizeMode.defaultsKey)
        let sized = ColumnWidthOverrides(widths: [0: 363, 2: 300])
        test.defaults.set(sized.rawValue, forKey: PaneViewMode.columnWidthOverridesDefaultsKey)

        var asked: [Int] = []
        let (host, window) = mount(BrowseSettingsTab(page: .panes, confirmReleasingColumnWidths: {
            asked.append($0); return false
        }), defaults: test.defaults, width: 520, height: 900)
        defer { window.contentView = nil }

        func picker() -> NSSegmentedControl? {
            segmentedControls(in: host).first { $0.segmentCount == 2 && $0.label(forSegment: 1) == "All columns" }
        }
        let control = try #require(picker(), "no segmented control offering All columns")
        #expect(control.selectedSegment == 0)

        // A write of the same value is still a defaults change other windows react to.
        var writes = 0
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: test.defaults, queue: nil) { _ in writes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        control.selectedSegment = 1
        _ = control.sendAction(control.action, to: control.target)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
        }

        #expect(asked == [2], "All columns did not ask about the two columns sized on their own: \(asked)")
        #expect(writes == 0, "a declined All columns wrote the settings back \(writes) time(s)")
        #expect(test.defaults.string(forKey: ColumnResizeMode.defaultsKey) == ColumnResizeMode.eachColumn.rawValue,
                "a declined All columns changed the setting")
        #expect(test.defaults.string(forKey: PaneViewMode.columnWidthOverridesDefaultsKey)
                    .flatMap(ColumnWidthOverrides.init(rawValue:)) == sized,
                "a declined All columns erased the widths")
        let shown = try #require(picker(), "the picker is gone after a declined choice")
        #expect(shown.selectedSegment == 0, "the picker shows All columns over a setting still at Each column")
    }

    /// The real row fits the narrowest column the sheet offers, at the largest text size: the
    /// two-word segments stay whole and unsqueezed beside their label.
    @Test func theColumnWidthsRowFitsTheNarrowestColumnAtTheLargestText() async throws {
        let test = TestDefaults("column-widths-fit")
        let tinyWindow = CGSize(width: SettingsSheetMetrics.floorSize.width + SettingsSheetMetrics.hostMargin,
                                height: SettingsSheetMetrics.floorSize.height + SettingsSheetMetrics.hostMargin)
        let column = SettingsSheetMetrics.contentWidth(textScale: FontSize.extraLarge.scale, available: tinyWindow)
        let (host, window) = mount(BrowseSettingsTab(page: .panes, confirmReleasingColumnWidths: { _ in false })
            .appFontSize(.extraLarge), defaults: test.defaults, width: column, height: 1600)
        defer { window.contentView = nil }

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
