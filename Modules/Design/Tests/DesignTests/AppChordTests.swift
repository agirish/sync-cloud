import SwiftUI
import Testing
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
        let all: [AppChord] = [
            .settings, .infoInspector, .activityLog, .shortcutsReference, .commandPalette,
            .findInPane,
            .paneBack, .paneForward, .rescan, .newFolder, .hiddenFiles, .previewColumn,
            .deleteSelection, .switchPaneFocus, .reviewDifferences, .verifyDifferences,
            .differencesList, .foldAllDifferences,
            .workspace(1), .workspace(2), .workspace(3), .workspace(4), .workspace(5),
        ]
        for chord in all {
            #expect(!chord.modifiers.contains(.option),
                    "\(chord.display) contains ⌥ and would fire from inside the ⌥-hold reveal")
        }
    }

    /// Every chord's spoken form contains no bare punctuation — the speech table must keep pace
    /// with the keys the chords actually use ("Command ." is announced as just "Command").
    @Test func everyChordSpeaksWithoutBarePunctuation() {
        let all: [AppChord] = [
            .settings, .infoInspector, .activityLog, .shortcutsReference, .commandPalette,
            .findInPane,
            .paneBack, .paneForward, .rescan, .newFolder, .hiddenFiles, .previewColumn,
            .deleteSelection, .switchPaneFocus, .reviewDifferences, .verifyDifferences,
            .differencesList, .foldAllDifferences,
        ]
        for chord in all {
            let spoken = ShortcutKeycapSpeech.spoken(chord.display)
            #expect(!spoken.contains(where: { "[]./,⌫⇥".contains($0) }),
                    "\(chord.display) speaks as “\(spoken)” — add the key to ShortcutKeycapSpeech")
        }
    }
}
