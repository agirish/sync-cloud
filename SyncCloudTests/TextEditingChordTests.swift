import Testing
import AppKit
import SwiftUI
import Design
@testable import SyncCloud

/// The one rule shared by every menu chord that is also a text-editing key.
///
/// **Why this suite is worth its length.** The rule decides, for five chords and soon two more,
/// whether a keystroke reaches your files or your caret — and it is invisible in every other test,
/// because a menu key equivalent cannot be driven from a unit test at all. `TextEditingChord.route`
/// is the seam that makes it checkable without a window: the responder is injected.
@MainActor
@Suite struct TextEditingChordTests {

    /// A field editor is what AppKit makes first responder whenever any text field holds the caret.
    private func fieldEditor() -> NSTextView { NSTextView(frame: .zero) }

    @Test func aTextViewOwnsTheKeystroke() {
        #expect(TextEditingChord.belongsToTextEditor(fieldEditor()))
    }

    @Test func aFileTableDoesNot() {
        #expect(!TextEditingChord.belongsToTextEditor(NSTableView(frame: .zero)))
    }

    /// **Nothing focused must route to the FILE action, not the editor one.** A cold window has no
    /// first responder, and that is the state a pane is in when you click a row and press ⌘C.
    @Test func noResponderRoutesToTheFileAction() {
        var ran = ""
        TextEditingChord.route(responder: nil,
                               editorAction: { _ in ran = "editor" },
                               fileAction: { ran = "file" })
        #expect(ran == "file")
    }

    @Test func aCaretRoutesToTheEditor() {
        var ran = ""
        TextEditingChord.route(responder: fieldEditor(),
                               editorAction: { _ in ran = "editor" },
                               fileAction: { ran = "file" })
        #expect(ran == "editor")
    }

    /// **The editor branch must hand the real editor over, not merely fire.** Routing to a closure
    /// that ignores its argument would pass the test above while doing nothing on screen — the
    /// failure mode where ⌘C in a text field silently copies nothing.
    @Test func theEditorBranchReceivesTheResponderItMatched() {
        let editor = fieldEditor()
        var received: NSTextView?
        TextEditingChord.route(responder: editor,
                               editorAction: { received = $0 },
                               fileAction: {})
        #expect(received === editor, "the editor branch fired without the editor to act on")
    }

    /// Exactly one branch runs. Written because a router that ran both would satisfy every
    /// assertion above and would, in the live app, copy your files *and* your text.
    @Test(arguments: [true, false])
    func exactlyOneBranchRuns(caretHasFocus: Bool) {
        var editorRuns = 0, fileRuns = 0
        TextEditingChord.route(responder: caretHasFocus ? fieldEditor() : nil,
                               editorAction: { _ in editorRuns += 1 },
                               fileAction: { fileRuns += 1 })
        #expect(editorRuns + fileRuns == 1)
        #expect(editorRuns == (caretHasFocus ? 1 : 0))
    }

    // The tautological alias test that stood here (`belongsToTextEditor(x) ==
    // belongsToTextEditor(x)`, literally self-comparison) was removed 2026-08-22 — the alias it
    // once pinned is long gone. What it wanted to guarantee is now guaranteed structurally:
    // `route` itself decides through `belongsToTextEditor`, so the predicate tests above pin the
    // shipped rule, and the scans below pin that every colliding chord actually calls `route`.

    // MARK: Call-site coverage — the routing has to be WIRED, not merely correct

    /// The exact chords NSText also claims: select-all, cut/copy/paste, delete-to-line-start, the
    /// line moves (⌘←/⌘→, ±⇧ for selection) and the document moves (⌘↑/⌘↓, ±⇧). Chords, not bare
    /// keys — the first cut of this matched any ⌘-chord on these keys and flagged ⇧⌘V, which the
    /// field editor does NOT bind, so a registered ⇧⌘V would have been forced through routing it
    /// does not need. The collision is a property of AppKit's field editor, so this set is stable
    /// while the app's registry grows toward it.
    private static let textEditorClaimedChords: [AppChord] = [
        AppChord("a", .command), AppChord("x", .command),
        AppChord("c", .command), AppChord("v", .command),
        AppChord(.delete, .command),
        AppChord(.leftArrow, .command), AppChord(.rightArrow, .command),
        AppChord(.leftArrow, [.shift, .command]), AppChord(.rightArrow, [.shift, .command]),
        AppChord(.upArrow, .command), AppChord(.downArrow, .command),
        AppChord(.upArrow, [.shift, .command]), AppChord(.downArrow, [.shift, .command]),
    ]

