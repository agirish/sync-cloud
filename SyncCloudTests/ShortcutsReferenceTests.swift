import Testing
import Foundation
import Design
@testable import SyncCloud

/// Pins the shortcuts reference's shape: the expected groups exist, every row has both keys and an
/// action, and no action is listed twice within a group. The content is a hand-maintained mirror
/// of the real bindings, checked against the registry below: update it with any shortcut change.
@Suite struct ShortcutsReferenceTests {

    @Test func testGroupsCoverTheExpectedAreas() {
        #expect(ShortcutsReference.groups.map(\.title)
                == ["General", "Panes", "Edit", "Tabs", "Differences", "Guided review"])
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

    /// No chord is described by two rows in one group. `testActionsAreUniqueWithinEachGroup`
    /// compares the prose, so the same pair listed twice in different words and order would pass
    /// it, and `testEveryRegisteredChordHasAReferenceRow` asks only whether a chord has a row.
    ///
    /// Split on "/" so a row listing a pair is read as the pair; a range written with "–" (the
    /// workspace digits) stays one token.
    @Test func testNoChordIsListedTwiceWithinAGroup() {
        for group in ShortcutsReference.groups {
            let chords = group.items
                .flatMap { $0.keys.components(separatedBy: "/") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let repeated = Set(chords.filter { chord in chords.filter { $0 == chord }.count > 1 })
            #expect(repeated.isEmpty,
                    "\(group.title) describes \(repeated.sorted().joined(separator: ", ")) in more than one row")
        }
    }

