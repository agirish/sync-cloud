import Testing
import Foundation

/// The `TODO` inbox stopped being a hidden root swap.
///
/// `ContentView.filingScanTargetFolder` used to retarget the filing scan to the loose-files inbox
/// whenever the pane happened to be sitting at the provider root — a *browsing accident deciding a
/// subject*. The branch is **deleted, not narrowed**: narrowing it would leave a rule that fires on
/// a condition the user cannot see, which is the whole complaint. What survives is the inbox
/// *path* resolution, promoted to a visible one-click scope shortcut on Organize's overview.
///
/// `ContentView` is a SwiftUI view in the app target with no seam to instantiate here, so this
/// reads the source. That is a blunt instrument with a known blind spot, so it fails loudly if the
/// file cannot be read rather than scanning an empty haystack — a source scan that silently finds
/// nothing passes just as green as one that proves something.
@Suite struct OrganizeScopeInboxTests {

    static func contentView() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/SyncCloudTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MacApp/ContentView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read MacApp/ContentView.swift — this scan would be vacuous")
        // `#require`, not `#expect`: a file that exists but is truncated hands a short string on,
        // after which every `contains` here answers false and every `!contains` answers true. One
        // quiet issue standing in front of a page of green is the wrong signal — stop instead.
        try #require(text.count > 10_000, "ContentView.swift is implausibly short — the scans below would be near-vacuous")
        return text
    }

    @Test func theInboxRootSwapIsGone() throws {
        let source = try Self.contentView()
        // The exact expression that made the pane's position choose the subject.
        #expect(!source.contains("(atRoot && inboxExists) ? inboxPath : focused"),
                "the inbox root-swap is back in filingScanTargetFolder")
        #expect(!source.contains("let atRoot ="),
                "filingScanTargetFolder is testing whether the pane is at the root again")
    }

    /// The rail's own inbox rule — the second half of the hidden behaviour, and the one that
    /// outlived the first.
    ///
    /// `filingScanTargetFolder`'s root-swap went early: the pane's position was choosing the
    /// subject. `tidyRailRelativePath(for:)` survived that cleanup and did the same thing wearing
    /// the other hat — it moved the pane *to* the inbox when Organize was opened, so on a fresh
    /// install (where `filingInboxRelativePathKey` is unset and defaults to `TODO`) switching to
    /// Organize jumped the source rail into a folder nobody had asked for.
    @Test func theRailNoLongerOpensOnTheInbox() throws {
        let source = try Self.contentView()
        // The resolver is gone outright. Matched on the **declaration**, not the bare name: the
        // comment that explains the removal names it, and a scan that cannot tell code from the
        // prose describing it is this suite's standing hazard — stated at the top of the file, and
        // the reason `body(of:in:)` exists.
        #expect(!source.contains("private func tidyRailRelativePath"),
                "the rail's inbox resolver is back — Organize opens on TODO again on a fresh install")

        let body = try Self.body(of: "func presentLensRail(for workspace: Workspace) {", in: source)
        #expect(body.contains("focusOn(relativePath: \"\", isLeft: true)"),
                "the rail no longer opens at the provider root — it is being positioned somewhere else again")
        // The key, not the word "inbox": the body's own comment explains what was removed and says
        // "inbox" four times, so a scan for the word would fail a correct implementation.
        #expect(!body.contains("filingInboxRelativePathKey"),
                "presentLensRail reads the inbox setting again, so opening Organize moves the pane")
    }

    /// The setting can express "off", which it could not.
    ///
    /// The field's placeholder was the key's own default, so a field the user had deliberately
    /// emptied rendered identically to one never touched — greyed-out "TODO" either way — and
    /// nothing on the row said what blank did. That is what "there is no way to clear it" was.
    @Test func theInboxSettingCanBeCleared() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Modules/Settings/Sources/Settings/SettingsView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read SettingsView.swift — this scan would be vacuous")
        #expect(source.contains("TextField(\"None\", text: $filingInbox)"),
                "the inbox field advertises its default as its placeholder again, so a cleared field looks unset")
        #expect(!source.contains("TextField(\"TODO\", text: $filingInbox)"))
    }

    @Test func theInboxPATHResolutionSurvives() throws {
        let source = try Self.contentView()
        // Deleted the rule, kept the resolution — the shortcut needs it, and it keeps the existence
        // check that stops the rail and the scan disagreeing about a missing inbox.
        #expect(source.contains("var filingInboxFolder: String?"))
        #expect(source.contains("GeneralSettings.filingInboxRelativePathKey"))
        #expect(source.contains("isDirectory: &isDir"),
                "the inbox existence check is gone — a missing TODO would resolve to a path that is not there")
        #expect(source.contains("filingInboxFolder: filingInboxFolder"),
                "the inbox is resolved but never handed to the lens, so no shortcut can appear")
    }

    /// The declaration's body, bounded by its **closing brace** rather than by a character count.
    ///
    /// A fixed-width window is a known way for a source scan to answer about the wrong text: the
    /// first version of the test below took 400 characters after the declaration, which ran clean
    /// past this four-line body and into the *next* member's doc comment — where the word "inbox"
    /// legitimately appears — and failed a correct implementation.
    ///
    /// The shared reader — see ``declarationBody(of:in:)``, which also strips comments and refuses
    /// a duplicated declaration. This copy did neither.
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
        // "Organize This Folder…" must SET the scope, not just scan — the scope is the lasting half.
        let body = try Self.body(of: "func organizeFolderAction(_ node: FileNode) {", in: source)
        #expect(body.contains("setOrganizeScope(folder)"),
                "Organize This Folder no longer sets the scope, so five lenses would ignore it")
        // And the one write is where the root is normalized away, so no caller can mint a second
        // encoding of the global view.
        #expect(source.contains("func setOrganizeScope(_ path: String?)"))
        // The normalization lives in ONE resolver behind both the read and the write, so the two
        // cannot drift about what a stored provider root means.
        #expect(source.contains("organizeScopePath = resolvedOrganizeScope(path)?.path ?? \"\""))
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
