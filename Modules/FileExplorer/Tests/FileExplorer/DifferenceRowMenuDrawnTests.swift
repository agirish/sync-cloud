import Testing
import Foundation
import SwiftUI
import AppKit
import Sync
@testable import FileExplorer

/// **Open in Edit on a differences row, as the menu DRAWS it (TE31).**
///
/// `DifferenceRowMenuTests` pins which sides `editableSides` returns. What it cannot see is whether
/// the menu applies that list, where the items land, and whether a row that offers nothing still
/// gains a stray divider — a `@ViewBuilder` branch that never builds and one that builds in the
/// wrong place both read the same in a source file. So the menu is hosted and read back.
///
/// **The technique is `OpenInEditorVerbTests.theDrawnMenuPutsOpenInEditAboveGetInfo`'s**: hosted
/// in a `VStack`, each `Button` becomes one focus-ring view at its own y, so the focus rings in y
/// order ARE the drawn items in order, and a `Divider` has none. A row is recognised by its width —
/// its label's intrinsic width — because the hosted rows carry no readable text.
///
/// **Every claim is relative, never a pixel count.** The same menu over the same row shape with a
/// PDF in place of a `.md` draws every item except the editor's with an identical label, so the
/// text row's drawing must be the PDF row's with exactly the editor items spliced in. Nothing here
/// is machine-pinned.
@MainActor
@Suite struct DifferenceRowMenuDrawnTests {

    private let names = PaneProviderNames(leftName: "iCloud", rightName: "Dropbox")

    private func row(_ type: FileDifference.DifferenceType, name: String,
                     enclosedItemCount: Int? = nil) -> FileDifference {
        FileDifference(relativePath: "docs/\(name)", leftItemPath: "/icloud/docs/\(name)",
                       rightItemPath: "/dropbox/docs/\(name)", type: type,
                       action: type == .missingOnLeft ? .copyToLeft : .copyToRight, description: "d",
                       enclosedItemCount: enclosedItemCount)
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

    /// **Directly under Compare…, ahead of Get Info, one per side.** The two-sided text row draws
    /// the PDF row's menu with the two editor items spliced in at index 1 — after Compare…, before
    /// the first Get Info — and nothing else moved, added or lost.
    @Test func aTextRowDrawsOpenInEditPerSideBetweenCompareAndGetInfo() throws {
        let left = editorWidth("iCloud"), right = editorWidth("Dropbox")
        #expect(left > 0 && right > 0, "an editor item drew nothing on its own")
        #expect(left != right, "the two sides' labels measure the same, so the order below proves less")

        let pdf = drawn(row(.differentDates, name: "report.pdf"))
        let text = drawn(row(.differentDates, name: "notes.md"))
        // The premise: Compare… leads both menus, and neither editor width is anywhere in the
        // PDF menu — otherwise a splice match could be a coincidence of widths.
        #expect(pdf.count >= 9, "the PDF row's menu drew \(pdf.count) items — the baseline is wrong")
        #expect(!pdf.contains(left) && !pdf.contains(right), "the PDF row's menu draws an editor item")

        var expected = pdf
        expected.insert(contentsOf: [left, right], at: 1)
        #expect(text == expected,
                "the text row's menu is not the PDF row's with Open in Edit (iCloud, Dropbox) at index 1: \(text) vs \(pdf)")
    }

    /// **A row missing on one side offers ONE item, and it leads the menu** — there is no
    /// Compare… on a one-sided row, so Open in Edit is the first thing drawn.
    @Test func aOneSidedTextRowDrawsOneEditorItemFirst() {
        let pdf = drawn(row(.missingOnRight, name: "report.pdf"))
        let text = drawn(row(.missingOnRight, name: "notes.md"))
        #expect(text == [editorWidth("iCloud")] + pdf,
                "a row only on iCloud should draw Open in Edit (iCloud) first and nothing else new")
        #expect(!text.contains(editorWidth("Dropbox")), "the missing side is offered to the editor")

        let onlyRight = drawn(row(.missingOnLeft, name: "notes.md"))
        #expect(onlyRight.first == editorWidth("Dropbox"), "a row only on Dropbox does not lead with its editor item")
        #expect(!onlyRight.contains(editorWidth("iCloud")), "the missing side is offered to the editor")
    }

    /// **A folder named like a text file draws exactly the menu it drew with no editor at all.**
    /// Equality with the editor-less build is what rules out a stray empty group: an extra item
    /// would add a width, and a divider on its own draws nothing to compare — which is why the
    /// divider is also pinned by the source order in `DifferenceRowMenuOrderScanTests`.
    @Test func aFolderRowDrawsNoEditorItem() {
        let folder = row(.missingOnRight, name: "notes.md", enclosedItemCount: 4)
        #expect(drawn(folder) == drawn(folder, offersEditor: false),
                "a folder row named notes.md draws an Open in Edit item")
    }

    /// **A host that wires no editor gets no editor items** — the same rule `onQuickLook` follows,
    /// and the one every test constructing `DifferencesView` without the argument relies on.
    @Test func aHostWithNoEditorDrawsNoEditorItem() {
        let text = row(.differentDates, name: "notes.md")
        #expect(drawn(text, offersEditor: false) == drawn(row(.differentDates, name: "report.pdf")),
                "without onOpenInEditor the text row should draw exactly the PDF row's menu")
    }

    /// The hosted focus-ring view of every `Button`, top to bottom.
    private static func focusRingFrames(in view: AnyView, height: CGFloat) -> [CGRect] {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: height)
        host.layoutSubtreeIfNeeded()
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)).contains("FocusRing") { found.append(v.frame) }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found.sorted { $0.minY < $1.minY }
    }
}

