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

    /// Nothing is cloud-only unless a test says so — the real check is an `lstat` for a placeholder
    /// flag, which a temp directory can never produce.
    private let nothingIsCloudOnly: (String) -> Bool = { _ in false }

    @Test func onlyTextKindsAreListed() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("notes.md", in: folder)
        try file("readme.txt", in: folder)
        try file("photo.jpg", in: folder)
        try file("paper.pdf", in: folder)
        try file("data.json", in: folder)

        let names = EditorRail.entries(in: folder.path, showsHidden: false,
                                       isCloudOnly: nothingIsCloudOnly).map(\.name)
        #expect(names == ["data.json", "notes.md", "readme.txt"])
    }

    @Test func foldersAreNotOfferedAsFilesToOpen() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        try file("real.md", in: folder)
        // A directory whose name ends in a text extension — the case a name-only filter passes.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("archive.md"),
                                                withIntermediateDirectories: true)

        let names = EditorRail.entries(in: folder.path, showsHidden: false,
                                       isCloudOnly: nothingIsCloudOnly).map(\.name)
        #expect(names == ["real.md"], "a folder named like a text file was offered for editing")
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

    /// **Listed and dim, never missing.** A file the editor cannot open is still a file in that
    /// folder, and leaving it out reads as the rail being broken.
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
        // The exact words, as the cloud-only sibling below pins its own. `!= nil` accepted any
        // string at all, so the reason could have drifted to "x" — or, more likely, out of step
        // with `BoundedTextRead.Outcome.caption`, which it says it is worded to match.
        // (Both numbers read 4.2 MB because the fixture is one byte over the cap; a real 40 MB file
        // reads "40 MB; the limit is 4.2 MB". The words are what is pinned here, not the fixture.)
        #expect(huge.dimmedReason == "Too large to open (4.2 MB; the limit is 4.2 MB).")
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

    /// The dim reasons are the cheap ones. Being binary is discovered by reading the file, so the
    /// rail lists a `.txt` full of NULs as an ordinary row and the editor says so at open time.
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

    @Test func aFolderThatCannotBeListedIsEmptyRatherThanAnError() {
        #expect(EditorRail.entries(in: "", showsHidden: false, isCloudOnly: nothingIsCloudOnly).isEmpty)
        #expect(EditorRail.entries(in: "/nowhere/at/all", showsHidden: false,
                                   isCloudOnly: nothingIsCloudOnly).isEmpty)
    }
}
