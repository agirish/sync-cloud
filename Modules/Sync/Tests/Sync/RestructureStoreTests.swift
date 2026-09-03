import Testing
import Foundation
@testable import Sync

/// The `kind × subject` identity every Restructure section keys on (ROADMAP_V5 §5.0).
///
/// The kind went into `StructureFinding.id` before the second detector landed, because
/// `RestructureLens` renders one `ForEach(findings)` and the second kind to fire on a family
/// would have collided with the first. The subject — not the family — is the other half, because
/// one family can hold two findings of the *same* kind about different children.
@Suite struct RestructureIdentityTests {

    @Test func theIdCarriesTheKindSoTwoKindsOnOneFamilyDoNotCollide() {
        let shape = StructureFinding(kind: .shape, family: "Finance/US/Income Tax", schemes: [])
        let series = StructureFinding(kind: .backlog, family: "Finance/US/Income Tax",
                                      subject: "Finance/US/Income Tax/2025", schemes: [])
        #expect(shape.id != series.id)
        #expect(shape.id == "shape|Finance/US/Income Tax")
    }

    @Test func theSubjectSeparatesTwoFindingsOfOneKindInOneFamily() {
        // Echo-name can fire twice in one family, on two different sibling pairs — the case that
        // made kind × family insufficient as an identity.
        let first = StructureFinding(kind: .echoName, family: "Forms",
                                     subject: "Forms/Form W2", schemes: [])
        let second = StructureFinding(kind: .echoName, family: "Forms",
                                      subject: "Forms/1099 INT", schemes: [])
        #expect(first.id != second.id)
    }

    @Test func theSubjectDefaultsToTheFamilyWhichIsWhatShapeMeans() {
        let finding = StructureFinding(family: "Finance/US/Income Tax", schemes: [])
        #expect(finding.kind == .shape)
        #expect(finding.subject == "Finance/US/Income Tax")
    }

    /// Raw values are a file format — `restructure.json` serialises them — so they are pinned
    /// here the way `GlassLevel`'s are: append-only, never renamed, never reused. A failure here
    /// is a failure to keep that promise, not a test to update.
    /// One spelling of the composite identity: a store key joined back to rendered findings must
    /// produce exactly ``StructureFinding/id``, or the two drift apart in silence.
    @Test func aKeysFindingIdMatchesTheFindingsOwnId() {
        let finding = StructureFinding(kind: .echoName, family: "Home",
                                       subject: "Home/ATT Bill",
                                       detail: .echoName(counterpart: "Home/ATT",
                                                         relation: .sibling))
        #expect(RestructureKey(finding).findingId == finding.id)
    }

    @Test func theRawValuesAreAFileFormatAndStayPinned() {
        let pinned: [FindingKind: String] = [
            .shape: "shape", .backlog: "backlog", .shadowAxis: "shadowAxis",
            .echoName: "echoName", .mirroredInbox: "mirroredInbox", .deadWeight: "deadWeight",
            .looseAboveSeries: "looseAboveSeries", .looseBesideContainer: "looseBesideContainer",
            .duplicatedTaxonomy: "duplicatedTaxonomy", .ask: "ask",
        ]
        #expect(FindingKind.allCases.count == pinned.count)
        for (kind, raw) in pinned { #expect(kind.rawValue == raw) }
    }

    /// The rail badge counts only plan-bearing kinds (§5.1): `ask` is the stated exclusion,
    /// `deadWeight` renders as the crowding strip rather than as cards, and `looseAboveSeries`
    /// hands its per-file fix to To File rather than growing an Apply.
    @Test func onlyThePlanBearingKindsCountTowardTheBadge() {
        let planless: Set<FindingKind> = [.ask, .deadWeight, .looseAboveSeries]
        for kind in FindingKind.allCases {
            #expect(kind.carriesPlan == !planless.contains(kind),
                    "\(kind.rawValue) has the wrong badge behaviour")
        }
    }
}

/// `restructure.json` — the one app-owned file for everything Restructure remembers.
///
/// Each proof here is §5.0's, verbatim: a round-trip per section, a suppression that outlives the
/// profile that was active when it was made, and a manifest rename that re-keys every section that
/// named the old path while leaving a sibling that merely shares a name prefix alone.
@MainActor
@Suite final class RestructureStoreTests {

