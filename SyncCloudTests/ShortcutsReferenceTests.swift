import Testing
import Foundation
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

    /// **Every ⌘-chord the menus actually register has a row here.**
    ///
    /// Read out of the source rather than hand-listed, which is the point: the reference is a
    /// hand-maintained mirror, and every test above pins only its shape, so a chord could be
    /// registered with no row and nothing would say so. ⌘? — "SyncCloud Help" — was exactly that,
    /// registered and unlisted, in the panel a user opens to find out what the app can do.
    ///
    /// Scoped to plain ⌘-letter/punctuation chords declared as `.keyboardShortcut("x", modifiers:
    /// .command)`. `.defaultAction`/`.cancelAction` are Return and esc, which the rows describe in
    /// their own words where they matter.
    @Test func testEveryRegisteredCommandChordHasAReferenceRow() throws {
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
        // Non-vacuity: the reader found the chords that certainly exist.
        #expect(registered.contains(","), "the scan found no ⌘, — it is not reading the menus")
        #expect(registered.contains("/"), "the scan found no ⌘/ — it is not reading the menus")

        let listed = ShortcutsReference.groups.flatMap { $0.items }.map(\.keys).joined(separator: " ")
        for key in registered.sorted() {
            #expect(listed.contains("⌘ \(key)"),
                    "⌘\(key) is registered in the menus but has no row in the ⌘/ reference")
        }
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
