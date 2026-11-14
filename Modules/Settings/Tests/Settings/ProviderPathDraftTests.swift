import Testing
@testable import Settings

/// Pins the Location field's draft lifecycle: when an external discovery change replaces the
/// draft, and when it must not.
@Suite struct ProviderPathDraftTests {

    private let iCloudDefault = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs"

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
