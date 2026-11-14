import Testing
import Foundation

/// Turning autosave back on asks for the write that is waiting. The debounce `.task(id:)` is keyed
/// on the buffer's version, so a setting change doesn't re-fire it: the switch calls
/// `onAutosaveResumed` when `toggle` says autosave is now on, or the file stays unwritten until the
/// next keystroke. A source scan, comments dropped: a hosted header has no element a test can press.
@Suite struct EditorAutosaveResumeWiringTests {

    private static func autosaveSwitchAction() throws -> String {
        let source = try SourceText.fileExplorer("EditorWorkspaceView.swift")
        let start = try #require(source.range(of: "private var autosaveSwitch: some View {"),
                                 "`autosaveSwitch` is gone or renamed — re-aim this scan")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "} label: {"),
                               "the switch's action no longer ends at its label — re-aim this scan")
        return rest[..<end.lowerBound].split(separator: "\n")
            .filter { !$0.drop { $0 == " " }.hasPrefix("//") }
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: " ")
    }

    @Test func turningAutosaveBackOnAsksForTheWrite() throws {
        let action = try Self.autosaveSwitchAction()
        #expect(action.contains("if autosavePolicy.toggle(path) { onAutosaveResumed() }"), """
                the switch no longer calls `onAutosaveResumed` when it turns autosave on, so the \
                file stays unwritten until the next keystroke: \(action)
                """)
        // Only on the way on: a write on the way off is the one autosave was just told not to make.
        #expect(action.components(separatedBy: "onAutosaveResumed()").count - 1 == 1,
                "the switch asks for the write more than once: \(action)")
    }
}
