import AppKit
import Foundation
import Testing
import Sync
import SwiftUI
@testable import FileExplorer

/// The To File cards redesign (mockup v6): every card says what moves where, File All's sheet lists
/// only Matched cards and files what is left ticked, and each file row's menu does what it says.
@Suite struct FilingRouteTextTests {
    static let docs = "/Users/a/Documents"
    static let todo = "/Users/a/Documents/TODO"

    private func statement(_ rel: String, to dest: String, account root: String, newSegments: [String] = [],
                           confidence: FilingConfidence = .high, proposed: String? = nil) -> FilingSuggestion {
        let acct = FilingAccount(root: root, ending: "5652", institution: "american express", archived: false, kind: .statement)
        return FilingSuggestion(filePath: Self.todo + "/" + rel, fileName: (rel as NSString).lastPathComponent, size: 1,
                                modificationDate: nil,
                                candidates: [FilingDestination(path: dest, confidence: confidence, reasons: ["r"],
                                                               newSegments: newSegments, fromContent: true,
                                                               proposedName: proposed, account: acct)],
                                providerRoot: Self.docs)
    }

    /// "From" is relative to the scanned folder, "Moves to" to the tree, both in full; the account
    /// and its year are bold, and a year made inside an account it has is a quiet note.
    @Test func fromAndMovesToAreWrittenOutInFull() {
        let account = Self.docs + "/Finance/US/Credit Accounts/American Express/Credit 44928"
        let s = statement("Finance/American Express/Credit 5652/2026/01. Jan 2026.pdf", to: account + "/2026",
                          account: account, newSegments: ["2026"])
        let lines = FilingRouteText.lines(members: [s], destination: s.best, scannedRoot: Self.todo)
        #expect(lines.map(\.label) == ["From", "Moves to"])
        #expect(lines[0].path.text == "TODO › Finance › American Express › Credit 5652 › 2026")
        #expect(lines[1].path.text == "Documents › Finance › US › Credit Accounts › American Express › Credit 44928 › 2026")
        #expect(lines[1].path.crumbs.filter(\.bold).map(\.name) == ["Credit 44928", "2026"])
        #expect(lines[1].path.note == "new 2026 folder", "a year inside an existing account is quiet")
        #expect(lines[1].path.crumbs.allSatisfy { $0.tag == nil })
    }

    /// A new account gets the accent tag on the account, and nothing shouts about its year.
    @Test func aNewAccountIsTaggedOnTheAccount() {
        let account = Self.docs + "/Finance/Chase/Checking 0896"
        let s = statement("Chase/a.pdf", to: account + "/2026", account: account,
                          newSegments: ["Checking 0896", "2026"], confidence: .medium)
        let path = FilingRouteText.movesTo(s.best!, providerRoot: Self.docs)
        #expect(path.crumbs.compactMap(\.tag) == ["new account"])
        #expect(path.crumbs.first { $0.tag != nil }?.name == "Checking 0896")
        #expect(path.note == nil)
        #expect(FilingRouteText.offersCreateAs(s.best!), "Create as is offered for the account it invents")
        let year = statement("x.pdf", to: Self.docs + "/Card/2026", account: Self.docs + "/Card", newSegments: ["2026"])
        #expect(!FilingRouteText.offersCreateAs(year.best!), "never for a year")
    }

    /// A home it isn't sure of reads "Best guess"; files from different folders give the folder they
    /// share, and each row then names its own.
    @Test func bestGuessAndSeveralFolders() {
        let low = FilingSuggestion(filePath: Self.todo + "/SON.pdf", fileName: "SON.pdf", size: 1, modificationDate: nil,
                                   candidates: [FilingDestination(path: Self.docs + "/Finance/US/Social Security/2026",
                                                                  confidence: .low, reasons: ["r"], newSegments: [])],
                                   providerRoot: Self.docs)
        let lowLines = FilingRouteText.lines(members: [low], destination: low.best, scannedRoot: Self.todo)
        #expect(lowLines.map(\.label) == ["From", "Best guess"])
        #expect(lowLines[0].path.text == "TODO")

        let account = Self.docs + "/IRA 9312"
        let a = statement("Schwab/2025/a.pdf", to: account, account: account)
        let b = statement("Schwab/2026/b.pdf", to: account, account: account)
        let from = FilingRouteText.from([a, b], scannedRoot: Self.todo)
        #expect(from.text == "TODO › Schwab" && from.note == "several folders")
        #expect(FilingRouteText.rowFrom(a, members: [a, b]) == "2025")
        #expect(FilingRouteText.rowFrom(a, members: [a]) == nil)
    }

