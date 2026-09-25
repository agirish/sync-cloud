import AppKit
import Design
import SwiftUI
import Testing
@testable import Sync
@testable import FileExplorer

/// **A duplicate copy's row menu: "Open in Edit", then "Compare with keeper".**
///
/// The row itself is the keeper-pick button, so its context menu is the one place on it that adds
/// no gesture — which is why the hand-off to Edit lives there and nowhere else on the row. Four
/// rows matter, and they are the four this suite is built around: a text copy (both items), the
/// text KEEPER (Open in Edit alone — the kept copy is the one you most want to open), a non-text
/// copy (Compare alone), and a non-text keeper (no menu at all, rather than an empty one).
///
/// **The menus are READ, not inferred.** `NSHostingView.menu(for:)` answers a right-click with the
/// real `NSMenu` SwiftUI builds for whatever sits under the event — measured here: a row with
/// `.contextMenu { Button("A") }` answers `["A"]`, a bare row answers nil. So a hosted card can be
/// swept top to bottom and each row's menu read by its item TITLES, in order, which is a stronger
/// claim than any predicate: it fails if the item is gated right and never drawn, drawn in the
/// wrong place, or drawn on a row that should have none.
@MainActor
@Suite struct DuplicateRowMenuTests {

    private static func copy(_ path: String, keeper: Bool = false, isDirectory: Bool = false)
    -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent,
                      isDirectory: isDirectory, size: 10, itemCount: 1, modificationDate: nil,
                      uniqueItemCount: 0, depth: 2, isRecommendedKeeper: keeper)
    }

    /// A two-copy group, keeper first — so the first row a top-to-bottom sweep meets is the keeper's.
    private static func card(_ names: (String, String), isDirectory: Bool = false,
                             onOpenInEditor: ((String) -> Void)? = { _ in },
                             onCompare: @escaping (DuplicateCopy, DuplicateCopy) -> Void = { _, _ in })
    -> (card: DuplicateGroupCard, keeper: DuplicateCopy, other: DuplicateCopy) {
        let keeper = copy("/d/a/\(names.0)", keeper: true, isDirectory: isDirectory)
        let other = copy("/d/b/\(names.1)", isDirectory: isDirectory)
        let group = DuplicateGroup(matchType: .identical, name: names.0, isDirectory: isDirectory,
                                   copies: [keeper, other], reclaimableBytes: 10)
        let card = DuplicateGroupCard(
            group: group, isExpanded: true, providerName: "iCloud", scanRoot: "/d",
            densityMetrics: ListDensity.comfortable.metrics,
            onToggle: {}, onApply: {}, onReveal: {}, onKeepSeparate: {},
            onChooseKeeper: { _ in }, onMerge: {}, onCompareCopies: onCompare,
            onOpenInEditor: onOpenInEditor, headerLayout: .row)
        return (card, keeper, other)
    }

    // MARK: Which rows offer what

    /// **The four rows, by the rules the menu is built from.**
    @Test func openInEditIsOfferedOnEveryTextRowAndCompareOnlyOffTheKeeper() {
        let text = Self.card(("notes.md", "notes.md"))
        #expect(text.card.offersOpenInEditor(text.other), "a text copy does not offer Open in Edit")
        #expect(text.card.offersOpenInEditor(text.keeper),
                "the text keeper does not offer Open in Edit — the copy you keep is the one to open")
        #expect(text.card.offersCompareWithKeeper(text.other))
        #expect(!text.card.offersCompareWithKeeper(text.keeper), "the keeper offers to compare with itself")

        let pdf = Self.card(("report.pdf", "report.pdf"))
        #expect(!pdf.card.offersOpenInEditor(pdf.other), "a PDF copy offers a text editor")
        #expect(!pdf.card.offersOpenInEditor(pdf.keeper), "a PDF keeper offers a text editor")
        #expect(pdf.card.offersCompareWithKeeper(pdf.other))

        // …and whether the row carries a menu at all follows from those two, not a third rule.
        #expect(text.card.hasRowMenu(text.keeper) && text.card.hasRowMenu(text.other))
        #expect(pdf.card.hasRowMenu(pdf.other))
        #expect(!pdf.card.hasRowMenu(pdf.keeper), "a non-text keeper row is given an empty menu")
    }

    /// **Two things that are never "a text file", whatever the name says.** A folder group whose
    /// copies are called `notes.md` is two folders; and a host with no editor (nil hand-off) offers
    /// nothing rather than an item that does nothing.
    @Test func aFolderGroupAndAHostWithNoEditorOfferNoOpenInEdit() {
        let folders = Self.card(("notes.md", "notes.md"), isDirectory: true)
        #expect(!folders.card.offersOpenInEditor(folders.keeper), "a FOLDER named notes.md offers Edit")
        #expect(!folders.card.offersOpenInEditor(folders.other), "a FOLDER named notes.md offers Edit")
        #expect(!folders.card.hasRowMenu(folders.keeper))

        let noEditor = Self.card(("notes.md", "notes.md"), onOpenInEditor: nil)
        #expect(!noEditor.card.offersOpenInEditor(noEditor.keeper),
                "a card with no hand-off still offers Open in Edit — an item that does nothing")
        #expect(!noEditor.card.hasRowMenu(noEditor.keeper))
    }

    /// **The item hands over the copy's PATH, to the card's hand-off** — not the name, not the
    /// keeper's path from a row that is not the keeper. The item's action is this named function;
    /// `theMenuItemIsWiredToTheNamedActionAndTheMenuIsGated` pins that the Button really calls it.
    @Test func theItemHandsTheRowsOwnPathToTheHandOff() {
        final class Box { var paths: [String] = [] }
        let box = Box()
        let text = Self.card(("notes.md", "notes.md"), onOpenInEditor: { box.paths.append($0) })
        text.card.openInEditorAction(for: text.other)()
        text.card.openInEditorAction(for: text.keeper)()
        #expect(box.paths == ["/d/b/notes.md", "/d/a/notes.md"],
                "the hand-off was given \(box.paths)")
    }

    // MARK: What is drawn

    /// **Each row's menu as SwiftUI actually builds it, top to bottom.**
    ///
    /// Text group: the keeper's row answers Open in Edit alone; the other row answers Open in Edit
    /// ABOVE Compare with keeper. PDF group: the keeper's row answers nothing at all, and the other
    /// row answers Compare alone. Both cards are the same shape, so the text card is the positive
    /// control for the PDF keeper — the sweep reaches the keeper's row, and finds a menu there only
    /// when one belongs.
    @Test func eachRowDrawsItsOwnMenuInOrder() {
        // One sweep per card: each is a few hundred hosted right-clicks, and on a loaded machine
        // the main actor they queue on is shared with every other UI suite in the package.
        let textRows = Self.drawnMenuRows(Self.card(("notes.md", "notes.md")).card)
        let pdfRows = Self.drawnMenuRows(Self.card(("report.pdf", "report.pdf")).card)

        let text = textRows.map(\.titles)
        #expect(text == [["Open in Edit"], ["Open in Edit", "Compare with keeper"]],
                "text rows drew \(text)")
        let pdf = pdfRows.map(\.titles)
        #expect(pdf == [["Compare with keeper"]], "PDF rows drew \(pdf)")

        // Where the keeper's row is: the first menu the text sweep met, and the PDF sweep met none
        // there. Read as positions, so a menu that moved rows cannot pass as the right count.
        if let keeperRow = textRows.first?.y, let otherRow = textRows.last?.y,
           let pdfOther = pdfRows.first?.y {
            #expect(keeperRow < otherRow)
            #expect(abs(pdfOther - otherRow) < 8,
                    "the PDF card's only menu is not on its second row (\(pdfOther) vs \(otherRow))")
        } else {
            Issue.record("a sweep found no menu at all: text \(textRows) pdf \(pdfRows)")
        }
    }

    /// **The card's own source, sliced to the parts a render cannot tell apart.**
    ///
    /// The drawn test above sees menus; it cannot see WHICH closure a menu item calls when clicked,
    /// and it cannot see a bare `.contextMenu` that happens to build nothing today. So: the item's
    /// Button is built on the named action, and the row attaches its menu only through `RowMenu`,
    /// gated on `hasRowMenu` — in both of `copyRow`'s branches, and nowhere else in the card.
    @Test func theMenuItemIsWiredToTheNamedActionAndTheMenuIsGated() throws {
        let source = try Self.cardSource()
        let menuStart = try #require(source.range(of: "func rowMenu(_ copy: DuplicateCopy)"),
                                     "rowMenu is gone")
        let menuEnd = try #require(source[menuStart.upperBound...].range(of: "\n    }\n"))
        let menu = String(source[menuStart.upperBound..<menuEnd.lowerBound])
        #expect(menu.contains("Button(action: openInEditorAction(for: copy))"),
                "Open in Edit no longer calls the action the tests exercise")
        #expect(menu.contains("Label(\"Open in Edit\", systemImage: \"square.and.pencil\")"),
                "the item is not named and drawn as the other doors are")
        #expect(source.contains("{ onOpenInEditor?(copy.path) }"), "the action no longer hands over the path")

        let attach = ".modifier(RowMenu(isAttached: hasRowMenu(copy)) { rowMenu(copy) })"
        #expect(source.components(separatedBy: attach).count - 1 == 2,
                "copyRow's two branches no longer both attach the gated menu")
        // The only `.contextMenu` in the file's CODE is RowMenu's own (comments may name it).
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.components(separatedBy: ".contextMenu").count - 1 == 1,
                "a .contextMenu is attached outside RowMenu — an ungated menu is back")
    }

    // MARK: Helpers

    /// Sweeps a right-click down the hosted card's middle and records each run of the same menu,
    /// with the y (from the top) where it began. A nil answer ends a run and is not recorded.
    private static func drawnMenuRows(_ card: DuplicateGroupCard) -> [(y: CGFloat, titles: [String])] {
        let width: CGFloat = 620
        let probe = NSHostingView(rootView: card.frame(width: width))
        let height = max(probe.fittingSize.height, 40)
        let host = NSHostingView(rootView: card.frame(width: width, height: height))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        var rows: [(y: CGFloat, titles: [String])] = []
        var previous: [String]? = nil
        var fromTop: CGFloat = 1
        while fromTop < height {
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: width / 2, y: height - fromTop),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
            let titles = event.flatMap { host.menu(for: $0) }?.items.map(\.title)
            if let titles, titles != previous { rows.append((fromTop, titles)) }
            previous = titles
            fromTop += 2
        }
        return rows
    }

    private static func cardSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FileExplorer (tests)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/FileExplorer/DuplicateGroupCard.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read DuplicateGroupCard.swift — the scan would be vacuous")
        try #require(text.count > 5_000, "DuplicateGroupCard.swift is implausibly short")
        return text
    }
}
