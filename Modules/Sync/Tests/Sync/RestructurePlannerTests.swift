import Foundation
import Testing
@testable import Sync

/// A tree the planner can be pointed at without a disk: folder paths to file names, with the
/// child-folder relation derived from the paths themselves.
private struct FakeTree {
    let files: [String: [String]]

    var view: RestructureTreeView {
        let known = Set(files.keys)
        return RestructureTreeView(
            childFolders: { path in
                guard known.contains(path) else { return nil }
                let prefix = path + "/"
                return known.compactMap { other -> String? in
                    guard other.hasPrefix(prefix) else { return nil }
                    let rest = other.dropFirst(prefix.count)
                    return rest.contains("/") ? nil : String(rest)
                }.sorted()
            },
            files: { files[$0] },
            fileCount: { files[$0]?.count })
    }
}

/// §5.4's derivation rules, one law per test — and the 6 Aug oracle, which is the release's
/// definition of "derived correctly".
@Suite struct RestructurePlannerTests {

    private static func derive(family: String, members: [String], mapping: RestructureMapping,
                               in view: RestructureTreeView)
        throws -> RestructureManifest {
        try RestructurePlanner.manifest(
            family: family, members: members, mapping: mapping, kind: .shape, in: view,
            profileId: "p", manifestId: "m1", createdAt: "2026-08-28T00:00:00").get()
    }

    // MARK: - The 6 Aug oracle