    @Test func aCloudRootIsNamedForItsCloud() {
        #expect(FilingRouteText.rootLabel("/Users/a/Library/Mobile Documents/com~apple~CloudDocs") == "iCloud")
        #expect(FilingRouteText.rootLabel("/Users/a/Library/CloudStorage/GoogleDrive-a@b.com") == "Google Drive")
        #expect(FilingRouteText.rootLabel(Self.docs) == "Documents")
    }

    /// The group card's title and "why" line, as the mockup words them.
    @Test func theGroupCardSaysWhoHowManyAndWhy() {
        let account = Self.docs + "/Credit 44928"
        let items = FilingCardGrouping.items([statement("01. Jan 2026.pdf", to: account, account: account),
                                              statement("10. Oct 2026.pdf", to: account, account: account)])
        guard case .group(let g) = items.first else { Issue.record("expected a group"); return }
        #expect(FilingGroupText.title(g) == "American Express ••5652 · 2 statements")
        #expect(FilingGroupText.why(g) == "Jan and Oct 2026 · account number on page 1 of both")
    }

    /// Trash takes only copies proven byte for byte; one matched by its text alone stays, and the
    /// card says to compare it.
    @Test func trashTakesOnlyProvenCopies() {
        let account = Self.docs + "/Credit 44928"
        let proven = statement("01. Jan 2026.pdf", to: account, account: account).alreadyFiled(at: ["Credit 44928"], proven: true)
        let lookalike = statement("02. Feb 2026.pdf", to: account, account: account).alreadyFiled(at: ["Credit 44928"], proven: false)
        let items = FilingCardGrouping.items([statement("03. Mar 2026.pdf", to: account, account: account), proven, lookalike])
        guard case .group(let g) = items.first else { Issue.record("expected a group"); return }
        #expect(FilingGroupText.removable(g).map(\.fileName) == ["01. Jan 2026.pdf"])
        #expect(FilingGroupText.leftBehind(g).hasSuffix("One matches by its text only, not as the same file, so compare before removing it."))
        #expect(FilingFileText.landing(lookalike)?.text == "looks already filed")
        #expect(FilingFileText.landing(proven)?.text == "already filed")
        let onlyLookalike = FilingCardGrouping.items([statement("03. Mar 2026.pdf", to: account, account: account), lookalike])
        guard case .group(let h) = onlyLookalike.first else { Issue.record("expected a group"); return }
        #expect(FilingGroupText.removable(h).isEmpty, "nothing to offer the Trash")
    }

    /// Claude's group has no account to name, so its reason titles it and the "why" says whose
    /// suggestion it is, not that a page number backs it.
    @Test func claudesGroupIsTitledByItsReason() {
        let home = Self.docs + "/Home/Utilities/AT&T/2026"
        func bill(_ name: String) -> FilingSuggestion {
            FilingSuggestion(filePath: Self.todo + "/AT&T/" + name, fileName: name, size: 1, modificationDate: nil,
                             candidates: [FilingDestination(path: home, confidence: .medium, reasons: ["AT&T bill"],
                                                            newSegments: ["2026"], fromAI: true)],
                             providerRoot: Self.docs)
        }
        let items = FilingCardGrouping.items([bill("04. Apr 2026.pdf"), bill("05. May 2026.pdf"), bill("06. Jun 2026.pdf")])
        guard items.count == 1, case .group(let g) = items[0] else { Issue.record("expected one group: \(items.map(\.id))"); return }
        #expect(g.account == nil)
        #expect(FilingGroupText.title(g) == "AT&T bill · 3 files")
        #expect(FilingGroupText.bank(g) == "AT&T bill")
        #expect(FilingGroupText.why(g) == "Apr–Jun 2026 · Claude suggested this folder for all 3 · check before filing")
    }

