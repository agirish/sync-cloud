import CoreGraphics
import Foundation
import Testing
@testable import Dashboard

/// A pane's Info: its keys, its width, and the line between a column and a drawer.
@Suite struct PaneInfoTests {

    /// Each pane has a switch of its own, and none is a name the retired window-level Info used:
    /// anyone who left `showCompareInspector` on must not find Info open in every pane.
    @Test func everyPaneHasItsOwnKeyAndNoneIsARetiredName() {
        let keys = [PaneInfo.defaultsKey(isLeft: true), PaneInfo.defaultsKey(isLeft: false),
                    PaneInfo.railDefaultsKey, PaneInfo.browseDefaultsKey]
        #expect(Set(keys).count == 4, "two panes share a switch: \(keys)")
        for retired in ["showCompareInspector", "compareInspectorWidth", "infoPreviewMigrationDone"] {
            #expect(!keys.contains(retired), "\(retired) is a retired key and must not come back")
        }
    }

    /// The line is the room Columns needs: it goes to one spanning column under 280, so the column
    /// stack beside the slot needs 280, plus the slot, its hairline and the stack's trailing gutter.
    @Test func theLineLeavesColumnsTheirOwnMinimum() {
        let needed = 280 + PaneInfo.slotWidth + 1 + 12
        #expect(PaneInfo.minPaneWidthForSlot >= needed, "the slot would push Columns into one column")
    }

    @Test func offIsOffAtAnyWidth() {
        for width in [0, 250, 600, 1400] as [CGFloat] {
            #expect(PaneInfo.presentation(isOn: false, paneWidth: width, previous: .slot) == .off)
        }
    }

    @Test func aWidePaneGetsAColumnAndANarrowOneADrawer() {
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 1089, previous: nil) == .slot)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 599, previous: nil) == .drawer)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: 600, previous: nil) == .slot)
    }

    /// A pane sitting on the line does not flip with every point: a drawer becomes a column only 40pt
    /// past it, and a column stays one until it crosses the line. Mutation: dropping the hysteresis
    /// must fail the middle two lines.
    @Test func crossingTheLineHasAHysteresis() {
        let line = PaneInfo.minPaneWidthForSlot
        #expect(PaneInfo.presentation(isOn: true, paneWidth: line + 20, previous: .drawer) == .drawer)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: line + PaneInfo.hysteresis, previous: .drawer) == .slot)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: line + 1, previous: .slot) == .slot)
        #expect(PaneInfo.presentation(isOn: true, paneWidth: line - 1, previous: .slot) == .drawer)
    }

    /// A drawer is 300, or the pane less a strip of its list, and never under the 200 the details
    /// panel needs to reflow cleanly.
    @Test func theDrawerLeavesAStripOfTheListAndKeepsItsFloor() {
        #expect(PaneInfo.drawerWidth(paneWidth: 1000) == 300)
        #expect(PaneInfo.drawerWidth(paneWidth: 305) == 257)
        #expect(PaneInfo.drawerWidth(paneWidth: 255) == 207)
        #expect(PaneInfo.drawerWidth(paneWidth: 200) == 200)
    }
}