    // A class suite so `deinit` can sweep what each test created — the struct version leaked
    // one fixture directory per test per run into the temp dir, standing debris on the
    // self-hosted runner. Swift Testing instantiates one suite per test, so the sweep runs
    // right after each test finishes.
    private var scratch: [URL] = []
    deinit { for dir in scratch { try? FileManager.default.removeItem(at: dir) } }

    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restructure-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        scratch.append(dir)
        return dir
    }

    private func fileBytes(_ dir: URL) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent("p/restructure.json"))
    }

    // MARK: Round trips

    @Test func aSuppressionRoundTripsThroughTheFile() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .shape, path: "Finance/US/Income Tax")
        RestructureStore(directory: dir, profileId: "p").suppress(key)

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.isSuppressed(key))
        #expect(!reread.isSuppressed(RestructureKey(kind: .backlog,
                                                    path: "Finance/US/Income Tax")))
    }

    @Test func anAnswerRoundTripsThroughTheFile() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .ask, path: "Health/Kaiser - PG&E")
        RestructureStore(directory: dir, profileId: "p").recordAnswer("coverage", for: key)

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.answer(for: key) == "coverage")
    }

    @Test func removingAnAnswerRemovesItFromTheFileToo() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .ask, path: "Health/Kaiser - PG&E")
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordAnswer("coverage", for: key)
        store.removeAnswer(for: key)

        #expect(RestructureStore(directory: dir, profileId: "p").answer(for: key) == nil)
    }

    /// §5.0: "a suppressed finding stays suppressed after the profile is swapped for a derived
    /// one." The store's keys are paths, not profile ids — so a finding regenerated from a
    /// *different* profile object still matches, as long as it is about the same place.
    @Test func aSuppressionSurvivesTheProfileBeingReplacedUnderneathIt() throws {
        let dir = try makeDirectory()
        let fromHandBuilt = StructureFinding(kind: .shape, family: "Finance/US/Income Tax",
                                             schemes: [])
        RestructureStore(directory: dir, profileId: "p").suppress(RestructureKey(fromHandBuilt))

        // The same family, found again in a freshly derived profile: a different FolderProfile,
        // a different StructureFinding instance, the same identity.
        let fromDerived = StructureFinding(kind: .shape, family: "Finance/US/Income Tax",
                                           schemes: [StructureFinding.Scheme(
                                               vocabulary: ["forms"], members: ["2016", "2017"])])
        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.isSuppressed(RestructureKey(fromDerived)))
    }

    // MARK: Replay

    @Test func aRenameRekeysTheKeyItNamesAndEverySectionCarriesIt() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .echoName, path: "Home/ATT Bill"))
        store.recordAnswer("keep", for: RestructureKey(kind: .ask, path: "Home/ATT Bill"))

        store.rekey(renames: [(from: "Home/ATT Bill", to: "Home/ATT")])

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.isSuppressed(RestructureKey(kind: .echoName, path: "Home/ATT")))
        #expect(!reread.isSuppressed(RestructureKey(kind: .echoName, path: "Home/ATT Bill")))
        #expect(reread.answer(for: RestructureKey(kind: .ask, path: "Home/ATT")) == "keep")
    }

    /// The nudge section round-trips, and — the point of it being a **year** rather than a flag —
    /// re-acknowledging under a new year replaces the old value rather than accumulating.
    @Test func aNudgeAcknowledgementRoundTripsAndCarriesItsYear() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .backlog, path: "Health/Dental/2026")
        let store = RestructureStore(directory: dir, profileId: "p")
        store.acknowledgeNudge(key, year: "2026")

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.nudgesAcknowledged[key] == "2026")
        #expect(reread.nudgesAcknowledged.count == 1)

        reread.acknowledgeNudge(key, year: "2027")
        let third = RestructureStore(directory: dir, profileId: "p")
        #expect(third.nudgesAcknowledged[key] == "2027", "the newer year replaces the older")
        #expect(third.nudgesAcknowledged.count == 1)
    }

    /// A store written before this section existed decodes with it absent — the tolerant-decoder
    /// rule every section here follows, and the reason the fifth one needed no migration.
    @Test func aStoreWithNoNudgeSectionDecodesWithoutOne() throws {
        let dir = try makeDirectory()
        let before = RestructureStore(directory: dir, profileId: "p")
        before.suppress(RestructureKey(kind: .shape, path: "Finance"))
        // Strip the section the way a v5.0 file would not have had it at all.
        var object = try #require(try JSONSerialization.jsonObject(with: fileBytes(dir))
                                    as? [String: Any])
        #expect(object["nudgesAcknowledged"] != nil, "a positive control: this build writes it")
        object["nudgesAcknowledged"] = nil
        try JSONSerialization.data(withJSONObject: object)
            .write(to: dir.appendingPathComponent("p/restructure.json"))

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(!reread.isUnreadable, "an absent section is absent, not unreadable")
        #expect(reread.nudgesAcknowledged.isEmpty)
        #expect(reread.isSuppressed(RestructureKey(kind: .shape, path: "Finance")))
    }

    // MARK: The trend (proposal O16)

    /// **One point per profile.** The findings are a pure function of the profile, so two stamps
    /// under one id are the same survey counted twice — which would flatten the line's shape by
    /// however often the memo happened to drop, and the memo's churn rate is not a fact about
    /// the tree.
    @Test func theTrendRecordsOnePointPerProfile() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        func point(_ id: String, _ total: Int, landing: Bool = false)
            -> RestructureStore.TrendPoint {
            .init(at: "2026-08-28T09:00:00", profileId: id, countsByKind: ["shape": total],
                  landing: landing)
        }
        store.recordTrend(point("a", 33))
        store.recordTrend(point("a", 33))
        store.recordTrend(point("b", 19))
        #expect(store.trend.map(\.total) == [33, 19])

        // A landing stamp REPLACES an ordinary one for the same profile: "this survey came from
        // a landing" is the more informative of the two claims, and a re-derive stamps before
        // anything downstream knows a manifest caused it.
        store.recordTrend(point("b", 19, landing: true))
        #expect(store.trend.count == 2)
        #expect(store.trend.last?.landing == true)
        // …and not back again.
        store.recordTrend(point("b", 19))
        #expect(store.trend.last?.landing == true)
    }

    /// It round-trips, and stays inside its cap oldest-first — the file is read whole at
    /// construction, so unbounded history would make every launch pay for it.
    @Test func theTrendRoundTripsAndStaysUnderItsCap() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        for index in 0..<(RestructureStore.trendCap + 5) {
            store.recordTrend(.init(at: "t\(index)", profileId: "p\(index)",
                                    countsByKind: ["shape": index], landing: index % 50 == 0))
        }
        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.trend.count == RestructureStore.trendCap)
        #expect(reread.trend.first?.total == 5, "the oldest five were dropped")
        #expect(reread.trend.last?.total == RestructureStore.trendCap + 4)
        #expect(reread.trend.contains { $0.landing }, "landings survive the round trip")
    }

    /// A store written before the section existed decodes with it absent.
    @Test func aStoreWithNoTrendSectionDecodesWithoutOne() throws {
        let dir = try makeDirectory()
        let before = RestructureStore(directory: dir, profileId: "p")
        before.suppress(RestructureKey(kind: .shape, path: "Finance"))
        var object = try #require(try JSONSerialization.jsonObject(with: fileBytes(dir))
                                    as? [String: Any])
        #expect(object["trend"] != nil, "a positive control: this build writes it")
        object["trend"] = nil
        try JSONSerialization.data(withJSONObject: object)
            .write(to: dir.appendingPathComponent("p/restructure.json"))

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(!reread.isUnreadable)
        #expect(reread.trend.isEmpty)
    }

    /// A backlog subject IS a folder path, so a landing that renames it must move this key with
    /// the rest — otherwise the nudge re-fires for a year already dismissed, under the new name.
    @Test func aRenameRekeysANudgeAcknowledgement() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.acknowledgeNudge(RestructureKey(kind: .backlog, path: "Health/Dental/2026"),
                               year: "2026")

        store.rekey(renames: [(from: "Health/Dental", to: "Health/Dental Care")])

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.nudgesAcknowledged[
            RestructureKey(kind: .backlog, path: "Health/Dental Care/2026")] == "2026")
        #expect(reread.nudgesAcknowledged[
            RestructureKey(kind: .backlog, path: "Health/Dental/2026")] == nil)
    }

    @Test func aRenameRekeysDescendantsButNotASiblingSharingANamePrefix() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .shape, path: "Finance/A/B/2016"))
        // The sibling trap: `A/BB` starts with the characters of `A/B` but is another folder.
        store.suppress(RestructureKey(kind: .shape, path: "Finance/A/BB"))

        store.rekey(renames: [(from: "Finance/A/B", to: "Finance/A/C")])

        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "Finance/A/C/2016")))
        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "Finance/A/BB")))
        #expect(!store.isSuppressed(RestructureKey(kind: .shape, path: "Finance/A/B/2016")))
    }

    @Test func renamesApplyInManifestOrderSoALaterOneSeesTheEarlierOnesProduct() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .shape, path: "Tax/Forms"))

        // §5.4's vacate-before-fill: Forms is vacated to Tax Records, then Federal fills Forms.
        // The suppression about the ORIGINAL Forms must follow the vacating rename and must not
        // be picked up by the fill.
        store.rekey(renames: [(from: "Tax/Forms", to: "Tax/Tax Records"),
                              (from: "Tax/Federal", to: "Tax/Forms")])

        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "Tax/Tax Records")))
        #expect(!store.isSuppressed(RestructureKey(kind: .shape, path: "Tax/Forms")))
    }

    // MARK: The file on disk

    @Test func anAbsentFileIsAFreshStoreAndTheFirstWriteCreatesIt() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(!store.isUnreadable)
        #expect(store.suppressed.isEmpty)

        store.suppress(RestructureKey(kind: .shape, path: "A"))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("p/restructure.json").path))
    }

    /// Absent, unreadable and newer-than-me are three different claims, and only absent is
    /// writable. A file that did not decode must keep its bytes through any mutation — a
    /// whole-file save of the empty fallback state would replace the real file with nothing.
    @Test func anUnreadableFileIsNeverWrittenOver() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/restructure.json")
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: url)

        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isUnreadable)
        store.suppress(RestructureKey(kind: .shape, path: "A"))

        #expect(try fileBytes(dir) == garbage)
        // The change still holds in memory for the session.
        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "A")))
    }

    @Test func aNewerSchemaIsReadButRefusedForWriting() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/restructure.json")
        let newer = """
            {
              "schemaVersion": 99,
              "suppressed": [ { "kind": "shape", "path": "Finance/US/Income Tax" } ],
              "sectionsANewerBuildWrote": { "whatever": true }
            }
            """
        try Data(newer.utf8).write(to: url)

        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isSuppressed(RestructureKey(kind: .shape, path: "Finance/US/Income Tax")))
        #expect(store.isUnreadable)

        let before = try fileBytes(dir)
        store.suppress(RestructureKey(kind: .backlog, path: "A"))
        #expect(try fileBytes(dir) == before)
    }

    /// A section this build does not model — hand-added, or written by a future schema this build
    /// happens to half-understand — must survive a save untouched. (`drafts` was this test's
    /// example while §5.4 was unbuilt; it is modelled now, so the foreign section here is one no
    /// planned schema claims.)
    @Test func sectionsThisBuildDoesNotModelSurviveASave() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/restructure.json")
        let withForeign = """
            {
              "schemaVersion": 1,
              "annotations": [ { "path": "Finance/US/Income Tax", "text": "revisit" } ],
              "_note": "hand-written, and load-bearing for this test"
            }
            """
        try Data(withForeign.utf8).write(to: url)

        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .shape, path: "A"))

        let object = try #require(try JSONSerialization.jsonObject(
            with: fileBytes(dir)) as? [String: Any])
        #expect(object["annotations"] != nil)
        #expect(object["_note"] as? String == "hand-written, and load-bearing for this test")
        #expect((object["suppressed"] as? [[String: Any]])?.count == 1)
    }

    /// A `drafts` section in a shape this build cannot decode is an UNREADABLE file, not an empty
    /// section: every save is whole-file, so writing would flatten what could not be read. Refusal
    /// is the same protection the syntax-error case gets.
    @Test func anUndecodableDraftsSectionRefusesWritesRatherThanFlattening() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/restructure.json")
        try Data("""
            {
              "schemaVersion": 1,
              "drafts": [ { "kind": "shape", "path": "F", "mapping": [] } ]
            }
            """.utf8).write(to: url)
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isUnreadable)
    }

    // MARK: Drafts (§5.4)

    private static func draftManifest(family: String = "Finance/US/Income Tax")
        -> RestructureManifest {
        RestructureManifest(
            profileId: "p", manifestId: "m1", createdAt: "2026-08-28T10:00:00",
            family: family, kind: .shape,
            mapping: [.init(source: "Federal Tax", target: "Forms")],
            actions: [.init(action: .renameDir, src: "\(family)/2013/Federal Tax",
                            dst: "\(family)/2013/Forms", filesCarried: 3)])
    }

    /// §5.7's *Planned, not applied*: the draft survives the sheet closing and the app quitting —
    /// mapping rows, actions and export mark all intact.
    @Test func aDraftRoundTripsThroughTheFileWhole() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .shape, path: "Finance/US/Income Tax")
        let record = RestructureStore.DraftRecord(
            manifest: Self.draftManifest(), savedAt: "2026-08-28T10:00:00",
            exportedTo: "restructure-2026-08-28-Finance-US-Income Tax.json",
            // The picker vocabulary, UNUSED names included — what lets a reopened draft offer
            // the same choices instead of only the targets its rows happen to use.
            vocabulary: ["Forms", "Payments", "Correspondence"])
        RestructureStore(directory: dir, profileId: "p").saveDraft(record, for: key)

        let reread = RestructureStore(directory: dir, profileId: "p")
        #expect(reread.draft(for: key) == record)
        #expect(reread.draft(for: key)?.vocabulary == ["Forms", "Payments", "Correspondence"])
        reread.removeDraft(for: key)
        #expect(RestructureStore(directory: dir, profileId: "p").draft(for: key) == nil)
    }

    /// A rename replays onto the draft's KEY — the section survives an Apply of another plan —
    /// while the manifest inside keeps the paths it was derived against: Apply re-validates a
    /// draft against the tree as it stands, and a stale path there is a card sentence, not a
    /// silent rewrite of a plan the user reviewed.
    @Test func aRenameRekeysADraftsKeyButNotItsManifest() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        let manifest = Self.draftManifest(family: "Home/ATT Bill")
        store.saveDraft(.init(manifest: manifest, savedAt: "t"),
                        for: RestructureKey(kind: .echoName, path: "Home/ATT Bill"))

        store.rekey(renames: [(from: "Home/ATT Bill", to: "Home/ATT")])

        let reread = RestructureStore(directory: dir, profileId: "p")
        let moved = try #require(reread.draft(for: RestructureKey(kind: .echoName,
                                                                  path: "Home/ATT")))
        #expect(reread.draft(for: RestructureKey(kind: .echoName, path: "Home/ATT Bill")) == nil)
        #expect(moved.manifest == manifest, "the reviewed plan's contents are not rewritten")
    }

    /// `Export plan…` writes the manifest beside the profile, named for its date and family with
    /// the path separators flattened — reviewable in a text editor with nothing at risk — and it
    /// writes even when the store itself is refusing: the refusal protects `restructure.json`,
    /// and this is a new file.
    @Test func exportWritesTheManifestBesideTheProfileEvenWhenTheStoreIsUnreadable() throws {
        let dir = try makeDirectory()
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("p/restructure.json"))
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isUnreadable)

        let name = try store.exportPlan(Self.draftManifest())

        #expect(name == "restructure-2026-08-28-Finance-US-Income Tax.json")
        let data = try Data(contentsOf: dir.appendingPathComponent("p/\(name)"))
        let decoded = try JSONDecoder().decode(RestructureManifest.self, from: data)
        #expect(decoded == Self.draftManifest())
        // The wire file is the log's vocabulary, and it carries the mapping it was derived from.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("rename-dir") && json.contains("\"mapping\""))
    }

    /// A root-level family has no name to put in the filename, and TWO unrelated plans can be
    /// root-level — a top-level pair and a scattered empties removal. Sharing one bucket meant
    /// the second export silently replaced the first, and the first draft's `exportedTo` then
    /// named a file holding a different plan.
    @Test func rootLevelPlansDoNotShareOneExportName() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        func manifest(family: String, kind: FindingKind) -> RestructureManifest {
            RestructureManifest(profileId: "p", manifestId: "m-\(kind.rawValue)",
                                createdAt: "2026-08-29T09:00:00", family: family, kind: kind,
                                actions: [.init(action: .keep, src: "x")])
        }
        let pair = try store.exportPlan(manifest(family: "", kind: .echoName))
        let removal = try store.exportPlan(manifest(family: ".", kind: .deadWeight))
        #expect(pair != removal, "one bucket meant the second overwrote the first")
        #expect(!pair.contains("--"), "an empty family left a bare dash in the name")
        #expect(!removal.contains("-..json"), "a dot family left a stray dot in the name")
        for name in [pair, removal] {
            #expect(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("p/\(name)").path))
        }
        // A shape plan's name is untouched by any of this — one shape finding per family, and
        // this is the spelling that shipped.
        #expect(try store.exportPlan(manifest(family: "Finance/US", kind: .shape))
                    == "restructure-2026-08-29-Finance-US.json")
    }

    /// **Date plus family stopped being unique when six kinds could export.** One parent carries
    /// two shadow-axis findings on the real tree, and both wrote one filename: the second
    /// replaced the first, and the first draft's `exportedTo` then named a different plan.
    @Test func twoFindingsUnderOneParentExportToTwoFiles() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        func shadowAxis(_ subject: String) -> RestructureManifest {
            RestructureManifest(
                profileId: "p", manifestId: "m-\(subject)", createdAt: "2026-08-29T09:00:00",
                family: "Finance/US/Income Tax", kind: .shadowAxis,
                actions: [.init(action: .renameDir,
                                src: "Finance/US/Income Tax/\(subject)",
                                dst: "Finance/US/Income Tax/2023")])
        }
        let first = try store.exportPlan(shadowAxis("IRS Docs - 2023"))
        let second = try store.exportPlan(shadowAxis("IRS Docs - 2024"))
        #expect(first != second)
        #expect(first.contains("IRS Docs - 2023"))
        #expect(second.contains("IRS Docs - 2024"))
        for name in [first, second] {
            #expect(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("p/\(name)").path),
                    "both plans survive — neither overwrote the other")
        }
        // Re-exporting one still replaces only itself: the subject is the finding's own folder.
        #expect(try store.exportPlan(shadowAxis("IRS Docs - 2023")) == first)
    }

    /// A landing can rename the finding's own subject — a shadow-axis rename does exactly that —
    /// and `rekey(renames:)` moves the draft's key before the caller drops it. Dropping the
    /// pre-landing key alone strands the draft forever behind a "Review N operations" trigger.
    @Test func aDraftIsDroppedThroughTheLandingsOwnRenames() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        let key = RestructureKey(kind: .shadowAxis, path: "Immigration/H-1B/IRS Docs - 2024")
        let landing = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "Immigration/H-1B",
            kind: .shadowAxis,
            actions: [.init(action: .renameDir, src: "Immigration/H-1B/IRS Docs - 2024",
                            dst: "Immigration/H-1B/2024")])
        store.saveDraft(.init(manifest: landing, savedAt: "t", exportedTo: nil, vocabulary: []),
                        for: key)
        #expect(store.draft(for: key) != nil)

        // Exactly what applyPlan does before the caller's continuation runs.
        store.rekey(renames: RestructureRederive.renameMap(of: landing))
        let moved = RestructureKey(kind: .shadowAxis, path: "Immigration/H-1B/2024")
        #expect(store.draft(for: key) == nil, "the key moved")
        #expect(store.draft(for: moved) != nil)

        store.removeDraft(for: key, consumedBy: landing)
        #expect(store.draft(for: moved) == nil, "the landing consumed it — it may not survive")
        #expect(store.drafts.isEmpty)
    }

    @Test func anUnchangedMutationDoesNotTouchTheDisk() throws {
        let dir = try makeDirectory()
        let key = RestructureKey(kind: .shape, path: "A")
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(key)
        let stamp = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("p/restructure.json").path)[.modificationDate]

        store.suppress(key)
        store.rekey(renames: [(from: "Elsewhere", to: "Nowhere")])

        let after = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("p/restructure.json").path)[.modificationDate]
        #expect(stamp as? Date == after as? Date)
    }
}