    /// Each row says what page 1 is and the name it takes, and only what To File read.
    @Test func aRowSaysWhatPageOneIsAndTheNameItTakes() {
        #expect(FilingFileText.pageLine(DocumentFacts(page: "Statement Period\nClosing Date 01/29/2026\nAccount Ending 6-44928"))
                == "Statement · Jan 29, 2026")
        #expect(FilingFileText.pageLine(DocumentFacts(page: "Immunization Record\nName")) == "Page 1 begins “Immunization Record”")
        let account = Self.docs + "/Credit 44928"
        let renamed = statement("01. Jan 2026.pdf", to: account, account: account, proposed: "2026-01-29.pdf")
        #expect(FilingFileText.landing(renamed)?.text == "2026-01-29.pdf")
        #expect(FilingFileText.landing(statement("a.pdf", to: account, account: account))?.text == "a.pdf",
                "a file keeping its name says so by restating it")
        #expect(FilingFileText.landing(renamed.alreadyFiled(at: ["x"]))?.moves == false)
        let low = FilingSuggestion(filePath: "/x/y.pdf", fileName: "y.pdf", size: 1, modificationDate: nil,
                                   candidates: [FilingDestination(path: "/x/z", confidence: .low, reasons: [], newSegments: [])])
        #expect(FilingFileText.landing(low) == nil, "a Needs your pick row ends at the file")
    }
}

@Suite struct FilingBatchPlanTests {
    static let docs = "/D"

    private func statement(_ name: String, account: String, ending: String = "9312",
                           confidence: FilingConfidence = .high) -> FilingSuggestion {
        let acct = FilingAccount(root: account, ending: ending, institution: "charles schwab", archived: false, kind: .statement)
        return FilingSuggestion(filePath: "/D/TODO/" + name, fileName: name, size: 1, modificationDate: nil,
                                candidates: [FilingDestination(path: account, confidence: confidence, reasons: ["r"], newSegments: [],
                                                               fromContent: true, account: acct)],
                                providerRoot: Self.docs)
    }

    private func byName(_ name: String, to folder: String) -> FilingSuggestion {
        FilingSuggestion(filePath: "/D/TODO/" + name, fileName: name, size: 1, modificationDate: nil,
                         candidates: [FilingDestination(path: folder, confidence: .high, reasons: ["r"], newSegments: [])],
                         providerRoot: Self.docs)
    }

    /// The sheet lists every Matched card that has something to move, and nothing else: a Check
    /// first card handed in, and a group whose files are all filed already, stay out.
    @Test func theSheetListsMatchedCardsOnly() {
        let ira = [statement("01.pdf", account: "/D/IRA 9312"), statement("02.pdf", account: "/D/IRA 9312")]
        let filed = [statement("a.pdf", account: "/D/Roth 5442", ending: "5442").alreadyFiled(at: ["Roth 5442"]),
                     statement("b.pdf", account: "/D/Roth 5442", ending: "5442").alreadyFiled(at: ["Roth 5442"])]
        let medium = statement("m.pdf", account: "/D/New 0896", ending: "0896", confidence: .medium)
        let items = FilingCardGrouping.items(ira + filed + [byName("Receipt.pdf", to: "/D/Receipts"), medium])
        let lines = FilingBatchPlan.lines(items, scannedRoot: "/D/TODO")
        #expect(lines.map(\.title) == ["Charles Schwab", "Receipt.pdf"])
        #expect(lines.map(\.count) == [2, 1])
        #expect(lines[0].ending == "9312" && lines[0].source == nil)
        #expect(lines[1].source == "by its name", "a name-placed file is marked so")
        #expect(FilingBatchPlan.title(lines) == "File 3 files into 2 folders?")
        #expect(FilingBatchPlan.title(Array(lines.prefix(1))) == "File 2 statements into 1 account?")
    }

    /// Unticked cards stay as cards: the button counts and files the rest, and the footer says what
    /// stays.
    @Test func untickingLeavesACardBehind() {
        let items = FilingCardGrouping.items([statement("01.pdf", account: "/D/IRA 9312"), statement("02.pdf", account: "/D/IRA 9312"),
                                              statement("c.pdf", account: "/D/Card 5652", ending: "5652"),
                                              statement("d.pdf", account: "/D/Card 5652", ending: "5652")])
        let lines = FilingBatchPlan.lines(items, scannedRoot: "/D/TODO")
        let off: Set<String> = [lines[1].id]
        #expect(FilingBatchPlan.fileCount(lines, unticked: off) == 2)
        #expect(FilingBatchPlan.ticked(lines, unticked: off).map(\.id) == [lines[0].id])
        #expect(FilingBatchPlan.footer(lines, unticked: off) == "Unticked: Charles Schwab ••5652 (2) stays as its card.")
        #expect(FilingBatchPlan.footer(lines, unticked: []) == nil)
        #expect(FilingBatchPlan.title(lines, unticked: off) == "File 2 statements into 1 account?")
        #expect(FilingBatchPlan.fileCount(lines, unticked: Set(lines.map(\.id))) == 0)
    }
}

