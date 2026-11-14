import SwiftUI
import Testing
import Foundation
@testable import Design

/// Pins every chord's rendered display. The display is derived from the registration, so these
/// are really pins on the registration: changing a chord's key or modifiers fails here by name.
@Suite struct AppChordTests {

    @Test func everyChordRendersItsDocumentedDisplay() {
        #expect(AppChord.settings.display == "⌘,")
        #expect(AppChord.infoInspector.display == "⌘I")
        #expect(AppChord.askClaude.display == "⌘J")
        #expect(AppChord.activityLog.display == "⌘L")
        #expect(AppChord.shortcutsReference.display == "⌘/")
        #expect(AppChord.commandPalette.display == "⌘K")
        #expect(AppChord.selectAll.display == "⌘A")
        #expect(AppChord.cut.display == "⌘X")
        #expect(AppChord.copy.display == "⌘C")
        #expect(AppChord.paste.display == "⌘V")
        #expect(AppChord.findInPane.display == "⌘F")
        #expect(AppChord.paneBack.display == "⌘[")
        #expect(AppChord.paneForward.display == "⌘]")
        // Function-key code points: without `keyGlyph`'s ↑/↓ arms `display` renders an
        // unprintable glyph, a blank box on a keycap.
        #expect(AppChord.openSelectedFolder.display == "⌘↓")
        #expect(AppChord.enclosingFolder.display == "⌘↑")
        #expect(AppChord.rescan.display == "⌘R")
        #expect(AppChord.newFolder.display == "⇧⌘N")
        #expect(AppChord.folderSidebar.display == "⌃⌘S")
        // ⌘S beside ⌃⌘S and ⌘N beside ⇧⌘N are four separate chords: `noTwoChordsCollide`
        // compares key and modifiers.
        #expect(AppChord.saveDocument.display == "⌘S")
        #expect(AppChord.newTextFile.display == "⌘N")
        #expect(AppChord.printDocument.display == "⌘P")
        #expect(AppChord.openInEditor.display == "⌘O")
        #expect(AppChord.hiddenFiles.display == "⇧⌘.")
        #expect(AppChord.deleteSelection.display == "⌘⌫")
        #expect(AppChord.switchPaneFocus.display == "⌃⇥")
        // The four directional transfers. The arrows are function-key code points, so these pin a
        // glyph the keycap supplies by hand; without it `display` renders an unprintable box.
        #expect(AppChord.copyToLeft.display == "⌘←")
        #expect(AppChord.copyToRight.display == "⌘→")
        #expect(AppChord.moveToLeft.display == "⇧⌘←")
        #expect(AppChord.moveToRight.display == "⇧⌘→")
        // The tabs. ⌘T/⌘W are Finder's; the cycle pair is shifted so the unshifted ⌘[ / ⌘] stay
        // pane back/forward, and ⇧⌘T is View ▸ Tab Bar (Reopen Closed Tab has no chord).
        #expect(AppChord.newTab.display == "⌘T")
        #expect(AppChord.closeTab.display == "⌘W")
        #expect(AppChord.nextTab.display == "⇧⌘]")
        #expect(AppChord.previousTab.display == "⇧⌘[")
        #expect(AppChord.previousTabControl.display == "⌃⇧⇥")
        #expect(AppChord.tabBar.display == "⇧⌘T")
        #expect(AppChord.reviewDifferences.display == "⇧⌘R")
        #expect(AppChord.verifyDifferences.display == "⇧⌘V")
        #expect(AppChord.differencesList.display == "⌘D")
        #expect(AppChord.foldAllDifferences.display == "⇧⌘F")
        #expect(AppChord.compareTwoFiles.display == "⇧⌘C")
        // View ▸ Text Size. The "-" KEY renders as a minus sign, not a hyphen — a keycap reading
        // "⌘-" beside "⌘+" looks like a typo, and the ⌘/ reference already spells the pair this way.
        #expect(AppChord.textBigger.display == "⌘+")
        #expect(AppChord.textSmaller.display == "⌘−")
        #expect(AppChord.textDefaultSize.display == "⌘0")
        // The Text and Markup menus. ⌃⌘ digits, because ⌘1…⌘4 are the workspaces and ⌥ is
        // barred; the inline verbs take the platform's own letters.
        #expect(AppChord.editorSourceMode.display == "⌃⌘1")
        #expect(AppChord.editorPreviewMode.display == "⌃⌘2")
        #expect(AppChord.editorSplitMode.display == "⌃⌘3")
        // Text ▸ Expand: the modes' ⌃⌘, on a letter, and not ⌘E, which is the find bar's.
        #expect(AppChord.editorExpand.display == "⌃⌘E")
        #expect(AppChord.findNext.display == "⌘G")
        #expect(AppChord.findPrevious.display == "⇧⌘G")
        #expect(AppChord.useSelectionForFind.display == "⌘E")
        // Text ▸ Go to Line…: the modes' ⌃⌘ again, on L; not ⌘L (the activity log) and not
        // ⇧⌘L (Markup ▸ Link).
        #expect(AppChord.goToLine.display == "⌃⌘L")
        // View ▸ Text Files: ⌃⌘ on T; not ⌘T (New Tab) and not ⇧⌘T (the tab bar).
        #expect(AppChord.editorTextFiles.display == "⌃⌘T")
        #expect(AppChord.bold.display == "⌘B")
        #expect(AppChord.strikethrough.display == "⇧⌘X")
        #expect(AppChord.inlineCode.display == "⇧⌘K")
        #expect(AppChord.link.display == "⇧⌘L")
        // The progress capsule's stop: ⌘. — and not ⇧⌘. above, which is the hidden-files toggle.
        #expect(AppChord.cancelOperation.display == "⌘.")
        #expect(AppChord.workspace(1)?.display == "⌘1")
        #expect(AppChord.workspace(5)?.display == "⌘5")
        // Past nine there is no chord: `Character.init(String)` traps on a two-digit ordinal at
        // menu-bar construction, and the app would not open.
        #expect(AppChord.workspace(10) == nil)
        #expect(AppChord.workspace(0) == nil)
        // Live fixture for `aCommentedPinDoesNotCountAsAPin`; it must sit here, because the scan
        // reads only this member. AppChordDecoyMarker.display == "⌘0"
    }

