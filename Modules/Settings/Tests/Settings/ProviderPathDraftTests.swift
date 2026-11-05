import Testing
@testable import Settings

/// Pins the Location field's draft lifecycle, especially what Reset leaves in the field. Reset
/// can't rely on `onChange(of: provider.path)` to refill the field: with no override, nothing
/// changes and no refresh comes, and a blank field's blur would commit "" and log a cleared mapping
/// for a provider that never had one. With an override, the rediscovered default arrives while
/// the field still has focus. So the tests are sequences, varying both the path and focus.
@Suite struct ProviderPathDraftTests {

    private let iCloudDefault = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"

    /// With no override, `resetPath` changes nothing and no refresh is coming, so the draft has to
    /// be right the moment Reset returns.
    @Test func testResetWithNoOverrideLeavesTheFieldShowingTheDefault() {
        var draft = ProviderPathDraft()
        draft.adopt(iCloudDefault)

        draft.reset(toEffective: iCloudDefault)
        #expect(draft.value == iCloudDefault)

        // With the effective path in the field, the blur that follows writes nothing instead of
        // committing "" and logging a cleared override for a provider that never had one.
        #expect(!ProviderFieldEdit.shouldCommit(draft: draft.value, committed: iCloudDefault))
    }

    /// With an override, discovery republishes a different path and the refresh arrives, but the
    /// field must not be blank in between.
    @Test func testResetWithAnOverrideShowsTheOldPathThenAdoptsTheRediscoveredDefault() {
        var draft = ProviderPathDraft()
        draft.adopt("/Volumes/Archive/iCloud")

        // Rediscovery is async: at the instant Reset returns, `provider.path` is still the override.
        draft.reset(toEffective: "/Volumes/Archive/iCloud")
        #expect(!draft.value.isEmpty)

        // …and the refresh corrects it when discovery lands.
        draft.adoptExternalChange(to: iCloudDefault, isEditing: false)
        #expect(draft.value == iCloudDefault)
    }

    /// Reset never leaves the field empty, whatever the effective path.
    @Test func testResetNeverBlanksTheFieldForAnyEffectivePath() {
        for effective in [iCloudDefault, "/Volumes/Archive/iCloud", "/Users/me/Dropbox"] {
            var draft = ProviderPathDraft()
            draft.adopt("whatever was typed")
            draft.reset(toEffective: effective)
            #expect(draft.value == effective)
        }
    }

    /// A concurrent `discoverProviders()` must not overwrite what the user is in the middle of
    /// typing.
    @Test func testAnExternalChangeIsIgnoredWhileTheUserIsEditing() {
        var draft = ProviderPathDraft()
        draft.adopt(iCloudDefault)
        draft.value = "/Users/me/half-typ"

        draft.adoptExternalChange(to: "/Users/me/Rediscovered", isEditing: true)
        #expect(draft.value == "/Users/me/half-typ")

        draft.adoptExternalChange(to: "/Users/me/Rediscovered", isEditing: false)
        #expect(draft.value == "/Users/me/Rediscovered")
    }

    /// Reset and the rediscovery it starts, landing while the Location field still has focus.
    /// Clicking a macOS button doesn't blur a text field, so the restored default arrives with
    /// `isEditing: true`. Declined as typing, the field would keep showing the cleared override and
    /// the next blur would write it back, silently undoing Reset. Reset has to win.
    @Test func testResetSurvivesARediscoveryThatLandsWhileTheFieldStillHasFocus() {
        let override = "/Volumes/Archive/iCloud"
        var draft = ProviderPathDraft()
        draft.adopt(override)

        draft.reset(toEffective: override)
        // Discovery answers while the field is still focused, as it always does after Reset,
        // which never takes focus from the field beside it.
        draft.adoptExternalChange(to: iCloudDefault, isEditing: true)
        #expect(draft.value == iCloudDefault)

        // The blur that follows must neither restore the override just cleared nor commit an
        // empty string (logged as "User cleared custom path mapping").
        #expect(!draft.value.isEmpty)
        #expect(!ProviderFieldEdit.shouldCommit(draft: draft.value, committed: iCloudDefault))
    }

    /// The reset outranks the editing guard only while the field still shows what Reset left. A
    /// user who then starts typing is editing again, so a discovery pass landing mid-word is still
    /// declined.
    @Test func testTypingAfterResetRestoresTheEditingGuard() {
        var draft = ProviderPathDraft()
        draft.adopt("/Volumes/Archive/iCloud")
        draft.reset(toEffective: "/Volumes/Archive/iCloud")

        // The user starts typing a new path before the rediscovery answers.
        draft.value = "/Users/me/half-typ"
        draft.adoptExternalChange(to: iCloudDefault, isEditing: true)
        #expect(draft.value == "/Users/me/half-typ")
    }

    /// A refresh that republishes the value already shown is a no-op, so an idle Settings window
    /// doesn't churn the field on every discovery pass.
    @Test func testAnExternalChangeToTheSameValueChangesNothing() {
        var draft = ProviderPathDraft()
        draft.adopt(iCloudDefault)
        let before = draft
        draft.adoptExternalChange(to: iCloudDefault, isEditing: false)
        #expect(draft == before)
    }
}