@MainActor
@Suite struct FilingFileActionTests {
    private let s = FilingSuggestion(filePath: "/D/TODO/01. Jan 2026.pdf", fileName: "01. Jan 2026.pdf", size: 1, modificationDate: nil,
                                     candidates: [FilingDestination(path: "/D/Credit 44928/2026", confidence: .high, reasons: ["r"],
                                                                    newSegments: [], proposedName: "2026-01-29.pdf")])

    /// The menu's items in order, Pull Out only in a group's rows, Copy Destination Path only with a
    /// destination; the selected row answers Finder's Space, ⌘Y and ⌥⌘C, and leaves the menu
    /// bar's chords alone.
    @Test func theMenuOffersWhatTheDesignLists() {
        #expect(FilingFileAction.sections(inGroup: true, hasDestination: true).flatMap { $0 }.map(\.title) ==
                ["Quick Look", "Open", "Reveal in Finder", "Open Folder", "Open Destination Folder", "Copy Path",
                 "Copy Destination Path", "Pull Out of This Card", "Choose a Folder for This File…", "Set Aside",
                 "Move to Trash"])
        #expect(!FilingFileAction.sections(inGroup: false, hasDestination: false).joined().contains(.openDestinationFolder))
        #expect(!FilingFileAction.sections(inGroup: false, hasDestination: true).joined().contains(.pullOut))
        #expect(!FilingFileAction.sections(inGroup: false, hasDestination: false).joined().contains(.copyDestinationPath))
        #expect(FilingFileAction.forKey(.space, modifiers: []) == .quickLook)
        #expect(FilingFileAction.forKey("y", modifiers: .command) == .quickLook)
        #expect(FilingFileAction.forKey("c", modifiers: [.command, .option]) == .copyPath)
        #expect(FilingFileAction.forKey("o", modifiers: .command) == nil, "⌘O is the menu bar's Open in Edit")
        #expect(FilingFileAction.forKey("r", modifiers: .command) == nil, "⌘R is the menu bar's Rescan")
        #expect(FilingFileAction.forKey(.delete, modifiers: .command) == nil, "⌘⌫ is the menu bar's Move Selection to Trash")
        #expect(FilingFileAction.forKey("c", modifiers: .command) == nil, "⌘C alone is the window's Copy")
        #expect(FilingFileAction.forKey(.delete, modifiers: []) == nil, "a bare ⌫ trashes nothing")
    }

    /// Each action reaches its own handler with this file, and the two copies put the right path on
    /// the pasteboard.
    @Test func eachActionDoesWhatItSays() {
        var calls: [String] = []
        let board = NSPasteboard(name: NSPasteboard.Name("FilingFileActionTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let other = FilingSuggestion(filePath: "/D/TODO/10. Oct 2026.pdf", fileName: "10. Oct 2026.pdf", size: 1,
                                     modificationDate: nil, candidates: [])
        let runner = FilingFileActionRunner(
            quickLook: { urls, url in calls.append("ql \(urls.map(\.lastPathComponent)) \(url.lastPathComponent)") },
            open: { calls.append("open \($0.lastPathComponent)") },
            reveal: { calls.append("reveal \($0.lastPathComponent)") },
            pasteboard: board,
            pullOut: { calls.append("pull \($0.fileName)") },
            chooseFolder: { calls.append("choose \($0.fileName)") },
            setAside: { calls.append("aside \($0.fileName)") },
            trash: { calls.append("trash \($0.fileName)") })
        for action in FilingFileAction.allCases where action != .copyPath && action != .copyDestinationPath {
            runner.perform(action, on: s, members: [s, other])
        }
        #expect(calls == ["ql [\"01. Jan 2026.pdf\", \"10. Oct 2026.pdf\"] 01. Jan 2026.pdf",
                          "open 01. Jan 2026.pdf", "reveal 01. Jan 2026.pdf", "open TODO", "open 2026", "pull 01. Jan 2026.pdf",
                          "choose 01. Jan 2026.pdf", "aside 01. Jan 2026.pdf", "trash 01. Jan 2026.pdf"],
                "Quick Look gets the card's files to step through, starting at this one; Open Folder opens where it is, Open Destination Folder where it goes")
        runner.perform(.copyPath, on: s, members: [s])
        #expect(board.string(forType: .string) == "/D/TODO/01. Jan 2026.pdf")
        runner.perform(.copyDestinationPath, on: s, members: [s])
        #expect(board.string(forType: .string) == "/D/Credit 44928/2026/2026-01-29.pdf", "where it lands, under its new name")
    }
}

