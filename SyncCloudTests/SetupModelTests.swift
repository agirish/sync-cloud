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
        let defaults = UserDefaults(suiteName: "setup-model-\(UUID().uuidString)")!
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
                   defaults: UserDefaults(suiteName: "setup-model-d-\(UUID().uuidString)")!,
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

        async let first: Void = model.save()
        async let second: Void = model.save()
        _ = await (first, second)

        let written = try FileManager.default.contentsOfDirectory(atPath: profiles.path)
            .filter { $0.hasPrefix("walk-") }
        #expect(written.count == 1, "two presses wrote \(written.count) profiles: \(written)")
        #expect(model.walkState.isDone,
                "the second press was let through and its refusal was recorded as a failed walk, over a profile that had just been written")
        #expect(model.walkFailureReason == nil)
        #expect(!model.isSaving, "the flag was not cleared, so the button would stay dead")
        #expect(model.writtenReport != nil)
    }
}