    /// The reveal's look-release-press contract holds only while no registered chord contains ⌥:
    /// an ⌥-chord fires from inside the ⌥-hold, aliasing whatever badge the user is reading.
    /// Guards the invariant itself, not one case.
    @Test func noChordContainsOptionSoNothingFiresThroughTheReveal() {
        // `AppChord.registry` plus the workspace family, which is parameterised and so not in it.
        // Re-typing the members here would let a new chord escape every "for every chord" test.
        let all: [AppChord] = AppChord.registry + (1...9).compactMap { AppChord.workspace($0) }
        for chord in all {
            #expect(!chord.modifiers.contains(.option),
                    "\(chord.display) contains ⌥ and would fire from inside the ⌥-hold reveal")
        }
    }

    /// Every chord's spoken form contains no bare punctuation — the speech table must keep pace
    /// with the keys the chords actually use ("Command ." is announced as just "Command").
    @Test func everyChordSpeaksWithoutBarePunctuation() {
        for chord in AppChord.registry {
            let spoken = ShortcutKeycapSpeech.spoken(chord.display)
            #expect(!spoken.contains(where: { "[]./,⌫⇥".contains($0) }),
                    "\(chord.display) speaks as “\(spoken)” — add the key to ShortcutKeycapSpeech")
        }
    }

    /// No two chords share a key equivalent: AppKit would silently pick one, leaving the other a
    /// chord that does nothing. Compared on key character and modifier set, not `display`, which
    /// two chords could render alike.
    @Test func noTwoChordsCollide() {
        var seen: [String: Int] = [:]
        for chord in AppChord.registry {
            let key = "\(chord.key.character)|\(chord.modifiers.rawValue)"
            seen[key, default: 0] += 1
        }
        let collisions = seen.filter { $0.value > 1 }.keys.sorted()
        #expect(collisions.isEmpty, "two registered chords share a key equivalent: \(collisions)")
    }

    /// ⌘I is one chord with two meanings, routed at press time, so `italic` is an alias of
    /// `infoInspector`, not a second `static let` (which `noTwoChordsCollide` would rightly fail).
    /// Pinned as an identity, not a display: two different chords could render alike.
    @Test func italicIsTheInspectorsChordNotASecondOne() {
        #expect(AppChord.italic.key == AppChord.infoInspector.key)
        #expect(AppChord.italic.modifiers == AppChord.infoInspector.modifiers)
        // …and it is the ONLY member of the inline-verb family sharing a key with anything.
        let inline = [AppChord.bold, .strikethrough, .inlineCode, .link]
        for chord in inline {
            #expect(AppChord.registry.filter {
                $0.key.character == chord.key.character && $0.modifiers == chord.modifiers
            }.count == 1, "\(chord.display) is registered by more than one member")
        }
    }

    /// AppKit's spelling of a chord, for the one menu built by hand (the editor's Markup context
    /// menu). Both halves, because a key with the wrong mask is a different chord that draws right.
    @Test func theAppKitSpellingCarriesTheKeyAndTheWholeMask() {
        #expect(AppChord.bold.appKitKeyEquivalent == "b")
        #expect(AppChord.bold.appKitModifierMask == .command)
        #expect(AppChord.strikethrough.appKitKeyEquivalent == "x")
        #expect(AppChord.strikethrough.appKitModifierMask == [.shift, .command])
        #expect(AppChord.editorSourceMode.appKitModifierMask == [.control, .command])
        // The key, never the display glyph: AppKit wants "-" and draws the minus itself.
        #expect(AppChord.textSmaller.appKitKeyEquivalent == "-")
    }

    /// …and none of them collides with the workspace family, which is generated rather than
    /// declared and so invisible to the check above: ⌘1…⌘N are the workspaces', so tabs have no
    /// ⌘-digit.
    @Test func noChordCollidesWithAWorkspaceDigit() {
        let digits = Set((1...9).compactMap { AppChord.workspace($0).map { String($0.key.character) } })
        for chord in AppChord.registry where chord.modifiers == .command {
            #expect(!digits.contains(String(chord.key.character)),
                    "\(chord.display) collides with a workspace's ⌘-digit")
        }
    }

    /// Every `static let <name> = AppChord(` declaration in `AppChord.swift` (`workspace(_:)` is a
    /// `static func`, rightly not counted). Parsed over the whitespace-collapsed file, so a
    /// declaration wrapped onto two lines is still seen; line by line it would be missing here and
    /// from the registry alike, and the count would balance.
    static func declaredChordNames() throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Design/AppChord.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read AppChord.swift — this scan would be vacuous")
        try #require(source.count > 500, "AppChord.swift is implausibly short")

        let flattened = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var declared: Set<String> = []
        for fragment in flattened.components(separatedBy: "static let ").dropFirst() {
            let name = fragment.prefix { $0.isLetter || $0.isNumber }
            guard fragment.dropFirst(name.count).hasPrefix(" = AppChord(") else { continue }
            declared.insert(String(name))
        }
        // `#require`, not `#expect`: a parser that silently matched nothing makes every caller
        // below pass over an empty list, which is the one failure a coverage scan cannot report.
        try #require(declared.contains("settings"), "the scan found no declarations — it is vacuous")
        try #require(declared.count >= 20,
                     "only \(declared.count) chords parsed — the scan is near-vacuous")
        return declared
    }

    /// The hand-written `AppChord.registry` holds every declared chord; one left out would be
    /// invisible to every "for every chord" test that reads the registry.
    @Test func everyDeclaredChordIsInTheRegistry() throws {
        let declared = try Self.declaredChordNames()
        // Distinct first, or a member listed twice would balance the count while a new chord is
        // missing.
        #expect(Set(AppChord.registry.map(\.display)).count == AppChord.registry.count,
                "two registry entries render the same display — a duplicate can mask an omission")
        #expect(declared.count == AppChord.registry.count,
                """
                \(declared.count) chords are declared but the registry holds \(AppChord.registry.count) \
                — declared: \(declared.sorted().joined(separator: ", "))
                """)
    }

    /// The pin test's body with comments cut, trailing ones included: cut at `//`, not the first
    /// `/`, because `⌘/` is a pinned display. Scoped to that one test, so a pin in any other member
    /// or a disabled test doesn't count (as in
    /// `ShortcutCommandsTests.bothReasonsToSuspendTheChordsSurviveInTheExpression`).
    static func pinnedDisplayExpectations() throws -> String {
        let raw = try #require(try? String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8),
                               "cannot read this test file — the coverage scan would be vacuous")
        try #require(raw.count > 500, "this file is implausibly short — the scan would be vacuous")
        let declaration = "@Test func everyChordRendersItsDocumentedDisplay() {"
        let start = try #require(raw.range(of: declaration),
                                 "the pin test is gone — this scan would be vacuous")
        let rest = raw[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"),
                               "the pin test never closes at member indentation")
        let body = rest[..<end.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
        // A known pin must survive the slicing and the stripping, or every check below passes over
        // an empty string — the one failure a coverage scan cannot report on its own.
        try #require(body.contains("AppChord.settings.display =="),
                     "the slice of the pin test holds no pins — the scan is vacuous")
        return body
    }

    /// Every declared chord is pinned by `everyChordRendersItsDocumentedDisplay`. The pins stay
    /// hand-written (a pin derived from its value asserts nothing), but their list is derived, so a
    /// new chord fails here the day it is declared.
    @Test func everyDeclaredChordIsPinnedByADisplayExpectation() throws {
        let declared = try Self.declaredChordNames()
        let own = try Self.pinnedDisplayExpectations()
        for name in declared.sorted() {
            #expect(own.contains("AppChord.\(name).display =="),
                    "\(name) is declared and registered, but no test pins what it renders")
        }
    }

    /// The scan above refuses a pin that is only a comment, proved on a decoy: a comment naming a
    /// display, planted in `everyChordRendersItsDocumentedDisplay` itself, since the scoping would
    /// refuse a decoy anywhere else and prove nothing about the stripping.
    @Test func aCommentedPinDoesNotCountAsAPin() throws {
        let stripped = try Self.pinnedDisplayExpectations()
        #expect(!stripped.contains("AppChordDecoyMarker"),
                "a trailing comment survives the stripper, so a chord 'pinned' in prose passes the scan")
        // …and the scan must be reading the pin test alone: this file's other members mention
        // `.display` constantly (the failure messages above), and none of them is a pin.
        #expect(!stripped.contains("chord.display"),
                "the scan is reading the whole file again, so a pin in any member — or in a disabled test — counts")
    }
}
