import Testing
import Foundation
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// Pins `ProviderMenu`, the source picker every pane header and lens source bar opens. Its items
/// are read through `NSHostingMenu`, which builds the real `NSMenu` (titles, order, check state);
/// two invariants it can't see are scans of the source:
///
/// - One inline `Picker` over the whole list. A second Picker over the same binding shows the check
///   column only in the group holding the selection, and re-spaces the list as the selection
///   crosses groups; the menu's titles and ticks would read the same.
/// - `.fixedSize(horizontal: false, vertical: true)`, vertical only. The full `.fixedSize()`
///   ignores the width proposal, so a long provider name pushes the label past the pane edge and
///   the header's nav cluster out of view.
@MainActor
@Suite struct ProviderMenuTests {

    private static let providers = [
        CloudProvider(id: "Dropbox", displayName: "Dropbox", imageName: "dropbox",
                      rootPath: "/Users/u/Library/CloudStorage/Dropbox", type: .dropBox),
        CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                      rootPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs", type: .iCloud)]

    /// The menu's lines as AppKit draws them, a ticked item marked "✓".
    private static func lines(currentId: String = "iCloud", chooseFolder: Bool, goToRoot: Bool) throws -> [String] {
        let menu = NSHostingMenu(rootView: ProviderMenu(
            providers: providers, currentId: currentId, onSelect: { _ in }, onManage: {},
            onChooseFolder: chooseFolder ? {} : nil, onGoToRoot: goToRoot ? {} : nil,
            cloudApps: CloudAppMonitor()) { Text("Source") })
        menu.update()
        let item = try #require(menu.items.first { $0.submenu != nil }, "no source menu was built")
        let submenu = try #require(item.submenu)
        submenu.update()
        return submenu.items.filter { !$0.isSeparatorItem }.map { ($0.state == .on ? "✓ " : "") + $0.title }
    }

    @Test func oneInlinePickerCarriesTheWholeListAndItsCheckColumn() throws {
        let code = SourceText.codeOnly(try SourceText.fileExplorer("ProviderMenu.swift"))
        let pickers = code.components(separatedBy: "Picker(").count - 1
        #expect(pickers == 1,
                "found \(pickers) Picker(s) — a second Picker over the same binding splits the check column and re-spaces the menu")
        #expect(code.contains(".pickerStyle(.inline)"),
                "the inline style is what renders the picker as menu rows with the native check column")
    }

    /// "Go to <source>" leads the menu, above the sources, and only for a caller that asks for it.
    /// It is about where you are rather than which source you're on, and the commoner act. The
    /// pane breadcrumb's whole first chip opens this menu, so the root has to be reachable from it.
    /// Order is the assertion, not presence: an item below the sources won't be read as being about
    /// position. A caller with no pane to move (the lens source bar) gets no item rather than a
    /// door onto a no-op.
    ///
    /// `Choose Folder…` is optional on the same terms; `Manage Sources…` is not, from any surface.
    @Test func goingToTheTopLeadsAndChooseFolderIsOptionalButManageSourcesIsNot() throws {
        #expect(try Self.lines(chooseFolder: true, goToRoot: true)
                == ["Go to iCloud", "Dropbox", "✓ iCloud", "Choose Folder…", "Manage Sources…"])
        #expect(try Self.lines(chooseFolder: false, goToRoot: false)
                == ["Dropbox", "✓ iCloud", "Manage Sources…"])
    }

    /// The name comes off the provider list, not a parameter, so it can't disagree with the row
    /// the Picker checks; a source missing from the list still gets a sentence, not "Go to ".
    @Test func goingToTheTopOfASourceMissingFromTheListStillSaysWhere() throws {
        #expect(try Self.lines(currentId: "gone", chooseFolder: false, goToRoot: true).first
                == "Go to the Top of This Source")
    }

    @Test func theMenuStaysCompressibleHorizontally() throws {
        let code = SourceText.codeOnly(try SourceText.fileExplorer("ProviderMenu.swift"))
        #expect(code.contains(".fixedSize(horizontal: false, vertical: true)"),
                "the vertical-only fixedSize is the ballooning-label fix — full fixedSize ignores the width proposal")
        // Exactly one `.fixedSize`, with its spelling pinned above: one count bans both the bare
        // `.fixedSize()` and the expanded `.fixedSize(horizontal: true, …)`.
        let uses = code.components(separatedBy: ".fixedSize").count - 1
        #expect(uses == 1,
                "found \(uses) .fixedSize uses — any spelling other than the vertical-only one reintroduces the ballooning-label regression")
    }
}
