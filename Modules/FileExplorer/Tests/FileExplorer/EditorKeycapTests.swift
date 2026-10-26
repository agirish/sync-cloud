import AppKit
import Design
import SwiftUI
import Testing
@testable import FileExplorer

/// **Edit's controls with a key show it while ⌥ is held** (TE194) — the format bar, Source /
/// Preview / Split, "Line 48, Col 12", the PDF's page arrows, page number, zoom steps, find arrows
/// and Close Find, the empty page's two buttons and Cancel under Compare…. Help and the shortcuts
/// window said every control with a shortcut wears one; these did not.
///
/// Two things are checked: that the keys do not run into each other where the buttons sit close —
/// measured, each key against the distance to its neighbour's centre — and that each control is
/// wired, read off the code, because an offscreen host has no ⌥ to hold.
@MainActor
@Suite struct EditorKeycapTests {

    /// A key's laid-out width.
    static func width(_ symbol: String, compact: Bool = true) -> CGFloat {
        NSHostingView(rootView: ShortcutKeycap(symbol, compact: compact)).fittingSize.width
    }

    /// Two keys centred on neighbours `pitch` apart clear each other when their half-widths, and
    /// ``breathing`` between them, still fit — keys that touch read as one, with their shadows.
    static func clear(_ a: String, _ b: String, pitch: CGFloat) -> Bool {
        (width(a) + width(b)) / 2 + breathing <= pitch
    }
    static let breathing: CGFloat = 2

    // MARK: Room

