import Foundation
import Settings
import Sync
import Testing
@testable import SyncCloud

/// The rules the guided sheet runs on, without a window.
///
/// **`SetupModel` exists so these can be asked at all.** Every one of them lived on a 1,978-line
/// view before, where nothing could reach them — which is how the caret rule came to fire on the
/// one path nobody uses and not on the one everybody does.
@MainActor
@Suite struct SetupModelTests {

    private func settings() async -> SettingsManager {
        let defaults = ScratchDefaults("setup-model")
        let manager = SettingsManager(
            autoDiscover: false,
            userDefaults: defaults,
            cloudStorageLister: {
                CloudStorageAccounts(
                    folders: [URL(fileURLWithPath: "/private/tmp/setup-model/GoogleDrive-a@example.com")],
                    rootWasReadable: true)
            },
            pathValidator: { _ in true })
        await manager.discoverProviders()
        return manager
    }

    private func model(walk: SetupWalk? = nil, syncManager: FileSyncManager? = nil) async -> SetupModel {
        SetupModel(settings: await settings(), peopleStore: nil, syncManager: syncManager,
                   hasFilingProfile: false,
                   defaults: ScratchDefaults("setup-model-d"),
                   walk: walk)
    }

    private static func walk(folders: [String], files: [String] = []) -> SetupWalk {
        SetupWalk.summarising(tree: SetupSheetFitTests.fixtureTree(folders: folders, files: files),
                              root: URL(fileURLWithPath: "/tmp/Documents"),
                              recordedRoot: "~/Documents", known: [])
    }

    // MARK: - The name, and the folder that corroborates it

    /// **The sentence the You screen exists to say could never appear.** The folder match was
    /// computed inside the field-seeding function, which guards on the fields being empty — so it
    /// ran once at open, before any tree existed, found nothing, and never ran again.
    @Test func theFolderMatchIsFoundOnceTheTreeArrives() async {
        let model = await self.model()
        model.firstName = "Abhishek"
        #expect(model.matchedFolder == nil, "there is no tree yet — nothing can corroborate")

        model.adopt(Self.walk(folders: ["Abhishek/Notes", "Finance/US"]))
        #expect(model.matchedFolder == "Abhishek")
    }

    /// It follows the name the user actually typed, which a value captured at open could not.
    @Test func theFolderMatchFollowsTheTypedName() async {
        let model = await self.model(walk: Self.walk(folders: ["Abhishek/Notes", "Maya/Notes"]))
        model.firstName = "Maya"
        #expect(model.matchedFolder == "Maya")
        model.firstName = "Nobody"
        #expect(model.matchedFolder == nil)
    }

    // MARK: - The forms of the name

