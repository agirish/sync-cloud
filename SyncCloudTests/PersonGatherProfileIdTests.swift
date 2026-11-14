import Testing
import Foundation

/// The person gather reads the corpus under a profile id, and that id must be the folder the
/// artifacts came from. `FilingProfileStore.active` treats the directory as the identity; the
/// `profileId` field in `folder-profile.json` decodes to `"default"` when a hand-built profile
/// omits it. Keyed on the field, the gather would ask `FilingSurveyStore.corpus(id:in:)` for an
/// empty folder and quietly show nothing.
///
/// A scan, because `acceptPersonScope` needs a whole `ContentView` and can't be driven.
@Suite struct PersonGatherProfileIdTests {

    /// The gather's id comes from the manager's directory-derived value, not the profile's field.
    @Test func thePersonGatherTakesItsProfileIdFromTheFolderNotTheField() throws {
        let source = try macAppSources()

        // Non-vacuity: the call site this is about still exists and still takes an id.
        #expect(source.contains("gatherOffMainActor("),
                "the gather was renamed — this scan is measuring nothing")
        #expect(source.contains("personId: person.id, profileId: id"),
                "the gather no longer takes `id` — re-read this scan before trusting it")

        #expect(source.contains("let id = syncManager.filingProfileDirectoryId ?? profile.profileId"),
                "the gather's id is not taken from the folder the artifacts were read from")
        #expect(!source.contains("let id = profile.profileId\n"),
                "the gather is back on the field inside the profile, which can name another folder")
    }

    /// The loader hands that id over, or the line above falls back to the field on every launch.
    @Test func theLoaderHandsTheDirectoryIdToTheManager() throws {
        let source = try macAppSources()
        #expect(source.contains("manager.filingProfileDirectoryId = loaded.id"),
                "nothing sets the directory id, so every reader falls back to the field")
        // `loaded.id` is the folder; the stores beside it take it too, so one function keeps one
        // convention.
        #expect(source.contains("profileId: loaded.id"),
                "the sibling stores stopped using the folder id — the convention has drifted")
    }
}
