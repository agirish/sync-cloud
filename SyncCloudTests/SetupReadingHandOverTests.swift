import Foundation
import Settings
import Sync
import Testing
@testable import SyncCloud

/// Setup's Save and the document reading it starts, driven together through a real engine.
///
/// The reading is the app's, not the model's (`ContentView` runs it through
/// ``DocumentSurveyStarter``), so these hand the model an `onStartSurvey` running the same starter
/// over a scratch profiles folder, with text "documents" the injected extractor reads back. Heat
/// holds a reading open: hot, it pauses before the next document; cooled, it reads on. Every wait
/// is bounded.
@MainActor
@Suite struct SetupReadingHandOverTests {

    private final class Machine {
        var hot = true
        /// Hot once this many documents are read, when set — so a reading stands paused part-way.
        var hotAfter: Int?
    }

    /// Every document the extractor opened, in order.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func note(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let documents: URL
        let profiles: URL
        let engine = FileSyncManager.scratch()
        let machine = Machine()
        let reads = Reads()
        var starts: [Task<DocumentSurveyStarter.Outcome, Never>] = []

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("setup-handover-\(UUID().uuidString)")
            documents = root.appendingPathComponent("Documents")
            profiles = root.appendingPathComponent("profiles")
            let page = "Pacific Gas and Electric statement for the account holder, with the "
                + "amount due and the date it is due by, and the usual notes about the service."
            for path in ["Finance/US/2024/jan.pdf", "Finance/US/2024/feb.pdf",
                         "Finance/IN/2024/mar.pdf", "Finance/IN/2024/apr.pdf"] {
                let url = documents.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data(page.utf8).write(to: url)
            }
            try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
            engine.filingProfilesDirectory = profiles
            let reads = reads
            engine.filingSnippetExtractor = {
                reads.note($0)
                return try? String(contentsOfFile: $0, encoding: .utf8)
            }
            let machine = machine
            engine.machineConditions = {
                let hot = machine.hotAfter.map { reads.all.count >= $0 } ?? machine.hot
                return MachineConditions(heat: hot ? .serious : .nominal)
            }
        }

        /// What `FilingArtifacts.attach` does, pointed at the scratch folder.
        func attach() {
            guard let loaded = FilingProfileStore.active(in: profiles) else { return }
            engine.filingFolderProfile = loaded.profile
            engine.filingMemory = loaded.memory
            engine.filingProfileDirectoryId = loaded.id
            engine.filingPeopleStore = PeopleStore(directory: profiles, profileId: loaded.id,
                                                   profile: loaded.profile)
        }

        /// What `ContentView.startDocumentSurvey(learnedRoot:)` does, minus the scope.
        func startReading(_ root: URL) {
            let engine = engine
            starts.append(Task { @MainActor in
                await DocumentSurveyStarter.start(manager: engine, askedFrom: root, mode: .read,
                                                  planned: { _ in })
            })
        }

        /// Setup's model over this engine, its Save attaching here and starting the reading here.
        func model(settings: SettingsManager, hasFilingProfile: Bool = false) -> SetupModel {
            SetupModel(settings: settings, peopleStore: nil, syncManager: engine,
                       hasFilingProfile: hasFilingProfile,
                       defaults: ScratchDefaults("setup-handover-d"), draftURL: nil,
                       onProfileWritten: { self.attach() },
                       onStartSurvey: { self.startReading($0) })
        }

        /// A folder `Elsewhere` beside Documents, holding one tax "document" of `text`.
        func elsewhere(_ text: String) throws -> URL {
            let folder = root.appendingPathComponent("Elsewhere")
            let url = folder.appendingPathComponent("Taxes/2023/w2.pdf")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return folder
        }

        func corpusExists(in profileId: String) -> Bool {
            FileManager.default.fileExists(
                atPath: profiles.appendingPathComponent("\(profileId)/filing-corpus.json").path)
        }
    }

    private func settings() async -> SettingsManager {
        let manager = SettingsManager(autoDiscover: false, userDefaults: ScratchDefaults("setup-handover"),
                                      cloudStorageLister: {
                                          CloudStorageAccounts(folders: [], rootWasReadable: true)
                                      },
                                      pathValidator: { _ in true })
        await manager.discoverProviders()
        return manager
    }

    // MARK: - A second Save while the documents are read (review M4)

    /// A second Save stops the reading, which carries on into the new profile from where it stood:
    /// two documents in at the Save, it opens only the other two. Left to run, it would write what
    /// it learned into the replaced profile.
    @Test(.timeLimit(.minutes(2)))
    func aSecondSaveCarriesTheReadingIntoTheNewProfile() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model(settings: await settings())
        fixture.machine.hotAfter = 2
        model.changeWalkRoot(to: fixture.documents, thenLearn: true)
        await model.lastWalk?.value
        let failure = model.walkFailureReason ?? "still running"
        try #require(model.walkState.isDone, "premise: the folder was read (\(failure))")
        model.confirmedCountries = ["US"]

        #expect(await model.save(), "premise: the first Save wrote")
        let first = try #require(model.writtenReport?.profileId)
        #expect(fixture.starts.count == 1, "premise: the first Save started the reading")
        await waitUntil("premise: the reading never got under way, so the rest proves nothing", timeout: 90) {
            fixture.engine.documentSurveyProgress?.pause == .thermal
        }

        model.toggleCountry("IN")
        #expect(await model.save(), "premise: the second Save wrote")
        let second = try #require(model.writtenReport?.profileId)
        #expect(second != first, "premise: the second Save wrote a new profile")

        guard fixture.starts.count == 2 else {
            Issue.record("the second Save did not start the reading again (\(fixture.starts.count) start(s))")
            // The first reading is still paused for the heat; end it so it does not outlive the test.
            await fixture.engine.stopDocumentSurvey()
            return
        }
        let handed = await fixture.starts[0].value
        #expect(handed == .handedOver, "the reading of \(first) was not stopped: \(handed)")
        #expect(fixture.reads.all.count == 2, "premise: the first reading stood two documents in")
        fixture.machine.hotAfter = nil
        fixture.machine.hot = false
        let carried = await fixture.starts[1].value
        guard case .ran(let report) = carried else {
            Issue.record("the restarted reading did not run: \(carried)")
            return
        }
        #expect(report.isComplete)
        #expect(fixture.corpusExists(in: second), "the reading never reached the profile in use")
        #expect(!fixture.corpusExists(in: first), "the reading landed in the profile the Save replaced")
        #expect(fixture.engine.filingMemory?.profileId == second)
        let opened = fixture.reads.all
        #expect(opened.count == 4 && Set(opened).count == 4,
                "the carried reading opened again what was read before the Save: \(opened.map { ($0 as NSString).lastPathComponent })")
    }

    /// A Save of another folder stops the reading under way, since its profile is no longer in use,
    /// but doesn't carry it on; with Read Documents off it starts none of its own. Restarting on a
    /// different folder would begin hours of reading nobody asked for.
    @Test(.timeLimit(.minutes(2)))
    func aSaveOfAnotherFolderStartsNoReadingItWasNotAskedFor() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let elsewhere = try fixture.elsewhere("Wage and tax statement for the year, from the employer to the "
                                              + "employee, with the amounts withheld for federal and state income tax.")
        _ = try FilingProfileStore.writeProfile(
            FolderProfile(profileId: "walk-elsewhere", root: elsewhere.path, folders: [:],
                          personTokens: []),
            in: fixture.profiles)
        fixture.attach()
        fixture.startReading(elsewhere)
        await waitUntil("premise: the reading of Elsewhere never got under way", timeout: 90) {
            fixture.engine.documentSurveyProgress?.pause == .thermal
        }

        let model = fixture.model(settings: await settings(), hasFilingProfile: true)
        model.changeWalkRoot(to: fixture.documents, thenLearn: true)
        await model.lastWalk?.value
        try #require(model.walkState.isDone, "premise: the folder was read")
        model.readDocuments = false

        #expect(await model.save(), "premise: the Save wrote")
        #expect(model.writtenReport?.becameActive == true, "premise: the Save replaced Elsewhere's profile")

        #expect(fixture.starts.count == 1,
                "the Save started a reading of \(model.walkRootName) with Read Documents off")
        if fixture.starts.count > 1 { await fixture.engine.stopDocumentSurvey() }
        let first = await fixture.starts[0].value
        #expect(first == .handedOver, "the reading of the replaced profile came to \(first)")
    }

    // MARK: - Look Again (review L2)

    /// Look Again only counts; it promises a count, not a reading. The card's state picks the mode,
    /// and only an offer of no readable documents gets the count-only mode.
    @Test func lookAgainCountsAndReadsNothing() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.machine.hot = false
        _ = try FilingProfileStore.writeProfile(
            FolderProfile(profileId: "t", root: fixture.documents.path, folders: [:], personTokens: []),
            in: fixture.profiles)
        fixture.attach()

        #expect(DocumentSurveyStarter.mode(for: .offered(documents: 0)) == .recountOnly)
        #expect(DocumentSurveyStarter.mode(for: .offered(documents: 4)) == .read)
        #expect(DocumentSurveyStarter.mode(for: .offered(documents: nil)) == .read)

        var facts: DocumentSurveyPlanFacts?
        let outcome = await DocumentSurveyStarter.start(
            manager: fixture.engine, askedFrom: fixture.documents,
            mode: DocumentSurveyStarter.mode(for: .offered(documents: 0)), planned: { facts = $0 })

        #expect(outcome == .counted(4), "Look Again came to \(outcome)")
        #expect(outcome.banner == nil, "the card says the count; a banner would say it twice")
        #expect(facts?.documents(for: fixture.documents.path) == 4,
                "the card was not handed the new count")
        #expect(fixture.engine.documentSurveyReport == nil, "Look Again read the documents")
        #expect(!fixture.corpusExists(in: "t"))
    }

    /// A plan made for a profile since replaced is made again, once, and the reading goes into the
    /// profile in use. The race is a Save landing while the plan walks; the large-walk question,
    /// asked part-way, is where this stages it.
    @Test func aPlanOvertakenByASaveIsMadeAgain() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.machine.hot = false
        _ = try FilingProfileStore.writeProfile(
            FolderProfile(profileId: "walk-old", root: fixture.documents.path, folders: [:],
                          personTokens: []),
            in: fixture.profiles)
        fixture.attach()
        fixture.engine.wholeTreeProbeBudget = 1
        var asked = 0
        let profiles = fixture.profiles
        let documents = fixture.documents
        let engine = fixture.engine
        engine.largeWalkConfirmer = { _ in
            asked += 1
            if asked == 1 {
                // A Save of the same folder, as Setup's lands mid-walk.
                _ = try? FilingProfileStore.writeProfile(
                    FolderProfile(profileId: "walk-new", root: documents.path, folders: [:],
                                  personTokens: []),
                    in: profiles)
                fixture.attach()
            }
            return true
        }
        #expect(engine.filingProfileDirectoryId == "walk-old")

        let outcome = await DocumentSurveyStarter.start(manager: engine, askedFrom: documents,
                                                        mode: .read, planned: { _ in })

        guard case .ran(let report) = outcome else {
            Issue.record("the overtaken plan came to \(outcome)")
            return
        }
        #expect(report.isComplete)
        #expect(asked == 2, "planned \(asked) time(s)")
        #expect(fixture.corpusExists(in: "walk-new"), "the reading never reached the profile in use")
        #expect(!fixture.corpusExists(in: "walk-old"), "the overtaken plan read into the old profile")
    }

    /// A plan overtaken by a Save of another folder is not made again: it walks the profile's own
    /// folder, so planning again would read the new folder, hours nobody asked for.
    @Test func aPlanOvertakenByASaveOfAnotherFolderReadsNothing() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.machine.hot = false
        let elsewhere = try fixture.elsewhere(
            "Wage and tax statement for the year, from the employer to the employee, with the amounts withheld.")
        _ = try FilingProfileStore.writeProfile(
            FolderProfile(profileId: "walk-old", root: fixture.documents.path, folders: [:],
                          personTokens: []),
            in: fixture.profiles)
        fixture.attach()
        fixture.engine.wholeTreeProbeBudget = 1
        var asked = 0
        let profiles = fixture.profiles
        fixture.engine.largeWalkConfirmer = { _ in
            asked += 1
            if asked == 1 {
                // A Save of another folder, as Setup's lands mid-walk.
                _ = try? FilingProfileStore.writeProfile(
                    FolderProfile(profileId: "walk-elsewhere", root: elsewhere.path, folders: [:],
                                  personTokens: []),
                    in: profiles)
                fixture.attach()
            }
            return true
        }

        let outcome = await DocumentSurveyStarter.start(manager: fixture.engine,
                                                        askedFrom: fixture.documents,
                                                        mode: .read, planned: { _ in })

        #expect(outcome == .refused(.profileReplaced), "the overtaken plan came to \(outcome)")
        #expect(fixture.reads.all.isEmpty,
                "read \(fixture.reads.all.map { ($0 as NSString).lastPathComponent }) — the folder the Save switched to")
        #expect(!fixture.corpusExists(in: "walk-elsewhere"))
        #expect(!fixture.corpusExists(in: "walk-old"))
    }

    /// A Save whose reading doesn't stop in time writes nothing, and the reading reads on. A stop
    /// lands between documents, so without a bound the Save, with Back greyed, would wait on a
    /// document whose text never comes.
    @Test(.timeLimit(.minutes(2)))
    func aSaveWhoseReadingDoesNotStopInTimeWritesNothing() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.machine.hot = false
        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var _entered = false, _released = false
            var entered: Bool { lock.lock(); defer { lock.unlock() }; return _entered }
            var released: Bool { lock.lock(); defer { lock.unlock() }; return _released }
            func enter() { lock.lock(); _entered = true; lock.unlock() }
            func release() { lock.lock(); _released = true; lock.unlock() }
        }
        let gate = Gate()
        fixture.engine.filingSnippetExtractor = { path in
            gate.enter()
            let deadline = Date().addingTimeInterval(100)
            while !gate.released, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        fixture.engine.documentSurveyStopWait = .milliseconds(300)
        let model = fixture.model(settings: await settings())
        model.changeWalkRoot(to: fixture.documents, thenLearn: true)
        await model.lastWalk?.value
        try #require(model.walkState.isDone, "premise: the folder was read")
        model.confirmedCountries = ["US"]
        #expect(await model.save(), "premise: the first Save wrote")
        let first = try #require(model.writtenReport?.profileId)
        await waitUntil("premise: no document read began", timeout: 90) { gate.entered }

        model.toggleCountry("IN")
        let wrote = await model.save()

        #expect(!wrote, "the Save went ahead over a reading that had not stopped")
        #expect(model.writtenReport?.profileId == first, "a second profile was written")
        #expect(model.saveFailure?.contains("still reading") == true,
                "the failure line says \(model.saveFailure ?? "nothing")")
        #expect(fixture.starts.count == 1, "the reading was started a second time")
        gate.release()
        let outcome = await fixture.starts[0].value
        guard case .ran(let report) = outcome else {
            Issue.record("the reading did not read on: \(outcome)")
            return
        }
        #expect(report.isComplete)
        #expect(fixture.corpusExists(in: first), "the reading did not land in the profile in use")
    }

    /// A reading that couldn't start says so as a refusal, kept for this session only, as the same
    /// refusal from To File's menu is; one that ran is kept.
    @Test func aReadingThatCouldNotStartIsARefusal() {
        let refused = DocumentSurveyStarter.Outcome.refused(.alreadyRunning).banner
        #expect(refused?.isRefusal == true)
        #expect(refused?.message == FileSyncManager.DocumentSurveyRefusal.alreadyRunning.sentence)
        #expect(DocumentSurveyStarter.Outcome.nothingToRead.banner?.isRefusal == false)
    }
}
