import Testing
import Foundation
import FileExplorer
import Sync
@testable import SyncCloud

/// How the host **applies** a `PaletteRoute`.
///
/// `CommandPaletteTests` proves the routing table: a query in, a route out. Nothing there — and
/// nothing in the render or panel suites — can see what the app then *does* with that route, and
/// `runPaletteRoute` is not reachable from a test: it is a method on a SwiftUI `View` struct whose
/// body owns a sync manager, a settings object and an `@AppStorage` pair.
///
/// So this is a source-level scan of the two decisions in it that have already been wrong once, or
/// would be silent if they were. It names the file it reads and fails if that file cannot be found,
/// and each check asserts the exact string whose absence is the regression.
@Suite struct CommandPaletteRouteCallSiteTests {

    /// The same text with whole-line `//` comments removed.
    ///
    /// **Only for the NEGATIVE checks**, and learned the hard way twice in one session: a scan
    /// asserting something is *absent* is exactly the one a comment explaining the absence will
    /// falsify. The first run of `theRouteWritesOrganizesStateThroughAppStorage` failed on the line
    /// reading "never `UserDefaults.standard.set`". Positive checks keep the raw text — matching a
    /// call that is genuinely there is not confused by prose.
    /// The shared stripper — see ``sourceCodeOnly(_:)``. Four suites in this target carried a
    /// byte-identical copy of it; consolidating `body(of:in:)` and leaving the thing it depends on
    /// duplicated would have been half a fix.
    static func codeOnly(_ source: String) -> String { sourceCodeOnly(source) }

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        // `#require`, not `#expect`: a file that exists but is truncated hands a short string on,
        // after which every `contains` here answers false and every `!contains` answers true. One
        // quiet issue standing in front of a page of green is the wrong signal — stop instead.
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// **The rail and the scope are written through `@AppStorage`, never `UserDefaults.standard`.**
    ///
    /// This app has already measured `@AppStorage` *losing* a standard-domain write outright rather
    /// than delivering it late — it is why the defaults-backed suites mount their own
    /// `ScratchDefaults` — and `LensWorkspaceView` holds both of these keys in `@AppStorage`. Written raw, a
    /// ⌘K route to "Organize ▸ Duplicates" could land on Organize and leave the rail wherever it
    /// already was, intermittently, with nothing to see and nothing logged.
    @Test func theRouteWritesOrganizesStateThroughAppStorage() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("paletteRailLens = lens"),
                "the rail selection is no longer written through @AppStorage")
        #expect(host.contains("if let scope { setOrganizeScope(scope) }"),
                "the scope no longer goes through setOrganizeScope — the one @AppStorage-backed writer")
        let code = Self.codeOnly(host)
        #expect(code.contains("paletteRailLens = lens"),
                "stripping comments emptied the file — the checks below would be vacuous")
        for raw in ["UserDefaults.standard.set", "UserDefaults.standard.removeObject"] {
            #expect(!code.contains(raw),
                    "\(raw) is back — a write @AppStorage is documented to lose")
        }
    }

    /// The scope is normalized by `setOrganizeScope(_:)` — ContentView's "one write of Organize's
    /// scope", whose resolver collapses the provider root to the cleared state. Two encodings of
    /// the global view is the state `OrganizeScope`'s failable `init?` exists to make
    /// unrepresentable, and the palette once carried its own inline copy of that rule — under a
    /// comment asserting there is exactly one.
    @Test func theRouteCannotMintASecondEncodingOfTheGlobalView() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("setOrganizeScope(scope)"),
                "the scope write no longer goes through the one owner")
        let code = Self.codeOnly(host)
        #expect(!code.contains("OrganizeScope(path:"),
                "the host has grown its own copy of the normalization again")
        for verbatim in ["paletteScopePath =", "organizeScopePath ="] {
            #expect(!code.contains(verbatim),
                    "the scope is written directly (`\(verbatim)`), bypassing setOrganizeScope")
        }
    }

    // MARK: One pane, asked once

    /// **The palette describes one pane, and must act on that same pane.**
    ///
    /// `lensProviderRootExpanded` follows the *focused* pane in Compare, so with the right pane
    /// focused every folder and recent row in the index is relative to the right provider's tree.
    /// Three places then assumed the left one: the reveal focused `isLeft: true` (handing a path
    /// from one provider's tree to the other's, so the pane jumped to a folder that most likely
    /// does not exist there), "The current source" was marked by comparing to `leftProviderId`, and
    /// choosing a source switched the left pane. `paletteProviderId` names the rule once.
    @Test func thePaletteRevealsIntoThePaneItIndexed() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("var aimedAtRight: Bool { lensTargetIsRight }"),
                "there is no single answer for which pane the palette is aimed at")
        #expect(host.contains("var paletteProviderId: String { aimedAtRight ? rightProviderId : leftProviderId }"),
                "the provider read no longer goes through the aim")
        #expect(host.contains("isLeft: isLeft ?? !aimedAtRight"),
                "the reveal always targets the left pane, even when the index came from the right one")
        #expect(!Self.codeOnly(host).contains("isLeft: true"),
                "a reveal still hard-codes the left pane")
        #expect(host.contains("isCurrent: provider.id == paletteProviderId"),
                "\"The current source\" is decided against the left pane rather than the aimed one")
        // One writer, so the rule cannot be restated differently at the next site: both routes
        // that change the source go through it.
        #expect(host.contains("func aimProvider(_ id: String)"),
                "there is no single writer for the aimed pane")
        #expect(host.contains("case .provider(let id):") && host.contains("aimProvider(id)"),
                "choosing a source from ⌘K switches the pane the palette was not describing")
        #expect(host.contains("chooseFolderSource { id in aimProvider(id) }"),
                "adding a source from ⌘K still points a pane the palette was not describing")
        #expect(Self.codeOnly(host).components(separatedBy: "lensTargetIsRight").count - 1 == 1,
                "the aimed-pane rule is stated in more than one place again")
    }

    /// **The aim is read before the workspace moves.**
    ///
    /// `lensProviderRootExpanded` and `lensTargetIsRight` both follow the focused pane, and only
    /// Compare has two panes — so switching to Organize makes them the LEFT pane's answers. A
    /// scope string taken from a right-pane index and resolved afterwards fails `OrganizeScope`,
    /// which writes `""` and silently clears the scope instead of setting it: "organize legal"
    /// loses its folder. Ordering is the whole fix, so ordering is what this asserts.
    ///
    /// **Three values, one hazard**, and the third was the one that stayed broken: this suite used
    /// to pin the reveal as `isLeft: !aimedAtRight` — an expression *evaluated after* the move —
    /// under a comment claiming it was a captured aim. The prose described the fix and the
    /// assertion pinned the bug, so the bug could not be fixed without turning this red. Every
    /// value that follows the focused pane is now required to be BOUND above the move and PASSED
    /// below it, which is a shape rather than a spelling.
    @Test func theOrganizeRouteResolvesItsScopeAgainstThePaneItCameFrom() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        // Comment-stripped, and via the shared reader: the needles below are ordinary prose about
        // this very function, and its comments already quote `setOrganizeScope(_:)` by name.
        let body = try declarationBody(of: "private func aimOrganize(lens: OrganizeLens?, scope: String?) {",
                                       in: host)
        let read = try #require(body.range(of: "let root = lensProviderRootExpanded"),
                                "aimOrganize no longer resolves a provider root")
        let move = try #require(body.range(of: "workspaceSelection.wrappedValue = .filing"),
                                "aimOrganize no longer enters Organize")
        #expect(read.lowerBound < move.lowerBound,
                "the root is read after the workspace changes, so it names the wrong pane")
        // The scope write shares the hazard: `setOrganizeScope` resolves against the LIVE
        // `lensProviderRootExpanded`, so calling it after the move measures the scope against the
        // left pane's root unconditionally — the same silent clear, one line later.
        let write = try #require(body.range(of: "if let scope { setOrganizeScope(scope) }"),
                                 "aimOrganize no longer routes the scope through the one owner")
        #expect(write.lowerBound < move.lowerBound,
                "the scope is set after the workspace changes, so the owner resolves it against the wrong pane")
        // **Which pane, on the same terms as which root.** `aimedAtRight` is a computed property
        // over `layoutMode`, so an `isLeft: !aimedAtRight` written at the reveal is not a captured
        // aim at all — it is evaluated after the line above has left Compare, and answers `false`
        // for a right-pane route. Asserted as the pair the root is: BOUND before the move…
        let aim = try #require(body.range(of: "let revealIntoLeft = !aimedAtRight"),
                               "aimOrganize no longer captures which pane the palette was aimed at")
        #expect(aim.lowerBound < move.lowerBound,
                "the aim is captured after the workspace changes, so it names the wrong pane")
        // …and PASSED at the reveal, rather than the expression being re-read there. The absence
        // check is the half that matters: handing the binding over while leaving a second live
        // read behind is the state that reads as fixed and is not.
        #expect(body.contains("revealInSourcePane(scope, root: root, isLeft: revealIntoLeft)"),
                "the reveal is not given the captured aim")
        #expect(!body.contains("isLeft: !aimedAtRight"),
                "the reveal re-reads an aim the workspace switch has already moved")
    }

    /// Every route case is applied. A `default:` arm would let a case added to `PaletteRoute` — a
    /// public enum in another module — compile here and silently do nothing.
    @Test func everyRouteCaseIsHandledWithoutADefaultArm() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        for arm in ["case .compare:", "case .storage:", "case .organize(let lens, let scope):",
                    "case .person(let id):", "case .provider(let id):", "case .folder(let path):",
                    "case .action(let action):"] {
            #expect(host.contains(arm), "runPaletteRoute no longer handles `\(arm)`")
        }
        let body = try #require(host.range(of: "func runPaletteRoute(_ route: PaletteRoute) {"))
        let rest = host[body.upperBound...]
        let end = try #require(rest.range(of: "\n    }"))
        #expect(!Self.codeOnly(String(rest[..<end.lowerBound])).contains("default:"),
                "a default arm would swallow a route case added upstream")
    }
}
