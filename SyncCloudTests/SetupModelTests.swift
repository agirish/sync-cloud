import Foundation
import Settings
import SwiftUI
import Sync
import Testing
@testable import SyncCloud

/// The rules the guided sheet runs on, without a window.
///
/// `SetupModel` exists so these rules can be tested at all; on the view, nothing could reach them.
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

    private func model(walk: SetupWalk? = nil, syncManager: FileSyncManager? = nil,
                       peopleStore: PeopleStore? = nil, hasFilingProfile: Bool = false,
                       startScreen: SetupFlow.Screen? = nil, draftURL: URL? = nil,
                       onProfileWritten: @escaping () -> Void = {},
                       onStartSurvey: @escaping (URL) -> Void = { _ in }) async -> SetupModel {
        SetupModel(settings: await settings(), peopleStore: peopleStore, syncManager: syncManager,
                   hasFilingProfile: hasFilingProfile,
                   defaults: ScratchDefaults("setup-model-d"),
                   walk: walk, startScreen: startScreen, draftURL: draftURL,
                   onProfileWritten: onProfileWritten, onStartSurvey: onStartSurvey)
    }

    /// One test's scratch folder: `folders` made under it, and an engine whose profiles live at
    /// `profiles`, made unless `makesProfiles` is false. With `blocked`, a regular file stands
    /// where the profiles folder's parent should be, so nothing can be written. `remove()` it in a
    /// `defer`.
    @MainActor private struct Scratch {
        let root: URL
        let engine = FileSyncManager.scratch()
        var documents: URL { root.appendingPathComponent("Documents") }
        var profiles: URL { root.appendingPathComponent("profiles") }
        var blocker: URL { root.appendingPathComponent("blocker") }

        init(_ tag: String, folders: [String] = [], makesProfiles: Bool = true, blocked: Bool = false) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("setup-\(tag)-\(UUID().uuidString)")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for folder in folders {
                try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            if blocked {
                try Data("not a folder".utf8).write(to: blocker)
                engine.filingProfilesDirectory = blocker.appendingPathComponent("profiles")
            } else {
                if makesProfiles { try fm.createDirectory(at: profiles, withIntermediateDirectories: true) }
                engine.filingProfilesDirectory = profiles
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func walk(folders: [String], files: [String] = []) -> SetupWalk {
        SetupWalk.summarising(tree: SetupSheetFitTests.fixtureTree(folders: folders, files: files),
                              root: URL(fileURLWithPath: "/tmp/Documents"),
                              recordedRoot: "~/Documents", known: [])
    }

    // MARK: - The name, and the folder that corroborates it

    /// The folder match is found once the tree arrives, not only at open: field seeding runs while
    /// the fields are empty, before any tree exists.
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

    /// Editing the name takes the old name's forms with it, so a corrected name doesn't leave the
    /// old one ticked and filed under.
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

    /// Learn cannot be pressed with nothing to read, where the press would do nothing and Structure
    /// would be unreachable with no line saying why.
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
        let engine = FileSyncManager.scratch()
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

    /// Seeding the root cannot throw away a reading that has finished. The sheet re-seeds on every
    /// change to the provider list: switching a location off after Learn moves the primary, and a
    /// re-seed that followed it would wipe the walk with no screen saying so.
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

    /// A reading that lands while Structure is already on screen draws the tree it read. Continue
    /// never waits, so on a large tree Structure can open before the reading lands.
    @Test(.timeLimit(.minutes(2)))
    func aReadingThatLandsOnStructureDrawsItsTree() async throws {
        let s = try Scratch("land", folders: ["Documents/Finance/US", "Documents/Family/Mother"], makesProfiles: false)
        defer { s.remove() }

        let model = await self.model(syncManager: s.engine)
        model.walkRoot = s.documents
        model.screen = .structure
        model.startWalk()
        await model.lastWalk?.value

        #expect(model.walkState.isDone, "premise: the reading landed (\(model.walkFailureReason ?? "still running"))")
        #expect(model.preview != nil, "Structure kept drawing “Nothing has been learned yet.”")
        #expect(model.canWriteProfile)
    }

    /// A reading that lands before Structure builds no preview (heavy main-actor work under the
    /// user's typing, for a tree arrival at Structure builds anyway); one that lands after it does.
    @Test(.timeLimit(.minutes(2)))
    func aReadingRebuildsThePreviewOnlyWhereItIsRead() async throws {
        let s = try Scratch("where", folders: ["Documents/Finance/US", "Documents/Family/Mother"], makesProfiles: false)
        defer { s.remove() }
        try Data("x".utf8).write(to: s.documents.appendingPathComponent("loose.pdf"))

        let early = await self.model(syncManager: s.engine)
        early.walkRoot = s.documents
        early.screen = .people
        early.startWalk()
        await early.lastWalk?.value
        #expect(early.walkState.isDone, "premise: the reading landed (\(early.walkFailureReason ?? "still running"))")
        #expect(early.preview == nil, "a reading landing on People built Structure's preview")
        early.screen = .countries
        #expect(early.advance(), "premise: Countries leads on")
        #expect(early.screen == .structure)
        #expect(early.preview != nil, "arrival at Structure no longer builds the preview")

        let late = await self.model(syncManager: s.engine)
        late.walkRoot = s.documents
        late.screen = .workspaces
        late.startWalk()
        await late.lastWalk?.value
        #expect(late.walkState.isDone)
        #expect(late.looseRoutes.count == 1,
                "a reading landing on Workspaces left it saying “No loose files” (\(late.looseRoutes.count) routes)")
    }

    /// A reading of the old folder that lands after Change… is dropped. Change… doesn't wait for
    /// the reading it supersedes, and a late result must not land as the new folder's reading.
    @Test(.timeLimit(.minutes(2)))
    func aReadingOfTheOldFolderThatLandsLateIsDropped() async throws {
        let s = try Scratch("late", folders: ["First/Finance/US", "First/Family/Mother", "Second/Taxes/2024"], makesProfiles: false)
        defer { s.remove() }
        let first = s.root.appendingPathComponent("First")
        let second = s.root.appendingPathComponent("Second")

        let model = await self.model(syncManager: s.engine)
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

    /// Skip during a reading stays skipped when the reading lands, and of two readings of one
    /// folder only the later lands. A guard on the folder alone would bring Countries and Structure
    /// back after a Skip, and let two walks land, each resetting the Countries ticks.
    @Test(.timeLimit(.minutes(2)))
    func onlyTheLatestAwaitedReadingLands() async throws {
        let s = try Scratch("gen", folders: ["Documents/Finance/US", "Documents/Family/Mother"], makesProfiles: false)
        defer { s.remove() }

        // The test holds the main actor, so neither reading can land before the next step.
        let skipped = await self.model(syncManager: s.engine)
        skipped.changeWalkRoot(to: s.documents)
        skipped.screen = .learn
        skipped.startWalk()
        #expect(skipped.skip())
        await skipped.lastWalk?.value
        #expect(skipped.walkState == .skipped, "the reading landed over a Skip: \(skipped.walkState)")
        #expect(!skipped.crumbs.contains(.structure), "Structure came back after Skip")

        let twice = await self.model(syncManager: s.engine)
        twice.changeWalkRoot(to: s.documents)
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

    /// Learn's card names the location the chosen folder is in, measured from the folder, not the
    /// primary location. The outside folder is asked first, so answering with the primary's name
    /// can't pass.
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
    /// On a re-run the chips are the real `people.json`, so one click would delete a person with
    /// the full names and aliases curated in Settings, where the same removal asks first.
    @Test func removingARosterPersonAsksFirst() async throws {
        let s = try Scratch("remove", makesProfiles: false)
        defer { s.remove() }
        let store = PeopleStore(directory: s.root, profileId: "remove", profile: nil)
        store.add(displayName: "Maya")
        let model = await self.model(peopleStore: store, hasFilingProfile: true)
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

    /// A person removed on People after a first-run Save stays removed. Save lands the draft in the
    /// roster it creates; if the draft in memory still named them, leaving People would bring them
    /// back.
    @Test func aPersonRemovedAfterAFirstRunSaveStaysRemoved() async throws {
        let s = try Scratch("unremove")
        defer { s.remove() }
        let draftURL = s.root.appendingPathComponent("setup-draft.json")
        let engine = s.engine, profiles = s.profiles
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: engine, draftURL: draftURL,
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

    /// Closing keeps the open screen's answers, as a screen change does, so a name typed on You
    /// survives Esc, ✕ or a click outside. Read from the draft on disk in a scratch folder, never the
    /// real `setup-draft.json`. Closing must not mark setup finished.
    @Test func closingKeepsTheOpenScreensAnswers() async throws {
        let s = try Scratch("close", makesProfiles: false)
        defer { s.remove() }
        let draftURL = s.root.appendingPathComponent("setup-draft.json")
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

    /// Two presses write one profile, and the second must not break the first. Within one second
    /// both mint the same id and the store refuses the second, so the count on disk is one either
    /// way; the guard protects the model, which would otherwise record the refusal as a failed walk
    /// and throw away the profile just written.
    @Test func twoSavesAtOnceWriteOneProfile() async throws {
        let s = try Scratch("save")
        defer { s.remove() }
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine)

        async let first = model.save()
        async let second = model.save()
        let wrote = await [first, second]

        let written = try FileManager.default.contentsOfDirectory(atPath: s.profiles.path)
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

    /// A failed write stays on Structure, keeps the reading, and says it was the write. Recorded as
    /// a failed walk, it would throw the tree away and show its reason on screens already behind,
    /// headed "Couldn't read that folder".
    @Test func aFailedSaveStaysOnStructureAndKeepsTheReading() async throws {
        let s = try Scratch("savefail", blocked: true)
        defer { s.remove() }

        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine)
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
        try FileManager.default.removeItem(at: s.blocker)
        try FileManager.default.createDirectory(at: s.engine.filingProfilesDirectory!,
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
        let s = try Scratch(tag, blocked: true)
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine)
        model.screen = .structure
        await model.saveAndContinue()
        #expect(model.saveFailure != nil, "premise: the first Save failed")
        return (model, s.root, s.blocker)
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

    /// Starts a Save and returns once it is parked mid-write, with the gate that lets it finish.
    /// Open the gate before awaiting the press. Parked rather than polled through `isSaving`, which
    /// on a loaded machine can miss the whole press.
    private func startSaving(_ model: SetupModel) async throws -> (press: Task<Void, Never>, gate: SaveGate) {
        let gate = SaveGate()
        model.saveInFlight = { await gate.park() }
        let press = Task { await model.saveAndContinue() }
        await waitUntil("the Save parks in flight", timeout: 10) { gate.parked }
        #expect(gate.parked && model.isSaving, "premise: the Save is parked in flight")
        return (press, gate)
    }

    /// A retry keeps the last failure on screen while it writes, so Structure doesn't jump and
    /// Continue Without Saving doesn't vanish for the length of the press.
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

    /// Back is refused while Save writes, and a Save that lands off Structure moves nothing, so it
    /// can't carry the sheet on from whatever screen is current when it lands.
    @Test(.timeLimit(.minutes(2)))
    func backIsRefusedWhileSaveWrites() async throws {
        let s = try Scratch("backsave")
        defer { s.remove() }

        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine)
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

    /// Continue Without Saving moves on and writes nothing; it is offered only after a failed Save.
    @Test func continuingWithoutSavingMovesOnAndWritesNothing() async throws {
        let s = try Scratch("nosave", blocked: true)
        defer { s.remove() }

        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine)
        model.screen = .structure
        #expect(model.structureSecondaryTitle == nil, "offered before any Save had failed")
        await model.saveAndContinue()
        #expect(model.structureSecondaryTitle != nil, "premise: the Save failed")

        model.continueWithoutSaving()
        #expect(model.screen == .workspaces, "Continue Without Saving stayed on \(model.screen)")
        #expect(model.writtenReport == nil)
        #expect(model.saveFailure == nil, "the failure line followed the sheet off Structure")
    }

    /// A reading Save has written is not written again. Summary's Learn leads back through
    /// Structure, where a second press must not write a second profile from the same tree or ask
    /// for a second reading of the documents.
    @Test func aWrittenReadingIsNotOfferedForSavingAgain() async throws {
        let s = try Scratch("twice")
        defer { s.remove() }
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine)
        #expect(model.canWriteProfile, "premise: a reading to write")
        #expect(await model.save(), "premise: the first Save wrote")

        #expect(!model.canWriteProfile,
                "Structure would offer “Save and Start Reading” over a reading already written")
        #expect(await model.save() == false, "a second Save of the same reading was let through")
        let written = try FileManager.default.contentsOfDirectory(atPath: s.profiles.path)
            .filter { $0.hasPrefix("walk-") }
        #expect(written.count == 1, "one reading wrote \(written.count) profiles: \(written)")

        // A new reading is a new thing to write.
        model.adopt(Self.walk(folders: ["Taxes/2024"]))
        #expect(model.canWriteProfile, "a fresh reading could not be saved")
    }

    /// A country changed after Save is written by a second Save, and the documents are not read a
    /// second time. Otherwise Summary would list the new countries while the profile on disk held
    /// the old ones.
    @Test func aCountryChangedAfterSaveIsSavedAgain() async throws {
        let s = try Scratch("recountry")
        defer { s.remove() }
        var started: [URL] = []
        let model = await self.model(walk: Self.walk(folders: ["Finance/US/2024", "Finance/IN/2024"]),
                                     syncManager: s.engine, onStartSurvey: { started.append($0) })
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
        let written = try #require(FilingProfileStore.profile(id: second, in: s.profiles))
        #expect(written.folders["Finance/IN"]?.axes["jurisdiction"] == "IN",
                "the profile the second Save wrote does not hold IN")
        #expect(started.count == 1, "the second Save started reading the same folder again: \(started)")
        #expect(!model.canWriteProfile, "the second Save's answers are still offered for saving")
    }

    // MARK: - Structure over a reading still running

    /// While the reading runs, Structure's button is Skip Saving; once it lands, Save. Continue
    /// never waits, so Structure can open before a big tree's reading lands.
    @Test func structuresButtonSaysSkipSavingUntilTheReadingLands() async throws {
        let engine = FileSyncManager.scratch()
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

    /// On a re-run, a reading in progress or a failed one is not passed off as the profile already
    /// here. With no reading in hand Structure shows this Mac's profile, read-only; while one runs
    /// it says so, and a failed one is said.
    @Test(arguments: [false, true])
    func aReadingNotInHandHidesTheProfileAlreadyHere(failed: Bool) async throws {
        let engine = FileSyncManager.scratch()
        engine.filingProfilesDirectory = FileManager.default.temporaryDirectory
        engine.filingFolderProfile = FileSyncManager.previewProfile(
            walk: Self.walk(folders: ["Finance/US"]), registry: nil, jurisdictionValues: [])
        let model = await self.model(syncManager: engine)
        model.screen = .structure
        #expect(model.structureIsReadOnly, "premise: the re-run shows this Mac's profile")
        #expect(model.structureShownProfile != nil, "premise: and draws it")

        model.walkState = failed ? .failed("The folder could not be read.") : .running
        let reading = failed ? "a failed reading" : "a reading in progress"
        #expect(!model.structureIsReadOnly, "\(reading) is called the profile already here")
        #expect(model.structureShownProfile == nil, "the old profile is drawn over \(reading)")
        if !failed { #expect(model.structurePrimaryTitle == "Skip Saving") }
    }

    /// Skip Saving moves on without waiting, and writes nothing.
    @Test func skipSavingMovesOnAndWritesNothing() async throws {
        let s = try Scratch("skipsave")
        defer { s.remove() }
        let model = await self.model(syncManager: s.engine)
        model.screen = .structure
        model.walkState = .running

        await model.pressStructurePrimary(shownSkipSaving: model.structurePrimaryTitle == SetupModel.skipSavingTitle)

        #expect(model.screen == .workspaces, "Skip Saving stayed on \(model.screen)")
        #expect(model.walkState.isRunning, "Skip Saving stopped the reading")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.profiles.path).isEmpty,
                "Skip Saving wrote a profile")
    }

    /// And once the reading has landed, the same press saves.
    @Test func structuresPressSavesOnceTheReadingLands() async throws {
        let s = try Scratch("pressave")
        defer { s.remove() }
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine)
        model.readDocuments = false
        model.screen = .structure

        await model.pressStructurePrimary(shownSkipSaving: model.structurePrimaryTitle == SetupModel.skipSavingTitle)

        #expect(model.writtenReport != nil, "the press over a landed reading wrote nothing")
        #expect(model.screen == .workspaces)
    }

    /// A press made under Skip Saving moves on without saving, even if the reading has landed
    /// since. The sheet runs the press in a `Task`, so a reading can land between the render and
    /// the press; deciding then would start hours of reading under a button that said skip.
    @Test func aPressUnderSkipSavingNeverSavesTheReadingThatLandedSince() async throws {
        let s = try Scratch("skiprace")
        defer { s.remove() }
        var started: [URL] = []
        let model = await self.model(syncManager: s.engine, startScreen: .structure,
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.profiles.path).isEmpty,
                "a press under Skip Saving wrote a profile")
        #expect(started.isEmpty, "a press under Skip Saving started reading the documents")
    }

    // MARK: - Structure over a reading that failed

    /// A reading that fails on Structure is said there: the walk's status line stands in the
    /// tree's box rather than the last reading's tree, the counts are dashes, the switch is off
    /// limits, and the button is Continue, with nothing to save or skip.
    @Test func aReadingThatFailsOnStructureIsSaidThere() async throws {
        let s = try Scratch("failed")
        defer { s.remove() }
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine, startScreen: .structure)
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.profiles.path).isEmpty,
                "Continue over a failed reading wrote a profile")
    }

    /// While the reading runs, Structure counts nothing and the switch waits: no zeros or old
    /// counts, and no "Read documents" switch for a Save the screen can't make yet. The people are
    /// the roster's either way, so they stay.
    @Test func whileTheReadingRunsStructureCountsNothingAndTheSwitchWaits() async throws {
        let engine = FileSyncManager.scratch()
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

    /// Over a finished reading, Learn's primary is Continue, and it keeps the reading. A re-read
    /// would reset the Countries ticks to the rule's picks, and Skip throws the reading away.
    @Test func continueOverAFinishedReadingKeepsIt() async throws {
        let engine = FileSyncManager.scratch()
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
    @Test(.timeLimit(.minutes(2)))
    func learnAgainReadsAfreshAndMovesOn() async throws {
        let s = try Scratch("again", folders: ["Documents/Finance/US"], makesProfiles: false)
        defer { s.remove() }

        let model = await self.model(walk: Self.walk(folders: ["Finance/US"]), syncManager: s.engine)
        model.walkRoot = s.documents
        model.screen = .learn
        model.pressLearnAgain()
        #expect(model.walkState == .running, "Learn Again did not start a reading")
        #expect(model.screen == .you, "Learn Again waited for the reading")
        // Let it land inside the fixture before the folder is removed.
        await model.lastWalk?.value
        #expect(!model.walkState.isRunning, "the reading never finished")
    }

    /// Summary's Learn goes back to Learn, with the sheet still open; no Settings tab can learn a
    /// folder.
    @Test func summarysLearnReturnsToTheLearnScreen() async {
        let model = await self.model(walk: Self.walk(folders: ["Finance/US"]))
        model.screen = .summary
        model.returnToLearn()
        #expect(model.screen == .learn)
        #expect(model.walkState.isDone, "the reading was dropped on the way back")
    }

    /// Summary describes what Save wrote, not the reading in hand: an unsaved reading isn't
    /// "Learned", and a written profile stays learned after Learn is skipped on the way back.
    @Test func summarySaysWhatWasWritten() async throws {
        let s = try Scratch("summary")
        defer { s.remove() }
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Mother"]),
                                     syncManager: s.engine)
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
        let source = try macAppFile("Setup/SummaryScreen.swift")
        #expect(source.contains("row(\"folder\", Self.folderLine(for: model),"))
        #expect(source.contains("if let countries = Self.countriesLine(for: model) {"))
    }

    /// Saves a walk into a fresh profiles folder — holding a hand-built profile first, when asked
    /// to — and answers which folders the reading was started on.
    private func save(besideAHandBuiltProfile: Bool) async throws -> (model: SetupModel, started: [URL], walk: SetupWalk) {
        let s = try Scratch("read")
        defer { s.remove() }
        if besideAHandBuiltProfile {
            _ = try FilingProfileStore.writeProfile(
                FolderProfile(profileId: "hand", root: "/Volumes/Archive/Docs",
                              folders: ["Finance": FolderProfileEntry(
                                path: "Finance", role: nil, naming: nil, anchors: [],
                                acceptsNewFiles: nil, fileCount: 1, subfolderCount: 0, axes: [:])],
                              personTokens: []),
                in: s.profiles, builtBy: "hand — setup-read fixture")
        }
        let walk = Self.walk(folders: ["Finance/US", "Family/Mother"])
        var started: [URL] = []
        let model = await self.model(walk: walk, syncManager: s.engine,
                                     hasFilingProfile: besideAHandBuiltProfile,
                                     onStartSurvey: { started.append($0) })
        #expect(model.readDocuments, "premise: reading the documents was asked for")
        await model.save()
        #expect(model.writtenReport != nil, "premise: the walk's profile was written")
        return (model, started, walk)
    }

    /// Setup reads the documents of the profile it wrote, so not when that profile is unused.
    /// Beside a hand-built profile the walk's is saved and left unused, and a reading covers the
    /// profile in use, so it would spend hours on a folder this run never pointed at.
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

    // MARK: - Learn twice, renaming yourself, and a roster added to after Save

    /// Learn pressed while the folder is still being read starts no second reading. Back to Learn
    /// mid-reading still says Learn, and nothing would cancel a second walk of the same tree.
    @Test(.timeLimit(.minutes(2)))
    func learnWhileTheFolderIsBeingReadReadsItOnce() async throws {
        let s = try Scratch("learn-twice", folders: ["Documents/Finance/US", "Documents/Family/Mother"], makesProfiles: false)
        defer { s.remove() }
        let model = await self.model(syncManager: s.engine)
        model.changeWalkRoot(to: s.documents)
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

    /// Closing Setup after editing your name renames your record rather than adding a second "me",
    /// which People hides, so a duplicate would show nowhere. The old name stays as an alias, so
    /// folders that call you by it still find you.
    @Test func editingYourNameAndClosingRenamesYourRecord() async throws {
        let s = try Scratch("rename-me", makesProfiles: false)
        defer { s.remove() }
        let store = PeopleStore(directory: s.root, profileId: "rename", profile: nil)
        store.add(displayName: "Abhishek", relationship: "me")
        store.add(displayName: "Maya", relationship: "wife")
        let id = try #require(store.people.first { $0.relationship == "me" }?.id)
        let model = await self.model(peopleStore: store, hasFilingProfile: true, startScreen: .you)
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

    /// A person added after a Save offers Save again, and the second Save holds them. Otherwise
    /// Structure would preview the new household beside a Continue while the profile on disk kept
    /// the old person axis.
    @Test func aPersonAddedAfterSaveIsSavedAgain() async throws {
        let s = try Scratch("rehousehold")
        defer { s.remove() }
        let model = await self.model(walk: Self.walk(folders: ["Finance/US", "Family/Maya", "Family/Ravi"]),
                                     syncManager: s.engine,
                                     onProfileWritten: {
                                         guard let id = FilingProfileStore.activeProfileId(in: s.profiles) else { return }
                                         s.engine.filingPeopleStore = PeopleStore(directory: s.profiles,
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
        let before = try #require(FilingProfileStore.profile(id: first, in: s.profiles))
        let after = try #require(FilingProfileStore.profile(id: second, in: s.profiles))
        #expect(before.folders["Family/Ravi"]?.axes["person"] == nil, "premise: the first had no Ravi")
        #expect(after.folders["Family/Ravi"]?.axes["person"] == "Ravi",
                "the second Save's profile does not hold Ravi")
        #expect(!model.canWriteProfile)
    }

    /// A roster Setup cannot write offers no ✕: the chip would vanish, the store refuse the save,
    /// and the person be back at the next launch.
    @Test func aReadOnlyRosterOffersNoRemove() async throws {
        let s = try Scratch("readonly", folders: ["p"], makesProfiles: false)
        defer { s.remove() }
        let dir = s.root
        // One id twice: valid, and refused for writing until somebody says which record is meant.
        try Data("""
            { "schemaVersion": 1, "people": [
                { "id": "elder", "displayName": "Elder" },
                { "id": "elder", "displayName": "Elder F" },
                { "id": "granny", "displayName": "Granny" } ] }
            """.utf8).write(to: dir.appendingPathComponent("p/people.json"))
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        let model = await self.model(peopleStore: store, hasFilingProfile: true)
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