    /// Every chord in `AppChord.registry` has a row here. The registry is the list, so nothing
    /// re-types the chords by hand.
    ///
    /// Whitespace-insensitive, because the reference spaces its keys for reading (`⇧⌘ N`) while a
    /// chord renders tight (`⇧⌘N`). Matched by equality against each key a row lists, not by
    /// substring: `⌘F` is a substring of `⇧⌘ F`, so a substring match would let the ⌘F row go
    /// missing unnoticed.
    @Test func testEveryRegisteredChordHasAReferenceRow() {
        let listed = Self.listedChordKeys()
        #expect(listed.count > 10, "the reference is implausibly short — this scan would be near-vacuous")
        for chord in AppChord.registry {
            #expect(listed.contains(Self.normalized(chord.display)),
                    "no reference row lists \u{201C}\(chord.display)\u{201D}")
        }
    }

    /// The other direction: every ⌘ chord a row names is one the app registers, so no row outlives
    /// its command. Rows for keys that aren't menu commands (clicks, a family, the system's own
    /// items) are named here, so a new one is a decision rather than a pass.
    @Test func testEveryListedCommandChordIsRegistered() {
        let registered = Set(AppChord.registry.map { Self.normalized($0.display) })
        let notCommands: Set<String> = Self.listedKeysThatAreNotRegisteredCommands
        let unregistered = Self.listedChordKeys()
            .filter { $0.contains("⌘") && !registered.contains($0) && !notCommands.contains($0) }
        #expect(unregistered.isEmpty,
                "the reference lists \(unregistered.sorted()) — no command registers it")
    }

    /// Listed ⌘ keys the app does not register through `AppChord`, each with its reason.
    static let listedKeysThatAreNotRegisteredCommands: Set<String> = [
        "⌘-click",   // a mouse gesture, not a key
        "⌘1–⌘4",     // the workspace family, registered as `AppChord.workspace(_:)`, one per tab
        "⌘Z", "⇧⌘Z", // Undo and Redo, the system Edit menu's own items
        "⌘?",        // Help, the system Help menu's own item
    ]

    /// Every chord a reference row names: keys split on the pair separator and whitespace removed,
    /// so they compare against `AppChord.display` as equals. Split on `" / "`, not `"/"`, because a
    /// slash is also a key: the reference's own row is `⌘ /`.
    static func listedChordKeys() -> Set<String> {
        Set(ShortcutsReference.groups.flatMap(\.items).flatMap { item in
            item.keys.components(separatedBy: " / ").map(Self.normalized)
        })
    }

    static func normalized(_ keys: String) -> String {
        keys.replacingOccurrences(of: " ", with: "")
    }

    /// The guard on the guard: the matcher must be able to say no. Every other test here asserts a
    /// presence, which a matcher that always said yes would pass.
    @Test func testTheChordMatcherRejectsAChordThatIsNotListed() {
        let listed = Self.listedChordKeys()
        #expect(!listed.contains(Self.normalized("⌘ ⌥ Q")), "the matcher accepts a chord nothing lists")
        // And the near-miss a substring match accepts: a bare ⌘F must be matched by the ⌘F row,
        // not the ⇧⌘F one.
        #expect(listed.contains("⌘F"))
        #expect(listed.contains("⇧⌘F"))
        #expect(!listed.contains("⌘⇧F"), "the reference spells a modifier order the app never renders")
        // A slash is a key as well as a separator; the row for this very panel is `⌘ /`.
        #expect(listed.contains("⌘/"), "splitting the keys lost the chord whose key IS a slash")
        #expect(!listed.contains(""), "an empty key survived the split")
    }

    /// And every chord registered outside `AppChord` has a row too. The registry can't see a
    /// `.keyboardShortcut("?", modifiers: .command)` written directly on a menu item, so these are
    /// read out of the source.
    @Test func testEveryLiterallyRegisteredCommandChordHasAReferenceRow() throws {
        var registered: Set<String> = []
        for line in try macAppSources().split(separator: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), code.contains(".keyboardShortcut(\"") else { continue }
            guard let open = code.range(of: ".keyboardShortcut(\""),
                  let close = code[open.upperBound...].firstIndex(of: "\"") else { continue }
            let key = String(code[open.upperBound..<close])
            guard key.count == 1, code.contains("modifiers: .command") else { continue }
            registered.insert(key)
        }
        // Non-vacuity: the reader found the literal registration that certainly exists.
        #expect(registered.contains("?"), "the scan found no ⌘? — it is not reading the menus")

        // Equality on split keys, as in the registry check above.
        let listed = Self.listedChordKeys()
        for key in registered.sorted() {
            #expect(listed.contains("⌘\(key.uppercased())"),
                    "⌘\(key) is registered in the menus but has no row in the ⌘/ reference")
        }
    }

    /// Numbering the workspaces by bar position assumes each fits behind a single digit; a tenth
    /// fails here before anyone ships a two-digit chord, which can't exist.
    @Test func testEveryWorkspaceIsReachableByASingleDigitChord() {
        #expect(Workspace.allCases.count <= 9)
    }

    /// ...and the reference's workspace row counts the same list. This is also where the range is
    /// checked for `AppChord.registry`: `workspace(_:)` is a family, not a member, so the registry
    /// sweep can't see it.
    @Test func testTheWorkspaceRowCountsEveryWorkspace() {
        let expected = "⌘ 1 – ⌘ \(Workspace.allCases.count)"
        let keys = ShortcutsReference.groups.flatMap(\.items).map(\.keys)
        #expect(keys.contains(expected), "no row lists “\(expected)”")
    }

    /// No row may advertise dragging or dropping: the app has no cross-pane drag and drop, and the
    /// shape tests above would stay green over a row describing it.
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

    /// No row may advertise a ⌘-double-click. The column row has no gesture to support one
    /// (`PaneColumnRowHasNoGestureTests` refuses it), and ⌘-click is multi-select.
    ///
    /// Narrowed to ⌘ on purpose: a plain double-click on the tab strip's empty stretch opens a tab,
    /// and a row describing that would be true.
    @Test func testNoRowAdvertisesACommandDoubleClick() {
        let rows = ShortcutsReference.groups.flatMap(\.items)
        #expect(rows.count > 10, "the reference is implausibly short — this scan would be near-vacuous")
        for item in rows {
            let text = "\(item.keys) \(item.action)".lowercased()
            #expect(!(text.contains("⌘") && text.contains("double-click")),
                    "“\(item.keys) — \(item.action)” advertises a ⌘-double-click, and no row has one")
        }
    }
}
