import SwiftUI
import Testing
import Foundation
@testable import Design

/// Pins every chord's rendered display. The display is derived from the registration, so these
/// are really pins on the REGISTRATION: changing a chord's key or modifiers fails here by name,
/// which is the review step the four hand-copied strings never had.
@Suite struct AppChordTests {

    @Test func everyChordRendersItsDocumentedDisplay() {
        #expect(AppChord.settings.display == "⌘,")
        #expect(AppChord.infoInspector.display == "⌘I")
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
        #expect(AppChord.rescan.display == "⌘R")
        #expect(AppChord.newFolder.display == "⇧⌘N")
        #expect(AppChord.hiddenFiles.display == "⇧⌘.")
        #expect(AppChord.previewColumn.display == "⇧⌘P")
        #expect(AppChord.deleteSelection.display == "⌘⌫")
        #expect(AppChord.switchPaneFocus.display == "⌃⇥")
        // The four directional transfers. The arrows are function-key code points, so these pin a
        // GLYPH the keycap has to supply by hand — without it `display` renders an unprintable box,
        // which reads on screen as a font problem rather than a missing case.
        #expect(AppChord.copyToLeft.display == "⌘←")
        #expect(AppChord.copyToRight.display == "⌘→")
        #expect(AppChord.moveToLeft.display == "⇧⌘←")
        #expect(AppChord.moveToRight.display == "⇧⌘→")
        // The tabs. ⌘T/⌘W are Finder's; the cycle pair is SHIFTED so the unshifted ⌘[ / ⌘] stay
        // pane back/forward, and ⇧⌘T is View ▸ Tab Bar rather than Reopen Closed Tab — which has
        // no chord at all and so nothing to pin here.
        #expect(AppChord.newTab.display == "⌘T")
        #expect(AppChord.closeTab.display == "⌘W")
        #expect(AppChord.nextTab.display == "⇧⌘]")
        #expect(AppChord.previousTab.display == "⇧⌘[")
        #expect(AppChord.tabBar.display == "⇧⌘T")
        #expect(AppChord.reviewDifferences.display == "⇧⌘R")
        #expect(AppChord.verifyDifferences.display == "⇧⌘V")
        #expect(AppChord.differencesList.display == "⌘D")
        #expect(AppChord.foldAllDifferences.display == "⇧⌘F")
        #expect(AppChord.workspace(1)?.display == "⌘1")
        #expect(AppChord.workspace(5)?.display == "⌘5")
        // **Past nine there is no chord, and asking for one must not take the app down.**
        // `Character.init(String)` requires exactly one grapheme cluster, so a two-digit ordinal
        // trapped — at menu-bar construction, which is to say the app would not open. Four
        // workspaces exist today; this is the boundary the 1…9 loops below never approach.
        #expect(AppChord.workspace(10) == nil)
        #expect(AppChord.workspace(0) == nil)
        // The live fixture for `aCommentedPinDoesNotCountAsAPin`: a trailing comment inside this
        // very body, naming a chord the way a real pin does. It has to sit HERE — the coverage scan
        // reads this member and nothing else, so a decoy anywhere else would prove only the
        // scoping. AppChordDecoyMarker.display == "⌘0"
    }

    /// The reveal's look-release-press contract holds only while NO registered chord contains ⌥
    /// — an ⌥-chord fires from inside the ⌥-hold, aliasing whatever badge the user is reading
    /// (the first cut's ⌥⌘F folded every folder under a user pressing "⌘F"). Guard the invariant
    /// itself, not the one case that violated it.
    @Test func noChordContainsOptionSoNothingFiresThroughTheReveal() {
        // `AppChord.registry` plus the workspace family, which is parameterised and so is not in
        // it. Re-typing the members here is what let a chord be added without every "for every
        // chord" test seeing it — the same hand-copy this type exists to remove.
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

    /// **The registry holds every chord that is declared.**
    ///
    /// `AppChord.registry` is a hand-written array, which is the one seam left in a type whose
    /// argument is that a chord is written down once: a `static let` added below it would be
    /// registered, rendered, and invisible to all three "for every chord" tests that read the
    /// registry. Counted from the source, so adding a member without listing it fails here rather
    /// than silently narrowing what the other tests cover.
    /// **No two chords are the same chord.** The registry exists so a chord is declared once; it
    /// cannot stop two of them being declared identically, and two menu items sharing a key
    /// equivalent is not a build error — AppKit simply picks one, so the loser looks like a chord
    /// that does nothing. Worth an invariant now that the app registers nineteen of them.
    ///
    /// Compared on what actually reaches the responder chain — the key character and the modifier
    /// set — rather than on `display`, which two different chords could in principle render alike.
    @Test func noTwoChordsCollide() {
        var seen: [String: Int] = [:]
        for chord in AppChord.registry {
            let key = "\(chord.key.character)|\(chord.modifiers.rawValue)"
            seen[key, default: 0] += 1
        }
        let collisions = seen.filter { $0.value > 1 }.keys.sorted()
        #expect(collisions.isEmpty, "two registered chords share a key equivalent: \(collisions)")
    }

    /// …and none of them collides with the workspace family, which is generated rather than
    /// declared and so is invisible to the check above. This is the one the tab work had to think
    /// about: ⌘1…⌘N are the workspaces', which is why tabs deliberately have no ⌘-digit.
    @Test func noChordCollidesWithAWorkspaceDigit() {
        let digits = Set((1...9).compactMap { AppChord.workspace($0).map { String($0.key.character) } })
        for chord in AppChord.registry where chord.modifiers == .command {
            #expect(!digits.contains(String(chord.key.character)),
                    "\(chord.display) collides with a workspace's ⌘-digit")
        }
    }

