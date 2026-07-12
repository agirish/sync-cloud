import Testing
import AppKit
@testable import SyncCloud

@Suite struct BottomPaneToggleTests {

    @Test func testSymbolNameExistsInSFSymbols() {
        // A typo'd symbol name renders as a blank icon at runtime; pin that it resolves.
        #expect(NSImage(systemSymbolName: BottomPaneToggle.symbol, accessibilityDescription: nil) != nil,
                "missing SF Symbol \(BottomPaneToggle.symbol)")
    }

    @Test func testNoOutlineSiblingExistsSoTintCarriesState() {
        // The toggle conveys state via tint because SF Symbols has no un-filled sibling
        // of the bottomthird glyph. If a future SDK adds one, this pin fails and the
        // button should switch to the filled/outline symbol swap instead.
        #expect(NSImage(systemSymbolName: "rectangle.bottomthird.inset", accessibilityDescription: nil) == nil,
                "rectangle.bottomthird.inset now exists — prefer a symbol swap over tint")
    }

    @Test func testTitleReflectsPaneVisibility() {
        #expect(BottomPaneToggle.title(paneVisible: true) == "Hide Bottom Pane")
        #expect(BottomPaneToggle.title(paneVisible: false) == "Show Bottom Pane")
    }

    @Test func testHelpTextReflectsPaneVisibility() {
        #expect(BottomPaneToggle.helpText(paneVisible: true) == "Hide the bottom pane")
        #expect(BottomPaneToggle.helpText(paneVisible: false) == "Show the bottom pane")
    }
}