@MainActor
@Suite struct FilingScopeLineTests {
    @Test func theReadoutSaysWhereTheFilesCameFrom() {
        #expect(LensWorkspaceView.filingScopeLine(folder: "/D/TODO", readSubfolders: true, files: 257)
                == "From TODO and its subfolders · 257 files")
        #expect(LensWorkspaceView.filingScopeLine(folder: "/D/TODO", readSubfolders: false, files: 1) == "From TODO · 1 file")
    }
}

/// What the first adversarial review of the cards found, pinned.
@Suite struct FilingCardsReviewOneTests {
    private func statement(_ name: String, account root: String, ending: String = "9312", archived: Bool = false,
                           to dest: String? = nil, newSegments: [String] = [], proposed: String? = nil) -> FilingSuggestion {
        let acct = FilingAccount(root: root, ending: ending, institution: "charles schwab", archived: archived, kind: .statement)
        return FilingSuggestion(filePath: "/D/TODO/" + name, fileName: name, size: 1, modificationDate: nil,
                                candidates: [FilingDestination(path: dest ?? root, confidence: .high, reasons: ["r"],
                                                               newSegments: newSegments, fromContent: true,
                                                               proposedName: proposed, account: acct)],
                                providerRoot: "/D")
    }

    /// The sheet says what a batch makes, copies and where it files: new folders, copies into
    /// other accounts, and the archive.
    @Test func theSheetSaysWhatItMakesCopiesAndWhere() {
        let archived = statement("a.pdf", account: "/D/Archive/IRA 9312", archived: true)
        let roth = FilingCopy(path: "/D/Roth IRA 5442/2026", proposedName: nil,
                              account: FilingAccount(root: "/D/Roth IRA 5442", ending: "5442", institution: "charles schwab",
                                                     archived: false, kind: .statement))
        let year = statement("b.pdf", account: "/D/Card 5652", ending: "5652", to: "/D/Card 5652/2026", newSegments: ["2026"])
        let lines = FilingBatchPlan.lines([.single(archived), .single(year)], scannedRoot: "/D/TODO",
                                          copies: { $0.fileName == "b.pdf" ? [roth] : [] })
        #expect(lines[0].extras == ["into the archive"])
        #expect(lines[1].extras == ["also copies into Roth IRA 5442"])
        #expect(lines[1].to.note == "new 2026 folder", "the new year folder reaches the sheet's line")
    }

    /// A name typed into "Create as" is the folder the sheet shows and files into.
    @Test func theSheetShowsATypedFolderName() {
        let s = FilingSuggestion(filePath: "/D/TODO/r.pdf", fileName: "r.pdf", size: 1, modificationDate: nil,
                                 candidates: [FilingDestination(path: "/D/Receipts/Hardware", confidence: .high, reasons: ["r"],
                                                                newSegments: ["Hardware"])], providerRoot: "/D")
        let typed = s.best!.renamingNewFolder(to: "Tools")
        let lines = FilingBatchPlan.lines([.single(s)], scannedRoot: "/D/TODO", destinations: [s.id: typed])
        #expect(lines.first?.to.text.hasSuffix("Tools") == true)
    }

    /// A folded group still says its files take new names.
    @Test func aFoldedGroupSaysItRenames() {
        let a = statement("01.pdf", account: "/D/IRA 9312", proposed: "IRA_01.pdf")
        let b = statement("02.pdf", account: "/D/IRA 9312", proposed: "02.pdf")
        guard case .group(let g) = FilingCardGrouping.items([a, b]).first else { Issue.record("expected a group"); return }
        #expect(FilingGroupText.renaming(g) == "1 of 2 take new names, like IRA_01.pdf")
        let keep = [statement("01.pdf", account: "/D/IRA 9312"), statement("02.pdf", account: "/D/IRA 9312")]
        guard case .group(let k) = FilingCardGrouping.items(keep).first else { Issue.record("expected a group"); return }
        #expect(FilingGroupText.renaming(k) == nil)
    }