    /// The proof §5.4 names: the fixture reduced from that day's log, the mapping as it was
    /// decided, and the derived manifest must be **exactly the log's four `rename-dir` operations
    /// with their `filesCarried`, and no `move-file`** — three families, each mapped its own way,
    /// because the direction the 6 Aug fix went existed nowhere in the tree.
    @Test func theOracleDerivesToExactlyTheLogsFourRenames() throws {
        let url = try #require(Bundle.module.url(forResource: "restructure-immigration-oracle",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profileData = try JSONSerialization.data(
            withJSONObject: try #require(object["profile"]))
        let profile = try JSONDecoder().decode(FolderProfile.self, from: profileData)
        let view = RestructureTreeView.fromProfile(profile)

        struct ExpectedOp: Decodable, Equatable {
            let action: String
            let src: String
            let dst: String
            let filesCarried: Int
        }
        let expectedData = try JSONSerialization.data(
            withJSONObject: try #require(object["expected"]))
        let expected = try JSONDecoder().decode([ExpectedOp].self, from: expectedData)
        #expect(expected.count == 4)

        // Per family, the mapping as §5.4 records it: Application → Petition under H-1B;
        // Petition → Application under H-4 (H-4 EAD carries no Petition in this range); and the
        // DS-160 spelling fix under the visa family.
        let plans: [(family: String, mapping: RestructureMapping)] = [
            ("Immigration/Authorization/H-1B",
             RestructureMapping(rows: [.init(source: "Application", target: "Petition")])),
            ("Immigration/Authorization/H-4",
             RestructureMapping(rows: [.init(source: "Petition", target: "Application")])),
            ("Immigration/Visa/US/H-1B Visa",
             RestructureMapping(rows: [.init(source: "DS-160 Form", target: "DS-160")])),
        ]
        var derived: [ExpectedOp] = []
        for plan in plans {
            let members = try #require(view.childFolders(plan.family),
                                       "the fixture must know \(plan.family)")
            let manifest = try Self.derive(family: plan.family, members: members.sorted(),
                                           mapping: plan.mapping, in: view)
            #expect(!manifest.actions.contains { $0.action == .moveFile },
                    "the 6 Aug fix moved nothing — every operation is an atomic rename")
            #expect(manifest.actions.allSatisfy { $0.evidence?.isEmpty == false },
                    "every operation carries its written justification")
            derived.append(contentsOf: manifest.actions
                .filter { $0.action == .renameDir }
                .map { ExpectedOp(action: $0.action.rawValue, src: $0.src ?? "",
                                  dst: $0.dst ?? "", filesCarried: $0.filesCarried ?? -1) })
        }
        #expect(derived == expected,
                "the derived manifest must be the log's four renames, counts and all")
    }

    /// The involution law, on the oracle's own manifest — plan-time, collision-free, which is the
    /// law's stated scope.
    @Test func theOracleManifestIsInvolutive() throws {
        let url = try #require(Bundle.module.url(forResource: "restructure-immigration-oracle",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let profile = try JSONDecoder().decode(FolderProfile.self, from:
            JSONSerialization.data(withJSONObject: try #require(object["profile"])))
        let view = RestructureTreeView.fromProfile(profile)
        let family = "Immigration/Authorization/H-4"
        let manifest = try Self.derive(
            family: family, members: try #require(view.childFolders(family)).sorted(),
            mapping: RestructureMapping(rows: [.init(source: "Petition", target: "Application")]),
            in: view)
        #expect(manifest.inverse.inverse == manifest)
        #expect(manifest.inverse.actions.first?.src?.hasSuffix("/Application") == true,
                "the inverse renames the new name back to the old one")
    }

    // MARK: - The flagship proof: merges, keep, collision

    /// §5.4's second proof, on the flagship family's own names: converging 2013 onto the 2016
    /// vocabulary needs a merge (two sources onto `Forms`), `keep` lists what the target has no
    /// slot for, and a seeded name collision surfaces as a counted ledger line, never a lost file.
    @Test func theFlagshipConvergenceCarriesMergesKeepsAndACountedCollision() throws {
        let family = "Finance/US/Income Tax"
        let tree = FakeTree(files: [
            family: [],
            "\(family)/2013": [],
            "\(family)/2013/Federal Tax": ["1040.pdf", "w2.pdf", "extension.pdf"],
            "\(family)/2013/Federal Tax/W-2": ["w2-employer.pdf"],
            "\(family)/2013/State Tax (California)": ["ca-540.pdf"],
            "\(family)/2013/State Tax (California)/Refund": ["refund-check.pdf"],
            "\(family)/2013/Transcripts": ["transcript.pdf"],
            "\(family)/2016": [],
            "\(family)/2016/Payment": ["receipt.pdf"],
            "\(family)/2016/Payments": ["receipt.pdf", "invoice.pdf"],
        ])
        let mapping = RestructureMapping(rows: [
            .init(source: "Federal Tax", target: "Forms"),
            .init(source: "State Tax (California)", target: "Forms"),
            .init(source: "Payment", target: "Payments"),
            .init(source: "Transcripts", target: nil),
        ])
        let manifest = try Self.derive(family: family, members: ["2013", "2016"],
                                       mapping: mapping, in: tree.view)

        // 2013: Forms is absent, so the source with the most files is renamed — the fewest moves
        // that reach the shape — and the other merges into it, files then subfolders.
        let renames = manifest.actions.filter { $0.action == .renameDir }
        #expect(renames.map(\.src) == ["\(family)/2013/Federal Tax"])
        #expect(renames.first?.dst == "\(family)/2013/Forms")
        #expect(renames.first?.filesCarried == 3)
        #expect(manifest.actions.contains {
            $0.action == .moveFile
                && $0.src == "\(family)/2013/State Tax (California)/ca-540.pdf"
                && $0.dst == "\(family)/2013/Forms/ca-540.pdf"
        })
        #expect(manifest.actions.contains {
            $0.action == .moveDir && $0.src == "\(family)/2013/State Tax (California)/Refund"
        }, "a subfolder the target lacks is carried whole, never nested")
        #expect(!manifest.actions.contains {
            $0.action == .moveDir && $0.src == "\(family)/2013/State Tax (California)"
        }, "never a move-dir of the source ONTO the target — that nests it")

        // 2016: Payments already stands, so Payment merges into it — and its receipt.pdf is
        // already there, which is the seeded collision, predicted on the action.
        let collided = manifest.actions.filter { $0.collisionExpected == true }
        #expect(collided.map(\.src) == ["\(family)/2016/Payment/receipt.pdf"])

        // Keep is listed per member that carries the name (invariant 4).
        let keeps = manifest.actions.filter { $0.action == .keep }
        #expect(keeps.map(\.src) == ["\(family)/2013/Transcripts"])

        // The ledger is derived, never pasted — and the collision is a counted line.
        let ledger = RestructureLedger(of: manifest)
        #expect(ledger.foldersRenamed == 1)
        #expect(ledger.filesCarried == 3)
        // ca-540.pdf out of State Tax (California), receipt.pdf out of Payment — the Refund
        // subfolder rides a move-dir, which is not a file move.
        #expect(ledger.filesMoved == 2)
        #expect(ledger.collisionsKept == 1)
        #expect(ledger.kept == 1)
        #expect(ledger.summary.contains("1 name collision, both kept"))
        // The emptied sources: State Tax (California) and Payment — the merge drains both.
        #expect(ledger.foldersEmptied == 2)

        // The mapping rides in the manifest header, so the exported file is auditable against
        // its own rows.
        #expect(manifest.mapping == mapping.rows)

        // And the whole thing round-trips its Codable, wire vocabulary intact.
        let data = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(RestructureManifest.self, from: data) == manifest)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("move-file") && json.contains("collisionExpected"))
    }

    /// An applied collision's inverse restores the file's ORIGINAL name — `collidedInto` is its
    /// own fact on the action precisely so the inverse can read it (§5.4).
    @Test func aCollidedMovesInverseRestoresTheOriginalName() {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m1", createdAt: "t", family: "F", kind: .shape,
            actions: [.init(action: .moveFile, src: "F/A/receipt.pdf", dst: "F/B/receipt.pdf",
                            collidedInto: "F/B/receipt 2.pdf")])
        let inverse = manifest.inverse
        #expect(inverse.actions.first?.src == "F/B/receipt 2.pdf",
                "the file IS at the collision-renamed path — that is what moves back")
        #expect(inverse.actions.first?.dst == "F/A/receipt.pdf")
        #expect(inverse.actions.first?.collidedInto == nil,
                "the round trip restores the tree, not the bookkeeping")
    }

    // MARK: - Ordering

    /// A folder is vacated before its name is filled: `Forms → Tax Records` must run before
    /// `Federal Tax → Forms` (§5.4's own example).
    @Test func aFolderIsVacatedBeforeItsNameIsFilled() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/Forms": ["a.pdf"],
            "F/2016/Federal Tax": ["b.pdf", "c.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "Forms", target: "Tax Records"),
                .init(source: "Federal Tax", target: "Forms"),
            ]), in: tree.view)
        #expect(manifest.actions.map(\.dst) == ["F/2016/Tax Records", "F/2016/Forms"])
        #expect(manifest.actions.map(\.action) == [.renameDir, .renameDir])
    }

    /// A two-way swap goes through a temporary name — three renames, and the manifest still
    /// inverts to something that runs.
    @Test func aTwoWaySwapGoesThroughATemporaryName() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/Application": ["a.pdf"],
            "F/2016/Petition": ["b.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "Application", target: "Petition"),
                .init(source: "Petition", target: "Application"),
            ]), in: tree.view)
        let ops = manifest.actions.filter { $0.action == .renameDir }
        #expect(ops.count == 3, "a swap is three renames, not an impossible two")
        let first = try #require(ops.first)
        let last = try #require(ops.last)
        #expect(first.dst?.contains(".restructure-swap") == true)
        #expect(last.src == first.dst, "the set-aside folder takes the vacated name at the end")
        // Every intermediate dst is either the temp or a name the previous step vacated.
        #expect(ops[1].dst == first.src)
        #expect(manifest.inverse.inverse == manifest)
    }

    /// A case-only rename stays ONE `rename-dir` — apply's `safeMoveItem` owns the two-step for
    /// case-insensitive volumes; the manifest does not pre-chew it (§5.4).
    @Test func aCaseOnlyRenameIsOneAction() throws {
        let tree = FakeTree(files: ["F": [], "F/2016": [], "F/2016/forms": ["a.pdf"]])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [.init(source: "forms", target: "Forms")]),
            in: tree.view)
        #expect(manifest.actions.map(\.action) == [.renameDir])
        #expect(manifest.actions.first?.src == "F/2016/forms")
        #expect(manifest.actions.first?.dst == "F/2016/Forms")
    }

    /// N sources onto one absent target: the one with the most files is renamed — atomic, carries
    /// everything — and the rest are merged into the result.
    @Test func theBiggestSourceIsRenamedAndTheRestMergeIntoIt() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/Small": ["a.pdf"],
            "F/2016/Big": ["b.pdf", "c.pdf", "d.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "Small", target: "Merged"),
                .init(source: "Big", target: "Merged"),
            ]), in: tree.view)
        let rename = try #require(manifest.actions.first { $0.action == .renameDir })
        #expect(rename.src == "F/2016/Big")
        #expect(rename.filesCarried == 3)
        #expect(manifest.actions.filter { $0.action == .moveFile }.map(\.src)
                == ["F/2016/Small/a.pdf"])
    }

    /// The chosen rename comes FIRST in its group regardless of how the sources sort — it is the
    /// action that CREATES the target directory, and the first spelling walked sources in sorted
    /// order, so `Apple`'s merge was emitted before `Zebra`'s rename and every merged file
    /// failed at apply against a parent that did not exist yet. (The test above could not see it:
    /// `Big` happens to sort before `Small`.)
    @Test func theRenamePrecedesItsGroupsMergesWhateverTheSortSays() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/Apple": ["a.pdf"],
            "F/2016/Zebra": ["b.pdf", "c.pdf", "d.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "Apple", target: "Merged"),
                .init(source: "Zebra", target: "Merged"),
            ]), in: tree.view)
        let operational = manifest.actions.filter { $0.action != .keep }
        #expect(operational.first?.action == .renameDir)
        #expect(operational.first?.src == "F/2016/Zebra")
        let renameIndex = try #require(manifest.actions.firstIndex {
            $0.action == .renameDir })
        let firstMerge = try #require(manifest.actions.firstIndex { $0.action == .moveFile })
        #expect(renameIndex < firstMerge,
                "every merge writes into the directory the rename creates")
    }

    /// A target occupied by a sibling differing only by case, which the mapping does NOT step
    /// up, refuses at derivation — on the case-insensitive volumes this app targets the rename
    /// could never land, and the first spelling derived it anyway, minting a reviewed plan whose
    /// apply skipped with the false sentence "appeared since the plan".
    @Test func aTargetTakenByAKeptCaseTwinRefuses() {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/Files": ["a.pdf"],
            "F/2016/forms": ["b.pdf"],
        ])
        let result = RestructurePlanner.manifest(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "Files", target: "Forms"),
                .init(source: "forms"),
            ]), kind: .shape, in: tree.view,
            profileId: "p", manifestId: "m", createdAt: "t")
        guard case .failure(.targetTakenByCase(let target, let standing, let member)) = result
        else {
            Issue.record("expected targetTakenByCase, got \(result)")
            return
        }
        #expect(target == "Forms")
        #expect(standing == "forms")
        #expect(member == "2016")
    }

    /// When a case twin of the target is one of the group's own sources, IT must be the rename —
    /// whatever the file counts say: while `forms/` stands the volume cannot create `Forms/`,
    /// and "merging" `forms` into `Forms` would move its files onto themselves.
    @Test func aCaseTwinSourceIsAlwaysTheChosenRename() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/forms": ["a.pdf"],
            "F/2016/Files": ["b.pdf", "c.pdf", "d.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "forms", target: "Forms"),
                .init(source: "Files", target: "Forms"),
            ]), in: tree.view)
        let rename = try #require(manifest.actions.first { $0.action == .renameDir })
        #expect(rename.src == "F/2016/forms",
                "the case-step wins the rename over the bigger source")
        #expect(rename.dst == "F/2016/Forms")
        #expect(manifest.actions.filter { $0.action == .moveFile }.map(\.src)
                == ["F/2016/Files/b.pdf", "F/2016/Files/c.pdf", "F/2016/Files/d.pdf"])
    }

    /// Drain before fill, the MERGE half of the ordering rule: a standing folder that is both a
    /// merge source (its files leave for T) and a merge target (X's files arrive) must be
    /// drained first — its outbound moves were listed at plan time, and files arriving first
    /// would trip the apply's unlisted-veto on the very folder the plan is emptying. Plain
    /// target-name sort ran the fill first whenever the filled name sorted before the drain's
    /// target.
    @Test func aFolderDrainedByOneGroupIsDrainedBeforeAnotherFillsIt() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/Slips": ["s.pdf"],
            "F/2016/Trove": ["t.pdf"],
            "F/2016/Extra": ["x.pdf"],
        ])
        // Slips → Trove (fill of Trove... no: drain of Slips into standing Trove) and
        // Extra → Slips (fill of standing Slips) — Slips must be drained before Extra arrives.
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "Slips", target: "Trove"),
                .init(source: "Extra", target: "Slips"),
            ]), in: tree.view)
        let moves = manifest.actions.filter { $0.action == .moveFile }.map(\.src)
        #expect(moves == ["F/2016/Slips/s.pdf", "F/2016/Extra/x.pdf"],
                "Slips drains before Extra fills it")
    }


    /// A same-named subfolder on both sides merges one level down; two levels down it is `keep`
    /// and reported rather than guessed at (§5.4's collision policy for subfolders).
    @Test func sameNamedSubfoldersMergeOneLevelDownThenKeep() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/Payment": ["p.pdf"],
            "F/2016/Payment/Receipts": ["r1.pdf"],
            "F/2016/Payment/Receipts/2016": ["deep.pdf"],
            "F/2016/Payments": [],
            "F/2016/Payments/Receipts": ["r2.pdf"],
            "F/2016/Payments/Receipts/2016": [],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [.init(source: "Payment", target: "Payments")]),
            in: tree.view)
        #expect(manifest.actions.contains {
            $0.action == .moveFile && $0.src == "F/2016/Payment/Receipts/r1.pdf"
                && $0.dst == "F/2016/Payments/Receipts/r1.pdf"
        }, "one level down, the same rules")
        #expect(manifest.actions.contains {
            $0.action == .keep && $0.src == "F/2016/Payment/Receipts/2016"
        }, "two levels down is kept and reported")
    }

    // MARK: - Refusals

    /// The refusals are sentences for the sheet, and each fires for exactly its own reason.
    @Test func theThreeRefusalsFireForTheirOwnReasons() {
        let tree = FakeTree(files: ["F": [], "F/2016": [], "F/2016/A": ["a.pdf"]])
        // All keep, or mapped to itself: nothing would land.
        for mapping in [
            RestructureMapping(rows: [.init(source: "A", target: nil)]),
            RestructureMapping(rows: [.init(source: "A", target: "A")]),
        ] {
            let result = RestructurePlanner.manifest(
                family: "F", members: ["2016"], mapping: mapping, kind: .shape, in: tree.view,
                profileId: "p", manifestId: "m", createdAt: "t")
            #expect(throws: RestructurePlanner.PlanRefusal.nothingMapped) { try result.get() }
        }
        // A mapping whose sources exist nowhere in the members is the same nothing.
        let phantom = RestructurePlanner.manifest(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [.init(source: "Ghost", target: "B")]),
            kind: .shape, in: tree.view, profileId: "p", manifestId: "m", createdAt: "t")
        #expect(throws: RestructurePlanner.PlanRefusal.nothingMapped) { try phantom.get() }

        // A merge the view cannot expand refuses rather than guessing — a profile knows counts,
        // not file names.
        let profile = FolderProfile(
            profileId: "p", root: "/tmp/x",
            folders: [
                "F/2016": FolderProfileEntry(path: "F/2016", role: nil, naming: nil, anchors: [],
                                             acceptsNewFiles: nil, fileCount: 0,
                                             subfolderCount: 2, axes: [:]),
                "F/2016/A": FolderProfileEntry(path: "F/2016/A", role: nil, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 2,
                                               subfolderCount: 0, axes: [:]),
                "F/2016/B": FolderProfileEntry(path: "F/2016/B", role: nil, naming: nil,
                                               anchors: [], acceptsNewFiles: nil, fileCount: 1,
                                               subfolderCount: 0, axes: [:]),
            ],
            personTokens: [])
        let blind = RestructurePlanner.manifest(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [.init(source: "A", target: "B")]),
            kind: .shape, in: .fromProfile(profile),
            profileId: "p", manifestId: "m", createdAt: "t")
        #expect(throws: RestructurePlanner.PlanRefusal.unknownFiles(source: "F/2016/A")) {
            try blind.get()
        }

        // Two distinct targets differing only by case cannot coexist on a case-insensitive
        // volume — refused up front, before any member derives toward them.
        let cased = RestructurePlanner.manifest(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "A", target: "Forms"),
                .init(source: "B", target: "forms"),
            ]),
            kind: .shape, in: tree.view, profileId: "p", manifestId: "m", createdAt: "t")
        #expect(throws: RestructurePlanner.PlanRefusal.conflictingTargets("Forms", "forms")) {
            try cased.get()
        }
    }

    /// The removal step's scope: the folders a manifest's moves drained, shallowest only — a
    /// one-level-down merge's `s/d` is inside the drained `s`, and counting both would offer the
    /// removal sheet a folder inside a folder it is also offering.
    @Test func emptiedFoldersAreTheShallowestDrainedSources() {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shape,
            actions: [
                .init(action: .renameDir, src: "F/Big", dst: "F/Merged"),
                .init(action: .moveFile, src: "F/Small/a.pdf", dst: "F/Merged/a.pdf"),
                .init(action: .moveFile, src: "F/Small/Sub/b.pdf", dst: "F/Merged/Sub/b.pdf"),
                .init(action: .moveDir, src: "F/Other/Refund", dst: "F/Merged/Refund"),
            ])
        #expect(RestructureLedger.emptiedFolders(of: manifest) == ["F/Other", "F/Small"],
                "shallowest only, sorted; a rename drains nothing — it carries")
    }

    // MARK: - Parallel families (§5.4 step 2's pointer)

    /// The 6 Aug case itself: H-4's mapping vocabulary is shared by H-1B, and the sheet must say
    /// so — fixing one family alone leaves the parallel one disagreeing. At the default bar of
    /// three shared names, H-4 EAD and I-140 (two names each, `Application`/`Approval` and
    /// `Petition`/`Approval`) sit BELOW it deliberately: two generic role names recur correctly
    /// all over a filed tree, and a pointer that fires everywhere is one nobody reads. The bar is
    /// a first guess to revisit with real use, which is why it is a parameter.
    @Test func parallelFamiliesNamesTheSiblingSharingTheVocabulary() throws {
        let url = try #require(Bundle.module.url(forResource: "restructure-immigration-oracle",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])
        let profile = try JSONDecoder().decode(FolderProfile.self, from:
            JSONSerialization.data(withJSONObject: try #require(object["profile"])))
        let view = RestructureTreeView.fromProfile(profile)

        let parallels = RestructurePlanner.parallelFamilies(
            of: "Immigration/Authorization/H-4", in: view)
        #expect(parallels == ["H-1B"])
        #expect(!parallels.contains("Form I-9"), "no shared vocabulary at all")
        // Lowering the bar admits the two-name overlaps — the tunable the doc promises.
        let loose = RestructurePlanner.parallelFamilies(
            of: "Immigration/Authorization/H-4", in: view, minimumShared: 2)
        #expect(loose.contains("H-4 EAD") && loose.contains("H-1B"))
    }

    // MARK: - The editor's row list

    /// One row per distinct source name across every member — 24 on the flagship family's 17
    /// members, the number §5.4 sizes the editor by, pinned against the in-repo fixture.
    @Test func theFlagshipFamilyHasTwentyFourDistinctChildNames() throws {
        let url = try #require(Bundle.module.url(forResource: "restructure-flagship",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let profile = try JSONDecoder().decode(FolderProfile.self,
                                               from: Data(contentsOf: url))
        let view = RestructureTreeView.fromProfile(profile)
        let family = "Finance/US/Income Tax"
        let members = try #require(view.childFolders(family))
        #expect(members.count == 17)
        let sources = RestructurePlanner.distinctSources(family: family, members: members,
                                                         in: view)
        #expect(sources.count == 24)
        // The near-duplicates a dropdown alone cannot resolve are both real rows.
        #expect(sources.contains("Payment") && sources.contains("Payments"))
        #expect(sources.contains("Forms") && sources.contains("Tax Returns"))
    }

    // MARK: - The target as the plan itself fills it

    /// A merge source's derivation must see what the group's own earlier actions put at the
    /// target. Here the target is CREATED by the chosen rename, whose payload includes a
    /// `Receipts/` subfolder and a `same.pdf` — plan-time reads of the absent target saw
    /// neither, so the plan emitted a whole-folder `move-dir` for the sibling's `Receipts/`
    /// (which could only skip at apply as "appeared since the plan") and promised `same.pdf`
    /// collision-free.
    @Test func aRenameCreatedTargetsPayloadCountsAsLanded() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/2023": ["same.pdf", "only-2023.pdf"],
            "F/2016/2023/Receipts": ["r1.pdf"],
            "F/2016/2024": ["same.pdf"],
            "F/2016/2024/Receipts": ["r2.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "2023", target: "Archive"),
                .init(source: "2024", target: "Archive"),
            ]), in: tree.view)
        // 2023 (more files) is the chosen rename; 2024 merges into what it lands.
        #expect(manifest.actions.first?.action == .renameDir)
        #expect(manifest.actions.first?.src == "F/2016/2023")
        #expect(!manifest.actions.contains {
            $0.action == .moveDir && $0.src == "F/2016/2024/Receipts"
        }, "the rename already landed a Receipts/ — carrying the sibling's whole would skip")
        #expect(manifest.actions.contains {
            $0.action == .moveFile && $0.src == "F/2016/2024/Receipts/r2.pdf"
                && $0.dst == "F/2016/Archive/Receipts/r2.pdf"
        }, "the occupied subfolder merges one level down instead")
        let same = manifest.actions.first { $0.src == "F/2016/2024/same.pdf" }
        #expect(same?.collisionExpected == true,
                "the rename's payload holds a same.pdf — the collision is predictable NOW")
    }

    /// Two merge sources sharing a subfolder name the standing target lacks: the first carries
    /// it whole, and the SECOND must merge into what the first landed — a second `move-dir` to
    /// the same destination could only skip at apply.
    @Test func twoSourcesSharingASubfolderLandOnceThenMergeInto() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/Keep": ["k.pdf"],
            "F/2016/Alpha": [],
            "F/2016/Alpha/Receipts": ["a.pdf"],
            "F/2016/Beta": [],
            "F/2016/Beta/Receipts": ["b.pdf", "a.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "Alpha", target: "Keep"),
                .init(source: "Beta", target: "Keep"),
            ]), in: tree.view)
        let wholeCarries = manifest.actions.filter {
            $0.action == .moveDir && $0.dst == "F/2016/Keep/Receipts"
        }
        #expect(wholeCarries.count == 1, "the name is occupied after the first landing")
        #expect(wholeCarries.first?.src == "F/2016/Alpha/Receipts")
        #expect(manifest.actions.contains {
            $0.action == .moveFile && $0.src == "F/2016/Beta/Receipts/b.pdf"
                && $0.dst == "F/2016/Keep/Receipts/b.pdf"
        })
        let collided = manifest.actions.first { $0.src == "F/2016/Beta/Receipts/a.pdf" }
        #expect(collided?.collisionExpected == true,
                "Alpha's landing already put an a.pdf there — the second source sees it")
    }

    /// A mapping that lists one source twice is refused, never trapped on —
    /// `Dictionary(uniqueKeysWithValues:)` used to fatalError here, and `RestructureMapping`
    /// is public input that nothing forces to be unique.
    @Test func aDuplicateMappingRowRefusesInsteadOfTrapping() {
        let tree = FakeTree(files: ["F": [], "F/2016": [], "F/2016/A": ["a.pdf"]])
        let result = RestructurePlanner.manifest(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "A", target: "X"),
                .init(source: "A", target: "Y"),
            ]), kind: .shape, in: tree.view,
            profileId: "p", manifestId: "m1", createdAt: "2026-08-28T00:00:00")
        #expect(throws: RestructurePlanner.PlanRefusal.duplicateMappingRows(source: "A")) {
            try result.get()
        }
    }

    /// A standing target that an EARLIER group drains must be read as the drain left it, not
    /// as the plan-time disk: `X → T1` empties `X`, so `A → X` merges into an empty folder —
    /// no false collisions against files that just left, and a subfolder `X` carried whole to
    /// `T1` no longer occupies its name, so `A`'s same-named subfolder lands whole.
    @Test func aDrainedStandingTargetIsReadAsTheDrainLeftIt() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/T1": [],
            "F/2016/X": ["shared.pdf"],
            "F/2016/X/S": ["s1.pdf"],
            "F/2016/A": ["shared.pdf"],
            "F/2016/A/S": ["s2.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "X", target: "T1"),
                .init(source: "A", target: "X"),
            ]), in: tree.view)
        let aShared = manifest.actions.first { $0.src == "F/2016/A/shared.pdf" }
        #expect(aShared?.collisionExpected == nil,
                "X's shared.pdf left for T1 before A arrived — predicting a collision is false")
        #expect(manifest.actions.contains {
            $0.action == .moveDir && $0.src == "F/2016/A/S" && $0.dst == "F/2016/X/S"
        }, "X/S was carried whole to T1/S, so A/S lands whole — a one-level merge into a gone folder could only skip")
    }

    /// The half of the drain that LEAVES something: a subfolder merged one level down (because
    /// the drain's own target already had it) leaves its SHELL at the source, which still
    /// occupies its name — a later arrival with the same name merges into the shell, against
    /// its post-drain (empty) contents.
    @Test func aMergedAwaySubfoldersShellStillOccupiesItsName() throws {
        let tree = FakeTree(files: [
            "F": [], "F/2016": [],
            "F/2016/T1": [],
            "F/2016/T1/S": ["t1s.pdf"],
            "F/2016/X": [],
            "F/2016/X/S": ["s1.pdf"],
            "F/2016/A": [],
            "F/2016/A/S": ["s1.pdf", "s3.pdf"],
        ])
        let manifest = try Self.derive(
            family: "F", members: ["2016"],
            mapping: RestructureMapping(rows: [
                .init(source: "X", target: "T1"),
                .init(source: "A", target: "X"),
            ]), in: tree.view)
        // X/S merged into T1/S (T1 already had one), so X/S remains as a SHELL: A/S must not
        // be carried whole onto it, and its files merge against the shell's EMPTY contents —
        // X/S's own s1.pdf left for T1/S, so A's s1.pdf is no collision.
        #expect(!manifest.actions.contains {
            $0.action == .moveDir && $0.src == "F/2016/A/S"
        }, "the shell occupies the name — a whole-carry onto it could only skip at apply")
        let aS1 = manifest.actions.first { $0.src == "F/2016/A/S/s1.pdf" }
        #expect(aS1?.dst == "F/2016/X/S/s1.pdf")
        #expect(aS1?.collisionExpected == nil,
                "the shell is empty — its s1.pdf left with the drain")
    }

    /// `memoized()` reads each listing once, however often the derivation re-asks — the plan
    /// sheet re-derives per keystroke, and a disk-backed view re-listed every directory each
    /// time.
    @Test func aMemoizedViewReadsEachListingOnce() {
        var reads = 0
        let counting = RestructureTreeView(
            childFolders: { _ in reads += 1; return [] },
            files: { _ in reads += 1; return ["f.pdf"] },
            fileCount: { _ in reads += 1; return 1 })
        let memo = counting.memoized()
        _ = memo.files("a"); _ = memo.files("a"); _ = memo.files("a")
        _ = memo.childFolders("a"); _ = memo.childFolders("a")
        _ = memo.fileCount("a"); _ = memo.fileCount("a")
        #expect(reads == 3, "one read per closure per path, not per call")
    }
}
