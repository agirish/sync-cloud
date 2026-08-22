import Testing
import Foundation

/// **The person gather reads the corpus under a profile id, and that id has to be the FOLDER the
/// artifacts came from.**
///
/// `FilingProfileStore.active` states the law — "The DIRECTORY is the identity" — and warns when
/// the folder name and the `profileId` field inside `folder-profile.json` disagree, which they do
/// whenever a hand-built profile omits the field: it decodes to `"default"`. Keyed on the field,
/// `acceptPersonScope` asked `FilingSurveyStore.corpus(id:in:)` for a folder holding nothing, got
/// nil, and "show me everything that's Aditi's" quietly produced nothing at all.
///
/// **This is a scan because the function cannot be driven.** `PersonGatherSupersedeTests` says so
/// in as many words — `acceptPersonScope` needs a whole `ContentView` with a live environment —
/// and its own tests reach past it to `ContentView.gatherOffMainActor`, passing `profileId:`
/// explicitly, so they exercise the callee and are blind to what the caller hands it. The two Sync-
/// side doors of this same defect (`resurveyFilingMemory`, `rejectedIdentifiers`) have real
/// behavioural tests; this one has the seam pinned instead of nothing.
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

    /// And the loader actually hands that id over, or the line above resolves to the fallback on
    /// every launch and the fix is inert.
    @Test func theLoaderHandsTheDirectoryIdToTheManager() throws {
        let source = try macAppSources()
        #expect(source.contains("manager.filingProfileDirectoryId = loaded.id"),
                "nothing sets the directory id, so every reader falls back to the field")
        // `loaded.id` is the folder; the three stores beside it already take it, and this is the
        // premise that makes them comparable rather than two conventions in one function.
        #expect(source.contains("profileId: loaded.id"),
                "the sibling stores stopped using the folder id — the convention has drifted")
    }
}
