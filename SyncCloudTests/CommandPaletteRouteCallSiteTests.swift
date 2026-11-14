import Testing
import Foundation
import FileExplorer
import Sync
@testable import SyncCloud

/// How the host applies a `PaletteRoute`. `CommandPaletteTests` proves the routing table; what the
/// app then does with a route lives on a SwiftUI `View` no test can build, so this scans its source
/// for the decisions that would go wrong silently.
@Suite struct CommandPaletteRouteCallSiteTests {

    /// The rail and the scope are written through `@AppStorage`, never `UserDefaults.standard`:
    /// `@AppStorage` can lose a standard-domain write outright, so a ⌘K route could land on Organize
    /// and leave the rail where it was, intermittently and with nothing logged.
    @Test func theRouteWritesOrganizesStateThroughAppStorage() throws {
        let code = try macAppCode("CommandPaletteHost.swift")
        for raw in ["UserDefaults.standard.set", "UserDefaults.standard.removeObject"] {
            #expect(!code.contains(raw),
                    "\(raw) is back — a write @AppStorage is documented to lose")
        }
    }

    /// The scope is normalized by `setOrganizeScope(_:)`, ContentView's one writer of Organize's
    /// scope, whose resolver collapses the provider root to the cleared state. Two encodings of the
    /// global view is what `OrganizeScope`'s failable `init?` exists to rule out, so the host must
    /// not carry its own copy of that rule.
    @Test func theRouteCannotMintASecondEncodingOfTheGlobalView() throws {
        let code = try macAppCode("CommandPaletteHost.swift")
        #expect(!code.contains("OrganizeScope(path:"),
                "the host has grown its own copy of the normalization again")
        for verbatim in ["paletteScopePath =", "organizeScopePath ="] {
            #expect(!code.contains(verbatim),
                    "the scope is written directly (`\(verbatim)`), bypassing setOrganizeScope")
        }
    }

    // MARK: One pane, asked once

    /// The palette describes one pane, and must act on that same pane: with the right pane focused
    /// in Compare the index is relative to the right provider's tree, so the reveal, "The current
    /// source" and choosing a source must all follow that aim, stated once.
    @Test func thePaletteRevealsIntoThePaneItIndexed() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        #expect(host.contains("var aimedAtRight: Bool { lensTargetIsRight }"),
                "there is no single answer for which pane the palette is aimed at")
        #expect(host.contains("var paletteProviderId: String { aimedAtRight ? rightProviderId : leftProviderId }"),
                "the provider read no longer goes through the aim")
        #expect(host.contains("isLeft: isLeft ?? !aimedAtRight"),
                "the reveal always targets the left pane, even when the index came from the right one")
        #expect(!sourceCodeOnly(host).contains("isLeft: true"),
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
        #expect(sourceCodeOnly(host).components(separatedBy: "lensTargetIsRight").count - 1 == 1,
                "the aimed-pane rule is stated in more than one place again")
    }

    /// The aim is read before the workspace moves: after switching to Organize, the focused-pane
    /// reads give the left pane's answers, and a right-pane scope resolved then is silently cleared.
    /// So the root, the scope and the reveal's pane are each bound above the move.
    @Test func theOrganizeRouteResolvesItsScopeAgainstThePaneItCameFrom() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        // Comment-stripped, via the shared reader, because this function's own comments quote
        // the needles below.
        let body = try declarationBody(of: "func aimOrganize(lens: OrganizeLens?, scope: String?) {",
                                       in: host)
        let read = try #require(body.range(of: "let root = lensProviderRootExpanded"),
                                "aimOrganize no longer resolves a provider root")
        let move = try #require(body.range(of: "workspaceSelection.wrappedValue = .filing"),
                                "aimOrganize no longer enters Organize")
        #expect(read.lowerBound < move.lowerBound,
                "the root is read after the workspace changes, so it names the wrong pane")
        // The scope write shares the hazard: `setOrganizeScope` resolves against the live
        // `lensProviderRootExpanded`, so after the move it measures against the left pane's root.
        let write = try #require(body.range(of: "if let scope { setOrganizeScope(scope, providerRoot: lensProviderRootExpanded) }"),
                                 "aimOrganize no longer routes the scope through the one owner")
        #expect(write.lowerBound < move.lowerBound,
                "the scope is set after the workspace changes, so the owner resolves it against the wrong pane")
        // Which pane, on the same terms: `aimedAtRight` read after leaving Compare answers `false`
        // for a right-pane route, so the aim is bound before the move (a `var`, since a confirmed
        // swap moves the named provider to the left)…
        let aim = try #require(body.range(of: "revealIntoLeft = !aimedAtRight"),
                               "aimOrganize no longer captures which pane the palette was aimed at")
        #expect(aim.lowerBound < move.lowerBound,
                "the aim is captured after the workspace changes, so it names the wrong pane")
        // …and passed at the reveal, not re-read there. The absence check matters most: passing
        // the binding while a second live read remains looks fixed and isn't.
        #expect(body.contains("revealInSourcePane(scope, root: root, isLeft: revealIntoLeft)"),
                "the reveal is not given the captured aim")
        #expect(!body.contains("isLeft: !aimedAtRight"),
                "the reveal re-reads an aim the workspace switch has already moved")
    }

    // MARK: The pane swap Organize needs, and what happens if it is declined

    /// The three writes happen in one order, and Cancel comes before all of them. Organize shows the
    /// left pane, so a right-pane scope is offered a pane swap:
    ///
    /// - Scope, then swap: after the swap `setOrganizeScope` would measure against the other tree
    ///   and store `""`, the very clear the dialog exists to prevent.
    /// - Swap, then move: `swapPanesAction` can refuse, and a refusal after the move leaves the
    ///   user in Organize on the wrong provider.
    /// - Cancel returns before every write.
    @Test func theOrganizePaneSwapIsOrderedAndCancellingItWritesNothing() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        let body = try declarationBody(of: "func aimOrganize(lens: OrganizeLens?, scope: String?) {",
                                       in: host)
        let decide = try #require(body.range(of: "PaneLogic.organizeAimNeedsPaneSwap("),
                                  "the swap decision is no longer the one pure rule — a second copy cannot be held to the resolver")
        let confirm = try #require(body.range(of: "confirmOrganizePaneSwap("),
                                   "the route no longer asks before moving the user's panes")
        let scopeWrite = try #require(body.range(of: "setOrganizeScope(scope, providerRoot:"),
                                      "aimOrganize no longer routes the scope through the one owner")
        let swap = try #require(body.range(of: "swapPanesAction()"),
                                "aimOrganize no longer swaps the panes for a right-pane scope")
        let move = try #require(body.range(of: "workspaceSelection.wrappedValue = .filing"),
                                "aimOrganize no longer enters Organize")

        #expect(decide.lowerBound < confirm.lowerBound,
                "the dialog is raised before anything decides it is needed")
        #expect(scopeWrite.lowerBound < swap.lowerBound,
                "the panes are swapped before the scope is written, so the one writer resolves the folder against the provider it is NOT in and stores \"\" — the silent clear, by the fix's own hand")
        #expect(swap.lowerBound < move.lowerBound,
                "the workspace moves before the swap, so a refused swap strands the user in Organize on the other provider")
        #expect(confirm.lowerBound < scopeWrite.lowerBound,
                "the scope is written before the user has agreed to anything — Cancel would leave half the route applied")
        // The refusal must leave, not fall through: between the question and the first write there
        // has to be a way out, or "Cancel" swaps nothing and applies everything anyway.
        let betweenAskAndWrite = textBetween(body, from: confirm.upperBound, to: scopeWrite.lowerBound)
        #expect(betweenAskAndWrite?.contains("return") == true,
                "nothing returns between the confirm and the first write — cancelling falls through and the route applies regardless")

        // The swap itself is the app's atomic one. Exchanging the two ids here would leave the
        // manager's paired focus, selections and histories behind, and fire both panes'
        // provider-switch teardowns that `swapPanesAction`'s ProviderPinPlan exists to suppress.
        for handRolled in ["leftProviderId = rightProviderId", "rightProviderId = leftProviderId",
                           "syncManager.swapPanes()", "PaneLogic.swappedProviderIds"] {
            #expect(!body.contains(handRolled),
                    "the panes are swapped by hand (`\(handRolled)`) instead of through swapPanesAction")
        }
    }

    /// The dialog is not styled as a destruction: a pane swap deletes nothing, and spending
    /// `confirmDestructive`'s caution signal here dulls it on the alert that really moves files to
    /// the Trash.
    @Test func thePaneSwapPromptIsNotDressedAsADestructiveAction() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        let code = sourceCodeOnly(host)
        #expect(code.contains("NativeAlerts.confirmChange("),
                "the pane-swap prompt no longer goes through the non-destructive confirm")
        #expect(!code.contains("confirmDestructive"),
                "the pane swap asks with the destructive alert — caution icon and all — for a reversible view change")
        #expect(code.contains("confirmTitle: \"Swap Panes\""),
                "the confirm button no longer names what it does; “OK” on a two-state explanation is a coin toss")
    }

    /// Every route case is applied. A `default:` arm would let a case added to `PaletteRoute` — a
    /// public enum in another module — compile here and silently do nothing.
    @Test func everyRouteCaseIsHandledWithoutADefaultArm() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        // No `case .storage:`: Storage is part of Organize, its place derived from
        // `OrganizeLens.railItems`, so it arrives through `case .organize(let lens, let scope):`
        // below, with a scope.
        for arm in ["case .browse:", "case .compare:", "case .editor:",
                    "case .organize(let lens, let scope):",
                    "case .person(let id):", "case .provider(let id):", "case .folder(let path):",
                    // Listed apart from `.folder` because it is a separate destination: the same
                    // reveal, after a source switch the pane has to survive.
                    "case .folderInSource(let providerId, let path):",
                    "case .action(let action):", "case .settings(let raw):"] {
            #expect(host.contains(arm), "runPaletteRoute no longer handles `\(arm)`")
        }
        #expect(host.contains("workspaceSelection.wrappedValue = .browse"))
        #expect(!(try declarationBody(of: "func runPaletteRoute(_ route: PaletteRoute) {", in: host)).contains("default:"),
                "a default arm would swallow a route case added upstream")
    }

    // MARK: Settings

    /// The host offers every Settings tab by passing the whole derived list through: a hand-picked
    /// subset here compiles and makes the other tabs unreachable from ⌘K, with nothing failing.
    @Test func theHostOffersEverySettingsTab() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        let code = sourceCodeOnly(host)
        #expect(code.contains("settingsTabs: SettingsView.SettingsTab.digests.map"),
                "the palette index no longer takes the whole derived tab list — a subset here is silent")
        #expect(!code.contains("SettingsTab.allCases.filter"),
                "the tab list is being filtered at the call site; a tab dropped here fails nothing")
    }

    /// A tab route goes through `openSettings(on:)`, never `showSettings = true` plus a write. That
    /// door presets the tab before the latch (a later preset shows the previous page for a frame)
    /// and puts the displaced tab back on a refused open; a hand-rolled latch looks right nearly
    /// every time.
    @Test func aTabRouteGoesThroughTheOneDeepLinkDoor() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        let code = sourceCodeOnly(host)
        #expect(code.contains("openSettings(on: place)"),
                "the Settings tab route no longer opens through openSettings(on:)")
        // `runPaletteAction`'s `case .settings` is the one legitimate bare latch in this file —
        // "put Settings back where I left it" names no tab. Anything beyond that one is the
        // hand-rolled open this test exists to refuse.
        #expect(code.components(separatedBy: "showSettings = true").count - 1 == 1,
                "a second bare `showSettings = true` appeared — a deep link that skips the door")
    }

    /// The open log counts the tabs, like the other three things the index carries: they cross a
    /// package wall, and with no count an empty list and a full one log the same line.
    @Test func theOpenLogReportsHowManySettingsTabsWereIndexed() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        #expect(sourceCodeOnly(host).contains("index.settingsTabs.count) settings tabs"),
                "the palette-open log no longer counts the settings tabs — an empty list would log identically")
    }

    /// A raw value that names no tab is reported and refused, not opened on whatever was last
    /// selected. The string crosses a package wall, so this can happen, and ↩ on a row that said
    /// Appearance delivering Advanced is worse than ↩ doing nothing.
    @Test func anUnknownTabRawValueIsRefusedOutLoud() throws {
        let host = try macAppFile("CommandPaletteHost.swift")
        let code = sourceCodeOnly(host)
        #expect(code.contains("guard let place = SettingsPlace(paletteRoute: raw)"),
                "the raw value is no longer checked before it is used")
        #expect(code.contains("is not a settings tab"),
                "an unrecognised tab is no longer logged — the palette would appear to do nothing")
    }
}
