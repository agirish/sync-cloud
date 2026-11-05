@testable import SyncCloud
import Testing
import AppKit

/// ↩ renames, and what must stay true about how it is wired.
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

    /// **Never** register ↩ as a menu key equivalent: it outranks the field editor and every
    /// default button, so it would take the key that commits the destination picker, the ⌘K field
    /// and every sheet. Finder doesn't register it either. Scans all of `MacApp/`, since the damage
    /// is the same wherever it is written.
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

    /// Wired where Space is, on the file list, focus-scoped, so it fires only while the list holds
    /// focus and never while the caret is in a field. Asserted on where the handler sits and what
    /// it calls, not its overload: which overload is right (it takes the keypad's Enter too) is
    /// `thePanesRenameKeyTakesBothEnterKeycapsAndRefusesChords`'s question, in
    /// `Modules/FileExplorer/Tests/FileExplorer/BareKeyEquivalentScanTests.swift`.
    ///
    /// These call-site scans run only in the app target, so a change checked with
    /// `xcodebuild build` instead of `xcodebuild test` can break them unseen.
    @Test func returnIsWiredOnTheFileListBesideSpace() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains(".onKeyPress(.space) { paneQuickLook() }"),
                "Space has moved — this check has stopped covering the list it is scoped to")

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let listModifier = "                .onKeyPress("        // 16 spaces: the list's own level
        let spaceAt = try #require(lines.firstIndex { $0.hasPrefix(listModifier)
                                                      && $0.contains(".space") },
                                   "Space is not an `onKeyPress` at the file list's indentation")
        // The next handler at exactly that indentation, and everything up to the modifier after it.
        let renameAt = try #require(lines[(spaceAt + 1)...].firstIndex { $0.hasPrefix(listModifier) },
                                    "there is no second key handler on the file list — ↩ is unwired")
        let end = lines[(renameAt + 1)...].firstIndex { $0.hasPrefix("                .")
                                                        && !$0.hasPrefix(listModifier) }
            ?? lines.endIndex
        let handler = lines[renameAt..<end].joined(separator: "\n")
        #expect(handler.contains("paneRename()"),
                """
                the handler on the file list after Space does not call `paneRename()` — ↩ is not \
                wired beside Space. What is there instead: \(handler)
                """)
    }

    /// The chord and the menu item run one closure: `paneRename()` reads
    /// `shortcutPaneRowVerbs.rename`, as File ▸ Rename does, so they can't disagree about when a
    /// rename is possible or what it renames.
    @Test func theChordRunsTheMenuItemsOwnAction() throws {
        let search = try Self.source("ContentView+PaneSearch.swift")
        let handler = try #require(search.range(of: "func paneRename()"),
                                   "the ↩ handler is gone or has moved out of this file")
        // Wide enough to hold the handler with its suspension guard and comments: a window tighter
        // than the body fails for the wrong reason.
        let body = String(search[handler.upperBound...].prefix(900))
        #expect(body.contains("shortcutPaneRowVerbs.rename"),
                "↩ resolves its own rename target — it must share the menu item's, or the two will drift")
        #expect(body.contains("return .ignored"),
                "↩ swallows the key when a rename is not possible, so nothing else can have it")
    }

    /// ↩ and Space are suspended while a surface owns the keyboard, like every mirrored menu chord.
    /// `suspended:` on the focused-value publication silences only the menu items, and these are
    /// `.onKeyPress` handlers reading `shortcutPaneRowVerbs` directly. Unguarded, ↩ under a
    /// destination pick would rename the row and swallow the key the picker's default button needs.
    ///
    /// Focus scoping doesn't prevent it: a full-window SwiftUI overlay doesn't take key from the
    /// `NSViewRepresentable` tables under it (why ⌘K is a window, `CommandPalettePanel.swift`).
    /// Scanned at source, since both handlers are `ContentView` extension methods.
    @Test func bothPaneKeyHandlersAskTheSuspensionRule() throws {
        let search = try Self.source("ContentView+PaneSearch.swift")
        for handler in ["func paneRename()", "func paneQuickLook()"] {
            let body = try #require(search.range(of: handler).map { String(search[$0.upperBound...].prefix(600)) },
                                    "\(handler) is gone — this check would be vacuous")
            #expect(body.contains("guard !paneChordsSuspended else { return .ignored }"),
                    "\(handler) does not ask the suspension rule — it fires under the destination picker")
        }
    }

    /// The rule itself, and that the publication reads the same one, not a second copy.
    @Test func theSuspensionRuleIsOneExpression() throws {
        let commands = try Self.source("ShortcutCommands.swift")
        #expect(commands.contains("var paneChordsSuspended: Bool { pendingDestination != nil || showCommandPalette }"),
                "the suspension rule moved or changed shape — the two key handlers name it by hand")
        #expect(commands.contains("suspended: paneChordsSuspended"),
                "the menu publication no longer reads the same rule the key handlers do — two copies is how they come to disagree")
        // An inline copy of the expression is the regression: the key handlers can't see it.
        #expect(!commands.contains("suspended: pendingDestination != nil || showCommandPalette"),
                "the publication went back to its own inline copy of the rule")
    }
}
