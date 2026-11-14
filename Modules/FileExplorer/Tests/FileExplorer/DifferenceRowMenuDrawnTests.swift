import Testing
import Foundation
import SwiftUI
import AppKit
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

/// Open in Edit on a differences row, as the menu draws it. `DifferenceRowMenuTests` pins which
/// sides `editableSides` returns; this checks the menu applies that list, where the items land, and
/// that a row offering nothing gains no stray item.
///
/// As in `OpenInEditorVerbTests.theDrawnMenuPutsOpenInEditAboveGetInfo`: in a `VStack` each
/// `Button` becomes one focus-ring view, so the rings in y order are the drawn items (a `Divider`
/// has none), recognised by width since the hosted rows carry no readable text. Every claim is
/// relative, never a pixel count: a `.docx` row (a kind Edit refuses) draws the same menu minus
/// the editor items.
@MainActor
@Suite struct DifferenceRowMenuDrawnTests {

    private let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")

    private func row(_ type: FileDifference.DifferenceType, name: String,
                     enclosedItemCount: Int? = nil, leftIsDirectory: Bool = false) -> FileDifference {
        FileDifference(relativePath: "docs/\(name)", leftItemPath: "/icloud/docs/\(name)",
                       rightItemPath: "/dropbox/docs/\(name)", type: type,
                       action: type == .missingOnLeft ? .copyToLeft : .copyToRight, description: "d",
                       enclosedItemCount: enclosedItemCount, leftIsDirectory: leftIsDirectory)
    }

    /// The menu for `difference`, in drawn order, as widths.
    private func drawn(_ difference: FileDifference, offersEditor: Bool = true) -> [CGFloat] {
        let menu = DifferenceInspectionMenu(difference: difference, paneNames: names,
                                            onCompareFilePair: { _ in },
                                            onOpenInEditor: offersEditor ? { _ in } : nil,
                                            onGetInfo: { _ in }, onQuickLook: { _ in })
        return Self.focusRingFrames(in: AnyView(VStack(alignment: .leading, spacing: 0) { menu }
                                                    .frame(width: 320)),
                                    height: 900).map(\.width)
    }

    /// The editor item for one pane, drawn alone at the width the menu gives it.
    private func editorWidth(_ paneName: String) -> CGFloat {
        let item = Button {} label: {
            Label("Open in Edit (\(paneName))", systemImage: "square.and.pencil")
        }
        return Self.focusRingFrames(in: AnyView(VStack(alignment: .leading) { item }.frame(width: 320)),
                                    height: 80).first?.width ?? 0
    }

    /// One editor item per side, directly under Compare… and ahead of Get Info: the two-sided text
    /// row draws the `.docx` row's menu with the two items spliced in at index 1, nothing else moved.
    /// A PDF row draws the same; Edit opens it read-only.
    @Test(arguments: ["notes.md", "report.pdf"])
    func aTextRowDrawsOpenInEditPerSideBetweenCompareAndGetInfo(_ name: String) throws {
        let left = editorWidth("iCloud"), right = editorWidth("Dropbox")
        #expect(left > 0 && right > 0, "an editor item drew nothing on its own")
        #expect(left != right, "the two sides' labels measure the same, so the order below proves less")

        let refused = drawn(row(.differentDates, name: "report.docx"))
        let text = drawn(row(.differentDates, name: name))
        // The premise: neither editor width appears in the .docx menu, or a splice match could be
        // a coincidence of widths.
        #expect(refused.count >= 9, "the .docx row's menu drew \(refused.count) items — the baseline is wrong")
        #expect(!refused.contains(left) && !refused.contains(right), "the .docx row's menu draws an editor item")

        var expected = refused
        expected.insert(contentsOf: [left, right], at: 1)
        #expect(text == expected,
                "the \(name) row's menu is not the .docx row's with Open in Edit (iCloud, Dropbox) at index 1: \(text) vs \(refused)")
    }

    /// A row missing on one side offers one item, and it leads the menu: a one-sided row has no
    /// Compare….
    @Test(arguments: ["notes.md", "report.pdf"])
    func aOneSidedTextRowDrawsOneEditorItemFirst(_ name: String) {
        let refused = drawn(row(.missingOnRight, name: "report.docx"))
        let text = drawn(row(.missingOnRight, name: name))
        #expect(text == [editorWidth("iCloud")] + refused,
                "a row only on iCloud should draw Open in Edit (iCloud) first and nothing else new")
        #expect(!text.contains(editorWidth("Dropbox")), "the missing side is offered to the editor")

        let onlyRight = drawn(row(.missingOnLeft, name: name))
        #expect(onlyRight.first == editorWidth("Dropbox"), "a row only on Dropbox does not lead with its editor item")
        #expect(!onlyRight.contains(editorWidth("iCloud")), "the missing side is offered to the editor")
    }

    /// A folder named like a text file draws exactly the editor-less menu, which rules out a stray
    /// item. A lone divider draws nothing to compare, so `DifferenceRowMenuOrderScanTests` pins the
    /// divider in source.
    @Test func aFolderRowDrawsNoEditorItem() {
        let folder = row(.missingOnRight, name: "notes.md", enclosedItemCount: 4, leftIsDirectory: true)
        #expect(drawn(folder) == drawn(folder, offersEditor: false),
                "a folder row named notes.md draws an Open in Edit item")
    }

    /// A host that wires no editor gets no editor items, the rule `onQuickLook` follows and every
    /// test building `DifferencesView` without the argument relies on.
    @Test func aHostWithNoEditorDrawsNoEditorItem() {
        let text = row(.differentDates, name: "notes.md")
        #expect(drawn(text, offersEditor: false) == drawn(row(.differentDates, name: "report.docx")),
                "without onOpenInEditor the text row should draw exactly the .docx row's menu")
    }

    /// The hosted focus-ring view of every `Button`, top to bottom.
    private static func focusRingFrames(in view: AnyView, height: CGFloat) -> [CGRect] {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        host.layoutSubtreeIfNeeded()
        return FocusRings.frames(in: host).sorted { $0.minY < $1.minY }
    }
}