    /// The page-1 view says "(marked)" only when it marked something, and marks whole numbers only.
    @Test func thePageViewMarksOnlyWhatItFinds() {
        let s = statement("01.pdf", account: "/D/IRA 9312")
        #expect(FilingPageRender.matchedLine(s, facts: nil, marked: false) == "account ••9312")
        #expect(FilingPageRender.matchedLine(s, facts: nil, marked: true) == "account ••9312 (marked)")
        #expect(FilingPageRender.wholeRange(of: "9312", in: "Ref 193120 · Account ending 9312")
                == NSRange(location: 28, length: 4), "never the 9312 inside 193120")
        #expect(FilingPageRender.wholeRange(of: "9312", in: "Ref 193120") == nil)
    }

    /// VoiceOver hears which path is which.
    @Test func eachRouteLineIsSpokenWithItsLabel() {
        let line = FilingRouteLine(label: "Moves to", path: FilingRoutePath(crumbs: [.init(name: "Documents"), .init(name: "2026")]))
        #expect(FilingRouteGrid.spoken(line) == "Moves to: Documents, 2026")
    }

    @MainActor @Test func theReadoutSaysHowManyASearchLeft() {
        #expect(LensWorkspaceView.filingScopeLine(folder: "/D/TODO", readSubfolders: false, files: 3, of: 257)
                == "From TODO · 3 of 257 files")
        #expect(LensWorkspaceView.filingScopeLine(folder: "/D/TODO", readSubfolders: false, files: 4, of: 4) == "From TODO · 4 files")
    }
}

/// The v8 action line (decision OR): Quick Look and Trash only for one file, the guess as a button.
@Suite struct FilingCardsV8Tests {
    private let s = FilingSuggestion(filePath: "/D/TODO/a.pdf", fileName: "a.pdf", size: 1, modificationDate: nil,
                                     candidates: [FilingDestination(path: "/D/Finance/US/Social Security/2026", confidence: .low,
                                                                    reasons: ["r"], newSegments: [])], providerRoot: "/D")

    /// With no file to act on (a group, nothing selected) there is no Quick Look and no Trash, only
    /// the folders; with one, the line's ⋯ holds the file's own actions, and Trash only when folded.
    @Test func quickLookAndTrashAreForOneFile() {
        #expect(FilingCardFileActions.menuActions(target: nil, folded: false).isEmpty,
                "no file selected: ⋯ is grayed out, Open Folder is on the line")
        #expect(FilingCardFileActions.menuActions(target: nil, folded: true) == [.openFolder])
        let shown = FilingCardFileActions.menuActions(target: s, folded: false)
        #expect(!shown.contains(.quickLook) && !shown.contains(.trash), "on the line itself, not in ⋯")
        let folded = FilingCardFileActions.menuActions(target: s, folded: true)
        #expect(folded.first == .quickLook && folded.last == .trash)
    }

    /// The guess's button names where it files, shorter on the narrowest line; a weak guess's why
    /// never says "Matched".
    @Test func theGuessIsAButtonAndAGuess() {
        #expect(FilingRouteText.guessButton(s.best!, providerRoot: "/D", short: false) == "File in Social Security › 2026")
        #expect(FilingRouteText.guessButton(s.best!, providerRoot: "/D", short: true) == "File in 2026")
        #expect(FilingRouteText.weakGuess(token: "Age") == "A guess: only the word “Age” in the file ties it there")
    }
}

/// What the second adversarial review found, pinned.
@Suite struct FilingCardsReviewTwoTests {
    private func card(_ name: String, to path: String, newSegments: [String] = [], confidence: FilingConfidence = .high) -> FilingSuggestion {
        FilingSuggestion(filePath: "/D/TODO/" + name, fileName: name, size: 1, modificationDate: nil,
                         candidates: [FilingDestination(path: path, confidence: confidence, reasons: ["r"], newSegments: newSegments)],
                         providerRoot: "/D")
    }

