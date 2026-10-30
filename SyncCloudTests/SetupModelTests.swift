import Foundation
import Settings
import SwiftUI
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
                   walk: walk, draftURL: nil)
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
    /// "Save and Start Reading" over "Nothing has been learned yet."
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
    @Test(.timeLimit(.minutes(2)))
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
    @Test(.timeLimit(.minutes(2)))
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
    @Test(.timeLimit(.minutes(2)))
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
                               walk: nil, draftURL: nil)
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

    // MARK: - Closing

    /// **Closing keeps the open screen's answers, as a screen change does** (ST4).
    ///
    /// Esc, ✕ and a click outside committed nothing, so a name typed on You and closed was gone,
    /// while the same name with Continue pressed first was in the draft. Asked of the draft on disk,
    /// in a scratch folder — never the real `setup-draft.json` — because the draft is what the next
    /// open reads. Nothing marks setup finished: the model never touches that key.
    @Test func closingKeepsTheOpenScreensAnswers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let draftURL = root.appendingPathComponent("setup-draft.json")
        let defaults = ScratchDefaults("setup-model-close")
        let model = SetupModel(settings: await settings(), peopleStore: nil, syncManager: nil,
                               hasFilingProfile: false, defaults: defaults,
                               startScreen: .you, draftURL: draftURL)
        model.firstName = "Maya"
        #expect(SetupDraftStore.read(at: draftURL) == nil, "premise: nothing is written while typing")

        model.commitBeforeClosing()

        let stored = try #require(SetupDraftStore.read(at: draftURL), "closing wrote no draft")
        #expect(stored.yourName == "Maya", "closing dropped the name typed on You")
        #expect(model.screen == .you, "closing moved the sheet")
        #expect(!defaults.bool(forKey: SetupFlow.hasCompletedDefaultsKey),
                "closing marked setup finished")
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
        #expect(model.structureSecondaryTitle == "Continue Without Saving",
                "a Save that keeps failing leaves Structure with no way on")

        // And the same press, once the write can succeed, moves on and clears the line.
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: engine.filingProfilesDirectory!,
                                                withIntermediateDirectories: true)
        await model.saveAndContinue()
        #expect(model.writtenReport != nil, "premise: the second press wrote")
        #expect(model.screen == .workspaces)
        #expect(model.saveFailure == nil)
        #expect(model.structureSecondaryTitle == nil, "Continue Without Saving outlived the failure")
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

    /// Holds a press at `SetupModel.saveInFlight` until the test lets it go.
    @MainActor private final class SaveGate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        var parked: Bool { waiter != nil }
        func park() async {
            guard !opened else { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// Starts a Save and returns once it is parked mid-write — the state the window shows
    /// mid-press — with the gate that lets it finish. Open the gate before awaiting the press.
    ///
    /// It used to start the press and poll `isSaving`, which on a 3-vCPU hosted VM missed the whole
    /// press about one run in four: the diagnostic said "the press had already finished" every time.
    private func startSaving(_ model: SetupModel) async throws -> (press: Task<Void, Never>, gate: SaveGate) {
        let gate = SaveGate()
        model.saveInFlight = { await gate.park() }
        let press = Task { await model.saveAndContinue() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !gate.parked, ContinuousClock.now < deadline { await Task.yield() }
        #expect(gate.parked && model.isSaving, "premise: the Save is parked in flight")
        return (press, gate)
    }

    /// **A retry keeps the last failure on screen while it writes.** It was cleared before the
    /// write, so Structure jumped and Continue Without Saving vanished for the length of the press.
    @Test(.timeLimit(.minutes(2)))
    func aRetryKeepsTheFailureUpWhileItWrites() async throws {
        let (model, root, _) = try await failedSave("retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let (press, gate) = try await startSaving(model)
        #expect(model.saveFailure != nil, "the failure line was cleared before the retry finished")
        #expect(model.structureSecondaryTitle != nil,
                "Continue Without Saving left the footer while the retry wrote")
        gate.open()
        await press.value
    }

    /// **Back is refused while Save writes, and a Save that lands off Structure moves nothing.**
    ///
    /// The press advanced from whatever screen was current when it landed, so Back mid-write left
    /// for Countries and was carried straight back to Structure.
    @Test(.timeLimit(.minutes(2)))
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
        var (press, gate) = try await startSaving(model)
        #expect(!model.canGoBack, "Back is offered while Save writes")
        model.retreat()
        #expect(model.screen == .structure, "Back left Structure mid-write, for \(model.screen)")
        gate.open()
        await press.value
        #expect(model.screen == .workspaces, "premise: the Save moved on")

        // However the sheet left Structure, a Save that lands elsewhere does not move it.
        model.toggleCountry("IN")
        model.screen = .structure
        (press, gate) = try await startSaving(model)
        model.screen = .countries
        gate.open()
        await press.value
        #expect(model.writtenReport != nil)
        #expect(model.screen == .countries, "a Save landing on Countries carried it to \(model.screen)")
    }

    /// **Continue Without Saving moves on and writes nothing** — offered only after a failed Save.
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
        #expect(model.screen == .workspaces, "Continue Without Saving stayed on \(model.screen)")
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
                "Structure would offer “Save and Start Reading” over a reading already written")
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
                               walk: Self.walk(folders: ["Finance/US/2024", "Finance/IN/2024"]), draftURL: nil,
                               onStartSurvey: { started.append($0) })
        model.confirmedCountries = ["US"]
        #expect(model.structurePrimaryTitle == "Save and Start Reading")
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

    // MARK: - Structure over a reading still running

    /// **While the reading runs, Structure's button is Skip Saving; once it lands, Save** (SR5).
    ///
    /// Continue never waits, so Structure opens before a big tree's reading lands. Its button said
    /// Continue — a press that drops the reading — over "Nothing has been learned yet".
    @Test func structuresButtonSaysSkipSavingUntilTheReadingLands() async throws {
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = FileManager.default.temporaryDirectory
        let model = await self.model(syncManager: engine)
        model.screen = .structure
        #expect(model.structurePrimaryTitle == "Continue", "premise: nothing read, nothing running")

        model.walkState = .running
        #expect(model.structureAwaitsReading)
        #expect(model.structurePrimaryTitle == "Skip Saving",
                "a reading in progress is offered as \(model.structurePrimaryTitle)")
        #expect(!model.canWriteProfile, "a reading in progress offered to write")

        model.adopt(Self.walk(folders: ["Finance/US", "Family/Mother"]))
        #expect(!model.structureAwaitsReading)
        #expect(model.structureShownProfile != nil, "the landed reading draws no tree")

        // Learn Again over that reading: the old tree is not offered as the new reading.
        model.walkState = .running
        #expect(model.structureProfile != nil, "premise: the last reading's preview is still built")
        #expect(model.structureShownProfile == nil,
                "Structure draws the last reading's tree while the new one runs")
        model.adopt(Self.walk(folders: ["Finance/US", "Family/Mother"]))
        #expect(model.structurePrimaryTitle == "Save and Start Reading",
                "the landed reading is offered as \(model.structurePrimaryTitle)")
    }

    /// **On a re-run, a reading in progress is not passed off as the profile already here.**
    ///
    /// With no reading in hand Structure shows this Mac's own profile, read-only. While a new
    /// reading runs it says it is reading instead.
    @Test func aReadingInProgressHidesTheProfileAlreadyHere() async throws {
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = FileManager.default.temporaryDirectory
        engine.filingFolderProfile = FileSyncManager.previewProfile(
            walk: Self.walk(folders: ["Finance/US"]), registry: nil, jurisdictionValues: [])
        let model = await self.model(syncManager: engine)
        model.screen = .structure
        #expect(model.structureIsReadOnly, "premise: the re-run shows this Mac's profile")
        #expect(model.structureShownProfile != nil, "premise: and draws it")

        model.walkState = .running
        #expect(!model.structureIsReadOnly, "a reading in progress is called the profile already here")
        #expect(model.structureShownProfile == nil, "the old profile is drawn while the reading runs")
        #expect(model.structurePrimaryTitle == "Skip Saving")
    }

    /// **Skip Saving moves on without waiting, and writes nothing** — as Continue did.
    @Test func skipSavingMovesOnAndWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-skipsave-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let model = await self.model(syncManager: engine)
        model.screen = .structure
        model.walkState = .running

        await model.pressStructurePrimary(shownSkipSaving: model.structurePrimaryTitle == SetupModel.skipSavingTitle)

        #expect(model.screen == .workspaces, "Skip Saving stayed on \(model.screen)")
        #expect(model.walkState.isRunning, "Skip Saving stopped the reading")
        #expect(try FileManager.default.contentsOfDirectory(atPath: profiles.path).isEmpty,
                "Skip Saving wrote a profile")
    }

    /// And once the reading has landed, the same press saves.
    @Test func structuresPressSavesOnceTheReadingLands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-pressave-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)
        model.readDocuments = false
        model.screen = .structure

        await model.pressStructurePrimary(shownSkipSaving: model.structurePrimaryTitle == SetupModel.skipSavingTitle)

        #expect(model.writtenReport != nil, "the press over a landed reading wrote nothing")
        #expect(model.screen == .workspaces)
    }

    /// **A press made under Skip Saving moves on without saving, even if the reading has landed
    /// since** (SR5).
    ///
    /// The sheet runs the press in a `Task`, so a reading that lands on the main actor between the
    /// render that drew "Skip Saving" and the press used to make it a Save — with the switch on,
    /// Save and Start Reading: hours of reading under a button that said it would skip.
    @Test func aPressUnderSkipSavingNeverSavesTheReadingThatLandedSince() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-skiprace-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        var started: [URL] = []
        let model = SetupModel(settings: await settings(), peopleStore: nil, syncManager: engine,
                               hasFilingProfile: false, defaults: ScratchDefaults("setup-model-d"),
                               startScreen: .structure, draftURL: nil,
                               onStartSurvey: { started.append($0) })
        model.walkState = .running
        let drawn = model.structurePrimaryTitle
        #expect(drawn == "Skip Saving", "premise: the button was drawn as Skip Saving")

        // The reading lands after the button was drawn and before the press runs.
        model.adopt(Self.walk(folders: ["Finance/US", "Family/Mother"]))
        #expect(model.structurePrimaryTitle == "Save and Start Reading",
                "premise: a press decided now would save and start reading")

        await model.pressStructurePrimary(shownSkipSaving: drawn == SetupModel.skipSavingTitle)

        #expect(model.screen == .workspaces, "Skip Saving stayed on \(model.screen)")
        #expect(model.writtenReport == nil, "a press under Skip Saving saved")
        #expect(try FileManager.default.contentsOfDirectory(atPath: profiles.path).isEmpty,
                "a press under Skip Saving wrote a profile")
        #expect(started.isEmpty, "a press under Skip Saving started reading the documents")
    }

    // MARK: - Structure over a reading that failed

    /// **A reading that fails on Structure is said there** (SR5).
    ///
    /// The "Reading names…" line went, and Structure showed "Nothing has been learned yet", this
    /// Mac's profile read-only, or — after Learn Again — the last reading's tree under "SyncCloud
    /// read this from …". None said it failed. Now the walk's status line stands in the tree's box,
    /// the counts are dashes, the switch is off limits, and the button is Continue: nothing to
    /// save, nothing pending to skip.
    @Test func aReadingThatFailsOnStructureIsSaidThere() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-failed-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let model = SetupModel(settings: await settings(), peopleStore: nil, syncManager: engine,
                               hasFilingProfile: false, defaults: ScratchDefaults("setup-model-d"),
                               walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                               startScreen: .structure, draftURL: nil)
        #expect(model.structureShownProfile != nil, "premise: the landed reading draws its tree")

        // Learn Again, and the new reading fails while Structure is on screen.
        model.walkState = .running
        model.walkState = .failed("The folder could not be read.")
        #expect(model.structureProfile != nil, "premise: the last reading's preview is still built")
        #expect(model.structureShowsWalkStatus, "a failed reading is not said on Structure")
        #expect(model.structureShownProfile == nil,
                "Structure draws the last reading's tree over the one that failed")
        #expect(!model.structureIsReadOnly)
        #expect(model.structurePrimaryTitle == "Continue",
                "a failed reading is offered as \(model.structurePrimaryTitle)")
        #expect(StructureScreen.counts(model)
                    == .init(folders: nil, files: nil, loose: nil, people: 0, countries: nil),
                "Structure counts a reading that failed")
        #expect(!model.structureReadingSwitchIsEnabled,
                "the reading switch offers a reading after a Save that cannot happen")

        await model.pressStructurePrimary(shownSkipSaving: false)
        #expect(model.screen == .workspaces, "Continue stayed on \(model.screen)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: profiles.path).isEmpty,
                "Continue over a failed reading wrote a profile")
    }

    /// On a re-run, a failed reading is said rather than passing this Mac's profile off as it.
    @Test func aFailedReadingHidesTheProfileAlreadyHere() async throws {
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = FileManager.default.temporaryDirectory
        engine.filingFolderProfile = FileSyncManager.previewProfile(
            walk: Self.walk(folders: ["Finance/US"]), registry: nil, jurisdictionValues: [])
        let model = await self.model(syncManager: engine)
        model.screen = .structure
        #expect(model.structureIsReadOnly, "premise: the re-run shows this Mac's profile")

        model.walkState = .failed("The folder could not be read.")
        #expect(!model.structureIsReadOnly, "a failed reading is called the profile already here")
        #expect(model.structureShownProfile == nil, "the old profile is drawn over the failed reading")
    }

    /// **While the reading runs, Structure counts nothing and the switch waits** (SR5).
    ///
    /// The stats row said 0 folders and 0 files — or, after Learn Again, the last reading's counts —
    /// and the "Read documents" switch stayed live with a tooltip about what happens after a Save
    /// the screen could not make. The people are the roster's either way, so they stay.
    @Test func whileTheReadingRunsStructureCountsNothingAndTheSwitchWaits() async throws {
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = FileManager.default.temporaryDirectory
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine)
        model.screen = .structure
        model.draft.others = [SetupDraft.DraftPerson(displayName: "Maya")]
        let landed = StructureScreen.counts(model)
        #expect((landed.folders ?? 0) > 0 && landed.people == 1,
                "premise: the landed reading has counts to hide")
        #expect(model.structureReadingSwitchIsEnabled, "premise: the switch is live over a reading")

        // Learn Again: the last reading's counts must not stand for the new one.
        model.walkState = .running
        #expect(StructureScreen.counts(model)
                    == .init(folders: nil, files: nil, loose: nil, people: 1, countries: nil),
                "Structure counts a reading still running")
        #expect(!model.structureReadingSwitchIsEnabled,
                "the reading switch is live while the reading runs")
    }

    // MARK: - Back to Learn

    /// **Over a finished reading, Learn's primary is Continue, and it keeps the reading.**
    ///
    /// The primary was "Learn Again", so going Back to Learn left only a re-read — which resets the
    /// Countries ticks to the rule's picks — or Skip, which throws the reading away.
    @Test func continueOverAFinishedReadingKeepsIt() async throws {
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = FileManager.default.temporaryDirectory
        let fresh = await self.model(syncManager: engine)
        #expect(fresh.learnPrimaryTitle == "Learn")
        #expect(fresh.learnAgainTitle == nil, "Learn Again is offered with nothing to read again")

        let model = await self.model(walk: Self.walk(folders: ["Finance/US/2024", "Legal/US/2024"]),
                                     syncManager: engine)
        // A tick the rule would not have made: a re-read would reset it.
        model.confirmedCountries = ["US", "IN"]
        model.screen = .learn
        #expect(model.learnPrimaryTitle == "Continue")
        #expect(model.learnAgainTitle == "Learn Again")

        model.pressLearnPrimary()
        #expect(model.screen == .you)
        #expect(model.walkState.isDone, "Continue started a new reading (\(model.walkState))")
        #expect(model.confirmedCountries == ["US", "IN"], "the hand-set ticks were reset")
    }

    /// And Learn Again still reads the folder afresh, and moves on without waiting.
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
        #expect(model.walkState == .running, "Learn Again did not start a reading")
        #expect(model.screen == .you, "Learn Again waited for the reading")
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
                               defaults: ScratchDefaults("setup-model-d"), walk: walk, draftURL: nil,
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
    /// read already — neither of them what "Save and Start Reading" offered.
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

    // MARK: - Review of the v6.1 Setup work, 2026-10-27

    /// **Learn pressed while the folder is still being read starts no second reading.** Back to
    /// Learn mid-reading still says Learn, and its press walked the same tree again beside the
    /// first walk, which nothing cancels.
    @Test(.timeLimit(.minutes(2)))
    func learnWhileTheFolderIsBeingReadReadsItOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-learn-twice-\(UUID().uuidString)")
        let documents = root.appendingPathComponent("Documents")
        for folder in ["Finance/US", "Family/Mother"] {
            try FileManager.default.createDirectory(at: documents.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = root.appendingPathComponent("profiles")
        let model = await self.model(syncManager: engine)
        model.changeWalkRoot(to: documents)
        model.screen = .learn
        // The test holds the main actor, so the reading cannot land before the second press.
        model.pressLearnPrimary()
        let first = try #require(model.lastWalk, "premise: Learn started a reading")
        #expect(model.walkState.isRunning)
        model.screen = .learn
        #expect(model.learnPrimaryTitle == "Learn", "premise: Learn mid-reading still says Learn")

        model.pressLearnPrimary()

        #expect(model.lastWalk == first, "the second press started a second walk of the same folder")
        await first.value
        #expect(model.walkState.isDone, "the reading under way was dropped")
    }

    /// **Closing Setup after editing your name renames your record, rather than adding a second
    /// "me"** (review M5). People hides "me", so the duplicate showed nowhere. The old name stays as
    /// an alias, so the folders that call you by it still do.
    @Test func editingYourNameAndClosingRenamesYourRecord() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-rename-me-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeopleStore(directory: dir, profileId: "rename", profile: nil)
        store.add(displayName: "Abhishek", relationship: "me")
        store.add(displayName: "Maya", relationship: "wife")
        let id = try #require(store.people.first { $0.relationship == "me" }?.id)
        let model = SetupModel(settings: await settings(), peopleStore: store, syncManager: nil,
                               hasFilingProfile: true, defaults: ScratchDefaults("setup-model-d"),
                               startScreen: .you, draftURL: nil)
        model.onOpen()
        #expect(model.draft.yourName == "Abhishek", "premise: You opens on the roster's name")

        model.firstName = "Abhi"
        model.surname = ""
        model.commitBeforeClosing()

        let mine = store.people.filter { PeopleOrder.tier(of: $0.relationship) == .yourself }
        #expect(mine.count == 1, "closing left \(mine.map(\.displayName)) all marked as you")
        #expect(mine.first?.id == id, "your record was replaced, not renamed")
        #expect(mine.first?.displayName == "Abhi")
        #expect(mine.first?.aliases.contains("Abhishek") == true,
                "the old name was dropped, so folders named for it no longer find you")
        #expect(store.people.map(\.displayName).sorted() == ["Abhi", "Maya"])
    }

    /// **A person added after a Save offers Save again, and the second Save holds them** (review
    /// M6). Only the reading and the countries counted, so Structure rebuilt its preview from the
    /// new household beside a Continue, and the profile on disk kept the old person axis.
    @Test func aPersonAddedAfterSaveIsSavedAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-rehousehold-\(UUID().uuidString)")
        let profiles = root.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FileSyncManager()
        engine.filingProfilesDirectory = profiles
        let model = SetupModel(settings: await settings(), peopleStore: nil, syncManager: engine,
                               hasFilingProfile: false, defaults: ScratchDefaults("setup-model-d"),
                               walk: Self.walk(folders: ["Finance/US", "Family/Maya", "Family/Ravi"]),
                               draftURL: nil,
                               onProfileWritten: {
                                   guard let id = FilingProfileStore.activeProfileId(in: profiles) else { return }
                                   engine.filingPeopleStore = PeopleStore(directory: profiles,
                                                                          profileId: id, profile: nil)
                               })
        model.screen = .people
        model.newPersonField = "Maya"
        model.commitTypedPerson()
        #expect(await model.save(), "premise: the first Save wrote")
        let first = try #require(model.writtenReport?.profileId)
        #expect(!model.canWriteProfile,
                "Save was offered again straight after it wrote, with nothing changed")

        model.screen = .people
        model.newPersonField = "Ravi"
        model.commitTypedPerson()
        _ = model.advance()

        #expect(model.canWriteProfile,
                "a person added after Save left Structure on Continue over a profile without them")
        #expect(await model.save(), "the second Save wrote nothing")
        let second = try #require(model.writtenReport?.profileId)
        #expect(second != first)
        let before = try #require(FilingProfileStore.profile(id: first, in: profiles))
        let after = try #require(FilingProfileStore.profile(id: second, in: profiles))
        #expect(before.folders["Family/Ravi"]?.axes["person"] == nil, "premise: the first had no Ravi")
        #expect(after.folders["Family/Ravi"]?.axes["person"] == "Ravi",
                "the second Save's profile does not hold Ravi")
        #expect(!model.canWriteProfile)
    }

    /// **A roster Setup cannot write offers no ✕** (review L1). The chip vanished, the store
    /// refused the save with a log line, and the person was back at the next launch.
    @Test func aReadOnlyRosterOffersNoRemove() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // One id twice: valid, and refused for writing until somebody says which record is meant.
        try Data("""
            { "schemaVersion": 1, "people": [
                { "id": "elder", "displayName": "Elder" },
                { "id": "elder", "displayName": "Elder F" },
                { "id": "granny", "displayName": "Granny" } ] }
            """.utf8).write(to: dir.appendingPathComponent("p/people.json"))
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        let model = SetupModel(settings: await settings(), peopleStore: store, syncManager: nil,
                               hasFilingProfile: true, defaults: ScratchDefaults("setup-model-d"),
                               walk: nil, draftURL: nil)
        #expect(model.rosterIsReadOnly, "premise: the roster is read-only")
        #expect(model.rosterRepeatsAnId, "a roster with one id twice was not told apart from an unreadable one")
        let shown = model.rosterNames
        #expect(shown.contains("Granny"), "premise: the chips show the roster")

        model.requestRemovePerson(named: "Granny")

        #expect(model.personAwaitingRemoval == nil, "a remove was offered on a roster that cannot change")
        #expect(model.rosterNames == shown, "the chip went from a roster that cannot change")

        // And the chip draws no ✕: the same chips, with and without a remove action.
        func width(_ chips: FlowChips) -> CGFloat {
            NSHostingController(rootView: chips).sizeThatFits(in: CGSize(width: 2000, height: 200)).width
        }
        let withRemove = width(FlowChips(items: ["Granny"], onRemove: { _ in }))
        let without = width(FlowChips(items: ["Granny"], onRemove: nil))
        #expect(without < withRemove,
                "the chip with no remove action is as wide as one with a ✕ (\(without) vs \(withRemove))")
    }
}
