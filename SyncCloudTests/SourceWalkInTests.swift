@testable import SyncCloud
import Dashboard
import Foundation
import Sync
import Testing

/// **Walking into a source from inside another one.**
///
/// `Home folder ▸ Dropbox ▸ Backup` and `Dropbox ▸ Backup` are the same folder described two ways.
/// The rule that collapses them is `PaneLogic.sourceRootedAt`; this suite is the rule, and
/// `SourceWalkInWiringTests` below is the half of it that lives in a `View` no test can build.
@Suite struct SourceWalkInTests {

    /// **Mimics the production resolver, including the part that bites.** Tilde expansion, no
    /// symlink following (that would need a real tree on disk) — and `""` mapped to a directory
    /// rather than left empty, because `URL(fileURLWithPath: "")` resolves to the process's current
    /// directory. A fixture that returns `""` for `""` passes over exactly the case the rule's two
    /// empty guards exist for, which is how the first version of those guards came to be written
    /// after the resolve, where neither could fire. `theProductionResolverDoesNotLeaveAnEmptyPath`
    /// below is what keeps this closure honest.
    private static let expand: (String) -> String = {
        $0.isEmpty ? "/" : ($0 as NSString).expandingTildeInPath
    }

    /// The fact the guards are placed around, asserted against the real resolver rather than
    /// trusted. If Foundation ever leaves `""` alone, `expand` above is lying and these tests go
    /// quiet about a case they were written for.
    @Test func theProductionResolverDoesNotLeaveAnEmptyPath() {
        #expect(!ContentView.resolved("").isEmpty,
                "an empty path no longer resolves to the current directory — the empty guards in sourceRootedAt, and `expand` above, are written around that")
    }

    private static func provider(_ id: String, _ name: String, root: String,
                                 type: CloudProvider.ProviderType = .dropBox) -> CloudProvider {
        CloudProvider(id: id, displayName: name, imageName: "", rootPath: root, type: type)
    }

    private static let sources = [
        provider("Dropbox", "Dropbox", root: "~/Dropbox"),
        provider("iCloud", "iCloud", root: "~/Library/Mobile Documents/com~apple~CloudDocs",
                 type: .iCloud),
        provider("folder:home", "Home folder", root: "~", type: .localFolder),
        provider("folder:disk", "Macintosh HD", root: "/", type: .localFolder),
    ]

    @Test func walkingOntoACloudSourcesOwnRootAdoptsIt() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~/Dropbox" as NSString).expandingTildeInPath,
            currentProviderId: "folder:home", among: Self.sources, resolve: Self.expand)
        #expect(adopted?.id == "Dropbox")
    }

    /// The rule that separates this from `owningSource`. Every folder in a Dropbox tree is "inside
    /// Dropbox", so a containment test would re-root the pane on the first drill and then claim
    /// every drill after it — the pane would never be able to walk anywhere.
    @Test func afolderInsideASourceIsNotThatSourcesRoot() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~/Dropbox/Backup" as NSString).expandingTildeInPath,
            currentProviderId: "folder:home", among: Self.sources, resolve: Self.expand)
        #expect(adopted == nil)
    }

    /// **The guard against one-way doors.** A re-root resets the pane's Back stack, so with `/` and
    /// `~` both added as folder sources an ordinary walk down the disk would strand the user in
    /// Home folder with `/Users` unreachable except through the source picker.
    @Test func walkingOntoAFolderSourcesRootDoesNotAdoptIt() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~" as NSString).expandingTildeInPath,
            currentProviderId: "folder:disk", among: Self.sources, resolve: Self.expand)
        #expect(adopted == nil, "a folder source must not be adopted — see the one-way-door rule")
    }

    /// Otherwise the first drill inside Dropbox would adopt Dropbox and reset the pane onto the
    /// root it is already showing.
    @Test func thePaneIsNeverAdoptedOntoTheSourceItIsAlreadyOn() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~/Dropbox" as NSString).expandingTildeInPath,
            currentProviderId: "Dropbox", among: Self.sources, resolve: Self.expand)
        #expect(adopted == nil)
    }

    /// Settings stores a hand-typed root verbatim, and the path in hand is built from an expanded
    /// one. Both sides go through `resolve` or the two spellings never meet.
    @Test func aTildeStoredRootMatchesAnExpandedPath() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~/Dropbox" as NSString).expandingTildeInPath,
            currentProviderId: "folder:home",
            among: [Self.provider("Dropbox", "Dropbox", root: "~/Dropbox")],
            resolve: Self.expand)
        #expect(adopted?.id == "Dropbox", "the stored `~/Dropbox` must resolve against the expanded path")
    }

    /// **A source with no root configured claims nothing** — and the folder it would otherwise
    /// claim is the startup disk, which is why this is more than hygiene. An app launched from
    /// Finder has `/` for a current directory, so an unset root resolves to `/` and a pane standing
    /// on `/` would be handed to a source that names nowhere.
    @Test func aSourceWithNoRootClaimsNothing() {
        let adopted = PaneLogic.sourceRootedAt(
            "/", currentProviderId: "folder:home",
            among: [Self.provider("Ghost", "Ghost", root: "")], resolve: Self.expand)
        #expect(adopted == nil)
    }

    /// The same guard from the pane's side: a pane on a source with no root builds an EMPTY
    /// location, which resolves to the current directory just as the ghost's unset root does. The
    /// two would meet there if either side went unguarded. Refusing the ghost is what covers both,
    /// which is why there is no separate empty-path guard — one was written and mutation testing
    /// showed nothing could kill it.
    @Test func aPaneWithNoRootAdoptsNothing() {
        let adopted = PaneLogic.sourceRootedAt(
            "", currentProviderId: "folder:home",
            among: [Self.provider("Ghost", "Ghost", root: "")], resolve: Self.expand)
        #expect(adopted == nil, "an empty pane path resolves to the current directory — the ghost source must not be sitting there to meet it")
    }

    /// **The case this feature actually meets on a real machine, driven through the PRODUCTION
    /// resolver.** `~/Dropbox` is a symlink to `~/Library/CloudStorage/Dropbox`, and the discovered
    /// source is rooted at the real folder — so a pane browsing Home folder reaches Dropbox by a
    /// name the source has never heard of. Comparing the paths as written finds nothing and the
    /// whole feature is silently dead for the one source it was asked for; the link-following
    /// resolver is what closes that gap, and this is the only test that runs it.
    @Test func aSourceIsFoundThroughASymlinkedPath() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walkin-\(UUID().uuidString)")
        let real = base.appendingPathComponent("CloudStorage/Dropbox")
        let link = base.appendingPathComponent("Dropbox")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let adopted = PaneLogic.sourceRootedAt(
            link.path, currentProviderId: "folder:home",
            among: [Self.provider("Dropbox", "Dropbox", root: real.path)],
            resolve: ContentView.resolved)
        #expect(adopted?.id == "Dropbox",
                "the resolver must follow the link, or the feature is dead for exactly the source it was built for")
    }

    /// A trailing slash on a user-settable root is the case `SidebarSourceModel.isSameFolder` was
    /// given trimming for; reaching it through this rule proves the trimming is on the path used.
    @Test func aRootSpelledWithATrailingSlashStillMatches() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~/Dropbox" as NSString).expandingTildeInPath,
            currentProviderId: "folder:home",
            among: [Self.provider("Dropbox", "Dropbox", root: "~/Dropbox/")],
            resolve: Self.expand)
        #expect(adopted?.id == "Dropbox")
    }
}

