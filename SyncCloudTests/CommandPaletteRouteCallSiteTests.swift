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
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        #expect(text.count > 500, "\(name) is implausibly short")
        return text
    }

    /// **The rail and the scope are written through `@AppStorage`, never `UserDefaults.standard`.**
    ///
    /// This app has already measured `@AppStorage` *losing* a standard-domain write outright rather
    /// than delivering it late — it is why the defaults-backed suites mount their own
    /// `ScratchDefaults` — and `TidyView` holds both of these keys in `@AppStorage`. Written raw, a
    /// ⌘K route to "Organize ▸ Duplicates" could land on Organize and leave the rail wherever it
    /// already was, intermittently, with nothing to see and nothing logged.
    @Test func theRouteWritesOrganizesStateThroughAppStorage() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("paletteRailLens = lens"),
                "the rail selection is no longer written through @AppStorage")
        #expect(host.contains("paletteScopePath = OrganizeScope(path: scope, providerRoot: root)?.path ?? \"\""),
                "the scope is no longer written through @AppStorage, or has stopped being normalized")
        let code = Self.codeOnly(host)
        #expect(code.contains("paletteRailLens = lens"),
                "stripping comments emptied the file — the checks below would be vacuous")
        for raw in ["UserDefaults.standard.set", "UserDefaults.standard.removeObject"] {
            #expect(!code.contains(raw),
                    "\(raw) is back — a write @AppStorage is documented to lose")
        }
    }

    /// The scope is normalized through `OrganizeScope`, whose `init?` is failable precisely so that
    /// pointing at the provider root **clears** the scope instead of storing the root as one. Two
    /// encodings of the global view is the state that type exists to make unrepresentable, and ⌘K
    /// is the newest writer of it.
    @Test func theRouteCannotMintASecondEncodingOfTheGlobalView() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("OrganizeScope(path: scope, providerRoot: root)"))
        #expect(!Self.codeOnly(host).contains("paletteScopePath = scope"),
                "the scope is being stored verbatim, so the provider root would be saved as a scope")
    }

    // MARK: One pane, asked once

    /// **The palette describes one pane, and must act on that same pane.**
    ///
    /// `tidyProviderRootExpanded` follows the *focused* pane in Compare, so with the right pane
    /// focused every folder and recent row in the index is relative to the right provider's tree.
    /// Three places then assumed the left one: the reveal focused `isLeft: true` (handing a path
    /// from one provider's tree to the other's, so the pane jumped to a folder that most likely
    /// does not exist there), "The current source" was marked by comparing to `leftProviderId`, and
    /// choosing a source switched the left pane. `paletteProviderId` names the rule once.
    @Test func thePaletteRevealsIntoThePaneItIndexed() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("var aimedAtRight: Bool { tidyTargetIsRight }"),
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
        #expect(Self.codeOnly(host).components(separatedBy: "tidyTargetIsRight").count - 1 == 1,
                "the aimed-pane rule is stated in more than one place again")
    }

    /// **The aim is read before the workspace moves.**
    ///
    /// `tidyProviderRootExpanded` and `tidyTargetIsRight` both follow the focused pane, and only
    /// Compare has two panes — so switching to Organize makes them the LEFT pane's answers. A
    /// scope string taken from a right-pane index and resolved afterwards fails `OrganizeScope`,
    /// which writes `""` and silently clears the scope instead of setting it: "organize legal"
    /// loses its folder. Ordering is the whole fix, so ordering is what this asserts.
    @Test func theOrganizeRouteResolvesItsScopeAgainstThePaneItCameFrom() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        let body = try #require(Self.aimOrganizeBody(host), "aimOrganize is gone — this scan is vacuous")
        let read = try #require(body.range(of: "let root = tidyProviderRootExpanded"),
                                "aimOrganize no longer resolves a provider root")
        let move = try #require(body.range(of: "workspaceSelection.wrappedValue = .filing"),
                                "aimOrganize no longer enters Organize")
        #expect(read.lowerBound < move.lowerBound,
                "the root is read after the workspace changes, so it names the wrong pane")
        // And the reveal is given that captured aim rather than re-reading it.
        #expect(body.contains("revealInSourcePane(scope, root: root, isLeft: !aimedAtRight)"),
                "the reveal re-reads an aim the workspace switch has already moved")
    }

    static func aimOrganizeBody(_ host: String) -> String? {
        guard let start = host.range(of: "private func aimOrganize(lens: OrganizeLens?, scope: String?) {")
        else { return nil }
        let rest = host[start.upperBound...]
        guard let end = rest.range(of: "\n    }") else { return nil }
        return String(rest[..<end.lowerBound])
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
