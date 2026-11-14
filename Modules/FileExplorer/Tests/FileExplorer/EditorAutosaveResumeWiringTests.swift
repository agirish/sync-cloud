import Testing
import Foundation

/// **Turning autosave back on asks for the write that is waiting.**
///
/// The debounce is a `.task(id:)` keyed on the buffer's version, so a setting changing does not
/// re-fire it: the header's switch calls `onAutosaveResumed` when `toggle` says autosave is now on,
/// and the host writes then. Without the call, the file stays unwritten until the next keystroke.
/// `EditorAutosavePolicyTests` holds `toggle`'s answer; this holds that the switch acts on it.
///
/// **A source scan, and that is its limit.** The switch is a SwiftUI `Button` in the header, and a
/// hosted header offers no element a test can press: mounted under `swift test`, its accessibility
/// tree has no "Autosave this file" (tried, 2026-11-06). So this pins the one line, read with
/// comments dropped so a comment quoting it cannot stand in for it.
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
