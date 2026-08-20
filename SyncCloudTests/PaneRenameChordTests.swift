@testable import SyncCloud
import Testing
import AppKit

/// ↩ renames — and the two things that must stay true about how it is wired.
@MainActor
@Suite struct PaneRenameChordTests {

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp").appendingPathComponent(name)
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — this scan would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short")
        return text
    }

    /// **↩ is never a menu key equivalent.** It outranks the field editor and every default button,
    /// so registering it would take the key that commits the destination picker, the ⌘K field and
    /// every sheet. Finder does not register it either. This scans the whole of `MacApp/` rather
    /// than one file, because the damage is the same wherever it is written.
    @Test func returnIsNotRegisteredAsAChordAnywhere() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp")
        let urls = try #require(try? FileManager.default.contentsOfDirectory(at: dir,
                                                                            includingPropertiesForKeys: nil),
                                "cannot list MacApp/ — this check would be vacuous")
        let swift = urls.filter { $0.pathExtension == "swift" }
        try #require(swift.count > 10, "MacApp/ listed \(swift.count) files — the reader is broken")
        for url in swift {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            #expect(!text.contains("keyboardShortcut(.return"),
                    "\(url.lastPathComponent) registers ↩ as a key equivalent — it would outrank every default button in the app")
            #expect(!text.contains("keyboardShortcut(.defaultAction, modifiers:"),
                    "\(url.lastPathComponent) puts modifiers on the default action, which is ↩ with extra steps")
        }
    }

    /// It is wired where Space is — on the file list, focus-scoped — so it fires only while the
    /// list holds focus and never while the caret is in a field.
    @Test func returnIsWiredOnTheFileListBesideSpace() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains(".onKeyPress(.space) { paneQuickLook() }"),
                "Space has moved — this check has stopped covering the list it is scoped to")
        #expect(content.contains(".onKeyPress(.return) { paneRename() }"),
                "↩ is not wired on the file list beside Space")
    }

    /// **The chord and the menu item run one closure.** `paneRename()` reads
    /// `shortcutPaneRowVerbs.rename`, which is what File ▸ Rename reads, so the two cannot come to
    /// disagree about when a rename is possible or what it renames.
    @Test func theChordRunsTheMenuItemsOwnAction() throws {
        let search = try Self.source("ContentView+PaneSearch.swift")
        let handler = try #require(search.range(of: "func paneRename()"),
                                   "the ↩ handler is gone or has moved out of this file")
        let body = String(search[handler.upperBound...].prefix(300))
        #expect(body.contains("shortcutPaneRowVerbs.rename"),
                "↩ resolves its own rename target — it must share the menu item's, or the two will drift")
        #expect(body.contains("return .ignored"),
                "↩ swallows the key when a rename is not possible, so nothing else can have it")
    }
}
