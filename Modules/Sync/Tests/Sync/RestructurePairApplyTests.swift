import Foundation
import Testing
@testable import Sync

/// The cross-parent pair merge through the real executor, not just the planner. The pair tests
/// next door stop at the derivation, which can't see a correct plan vetoed at apply (say, by a rule
/// assuming a `move-dir`'s source parent is drained). Every one of these runs
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

    /// `Health/TODO/Dental` merged into `Health/Dental`: the mirrored inbox.
    private static func dentalMerge(in root: URL) throws -> RestructureManifest {
        try #require(try RestructurePlanner.pairMergeManifest(
            source: "Health/TODO/Dental", destination: "Health/Dental", kind: .mirroredInbox,
            in: view(of: root), profileId: "p", manifestId: "m", createdAt: "t").get())
    }

    /// The loose `Work/Badge` moved whole into `Work/Acme/Badge`, beside its container.
    private static func badgeRelocation(in root: URL) throws -> RestructureManifest {
        try #require(try RestructurePlanner.pairMergeManifest(
            source: "Work/Badge", destination: "Work/Acme/Badge", kind: .looseBesideContainer,
            in: view(of: root), profileId: "p", manifestId: "m", createdAt: "t").get())
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

    /// The loose-folder plan has to land. Its detector fires only when a sibling container exists,
    /// and that sibling is what the apply's unlisted-file rule reads as "an item the plan never
    /// listed", so the action must declare itself a relocation or it is skipped on every tree.
    @Test func aWholeFolderMoveLandsPastItsUninvolvedSiblings() throws {
        let root = try Self.makeTree(["Work/Badge/badge.pdf",
                                      "Work/Acme/Offer Letter/offer.pdf",
                                      "Work/Payslips/2024.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try Self.badgeRelocation(in: root)

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
        let manifest = try Self.dentalMerge(in: root)
        #expect(manifest.actions.allSatisfy { $0.movesWholeFolder != true },
                "a merge drains its source — none of its moves is a relocation")

        // A file lands in the source between plan and apply. The plan never listed it, so the
        // whole drain is refused rather than moving around it.
        try Data("late".utf8).write(to: root.appendingPathComponent("Health/TODO/Dental/late.pdf"))
        let execution = Self.run(manifest, in: root)

        #expect(execution.filesMoved == 0)
        #expect(execution.skipped.contains { $0.contains("the plan never listed") })
    }

    /// A file landing where the target has a folder of that name, in any case, collides as surely
    /// as a file would: the apply lands it under a unique name, so the plan must not promise no
    /// collision. One level down too.
    @Test func aFolderOfTheSameNameIsACollision() throws {
        let root = try Self.makeTree(["Health/TODO/Dental/Claims",
                                      "Health/TODO/Dental/Sub/Notes",
                                      "Health/Dental/claims/old.pdf",
                                      "Health/Dental/Sub/notes/a.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try Self.dentalMerge(in: root)
        func move(_ src: String) -> RestructureManifest.Action? {
            manifest.actions.first { $0.action == .moveFile && $0.src == src }
        }
        #expect(try #require(move("Health/TODO/Dental/Claims")).collisionExpected == true,
                "a file landing on a folder of its name was planned as no collision")
        #expect(try #require(move("Health/TODO/Dental/Sub/Notes")).collisionExpected == true,
                "one level down, the same")

        let execution = Self.run(manifest, in: root)
        #expect(execution.collisions == 2, "the premise: the apply does collide")
    }

    // MARK: - The landing journal (FR16)

    /// Every action the executor performs is on disk, in order and with its collision name, the
    /// moment it runs — what an Undo of a cut-off landing has to go on.
    @Test func theExecutorJournalsEachActionAsItRuns() throws {
        let root = try Self.makeTree(["Health/TODO/Dental/invoice.pdf", "Health/TODO/Dental/x-ray.pdf",
                                      "Health/Dental/invoice.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try Self.dentalMerge(in: root)
        let url = root.appendingPathComponent("journal.jsonl")
        let journal = try #require(RestructureLandingJournal(at: url))

        let execution = FileSyncManager.executeRestructureActions(manifest.actions, root: root.path,
                                                                  fm: FileManager.default, journal: journal)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let recorded = try lines.map { try JSONDecoder().decode(RestructureManifest.Action.self, from: Data($0.utf8)) }
        #expect(!execution.performed.isEmpty)
        #expect(recorded == execution.performed)
        #expect(recorded.contains { $0.collidedInto != nil }, "the collision name is in the journal")
    }

    // MARK: - Packages and links travel whole (FR2)

    /// Both folders hold `Return.pages`. Merging one level down would move one document's insides
    /// into the other (`Index 2.zip`) and leave a shell that won't open. A package is one item: it
    /// moves whole, and the name already taken keeps both.
    @Test func aMergeMovesAPackageWholeAndKeepsBoth() throws {
        let root = try Self.makeTree(["Health/TODO/Dental/Return.pages/Index.zip",
                                      "Health/TODO/Dental/Return.pages/Data/p.jpg",
                                      "Health/Dental/Return.pages/Index.zip",
                                      "Health/Dental/Return.pages/Data/q.jpg"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try Self.dentalMerge(in: root)

        let execution = Self.run(manifest, in: root)

        let fm = FileManager.default
        let kept = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Health/Dental/Return.pages").path)
        #expect(Set(kept) == ["Index.zip", "Data"], "nothing was moved into the other document")
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Health/Dental/Return.pages/Data").path) == ["q.jpg"])
        let arrived = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Health/Dental").path)
            .first { $0 != "Return.pages" && $0.hasSuffix(".pages") }
        let moved = try #require(arrived, "the source document arrived beside it under its own name")
        #expect(Self.exists(root, "Health/Dental/\(moved)/Index.zip"))
        #expect(Self.exists(root, "Health/Dental/\(moved)/Data/p.jpg"))
        #expect(execution.collisions == 1)
    }

    /// The pair route names the packages themselves: a mirrored inbox holding `TODO/Return.pages`
    /// beside `Return.pages`. A document has no listing, so no merge of its insides is planned.
    @Test func aPairMergeRefusesAPackageAsEitherEnd() throws {
        let root = try Self.makeTree(["Taxes/TODO/Return.pages/Index.zip",
                                      "Taxes/Return.pages/Index.zip"])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try RestructurePlanner.pairMergeManifest(
            source: "Taxes/TODO/Return.pages", destination: "Taxes/Return.pages",
            kind: .mirroredInbox, in: Self.view(of: root),
            profileId: "p", manifestId: "m", createdAt: "t")
        guard case .failure = result else {
            Issue.record("a merge of one document into another was planned: \(result)")
            return
        }
    }

    /// `TODO/Dental/Shared` is a link to a folder in another provider. Merging through it would
    /// move that provider's files into this tree. The link is one item: it moves, its target stays.
    @Test func aMergeMovesALinkNotWhatItPointsAt() throws {
        let root = try Self.makeTree(["Elsewhere/Shared/theirs.pdf",
                                      "Health/TODO/Dental/invoice.pdf",
                                      "Health/Dental/Shared/ours.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("Health/TODO/Dental/Shared"),
                                  withDestinationURL: root.appendingPathComponent("Elsewhere/Shared"))
        let manifest = try Self.dentalMerge(in: root)

        _ = Self.run(manifest, in: root)

        #expect(Self.exists(root, "Elsewhere/Shared/theirs.pdf"), "the link's target was not drained")
        #expect(!Self.exists(root, "Health/Dental/Shared/theirs.pdf"))
        #expect(Self.exists(root, "Health/Dental/invoice.pdf"))
        let landed = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Health/Dental").path)
            .filter { $0.hasPrefix("Shared") && $0 != "Shared" }
        #expect(landed.count == 1, "the link itself travelled, under a name of its own")
        if let name = landed.first {
            let attrs = try fm.attributesOfItem(atPath: root.appendingPathComponent("Health/Dental/\(name)").path)
            #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        }
    }

    /// A relocation empties nothing. Reading the drained folder off the action's path would make it
    /// the source's parent, and the landing's card would offer `Work/`, which still holds `Acme`,
    /// as a folder to move to the Trash.
    @Test func aWholeFolderMoveReportsNoEmptiedFolders() throws {
        let root = try Self.makeTree(["Work/Badge/badge.pdf", "Work/Acme/Offer Letter/offer.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try Self.badgeRelocation(in: root)

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
        let manifest = try Self.dentalMerge(in: root)
        #expect(RestructureLedger.emptiedFolders(of: manifest) == ["Health/TODO/Dental"])
    }

    // MARK: - The empty same-name subfolder

    /// A same-name subfolder that is empty produces no file moves and no deeper rows, so the
    /// apply's unlisted-file rule would read it as unlisted and refuse the whole merge. It is
    /// listed as kept instead.
    @Test func anEmptySameNameSubfolderIsListedSoTheMergeCanRun() throws {
        let root = try Self.makeTree(["Health/TODO/Dental/invoice.pdf",
                                      "Health/Dental/Claims/old.pdf"])
        defer { try? FileManager.default.removeItem(at: root) }
        // The source's own `Claims/` exists and is empty; the destination has one too.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Health/TODO/Dental/Claims"),
            withIntermediateDirectories: true)

        let manifest = try Self.dentalMerge(in: root)

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
        let manifest = try Self.badgeRelocation(in: root)

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
