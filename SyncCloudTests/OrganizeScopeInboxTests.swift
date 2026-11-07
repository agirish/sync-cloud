import Testing
import Foundation

/// The `TODO` inbox is never a hidden root swap. Where the pane happens to stand must not decide
/// the filing scan's subject, so no rule retargets it to the inbox, even narrowly: that would fire
/// on a condition the user can't see. The inbox path resolution stays, as a visible one-click
/// scope shortcut on Organize's overview.
///
/// `ContentView` has no seam to instantiate here, so this reads the source, and fails loudly if the
/// file can't be read: a scan of an empty haystack passes as green as one that proves something.
@Suite struct OrganizeScopeInboxTests {

    static func contentView() throws -> String { try macAppFile("ContentView.swift") }

    @Test func theInboxRootSwapIsGone() throws {
        let source = try Self.contentView()
        // The expression that would let the pane's position choose the subject.
        #expect(!source.contains("(atRoot && inboxExists) ? inboxPath : focused"),
                "the inbox root-swap is back in filingScanTargetFolder")
        #expect(!source.contains("let atRoot ="),
                "filingScanTargetFolder is testing whether the pane is at the root again")
    }

    /// Opening Organize must not move the pane to the inbox. On a fresh install
    /// `filingInboxRelativePathKey` defaults to `TODO`, so a rail rule that opened on the inbox
    /// would jump the source rail into a folder nobody asked for.
    @Test func theRailNoLongerOpensOnTheInbox() throws {
        let source = try Self.contentView()
        // The pane keeps the folder it was in, and `LensEntryContinuityTests` bans every pane move
        // in this body; this holds that no rule of Organize's own, the inbox above all, moves it.
        let body = try Self.body(of: "func presentLensRail(for workspace: Workspace) {", in: source)
        // The key, not the word "inbox": the body's own comment may say "inbox", and a scan for the
        // word would fail a correct implementation.
        #expect(!body.contains("filingInboxRelativePathKey"),
                "presentLensRail reads the inbox setting again, so opening Organize moves the pane")
    }

    /// The setting can express "off". A placeholder of the key's default ("TODO") would make a
    /// cleared field look exactly like an untouched one.
    @Test func theInboxSettingCanBeCleared() throws {
        let source = try repoFile("Modules/Settings/Sources/Settings/SettingsView.swift")
        #expect(source.contains("TextField(\"None\", text: $filingInbox)"),
                "the inbox field advertises its default as its placeholder again, so a cleared field looks unset")
        #expect(!source.contains("TextField(\"TODO\", text: $filingInbox)"))
    }

    @Test func theInboxPATHResolutionSurvives() throws {
        let source = try Self.contentView()
        // No rule, but the resolution stays: the shortcut needs it, and its existence check stops
        // the rail and the scan disagreeing about a missing inbox.
        #expect(source.contains("var filingInboxFolder: String?"))
        #expect(source.contains("GeneralSettings.filingInboxRelativePathKey"))
        #expect(source.contains("isDirectory: &isDir"),
                "the inbox existence check is gone — a missing TODO would resolve to a path that is not there")
        #expect(source.contains("filingInboxFolder: filingInboxFolder"),
                "the inbox is resolved but never handed to the lens, so no shortcut can appear")
    }

    /// The declaration's body, bounded by its closing brace, not a character count: a fixed window
    /// can run past a short body into the next member's text and answer about the wrong code. The
    /// shared reader, ``declarationBody(of:in:)``, also strips comments and refuses a duplicated
    /// declaration.
    static func body(of declaration: String, in source: String) throws -> String {
        try declarationBody(of: declaration, in: source)
    }

    @Test func filingScanTargetIsSimplyTheFocusedFolder() throws {
        let source = try Self.contentView()
        let body = try Self.body(of: "var filingScanTargetFolder: String? {", in: source)
        #expect(body.contains("return focused"))
        #expect(!body.contains("inbox"),
                "filingScanTargetFolder mentions the inbox again — it must not decide the subject")
        // Non-vacuity: a body that had collapsed to nothing would satisfy the `!contains` above.
        #expect(body.contains("lensScanRootExpanded"))
    }

    @Test func pointingAtAFolderSetsTheScopeAndTheRootClearsIt() throws {
        let source = try Self.contentView()
        // "Organize This Folder…" must set the scope, not just scan: the scope is the lasting half.
        let body = try Self.body(
            of: "func organizeFolderAction(_ node: FileNode, providerRoot: String, providerAnchor: String) {",
            in: source)
        #expect(body.contains("setOrganizeScope(folder, providerRoot: providerRoot)"),
                "Organize This Folder no longer sets the scope, so five lenses would ignore it")
        // The two roots must not be swapped here: the scope against the account root, the filing
        // scan's taxonomy at the source's anchor (`OrganizeScopeAutoRescanTests
        // .everyFilingScanFilesIntoFileIntosFolder`). The one write normalizes the root away, so no
        // caller can mint a second encoding of the global view.
        // One resolver behind both read and write, so they can't drift about what a stored
        // provider root means.
        #expect(source.contains("organizeScopePath = OrganizeScope.normalizedPath(path, providerRoot: providerRoot)"),
                "the scope write no longer routes through OrganizeScope.normalizedPath — a second copy of the normalization is back")
        #expect(source.contains("private func resolvedOrganizeScope(_ path: String?) -> OrganizeScope?"))
        #expect(source.contains("OrganizeScope(path: path, providerRoot: lensProviderRootExpanded)"))
    }

    @Test func theScopeIsMigratedAtLaunch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/SyncCloudApp.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read MacApp/SyncCloudApp.swift")
        #expect(source.contains("OrganizeScopeDefaults.migrate(defaults: .standard)"),
                "the scope's stamped migration never runs, so a foreign stored value would be trusted")
    }
}
