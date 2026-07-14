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

    @Test func testTitleReflectsPaneVisibility() {
        #expect(TopPaneVisibility.title(topVisible: true) == "Hide Top Panes")
        #expect(TopPaneVisibility.title(topVisible: false) == "Show Top Panes")
    }

    @Test func testHelpTextReflectsPaneVisibility() {
        #expect(TopPaneVisibility.helpText(topVisible: true) == "Hide the Left/Right file panes")
        #expect(TopPaneVisibility.helpText(topVisible: false) == "Show the Left/Right file panes")
    }

    // MARK: Per-tab capability & defaults

    @Test func testOnlySingleProviderWorkspacesCanHideTopPanes() {
        // Tidy and Storage Lens scan one provider — the second pane is dead space there.
        #expect(TopPaneVisibility.canHideTopPanes(for: .tidy))
        #expect(TopPaneVisibility.canHideTopPanes(for: .storageLens))
        // The comparison tabs need both panes and must never lose them.
        #expect(!TopPaneVisibility.canHideTopPanes(for: .differences))
        #expect(!TopPaneVisibility.canHideTopPanes(for: .details))
    }

    @Test func testDefaultsCollapsePanesOnlyForSingleProviderTabs() {
        #expect(TopPaneVisibility.defaultTopHidden(for: .tidy))
        #expect(TopPaneVisibility.defaultTopHidden(for: .storageLens))
        #expect(!TopPaneVisibility.defaultTopHidden(for: .differences))
        #expect(!TopPaneVisibility.defaultTopHidden(for: .details))
    }

    // MARK: Resolution

    @Test func testResolvesToTabDefaultWhenNoOverride() {
        #expect(TopPaneVisibility.topHidden(for: .tidy, override: nil))
        #expect(TopPaneVisibility.topHidden(for: .storageLens, override: nil))
        #expect(!TopPaneVisibility.topHidden(for: .differences, override: nil))
        #expect(!TopPaneVisibility.topHidden(for: .details, override: nil))
    }

    @Test func testOverrideWinsOnHideCapableTabs() {
        // Override the auto-collapse: keep the panes up on Tidy.
        #expect(!TopPaneVisibility.topHidden(for: .tidy, override: false))
        // Or force-hide them on Storage Lens (already the default, but the override still holds).
        #expect(TopPaneVisibility.topHidden(for: .storageLens, override: true))
    }

    @Test func testNonHideableTabsIgnoreEvenAStaleHiddenOverride() {
        // A bad/stale override must never empty the comparison view.
        #expect(!TopPaneVisibility.topHidden(for: .differences, override: true))
        #expect(!TopPaneVisibility.topHidden(for: .details, override: true))
    }

    // MARK: Override encoding

    @Test func testOverrideEncodeDecodeRoundTrips() {
        let map: [String: Bool] = [
            ContentView.BottomTab.tidy.rawValue: false,
            ContentView.BottomTab.storageLens.rawValue: true,
        ]
        let decoded = TopPaneVisibility.decodeOverrides(TopPaneVisibility.encodeOverrides(map))
        #expect(decoded == map)
    }

    @Test func testEncodingIsStableAcrossCalls() {
        // Sorted keys keep the persisted string identical for identical contents, so an
        // unchanged map doesn't churn @AppStorage.
        let map: [String: Bool] = ["Tidy": true, "Storage Lens": false]
        #expect(TopPaneVisibility.encodeOverrides(map) == TopPaneVisibility.encodeOverrides(map))
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
