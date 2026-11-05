@testable import SyncCloud
import Dashboard
import Foundation
import Sync
import Testing

/// Walking into a source from inside another one.
///
/// `Home folder ▸ Dropbox ▸ Backup` and `Dropbox ▸ Backup` are the same folder described two ways.
/// `PaneLogic.sourceRootedAt` collapses them; this suite pins the rule, and
/// `SourceWalkInWiringTests` below the half that lives in a `View` no test can build.
@Suite struct SourceWalkInTests {

    /// Mimics the production resolver: tilde expansion, no symlink following (that needs a real
    /// tree), and `""` mapped to a directory, because `URL(fileURLWithPath: "")` resolves to the
    /// current directory. A fixture returning `""` for `""` would skip the case the rule's empty
    /// guards exist for. `theProductionResolverDoesNotLeaveAnEmptyPath` keeps this honest.
    private static let expand: (String) -> String = {
        $0.isEmpty ? "/" : ($0 as NSString).expandingTildeInPath
    }

    /// The fact the guards are placed around, asserted against the real resolver. If Foundation
    /// ever leaves `""` alone, `expand` above is wrong and these tests miss the case.
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

    /// What separates this from `owningSource`: every folder in a Dropbox tree is inside Dropbox,
    /// so a containment test would re-root the pane on every drill.
    @Test func afolderInsideASourceIsNotThatSourcesRoot() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~/Dropbox/Backup" as NSString).expandingTildeInPath,
            currentProviderId: "folder:home", among: Self.sources, resolve: Self.expand)
        #expect(adopted == nil)
    }

    /// The guard against one-way doors. A re-root resets the pane's Back stack, so with `/` and `~`
    /// both folder sources a walk down the disk would strand the user in Home folder with `/Users`
    /// reachable only through the source picker.
    @Test func walkingOntoAFolderSourcesRootDoesNotAdoptIt() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~" as NSString).expandingTildeInPath,
            currentProviderId: "folder:disk", among: Self.sources, resolve: Self.expand)
        #expect(adopted == nil, "a folder source must not be adopted — see the one-way-door rule")
    }

    /// Otherwise a drill onto Dropbox's root would adopt Dropbox and reset the pane onto the root
    /// it is already showing.
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

    /// A source with no root configured claims nothing. An app launched from Finder has `/` for a
    /// current directory, so an unset root resolves to `/`, and a pane on the startup disk would be
    /// handed to a source that names nowhere.
    @Test func aSourceWithNoRootClaimsNothing() {
        let adopted = PaneLogic.sourceRootedAt(
            "/", currentProviderId: "folder:home",
            among: [Self.provider("Ghost", "Ghost", root: "")], resolve: Self.expand)
        #expect(adopted == nil)
    }

    /// The same guard from the pane's side: a pane on a source with no root builds an empty
    /// location, which resolves to the current directory just as the ghost's unset root does.
    /// Refusing the ghost covers both, so there is no separate empty-path guard.
    @Test func aPaneWithNoRootAdoptsNothing() {
        let adopted = PaneLogic.sourceRootedAt(
            "", currentProviderId: "folder:home",
            among: [Self.provider("Ghost", "Ghost", root: "")], resolve: Self.expand)
        #expect(adopted == nil, "an empty pane path resolves to the current directory — the ghost source must not be sitting there to meet it")
    }

    /// The real-machine case, through the production resolver: `~/Dropbox` is a symlink to
    /// `~/Library/CloudStorage/Dropbox`, where the discovered source is rooted, so a pane in Home
    /// folder reaches Dropbox by a path the source doesn't know. Only the link-following resolver
    /// matches them, and this is the only test that runs it.
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

    /// A trailing slash on a user-settable root, which `SidebarSourceModel.isSameFolder` trims;
    /// reaching it through this rule proves the trimming is on the path used.
    @Test func aRootSpelledWithATrailingSlashStillMatches() {
        let adopted = PaneLogic.sourceRootedAt(
            ("~/Dropbox" as NSString).expandingTildeInPath,
            currentProviderId: "folder:home",
            among: [Self.provider("Dropbox", "Dropbox", root: "~/Dropbox/")],
            resolve: Self.expand)
        #expect(adopted?.id == "Dropbox")
    }
}

/// The half of the walk-in that lives in `ContentView`, a `View` with `@State` no test can call.
/// Like `PaneRetargetWiringTests` and `FolderSidebarWiringTests`, it reads the file with comments
/// stripped, and requires a known anchor so a scan that finds nothing fails loudly.
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

    /// The walk-in is consulted before the mirror is computed: a mirrored drill would hand this
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

    /// Drills only. `handleBackgroundDeselect` truncates the stack through this same door, and ⌘↑
    /// walks it back up; a click on empty space must never change the pane's source.
    @Test func theWalkInFiresOnlyOnAMoveThatGoesDeeper() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        #expect(body.contains("guard path.depth > paneStack(isLeft: isLeft).depth else { return false }"),
                "the depth guard is gone or no longer strictly deeper — a truncation would change source")
    }

    /// A plain provider write, deliberately. The pane must end up as if the source were picked in
    /// the menu: old Back stack gone, column stack cleared, tree reloaded, all done by
    /// `retargetPane()`. `adoptProviderForTab`, which the neighbouring cross-source features use,
    /// suppresses exactly that, leaving the history pointing into the tree just left.
    @Test func theWalkInTakesThePlainProviderWriteNotTheArmedOne() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        #expect(body.contains("setFolderSidebarProvider(adopted.id, isLeft: isLeft)"),
                "the walk-in no longer writes the provider id through the plain door")
        #expect(!body.contains("adoptProviderForTab"),
                "the armed write suppresses retargetPane(), which is the whole of what this caller wants")
    }

    /// Enabled, not merely available: no refresh walks a disabled source, so a pane pointed at one
    /// would have no tree and nothing to load one.
    @Test func theWalkInOffersOnlyEnabledSources() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        #expect(body.contains("among: settings.enabledProviders"),
                "the walk-in must consider only enabled sources")
    }

    /// Every read here is of the pane the drill happened on (`paneStack`, `paneProviderId`,
    /// `paneScope` and the write), since a stray `!isLeft` would re-root the pane the user wasn't in.
    @Test func everySideReadInTheWalkInIsTheDrillingPane() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        for read in ["paneStack(isLeft: isLeft)", "paneProviderId(isLeft: isLeft)",
                     "paneScope(isLeft: isLeft)", "isLeft: isLeft)"] {
            #expect(body.contains(read), "\(read) is gone — the walk-in reads some other pane")
        }
        #expect(!body.contains("!isLeft"), "the walk-in must never read or write the sibling pane")
    }

    /// The one navigation the user didn't ask for by name: they clicked a folder and the pane
    /// changed source. The provider handler's own "User switched … provider" line would alone
    /// describe a menu pick that never happened.
    @Test func theWalkInSaysWhatItDid() throws {
        let body = try Self.body(of: "func adoptSourceWalkedInto(_ path: PaneBrowsePath, isLeft: Bool) -> Bool {")
        #expect(body.contains("Logger.shared.info("), "an automatic source switch must not be silent")
    }
}