    /// Editing the name takes the old name's forms with it.
    ///
    /// They used to be the answer itself, so they outlived the name they were about: the screen
    /// offered `Abhishek Girish` under a first name now reading `Abhi`, ticked, and filed under it.
    @Test func editingTheNameDropsTheOldNamesForms() async {
        let model = await self.model()
        model.firstName = "Abhishek"
        model.surname = "Girish"
        #expect(model.tickedForms.contains("Abhishek Girish"))

        model.firstName = "Abhi"
        #expect(model.offeredNameForms.map(\.form).contains("Abhi Girish"))
        #expect(!model.offeredNameForms.map(\.form).contains("Abhishek Girish"),
                "the old name's form is still on offer")
        #expect(!model.tickedForms.contains("Abhishek Girish"),
                "the user would be filed under a name they have just corrected")
    }

    /// A form the user typed is theirs, so it survives an edit to the fields.
    @Test func aTypedFormSurvivesAnEditToTheName() async {
        let model = await self.model()
        model.firstName = "Abhishek"
        model.newFormField = "Dad"
        model.commitTypedForm()
        #expect(model.tickedForms.contains("Dad"))

        model.firstName = "Abhi"
        #expect(model.tickedForms.contains("Dad"), "a nickname is not a consequence of the spelling")
    }

    /// Unticking a suggestion is remembered, and re-ticking it works.
    @Test func aDecisionAboutASuggestionIsKept() async {
        let model = await self.model()
        model.firstName = "Abhishek"
        model.surname = "Girish"
        #expect(model.tickedForms.contains("Girish Abhishek"))

        model.toggleForm("Girish Abhishek")
        #expect(!model.tickedForms.contains("Girish Abhishek"))
        model.toggleForm("Girish Abhishek")
        #expect(model.tickedForms.contains("Girish Abhishek"))
    }

    /// Initials are offered and left for the user, so they are not in the answer by default.
    @Test func initialsAreOfferedAndNotTicked() async {
        let model = await self.model()
        model.firstName = "Abhishek"
        model.surname = "Girish"
        #expect(model.offeredNameForms.map(\.form).contains("A. Girish"))
        #expect(!model.tickedForms.contains("A. Girish"))
    }

    // MARK: - The walk

    /// A tree brings the countries and the preview with it — the four things a real walk produces.
    @Test func adoptingATreeSeedsEverythingDownstreamOfIt() async {
        var folders: [String] = []
        for parent in ["Finance", "Legal", "School", "Work", "Immigration"] {
            folders.append("\(parent)/US/2024")
            folders.append("\(parent)/EMP/2024")
        }
        let model = await self.model(walk: Self.walk(folders: folders, files: ["loose.pdf"]))

        #expect(model.walkState.isDone)
        #expect(model.confirmedCountries == ["US"],
                "EMP splits five parents too, and is not a country — the region check is what tells them apart")
        #expect(model.preview != nil, "Structure would draw nothing")
        #expect(!model.previewReadings.children.isEmpty, "the tree's sibling map was not derived")
        #expect(model.looseRoutes.count == 1)
    }

    /// Skipping Learn records that nothing was read, and lands on the next screen that still asks
    /// something.
    @Test func skippingLearnGoesToYouAndDropsWhatNeedsATree() async {
        let model = await self.model()
        model.screen = .learn
        #expect(model.skip())
        #expect(model.walkState == .skipped)
        #expect(model.screen == .you)
        #expect(!model.crumbs.contains(.countries))
        #expect(!model.crumbs.contains(.structure))
    }

    /// **Learn cannot be pressed with nothing to read.** It used to be: the press did nothing at
    /// all, and the sheet then could not reach Structure with no line anywhere saying why.
    @Test func learnIsRefusedWithoutAFolderOrAnEngine() async {
        let model = await self.model()
        model.walkRoot = nil
        #expect(!model.canLearn)
        model.walkRoot = URL(fileURLWithPath: "/tmp")
        #expect(!model.canLearn, "there is no engine to walk with")
    }

    /// Structure's three states, and the one thing that must never be true: a button that writes
    /// nothing while saying Save.
    @Test func structureOffersToWriteOnlyWhenThereIsSomethingToWrite() async throws {
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = FileManager.default.temporaryDirectory

        // A walk in hand: it writes.
        let learned = await self.model(walk: Self.walk(folders: ["Finance/US"]), syncManager: engine)
        #expect(learned.canWriteProfile)
        #expect(!learned.structureIsReadOnly)

        // A folder changed and not re-read: nothing to write, and nothing to show either.
        learned.invalidateProposals()
        #expect(!learned.canWriteProfile)
        #expect(learned.structureProfile == nil)

        // No engine at all — a layout fixture, and the case a disabled button is for.
        let bare = await self.model(walk: Self.walk(folders: ["Finance/US"]))
        #expect(!bare.canWriteProfile)
    }

    /// Seeding the root cannot throw away a reading that has finished.
    ///
    /// **The sheet re-seeds on every change to the provider list**, so this is not hypothetical:
    /// learn a folder, go Back to Locations and switch that location off, and `reconcilePrimary`
    /// moves the primary, `seedWalkRoot` finds a different path and `invalidateProposals` wipes the
    /// walk — with no screen saying so. Structure then reads "Nothing has been learned yet" over a
    /// tree the user watched being read a moment earlier.
    @Test func seedingTheRootKeepsAFinishedReading() async throws {
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Home/Water"]))
        #expect(model.walkState.isDone)
        let root = try #require(model.walkRoot)

        // What the sheet does when the provider list changes under it.
        model.reconcilePrimary()
        model.seedWalkRoot()

        #expect(model.walkState.isDone, "a finished reading was discarded by a re-seed")
        #expect(model.walkRoot == root, "the root moved out from under a finished reading")
        #expect(model.structureProfile != nil, "Structure has nothing to draw")
    }

    /// And it still seeds when there is nothing to lose — the case it exists for.
    @Test func seedingTheRootStillRunsBeforeAnythingIsRead() async {
        let model = await self.model()
        #expect(!model.walkState.isDone)
        model.reconcilePrimary()
        model.seedWalkRoot()
        #expect(model.walkRoot != nil, "the first screen never got a folder to offer")
    }

    /// A reading that lands while Structure is already on screen draws the tree it read.
    ///
    /// **Continue never waits**, so on a large tree Structure can open while the reading still
    /// runs. Arriving there was the only thing that rebuilt the preview, so the button turned into
    /// "Save and start reading" over "Nothing has been learned yet."
    @Test func aReadingThatLandsOnStructureDrawsItsTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-land-\(UUID().uuidString)")
        let documents = root.appendingPathComponent("Documents")
        for folder in ["Finance/US", "Family/Mother"] {
            try FileManager.default.createDirectory(at: documents.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = root.appendingPathComponent("profiles")

        let model = await self.model(syncManager: engine)
        model.walkRoot = documents
        model.screen = .structure
        model.startWalk()
        for _ in 0..<500 where !model.walkState.isDone && model.walkFailureReason == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.walkState.isDone, "premise: the reading landed (\(model.walkFailureReason ?? "still running"))")
        #expect(model.preview != nil, "Structure kept drawing “Nothing has been learned yet.”")
        #expect(model.canWriteProfile)
    }

    /// **A reading that lands before Structure builds no preview; one that lands after it does.**
    ///
    /// The rebuild is heavy main-actor work. On You or People — where a reading usually lands,
    /// Continue never waiting — it ran under the user's typing, for a tree arrival at Structure
    /// builds anyway. Past Structure it is the only rebuild: Workspaces reads the loose-file routes.
    @Test(.timeLimit(.minutes(1)))
    func aReadingRebuildsThePreviewOnlyWhereItIsRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-where-\(UUID().uuidString)")
        let documents = root.appendingPathComponent("Documents")
        for folder in ["Finance/US", "Family/Mother"] {
            try FileManager.default.createDirectory(at: documents.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: documents.appendingPathComponent("loose.pdf"))
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = root.appendingPathComponent("profiles")

        let early = await self.model(syncManager: engine)
        early.walkRoot = documents
        early.screen = .people
        early.startWalk()
        await early.lastWalk?.value
        #expect(early.walkState.isDone, "premise: the reading landed (\(early.walkFailureReason ?? "still running"))")
        #expect(early.preview == nil, "a reading landing on People built Structure's preview")
        early.screen = .countries
        #expect(early.advance(), "premise: Countries leads on")
        #expect(early.screen == .structure)
        #expect(early.preview != nil, "arrival at Structure no longer builds the preview")

        let late = await self.model(syncManager: engine)
        late.walkRoot = documents
        late.screen = .workspaces
        late.startWalk()
        await late.lastWalk?.value
        #expect(late.walkState.isDone)
        #expect(late.looseRoutes.count == 1,
                "a reading landing on Workspaces left it saying “No loose files” (\(late.looseRoutes.count) routes)")
    }

    /// **A reading of the old folder that lands after Change… is dropped.**
    ///
    /// Change… does not wait for the reading it supersedes. The late result landed as the reading
    /// of the new folder, and Learn's primary — Continue over a finished reading — kept the old
    /// folder's tree under the new folder's name.
    @Test(.timeLimit(.minutes(1)))
    func aReadingOfTheOldFolderThatLandsLateIsDropped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-late-\(UUID().uuidString)")
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        for folder in ["First/Finance/US", "First/Family/Mother", "Second/Taxes/2024"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = root.appendingPathComponent("profiles")

        let model = await self.model(syncManager: engine)
        model.walkRoot = first
        model.screen = .learn
        model.startWalk()
        // The test holds the main actor, so the reading cannot land before the folder changes.
        model.changeWalkRoot(to: second)
        await model.lastWalk?.value

        #expect(model.walkRoot == second, "premise: the folder changed")
        #expect(!model.walkState.isDone,
                "the reading of \(model.walkState.walk?.root.lastPathComponent ?? "?") landed as the reading of Second")
        #expect(model.learnPrimaryTitle == "Learn",
                "Learn offered \(model.learnPrimaryTitle) over a folder nobody has read")
    }

    /// **Skip during a reading stays skipped when the reading lands**, and of two readings of one
    /// folder only the later one lands.
    ///
    /// The landing guard checked the folder alone, so a Skip was overridden — Countries and
    /// Structure came back into a flow the user had just dropped them from — and Back to Learn
    /// again mid-reading had two walks land, each resetting the Countries ticks.
    @Test(.timeLimit(.minutes(1)))
    func onlyTheLatestAwaitedReadingLands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-gen-\(UUID().uuidString)")
        let documents = root.appendingPathComponent("Documents")
        for folder in ["Finance/US", "Family/Mother"] {
            try FileManager.default.createDirectory(at: documents.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = root.appendingPathComponent("profiles")

        // The test holds the main actor, so neither reading can land before the next step.
        let skipped = await self.model(syncManager: engine)
        skipped.changeWalkRoot(to: documents)
        skipped.screen = .learn
        skipped.startWalk()
        #expect(skipped.skip())
        await skipped.lastWalk?.value
        #expect(skipped.walkState == .skipped, "the reading landed over a Skip: \(skipped.walkState)")
        #expect(!skipped.crumbs.contains(.structure), "Structure came back after Skip")

        let twice = await self.model(syncManager: engine)
        twice.changeWalkRoot(to: documents)
        twice.startWalk()
        let first = try #require(twice.lastWalk)
        twice.startWalk()
        await first.value
        await twice.lastWalk?.value
        #expect(twice.walkState.isDone, "premise: the later reading landed")
        #expect(twice.readingNumber == 1, "\(twice.readingNumber) readings landed for one Learn")
    }

    /// And a reading kept in hand is Continue's only for the folder it read.
    @Test func continueIsOfferedOnlyForTheFolderTheReadingRead() async {
        let model = await self.model(walk: Self.walk(folders: ["Finance/US"]))
        model.screen = .learn
        #expect(model.learnPrimaryTitle == "Continue", "premise: a reading of the chosen folder")

        model.changeWalkRoot(to: URL(fileURLWithPath: "/tmp/Elsewhere"))
        #expect(model.learnPrimaryTitle == "Learn",
                "Continue would keep /tmp/Documents's tree under Elsewhere's name")
        #expect(model.learnAgainTitle == nil)
    }

    /// Learn's card names the location the chosen folder is in, measured from the folder.
    ///
    /// **It named the primary location whatever was picked**, so Change… to a folder outside every
    /// location read "in Google Drive" under its name. The outside folder is asked first, so the
    /// old answer — the primary's name — cannot pass it.
    @Test func learnsCardNamesTheLocationTheFolderIsIn() async {
        let model = await self.model()
        let drive = model.settings.enabledProviders.first {
            $0.rootPath.hasPrefix("/private/tmp/setup-model/GoogleDrive")
        }
        guard let drive else {
            Issue.record("premise: the fixture's Drive account is enabled")
            return
        }
        model.primarySourceId = drive.id

        model.changeWalkRoot(to: URL(fileURLWithPath: "/private/tmp/setup-model-elsewhere/Scans"))
        #expect(model.walkRootLocationLine == "on this Mac")

        model.changeWalkRoot(to: URL(fileURLWithPath: drive.rootPath + "/Documents/Taxes"))
        #expect(model.walkRootLocationLine == "in Google Drive")

        // A sibling that only shares the root's string prefix is not inside it.
        model.changeWalkRoot(to: URL(fileURLWithPath: drive.rootPath + "-old/Taxes"))
        #expect(model.walkRootLocationLine == "on this Mac")
    }

    // MARK: - People

    /// The ✕ on a person who was already on the roster asks first; one added in this run does not.
    ///
    /// **On a re-run the chips are the real `people.json`.** One click on the 10pt ✕ deleted a
    /// person along with the full names and aliases curated for them in Settings, where the same
    /// removal asks first.
    @Test func removingARosterPersonAsksFirst() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "remove", profile: nil)
        store.add(displayName: "Maya")
        let model = SetupModel(settings: await settings(), peopleStore: store, syncManager: nil,
                               hasFilingProfile: true, defaults: ScratchDefaults("setup-model-d"),
                               walk: nil)
        #expect(model.rosterNames == ["Maya"], "premise: the roster is what the chips show")

        model.requestRemovePerson(named: "Maya")
        #expect(model.personAwaitingRemoval == "Maya", "nothing asked")
        #expect(store.people.map(\.displayName) == ["Maya"], "removed before the answer")

        model.personAwaitingRemoval = nil
        model.newPersonField = "Ravi"
        model.commitTypedPerson()
        model.requestRemovePerson(named: "Ravi")
        #expect(model.personAwaitingRemoval == nil, "a name added a moment ago asked first")
        #expect(store.people.map(\.displayName) == ["Maya"])
    }

    /// **A person removed on People after a first-run Save stays removed.**
    ///
    /// Save lands the draft in the roster it creates, but the draft in memory still named them, so
    /// leaving People applied it again and the person came back.
    @Test func aPersonRemovedAfterAFirstRunSaveStaysRemoved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-unremove-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let draftURL = root.appendingPathComponent("setup-draft.json")
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let model = SetupModel(settings: await settings(), peopleStore: nil, syncManager: engine,
                               hasFilingProfile: false, defaults: ScratchDefaults("setup-model-d"),
                               walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                               draftURL: draftURL,
                               onProfileWritten: {
                                   // What `FilingArtifacts.attach` does, pointed at the scratch folder.
                                   guard let id = FilingProfileStore.activeProfileId(in: profiles) else { return }
                                   engine.filingPeopleStore = PeopleStore(directory: profiles,
                                                                          profileId: id, profile: nil)
                               })
        model.screen = .people
        model.newPersonField = "Maya"
        model.commitTypedPerson()
        #expect(model.draft.others.map(\.displayName) == ["Maya"], "premise: Maya is in the draft")
        #expect(FileManager.default.fileExists(atPath: draftURL.path), "premise: the draft was written")

        #expect(await model.save(), "premise: the Save wrote")
        let store = try #require(model.roster, "premise: the Save attached a roster")
        #expect(store.people.map(\.displayName) == ["Maya"], "premise: the draft landed")

        model.screen = .people
        model.requestRemovePerson(named: "Maya")
        #expect(model.personAwaitingRemoval == "Maya", "premise: a roster person asks first")
        model.personAwaitingRemoval = nil
        model.removePerson(named: "Maya")
        #expect(store.people.isEmpty, "premise: Maya left the roster")

        _ = model.advance()
        model.applyDraftIfPossible()   // what finishing does
        #expect(store.people.isEmpty,
                "Maya came back: \(store.people.map(\.displayName)) — the draft re-applied her")
        #expect(model.draft.others.isEmpty)
    }

    // MARK: - Saving

    /// Two presses write one profile.
    ///
    /// **And the second press must not break the first.** Both presses mint their id before either
    /// has written anything, so inside one second they mint the *same* id — and the store refuses
    /// over an id that now exists. The count on disk therefore stays at one either way; what the
    /// guard actually saves is the model, which without it takes the refusal as a failed walk and
    /// throws away a profile that had just been written successfully.
    @Test func twoSavesAtOnceWriteOneProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-save-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)

        async let first = model.save()
        async let second = model.save()
        let wrote = await [first, second]

        let written = try FileManager.default.contentsOfDirectory(atPath: profiles.path)
            .filter { $0.hasPrefix("walk-") }
        #expect(written.count == 1, "two presses wrote \(written.count) profiles: \(written)")
        #expect(model.walkState.isDone,
                "the second press was let through and its refusal was recorded as a failed walk, over a profile that had just been written")
        #expect(model.walkFailureReason == nil)
        #expect(model.saveFailure == nil, "the refused second press was reported as a failed write")
        #expect(wrote.filter { $0 }.count == 1,
                "\(wrote) — the refused press answered that it wrote, and Save would move the sheet on twice")
        #expect(!model.isSaving, "the flag was not cleared, so the button would stay dead")
        #expect(model.writtenReport != nil)
    }

    /// **A failed write stays on Structure, keeps the reading, and says it was the write.**
    ///
    /// It used to move on regardless and record the failure as a failed walk: the tree was thrown
    /// away, Summary said nothing had been learned, and the reason sat on People and Countries —
    /// screens already behind — headed "Couldn't read that folder".
    @Test func aFailedSaveStaysOnStructureAndKeepsTheReading() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-savefail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file where the profiles folder's parent should be: nothing can be written.
        let blocker = root.appendingPathComponent("blocker")
        try Data("not a folder".utf8).write(to: blocker)
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = blocker.appendingPathComponent("profiles")

        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)
        model.screen = .structure
        await model.saveAndContinue()

        #expect(model.screen == .structure, "a failed write moved the sheet on to \(model.screen)")
        #expect(model.walkState.isDone, "the reading was thrown away over a failed write")
        #expect(model.walkFailureReason == nil,
                "a failed write was recorded as a failed reading — People would say “Couldn't read that folder”")
        let failure = try #require(model.saveFailure, "nothing on Structure says the write failed")
        // A sentence under the heading, not the log's words or an NSError dump.
        #expect(!failure.contains("could not be written —") && !failure.contains("Error Domain"),
                "Structure shows the log's words: \(failure)")
        #expect(model.writtenReport == nil)
        #expect(model.structureSecondaryTitle == "Continue without saving",
                "a Save that keeps failing leaves Structure with no way on")

        // And the same press, once the write can succeed, moves on and clears the line.
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: engine.filingProfilesDirectory!,
                                                withIntermediateDirectories: true)
        await model.saveAndContinue()
        #expect(model.writtenReport != nil, "premise: the second press wrote")
        #expect(model.screen == .workspaces)
        #expect(model.saveFailure == nil)
        #expect(model.structureSecondaryTitle == nil, "Continue without saving outlived the failure")
    }

    /// A model on Structure whose Save has failed once, against a profiles folder that cannot be
    /// written — and the blocker to remove when the write should succeed.
    private func failedSave(_ tag: String) async throws -> (model: SetupModel, root: URL, blocker: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try Data("not a folder".utf8).write(to: blocker)
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = blocker.appendingPathComponent("profiles")
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)
        model.screen = .structure
        await model.saveAndContinue()
        #expect(model.saveFailure != nil, "premise: the first Save failed")
        return (model, root, blocker)
    }

    /// Starts a Save and returns once it is writing — the state the window shows mid-press.
    private func startSaving(_ model: SetupModel) async throws -> Task<Void, Never> {
        let press = Task { await model.saveAndContinue() }
        for _ in 0..<1000 where !model.isSaving { await Task.yield() }
        #expect(model.isSaving, "premise: the Save is in flight")
        return press
    }

    /// **A retry keeps the last failure on screen while it writes.** It was cleared before the
    /// write, so Structure jumped and Continue without saving vanished for the length of the press.
    @Test(.timeLimit(.minutes(1)))
    func aRetryKeepsTheFailureUpWhileItWrites() async throws {
        let (model, root, _) = try await failedSave("retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let press = try await startSaving(model)
        #expect(model.saveFailure != nil, "the failure line was cleared before the retry finished")
        #expect(model.structureSecondaryTitle != nil,
                "Continue without saving left the footer while the retry wrote")
        await press.value
    }

    /// **Back is refused while Save writes, and a Save that lands off Structure moves nothing.**
    ///
    /// The press advanced from whatever screen was current when it landed, so Back mid-write left
    /// for Countries and was carried straight back to Structure.
    @Test(.timeLimit(.minutes(1)))
    func backIsRefusedWhileSaveWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-backsave-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles

        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)
        model.screen = .structure
        #expect(model.canGoBack, "premise: Back is offered on Structure")
        var press = try await startSaving(model)
        #expect(!model.canGoBack, "Back is offered while Save writes")
        model.retreat()
        #expect(model.screen == .structure, "Back left Structure mid-write, for \(model.screen)")
        await press.value
        #expect(model.screen == .workspaces, "premise: the Save moved on")

        // However the sheet left Structure, a Save that lands elsewhere does not move it.
        model.toggleCountry("IN")
        model.screen = .structure
        press = try await startSaving(model)
        model.screen = .countries
        await press.value
        #expect(model.writtenReport != nil)
        #expect(model.screen == .countries, "a Save landing on Countries carried it to \(model.screen)")
    }

    /// **Continue without saving moves on and writes nothing** — offered only after a failed Save.
    @Test func continuingWithoutSavingMovesOnAndWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-nosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("blocker")
        try Data("not a folder".utf8).write(to: blocker)
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = blocker.appendingPathComponent("profiles")

        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)
        model.screen = .structure
        #expect(model.structureSecondaryTitle == nil, "offered before any Save had failed")
        await model.saveAndContinue()
        #expect(model.structureSecondaryTitle != nil, "premise: the Save failed")

        model.continueWithoutSaving()
        #expect(model.screen == .workspaces, "Continue without saving stayed on \(model.screen)")
        #expect(model.writtenReport == nil)
        #expect(model.saveFailure == nil, "the failure line followed the sheet off Structure")
    }

    /// **A reading Save has written is not written again.**
    ///
    /// Summary's Learn leads back through Structure, and its button still said "Save and start
    /// reading": a second press wrote a second profile from the same tree, and asked for a second
    /// reading of the documents.
    @Test func aWrittenReadingIsNotOfferedForSavingAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-twice-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)
        #expect(model.canWriteProfile, "premise: a reading to write")
        #expect(await model.save(), "premise: the first Save wrote")

        #expect(!model.canWriteProfile,
                "Structure would offer “Save and start reading” over a reading already written")
        #expect(await model.save() == false, "a second Save of the same reading was let through")
        let written = try FileManager.default.contentsOfDirectory(atPath: profiles.path)
            .filter { $0.hasPrefix("walk-") }
        #expect(written.count == 1, "one reading wrote \(written.count) profiles: \(written)")

        // A new reading is a new thing to write.
        model.adopt(Self.walk(folders: ["Taxes/2024"]))
        #expect(model.canWriteProfile, "a fresh reading could not be saved")
    }

    /// **A country changed after Save is written by a second Save** — and the documents are not
    /// read a second time.
    ///
    /// The reading counted as written whatever the ticks said, so going back to Countries after a
    /// Save left Structure on Continue: Summary listed the new countries and the profile on disk
    /// held the old ones.
    @Test func aCountryChangedAfterSaveIsSavedAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-recountry-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        var started: [URL] = []
        let model = SetupModel(settings: await settings(), peopleStore: nil, syncManager: engine,
                               hasFilingProfile: false, defaults: ScratchDefaults("setup-model-d"),
                               walk: Self.walk(folders: ["Finance/US/2024", "Finance/IN/2024"]),
                               onStartSurvey: { started.append($0) })
        model.confirmedCountries = ["US"]
        #expect(model.structurePrimaryTitle == "Save and start reading")
        #expect(await model.save(), "premise: the first Save wrote")
        let first = try #require(model.writtenReport?.profileId)
        #expect(started.count == 1, "premise: the first Save started the reading")

        // Unchanged: nothing to write.
        #expect(!model.canWriteProfile)
        #expect(model.structurePrimaryTitle == "Continue")

        // A tick changed: Save is offered again, and writes the new countries.
        model.toggleCountry("IN")
        #expect(model.canWriteProfile,
                "a changed country left Structure on Continue over a profile that does not hold it")
        #expect(model.structurePrimaryTitle == "Save",
                "the second Save says it starts a reading the first one already started")
        #expect(await model.save(), "the second Save wrote nothing")
        let second = try #require(model.writtenReport?.profileId)
        #expect(second != first, "the changed countries did not write a new profile")
        let written = try #require(FilingProfileStore.profile(id: second, in: profiles))
        #expect(written.folders["Finance/IN"]?.axes["jurisdiction"] == "IN",
                "the profile the second Save wrote does not hold IN")
        #expect(started.count == 1, "the second Save started reading the same folder again: \(started)")
        #expect(!model.canWriteProfile, "the second Save's answers are still offered for saving")
    }

    // MARK: - Back to Learn

    /// **Over a finished reading, Learn's primary is Continue, and it keeps the reading.**
    ///
    /// The primary was "Learn again", so going Back to Learn left only a re-read — which resets the
    /// Countries ticks to the rule's picks — or Skip, which throws the reading away.
    @Test func continueOverAFinishedReadingKeepsIt() async throws {
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = FileManager.default.temporaryDirectory
        let fresh = await self.model(syncManager: engine)
        #expect(fresh.learnPrimaryTitle == "Learn")
        #expect(fresh.learnAgainTitle == nil, "Learn again is offered with nothing to read again")

        let model = await self.model(walk: Self.walk(folders: ["Finance/US/2024", "Legal/US/2024"]),
                                     syncManager: engine)
        // A tick the rule would not have made: a re-read would reset it.
        model.confirmedCountries = ["US", "IN"]
        model.screen = .learn
        #expect(model.learnPrimaryTitle == "Continue")
        #expect(model.learnAgainTitle == "Learn again")

        model.pressLearnPrimary()
        #expect(model.screen == .you)
        #expect(model.walkState.isDone, "Continue started a new reading (\(model.walkState))")
        #expect(model.confirmedCountries == ["US", "IN"], "the hand-set ticks were reset")
    }

    /// And Learn again still reads the folder afresh, and moves on without waiting.
    @Test func learnAgainReadsAfreshAndMovesOn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-again-\(UUID().uuidString)")
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents.appendingPathComponent("Finance/US"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = root.appendingPathComponent("profiles")

        let model = await self.model(walk: Self.walk(folders: ["Finance/US"]), syncManager: engine)
        model.walkRoot = documents
        model.screen = .learn
        model.pressLearnAgain()
        #expect(model.walkState == .running, "Learn again did not start a reading")
        #expect(model.screen == .you, "Learn again waited for the reading")
        // Let it land inside the fixture before the folder is removed.
        for _ in 0..<500 where model.walkState.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.walkState.isRunning, "the reading never finished")
    }

    /// **Summary's Learn goes back to Learn, with the sheet still open.** It used to close setup
    /// on a Settings tab that has no control to learn a folder with.
    @Test func summarysLearnReturnsToTheLearnScreen() async {
        let model = await self.model(walk: Self.walk(folders: ["Finance/US"]))
        model.screen = .summary
        model.returnToLearn()
        #expect(model.screen == .learn)
        #expect(model.walkState.isDone, "the reading was dropped on the way back")
    }

    /// **Summary describes what Save wrote, not the reading in hand.**
    ///
    /// A reading continued past without saving read "Learned", and a profile written earlier in the
    /// run read "not learned" once Learn was skipped on the way back.
    @Test func summarySaysWhatWasWritten() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-summary-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)
        model.confirmedCountries = ["US"]

        #expect(SummaryScreen.folderLine(for: model) == "Read Documents — not saved")
        #expect(SummaryScreen.countriesLine(for: model) == "Countries: US — not saved")

        #expect(await model.save(), "premise: the Save wrote")
        let saved = SummaryScreen.folderLine(for: model)
        #expect(saved.hasPrefix("Learned: Documents, "), "after Save: \(saved)")
        #expect(SummaryScreen.countriesLine(for: model) == "Countries: US")

        // Back to Learn and Skip: the profile on disk is still learned, with what it holds.
        model.screen = .learn
        #expect(model.skip())
        #expect(SummaryScreen.folderLine(for: model) == saved,
                "a written profile reads “\(SummaryScreen.folderLine(for: model))” after Skip")
        #expect(SummaryScreen.countriesLine(for: model) == "Countries: US")

        // And the screen draws these rules, not a copy of them.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/Setup/SummaryScreen.swift"), encoding: .utf8)
        #expect(source.contains("row(\"folder\", Self.folderLine(for: model),"))
        #expect(source.contains("if let countries = Self.countriesLine(for: model) {"))
    }

    /// Saves a walk into a fresh profiles folder — holding a hand-built profile first, when asked
    /// to — and answers which folders the reading was started on.
    private func save(besideAHandBuiltProfile: Bool) async throws -> (model: SetupModel, started: [URL], walk: SetupWalk) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-read-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if besideAHandBuiltProfile {
            _ = try FilingProfileStore.writeProfile(
                FolderProfile(profileId: "hand", root: "/Volumes/Archive/Docs",
                              folders: ["Finance": FolderProfileEntry(
                                path: "Finance", role: nil, naming: nil, anchors: [],
                                acceptsNewFiles: nil, fileCount: 1, subfolderCount: 0, axes: [:])],
                              personTokens: []),
                in: profiles, builtBy: "hand — setup-read fixture")
        }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let walk = Self.walk(folders: ["Finance/US", "Family/Mother"])
        var started: [URL] = []
        let model = SetupModel(settings: await settings(), peopleStore: nil, syncManager: engine,
                               hasFilingProfile: besideAHandBuiltProfile,
                               defaults: ScratchDefaults("setup-model-d"), walk: walk,
                               onStartSurvey: { started.append($0) })
        #expect(model.readDocuments, "premise: reading the documents was asked for")
        await model.save()
        #expect(model.writtenReport != nil, "premise: the walk's profile was written")
        return (model, started, walk)
    }

    /// **Setup reads the documents of the profile it wrote — so not when that profile is unused.**
    ///
    /// Beside a hand-built profile the walk's is saved and left unused, and the summary says so.
    /// The reading went ahead anyway, and a reading covers the profile in use: hours spent on a
    /// folder this run of setup never pointed at, or a refusal saying those documents had been
    /// read already — neither of them what "Save and start reading" offered.
    @Test func aWalkThatIsNotInUseStartsNoReading() async throws {
        let (model, started, _) = try await save(besideAHandBuiltProfile: true)
        #expect(model.walkNotInUse, "premise: the hand-built profile stayed in use")
        #expect(started.isEmpty, "started reading \(started) for a profile this Mac does not use")
    }

    /// And the case it exists for: a walk that became the profile in use starts the reading, on
    /// the folder it learned.
    @Test func aWalkThatIsInUseStartsTheReadingOnItsFolder() async throws {
        let (model, started, walk) = try await save(besideAHandBuiltProfile: false)
        #expect(!model.walkNotInUse)
        #expect(started == [walk.root])
    }
}