    /// **B, I and S sit 27pt apart, and a full key is wider than that**: "⇧⌘X" ran over "⌘I". So
    /// the bar wears the compact key, and every pair of neighbours with a chord clears.
    @Test func theFormatBarsKeysClearEachOther() throws {
        let pitch = EditorFormatBar.box(at: 1) + EditorFormatBar.buttonGap
        let marks = [MarkupVerb.bold, .italic, .strikethrough].compactMap(EditorFormatBar.keycap)
        try #require(marks.count == 3, "B, I and S lost a chord: \(marks)")
        for (a, b) in zip(marks, marks.dropFirst()) {
            #expect(Self.clear(a, b, pitch: pitch),
                    "\(a) (\(Self.width(a))pt) and \(b) (\(Self.width(b))pt) meet \(pitch)pt apart")
        }
        // The control: the full keys did meet, which is why the bar does not wear them.
        #expect((Self.width("⌘I", compact: false) + Self.width("⇧⌘X", compact: false)) / 2 > pitch,
                "full keys fit the bar after all — the compact one is no longer needed")
    }

    /// Source, Preview and Split without their words: three 25pt segments 3pt apart.
    @Test func theModeCapsulesKeysClearEachOther() {
        let pitch = CapsuleGlyph.box(at: 1) + 2 * EditorModeBar.glyphSegmentPadding + EditorModeBar.segmentGap
        let keys = EditorMode.allCases.map(\.chord.display)
        for (a, b) in zip(keys, keys.dropFirst()) {
            #expect(Self.clear(a, b, pitch: pitch), "\(a) and \(b) meet \(pitch)pt apart")
        }
    }

    /// The PDF's capsule: ‹ beside the page number's field, and each step 20pt square with 2pt
    /// between — across, and standing upright, where a key's height is what must clear.
    @Test func thePDFCapsulesKeysClearEachOther() {
        let step = EditorPDFCapsule.stepSize, gap = EditorPDFCapsule.pieceGap
        let field = EditorPDFCapsule.fieldWidth(pageCount: 9)
        // ‹ to the field's centre: half a step, the gap, the field group's 2pt inset, half the field.
        let toField = step / 2 + gap + 2 + field / 2
        #expect(Self.clear(EditorPDFCapsule.pageStepKeycap(forward: false), AppChord.goToLine.display, pitch: toField))
        // The field's key sits on the field alone, never wider than the capsule is across it.
        #expect(Self.width(AppChord.goToLine.display) <= field + 2 * 2, "⌃⌘L is wider than the field it sits on")
        // Upright, steps stack: a key is shorter than a step and its gap.
        let tall = NSHostingView(rootView: ShortcutKeycap(EditorPDFCapsule.zoomStepKeycap(in: true), compact: true))
            .fittingSize.height
        #expect(tall <= step + gap, "an upright capsule's keys overlap: \(tall)pt keys on \(step + gap)pt steps")
        // Across, − and + are on either side of the zoom label, and ‹ and › of the field — never next
        // to each other; each key is about its step's width.
        for key in [EditorPDFCapsule.zoomStepKeycap(in: true), EditorPDFCapsule.zoomStepKeycap(in: false),
                    EditorPDFCapsule.pageStepKeycap(forward: true)] {
            #expect(Self.width(key) <= step + gap, "\(key) is wider than its step")
        }
    }

    /// The find card's arrows sit 22pt apart, and Close Find 6pt after them.
    @Test func theFindCardsKeysClearEachOther() {
        let step = EditorPDFCapsule.stepSize
        #expect(Self.clear(AppChord.findPrevious.display, AppChord.findNext.display,
                           pitch: step + EditorPDFFindBar.stepGap),
                "⇧⌘G (\(Self.width(AppChord.findPrevious.display))pt) and ⌘G (\(Self.width(AppChord.findNext.display))pt) meet")
        #expect(Self.clear(AppChord.findNext.display, "esc",
                           pitch: step / 2 + EditorPDFFindBar.cardGap + EditorPDFFindBar.closeSize / 2))
    }

    // MARK: Which keys, and when

    /// The bar's keys are the verbs' chords, and show only with the caret in the text: elsewhere ⌘I
    /// is the Info inspector. Nothing held, nothing asked — no window here has a caret either.
    @Test func theFormatBarShowsItsKeysOnlyWithTheCaretInTheText() {
        #expect(EditorFormatBar.keycap(.bold) == "⌘B")
        #expect(EditorFormatBar.keycap(.italic) == "⌘I")
        #expect(EditorFormatBar.keycap(.heading(1)) == nil, "a heading has no key to show")
        #expect(!EditorFormatBar.caretIsInText(revealing: false))
        #expect(!EditorFormatBar.caretIsInText(revealing: true), "no caret in a test host's key window")
    }

    /// Every control the row named wears its key, above any `.disabled`, so a greyed one shows
    /// none (`shortcutKeycap`'s ordering rule). Mutation: drop any one modifier and its line fails.
    @Test func eachControlWearsItsKey() throws {
        func squashed(_ file: String) throws -> String {
            EditorAcrossPolishTests.squashed(try EditorAcrossPolishTests.source(file))
        }
        let wiring: [(file: String, code: String)] = [
            ("EditorFormatBar.swift", ".shortcutKeycap(Self.keycap(verb), compact: true, shown: Self.caretIsInText(revealing: isRevealing)) .disabled(!offered)"),
            ("EditorMode.swift", ".shortcutKeycap(candidate.chord.display, compact: true)"),
            ("EditorStatusLine.swift", ".shortcutKeycap(AppChord.goToLine.display, compact: true, shown: caretIsCurrent)"),
            ("EditorPDFCapsule.swift", ".shortcutKeycap(Self.pageStepKeycap(forward: forward), compact: true, shown: state.hasFocus) .disabled(!state.canTurnPage(forward: forward))"),
            ("EditorPDFCapsule.swift", ".shortcutKeycap(Self.zoomStepKeycap(in: zoomingIn), compact: true, shown: state.hasFocus) .disabled(!state.canZoom(in: zoomingIn))"),
            ("EditorPDFCapsule.swift", ".focused($pageFieldFocused) .shortcutKeycap(AppChord.goToLine.display, compact: true)"),
            ("EditorPDFFindBar.swift", ".shortcutKeycap(forward ? AppChord.findNext.display : AppChord.findPrevious.display, compact: true) .disabled(find.matches.isEmpty)"),
            ("EditorPDFFindBar.swift", ".shortcutKeycap(\"esc\", compact: true) .accessibilityLabel(\"Close Find\")"),
            ("EditorRecentFilesPage.swift", ".accentedProminent() .shortcutKeycap(AppChord.newTextFile.display)"),
            ("EditorRecentFilesPage.swift", ".buttonWordsTint(accent) .shortcutKeycap(AppChord.editorTextFiles.display)"),
            ("EditorWorkspaceView.swift", ".buttonWordsTint(accent) .shortcutKeycap(AppChord.editorTextFiles.display)"),
            ("EditorDivergenceDiffOverlay.swift", "Button(\"Cancel\") { onAnswer(.cancel) } .buttonStyle(.bordered) .shortcutKeycap(\"esc\")"),
        ]
        for (file, code) in wiring {
            #expect(try squashed(file).contains(code), "\(file) no longer wears “\(code)”")
        }
        #expect(EditorPDFCapsule.pageStepKeycap(forward: true) == "⌥→")
        #expect(EditorPDFCapsule.zoomStepKeycap(in: false) == AppChord.textSmaller.display)
    }
}
