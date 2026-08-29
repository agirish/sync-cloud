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
        let tree = Self.view(["F/2013": (["A", "B", "C"], []),
                              "F/2013/A": ([], ["dup.pdf"]),
                              "F/2013/B": ([], ["dup.pdf"]),
                              "F/2013/C": ([], ["dup.pdf"])])
        // The two must have DIFFERENT owners, or reading `dst` instead of `collidedInto`
        // gives the same answer and the assertion cannot fail (law 1: the fixture's expected
        // value must not equal the fallback's).
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shape,
            actions: [.init(action: .moveFile, src: "F/2013/A/dup.pdf", dst: "F/2013/B/dup.pdf",
                            collidedInto: "F/2013/C/dup 2.pdf")])
        let preview = try #require(RestructurePlanner.preview(member: "F/2013", in: manifest,
                                                              tree: tree))
        let c = try #require(preview.after.first { $0.name == "C" })
        #expect(c.files == 2, "the file is counted where it LANDED, not where it was aimed")
        #expect(c.fate == .mergedFrom(renamedFrom: nil, sources: ["A"]))
        let b = try #require(preview.after.first { $0.name == "B" })
        #expect(b.files == 1, "B never received it")
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

    // MARK: The shapes a delta-based preview got wrong

    /// **A two-way swap goes through a temporary name**, and the after column must not show it.
    /// The delta version kept `B.restructure-swap` as a surviving row and gave `A` zero files.
    @Test func aSwapReportsTheOriginalNamesAndNoScratchFolder() throws {
        let tree = Self.view(["M": (["A", "B"], []),
                              "M/A": ([], ["a1.pdf", "a2.pdf"]),
                              "M/B": ([], ["b1.pdf"])])
        let manifest = try #require(try RestructurePlanner.manifest(
            family: "", members: ["M"],
            mapping: RestructureMapping(rows: [.init(source: "A", target: "B"),
                                               .init(source: "B", target: "A")]),
            kind: .shape, in: tree, profileId: "p", manifestId: "m", createdAt: "t").get())
        #expect(manifest.actions.contains { ($0.dst ?? "").contains("restructure-swap") },
                "the fixture must actually exercise the temp-name ring")

        let preview = try #require(RestructurePlanner.preview(member: "M", in: manifest,
                                                              tree: tree))
        #expect(preview.after.map(\.name) == ["A", "B"],
                "a scratch name is machinery, not a folder anyone will see")
        #expect(preview.after.map(\.files) == [1, 2], "the contents swapped with the names")
        #expect(preview.after[0].fate == .renamedFrom("B"))
        #expect(preview.after[1].fate == .renamedFrom("A"),
                "the chain collapses to the ORIGINAL name, not the temporary one")
    }

    /// A merge whose source holds no loose files moves only folders — and the delta version,
    /// which read merges off `move-file` alone, left the drained source standing.
    @Test func aFolderOnlyMergeStillDrainsItsSource() throws {
        let tree = Self.view(["M": (["Old", "Forms"], []),
                              "M/Old": (["Sub"], []),
                              "M/Old/Sub": ([], ["x.pdf"]),
                              "M/Forms": ([], ["f.pdf"])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "M", kind: .shape,
            actions: [.init(action: .moveDir, src: "M/Old/Sub", dst: "M/Forms/Sub")])
        let preview = try #require(RestructurePlanner.preview(member: "M", in: manifest,
                                                              tree: tree))
        #expect(preview.after.map(\.name) == ["Forms"], "Old gave up everything it had")
        #expect(preview.after[0].fate == .mergedFrom(renamedFrom: nil, sources: ["Old"]))
    }

    /// The discriminating other direction: a folder that gives up ONE of its things still
    /// stands, and dropping it would be the after column lying.
    @Test func aPartiallyDrainedFolderSurvives() throws {
        let tree = Self.view(["M": (["Old", "Forms"], []),
                              "M/Old": ([], ["keep.pdf", "go.pdf"]),
                              "M/Forms": ([], [])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "M", kind: .shape,
            actions: [.init(action: .moveFile, src: "M/Old/go.pdf", dst: "M/Forms/go.pdf")])
        let preview = try #require(RestructurePlanner.preview(member: "M", in: manifest,
                                                              tree: tree))
        #expect(preview.after.map(\.name) == ["Forms", "Old"])
        #expect(preview.after.first { $0.name == "Old" }?.files == 1)
    }

    /// A folder the plan trashes leaves the after column.
    @Test func aRemovedFolderIsGone() throws {
        let tree = Self.view(["M": (["Empty", "Keep"], []),
                              "M/Empty": ([], []), "M/Keep": ([], ["k.pdf"])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "M", kind: .deadWeight,
            actions: [.init(action: .removeEmptyDir, src: "M/Empty")])
        let preview = try #require(RestructurePlanner.preview(member: "M", in: manifest,
                                                              tree: tree))
        #expect(preview.after.map(\.name) == ["Keep"])
    }

    /// A folder carried in from OUTSIDE the member arrives with the files it carried — the
    /// delta version labelled it created and showed zero.
    @Test func aFolderCarriedInArrivesWithItsFiles() throws {
        let tree = Self.view(["M": (["Forms"], []), "M/Forms": ([], ["f.pdf"])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "M",
            kind: .looseBesideContainer,
            actions: [.init(action: .moveDir, src: "Elsewhere/Badge", dst: "M/Badge",
                            filesCarried: 4, movesWholeFolder: true)])
        let preview = try #require(RestructurePlanner.preview(member: "M", in: manifest,
                                                              tree: tree))
        let badge = try #require(preview.after.first { $0.name == "Badge" })
        #expect(badge.files == 4, "its files rode along")
        #expect(badge.fate == .created)
    }

    /// Depth is not decoration: a rename two levels down is not a top-level row, and a file two
    /// levels down does not change its grandparent's own count.
    @Test func onlyDirectChildrenGetRowsAndDirectItemsGetCounted() throws {
        let tree = Self.view(["M": (["Forms"], []),
                              "M/Forms": (["Sub"], ["top.pdf"]),
                              "M/Forms/Sub": ([], ["deep.pdf"])])
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "M", kind: .shape,
            actions: [.init(action: .renameDir, src: "M/Forms/Sub", dst: "M/Forms/Renamed"),
                      .init(action: .moveFile, src: "M/Forms/Renamed/deep.pdf",
                            dst: "M/Forms/Renamed/moved.pdf")])
        let preview = try #require(RestructurePlanner.preview(member: "M", in: manifest,
                                                              tree: tree))
        #expect(preview.after.map(\.name) == ["Forms"], "a deep rename invents no row")
        #expect(preview.after[0].files == 1, "the deep file never touched Forms's own count")
    }

    @Test func anUnknownMemberHasNoPreview() {
        #expect(RestructurePlanner.preview(
            member: "F/nope",
            in: RestructureManifest(profileId: "p", manifestId: "m", createdAt: "t",
                                    family: "F", kind: .shape, actions: []),
            tree: Self.view([:])) == nil)
    }
}
