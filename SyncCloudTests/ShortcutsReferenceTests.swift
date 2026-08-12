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

        // **Equality against each key a row names, not a substring of them all joined.** Searching
        // the joined string for "⌘ X" is satisfied by any row that merely contains those
        // characters — `⇧⌘ Z` contains `⌘ Z` — so a registered chord could lose its row and this
        // would still pass, which is the one failure it exists to catch. A row may name a pair
        // (`⌘ Z / ⇧⌘ Z`), so the keys are split on the separator first; the split is on `" / "`
        // and not on `"/"` because a slash is also a KEY — the row for this very panel is `⌘ /`.
        let listed = Self.listedChordKeys()
        for key in registered.sorted() {
            #expect(listed.contains("⌘\(key)"),
                    "⌘\(key) is registered in the menus but has no row in the ⌘/ reference")
        }
    }

    /// Every chord a reference row names, one per element, whitespace removed.
    static func listedChordKeys() -> Set<String> {
        Set(ShortcutsReference.groups.flatMap { $0.items }.flatMap { item in
            item.keys.components(separatedBy: " / ")
                .map { $0.replacingOccurrences(of: " ", with: "") }
        })
    }

    /// The guard on the guard: the matcher must be able to say no, and must not confuse a chord
    /// with a modified version of it.
    @Test func testTheChordMatcherRejectsAChordThatIsNotListed() {
        let listed = Self.listedChordKeys()
        #expect(!listed.contains("⌘⌥Q"), "the matcher accepts a chord nothing lists")
        #expect(listed.contains("⌘/"), "splitting the keys lost the chord whose key IS a slash")
        #expect(!listed.contains(""), "an empty key survived the split")
        // `⌘ Z` and `⇧⌘ Z` are different chords and the reference lists them in one row; each must
        // be found as itself, and neither may stand in for the other.
        #expect(listed.contains("⌘Z"))
        #expect(listed.contains("⇧⌘Z"))
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
