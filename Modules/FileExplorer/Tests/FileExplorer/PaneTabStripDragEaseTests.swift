import Foundation
import SwiftUI
import Testing
@testable import FileExplorer

/// **A dragged pane tab rides the pointer** (speed audit 14).
///
/// The 0.16 s ease keyed on the drag offset was meant for the neighbours stepping aside, and it
/// eased the dragged tab's own offset as well — four places, since the strip restates both drag
/// animations outside the lens host for Frosted and Clear — so the tab trailed the pointer for the
/// whole drag. `PaneTabStrip.dragEase(holding:)` is the one rule; this pins the rule and that all
/// four sites ask it with the right question. Driving a real `DragGesture` needs the event
/// machinery, and a test that did would be pinning SwiftUI's gesture rather than this choice.
@Suite struct PaneTabStripDragEaseTests {

    private static func stripSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/Tests/FileExplorer
            .deletingLastPathComponent()      // …/Tests
            .deletingLastPathComponent()      // …/FileExplorer
            .appendingPathComponent("Sources/FileExplorer/PaneTabStrip.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Held: no ease. Not held — a neighbour, or any chip once the drop clears the drag — the ease.
    @Test func theHeldChipIsNotEasedAndEverythingElseIs() {
        #expect(PaneTabStrip.dragEase(holding: true) == nil, "the held chip is eased, so it trails the pointer")
        #expect(PaneTabStrip.dragEase(holding: false) == .easeOut(duration: 0.16),
                "the neighbours and the settle lost their ease")
    }

    /// Each chip asks whether IT is the held one; the lens host asks whether the LENS is on the held
    /// one — the active chip. Asking "is any chip held" would snap the lens ahead of the active chip
    /// while another is dragged past it and the active one eases aside.
    @Test func allFourSitesAskTheRuleTheRightQuestion() throws {
        // Whitespace collapsed, so a modifier spread over two lines reads as one.
        let code = try Self.stripSource().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: " )", with: ")")
        for (site, line) in [
            ("a chip's offset", ".designAnimation(Self.dragEase(holding: draggingTab == item.id), value: dragOffset)"),
            ("a chip's settle", ".designAnimation(Self.dragEase(holding: draggingTab == item.id), value: draggingTab)"),
            ("the lens host's offset", ".designAnimation(drawsLens ? Self.dragEase(holding: draggingTab != nil && draggingTab == activeTabID) : nil, value: dragOffset)"),
            ("the lens host's settle", ".designAnimation(drawsLens ? Self.dragEase(holding: draggingTab != nil && draggingTab == activeTabID) : nil, value: draggingTab)"),
        ] {
            #expect(code.components(separatedBy: line).count - 1 == 1, "\(site) no longer asks the drag rule once: \(line)")
        }
        // No fifth site eases the drag some other way.
        // Each call's own `value:` is the first after its name.
        let eased = code.components(separatedBy: ".designAnimation(").dropFirst().filter { call in
            guard let label = call.range(of: "value: ") else { return false }
            let key = call[label.upperBound...].prefix { $0.isLetter || $0.isNumber }
            return key == "dragOffset" || key == "draggingTab"
        }
        #expect(eased.count == 4, "the drag is animated at \(eased.count) sites, not the four the rule covers")
    }
}