    /// Open Destination Folder for a home filing would make opens the deepest folder that is there,
    /// so a group's ⋯ is never empty.
    @Test func theDestinationFolderIsTheDeepestThatExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeepestExisting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Credit 44928"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FilingRouteText.deepestExisting(root.path + "/Credit 44928/2026") == root.path + "/Credit 44928")
        #expect(FilingRouteText.deepestExisting(root.path + "/Credit 44928") == root.path + "/Credit 44928")
    }

    /// A group's Quick Look and Trash act on the selected row, only while it is a member and the
    /// rows show.
    @Test func aGroupActsOnItsSelectedRowOnly() {
        let a = card("01.pdf", to: "/D/IRA"), b = card("02.pdf", to: "/D/IRA")
        #expect(FilingGroupCard.target(members: [a, b], selected: b.id, expanded: true)?.id == b.id)
        #expect(FilingGroupCard.target(members: [a, b], selected: b.id, expanded: false) == nil, "folded: no row to act on")
        #expect(FilingGroupCard.target(members: [a], selected: b.id, expanded: true) == nil, "pulled out or trashed: gone")
        #expect(FilingGroupCard.target(members: [a, b], selected: nil, expanded: true) == nil)
    }

    /// A name typed into Create as is where the guess's button says it files, and what Copy
    /// Destination Path copies.
    @MainActor @Test func aTypedNameReachesTheGuessAndTheCopiedPath() {
        let s = card("r.pdf", to: "/D/Receipts/Hardware", newSegments: ["Hardware"], confidence: .low)
        let typed = s.best!.renamingNewFolder(to: "Tools")
        #expect(FilingRouteText.guessButton(typed, providerRoot: "/D", short: false) == "File in Receipts › Tools")
        let board = NSPasteboard(name: NSPasteboard.Name("FilingCardsReviewTwoTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let runner = FilingFileActionRunner(quickLook: { _, _ in }, pasteboard: board, home: { _ in typed },
                                            pullOut: { _ in }, chooseFolder: { _ in }, setAside: { _ in }, trash: { _ in })
        runner.perform(.copyDestinationPath, on: s, members: [s])
        #expect(board.string(forType: .string) == "/D/Receipts/Tools/r.pdf")
    }
}

/// The filing motion: a receipt waits unseen while its card shows, then stands in its place.
@Suite struct FilingReceiptLayoutTests {
    private func card(_ name: String) -> FilingSuggestion {
        FilingSuggestion(filePath: "/D/TODO/" + name, fileName: name, size: 1, modificationDate: nil,
                         candidates: [FilingDestination(path: "/D/Receipts", confidence: .high, reasons: ["r"], newSegments: [])],
                         providerRoot: "/D")
    }

    @Test func aReceiptTakesItsCardsPlaceOnceTheCardHasGone() throws {
        let a = card("a.pdf"), b = card("b.pdf"), c = card("c.pdf")
        let receipt = FilingReceipt(kind: .filed, cardID: b.id, section: .matched, index: 1, text: "Filed “b.pdf”")
        let before = try #require(FilingCardSections.sections([a, b, c]).first)
        let shown = FilingReceiptLayout.rows(before, receipts: [receipt], allCardIDs: [a.id, b.id, c.id])
        #expect(shown.map(\.id) == [a.id, b.id, c.id], "while the card shows, it says Filing… itself")
        let after = try #require(FilingCardSections.sections([a, c]).first)
        let gone = FilingReceiptLayout.rows(after, receipts: [receipt], allCardIDs: [a.id, c.id])
        #expect(gone.map(\.id) == [a.id, "receipt:" + receipt.id.uuidString, c.id], "the receipt stands where b stood")
    }

    @Test func aSummaryLeadsItsSection() throws {
        let a = card("a.pdf")
        let summary = FilingReceipt(kind: .summary, cardID: nil, section: .matched, index: 0, text: "Filed 12 files into 3 accounts")
        let section = try #require(FilingCardSections.sections([a]).first)
        #expect(FilingReceiptLayout.rows(section, receipts: [summary], allCardIDs: [a.id]).first?.id == "receipt:" + summary.id.uuidString)
    }

    @Test func aReceiptNamesTheLastTwoFolders() {
        let dest = FilingDestination(path: "/D/Finance/US/Credit Accounts/American Express/Credit 44928/2026",
                                     confidence: .high, reasons: [], newSegments: ["2026"])
        #expect(FilingReceiptLayout.place(dest, providerRoot: "/D") == "Credit 44928 › 2026")
    }
}
