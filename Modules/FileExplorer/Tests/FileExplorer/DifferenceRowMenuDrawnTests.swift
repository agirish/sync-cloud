import Testing
import Foundation
import SwiftUI
import AppKit
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

/// Open in Edit on a differences row, as the menu draws it. `DifferenceRowMenuTests` pins which
/// sides `editableSides` returns; this checks the menu applies that list, where the items land, and
/// that a row offering nothing gains no stray item. So the menu is hosted and read back.
///
/// As in `OpenInEditorVerbTests.theDrawnMenuPutsOpenInEditAboveGetInfo`: in a `VStack` each
/// `Button` becomes one focus-ring view, so the rings in y order are the drawn items, and a
/// `Divider` has none. Items are recognised by width, since the hosted rows carry no readable text.
///
/// Every claim is relative, never a pixel count: a `.docx` row (a kind Edit refuses) draws the same
/// menu minus the editor items, so a text row must be that menu with the editor items spliced in.
/// Nothing here is machine-pinned.
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
    @Test func aTextRowDrawsOpenInEditPerSideBetweenCompareAndGetInfo() throws {
        let left = editorWidth("iCloud"), right = editorWidth("Dropbox")
        #expect(left > 0 && right > 0, "an editor item drew nothing on its own")
        #expect(left != right, "the two sides' labels measure the same, so the order below proves less")

        let refused = drawn(row(.differentDates, name: "report.docx"))
        let text = drawn(row(.differentDates, name: "notes.md"))
        // The premise: neither editor width appears in the .docx menu, or a splice match could be
        // a coincidence of widths.
        #expect(refused.count >= 9, "the .docx row's menu drew \(refused.count) items — the baseline is wrong")
        #expect(!refused.contains(left) && !refused.contains(right), "the .docx row's menu draws an editor item")

        var expected = refused
        expected.insert(contentsOf: [left, right], at: 1)
        #expect(text == expected,
                "the text row's menu is not the .docx row's with Open in Edit (iCloud, Dropbox) at index 1: \(text) vs \(refused)")
    }

    /// A PDF row draws the text row's editor items in the same place; Edit opens it read-only.
    @Test func aPDFRowDrawsOpenInEditPerSideBetweenCompareAndGetInfo() {
        let refused = drawn(row(.differentDates, name: "report.docx"))
        var expected = refused
        expected.insert(contentsOf: [editorWidth("iCloud"), editorWidth("Dropbox")], at: 1)
        #expect(drawn(row(.differentDates, name: "report.pdf")) == expected,
                "the PDF row's menu is not the .docx row's with Open in Edit (iCloud, Dropbox) at index 1")
        #expect(drawn(row(.missingOnRight, name: "report.pdf")) == [editorWidth("iCloud")] + drawn(row(.missingOnRight, name: "report.docx")),
                "a PDF row only on iCloud should lead with Open in Edit (iCloud)")
    }

    /// A row missing on one side offers one item, and it leads the menu: a one-sided row has no
    /// Compare….
    @Test func aOneSidedTextRowDrawsOneEditorItemFirst() {
        let refused = drawn(row(.missingOnRight, name: "report.docx"))
        let text = drawn(row(.missingOnRight, name: "notes.md"))
        #expect(text == [editorWidth("iCloud")] + refused,
                "a row only on iCloud should draw Open in Edit (iCloud) first and nothing else new")
        #expect(!text.contains(editorWidth("Dropbox")), "the missing side is offered to the editor")

        let onlyRight = drawn(row(.missingOnLeft, name: "notes.md"))
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

    /// `DifferenceInspectionMenu`'s body, by its own matched braces (``SwiftBlockScan``).
    private static func menuBody() throws -> String {
        try SwiftBlockScan.block(opening: "struct DifferenceInspectionMenu: View {", in: try viewSource())
    }

    static func viewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/DifferencesView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8))
        try #require(text.count > 5_000, "DifferencesView.swift is implausibly short")
        return text
    }

    /// Compare…, its divider, the editor group, its divider, then Get Info, with the group's
    /// divider inside its own `if` so a row offering nothing draws no extra separator.
    ///
    /// About structure, not indentation: snippets are matched whitespace-normalised
    /// (``SwiftBlockScan/normalized(_:)``), and "inside the gate" is read off the gate's own braces
    /// (its last statement is `Divider()`), so re-indenting or a blank line can't turn it red.
    @Test func openInEditSitsBetweenCompareAndGetInfoWithItsOwnDivider() throws {
        let raw = try Self.menuBody()
        let body = SwiftBlockScan.normalized(raw)
        func find(_ snippet: String) -> Range<String.Index>? { body.range(of: SwiftBlockScan.normalized(snippet)) }
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
        // The group's divider is between its item and Get Info.
        let between = body[editor.upperBound..<getInfo.lowerBound]
        #expect(between.contains("Divider()"), "the editor group has no divider before Get Info")
        #expect(between.components(separatedBy: "Divider()").count == 2,
                "more than one divider between Open in Edit and Get Info")
        // …and inside the gate, as its last statement. Past the gate's closing brace it would still
        // sit between the labels, but draw a second separator on every row offering no editor.
        let gateBody = SwiftBlockScan.normalized(
            try SwiftBlockScan.block(opening: "if let onOpenInEditor, !editable.isEmpty {", in: raw))
        #expect(gateBody.hasSuffix("Divider()"),
                "the editor group's divider has left its gate — a non-text row would draw a double separator")
        #expect(find("ForEach(editable, id: \\.paneName)") != nil,
                "the items no longer iterate the editable sides")
        #expect(find("let editable = DifferenceRowMenu.editableSides(for: difference, paneNames: paneNames)") != nil,
                "the editor group no longer asks editableSides which sides it may offer")
    }

    /// The item hands over the side's path.
    @Test func openInEditHandsTheEditorTheSidesPath() throws {
        let body = SwiftBlockScan.normalized(try Self.menuBody())
        #expect(body.contains("onOpenInEditor(side.path)"), "Open in Edit does not hand over the side's path")
    }

    /// The review table's menu has the items too: both menus build the one view, and it is handed
    /// the host's closure rather than one of its own.
    @Test func bothRowMenusBuildTheInspectionItemsWithTheHostsEditor() throws {
        let source = try Self.viewSource()
        // Each member by its own braces.
        let wrapperBody = SwiftBlockScan.normalized(try SwiftBlockScan.block(
            opening: "private func inspectionMenuItems(for difference: FileDifference) -> some View {", in: source))
        #expect(wrapperBody.contains("DifferenceInspectionMenu(")
                && wrapperBody.contains(SwiftBlockScan.normalized("onOpenInEditor: onOpenInEditor")),
                "the row menus no longer pass the host's editor to the items")

        for member in ["private func singleRowMenu(", "private func reviewTable("] {
            let body = SwiftBlockScan.normalized(try SwiftBlockScan.block(opening: member, in: source))
            #expect(body.contains(SwiftBlockScan.normalized("inspectionMenuItems(for: difference)")),
                    "\(member) no longer builds the shared inspection items — it would lack Open in Edit")
        }
    }
}

