import Testing
import Foundation
import SwiftUI
import AppKit
import Sync
@testable import FileExplorer
import FileExplorerTestSupport

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
        let folder = row(.missingOnRight, name: "notes.md", enclosedItemCount: 4, leftIsDirectory: true)
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
        return FocusRings.frames(in: host).sorted { $0.minY < $1.minY }
    }
}

/// **The menu's source, for the two things a drawing cannot show: dividers and the action.**
///
/// A `Divider` has no focus ring, so the drawn tests above cannot tell a menu with the editor
/// group's divider from one without — and a closure's argument is not drawn at all.
/// `onOpenInEditor(side.paneName)` would draw identically and hand the editor a name.
@Suite struct DifferenceRowMenuOrderScanTests {

    /// `DifferenceInspectionMenu`'s body — its own braces, matched (``SwiftBlockScan``), where it
    /// was the text up to the next top-level MARK.
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

    /// Compare…, its divider, the editor group, ITS divider, then Get Info — in that order, with
    /// the editor group's divider inside its own `if` so a row that offers nothing draws no
    /// separator of its own.
    ///
    /// **About structure, not indentation** (2026-09-26): every snippet is matched
    /// whitespace-normalised (``SwiftBlockScan/normalized(_:)``), and "the divider is inside the
    /// gate" is read off the gate's own braces — the `if`'s last statement is `Divider()` — where
    /// it was the exact text `"\n            Divider()\n        }\n"`, which re-indenting the
    /// menu, or one blank line, turned red with the divider exactly where it belongs.
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
        // the whole test process — and every drawn test still running beside it — down with it.
        try #require(compare.lowerBound < gate.lowerBound && gate.lowerBound < editor.lowerBound
                     && editor.upperBound <= getInfo.lowerBound,
                     "Open in Edit no longer sits between Compare… and Get Info")
        // The group's divider is between its item and Get Info — i.e. inside the gate.
        let between = body[editor.upperBound..<getInfo.lowerBound]
        #expect(between.contains("Divider()"), "the editor group has no divider before Get Info")
        #expect(between.components(separatedBy: "Divider()").count == 2,
                "more than one divider between Open in Edit and Get Info")
        // …and INSIDE the gate: the divider is the gate's last statement. Moved out past the
        // gate's closing brace it still sits between the two labels — and draws a second
        // separator under Compare… on every row that offers no editor.
        let gateBody = SwiftBlockScan.normalized(
            try SwiftBlockScan.block(opening: "if let onOpenInEditor, !editable.isEmpty {", in: raw))
        #expect(gateBody.hasSuffix("Divider()"),
                "the editor group's divider has left its gate — a non-text row would draw a double separator")
        #expect(find("ForEach(editable, id: \\.paneName)") != nil,
                "the items no longer iterate the editable sides")
        #expect(find("let editable = DifferenceRowMenu.editableSides(for: difference, paneNames: paneNames)") != nil,
                "the editor group no longer asks editableSides which sides it may offer")
    }

    /// The item hands over the side's PATH.
    @Test func openInEditHandsTheEditorTheSidesPath() throws {
        let body = SwiftBlockScan.normalized(try Self.menuBody())
        #expect(body.contains("onOpenInEditor(side.path)"), "Open in Edit does not hand over the side's path")
    }

    /// **The review table's menu gains the items too**, because both menus build the one view —
    /// and the view is handed the host's closure rather than one of its own.
    @Test func bothRowMenusBuildTheInspectionItemsWithTheHostsEditor() throws {
        let source = try Self.viewSource()
        // Each member's own braces, where they were a 400-character window and "up to the next
        // `private func` or doc comment at four spaces".
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

/// **A block's own braces, and code compared without its layout** — for the scans above.
///
/// The app target's `TestSupport.swift` has the full reader (`declarationBody`, `CodeText`,
/// `CallArguments`); this module cannot see it, so this is the part these scans need: a lexer
/// that knows comments and string literals (escapes, `\(…)` interpolations, `"""`, `#"…"#`), a
/// brace matcher over it, and a normaliser that drops whitespace outside strings except between
/// two word characters. Keep it in step with that one if either learns something.
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
