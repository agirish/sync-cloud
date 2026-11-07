import Testing
import Foundation
import SwiftUI
@testable import FileExplorer

/// Pins the structural invariants of `ProviderMenu`, the source picker every pane header and lens
/// source bar opens. Its `Menu` content exists only while the menu is open, so nothing here can be
/// driven headless; these scans read its source instead:
///
/// - One inline `Picker` over the whole list. A second Picker over the same binding shows the check
///   column only in the group holding the selection, and re-spaces the list as the selection
///   crosses groups.
/// - `Choose Folder…` is optional (`onChooseFolder` nil hides it); `Manage Sources…` is not.
/// - `.fixedSize(horizontal: false, vertical: true)`, vertical only. The full `.fixedSize()`
///   ignores the width proposal, so a long provider name pushes the label past the pane edge and
///   the header's nav cluster out of view.
@Suite struct ProviderMenuTests {

    private static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/ProviderMenu.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read ProviderMenu.swift — every scan here would be vacuous")
        try #require(text.count > 500, "ProviderMenu.swift read as \(text.count) characters — truncated?")
        return text
    }

    /// Whole-line comments stripped, so prose describing the invariants cannot satisfy the scans.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func oneInlinePickerCarriesTheWholeListAndItsCheckColumn() throws {
        let code = Self.codeOnly(try Self.source())
        let pickers = code.components(separatedBy: "Picker(").count - 1
        #expect(pickers == 1,
                "found \(pickers) Picker(s) — a second Picker over the same binding splits the check column and re-spaces the menu")
        #expect(code.contains(".pickerStyle(.inline)"),
                "the inline style is what renders the picker as menu rows with the native check column")
    }

    @Test func chooseFolderIsTheOptionalDoorAndManageSourcesIsNot() throws {
        let code = Self.codeOnly(try Self.source())
        #expect(code.contains("if let onChooseFolder"),
                "Choose Folder… must be withheld when the surface offers no folder door")
        // Manage Sources is unconditional — it must not have crept behind the same (or any) gate.
        let manage = try #require(code.range(of: "Manage Sources"), "the Manage Sources item is gone")
        let before = code[..<manage.lowerBound]
        let lastGate = before.range(of: "if let onChooseFolder", options: .backwards)
        if let lastGate {
            // Walked, not `contains("}")`: a Button between the gate and the item closes its own
            // braces, so that check passes with the item inside the gate. Nor a net-depth count:
            // the Manage button's `label:` closure holds depth +1 at the item's text. The question
            // is whether the gate's block closes before the item appears.
            let afterGate = code[lastGate.upperBound...]
            let open = try #require(afterGate.firstIndex(of: "{"), "the gate has no block")
            var depth = 0
            var gateClose: String.Index?
            var i = open
            while i < afterGate.endIndex {
                if afterGate[i] == "{" { depth += 1 }
                if afterGate[i] == "}" {
                    depth -= 1
                    if depth == 0 { gateClose = i; break }
                }
                i = afterGate.index(after: i)
            }
            let close = try #require(gateClose, "the gate's block never closes — the scan is broken")
            #expect(close < manage.lowerBound,
                    "Manage Sources… appears inside the onChooseFolder gate — it must be reachable from every surface")
        }
    }

    /// "Go to <source>" leads the menu, above the sources, and only for a caller that asks for it.
    /// It is about where you are rather than which source you're on, and the commoner act. The
    /// pane breadcrumb's whole first chip opens this menu, so the root has to be reachable from it.
    ///
    /// Order is the assertion, not presence: an item below the Picker won't be read as being about
    /// position.
    @Test func goingToTheSourcesTopLeadsTheMenuAndIsOptional() throws {
        let code = Self.codeOnly(try Self.source())
        let goTo = try #require(code.range(of: "Go to"),
                                "the menu no longer offers a way to the top of the current source")
        let picker = try #require(code.range(of: "Picker("))
        #expect(goTo.lowerBound < picker.lowerBound,
                "Go to… sits below the source list — it is about position, not about which source, and belongs above it")

        // Optional on the same terms `Choose Folder…` is: a caller with no pane to move — the lens
        // source bar — must get no item rather than a door onto a no-op.
        #expect(code.contains("if let onGoToRoot"),
                "the item is drawn unconditionally, so a caller that passed no handler offers a dead row")

        // The name comes off the provider list, not a parameter, so it can't disagree with the row
        // the Picker checks; a source missing from the list still gets a sentence, not "Go to ".
        #expect(code.contains("currentName.map"),
                "the item's title no longer degrades when the current source is missing from the list")
    }

    @Test func theMenuStaysCompressibleHorizontally() throws {
        let code = Self.codeOnly(try Self.source())
        #expect(code.contains(".fixedSize(horizontal: false, vertical: true)"),
                "the vertical-only fixedSize is the ballooning-label fix — full fixedSize ignores the width proposal")
        // Exactly one `.fixedSize`, with its spelling pinned above: one count bans both the bare
        // `.fixedSize()` and the expanded `.fixedSize(horizontal: true, …)`.
        let uses = code.components(separatedBy: ".fixedSize").count - 1
        #expect(uses == 1,
                "found \(uses) .fixedSize uses — any spelling other than the vertical-only one reintroduces the ballooning-label regression")
    }
}