/// A block's own braces, and code compared without its layout, for the scans above.
///
/// The app target's `TestSupport.swift` has the full reader (`declarationBody`, `CodeText`,
/// `CallArguments`), which this module can't see. This is the part these scans need: a lexer that
/// knows comments and string literals (escapes, `\(…)`, `"""`, `#"…"#`), a brace matcher over it,
/// and a whitespace normaliser. Keep the two in step.
private enum SwiftBlockScan {
    enum Kind { case code, string, comment }

    /// What each byte is part of: code, a string literal (interpolations included), or a comment.
    static func kinds(_ b: [UInt8]) -> [Kind] {
        var kinds = [Kind](repeating: .code, count: b.count)
        func at(_ i: Int) -> UInt8? { i < b.count ? b[i] : nil }
        let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), slash = UInt8(ascii: "/"),
            star = UInt8(ascii: "*"), newline = UInt8(ascii: "\n"), backslash = UInt8(ascii: "\\"),
            open = UInt8(ascii: "("), close = UInt8(ascii: ")")
        // Code from `i`; with `interpolation`, returns after the `)` that closes it.
        func code(from start: Int, interpolation: Bool, mark: Bool) -> Int {
            var i = start, depth = 0
            while i < b.count {
                let c = b[i]
                var end: Int?
                var kind = Kind.comment
                if c == slash, at(i + 1) == slash {
                    var j = i
                    while j < b.count, b[j] != newline { j += 1 }
                    end = j
                } else if c == slash, at(i + 1) == star {
                    var j = i + 2, level = 1
                    while j < b.count, level > 0 {
                        if b[j] == slash, at(j + 1) == star { level += 1; j += 2 }
                        else if b[j] == star, at(j + 1) == slash { level -= 1; j += 2 }
                        else { j += 1 }
                    }
                    end = j
                } else if c == quote || c == hash {
                    end = string(at: i)
                    kind = .string
                }
                if let end {
                    if mark { for k in i..<min(end, b.count) { kinds[k] = kind } }
                    i = end
                    continue
                }
                if interpolation, c == open { depth += 1 }
                if interpolation, c == close {
                    if depth == 0 { return i + 1 }
                    depth -= 1
                }
                i += 1
            }
            return b.count
        }
        func string(at i: Int) -> Int? {
            var j = i, hashes = 0
            while at(j) == hash { hashes += 1; j += 1 }
            guard at(j) == quote else { return nil }
            let multiline = at(j + 1) == quote && at(j + 2) == quote
            j += multiline ? 3 : 1
            func hashesAt(_ k: Int) -> Bool { (0..<hashes).allSatisfy { at(k + $0) == hash } }
            while j < b.count {
                if b[j] == backslash, hashesAt(j + 1) {
                    let k = j + 1 + hashes
                    j = at(k) == open ? code(from: k + 1, interpolation: true, mark: false) : k + 1
                    continue
                }
                if b[j] == quote, !multiline || (at(j + 1) == quote && at(j + 2) == quote) {
                    let after = j + (multiline ? 3 : 1)
                    if hashesAt(after) { return after + hashes }
                }
                if !multiline, b[j] == newline { return j }
                j += 1
            }
            return b.count
        }
        _ = code(from: 0, interpolation: false, mark: true)
        return kinds
    }

    /// The text inside the braces of the block `opening` starts — the first `{` in code from the
    /// start of `opening`, to its match. `opening` must occur exactly once.
    static func block(opening: String, in source: String,
                      sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let count = source.components(separatedBy: opening).count - 1
        try #require(count == 1, "\(opening) occurs \(count)× — the scan would read the wrong block",
                     sourceLocation: sourceLocation)
        let start = try #require(source.range(of: opening), sourceLocation: sourceLocation)
        let b = Array(source.utf8)
        let kind = kinds(b)
        var i = source.utf8.distance(from: source.startIndex, to: start.lowerBound)
        while i < b.count, !(kind[i] == .code && b[i] == UInt8(ascii: "{")) { i += 1 }
        let open = i
        var depth = 0
        while i < b.count {
            if kind[i] == .code, b[i] == UInt8(ascii: "{") { depth += 1 }
            if kind[i] == .code, b[i] == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return String(decoding: b[(open + 1)..<i], as: UTF8.self) }
            }
            i += 1
        }
        Issue.record("\(opening) never closes — the scan would read the rest of the file", sourceLocation: sourceLocation)
        return String(decoding: b[min(open + 1, b.count)...], as: UTF8.self)
    }

    /// Comments dropped, and whitespace outside string literals dropped except between two word
    /// characters, where it becomes one space. Strings are kept byte for byte.
    static func normalized(_ text: String) -> String {
        let b = Array(text.utf8)
        let kind = kinds(b)
        func isWord(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || c == UInt8(ascii: "@")
                || c == UInt8(ascii: "#") || c >= 0x80
        }
        var out: [UInt8] = []
        var pending = false
        for i in 0..<b.count {
            let c = b[i]
            if kind[i] == .comment || (kind[i] == .code && (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D)) {
                pending = true
                continue
            }
            if pending, let last = out.last, isWord(last), isWord(c) { out.append(0x20) }
            pending = false
            out.append(c)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
