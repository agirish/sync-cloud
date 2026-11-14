import Foundation
import Testing
import Sync
import Design
@testable import FileExplorer

/// ⌘← / ⌘→ / ⇧⌘← / ⇧⌘→: the rule that decides when the chord means the differences selection. As
/// menu items they have no key focus to ask, so `lastSelectionSurface` answers, the arbiter Space
/// already uses to tell a differences selection from a pane one. Every axis below flips the answer;
/// an axis no test can flip is one the view could stop passing correctly with nothing failing.
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

    /// The gate that stands in for focus. Both panes and the table can hold a selection at once;
    /// with the panes holding it, ⌘→ must not transfer rows the user stopped meaning, since the
    /// pane action bar's own Copy is what they want then.
    @Test(arguments: [SelectionSurface.pane, nil])
    func aSelectionBelongingToThePanesWithholdsIt(surface: SelectionSurface?) {
        #expect(!Self.available(surface: surface),
                "the table's chord fired for a selection owned by \(String(describing: surface))")
    }

    /// The other axes, each removed alone.
    enum Withheld: String, CaseIterable {
        case nothingSelected
        /// A review session owns the keyboard while it runs: its card reads plain ⌫ and ↩, one
        /// modifier away from these.
        case aRunningReview
        case aBlockingSync
        /// The destination picker and the ⌘K palette silence every mirrored chord; a transfer
        /// started underneath one would move the files the pick is asking about.
        case suspension
    }

    @Test(arguments: Withheld.allCases)
    func eachOtherAxisWithholdsIt(_ axis: Withheld) {
        let available = switch axis {
        case .nothingSelected: Self.available(selectionCount: 0)
        case .aRunningReview: Self.available(sessionActive: true)
        case .aBlockingSync: Self.available(blocked: true)
        case .suspension: Self.available(suspended: true)
        }
        #expect(!available, "\(axis.rawValue) left the chord available")
    }
}

/// The four chords, and the one place they are written down.
@Suite struct TransferChordTests {

    /// The badge on the header button and the menu item's key equivalent must be one value, or the
    /// badge could silently disagree with the handler.
    @Test(arguments: [(false, false, "⌘←"), (true, false, "⌘→"),
                      (false, true, "⇧⌘←"), (true, true, "⇧⌘→")])
    func eachTransferDisplaysItsChord(spec: (toRight: Bool, isMove: Bool, expected: String)) {
        #expect(AppChord.transfer(toRight: spec.toRight, isMove: spec.isMove).display == spec.expected)
    }

    /// The arrows are function-key code points, so without an explicit glyph the keycap renders an
    /// unprintable box, a defect that looks like a font problem.
    @Test func theArrowsAreDrawableGlyphs() {
        for chord in [AppChord.transfer(toRight: true, isMove: false),
                      AppChord.transfer(toRight: false, isMove: false)] {
            #expect(chord.display.allSatisfy { $0.isASCII || "←→⌘⇧".contains($0) },
                    "\(chord.display) carries an unprintable character")
        }
    }
}

/// What a directional transfer acts on, and mostly what it must never act on. `transferItems` is
/// its own rule because the resolver beside it (``DifferenceActionTargets``) falls back to the
/// whole filtered set when a selection resolves to nothing: right for a header button, catastrophic
/// for a chord. These tests make "these look the same, unify them" fail.
@Suite struct TransferItemsRuleTests {

    static func row(_ path: String, _ action: FileDifference.SyncAction,
                    id: UUID = UUID()) -> FileDifference {
        FileDifference(id: id, relativePath: path, leftItemPath: "/l/" + path,
                       rightItemPath: "/r/" + path, type: .missingOnRight, action: action,
                       description: path)
    }

    @Test func onlySelectedRowsGoingThisWayAreTaken() {
        let a = Self.row("a.txt", .copyToRight)
        let b = Self.row("b.txt", .copyToLeft)
        let c = Self.row("c.txt", .copyToRight)
        let items = DifferencesShortcutRules.transferItems(
            rows: [a, b, c], selection: [a.id, b.id], direction: .copyToRight)
        #expect(items.map(\.relativePath) == ["a.txt"],
                "took \(items.map(\.relativePath)) — the other direction or an unselected row came along")
    }

    /// The property that makes this a separate rule: a selection whose ids are no longer in the
    /// rows (a rescan mints fresh UUIDs) must yield nothing, not the whole list.
    @Test func aSelectionThatMatchesNoRowTakesNothingAtAll() {
        let rows = [Self.row("a.txt", .copyToRight), Self.row("b.txt", .copyToRight)]
        let items = DifferencesShortcutRules.transferItems(
            rows: rows, selection: [UUID(), UUID()], direction: .copyToRight)
        #expect(items.isEmpty, """
                a stale selection resolved to \(items.count) row(s). \
                `DifferenceActionTargets` falls back to the whole filtered set here, on purpose, and \
                a chord that did the same would transfer every differing file with nothing on screen \
                having said so.
                """)
    }

    @Test func anEmptySelectionTakesNothing() {
        let rows = [Self.row("a.txt", .copyToRight)]
        #expect(DifferencesShortcutRules.transferItems(rows: rows, selection: [],
                                                        direction: .copyToRight).isEmpty)
    }

    /// The rows the chord is handed are the current ones, so a value that changed under it is the
    /// value it acts on. Two answers over one selection: the difference between resolving at
    /// publish time and at fire time.
    @Test func theRowsHandedInAreTheOnesActedOn() {
        let id = UUID()
        let asPublished = [Self.row("a.txt", .copyToRight, id: id)]
        // The same row after a bulk sync sent it the other way.
        let asItIsNow = [Self.row("a.txt", .copyToLeft, id: id)]

        #expect(DifferencesShortcutRules.transferItems(rows: asPublished, selection: [id],
                                                        direction: .copyToRight).count == 1)
        #expect(DifferencesShortcutRules.transferItems(rows: asItIsNow, selection: [id],
                                                        direction: .copyToRight).isEmpty,
                "the row now copies the other way, so ⌘→ must find nothing to do with it")
    }

    /// The chord resolves its rows at fire time, through `transferItems`; the tests above stay
    /// green whether or not anything calls it. `DifferencesView` is a `View` with `@State` that
    /// nothing can construct, so the wiring is checked at source level: name the file, fail if it
    /// can't be read, and assert the strings whose presence is the regression.
    @Test func theChordTakesNoSnapshotOfTheRows() throws {
        let source = try SourceText.fileExplorer("DifferencesView.swift", atLeast: 5_000)

        // The rows must not be closed over from `body`'s local: a focused value isn't re-armed
        // while a menu is open.
        #expect(!source.contains("keyboardCopy(direction: direction, isMove: isMove, in: sorted)"),
                "the transfer chord closes over `sorted` again — a focused value is not re-armed while a menu is open")
        #expect(!source.contains("in sorted: [FileDifference]"),
                "`keyboardCopy` takes the rows as a parameter again, which is the only way to capture them")
        // …and the shape that replaced it.
        #expect(source.contains("keyboardCopy(direction: direction, isMove: isMove)"),
                "the transfer chord no longer calls `keyboardCopy` — this scan is measuring nothing")
        #expect(source.contains("DifferencesShortcutRules.transferItems(rows: displayRows.sorted,"),
                "`keyboardCopy` resolves its own rows again instead of asking the rule, or reads them from somewhere other than the visible set")
    }
}
