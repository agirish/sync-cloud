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
        #expect(text.count > 10_000, "ContentView.swift is implausibly short")
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
    static func body(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — the scan below would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(declaration)")
        return String(rest[..<end.lowerBound])
    }

    @Test func filingScanTargetIsSimplyTheFocusedFolder() throws {
        let source = try Self.contentView()
        let body = try Self.body(of: "var filingScanTargetFolder: String? {", in: source)
        #expect(body.contains("return focused"))
        #expect(!body.contains("inbox"),
                "filingScanTargetFolder mentions the inbox again — it must not decide the subject")
        // Non-vacuity: a body that had collapsed to nothing would satisfy the `!contains` above.
        #expect(body.contains("tidyScanRootExpanded"))
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
        #expect(source.contains("OrganizeScope(path: path, providerRoot: tidyProviderRootExpanded)"))
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
