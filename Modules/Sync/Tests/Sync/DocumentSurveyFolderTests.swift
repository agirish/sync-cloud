import Foundation
import Testing
import Events
import EventsTestSupport
@testable import Sync

/// **A document survey reads the profile's own folder, whatever it was asked about.**
///
/// What it learns is keyed by paths relative to the folder it walks, and To File reads that memory
/// by the profile's folder paths — so a survey of any other folder writes a memory that lines up
/// with nothing, under the profile's name. It was asked with Organize's scope, or failing that the
/// focused pane's current folder: a first reading started from setup while the pane sat on another
/// source spent hours on the wrong tree, and the next Refresh — which has walked the profile's own
/// folder since P70 — then read nearly all of it as gone. Started inside a subfolder, it keyed
/// every document a level off until a Refresh re-keyed what it could match by size and date.
///
/// The sibling of `FilingResurveyTests`' "the profile's own folder" cases, on the same fixture.
@Suite @MainActor struct DocumentSurveyFolderTests {

    /// The four documents `FilingResurveyTests.makeTree()` puts in the profile's folder.
    static let own: Set<String> = ["Home/PG&E/2024/jan.pdf", "Home/PG&E/2024/feb.pdf",
                                   "Health/Kaiser/eob-1.pdf", "Health/Kaiser/eob-2.pdf"]

    /// A folder beside the profile's: one document at a path the profile also has, so a survey of
    /// the wrong tree keys it exactly where a right one would, and one only this folder has.
    static func elsewhere(beside docs: URL) throws -> URL {
        let elsewhere = docs.deletingLastPathComponent().appendingPathComponent("Elsewhere")
        try FilingResurveyTests.write(elsewhere.appendingPathComponent("Health/Kaiser/eob-1.pdf"),
                                      FilingResurveyTests.page("Aetna dental claim"))
        try FilingResurveyTests.write(elsewhere.appendingPathComponent("Finance/Chase/statement.pdf"),
                                      FilingResurveyTests.page("Chase checking"))
        return elsewhere
    }

    /// **Asked about another folder, it plans, reads and records the profile's.** Every artifact
    /// is checked, because each one was wrong: the plan listed the other folder's documents, the
    /// run opened them, the corpus was keyed by them, and the memory and the receipt both named
    /// that folder.
    @Test func aSurveyAskedAboutAnotherFolderReadsTheProfilesOwn() async throws {
        let (manager, docs, profiles, reads) = try FilingResurveyTests.makeTree()
        let elsewhere = try Self.elsewhere(beside: docs)

        let plan = try await manager.planDocumentSurvey(root: elsewhere).get()
        #expect(Set(plan.paths) == Self.own, "planned the documents of the folder it was asked about")
        #expect(plan.root.path == docs.path)
        // What the card matches its receipt against, so the two must be the same value.
        #expect(plan.root == manager.documentSurveyFolder)

        let report = try await manager.runDocumentSurvey(plan: plan).get()

        #expect(!reads.paths.contains { $0.hasPrefix(elsewhere.path + "/") },
                "opened documents from the folder it was asked about: \(reads.paths)")
        #expect(Set(reads.paths) == Set(Self.own.map { docs.appendingPathComponent($0).path }))
        let corpus = try #require(FilingSurveyStore.corpus(id: "t", in: profiles))
        #expect(Set(corpus.documents.keys) == Self.own, "the corpus does not describe the profile's folder")
        let memory = try Data(contentsOf: profiles.appendingPathComponent("t/filing-memory.json"))
        let header = try #require(try JSONSerialization.jsonObject(with: memory) as? [String: Any])
        #expect(header["root"] as? String == docs.path, "the memory names another folder as its root")
        #expect(report.rootPath == docs.path, "the receipt describes another folder")
    }

    /// **The spelling real profiles use.** Every profile on disk records `~/Documents` and every
    /// fixture here an absolute path, so a survey that took the recorded root without expanding the
    /// tilde would resolve it against the working directory and refuse every real reading with all
    /// of the above green. Spelled through `~` and back down to the temp folder, and asked about
    /// another folder, so only the expansion makes the plan come out right.
    @Test func aRootRecordedThroughTheTildeIsExpandedAndSurveyed() async throws {
        let (manager, docs, _, reads) = try FilingResurveyTests.makeTree()
        let elsewhere = try Self.elsewhere(beside: docs)
        let depth = NSHomeDirectory().split(separator: "/").count
        let spelled = "~/" + String(repeating: "../", count: depth) + docs.path.dropFirst()
        #expect((spelled as NSString).expandingTildeInPath != spelled, "premise: the tilde is what expands")
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: spelled, folders: [:],
                                                    personTokens: [])

        let plan = try await manager.planDocumentSurvey(root: elsewhere).get()
        _ = try await manager.runDocumentSurvey(plan: plan).get()

        #expect(Set(plan.paths) == Self.own)
        #expect(reads.paths.count == Self.own.count
                && reads.paths.allSatisfy { $0.contains("/Documents/") }, "\(reads.paths)")
    }

    /// **A profile that does not say which folder it describes is not surveyed.** Its file has no
    /// `root`, which decodes as `~` — a placeholder, not a record — and a first reading of the
    /// whole home folder under that guess is hours spent writing a memory keyed to the wrong tree.
    /// A root that is not absolute once `~` is expanded is refused the same way: it would resolve
    /// against the working directory. Refresh refuses both, since P70.
    ///
    /// The probe is tiny and the confirmer declines, so a regression that does walk a guessed
    /// folder asks about it here and stops before it opens a document — which is also what marks
    /// the old behaviour, that walked the folder it was asked about. The refusal is read off the
    /// log by the sentence only this pass writes; Refresh's names the same two failures.
    @Test(arguments: [(#"{"profileId": "t", "folders": []}"#,
                       "does not record which folder it describes"),
                      (#"{"profileId": "t", "root": "Documents", "folders": []}"#,
                       "names “Documents” as its folder")])
    func aProfileThatRecordsNoFolderIsNotSurveyed(profileJSON: String, refusal: String) async throws {
        let (manager, docs, profiles, reads) = try FilingResurveyTests.makeTree()
        manager.filingFolderProfile = try JSONDecoder().decode(FolderProfile.self,
                                                               from: Data(profileJSON.utf8))
        manager.wholeTreeProbeBudget = 1
        var asked: LargeWalkPreflight?
        manager.largeWalkConfirmer = { asked = $0; return false }
        let log = LogCapture()

        let result = await manager.planDocumentSurvey(root: docs)

        #expect(asked == nil, "walked \(asked?.rootPath ?? "") on a guess")
        guard case .failure(let reason) = result else {
            Issue.record("planned a survey for a profile that names no folder")
            return
        }
        #expect(reason == .noRecordedFolder)
        #expect(await log.holds(.warning, containing: "Document survey: the filing profile " + refusal))
        #expect(reads.paths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: profiles.path),
                "wrote something for a profile that names no folder")
    }
}