    /// Every `static let <name> = AppChord(` declaration in `AppChord.swift`.
    ///
    /// The parameterised `workspace(_:)` is a `static func` and so is correctly not counted.
    /// Counted over the whitespace-collapsed whole file rather than line by line, so a declaration
    /// whose initialiser wraps (`static let x =` / newline / `AppChord(…)`) is still seen. Line-
    /// scoped, such a member would be invisible here AND absent from the registry — the count
    /// would balance and the chord would reach none of the sweeps that read this.
    ///
    /// Shared by the two tests below, which ask different questions of the same list: that every
    /// declared chord is in `registry`, and that every declared chord has a display pin. A second
    /// copy of the parser would be one more place for the list to go stale.
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

    @Test func everyDeclaredChordIsInTheRegistry() throws {
        let declared = try Self.declaredChordNames()
        // **Distinct first, or the count proves nothing.** `registry` is a plain array: listing one
        // member twice balances the count while a genuinely new chord is missing, which is exactly
        // the omission this test exists to catch. Every chord this app registers renders a
        // different display, so uniqueness there is a real property and not an accident.
        #expect(Set(AppChord.registry.map(\.display)).count == AppChord.registry.count,
                "two registry entries render the same display — a duplicate can mask an omission")
        #expect(declared.count == AppChord.registry.count,
                """
                \(declared.count) chords are declared but the registry holds \(AppChord.registry.count) \
                — declared: \(declared.sorted().joined(separator: ", "))
                """)
    }

    /// **Every declared chord is pinned by `everyChordRendersItsDocumentedDisplay`.**
    ///
    /// The pins themselves stay hand-written — a pin derived from the value it pins asserts
    /// nothing — but the LIST of them is derived, because the hand-written list is what went
    /// stale: the tab work declared five chords (⌘T, ⌘W, ⇧⌘], ⇧⌘[, ⇧⌘T) that were registered on
    /// menu items and rendered on keycaps with no test naming any of them, so a slip in any of
    /// their modifiers would have failed nothing. The other "for every chord" tests could not see
    /// it — they read `registry`, which the five were correctly in.
    ///
    /// So the next chord fails here on the day it is declared, rather than on the day someone
    /// remembers this file.
    /// **Scoped to the pin test's own body, and with TRAILING comments cut too.**
    ///
    /// Two holes the first cut left, both of them the decoy this scan exists to refuse:
    ///
    /// - It dropped only WHOLE-LINE `//` comments, so `#expect(true)  // AppChord.newTab.display ==
    ///   "⌘T"` satisfied it while nothing pinned ⌘T — the exact hazard
    ///   `ShortcutCommandsTests.bothReasonsToSuspendTheChordsSurviveInTheExpression` was rewritten
    ///   to defeat, reintroduced here. Cut at `//` rather than at the first `/`, because `⌘/` is a
    ///   real display string this file pins.
    /// - It searched the WHOLE file, so a pin sitting in a disabled or deleted-but-not-yet-removed
    ///   test — or in any other member — counted. The pins live in one named test; that is where
    ///   they are looked for.
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

    @Test func everyDeclaredChordIsPinnedByADisplayExpectation() throws {
        let declared = try Self.declaredChordNames()
        let own = try Self.pinnedDisplayExpectations()
        for name in declared.sorted() {
            #expect(own.contains("AppChord.\(name).display =="),
                    "\(name) is declared and registered, but no test pins what it renders")
        }
    }

    /// **The scan above refuses a pin that is only a comment.** Proved rather than asserted about:
    /// a decoy in this file's own text — a trailing comment naming a chord, which is what the first
    /// cut accepted — must not appear in what the scan reads.
    ///
    /// The decoy is planted inside `everyChordRendersItsDocumentedDisplay` itself — a real trailing
    /// comment naming a display, on the last line of the member the scan reads — because a decoy
    /// anywhere else would be refused by the scoping and prove nothing about the stripping.
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