/// **The menu's source, for the two things a drawing cannot show: dividers and the action.**
///
/// A `Divider` has no focus ring, so the drawn tests above cannot tell a menu with the editor
/// group's divider from one without — and a closure's argument is not drawn at all.
/// `onOpenInEditor(side.paneName)` would draw identically and hand the editor a name.
@Suite struct DifferenceRowMenuOrderScanTests {

    /// `DifferenceInspectionMenu`'s body, from its declaration to the next top-level MARK.
    private static func menuBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FileExplorer
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // FileExplorer package
            .appendingPathComponent("Sources/FileExplorer/DifferencesView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read DifferencesView.swift — every check would be vacuous")
        let start = try #require(source.range(of: "struct DifferenceInspectionMenu: View {"),
                                 "the menu view is gone or renamed — this scan measures nothing")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n// MARK: - "), "the menu view never ends")
        return String(rest[..<end.lowerBound])
    }

    static func viewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/DifferencesView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8))
        try #require(text.count > 5_000, "DifferencesView.swift is implausibly short")
        return text
    }

    /// Compare…, its divider, the editor group, ITS divider, then Get Info — in that order, with
    /// the editor group's divider inside its own `if` so a row that offers nothing draws no
    /// separator of its own.
    @Test func openInEditSitsBetweenCompareAndGetInfoWithItsOwnDivider() throws {
        let body = try Self.menuBody()
        let compare = try #require(body.range(of: "Label(\"Compare…\""), "Compare… is gone")
        let gate = try #require(body.range(of: "if let onOpenInEditor, !editable.isEmpty {"),
                                "the editor group is no longer gated on both a host and an editable side")
        let editor = try #require(body.range(of: "Label(\"Open in Edit (\\(side.paneName))\", systemImage: \"square.and.pencil\")"),
                                  "the per-side Open in Edit label is gone or reworded")
        let getInfo = try #require(body.range(of: "Label(\"Get Info (\\(side.paneName))\""), "Get Info is gone")
        // `#require`, not `#expect`: the slice below traps on an inverted range, and a trap takes
        // the whole test process — and every drawn test still running beside it — down with it.
        try #require(compare.lowerBound < gate.lowerBound && gate.lowerBound < editor.lowerBound
                     && editor.upperBound <= getInfo.lowerBound,
                     "Open in Edit no longer sits between Compare… and Get Info")
        // The group's divider is between its item and Get Info — i.e. inside the gate.
        let between = body[editor.upperBound..<getInfo.lowerBound]
        #expect(between.contains("Divider()"), "the editor group has no divider before Get Info")
        #expect(between.components(separatedBy: "Divider()").count == 2,
                "more than one divider between Open in Edit and Get Info")
        // …and INSIDE the gate: the divider is the gate's last statement, so its closing brace
        // follows it. Moved out past that brace it still sits between the two labels — and draws
        // a second separator under Compare… on every row that offers no editor.
        #expect(between.contains("\n            Divider()\n        }\n"),
                "the editor group's divider has left its gate — a non-text row would draw a double separator")
        #expect(body.contains("ForEach(editable, id: \\.paneName)"),
                "the items no longer iterate the editable sides")
        #expect(body.contains("let editable = DifferenceRowMenu.editableSides(for: difference, paneNames: paneNames)"),
                "the editor group no longer asks editableSides which sides it may offer")
    }

    /// The item hands over the side's PATH.
    @Test func openInEditHandsTheEditorTheSidesPath() throws {
        let body = try Self.menuBody()
        #expect(body.contains("onOpenInEditor(side.path)"), "Open in Edit does not hand over the side's path")
    }

    /// **The review table's menu gains the items too**, because both menus build the one view —
    /// and the view is handed the host's closure rather than one of its own.
    @Test func bothRowMenusBuildTheInspectionItemsWithTheHostsEditor() throws {
        let source = try Self.viewSource()
        let wrapper = try #require(source.range(of: "private func inspectionMenuItems(for difference: FileDifference) -> some View {"))
        let wrapperBody = String(source[wrapper.upperBound...].prefix(400))
        #expect(wrapperBody.contains("DifferenceInspectionMenu(") && wrapperBody.contains("onOpenInEditor: onOpenInEditor"),
                "the row menus no longer pass the host's editor to the items")

        for member in ["private func singleRowMenu(", "private func reviewTable("] {
            let start = try #require(source.range(of: member), "\(member) is gone")
            let rest = source[start.upperBound...]
            let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    /// ")
            let body = String(rest[..<(end?.lowerBound ?? rest.endIndex)])
            #expect(body.contains("inspectionMenuItems(for: difference)"),
                    "\(member) no longer builds the shared inspection items — it would lack Open in Edit")
        }
    }
}
