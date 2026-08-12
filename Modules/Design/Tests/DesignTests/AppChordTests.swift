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
        #expect(AppChord.findInPane.display == "⌘F")
        #expect(AppChord.paneBack.display == "⌘[")
        #expect(AppChord.paneForward.display == "⌘]")
        #expect(AppChord.rescan.display == "⌘R")
        #expect(AppChord.newFolder.display == "⇧⌘N")
        #expect(AppChord.hiddenFiles.display == "⇧⌘.")
        #expect(AppChord.previewColumn.display == "⇧⌘P")
        #expect(AppChord.deleteSelection.display == "⌘⌫")
        #expect(AppChord.switchPaneFocus.display == "⌃⇥")
        #expect(AppChord.reviewDifferences.display == "⇧⌘R")
        #expect(AppChord.verifyDifferences.display == "⇧⌘V")
        #expect(AppChord.differencesList.display == "⌘D")
        #expect(AppChord.foldAllDifferences.display == "⇧⌘F")
        #expect(AppChord.workspace(1).display == "⌘1")
        #expect(AppChord.workspace(5).display == "⌘5")
    }

    /// The reveal's look-release-press contract holds only while NO registered chord contains ⌥
    /// — an ⌥-chord fires from inside the ⌥-hold, aliasing whatever badge the user is reading
    /// (the first cut's ⌥⌘F folded every folder under a user pressing "⌘F"). Guard the invariant
    /// itself, not the one case that violated it.
    @Test func noChordContainsOptionSoNothingFiresThroughTheReveal() {
        // `AppChord.registry` plus the workspace family, which is parameterised and so is not in
        // it. Re-typing the members here is what let a chord be added without every "for every
        // chord" test seeing it — the same hand-copy this type exists to remove.
        let all: [AppChord] = AppChord.registry + (1...9).map { AppChord.workspace($0) }
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
    @Test func everyDeclaredChordIsInTheRegistry() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Design/AppChord.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read AppChord.swift — this scan would be vacuous")
        try #require(source.count > 500, "AppChord.swift is implausibly short")

        // Every `static let <name> = AppChord(` declaration — the parameterised `workspace(_:)` is
        // a `static func` and so is correctly not counted.
        // Counted over the whitespace-collapsed whole file rather than line by line, so a
        // declaration whose initialiser wraps (`static let x =` / newline / `AppChord(…)`) is still
        // seen. Line-scoped, such a member would be invisible here AND absent from the registry —
        // the count would balance and the chord would reach none of the three sweeps.
        let flattened = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var declared: Set<String> = []
        for fragment in flattened.components(separatedBy: "static let ").dropFirst() {
            let name = fragment.prefix { $0.isLetter || $0.isNumber }
            guard fragment.dropFirst(name.count).hasPrefix(" = AppChord(") else { continue }
            declared.insert(String(name))
        }
        #expect(declared.contains("settings"), "the scan found no declarations — it is vacuous")
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
}
