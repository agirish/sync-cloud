import Foundation
import Testing
@testable import Sync

/// §5.4's review section shows the operations; this is the shape those operations produce — one
/// member's children before and after, derived from the manifest alone (proposal O3).
@Suite struct RestructurePreviewTests {

    private static func view(_ tree: [String: (folders: [String], files: [String])])
        -> RestructureTreeView {
        RestructureTreeView(childFolders: { tree[$0]?.folders },
                            files: { tree[$0]?.files },
                            fileCount: { tree[$0]?.files.count })
    }

    /// The flagship shape: two folders converge on one name, a third is kept because the target
    /// shape has no slot for it, and a fourth is created empty.
    @Test func aMergeShowsTheSourcesFoldingIntoOneRow() throws {
        let tree = Self.view([
            "F/2013": (["Federal Tax", "State Tax", "Transcripts"], []),
            "F/2013/Federal Tax": ([], ["a.pdf", "b.pdf"]),
            "F/2013/State Tax": ([], ["c.pdf"]),
            "F/2013/Transcripts": ([], ["t.pdf"]),
        ])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shape,
            actions: [
                .init(action: .renameDir, src: "F/2013/Federal Tax", dst: "F/2013/Forms",
                      filesCarried: 2),
                .init(action: .moveFile, src: "F/2013/State Tax/c.pdf",
                      dst: "F/2013/Forms/c.pdf"),
                .init(action: .createDir, dst: "F/2013/Reference"),
                .init(action: .keep, src: "F/2013/Transcripts"),
            ])
        let preview = try #require(RestructurePlanner.preview(member: "F/2013", in: manifest,
                                                              tree: tree))

        #expect(preview.before.map(\.name) == ["Federal Tax", "State Tax", "Transcripts"])
        #expect(preview.before.map(\.files) == [2, 1, 1])

        #expect(preview.after.map(\.name) == ["Forms", "Reference", "Transcripts"])
        #expect(preview.after.map(\.files) == [3, 0, 1],
                "the merged row carries both sources' files; the created one holds nothing")
        #expect(preview.after[0].fate
                    == .mergedFrom(renamedFrom: "Federal Tax", sources: ["State Tax"]),
                "the row took its name from one folder and its files from two")
        #expect(preview.after[1].fate == .created)
        #expect(preview.after[2].fate == .kept)
        #expect(!preview.after.contains { $0.name == "State Tax" },
                "a drained source stops existing as itself")
    }

    /// A pure rename keeps its files and says where the name came from — a different claim from
    /// a merge, and the column is the only place the difference is visible.
    @Test func aRenameIsNotAMerge() throws {
        let tree = Self.view(["F/2016": (["IRS Docs - 2016"], []),
                              "F/2016/IRS Docs - 2016": ([], ["x.pdf", "y.pdf"])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shadowAxis,
            actions: [.init(action: .renameDir, src: "F/2016/IRS Docs - 2016",
                            dst: "F/2016/2016", filesCarried: 2)])
        let preview = try #require(RestructurePlanner.preview(member: "F/2016", in: manifest,
                                                              tree: tree))
        #expect(preview.after.map(\.name) == ["2016"])
        #expect(preview.after[0].fate == .renamedFrom("IRS Docs - 2016"))
        #expect(preview.after[0].files == 2, "a rename carries its files")
    }

    /// A member the plan never touches shows the same two columns — that is the honest answer,
    /// and an empty after-column would read as "everything goes".
    @Test func anUntouchedMemberIsUnchangedOnBothSides() throws {
        let tree = Self.view(["F/2020": (["Forms"], []), "F/2020/Forms": ([], ["a.pdf"])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shape,
            actions: [.init(action: .renameDir, src: "F/2013/Old", dst: "F/2013/New")])
        let preview = try #require(RestructurePlanner.preview(member: "F/2020", in: manifest,
                                                              tree: tree))
        #expect(preview.before.map(\.name) == preview.after.map(\.name))
        #expect(preview.after.allSatisfy { $0.fate == .unchanged })
    }

    /// Only DIRECT children get rows: a file moving two levels down belongs to its folder's row.
    @Test func aDeeperMoveDoesNotInventARow() throws {
        let tree = Self.view(["F/2013": (["Forms"], []),
                              "F/2013/Forms": (["Sub"], []),
                              "F/2013/Forms/Sub": ([], ["a.pdf"])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shape,
            actions: [.init(action: .moveFile, src: "F/2013/Forms/Sub/a.pdf",
                            dst: "F/2013/Forms/a.pdf")])
        let preview = try #require(RestructurePlanner.preview(member: "F/2013", in: manifest,
                                                              tree: tree))
        #expect(preview.after.map(\.name) == ["Forms"])
    }

    /// A collision lands the file under another name, and the count has to follow where it
    /// actually went rather than where the plan aimed it.
    @Test func aCollidedFileCountsWhereItLanded() throws {
        let tree = Self.view(["F/2013": (["A", "B"], []),
                              "F/2013/A": ([], ["dup.pdf"]),
                              "F/2013/B": ([], ["dup.pdf"])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shape,
            actions: [.init(action: .moveFile, src: "F/2013/A/dup.pdf", dst: "F/2013/B/dup.pdf",
                            collidedInto: "F/2013/B/dup 2.pdf")])
        let preview = try #require(RestructurePlanner.preview(member: "F/2013", in: manifest,
                                                              tree: tree))
        #expect(preview.after.first { $0.name == "B" }?.fate
                    == .mergedFrom(renamedFrom: nil, sources: ["A"]),
                "B was never renamed — it only absorbed")
        let b = try #require(preview.after.first { $0.name == "B" })
        #expect(b.files == 2, "both files are there — a collision keeps both")
    }

    /// **Against the 6 Aug oracle** — the release's own proof fixture. That day renamed
    /// `Application` to `Petition` under H-1B, carrying its files; the preview of the member it
    /// happened in has to show exactly that and invent nothing else.
    @Test func theOraclesRenameShowsAsARenameInItsMember() throws {
        let url = try #require(Bundle.module.url(forResource: "restructure-immigration-oracle",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let object = try #require(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: url)) as? [String: Any])
        let profile = try JSONDecoder().decode(
            FolderProfile.self,
            from: try JSONSerialization.data(withJSONObject: try #require(object["profile"])))
        let view = RestructureTreeView.fromProfile(profile)

        let family = "Immigration/Authorization/H-1B"
        let members = try #require(view.childFolders(family)).sorted()
        let result = RestructurePlanner.manifest(
            family: family, members: members,
            mapping: RestructureMapping(rows: [.init(source: "Application", target: "Petition")]),
            kind: .shape, in: view, profileId: "p", manifestId: "m", createdAt: "t")
        let manifest = try #require(try result.get())

        // The member the log's rename happened in.
        let renamed = try #require(manifest.actions.first { $0.action == .renameDir })
        let member = ((renamed.src ?? "") as NSString).deletingLastPathComponent
        let preview = try #require(RestructurePlanner.preview(member: member, in: manifest,
                                                              tree: view))

        #expect(preview.before.contains { $0.name == "Application" })
        #expect(!preview.before.contains { $0.name == "Petition" },
                "the fixture is the tree BEFORE that day's fix")
        let after = try #require(preview.after.first { $0.name == "Petition" })
        #expect(after.fate == .renamedFrom("Application"))
        #expect(after.files == renamed.filesCarried,
                "the rename carries exactly the files the log recorded")
        #expect(!preview.after.contains { $0.name == "Application" })
        #expect(preview.before.count == preview.after.count,
                "a pure rename adds and removes nothing")
    }

    @Test func anUnknownMemberHasNoPreview() {
        #expect(RestructurePlanner.preview(
            member: "F/nope",
            in: RestructureManifest(profileId: "p", manifestId: "m", createdAt: "t",
                                    family: "F", kind: .shape, actions: []),
            tree: Self.view([:])) == nil)
    }
}
