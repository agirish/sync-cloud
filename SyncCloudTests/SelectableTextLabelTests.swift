import Foundation
import Testing

/// Selectable text never carries an accessibility label of its own (2026-11-03). Its node is
/// backed by the text's AppKit view, and while Ask Claude answered, SwiftUI's label for that node
/// asked the view, whose label asked the node back, until the stack ran out: any assistive app
/// reading the panel crashed SyncCloud. Found under lldb; a test window builds no accessibility
/// tree, so a hosted view can't show it, and this reads the source instead. A label goes on an
/// element of its own, `.accessibilityElement(children:)`, between the two.
@Suite struct SelectableTextLabelTests {

    /// Each modifier chain from `.textSelection(.enabled)` on: its own line, then the lines under
    /// it that go on with `.` (or are comments), up to the first that doesn't.
    static func unguardedLabels(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        var found: [Int] = []
        for (index, line) in lines.enumerated() {
            guard let start = line.range(of: ".textSelection(.enabled)") else { continue }
            var chain = [String(line[start.upperBound...])]
            for next in lines.dropFirst(index + 1) {
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(".") || trimmed.hasPrefix("//") else { break }
                if !trimmed.hasPrefix("//") { chain.append(trimmed) }
            }
            let modifiers = chain.joined(separator: " ")
            guard let label = modifiers.range(of: ".accessibilityLabel(") else { continue }
            if modifiers.range(of: ".accessibilityElement(").map({ $0.lowerBound > label.lowerBound }) ?? true {
                found.append(index + 1)
            }
        }
        return found
    }

    @Test func everySelectableTextInTheAppLabelsAnElementOfItsOwn() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("MacApp")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
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
}
