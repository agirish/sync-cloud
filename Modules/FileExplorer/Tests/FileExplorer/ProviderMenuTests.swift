import Testing
import Foundation
import SwiftUI
@testable import FileExplorer

/// First coverage for `ProviderMenu` — the source picker every pane header and lens source bar
/// opens. Its body is a `Menu`, whose content exists only while the menu is open, so nothing here
/// can be driven headless; what CAN be pinned are the structural invariants its own doc comments
/// argue for, each of which was a shipped behavior or a shipped regression:
///
/// - ONE inline `Picker` over the whole list. A second Picker over the same binding shows the
///   check column in whichever group holds the selection and a blank column in the other, and the
///   list re-spaces as the selection crosses groups.
/// - `Choose Folder…` is optional (`onChooseFolder` nil hides the door), `Manage sources…` is not.
/// - `.fixedSize(horizontal: false, vertical: true)` — vertical-ONLY. The full `.fixedSize()`
///   spelling ignored the width proposal, so a long custom provider name ballooned the label past
///   the pane edge and pushed the header's nav cluster out of view. The modifier IS the fix, so
///   the exact spelling is what a regression would change.
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

    // This line's menu predates the Choose Folder… door (a v3+ feature), so the door pin the
    // newer lines carry has no subject here; what is unconditional on 2.x is the one escape hatch.
    @Test func manageProvidersIsAlwaysReachable() throws {
        let code = Self.codeOnly(try Self.source())
        #expect(code.range(of: "Manage providers") != nil, "the Manage providers item is gone")
        #expect(!code.contains("if let onChooseFolder"),
                "the folder door arrived on 2.x — restore the newer lines\' door-and-gate pin instead of this reduced one")
    }

    @Test func theMenuStaysCompressibleHorizontally() throws {
        let code = Self.codeOnly(try Self.source())
        #expect(code.contains(".fixedSize(horizontal: false, vertical: true)"),
                "the vertical-only fixedSize is the ballooning-label fix — full fixedSize ignores the width proposal")
        // Exactly one .fixedSize in the file, and the line above pins its spelling — which bans
        // the bare `.fixedSize()` AND the expanded `.fixedSize(horizontal: true, …)` in one count,
        // where a bare-spelling ban alone let the expanded form balloon the label all the same.
        let uses = code.components(separatedBy: ".fixedSize").count - 1
        #expect(uses == 1,
                "found \(uses) .fixedSize uses — any spelling other than the vertical-only one reintroduces the ballooning-label regression")
    }
}
