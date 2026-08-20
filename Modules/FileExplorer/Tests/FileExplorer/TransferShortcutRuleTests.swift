import Testing
import Sync
import Design
@testable import FileExplorer

/// ⌘← / ⌘→ / ⇧⌘← / ⇧⌘→ — **the rule that decides when the chord means the differences selection.**
///
/// These were a `.onKeyPress` inside the Table until v4.2, so "does this chord apply?" was answered
/// by where key focus sat. As a menu item there is no focus to ask, and the replacement answer is
/// `lastSelectionSurface` — the arbiter Space already uses to tell a differences selection from a
/// pane one. Every axis below flips the answer; an axis no test can flip is one the view could stop
/// passing correctly without anything failing.
@Suite struct TransferShortcutRuleTests {

    /// The available case, from which each test below removes exactly one thing.
    static func available(selectionCount: Int = 3, surface: SelectionSurface? = .differences,
                          sessionActive: Bool = false, blocked: Bool = false,
                          suspended: Bool = false) -> Bool {
        DifferencesShortcutRules.transferAvailable(
            selectionCount: selectionCount, surface: surface,
            sessionActive: sessionActive, blocked: blocked, suspended: suspended)
    }

    @Test func rowsSelectedInTheTableMakeItAvailable() {
        #expect(Self.available())
    }

    @Test func nothingSelectedWithholdsIt() {
        #expect(!Self.available(selectionCount: 0))
    }

    /// **The gate that replaces focus, and the reason this rule exists at all.** Both panes and the
    /// table can hold a selection at once. With the panes holding it, ⌘→ must not transfer rows the
    /// user stopped meaning — the pane action bar's own Copy is what they want then.
    @Test(arguments: [SelectionSurface.pane, nil])
    func aSelectionBelongingToThePanesWithholdsIt(surface: SelectionSurface?) {
        #expect(!Self.available(surface: surface),
                "the table's chord fired for a selection owned by \(String(describing: surface))")
    }

    /// A review session owns the keyboard while it runs — its card reads plain ⌫ and ↩, one
    /// modifier away from these.
    @Test func aRunningReviewWithholdsIt() {
        #expect(!Self.available(sessionActive: true))
    }

    @Test func aBlockingSyncWithholdsIt() {
        #expect(!Self.available(blocked: true))
    }

    /// The destination picker and the ⌘K palette silence every mirrored chord; a transfer started
    /// underneath one would move the files the pick is asking about.
    @Test func suspensionWithholdsIt() {
        #expect(!Self.available(suspended: true))
    }
}

/// The four chords, and the one place they are written down.
@Suite struct TransferChordTests {

    /// The badge on the header button and the menu item's key equivalent must be one value — the
    /// badge hand-built its string until v4.2 and could disagree with the handler silently.
    @Test(arguments: [(false, false, "⌘←"), (true, false, "⌘→"),
                      (false, true, "⇧⌘←"), (true, true, "⇧⌘→")])
    func eachTransferDisplaysItsChord(spec: (toRight: Bool, isMove: Bool, expected: String)) {
        #expect(AppChord.transfer(toRight: spec.toRight, isMove: spec.isMove).display == spec.expected)
    }

    /// The arrows are function-key code points, so without an explicit glyph the keycap renders an
    /// unprintable box rather than nothing — a defect that looks like a font problem.
    @Test func theArrowsAreDrawableGlyphs() {
        for chord in [AppChord.transfer(toRight: true, isMove: false),
                      AppChord.transfer(toRight: false, isMove: false)] {
            #expect(chord.display.allSatisfy { $0.isASCII || "←→⌘⇧".contains($0) },
                    "\(chord.display) carries an unprintable character")
        }
    }
}