/// **The half of the walk-in that lives in `ContentView`.**
///
/// `ContentView` is a `View` with `@State`, so nothing here can be called from a test — the same
/// reason `PaneRetargetWiringTests` and `FolderSidebarWiringTests` exist, and this suite borrows
/// their instrument: read the one file, strip comments so a mention in prose cannot satisfy a
/// check, and `#require` a known-present anchor so a scan that finds nothing fails loudly.
@Suite struct SourceWalkInWiringTests {

    private static func body(of declaration: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView.swift — this scan would be vacuous")
        let source = SyncCloudTests.strippingComments(raw)
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"),
                               "\(declaration) never closes at member indentation")
        return String(rest[..<end.lowerBound])
    }

    /// The drill has to be refused BEFORE the mirror is computed: a mirrored drill hands this
    /// pane's stack to a sibling on another source, for a re-root it had no part in.
    @Test func theColumnDoorConsultsTheWalkInBeforeItMirrors() throws {
        let body = try Self.body(of: "func applyColumnNavigation(_ path: PaneBrowsePath, isLeft: Bool) {")
        let adopt = try #require(body.range(of: "adoptSourceWalkedInto(path, isLeft: isLeft)"),
                                 "applyColumnNavigation no longer consults the walk-in rule")
        let mirror = try #require(body.range(of: "let mirror ="),
                                  "applyColumnNavigation no longer computes a mirror — this scan is vacuous")
        #expect(adopt.lowerBound < mirror.lowerBound,
                "the walk-in must be consulted before the mirror is computed")
        #expect(body.contains("{ return }"), "the walk-in must take the navigation whole when it fires")
    }

    /// **Drills only.** `handleBackgroundDeselect` truncates the stack through this same door, and
    /// ⌘↑ walks it back up. A click on a pane's empty space that changed the pane's SOURCE would be
    /// the least explicable gesture in the app.
    @Test func theWalkInFiresOnlyOnAMoveThatGoesDeeper() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        #expect(body.contains("guard path.depth > paneStack(isLeft: isLeft).depth else { return false }"),
                "the depth guard is gone or no longer strictly deeper — a truncation would change source")
    }

    /// **A plain provider write, deliberately.** The pane must come out of this indistinguishable
    /// from one that picked the source in the menu: Back inside the new source, the old source's
    /// Back stack gone rather than silently re-anchored to a root the pane no longer has, the
    /// column stack cleared, the tree reloaded. `adoptProviderForTab` suppresses exactly the
    /// `retargetPane()` that does all of that, so reaching for it here — the obvious "consistency"
    /// edit, since the two neighbouring cross-source features both use it — would quietly leave
    /// the pane's history pointing into the tree it just left.
    @Test func theWalkInTakesThePlainProviderWriteNotTheArmedOne() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        #expect(body.contains("setFolderSidebarProvider(adopted.id, isLeft: isLeft)"),
                "the walk-in no longer writes the provider id through the plain door")
        #expect(!body.contains("adoptProviderForTab"),
                "the armed write suppresses retargetPane(), which is the whole of what this caller wants")
    }

    /// Enabled, not merely available: a disabled source is one no refresh will walk, so a pane
    /// pointed at it lands in a state with no tree and nothing to load one.
    @Test func theWalkInOffersOnlyEnabledSources() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        #expect(body.contains("among: settings.enabledProviders"),
                "the walk-in must consider only enabled sources")
    }

    /// The recurring defect in this file is a side read from the wrong half of a pair. Every read
    /// here must be of the pane the drill happened on — `paneStack`, `paneProviderId`, `paneScope`
    /// and the write — so a stray `!isLeft` re-roots the pane the user was not in.
    @Test func everySideReadInTheWalkInIsTheDrillingPane() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        for read in ["paneStack(isLeft: isLeft)", "paneProviderId(isLeft: isLeft)",
                     "paneScope(isLeft: isLeft)", "isLeft: isLeft)"] {
            #expect(body.contains(read), "\(read) is gone — the walk-in reads some other pane")
        }
        #expect(!body.contains("!isLeft"), "the walk-in must never read or write the sibling pane")
    }

    /// The one navigation in the app the user did not ask for by name — they clicked a folder and
    /// the pane changed source. The provider handler's own "User switched … provider" line lands a
    /// beat later and, alone, describes a menu pick that never happened.
    @Test func theWalkInSaysWhatItDid() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        #expect(body.contains("Logger.shared.info("), "an automatic source switch must not be silent")
    }
}