/// The menu's source, for what a drawing can't show: dividers, which have no focus ring, and the
/// action's argument. `onOpenInEditor(side.paneName)` would draw identically and hand the editor a
/// name.
@Suite struct DifferenceRowMenuOrderScanTests {

    /// `DifferenceInspectionMenu`'s body, by its own matched braces (``SourceText``).
    private static func menuBody() throws -> String {
        try SourceText.block(opening: "struct DifferenceInspectionMenu: View {", in: try viewSource())
    }

    static func viewSource() throws -> String {
        try SourceText.fileExplorer("DifferencesView.swift", atLeast: 5_000)
    }

    /// Compare…, its divider, the editor group, its divider, then Get Info, with the group's
    /// divider inside its own `if` so a row offering nothing draws no extra separator.
    ///
    /// About structure, not indentation: snippets are matched whitespace-normalised
    /// (``SourceText/normalized(_:)``), and "inside the gate" is read off the gate's own braces
    /// (its last statement is `Divider()`), so re-indenting or a blank line can't turn it red.
    @Test func openInEditSitsBetweenCompareAndGetInfoWithItsOwnDivider() throws {
        let raw = try Self.menuBody()
        let body = SourceText.normalized(raw)
        func find(_ snippet: String) -> Range<String.Index>? { body.range(of: SourceText.normalized(snippet)) }
        let compare = try #require(find("Label(\"Compare…\""), "Compare… is gone")
        let gate = try #require(find("if let onOpenInEditor, !editable.isEmpty {"),
                                "the editor group is no longer gated on both a host and an editable side")
        let editor = try #require(find("Label(\"Open in Edit (\\(side.paneName))\", systemImage: \"square.and.pencil\")"),
                                  "the per-side Open in Edit label is gone or reworded")
        let getInfo = try #require(find("Label(\"Get Info (\\(side.paneName))\""), "Get Info is gone")
        // `#require`, not `#expect`: the slice below traps on an inverted range, and a trap takes
        // down the whole test process.
        try #require(compare.lowerBound < gate.lowerBound && gate.lowerBound < editor.lowerBound
                     && editor.upperBound <= getInfo.lowerBound,
                     "Open in Edit no longer sits between Compare… and Get Info")
        let between = body[editor.upperBound..<getInfo.lowerBound]
        #expect(between.contains("Divider()"), "the editor group has no divider before Get Info")
        #expect(between.components(separatedBy: "Divider()").count == 2,
                "more than one divider between Open in Edit and Get Info")
        // …and inside the gate, as its last statement. Past the gate's closing brace it would still
        // sit between the labels, but draw a second separator on every row offering no editor.
        let gateBody = SourceText.normalized(
            try SourceText.block(opening: "if let onOpenInEditor, !editable.isEmpty {", in: raw))
        #expect(gateBody.hasSuffix("Divider()"),
                "the editor group's divider has left its gate — a non-text row would draw a double separator")
        #expect(find("ForEach(editable, id: \\.paneName)") != nil,
                "the items no longer iterate the editable sides")
        #expect(find("let editable = DifferenceRowMenu.editableSides(for: difference, paneNames: paneNames)") != nil,
                "the editor group no longer asks editableSides which sides it may offer")
    }

    /// The item hands over the side's path.
    @Test func openInEditHandsTheEditorTheSidesPath() throws {
        let body = SourceText.normalized(try Self.menuBody())
        #expect(body.contains("onOpenInEditor(side.path)"), "Open in Edit does not hand over the side's path")
    }

    /// The review table's menu has the items too: both menus build the one view, and it is handed
    /// the host's closure rather than one of its own.
    @Test func bothRowMenusBuildTheInspectionItemsWithTheHostsEditor() throws {
        let source = try Self.viewSource()
        let wrapperBody = SourceText.normalized(try SourceText.block(
            opening: "private func inspectionMenuItems(for difference: FileDifference) -> some View {", in: source))
        #expect(wrapperBody.contains("DifferenceInspectionMenu(")
                && wrapperBody.contains(SourceText.normalized("onOpenInEditor: onOpenInEditor")),
                "the row menus no longer pass the host's editor to the items")

        for member in ["private func singleRowMenu(", "private func reviewTable("] {
            let body = SourceText.normalized(try SourceText.block(opening: member, in: source))
            #expect(body.contains(SourceText.normalized("inspectionMenuItems(for: difference)")),
                    "\(member) no longer builds the shared inspection items — it would lack Open in Edit")
        }
    }
}
