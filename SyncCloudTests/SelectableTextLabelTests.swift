import Foundation
import Testing

/// Selectable text never carries an accessibility label of its own (2026-11-03). Its node is
/// backed by the text's AppKit view, and while Ask Claude answered, SwiftUI's label for that node
/// asked the view, whose label asked the node back, until the stack ran out: any assistive app
/// reading the panel crashed SyncCloud. Found under lldb; a test window builds no accessibility
/// tree, so a hosted view can't show it, and this reads the source instead. A label goes on an
/// element of its own, `.accessibilityElement(children:)`, between the two.
@Suite struct SelectableTextLabelTests {

    /// Each modifier chain through `.textSelection(.enabled)`, both ways: the lines above it that
    /// are modifiers of the same view, its own line, and the lines under it that go on with `.` (or
    /// are comments), stepping over the body of a modifier's closure by its braces (review 2 of
    /// 11-04: a label under `.overlay { … }` went unseen). A label, hint or value in that chain
    /// with no `.accessibilityElement(children: .ignore)` or `.contain` before it is the crash's
    /// shape. And a Toggle's or Button's label holding selectable text is too: the control reads
    /// its label for VoiceOver (69c6b6584's read card, fixed by hand in 1c8376d88).
    static func unguardedLabels(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        let labels = [".accessibilityLabel(", ".accessibilityHint(", ".accessibilityValue("]
        func depthChange(_ line: String) -> Int {
            line.reduce(0) { $0 + ("({[".contains($1) ? 1 : ")}]".contains($1) ? -1 : 0) }
        }
        var found: [Int] = []
        for (index, line) in lines.enumerated() {
            guard let start = line.range(of: ".textSelection(.enabled)") else { continue }
            // Above: the view's own modifiers, up to the line that starts it.
            var above: [String] = []
            for previous in lines[..<index].reversed() {
                let trimmed = previous.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(".") || trimmed.hasPrefix("//") else { break }
                if !trimmed.hasPrefix("//") { above.insert(trimmed, at: 0) }
            }
            var below = [String(line[start.upperBound...])]
            var depth = 0
            for next in lines.dropFirst(index + 1) {
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if depth > 0 {
                    depth += depthChange(trimmed)
                    continue
                }
                guard trimmed.hasPrefix(".") || trimmed.hasPrefix("//") else { break }
                if trimmed.hasPrefix("//") { continue }
                below.append(trimmed)
                depth = max(0, depthChange(trimmed))
            }
            let modifiers = (above + below).joined(separator: " ")
            let firstLabel = labels.compactMap { modifiers.range(of: $0)?.lowerBound }.min()
            guard let label = firstLabel else { continue }
            if modifiers.range(of: ".accessibilityElement(").map({ $0.lowerBound > label }) ?? true {
                found.append(index + 1)
            }
        }
        // A Toggle's or Button's label closure holding selectable text.
        // The control itself, not a name that ends in one (`receiptButton(`, `AskClaudeHeaderButton(`).
        let control = try! NSRegularExpression(pattern: #"(^|[^A-Za-z0-9_])(Toggle|Button)\s*[({]"#)
        for (index, line) in lines.enumerated()
        where control.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            var depth = 0
            var opened = false
            for (offset, next) in lines[index...].prefix(60).enumerated() {
                depth += depthChange(next)
                if depth > 0 { opened = true }
                if next.contains(".textSelection(.enabled)"), offset > 0 || !line.hasPrefix(".") {
                    found.append(index + offset + 1)
                    break
                }
                // A control written on one line has no label closure to look in.
                if opened ? depth <= 0 : offset == 0 && depth <= 0 { break }
            }
        }
        return Array(Set(found)).sorted()
    }

    @Test func everySelectableTextInTheAppLabelsAnElementOfItsOwn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // The app and every package's sources: a package view in the app's window has the same tree.
        var files: [URL] = []
        for top in ["MacApp", "Modules"] {
            let dir = root.appendingPathComponent(top)
            files += try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" && !$0.path.contains("/Tests/") && !$0.path.contains("/.build/") }
        }
        var selectable = 0
        var unguarded: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            selectable += source.components(separatedBy: ".textSelection(.enabled)").count - 1
            unguarded += Self.unguardedLabels(in: source).map { "\(file.lastPathComponent):\($0)" }
        }
        #expect(selectable >= 5, "found \(selectable) selectable texts; is MacApp where it was?")
        #expect(unguarded.isEmpty, "label on selectable text's own node: \(unguarded)")
    }

    /// The question's bubble as it was: the crash's shape is caught, and its fix passes.
    @Test func theBubbleThatCrashedIsCaughtAndItsFixIsNot() {
        let crashed = """
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .accessibilityLabel("You: \\(text)")
            """
        let fixed = """
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                // Its own element.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("You: \\(text)")
            """
        let container = """
            VStack { rows }
                .textSelection(.enabled)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Claude")
            """
        #expect(SelectableTextLabelTests.unguardedLabels(in: crashed) == [2])
        #expect(SelectableTextLabelTests.unguardedLabels(in: fixed).isEmpty)
        #expect(SelectableTextLabelTests.unguardedLabels(in: container).isEmpty)
    }

    /// The shapes the first scan missed (review 2 of 11-04): a label above the selection, a label
    /// past a modifier's closure, a hint, and selectable text in a Toggle's label.
    @Test func theShapesTheFirstScanMissedAreCaught() {
        let above = """
            Text(text)
                .accessibilityLabel("You: \\(text)")
                .textSelection(.enabled)
            """
        let pastAClosure = """
            Text(text)
                .textSelection(.enabled)
                .overlay(alignment: .top) {
                    if showsBar { bar }
                }
                .accessibilityLabel("You")
            """
        let hint = """
            Text(text)
                .textSelection(.enabled)
                .accessibilityHint("Double-click to copy")
            """
        let toggle = """
            Toggle(isOn: $on) {
                VStack {
                    Text(answer)
                        .textSelection(.enabled)
                }
            }
            """
        #expect(SelectableTextLabelTests.unguardedLabels(in: above) == [3])
        #expect(SelectableTextLabelTests.unguardedLabels(in: pastAClosure) == [2])
        #expect(SelectableTextLabelTests.unguardedLabels(in: hint) == [2])
        #expect(SelectableTextLabelTests.unguardedLabels(in: toggle) == [4])
    }
}
