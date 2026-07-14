import Testing
import AppKit
@testable import SyncCloud

@Suite struct TopPaneVisibilityTests {

    // MARK: Presentation

    @Test func testSymbolNameExistsInSFSymbols() {
        // A typo'd symbol name renders as a blank icon at runtime; pin that it resolves.
        #expect(NSImage(systemSymbolName: TopPaneVisibility.symbol, accessibilityDescription: nil) != nil,
                "missing SF Symbol \(TopPaneVisibility.symbol)")
    }

    @Test func testTitleReflectsModeAndVisibility() {
        // Comparison tabs speak of "File Panes"; the single-source tab of the "Source Pane" (its rail).
        #expect(TopPaneVisibility.title(panesVisible: true, mode: .compare) == "Hide File Panes")
        #expect(TopPaneVisibility.title(panesVisible: false, mode: .compare) == "Show File Panes")
        #expect(TopPaneVisibility.title(panesVisible: true, mode: .singleSource) == "Hide Source Pane")
        #expect(TopPaneVisibility.title(panesVisible: false, mode: .singleSource) == "Show Source Pane")
    }

    @Test func testHelpTextReflectsModeAndVisibility() {
        #expect(TopPaneVisibility.helpText(panesVisible: true, mode: .compare) == "Hide the Left/Right file panes")
        #expect(TopPaneVisibility.helpText(panesVisible: false, mode: .compare) == "Show the Left/Right file panes")
        #expect(TopPaneVisibility.helpText(panesVisible: true, mode: .singleSource) == "Collapse the source rail")
        #expect(TopPaneVisibility.helpText(panesVisible: false, mode: .singleSource) == "Show the source rail to browse or re-scope")
    }

    // MARK: Mode & pane count

    @Test func testModePerTab() {
        // Differences and Details compare two locations; Tidy scans one.
        #expect(TopPaneVisibility.mode(for: .differences) == .compare)
        #expect(TopPaneVisibility.mode(for: .details) == .compare)
        #expect(TopPaneVisibility.mode(for: .tidy) == .singleSource)
    }

    @Test func testPaneCountPerTab() {
        #expect(TopPaneVisibility.paneCount(for: .differences) == 2)
        #expect(TopPaneVisibility.paneCount(for: .details) == 2)
        #expect(TopPaneVisibility.paneCount(for: .tidy) == 1)
    }

    // MARK: Defaults

    @Test func testDefaultsHideOnlyTheSingleSourceRail() {
        // The single-source rail starts collapsed (workspace fills); comparison panes start shown.
        #expect(TopPaneVisibility.defaultPanesHidden(for: .tidy))
        #expect(!TopPaneVisibility.defaultPanesHidden(for: .differences))
        #expect(!TopPaneVisibility.defaultPanesHidden(for: .details))
    }

    // MARK: Resolution

    @Test func testResolvesToTabDefaultWhenNoOverride() {
        #expect(TopPaneVisibility.panesHidden(for: .tidy, override: nil))
        #expect(!TopPaneVisibility.panesHidden(for: .differences, override: nil))
        #expect(!TopPaneVisibility.panesHidden(for: .details, override: nil))
    }

    @Test func testOverrideWinsOnEveryTab() {
        // Every tab is freely hideable now — an override flips the default in both directions.
        #expect(!TopPaneVisibility.panesHidden(for: .tidy, override: false))     // keep the rail up
        #expect(TopPaneVisibility.panesHidden(for: .differences, override: true)) // hide compare panes
        #expect(!TopPaneVisibility.panesHidden(for: .details, override: false))
    }

    // MARK: Override encoding (persistence format is stable — stores `hidden`, keyed by tab raw value)

    @Test func testOverrideEncodeDecodeRoundTrips() {
        let map: [String: Bool] = [
            ContentView.BottomTab.tidy.rawValue: false,
            ContentView.BottomTab.differences.rawValue: true,
        ]
        let decoded = TopPaneVisibility.decodeOverrides(TopPaneVisibility.encodeOverrides(map))
        #expect(decoded == map)
    }

    @Test func testEncodingIsStableAcrossCalls() {
        // Sorted keys keep the persisted string identical for identical contents, so an
        // unchanged map doesn't churn @AppStorage.
        let map: [String: Bool] = ["Tidy": true, "Differences": false]
        #expect(TopPaneVisibility.encodeOverrides(map) == TopPaneVisibility.encodeOverrides(map))
    }

    @Test func testUnknownKeysAreIgnoredNotFatal() {
        // A retired tab's leftover entry (e.g. the old "Storage Lens") stays in the map but is
        // never looked up, so it can't affect any current tab.
        let raw = TopPaneVisibility.encodeOverrides(["Storage Lens": true, "Tidy": false])
        let decoded = TopPaneVisibility.decodeOverrides(raw)
        #expect(decoded["Storage Lens"] == true)
        #expect(!TopPaneVisibility.panesHidden(for: .tidy, override: decoded["Tidy"]))
    }

    @Test func testMalformedAndEmptyOverridesDecodeToEmptyMap() {
        #expect(TopPaneVisibility.decodeOverrides("") == [:])
        #expect(TopPaneVisibility.decodeOverrides("not json") == [:])
        #expect(TopPaneVisibility.decodeOverrides("{\"Tidy\":123}") == [:])
    }

    @Test func testSettingOverrideAddsAndReplaces() {
        var overrides: [String: Bool] = [:]
        overrides = TopPaneVisibility.settingOverride(overrides, tab: .tidy, hidden: false)
        #expect(overrides[ContentView.BottomTab.tidy.rawValue] == false)
        // Replacing the same tab overwrites, doesn't duplicate.
        overrides = TopPaneVisibility.settingOverride(overrides, tab: .tidy, hidden: true)
        #expect(overrides[ContentView.BottomTab.tidy.rawValue] == true)
        #expect(overrides.count == 1)
    }
}
