import Foundation
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

/// What a directional transfer acts on — **and, mostly, what it must never act on.**
///
/// `transferItems` is two lines, and it is its own named rule for one reason: the resolver beside it
/// (``DifferenceActionTargets``) falls back to the WHOLE filtered set when a selection resolves to
/// nothing, which is right for a header button and catastrophic for a chord. These tests exist so
/// that "these look the same, unify them" fails instead of shipping.
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

    /// **The property that makes this a separate rule.** A selection whose ids are no longer in the
    /// rows — a rescan mints fresh UUIDs — must yield NOTHING, not the whole list.
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

    /// The rows the chord is handed are the CURRENT ones, so a value that changed under it is the
    /// value it acts on. Written as the two answers over one selection, because that is the whole
    /// difference between resolving at publish time and at fire time.
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

    /// **The chord resolves its rows at fire time, and the parameter that let it not to is gone.**
    ///
    /// A rule extracted for testability is one revert from being unused, and the four tests above
    /// stay green whether or not anything calls `transferItems`. `DifferencesView` is a SwiftUI
    /// `View` with `@State` that nothing can construct, so the wiring is checked at source level,
    /// with the habits that keep such a scan honest: name the file, fail if it cannot be read, and
    /// assert the strings whose presence IS the regression.
    @Test func theChordTakesNoSnapshotOfTheRows() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/DifferencesView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read DifferencesView.swift — every check below would be vacuous")
        try #require(source.count > 5_000, "DifferencesView.swift is implausibly short")

        // The regression, exactly as it shipped: the rows closed over from `body`'s local.
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

