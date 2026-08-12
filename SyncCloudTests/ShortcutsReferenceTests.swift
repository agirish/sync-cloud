import Testing
import Foundation
import Design
@testable import SyncCloud

/// Pins the shortcuts reference's shape: the three expected groups exist, every row has
/// both keys and an action, and no action is listed twice within a group. The CONTENT is a
/// hand-maintained mirror of the real bindings — update it alongside any shortcut change.
@Suite struct ShortcutsReferenceTests {

    @Test func testGroupsCoverTheExpectedAreas() {
        #expect(ShortcutsReference.groups.map(\.title) == ["General", "Panes", "Differences", "Guided review"])
    }

    @Test func testEveryItemHasKeysAndAction() {
        for group in ShortcutsReference.groups {
            #expect(!group.items.isEmpty)
            for item in group.items {
                #expect(!item.keys.isEmpty)
                #expect(!item.action.isEmpty)
            }
        }
    }

    @Test func testActionsAreUniqueWithinEachGroup() {
        for group in ShortcutsReference.groups {
            let actions = group.items.map(\.action)
            #expect(Set(actions).count == actions.count)
        }
    }

    /// **Every chord in `AppChord.registry` has a row here.**
    ///
    /// Not a hand-typed list of chords, which is what this was: `AppChord` exists so a chord is
    /// declared once, and a test that re-types them all to check them is the same hand-copy the
    /// type was introduced to remove — it can only ever pin what someone remembered to add to it.
    /// The registry is the list; this compares against it.
    ///
    /// Whitespace-insensitive, because the reference spaces its keys for reading (`⇧⌘ N`) while a
    /// chord renders tight (`⇧⌘N`): one chord, formatted for two places.
    @Test func testEveryRegisteredChordHasAReferenceRow() {
        let listed = ShortcutsReference.groups.flatMap(\.items)
            .map { $0.keys.replacingOccurrences(of: " ", with: "") }
        #expect(listed.count > 10, "the reference is implausibly short — this scan would be near-vacuous")
        for chord in AppChord.registry {
            let display = chord.display.replacingOccurrences(of: " ", with: "")
            #expect(listed.contains { $0.contains(display) },
                    "no reference row lists \u{201C}\(chord.display)\u{201D}")
        }
    }

    /// The workspace range is a family rather than a chord, so it is checked on its own.
    @Test func testTheWorkspaceRangeHasARow() {
        let keys = ShortcutsReference.groups.flatMap(\.items).map(\.keys)
        #expect(keys.contains("⌘ 1 – ⌘ \(Workspace.allCases.count)"))
    }

    /// **And every chord registered OUTSIDE `AppChord` has a row too.**
    ///
    /// The registry cannot see a `.keyboardShortcut("?", modifiers: .command)` written directly on
    /// a menu item, and ⌘? — "SyncCloud Help" — was exactly that: registered, unlisted, in the
    /// panel a person opens to find out what the app can do. Read out of the source, so the answer
    /// comes from what is registered rather than from what someone remembered.
    @Test func testEveryLiterallyRegisteredCommandChordHasAReferenceRow() throws {
        let macApp = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp")
        let files = try #require(try? FileManager.default.contentsOfDirectory(at: macApp,
                                                                             includingPropertiesForKeys: nil),
                                 "cannot list MacApp/ — this scan would be vacuous")
        var registered: Set<String> = []
        for url in files where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains(".keyboardShortcut(\"") else { continue }
                guard let open = code.range(of: ".keyboardShortcut(\""),
                      let close = code[open.upperBound...].firstIndex(of: "\"") else { continue }
                let key = String(code[open.upperBound..<close])
                guard key.count == 1, code.contains("modifiers: .command") else { continue }
                registered.insert(key)
            }
        }
        // Non-vacuity: the reader found the literal registration that certainly exists.
        #expect(registered.contains("?"), "the scan found no ⌘? — it is not reading the menus")

        let listed = ShortcutsReference.groups.flatMap(\.items)
            .map { $0.keys.replacingOccurrences(of: " ", with: "") }
        for key in registered.sorted() {
            #expect(listed.contains { $0.contains("⌘\(key.uppercased())") },
                    "⌘\(key) is registered in the menus but has no row in the ⌘/ reference")
        }
    }

    /// Numbering the workspaces by bar position assumes every one fits behind a single digit.
    /// Another still fits; a tenth does not — this fails first, before someone ships a chord with
    /// two digits in it, which cannot exist.
    @Test func testEveryWorkspaceIsReachableByASingleDigitChord() {
        #expect(Workspace.allCases.count <= 9)
    }

    /// ...and the reference's workspace row must count the same list: a sixth workspace would
    /// otherwise ship with a row still reading "⌘ 1 – ⌘ 3" and every shape test green.
    @Test func testTheWorkspaceRowCountsEveryWorkspace() {
        let expected = "⌘ 1 – ⌘ \(Workspace.allCases.count)"
        let keys = ShortcutsReference.groups.flatMap(\.items).map(\.keys)
        #expect(keys.contains(expected), "no row lists “\(expected)”")
    }

    /// No row may advertise dragging or dropping.
    ///
    /// Cross-pane drag & drop was removed in `4d55246`, but this reference kept listing
    /// "⇧ or ⌘ while dropping — Move instead of copy when dragging between panes" until
    /// `94f1776`'s follow-up, because every test above pins only the SHAPE: groups exist, rows
    /// are non-empty, actions are unique. A row can therefore describe a feature that no longer
    /// exists and stay green — which is exactly what happened, in a panel the user opens with ⌘/
    /// to find out what the app can do.
    ///
    /// If a future feature legitimately involves dragging (resizing a divider, say), narrow this
    /// to the cross-pane transfer wording rather than deleting it.
    @Test func testNoRowAdvertisesDragAndDrop() {
        for group in ShortcutsReference.groups {
            for item in group.items {
                let text = "\(item.keys) \(item.action)".lowercased()
                #expect(!text.contains("drag"), "\(group.title): “\(item.action)” mentions dragging")
                #expect(!text.contains("drop"), "\(group.title): “\(item.action)” mentions dropping")
            }
        }
    }
}
