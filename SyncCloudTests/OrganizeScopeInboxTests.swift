import Testing
import Foundation

/// The `TODO` inbox is never a hidden root swap: no rule retargets the filing scan to it, even
/// narrowly, since that would fire on a condition the user can't see. The inbox resolution stays
/// as a visible one-click scope shortcut on Organize's overview. Reads `ContentView`'s source and
/// fails loudly if it can't: a scan of an empty haystack passes as green as a real one.
@Suite struct OrganizeScopeInboxTests {
    @Test func theInboxRootSwapIsGone() throws {
        let source = try macAppFile("ContentView.swift")
        // The expression that would let the pane's position choose the subject.
        #expect(!source.contains("(atRoot && inboxExists) ? inboxPath : focused"),
                "the inbox root-swap is back in filingScanTargetFolder")
        #expect(!source.contains("let atRoot ="),
                "filingScanTargetFolder is testing whether the pane is at the root again")
    }

    /// Opening Organize must not move the pane to the inbox: `filingInboxRelativePathKey` defaults to
    /// `TODO`, so on a fresh install the rail would jump into a folder nobody asked for.
    @Test func theRailNoLongerOpensOnTheInbox() throws {
        let source = try macAppFile("ContentView.swift")
        // `LensEntryContinuityTests` bans every pane move in this body; this holds that no rule of
        // Organize's own, the inbox above all, moves it.
        let body = try declarationBody(of: "func presentLensRail(for workspace: Workspace) {", in: source)
        // The key, not the word "inbox", which the body's own comment may say.
        #expect(!body.contains("filingInboxRelativePathKey"),
                "presentLensRail reads the inbox setting again, so opening Organize moves the pane")
    }

    /// The setting can express "off": a placeholder of the default ("TODO") would make a cleared
    /// field look untouched.
    @Test func theInboxSettingCanBeCleared() throws {
        let source = try repoFile("Modules/Settings/Sources/Settings/SettingsView.swift")
        #expect(source.contains("TextField(\"None\", text: $filingInbox)"),
                "the inbox field advertises its default as its placeholder again, so a cleared field looks unset")
        #expect(!source.contains("TextField(\"TODO\", text: $filingInbox)"))
    }

    @Test func theInboxPATHResolutionSurvives() throws {
        let source = try macAppFile("ContentView.swift")
        // The resolution stays: the shortcut needs it, and its existence check stops the rail and the
        // scan disagreeing about a missing inbox.
        #expect(source.contains("var filingInboxFolder: String?"))
        #expect(source.contains("GeneralSettings.filingInboxRelativePathKey"))
        #expect(source.contains("isDirectory: &isDir"),
                "the inbox existence check is gone — a missing TODO would resolve to a path that is not there")
        #expect(source.contains("filingInboxFolder: filingInboxFolder"),
                "the inbox is resolved but never handed to the lens, so no shortcut can appear")
    }

    @Test func filingScanTargetIsSimplyTheFocusedFolder() throws {
        let source = try macAppFile("ContentView.swift")
        let body = try declarationBody(of: "var filingScanTargetFolder: String? {", in: source)
        #expect(body.contains("return focused"))
        #expect(!body.contains("inbox"),
                "filingScanTargetFolder mentions the inbox again — it must not decide the subject")
        // Non-vacuity: a body that had collapsed to nothing would satisfy the `!contains` above.
        #expect(body.contains("lensScanRootExpanded"))
    }

    @Test func pointingAtAFolderSetsTheScopeAndTheRootClearsIt() throws {
        let source = try macAppFile("ContentView.swift")
        // "Organize This Folder…" must set the scope, not just scan: the scope is the lasting half.
        let body = try declarationBody(
            of: "func organizeFolderAction(_ node: FileNode, providerRoot: String, providerAnchor: String) {",
            in: source)
        #expect(body.contains("setOrganizeScope(folder, providerRoot: providerRoot)"),
                "Organize This Folder no longer sets the scope, so five lenses would ignore it")
        // The scope is against the account root, the filing scan's taxonomy at the source's anchor
        // (`OrganizeScopeAutoRescanTests.everyFilingScanFilesIntoFileIntosFolder`). The one write
        // normalizes the root away, so no caller can mint a second encoding of the global view, and one
        // resolver serves read and write.
        #expect(source.contains("organizeScopePath = OrganizeScope.normalizedPath(path, providerRoot: providerRoot)"),
                "the scope write no longer routes through OrganizeScope.normalizedPath — a second copy of the normalization is back")
        #expect(source.contains("private func resolvedOrganizeScope(_ path: String?) -> OrganizeScope?"))
        #expect(source.contains("OrganizeScope(path: path, providerRoot: lensProviderRootExpanded)"))
    }
}