    /// How each colliding chord is spelled at its registration in `ShortcutCommands.swift`.
    /// Hand-written, so it is guarded against registry drift by the set-equality test below: a NEW
    /// chord landing on a text-editing key fails that test until it is named here, and naming it
    /// here is what puts its registration under the routing scan.
    ///
    /// The scheme's boundary, stated rather than implied: it derives from `AppChord.registry`, so
    /// a chord registered as a bare `.keyboardShortcut("c", modifiers: .command)` literal never
    /// enters it and is invisible here. `ShortcutsReferenceTests`' literal scan polices that
    /// boundary for the quoted-key spelling (it forces such a chord into the reference table,
    /// where a text-editing key would be conspicuous) — a chord built from a variable would evade
    /// both, and nothing in the repo registers one that way today.
    private static let collidingRegistrations: [(spelling: String, chords: [AppChord])] = [
        ("AppChord.selectAll.key", [.selectAll]),
        ("AppChord.cut.key", [.cut]),
        ("AppChord.copy.key", [.copy]),
        ("AppChord.paste.key", [.paste]),
        ("AppChord.deleteSelection.key", [.deleteSelection]),
        ("AppChord.transfer(", [.copyToLeft, .copyToRight, .moveToLeft, .moveToRight]),
    ]

    @Test func theCollidingSpellingTableMatchesTheRegistry() {
        let claimed = Set(Self.textEditorClaimedChords.map(\.display))
        let colliding = AppChord.registry.filter { claimed.contains($0.display) }
        let tabled = Self.collidingRegistrations.flatMap(\.chords)
        #expect(Set(colliding.map(\.display)) == Set(tabled.map(\.display)),
                """
                the registry's text-editing chords and the spelling table disagree. A chord \
                added on one of NSText's own bindings must be listed in `collidingRegistrations` \
                so the routing scan covers its registration. Registry: \(colliding.map(\.display)); \
                table: \(tabled.map(\.display))
                """)
        // Non-vacuity: the six known chord families are actually in the derived set.
        #expect(colliding.count >= 9, "the derived colliding set shrank — the filter is broken, not the app")
    }

    /// Every registration of a colliding chord hands the keystroke through `TextEditingChord.route`.
    ///
    /// This is the test whose absence was the finding: `route` was unit-tested to perfection while
    /// nothing pinned that any chord CALLED it — deleting the route from ⌘C would have shipped
    /// "⌘C over a caret copies files" with every suite green.
    /// The file cut into per-command blocks, comments stripped first — comment text can
    /// legitimately name a chord's spelling (and does); only code decides.
    ///
    /// Top-level struct declarations delimit the blocks; nested types are indented and don't
    /// split. The modifier normalization matters: a `private struct` (the file already has
    /// twenty-odd) would otherwise merge silently into the preceding block, and a route call
    /// there would vouch for a command that lost its own.
    private static func registrationBlocks(of source: String) -> [String] {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let slash = line.range(of: "//") { return line[line.startIndex..<slash.lowerBound] }
                return line
            }
            .joined(separator: "\n")
        let normalized = code.replacing(
            #/\n(?:@[A-Za-z]+ )*(?:(?:private|fileprivate|internal|public) )?struct /#,
            with: "\nstruct ")
        return normalized.components(separatedBy: "\nstruct ")
    }

    @Test func everyCollidingChordRegistrationRoutesThroughTextEditingChord() throws {
        let source = try shortcutCommandsSource()
        let blocks = Self.registrationBlocks(of: source)
        try #require(blocks.count > 10, "ShortcutCommands.swift split into \(blocks.count) blocks — the scan is broken")

        for (spelling, chords) in Self.collidingRegistrations {
            let registering = blocks.filter { $0.contains(".keyboardShortcut(") && $0.contains(spelling) }
            try #require(!registering.isEmpty,
                         "no block registers \(spelling) — the spelling table is stale, fix the table")
            for block in registering {
                let name = block.prefix(while: { $0 != ":" && $0 != "\n" })
                #expect(block.contains("TextEditingChord.route("),
                        """
                        \(name) registers \(chords.map(\.display).joined(separator: " ")) without \
                        routing through TextEditingChord.route — with the caret in any text field \
                        this chord would act on FILES instead of the text
                        """)
            }
        }
    }

    /// The scan's own failure mode: a matcher that finds nothing fails, never passes. A decoy
    /// spelling that exists nowhere must be reported as stale, proving `#require(!registering
    /// .isEmpty)` really is reachable.
    @Test func theRoutingScanRefusesAStaleSpelling() throws {
        // The same pipeline the real scan uses — a decoy probed against a differently prepared
        // source would prove reachability for a matcher nothing runs.
        let blocks = Self.registrationBlocks(of: try shortcutCommandsSource())
        let registering = blocks.filter { $0.contains(".keyboardShortcut(") && $0.contains("AppChord.decoyNeverRegistered.key") }
        #expect(registering.isEmpty, "the decoy is supposed to match nothing")
    }
}

/// `MacApp/ShortcutCommands.swift` alone, with a truncation guard sized to the file — a partially
/// read file would make every `contains` above answer false and every negative vacuously true.
private func shortcutCommandsSource() throws -> String {
    let text = try macAppFile("ShortcutCommands.swift")
    try #require(text.count > 5_000, "ShortcutCommands.swift read as \(text.count) characters — truncated?")
    return text
}
