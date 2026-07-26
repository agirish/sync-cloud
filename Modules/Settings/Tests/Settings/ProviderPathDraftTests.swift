import Testing
@testable import Settings

/// Pins the Location field's draft lifecycle — specifically what "Reset" leaves in the field.
///
/// The bug: `resetToDefault()` blanked the draft and relied on `onChange(of: provider.path)` to
/// refill it. That refresh only fires when the published path actually CHANGES, and resetting a
/// provider with NO override removes a defaults key that was never there — so nothing changed,
/// nothing refreshed, and the field sat empty. Then a focus-blur committed that empty string,
/// which `SettingsManager.setPath` records as "User cleared custom path mapping" for a provider
/// that never had one.
///
/// The two cases differ only in whether an external change follows, which is why they are tested
/// as sequences rather than as single calls.
@Suite struct ProviderPathDraftTests {

    private let iCloudDefault = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"

    /// The case that was broken. No override → `resetPath` changes nothing → no refresh is coming,
    /// so the draft has to be correct the moment Reset returns.
    @Test func testResetWithNoOverrideLeavesTheFieldShowingTheDefault() {
        var draft = ProviderPathDraft()
        draft.adopt(iCloudDefault)

        draft.reset(toEffective: iCloudDefault)
        #expect(draft.value == iCloudDefault)

        // The consequence that made the blank field more than cosmetic: with the effective path in
        // the field, the blur that follows is a no-op instead of committing "" and logging a
        // cleared override for a provider that never had one.
        #expect(!ProviderFieldEdit.shouldCommit(draft: draft.value, committed: iCloudDefault))
    }

    /// The case that appeared to work. An override IS cleared, so discovery republishes a
    /// different path and the refresh arrives — but the field must still be honest in between,
    /// never blank.
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

    /// Reset never yields an empty field for either provider shape — the one property the old code
    /// violated, stated directly so a future edit can't reintroduce it through some other route.
    @Test func testResetNeverBlanksTheFieldForAnyEffectivePath() {
        for effective in [iCloudDefault, "/Volumes/Archive/iCloud", "/Users/me/Dropbox"] {
            var draft = ProviderPathDraft()
            draft.adopt("whatever was typed")
            draft.reset(toEffective: effective)
            #expect(draft.value == effective)
        }
    }

    /// The pre-existing guard this refactor had to preserve: a concurrent `discoverProviders()`
    /// must not overwrite what the user is in the middle of typing.
    @Test func testAnExternalChangeIsIgnoredWhileTheUserIsEditing() {
        var draft = ProviderPathDraft()
        draft.adopt(iCloudDefault)
        draft.value = "/Users/me/half-typ"

        draft.adoptExternalChange(to: "/Users/me/Rediscovered", isEditing: true)
        #expect(draft.value == "/Users/me/half-typ")

        draft.adoptExternalChange(to: "/Users/me/Rediscovered", isEditing: false)
        #expect(draft.value == "/Users/me/Rediscovered")
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
