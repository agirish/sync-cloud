import Testing
import Foundation

/// Which of a pane's two names the lens workspaces use, at the call site. `PaneProviderNamesTests`
/// proves `plain(isLeft:)` drops the "(left)"/"(right)" a two-pane surface needs, but not that
/// Organize asks for it: `paneNames.left` there would put "iCloud (left) › Documents › …" in every
/// breadcrumb with every other test green. A source scan that fails loudly on an empty read and
/// pins the whole expression, not its ingredients.
@Suite struct LensProviderNameCallSiteTests {

    /// The lens workspaces show one source, so their name carries no pane suffix.
    @Test func theLensNameIsThePlainOne() throws {
        let body = try declarationBody(of: "var lensProviderName: String {", in: macAppFile("ContentView.swift"))
        #expect(body.contains("paneNames.plain(isLeft: !lensTargetIsRight)"), """
                `lensProviderName` no longer asks for the plain name. A lens workspace shows one \
                pane, so a "(left)"/"(right)" suffix there disambiguates against a pane that is \
                not on screen — which is what put "iCloud (left)" in every Organize breadcrumb. \
                Body was: \(body)
                """)
        #expect(!body.contains("paneNames.left"),
                "the disambiguated name is back in a single-pane surface: \(body)")
        #expect(!body.contains("paneNames.right"),
                "the disambiguated name is back in a single-pane surface: \(body)")
    }
}
