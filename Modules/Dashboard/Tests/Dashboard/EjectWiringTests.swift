import Foundation
import AppKit
import Testing
import Sync
@testable import Dashboard

/// The eject half, and the wiring that makes it real. `MountedVolumeMemoryTests` and
/// `VolumeMembershipTests` pin the rules; this pins that something calls them. Most of the wiring
/// lives in `MacApp/`, which is in no SPM package, so a source scan is the only reading available
/// from here. The failure is silent: a subscription never made, or a menu item wired to a renamed
/// handler, leaves every rule green and the feature absent.
@Suite struct EjectWiringTests {

    // MARK: The notice can say something with nothing to offer

    /// Every notice has a way off the column. Nothing else in the host clears one, so a notice
    /// without a link would sit at the bottom of the sidebar all session. An eject-removal has
    /// nothing to undo, the volume being gone, so its verb is "Dismiss".
    @Test func everyNoticeKindNamesItsLink() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        #expect(host.contains("case .dismiss: return \"Dismiss\""),
                "the eject notice has no link, so nothing can clear it")
        #expect(host.contains("case .undoPromotion: return \"Remove\""),
                "the promotion notice lost its Remove")
        // And the host clears it: a "Dismiss" that dismisses nothing is worse than none.
        #expect(host.contains("func actOnFolderSidebarNotice"),
                "the notice's link is not routed anywhere")
        #expect(host.contains("folderSidebarNotice = nil"),
                "acting on a notice never clears it")
    }

    /// The removal notice must not say "ejected": `didUnmount` fires for a card pulled out of the
    /// reader as readily as for one ejected in Finder, and macOS doesn't say which.
    @Test func theRemovalNoticeDoesNotClaimTheCardWasEjected() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        let handler = try #require(Self.body(of: "func forgetFolderSidebarSourcesOnUnmount", in: host),
                                   "the unmount handler was renamed — this scan now reads nothing")
        #expect(handler.contains("is no longer connected"),
                "the removal notice no longer states the neutral fact")
        // Matched on the literal's opening, capital and trailing space included, so a comment
        // beside it explaining why the word is wrong doesn't trip the guard.
        #expect(!handler.contains("\"Ejected "),
                "the removal notice claims an eject it cannot know happened")
    }

    /// The eject must leave the main actor. `unmountAndEjectDevice(at:)` is synchronous and macOS
    /// flushes the volume first, which with writes in flight freezes the window for seconds. An
    /// `async` member of a `@MainActor` type would hop straight back, so the detach is under test,
    /// not the `await`.
    @Test func ejectingDoesNotRunOnTheMainActor() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        #expect(host.contains("nonisolated static func ejectVolume(at url: URL) async throws"),
                "the eject helper is no longer nonisolated — the await hops back to main")
        #expect(host.contains("Task.detached(priority: .userInitiated)"),
                "the eject runs inline on whatever actor called it")
        // Through `NSWorkspace`, and a refusal (a file on the card still open) must reach the
        // user, not leave a menu item that silently does nothing.
        #expect(host.contains("NSWorkspace.shared.unmountAndEjectDevice"),
                "Eject does not actually eject anything")
        #expect(host.contains("Could not eject"),
                "a refused eject is swallowed rather than reported")
    }

    /// The volume walk stays off the render path. Inline in the sidebar's arguments it would put a
    /// `mountedVolumeURLs` call and a resource read per volume into every body evaluation, which
    /// runs on hover and every drag frame.
    @Test func theEjectableSetIsResolvedWithTheRowsNotInTheBody() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        #expect(host.contains("ejectablePaths: folderSidebarEjectablePaths"),
                "the sidebar is handed a set built inline in its own arguments")
        let refresh = try #require(Self.body(of: "func refreshFolderSidebarRows", in: host),
                                   "the refresh was renamed — this scan now reads nothing")
        #expect(refresh.contains("folderSidebarEjectablePaths = Set("),
                "the ejectable set is not resolved on the row-refresh pass")
    }

    /// The unmount refreshes the column whatever it decided: the volume's own Locations row comes
    /// from the mounted-volume walk, so it is stale once the notification arrives, even for a card
    /// that was never a source.
    @Test func anUnmountAlwaysRefreshesTheColumn() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        let handler = try #require(Self.body(of: "func forgetFolderSidebarSourcesOnUnmount", in: host),
                                   "the unmount handler was renamed — this scan now reads nothing")
        // In the `defer`: the handler returns early twice below it (an unrecognised volume, and one
        // with nothing on it), and a plain call at the end reaches neither. Checking the order of
        // the strings instead would wrongly fail a correct handler whose first guard precedes the
        // defer.
        let deferBlock = try #require(
            handler.range(of: "defer {").flatMap { start in
                handler.range(of: "\n        }", range: start.upperBound..<handler.endIndex)
                    .map { String(handler[start.upperBound..<$0.lowerBound]) }
            }, "the unmount handler has no defer — its early returns now skip the refresh")
        #expect(deferBlock.contains("refreshFolderSidebarRows()"),
                "the refresh sits outside the defer, so an unmount with nothing to remove leaves the row on screen")
        #expect(deferBlock.contains("MountedVolumeMemory.shared.forget(volume: path)"),
                "the record is dropped outside the defer — an early return now leaks it")
    }

    // MARK: The row's verb

    @Test func theSidebarOffersEjectAndKeysItByMountPoint() throws {
        let sidebar = try DashboardSource.read("FolderSidebar.swift")
        #expect(sidebar.contains("ejectablePaths.contains(FolderSidebarView.mountKey(source.absolutePath))"),
                "Eject is offered on something other than a normalised mount point")
        #expect(sidebar.contains("Button(\"Eject \\(source.name)…\")"),
                "the context menu offers no Eject, or its item no longer says it will ask first")
    }

    /// Ejecting is confirmed, and the confirmation names the part beyond this app: the volume
    /// leaves Finder and every other app at once, so mentioning only the source would describe the
    /// smaller half of the click.
    @Test func theEjectConfirmationSaysItUnmountsFromMacOS() {
        for losesItsSource in [false, true] {
            let message = FolderSidebarView.PendingRowAction.eject(Self.card, losesItsSource: losesItsSource).message
            #expect(message.contains("unmounted from macOS, not just from SyncCloud"),
                    "the eject confirmation does not say the unmount is system-wide (losesItsSource: \(losesItsSource))")
            #expect(message.contains("leaves Finder and every other app"),
                    "the eject confirmation does not name who else loses the volume (losesItsSource: \(losesItsSource))")
            // Ejecting changes nothing on the card, the reassurance a person actually wants.
            #expect(message.contains("Nothing on it is changed."),
                    "the eject confirmation no longer says the card's contents are untouched (losesItsSource: \(losesItsSource))")
        }
    }

    /// The menu arms a confirmation rather than acting, for both verbs. An `onEjectSource` called
    /// straight from the button would pass a scan that only checks the handler exists.
    @Test func bothConsequentialVerbsGoThroughTheConfirmation() throws {
        let sidebar = try DashboardSource.read("FolderSidebar.swift")
        #expect(sidebar.contains("arm(.eject(source, losesItsSource:"),
                "Eject acts immediately instead of asking")
        #expect(sidebar.contains("arm(.removeSource(source))"),
                "Remove Source acts immediately instead of asking")
        #expect(!sidebar.contains("Button(\"Eject \\(source.name)…\") { onEjectSource(source) }"),
                "the Eject button calls the handler directly, bypassing the dialog")
        // One dialog, one state. SwiftUI presents two `confirmationDialog` modifiers armed at once
        // unreliably, and both could be armed here by right-clicking a second row while the first
        // dialog is up.
        #expect(sidebar.components(separatedBy: ".confirmationDialog(").count - 1 == 1,
                "the column now has more than one confirmation dialog")
        // The title is latched. It is a plain parameter, not part of `presenting:`, so it is
        // re-read on every render, including during the dismissal animation, when the action is
        // nil again and a derived title would render as an empty heading.
        #expect(sidebar.contains(".confirmationDialog(pendingRowTitle,"),
                "the dialog's title is derived from a value that goes nil as it dismisses")
        #expect(sidebar.contains("private func arm(_ action: PendingRowAction)"),
                "the title and the action are set separately and can drift")
    }

    /// Red means "can't be got back". Removing a source loses its name, landing folder and enabled
    /// flag, as does ejecting a card that is one; ejecting any other card costs only the mount,
    /// which plugging it in returns. Making that red would teach the colour to mean nothing.
    @Test func onlyTheIrreversibleConfirmationsAreDestructive() {
        #expect(FolderSidebarView.PendingRowAction.removeSource(Self.card).isDestructive)
        #expect(!FolderSidebarView.PendingRowAction.eject(Self.card, losesItsSource: false).isDestructive,
                "ejecting a card that keeps its source is dressed as destructive")
        #expect(FolderSidebarView.PendingRowAction.eject(Self.card, losesItsSource: true).isDestructive,
                "ejecting a card that loses its source is not dressed as destructive")
    }

    private static let card = SidebarSourceRow(id: "/Volumes/CARD", name: "CARD", detail: nil,
                                               symbol: "sdcard", absolutePath: "/Volumes/CARD",
                                               band: .device, state: .configured, isAvailable: true)

    /// The dialog must not promise a source removal that won't happen. Eject is offered on anything
    /// Finder would eject, network shares included, but unmounting a share leaves its sources alone
    /// (`Volume.losesItsSourcesOnUnmount`). Asking only whether the row is a source would warn a
    /// share's user of a loss that never comes.
    @Test func theEjectDialogAsksWhetherTheSourceWillActuallyGo() throws {
        let sidebar = try DashboardSource.read("FolderSidebar.swift")
        #expect(sidebar.contains("removableSourceIds.contains(source.id)")
                && sidebar.contains("&& detachablePaths.contains(key)"),
                "the eject dialog decides its source clause on the row's status alone")
        #expect(sidebar.contains("case eject(SidebarSourceRow, losesItsSource: Bool)"),
                "the payload is named for the row's status rather than for the consequence")
    }

    /// The two sets differ, and the narrower one comes from the model's own rule. A host predicate
    /// for `detachablePaths` could drift from the one `MountedVolumeMemory` applies and make the
    /// dialog wrong.
    @Test func theDetachableSetComesFromTheModelsOwnRule() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        #expect(host.contains("volumes.filter(\\.losesItsSourcesOnUnmount)"),
                "the host re-derives which volumes lose their sources instead of asking the model")
        #expect(host.contains("detachablePaths: folderSidebarDetachablePaths"),
                "the sidebar is not told which volumes actually lose their sources")
        // The rule itself is in `MountedVolumeMemoryTests.theSidebarVolumeCarriesLocality`.
    }

    /// One mounted-volume walk per refresh, not two. `mountedVolumeURLs` plus a resource read per
    /// volume can block on an unreachable network mount, so recording the volumes and building the
    /// rows share one walk (as the refresh's `reachable` call answers both its lists in one pass).
    @Test func theRefreshWalksTheVolumesOnce() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        let refresh = try #require(Self.body(of: "func refreshFolderSidebarRows", in: host),
                                   "the refresh was renamed — this scan now reads nothing")
        #expect(refresh.components(separatedBy: "Self.mountedVolumes()").count - 1 == 1,
                "the refresh walks the mounted volumes more than once")
        #expect(host.contains("static func deviceEntries(_ volumes: [SidebarSourceModel.Volume])"),
                "deviceEntries makes its own walk again, so the refresh pays for two")
    }

    /// Both sides of `ejectablePaths` must key the same way, or the set never matches and the item
    /// silently never appears.
    @Test func bothSidesOfTheEjectableSetNormaliseTheSameWay() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        #expect(host.contains("FolderSidebarView.mountKey($0.path)"),
                "the caller builds the ejectable set without normalising the mount point")
        #expect(FolderSidebarView.mountKey("/Volumes/CARD/") == FolderSidebarView.mountKey("/Volumes/CARD"),
                "the shared key does not fold a trailing slash")
    }

    // MARK: The three subscriptions that make an unmount actionable

    /// Every notification that changes what is mounted drops the cached walk; `willUnmount` must
    /// not. The cache is invalidated only by the events that can change its answer, so a handler
    /// that forgot would leave the column showing a gone volume or missing a new one, silently.
    ///
    /// `willUnmount` is the trap: the volume hasn't gone yet, and dropping the cache there sends
    /// this handler's own record back to a filesystem being torn down, the walk most likely to
    /// block.
    ///
    /// All three are subscribed (each block is required below), because `didUnmount` only says a
    /// volume went; only a record taken while it was mounted says whether it was a card or a share.
    @Test func everyMountEventDropsTheCachedWalkExceptTheOneThatMustNot() throws {
        let content = try DashboardSource.app("ContentView.swift")
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        try #require(host.contains("static func forgetMountedVolumes()"),
                     "the invalidation is gone — this scan is aimed at nothing")
        #expect(content.contains("forgetFolderSidebarSourcesOnUnmount"),
                "the unmount notification is subscribed to but not acted on")
        // The launch walk. `refreshFolderSidebarRows` returns early wherever the column is hidden,
        // so a card already in the reader would otherwise never be recorded.
        //
        // Through `mountedVolumesAsLastSeen`, the walk and its cache in one, so launch and the
        // refresh after it walk once; each walk can block on a network mount. Asserted on the
        // accessor so an edit reaching past the cache fails here.
        #expect(content.contains("Self.rememberMountedVolumes(Self.mountedVolumesAsLastSeen())"),
                "nothing records the volumes already mounted at launch")
        #expect(!content.contains("Self.rememberMountedVolumes(Self.mountedVolumes())"),
                "a recorder walks the volumes directly again, so launch and each mount pay for two walks")

        for handler in ["didMountNotification", "didUnmountNotification"] {
            let block = try #require(Self.between("publisher(for: NSWorkspace.\(handler))", "}", in: content),
                                     "the \(handler) subscription was restructured — this scan reads nothing")
            #expect(block.contains("Self.forgetMountedVolumes()"),
                    "\(handler) leaves the cached volume walk in place, so the column keeps a stale set of disks")
        }

        let willUnmount = try #require(
            Self.between("publisher(for: NSWorkspace.willUnmountNotification)", "}", in: content),
            "the willUnmount subscription was restructured — this scan reads nothing")
        #expect(!willUnmount.contains("Self.forgetMountedVolumes()"),
                "willUnmount drops the cache while the volume is mid-unmount, sending its own record straight back to the filesystem it is meant to avoid")
        #expect(willUnmount.contains("Self.rememberMountedVolumes(Self.mountedVolumesAsLastSeen()"),
                "willUnmount no longer records what the volume was — the unmount cannot answer that itself")

        // And the rename, which moves a mount point rather than adding or removing one.
        #expect(content.contains("FolderJumpStore.shared.followVolumeRename(from: old, to: new)"),
                "the rename handler was restructured — this scan reads nothing")
        let rename = try #require(Self.between("FolderJumpStore.shared.followVolumeRename(from: old, to: new)",
                                               "refreshFolderSidebarRows()", in: content),
                                  "the rename handler no longer refreshes — this scan reads nothing")
        #expect(rename.contains("Self.forgetMountedVolumes()"),
                "a rename leaves the cached walk naming a mount point that no longer exists")
    }

    @Test func theUnmountHandlerConsultsTheMemoryBeforeRemovingAnything() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        #expect(host.contains("MountedVolumeMemory.shared.isDetachable(volume: path)"),
                "sources are removed on an unmount without checking what the volume was")
        #expect(host.contains("settings.removeFolderSources(onVolume: path)"),
                "the unmount does not remove the sources on the volume")
    }

    /// An unmount leaves the pins alone: they are keyed by path, so a card plugged back in and added
    /// again finds them where they were. Tidying them up on unmount gains nothing and loses them.
    @Test func anUnmountDoesNotClearThePinnedFolders() throws {
        let host = try DashboardSource.app("ContentView+FolderSidebar.swift")
        let handler = try #require(Self.body(of: "func forgetFolderSidebarSourcesOnUnmount", in: host),
                                   "the unmount handler was renamed — this scan now reads nothing")
        #expect(!handler.contains("FolderJumpStore"),
                "the unmount handler now touches the jump store; the pins were meant to survive it")
    }

    /// The text between two markers, for a scan that reads one member of a type rather than a whole
    /// function. Nil when either marker has moved, so a rename fails loudly instead of scanning an
    /// empty string.
    private static func between(_ start: String, _ end: String, in source: String) -> String? {
        guard let from = source.range(of: start),
              let to = source.range(of: end, range: from.upperBound..<source.endIndex)
        else { return nil }
        return String(source[from.upperBound..<to.lowerBound])
    }

    /// The reader most scans above go through: one member's body, up to the next member, rather
    /// than a fixed `prefix(n)` that would stop covering the end of a function once it grows.
    private static func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        // The next member's declaration line at the same indentation: every member of this
        // extension is declared at four spaces, so this is the real boundary.
        guard let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    func ")
                        ?? rest.range(of: "\n    nonisolated ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }
}
