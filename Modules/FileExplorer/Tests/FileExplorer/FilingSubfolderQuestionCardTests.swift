import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// "Scan TODO’s subfolders too?", the card To File shows before a scan of an inbox whose files sit
/// in subfolders: its words in each state, where it sits among To File's states, and its buttons at
/// the Ask Claude column's width.
@MainActor
@Suite struct FilingSubfolderQuestionCardTests {

    private let todo = FilingSubfolderQuestion(
        folder: "/x/Documents/TODO", looseFiles: 1, files: 256, folders: 42,
        commonPath: ["Finance"], largestGroups: ["Charles Schwab", "Chase", "Bank of America"], otherGroups: 6)

    @Test func theCardForOneLooseFileAndManyBelow() {
        #expect(FilingSubfolderText.title(todo) == "Scan TODO’s subfolders too?")
        #expect(FilingSubfolderText.message(todo) == "1 file sits in TODO itself. 256 more are in 42 subfolders: "
                + "Finance › Charles Schwab, Chase, Bank of America and 6 more.")
        #expect(FilingSubfolderText.scanAll(todo) == "Scan All 257 Files")
        #expect(FilingSubfolderText.folderOnly(todo) == "Only the 1 in TODO")
    }

    @Test func aFolderWithNothingOfItsOwn() {
        let q = FilingSubfolderQuestion(folder: "/x/Downloads", looseFiles: 0, files: 1, folders: 1,
                                        commonPath: ["Unzipped", "Receipts"])
        #expect(FilingSubfolderText.title(q) == "Scan Downloads’ subfolders?")
        #expect(FilingSubfolderText.message(q) == "Nothing sits in Downloads itself. 1 file is in 1 subfolder: Unzipped › Receipts.")
        #expect(FilingSubfolderText.scanAll(q) == "Scan All 1 File")
    }

    @Test func pastTheCountsCapItSaysAtLeast() {
        let q = FilingSubfolderQuestion(folder: "/x/TODO", looseFiles: 3, files: 19_950, folders: 300, atLeast: true,
                                        largestGroups: ["Finance", "Medical"])
        #expect(FilingSubfolderText.message(q) == "3 files sit in TODO itself. At least 19,950 more are in its subfolders: "
                + "Finance and Medical.")
        #expect(FilingSubfolderText.scanAll(q) == "Scan All Files", "no total to vouch for")
    }

    @Test func theQuestionComesBeforeEveryOtherState() {
        #expect(LensWorkspaceView.filingContentState(asksAboutSubfolders: true, isScanning: true, showsSetup: true,
                                                     rowsShown: 3, suggestions: 3, scopeIsSet: false,
                                                     scopeWasScanned: true) == .asksAboutSubfolders)
        #expect(LensWorkspaceView.filingContentState(asksAboutSubfolders: false, isScanning: false, showsSetup: false,
                                                     rowsShown: 3, suggestions: 3, scopeIsSet: false,
                                                     scopeWasScanned: true) == .list)
    }

    private func height(_ q: FilingSubfolderQuestion, width: CGFloat) -> CGFloat {
        let buttons = FilingSubfolderQuestionButtons(question: q, always: false, onScanAll: {}, onFolderOnly: {}, onNotNow: {})
        return NSHostingController(rootView: buttons).sizeThatFits(in: CGSize(width: width, height: 400)).height
    }

    /// At the Ask Claude column (~340 pt, less the card's 28 pt sides) the buttons stack; wide,
    /// they share a row. Heights, not widths: a squeezed row would fit the width too.
    @Test func theButtonsStackInANarrowColumn() {
        let wide = height(todo, width: 600)
        let narrow = height(todo, width: 284)
        #expect(narrow > wide * 1.6, "stacked at 284 pt: \(narrow) against \(wide) in a row")
    }
}