/// The store under imperfect input and colliding history — every one of these used to trap
/// (`Dictionary(uniqueKeysWithValues:)`) or silently lie (a swallowed ledger write).
@MainActor
@Suite final class RestructureStoreRobustnessTests {

    // Class + deinit for the same reason as `RestructureStoreTests`: each test's fixture
    // directory is swept the moment its suite instance goes away.
    private var scratch: [URL] = []
    deinit { for dir in scratch { try? FileManager.default.removeItem(at: dir) } }

    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restructure-robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        scratch.append(dir)
        return dir
    }

    private func manifest(id: String, family: String = "F") -> RestructureManifest {
        RestructureManifest(profileId: "p", manifestId: id, createdAt: "t", family: family,
                            kind: .shape, actions: [
                                .init(action: .renameDir, src: "\(family)/a", dst: "\(family)/b"),
                            ])
    }

    /// A rename whose destination equals a key recorded before that folder was hand-deleted is
    /// history, not a programming error: the rekeyed claim wins and nothing traps at the tail
    /// of a successful apply.
    @Test func rekeyingTwoAnswersOntoOneKeySurvivesAndTheRekeyedClaimWins() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordAnswer("stale", for: RestructureKey(kind: .ask, path: "Tax/Tax Records"))
        store.recordAnswer("fresh", for: RestructureKey(kind: .ask, path: "Tax/Forms"))

        store.rekey(renames: [(from: "Tax/Forms", to: "Tax/Tax Records")])

        #expect(store.answer(for: RestructureKey(kind: .ask, path: "Tax/Tax Records")) == "fresh")
    }

    /// A hand-edited file with a duplicated row loads (last row wins, JSON's own object rule) —
    /// the whole philosophy here is refusal over trap, and `load` used to crash the store's
    /// construction on exactly this input.
    @Test func aDuplicatedAnswerRowLoadsInsteadOfTrapping() throws {
        let dir = try makeDirectory()
        let json = """
        {"schemaVersion": 1, "answers": [
          {"kind": "ask", "path": "A", "choice": "first"},
          {"kind": "ask", "path": "A", "choice": "second"}
        ]}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("p/restructure.json"))
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(!store.isUnreadable)
        #expect(store.answer(for: RestructureKey(kind: .ask, path: "A")) == "second")
    }

    /// §5.5's licence to move files: `recordApplied` reports whether the record REACHED the
    /// disk, and the engine refuses the whole landing on false — tested here at the seam, with
    /// an unwritable directory standing in for a full disk.
    @Test func aFailedLedgerWriteIsReportedToTheCaller() throws {
        let dir = try makeDirectory()
        let folder = dir.appendingPathComponent("p")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: folder.path) }
        let store = RestructureStore(directory: dir, profileId: "p")
        let landed = store.recordApplied(RestructureStore.AppliedRecord(
            manifest: manifest(id: "m1"), inverse: manifest(id: "m1").inverse,
            at: "t", created: 0, skipped: 0, appliedUnderProfileId: "p"))
        #expect(!landed, "an unwritable ledger must be reported, not shrugged into memory")
    }

    // MARK: The one undoable landing (§5.5's chain, in its single spelling)

    private func record(id: String, appliedUnder: String? = "prof-a",
                        produced: String? = "prof-b", summary: String? = "did things",
                        undoneAt: String? = nil) -> RestructureStore.AppliedRecord {
        RestructureStore.AppliedRecord(
            manifest: manifest(id: id), inverse: manifest(id: id).inverse, at: "t",
            created: 0, skipped: 0, appliedUnderProfileId: appliedUnder,
            producedProfileId: produced, summary: summary, undoneAt: undoneAt)
    }

    @Test func theNewestNotUndoneReorganisationIsTheOneOffered() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", produced: "prof-b"))
        store.recordApplied(record(id: "m2", appliedUnder: "prof-b", produced: "prof-c"))
        #expect(store.undoableReorganisation(currentProfileId: "prof-c")?
            .manifest.manifestId == "m2")
        #expect(store.undoableReorganisation(currentProfileId: "prof-b") == nil,
                "the newest landing's produced directory is not active — nothing is offered")
    }

    /// A scaffold record never carries `appliedUnderProfileId`; it is not a link in the chain
    /// and must neither be offered nor block the reorganisation beneath it.
    @Test func aScaffoldRecordIsInvisibleToTheChain() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", produced: "prof-b"))
        store.recordApplied(record(id: "scaffold-1", appliedUnder: nil, produced: nil,
                                   summary: nil))
        #expect(store.undoableReorganisation(currentProfileId: "prof-b")?
            .manifest.manifestId == "m1")
    }

    /// A landing whose re-derive failed never re-pointed the survey (`producedProfileId` nil,
    /// summary set): it anchors on the directory it was applied under, and is still undoable —
    /// the first gate compared produced ids and stranded exactly these records forever.
    @Test func aLandingWhoseRederiveFailedIsStillOffered() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", appliedUnder: "prof-a", produced: nil))
        #expect(store.undoableReorganisation(currentProfileId: "prof-a")?
            .manifest.manifestId == "m1")
    }

    /// A record without a summary never finalised — the app quit mid-apply, so its stored
    /// inverse may not match the disk. Never offered.
    @Test func aNeverFinalisedLandingIsNotOffered() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", produced: nil, summary: nil))
        #expect(store.undoableReorganisation(currentProfileId: "prof-a") == nil)
    }

    @Test func anUndoneLandingReopensTheOneBeneathIt() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1", produced: "prof-b"))
        store.recordApplied(record(id: "m2", appliedUnder: "prof-b", produced: "prof-c",
                                   undoneAt: "later"))
        #expect(store.undoableReorganisation(currentProfileId: "prof-b")?
            .manifest.manifestId == "m1")
    }
}

/// **The ledger's write path: how often it writes, and in what shape.**
///
/// A landing rewrote `restructure.json` five times, each a whole-file encode of an append-only
/// ledger whose every record carries a manifest AND its inverse with an evidence sentence per
/// action — and it pretty-printed them, which roughly doubles the bytes. These pin the two fixes
/// and, more importantly, the ONE thing that must not have moved with them: a record only counts
/// as on disk when it really is.
@MainActor
@Suite final class RestructureLedgerWriteTests {

    private var scratch: [URL] = []
    deinit { for dir in scratch { try? FileManager.default.removeItem(at: dir) } }

    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restructure-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        scratch.append(dir)
        return dir
    }

    private func fileURL(_ dir: URL) -> URL {
        dir.appendingPathComponent("p/restructure.json")
    }

    private func manifest(id: String) -> RestructureManifest {
        RestructureManifest(profileId: "p", manifestId: id, createdAt: "t", family: "F",
                            kind: .shape, actions: [
                                .init(action: .renameDir, src: "F/a", dst: "F/b"),
                            ])
    }

    private func record(id: String) -> RestructureStore.AppliedRecord {
        RestructureStore.AppliedRecord(manifest: manifest(id: id),
                                       inverse: manifest(id: id).inverse, at: "t",
                                       created: 0, skipped: 0,
                                       appliedUnderProfileId: "prof-a")
    }

    /// The file's modification date is the only honest witness to "did it write", so writes are
    /// counted by watching it. A whole-second resolution would not separate two writes in one
    /// test, so the size is watched too — every mutation here changes the content.
    private func snapshot(_ dir: URL) throws -> Data { try Data(contentsOf: fileURL(dir)) }

    // MARK: The shape

    /// **Not pretty-printed, still sorted, still readable by the loader.** Sorted keys are what
    /// make the bytes a function of the state; the whitespace was never part of that.
    @Test func theLedgerIsWrittenCompactAndSortedAndReadsBack() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.suppress(RestructureKey(kind: .shape, path: "F"))
        store.recordApplied(record(id: "m1"))

        let text = try String(contentsOf: fileURL(dir), encoding: .utf8)
        #expect(!text.contains("\n  \""), "the ledger must not be pretty-printed")
        // `.sortedKeys` at the top level: applied before schemaVersion before suppressed.
        let keyOrder = ["\"applied\"", "\"schemaVersion\"", "\"suppressed\""]
            .map { text.range(of: $0)?.lowerBound }
        #expect(keyOrder.allSatisfy { $0 != nil })
        #expect(zip(keyOrder, keyOrder.dropFirst()).allSatisfy { $0! < $1! },
                "keys must still be sorted — the bytes are a function of the state")

        let reopened = RestructureStore(directory: dir, profileId: "p")
        #expect(!reopened.isUnreadable)
        #expect(reopened.applied.map(\.manifest.manifestId) == ["m1"])
        #expect(reopened.isSuppressed(RestructureKey(kind: .shape, path: "F")))
    }

    /// A file an older build wrote — pretty-printed, same schema — still loads. The format did
    /// not change; only the whitespace did.
    @Test func aPrettyPrintedFileFromAnOlderBuildStillLoads() throws {
        let dir = try makeDirectory()
        let seed = RestructureStore(directory: dir, profileId: "p")
        seed.recordApplied(record(id: "m1"))
        // Re-write the very same content pretty-printed, as the previous build did.
        let object = try JSONSerialization.jsonObject(with: try snapshot(dir))
        try JSONSerialization.data(withJSONObject: object,
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: fileURL(dir))

        let reopened = RestructureStore(directory: dir, profileId: "p")
        #expect(!reopened.isUnreadable)
        #expect(reopened.applied.map(\.manifest.manifestId) == ["m1"])
    }

    // MARK: The batch

    /// Mutations inside a batch reach the disk exactly ONCE, at the end.
    @Test func aBatchWritesOnceAtTheEnd() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1"))
        let before = try snapshot(dir)

        var midBatch: Data?
        store.batchingSaves {
            store.updateApplied(manifestId: "m1") { $0.summary = "one" }
            store.suppress(RestructureKey(kind: .shape, path: "F"))
            store.recordAnswer("later", for: RestructureKey(kind: .shape, path: "G"))
            midBatch = try? self.snapshot(dir)
        }
        #expect(midBatch == before, "nothing may reach the file while the batch is open")

        let after = try snapshot(dir)
        #expect(after != before, "the batch must flush at its end")
        let reopened = RestructureStore(directory: dir, profileId: "p")
        #expect(reopened.applied.first?.summary == "one")
        #expect(reopened.isSuppressed(RestructureKey(kind: .shape, path: "F")))
        #expect(reopened.answer(for: RestructureKey(kind: .shape, path: "G")) == "later")
    }

    /// **`recordApplied` writes even inside a batch.** Its `true` is the licence to start moving
    /// files — "the inverse is on disk before the first operation" — so a batched `true` meaning
    /// "queued" would be that invariant lost in one word.
    @Test func recordAppliedReachesDiskEvenInsideABatch() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1"))

        var wroteDuringBatch = false
        store.batchingSaves {
            store.suppress(RestructureKey(kind: .shape, path: "F"))
            #expect(store.recordApplied(self.record(id: "m2")))
            // Read the file from a SECOND store: the record must be on disk right now.
            let peek = RestructureStore(directory: dir, profileId: "p")
            wroteDuringBatch = peek.applied.map(\.manifest.manifestId) == ["m1", "m2"]
        }
        #expect(wroteDuringBatch,
                "the ledger record must be on disk before the caller is told it may move files")
    }

    /// A batch that changes nothing writes nothing — an empty flush would rewrite the file for
    /// no reason, and this store is on a path where every write matters.
    @Test func anEmptyBatchDoesNotWrite() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1"))
        let before = try FileManager.default.attributesOfItem(atPath: fileURL(dir).path)
        store.batchingSaves { _ = store.applied.count }
        let after = try FileManager.default.attributesOfItem(atPath: fileURL(dir).path)
        #expect((before[.modificationDate] as? Date) == (after[.modificationDate] as? Date))
    }

    /// Nested batches flush at the OUTERMOST close, not the first one to finish.
    @Test func nestedBatchesFlushOnceAtTheOutermostClose() throws {
        let dir = try makeDirectory()
        let store = RestructureStore(directory: dir, profileId: "p")
        store.recordApplied(record(id: "m1"))
        let before = try snapshot(dir)

        var afterInner: Data?
        store.batchingSaves {
            store.batchingSaves {
                store.suppress(RestructureKey(kind: .shape, path: "F"))
            }
            afterInner = try? self.snapshot(dir)
        }
        #expect(afterInner == before, "the inner close must not flush")
        #expect(try snapshot(dir) != before)
    }

    /// A batch over a store that is refusing to write still refuses — the flush goes through the
    /// same `isUnreadable` gate every save does.
    @Test func aBatchOverAnUnreadableStoreStillRefuses() throws {
        let dir = try makeDirectory()
        try Data("{ not json".utf8).write(to: fileURL(dir))
        let store = RestructureStore(directory: dir, profileId: "p")
        #expect(store.isUnreadable)
        let (_, saved) = store.batchingSaves {
            store.suppress(RestructureKey(kind: .shape, path: "F"))
        }
        #expect(!saved)
        #expect(try String(contentsOf: fileURL(dir), encoding: .utf8) == "{ not json")
    }
}
