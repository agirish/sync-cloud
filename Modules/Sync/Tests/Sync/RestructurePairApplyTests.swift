import Foundation
import Testing
@testable import Sync

/// The cross-parent pair merge **through the real executor**, not just the planner.
///
/// The pair tests next door stop at the derivation, and that gap hid the defect this suite exists
/// for: a whole-folder relocation derived perfectly and was then vetoed at apply by a rule that
/// assumes a `move-dir`'s source parent is a folder the plan drains. Every one of these runs
/// `executeRestructureActions` against a real temporary tree.
@Suite struct RestructurePairApplyTests {

    // MARK: - Fixtures

    private static func makeTree(_ files: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pair-apply-\(UUID().uuidString)")
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return root
    }

    private static func view(of root: URL) -> RestructureTreeView {
        .fromDisk(root: root)
    }

    private static func run(_ manifest: RestructureManifest, in root: URL)
        -> FileSyncManager.RestructureExecution {
        FileSyncManager.executeRestructureActions(manifest.actions, root: root.path,
                                                  fm: FileManager.default)
    }

    private static func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    // MARK: - The whole-folder relocation

    /// **The loose-folder plan has to land.** Its detector only fires when a sibling container
    /// exists — that sibling is exactly what the apply's unlisted-file rule reads as "an item the
    /// plan never listed", so before the action declared itself a relocation this was skipped
    /// every single time, on every tree, while the sheet reported a successful landing.
    @Test func aWholeFolderMoveLandsPastItsUninvolvedSiblings() throws {
        let root = try Self.makeTree(["Work/Badge/badge.pdf",
                                      "Work/Acme/Offer Letter/offer.pdf",
                                      "Work/Payslips/2024.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Work/Badge", destination: "Work/Acme/Badge",
            kind: .looseBesideContainer, in: Self.view(of: root),
            profileId: "p", manifestId: "m", createdAt: "t").get())

        let execution = Self.run(manifest, in: root)

        #expect(execution.skipped.isEmpty,
                "the siblings this plan never touches are not a reason to refuse it")
        #expect(execution.foldersMovedWhole == 1)
        #expect(execution.performed.count == 1)
        #expect(Self.exists(root, "Work/Acme/Badge/badge.pdf"))
        #expect(!Self.exists(root, "Work/Badge"))
        #expect(Self.exists(root, "Work/Payslips/2024.pdf"), "the sibling is untouched")
    }

    /// The flag is what licenses that, and it must be narrow: an ordinary merge's `move-dir` —
    /// which DOES drain its source — keeps the veto, or the rule protecting every mapped plan
    /// would have been switched off for all of them.
    @Test func anOrdinaryMergeStillRefusesADrainItCannotAccountFor() throws {
        let root = try Self.makeTree(["Health/TODO/Dental/invoice.pdf",
                                      "Health/TODO/Dental/Claims/claim.pdf",
                                      "Health/Dental/summary.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Health/TODO/Dental", destination: "Health/Dental",
            kind: .mirroredInbox, in: Self.view(of: root),
            profileId: "p", manifestId: "m", createdAt: "t").get())
        #expect(manifest.actions.allSatisfy { $0.movesWholeFolder != true },
                "a merge drains its source — none of its moves is a relocation")

        // A file lands in the source between plan and apply. The plan never listed it, so the
        // whole drain is refused rather than moving around it.
        try Data("late".utf8).write(to: root.appendingPathComponent("Health/TODO/Dental/late.pdf"))
        let execution = Self.run(manifest, in: root)

        #expect(execution.filesMoved == 0)
        #expect(execution.skipped.contains { $0.contains("the plan never listed") })
    }

    /// A relocation empties nothing. Reading the drained folder off the action's path made this
    /// the source's PARENT, so the landing's card offered `Work/` — which still held `Acme` —
    /// as a folder to move to the Trash.
    @Test func aWholeFolderMoveReportsNoEmptiedFolders() throws {
        let root = try Self.makeTree(["Work/Badge/badge.pdf", "Work/Acme/Offer Letter/offer.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Work/Badge", destination: "Work/Acme/Badge",
            kind: .looseBesideContainer, in: Self.view(of: root),
            profileId: "p", manifestId: "m", createdAt: "t").get())

        #expect(RestructureLedger.emptiedFolders(of: manifest) == [],
                "the source travelled intact and its parent kept every other child")
        #expect(RestructureLedger(of: manifest).foldersEmptied == 0)
    }

    /// The discriminating other direction: a real merge DOES empty its source, and the removal
    /// step depends on that still being reported.
    @Test func aMergeStillReportsTheFolderItDrained() throws {
        let root = try Self.makeTree(["Health/TODO/Dental/invoice.pdf",
                                      "Health/Dental/summary.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Health/TODO/Dental", destination: "Health/Dental",
            kind: .mirroredInbox, in: Self.view(of: root),
            profileId: "p", manifestId: "m", createdAt: "t").get())
        #expect(RestructureLedger.emptiedFolders(of: manifest) == ["Health/TODO/Dental"])
    }

    // MARK: - The empty same-name subfolder

    /// A same-name subfolder that is EMPTY produces no file moves and no deeper rows, so nothing
    /// in the manifest named it — and the apply's unlisted-file rule then read it as an item the
    /// plan never listed and refused the whole merge. It is listed as kept instead.
    @Test func anEmptySameNameSubfolderIsListedSoTheMergeCanRun() throws {
        let root = try Self.makeTree(["Health/TODO/Dental/invoice.pdf",
                                      "Health/Dental/Claims/old.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        // The source's own `Claims/` exists and is empty; the destination has one too.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/TODO/Dental/Claims"),
            withIntermediateDirectories: true)

        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Health/TODO/Dental", destination: "Health/Dental",
            kind: .mirroredInbox, in: Self.view(of: root),
            profileId: "p", manifestId: "m", createdAt: "t").get())

        #expect(manifest.actions.contains {
            $0.action == .keep && $0.src == "Health/TODO/Dental/Claims"
        }, "the empty shell has to appear in the manifest or the veto reads it as unlisted")

        let execution = Self.run(manifest, in: root)
        #expect(execution.skipped.isEmpty)
        #expect(execution.filesMoved == 1)
        #expect(Self.exists(root, "Health/Dental/invoice.pdf"))
        #expect(Self.exists(root, "Health/Dental/Claims/old.pdf"),
                "the destination's own Claims is untouched")
    }

    // MARK: - Undo

    /// Whatever route derived it, the stored inverse has to put the tree back byte for byte.
    @Test func aRelocationIsReversedByItsOwnInverse() throws {
        let root = try Self.makeTree(["Work/Badge/badge.pdf", "Work/Acme/Offer Letter/offer.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let before = Self.treeList(root)
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Work/Badge", destination: "Work/Acme/Badge",
            kind: .looseBesideContainer, in: Self.view(of: root),
            profileId: "p", manifestId: "m", createdAt: "t").get())

        var landed = manifest
        landed.actions = Self.run(manifest, in: root).performed
        #expect(landed.actions.count == 1)

        // The inverse runs with the veto off, exactly as `undoReorganisation` runs it.
        let undo = FileSyncManager.executeRestructureActions(
            landed.inverse.actions, root: root.path, fm: FileManager.default,
            vetoUnlistedSourceFolders: false)
        #expect(undo.skipped.isEmpty)
        #expect(Self.treeList(root) == before, "the tree is back where it started")
    }

    private static func treeList(_ root: URL) -> String {
        var lines: [String] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker {
                lines.append(String(url.path.dropFirst(root.path.count)))
            }
        }
        return lines.sorted().joined(separator: " | ")
    }
}
