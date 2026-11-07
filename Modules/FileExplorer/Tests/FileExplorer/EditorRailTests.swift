import Testing
import Foundation
import SwiftUI
import AppKit
import Sync
@testable import FileExplorer

/// What the editor's rail lists, and what it dims.
@Suite struct EditorRailTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editor-rail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ name: String, bytes: Int = 1, in folder: URL) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url.path
    }

    /// Nothing is cloud-only unless a test says so: the real check is an `lstat` for a placeholder
    /// flag, which a temp directory can never produce.
    private let nothingIsCloudOnly: (String) -> Bool = { _ in false }

    /// Text kinds and PDFs, the two Edit opens, are listed; a photo is not.
    @Test func onlyTextKindsAndPDFsAreListed() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("notes.md", in: folder)
        try file("readme.txt", in: folder)
        try file("photo.jpg", in: folder)
        try file("paper.pdf", in: folder)
        try file("data.json", in: folder)

        let rows = EditorRail.entries(in: folder.path, showsHidden: false,
                                      isCloudOnly: nothingIsCloudOnly)
        #expect(rows.map(\.name) == ["data.json", "notes.md", "paper.pdf", "readme.txt"])
        #expect(rows.map(\.kind) == [.text, .text, .pdf, .text])
    }

    /// A folder of files Edit doesn't open is not an empty folder: this count is what tells a
    /// folder of photos from one with nothing in it.
    @Test func aFolderOfUnopenableFilesIsCountedRatherThanCalledEmpty() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("photo one.jpg", in: folder)
        try file("photo two.jpg", in: folder)
        try file("letter.docx", in: folder)

        let survey = EditorRail.survey(in: folder.path, showsHidden: false,
                                       isCloudOnly: nothingIsCloudOnly)
        #expect(survey.rows.isEmpty, "a file Edit does not open was listed")
        #expect(survey.otherFileCount == 3,
                "counted \(survey.otherFileCount as Int?) of the 3 files in the folder")
    }

    /// Directories are not files: counting them would say "none of the 4 files" over a folder
    /// holding three subfolders and one file.
    @Test func theOtherFileCountLeavesFoldersOut() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("letter.docx", in: folder)
        for name in ["Archive", "Sent", "Drafts"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }

        let survey = EditorRail.survey(in: folder.path, showsHidden: false,
                                       isCloudOnly: nothingIsCloudOnly)
        #expect(survey.otherFileCount == 1,
                "subfolders were counted as files: \(survey.otherFileCount as Int?)")
    }

    /// The count describes what he can see. A folder whose only other file is hidden reads as empty
    /// while hidden files are off, because on screen it is.
    @Test func theOtherFileCountFollowsTheHiddenFilesPreference() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("visible.docx", in: folder)
        try file(".hidden.docx", in: folder)

        #expect(EditorRail.survey(in: folder.path, showsHidden: false,
                                  isCloudOnly: nothingIsCloudOnly).otherFileCount == 1)
        #expect(EditorRail.survey(in: folder.path, showsHidden: true,
                                  isCloudOnly: nothingIsCloudOnly).otherFileCount == 2)
    }

    /// Not asked when the rail has rows, which keeps the second pass off every folder with a note
    /// in it: only the empty caption reads this, and it isn't on screen then.
    @Test func theOtherFileCountIsNotAskedWhenTheRailListsSomething() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("notes.md", in: folder)
        try file("letter.docx", in: folder)

        let survey = EditorRail.survey(in: folder.path, showsHidden: false,
                                       isCloudOnly: nothingIsCloudOnly)
        #expect(survey.rows.map(\.name) == ["notes.md"])
        #expect(survey.otherFileCount == nil,
                "the folder was walked a second time to answer a question nobody asked")
    }

    /// A folder with nothing in it answers `0`, and a folder that couldn't be read answers `nil`:
    /// one is a fact about the folder, the other the absence of one. One that can't be listed has
    /// no rows rather than an error.
    @Test func nothingInItAndCouldNotReadItAreDifferentAnswers() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(EditorRail.survey(in: folder.path, showsHidden: false,
                                  isCloudOnly: nothingIsCloudOnly).otherFileCount == 0)
        let nowhere = EditorRail.survey(in: "/nowhere/at/all", showsHidden: false, isCloudOnly: nothingIsCloudOnly)
        #expect(nowhere.otherFileCount == nil && nowhere.rows.isEmpty)
        let empty = EditorRail.survey(in: "", showsHidden: false, isCloudOnly: nothingIsCloudOnly)
        #expect(empty.otherFileCount == nil && empty.rows.isEmpty)
    }

    @Test func hiddenFilesFollowTheAppsOwnPreference() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("visible.md", in: folder)
        try file(".hidden.md", in: folder)

        #expect(EditorRail.entries(in: folder.path, showsHidden: false,
                                   isCloudOnly: nothingIsCloudOnly).map(\.name) == ["visible.md"])
        #expect(EditorRail.entries(in: folder.path, showsHidden: true,
                                   isCloudOnly: nothingIsCloudOnly).map(\.name)
                == [".hidden.md", "visible.md"])
    }

    @Test func rowsAreOrderedTheWayFinderOrdersThem() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["note 10.md", "note 2.md", "Note 1.md"] { try file(name, in: folder) }

        let names = EditorRail.entries(in: folder.path, showsHidden: false,
                                       isCloudOnly: nothingIsCloudOnly).map(\.name)
        #expect(names == ["Note 1.md", "note 2.md", "note 10.md"],
                "the rail sorted by code points rather than the way a person reads numbers")
    }

    /// Listed and dim, never missing: a file the editor can't open is still a file in that folder,
    /// and leaving it out reads as the rail being broken.
    @Test func aFileOverTheReadCapIsListedDimWithAReason() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("small.md", bytes: 10, in: folder)
        try file("huge.md", bytes: BoundedTextRead.maxBytes + 1, in: folder)

        let rows = EditorRail.entries(in: folder.path, showsHidden: false,
                                      isCloudOnly: nothingIsCloudOnly)
        let huge = try #require(rows.first { $0.name == "huge.md" })
        let small = try #require(rows.first { $0.name == "small.md" })
        #expect(huge.isTooLarge && huge.isDimmed)
        // The exact words, as the cloud-only sibling below pins its own, so the reason can't drift
        // out of step with `EditorFileStore.refusal(for:)`, which it is worded to match. Both
        // numbers read 4.2 MB because the fixture is one byte over the cap.
        #expect(huge.dimmedReason == "Too large to open in Edit — 4.2 MB, and Edit opens text files up to 4.2 MB.")
        #expect(!small.isDimmed && small.dimmedReason == nil)
    }

    @Test func aCloudOnlyFileIsDimmedForThatReasonRatherThanForItsSize() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = try file("placeholder.md", bytes: 4, in: folder)

        let rows = EditorRail.entries(in: folder.path, showsHidden: false,
                                      isCloudOnly: { $0 == path })
        let row = try #require(rows.first)
        #expect(row.isCloudOnly && row.isDimmed && !row.isTooLarge)
        #expect(row.dimmedReason == "Not downloaded — there is nothing here to read yet.")
    }

    /// The dim reasons are the cheap ones. Being binary is found by reading the file, so the rail
    /// lists a `.txt` full of NULs as an ordinary row and the editor says so at open time.
    @Test func beingBinaryIsNotSomethingTheRailClaimsToKnow() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("blob.txt")
        try Data([0x00, 0x01, 0x02]).write(to: url)

        let row = try #require(EditorRail.entries(in: folder.path, showsHidden: false,
                                                  isCloudOnly: nothingIsCloudOnly).first)
        #expect(!row.isDimmed)
        guard case .refused = EditorFileStore.open(path: url.path) else {
            Issue.record("the editor opened a binary file the rail had offered")
            return
        }
    }

    // MARK: The filter

    private var three: [EditorRailEntry] {
        ["Release plan.md", "scratch.txt", "Récipes.md"].map {
            EditorRailEntry(path: "/n/\($0)", name: $0, size: 10, isCloudOnly: false)
        }
    }

    /// Anywhere in the name, ignoring case and diacritics: his folders have accented names in
    /// them, and somebody typing `rec` means `Récipes`. An empty or blank filter is no filter,
    /// since somebody who has typed a space and stopped is mid-thought, and answering "no files"
    /// would look like the rail emptied itself.
    @Test(arguments: [("plan", ["Release plan.md"]), ("PLAN", ["Release plan.md"]),
                      ("recipes", ["Récipes.md"]),
                      ("", ["Release plan.md", "scratch.txt", "Récipes.md"]),
                      ("   ", ["Release plan.md", "scratch.txt", "Récipes.md"]), ("zzz", []),
                      (".md", ["Release plan.md", "Récipes.md"])])
    func aFilterMatches(_ query: String, names: [String]) {
        #expect(EditorRail.filtered(three, matching: query).map(\.name) == names)
    }

    /// The filter narrows what is drawn and never reorders it: the Finder-like order is decided in
    /// `entries(in:)`, and a filter that re-sorted would make the list jump as you type.
    @Test func theFilterKeepsTheRailsOrder() {
        let ordered = EditorRail.filtered(three, matching: "e").map(\.name)
        #expect(ordered == three.filter { $0.name.localizedCaseInsensitiveContains("e") || $0.name.contains("é") }.map(\.name),
                "the filter reordered the rail: \(ordered)")
    }
}
