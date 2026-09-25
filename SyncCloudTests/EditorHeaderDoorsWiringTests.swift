import Testing
import Foundation
import FileExplorer
@testable import SyncCloud

/// The app side of the header's ＋ (TE45): what `ContentView` actually hands the button.
///
/// **The lesson of the TE27–TE30 review, applied.** `EditorHeaderDoorsTests` builds the view with
/// closures of its own, so nothing there can see what the APP passes — replacing the real closure
/// with `{}` would leave that suite green. `ContentView` cannot be built in a test (its memberwise
/// initializer is private; see `BrowseWorkspaceCallSiteTests`), so the call site is scanned, with
/// comments stripped and a positive control.
@Suite struct EditorHeaderDoorsWiringTests {

    /// **The ＋ is handed ⌘N's own closure** — not a copy of its body, and not a closure that only
    /// sets `editorIsNaming`, which would open the row without taking focus. Mutations: `{
    /// editorIsNaming = true }`, `nil`, or `{}` in its place each fail.
    @Test func theHeaderPlusIsHandedTheNewFileChordItself() throws {
        let body = try Self.memberBody("func editorWorkspace(showsRail: Bool)", in: Self.editor())
        #expect(body.contains("onNewTextFile: shortcutNewTextFile,") || body.contains("onNewTextFile: shortcutNewTextFile)"),
                "the header's ＋ is not handed ⌘N's closure — it can drift from what the chord does")
    }

    /// What that closure does, so "the same as ⌘N" is a claim about something: it opens the naming
    /// row AND bumps the focus counter, so a ＋ pressed with the row already open still takes focus.
    @Test func theNewFileChordOpensTheRowAndTakesFocus() throws {
        let body = try Self.memberBody("var shortcutNewTextFile: (() -> Void)?", in: Self.editor())
        #expect(body.contains("editorIsNaming = true"), "⌘N no longer opens the naming row")
        #expect(body.contains("editorNamingFocus &+= 1"), "⌘N no longer bumps the focus counter")
        #expect(body.contains("guard !editorFolder.isEmpty else { return nil }"),
                "⌘N is offered with no folder — the ＋ would not grey")
    }

    /// **Every Edit layout mounts the same workspace builder**, so the ＋ is in the header whether
    /// the pane is open, the rail is drawn, or "Just the text" is on. Both arms of `editorLayout`
    /// call `editorWorkspace(showsRail:)`; a third route to `EditorWorkspaceView` would be one that
    /// could forget the ＋.
    @Test func everyEditLayoutMountsTheOneBuilder() throws {
        let source = try Self.editor()
        let layout = try Self.memberBody("func editorLayout(collapsed: Bool, geo: GeometryProxy)", in: source)
        #expect(layout.components(separatedBy: "editorWorkspace(showsRail:").count - 1 == 2,
                "editorLayout no longer mounts the workspace through the one builder in both arms")
        #expect(source.components(separatedBy: "EditorWorkspaceView(").count - 1 == 1,
                "a second EditorWorkspaceView construction site appeared in ContentView+Editor")
    }

    /// The positive control: the scans are reading the real file.
    @Test func theScanCanActuallyFail() throws {
        let source = try Self.editor()
        #expect(source.contains("func settleEditorDocument()"), "not reading ContentView+Editor.swift")
        #expect(!source.contains("thisStringIsNotInTheFile"))
    }

    // MARK: Source helpers

    static func editor() throws -> String { try source("ContentView+Editor.swift") }

    /// A MacApp file with its comments removed, so prose describing the wiring cannot satisfy a
    /// scan for it.
    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8), "cannot read \(name)")
        try #require(text.count > 500, "\(name) read as \(text.count) characters — truncated?")
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// One member's body: its declaration to the first closing brace at member indentation.
    static func memberBody(_ declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration), "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }")
        return String(rest[..<(end?.upperBound ?? rest.endIndex)])
    }
}
