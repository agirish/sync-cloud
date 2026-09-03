import Foundation
import AppKit
import Testing
import Sync
@testable import Dashboard

/// **The eject half, and the wiring that makes it real.**
///
/// `MountedVolumeMemoryTests` and `VolumeMembershipTests` pin the rules; this pins that anything
/// calls them. Three of the four pieces live in `MacApp/`, which is in no SPM package and which
/// only CI's app-target step even compiles, so a source scan is the only reading of it available
/// from here — and the failure this guards against is silent by construction: a subscription that
/// is never made, or a menu item wired to a handler that was renamed, leaves every rule below
/// green and the feature absent.
@Suite struct EjectWiringTests {

    // MARK: The notice can say something with nothing to offer

    /// **Every notice has a way off the column.** Nothing else in the host clears one, so a notice
    /// whose link was omitted — the shape this feature nearly shipped with — would sit at the
    /// bottom of the sidebar for the rest of the session. An eject-removal has nothing to *undo*,
    /// the volume being gone, and "Dismiss" is the honest verb for that rather than no verb.
    @Test func everyNoticeKindNamesItsLink() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        #expect(host.contains("case .dismiss: return \"Dismiss\""),
                "the eject notice has no link, so nothing can clear it")
        #expect(host.contains("case .undoPromotion: return \"Remove\""),
                "the promotion notice lost its Remove")
        // And the host actually clears it: a "Dismiss" that dismisses nothing is worse than none.
        #expect(host.contains("func actOnFolderSidebarNotice"),
                "the notice's link is not routed anywhere")
        #expect(host.contains("folderSidebarNotice = nil"),
                "acting on a notice never clears it")
    }

    /// The messages the two paths post. **Neither may say "ejected"**: `didUnmount` fires for a card
    /// pulled out of the reader as readily as for one ejected in Finder, and macOS does not say
    /// which — so naming the tidy one tells the user something the app does not know, in the exact
    /// case where they did the untidy thing.
    @Test func theRemovalNoticeDoesNotClaimTheCardWasEjected() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        let handler = try #require(Self.body(of: "func forgetFolderSidebarSourcesOnUnmount", in: host),
                                   "the unmount handler was renamed — this scan now reads nothing")
        #expect(handler.contains("is no longer connected"),
                "the removal notice no longer states the neutral fact")
        // Matched on the literal's opening, capital and trailing space included, so the comment
        // beside it explaining WHY the word is wrong does not trip its own guard — the shape that
        // makes a text scan report the thing it is documenting.
        #expect(!handler.contains("\"Ejected "),
                "the removal notice claims an eject it cannot know happened")
    }

    /// **The eject itself must leave the main actor.** `unmountAndEjectDevice(at:)` is synchronous
    /// and macOS flushes the volume before unmounting it, which on a card with writes in flight is
    /// seconds of frozen window. An `async` member of a `@MainActor` type would hop straight back,
    /// so the detach is the thing under test, not the `await`.
    @Test func ejectingDoesNotRunOnTheMainActor() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        #expect(host.contains("nonisolated static func ejectVolume(at url: URL) async throws"),
                "the eject helper is no longer nonisolated — the await hops back to main")
        #expect(host.contains("Task.detached(priority: .userInitiated)"),
                "the eject runs inline on whatever actor called it")
    }

    /// **The volume walk is off the render path.** It was inline in the sidebar's arguments for one
    /// build, which put a `mountedVolumeURLs` call plus a resource read per volume into every body
    /// evaluation — and that body re-evaluates on hover and on every drag frame.
    @Test func theEjectableSetIsResolvedWithTheRowsNotInTheBody() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        #expect(host.contains("ejectablePaths: folderSidebarEjectablePaths"),
                "the sidebar is handed a set built inline in its own arguments")
        let refresh = try #require(Self.body(of: "func refreshFolderSidebarRows", in: host),
                                   "the refresh was renamed — this scan now reads nothing")
        #expect(refresh.contains("folderSidebarEjectablePaths = Set("),
                "the ejectable set is not resolved on the row-refresh pass")
    }

    /// The unmount has to refresh the column **whatever it decided**: the volume's own Locations
    /// row comes from the mounted-volume walk, so it is stale the moment the notification arrives,
    /// even for a card that was never a source.
    @Test func anUnmountAlwaysRefreshesTheColumn() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        let handler = try #require(Self.body(of: "func forgetFolderSidebarSourcesOnUnmount", in: host),
                                   "the unmount handler was renamed — this scan now reads nothing")
        // **In the `defer`, which is the mechanism and not merely where the line happens to sit.**
        // The handler returns early twice below it — an unrecognised volume, and one with nothing
        // on it — and a plain call at the end reaches neither. Asserting on the ORDER of the two
        // strings would pass for a `defer` and for a first-line call alike, and fail for a correct
        // handler whose first guard (the malformed notification) precedes the defer, which is
        // exactly what it did.
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
        let sidebar = try Self.source("Sources/Dashboard/FolderSidebar.swift")
        #expect(sidebar.contains("ejectablePaths.contains(FolderSidebarView.mountKey(source.absolutePath))"),
                "Eject is offered on something other than a normalised mount point")
        #expect(sidebar.contains("Button(\"Eject \\(source.name)…\")"),
                "the context menu offers no Eject, or its item no longer says it will ask first")
    }

    /// **Ejecting is confirmed, and the confirmation has to name the part that is not about this
    /// app.** Unmounting reaches past SyncCloud — the volume leaves Finder and every other app at
    /// the same moment — and a dialog that only mentioned the source would be describing the
    /// smaller half of what the click does.
    @Test func theEjectConfirmationSaysItUnmountsFromMacOS() throws {
        let sidebar = try Self.source("Sources/Dashboard/FolderSidebar.swift")
        let message = try #require(Self.between("var message: String {", "var verb: String {", in: sidebar),
                                   "the dialog's message was restructured — this scan now reads nothing")
        #expect(message.contains("unmounted from macOS, not just from SyncCloud"),
                "the eject confirmation does not say the unmount is system-wide")
        #expect(message.contains("leaves Finder and every other app"),
                "the eject confirmation does not name who else loses the volume")
        // Ejecting changes nothing ON the card, and that is the reassurance a person actually wants.
        #expect(message.contains("Nothing on it is changed."),
                "the eject confirmation no longer says the card's contents are untouched")
    }

    /// The menu arms a confirmation rather than acting, for BOTH verbs — an `onEjectSource` called
    /// straight from the button is the shape this replaced, and it looks identical from a scan that
    /// only checks the handler exists.
    @Test func bothConsequentialVerbsGoThroughTheConfirmation() throws {
        let sidebar = try Self.source("Sources/Dashboard/FolderSidebar.swift")
        #expect(sidebar.contains("arm(.eject(source, losesItsSource:"),
                "Eject acts immediately instead of asking")
        #expect(sidebar.contains("arm(.removeSource(source))"),
                "Remove Source acts immediately instead of asking")
        #expect(!sidebar.contains("Button(\"Eject \\(source.name)…\") { onEjectSource(source) }"),
                "the Eject button calls the handler directly, bypassing the dialog")
    }

    /// **Red means "cannot be got back".** Removing a source loses the name, the landing folder and
    /// the enabled flag, and so does ejecting a card that IS one — while ejecting a card that is not
    /// costs only the mount, which plugging it in returns. Dressing that as destructive would teach
    /// the colour to mean nothing.
    @Test func onlyTheIrreversibleConfirmationsAreDestructive() throws {
        let sidebar = try Self.source("Sources/Dashboard/FolderSidebar.swift")
        let rule = try #require(Self.between("var isDestructive: Bool {", "\n    }", in: sidebar),
                                "the destructive rule was renamed — this scan now reads nothing")
        #expect(rule.contains("case .removeSource: return true"))
        #expect(rule.contains("case .eject(_, let losesItsSource): return losesItsSource"),
                "ejecting a card that keeps its source is dressed as destructive, or one that loses it is not")
    }

    /// **One dialog, one state.** Two `confirmationDialog` modifiers on a view SwiftUI can arm at
    /// once is a shape it presents unreliably, and both can be armed here — a right-click on a
    /// second row while the first dialog is up.
    @Test func thereIsOneConfirmationDialogForBothVerbs() throws {
        let sidebar = try Self.source("Sources/Dashboard/FolderSidebar.swift")
        #expect(sidebar.components(separatedBy: ".confirmationDialog(").count - 1 == 1,
                "the column now has more than one confirmation dialog")
    }

    /// **The dialog may not promise a source removal that will not happen.**
    ///
    /// Eject is offered on anything Finder would eject, which includes a network share — Finder
    /// draws one an eject arrow. But a share is not local, so unmounting it leaves its sources
    /// alone (`Volume.losesItsSourcesOnUnmount`). Asking only whether the row is a source, which
    /// is what this did, told a user with a share as a source that they were about to lose it.
    @Test func theEjectDialogAsksWhetherTheSourceWillActuallyGo() throws {
        let sidebar = try Self.source("Sources/Dashboard/FolderSidebar.swift")
        #expect(sidebar.contains("removableSourceIds.contains(source.id)")
                && sidebar.contains("&& detachablePaths.contains(key)"),
                "the eject dialog decides its source clause on the row's status alone")
        #expect(sidebar.contains("case eject(SidebarSourceRow, losesItsSource: Bool)"),
                "the payload is named for the row's status rather than for the consequence")
    }

    /// **The two sets are different sets, and the narrower one is the model's own rule.** If the
    /// host built `detachablePaths` from its own predicate, that predicate and the one
    /// `MountedVolumeMemory` applies could drift — which is how the dialog came to be wrong in the
    /// first place.
    @Test func theDetachableSetComesFromTheModelsOwnRule() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        #expect(host.contains("volumes.filter(\\.losesItsSourcesOnUnmount)"),
                "the host re-derives which volumes lose their sources instead of asking the model")
        #expect(host.contains("detachablePaths: folderSidebarDetachablePaths"),
                "the sidebar is not told which volumes actually lose their sources")
        // The rule itself, so a green scan cannot sit over a predicate that says the wrong thing.
        let card = SidebarSourceModel.Volume(name: "CARD", path: "/Volumes/CARD",
                                             isRemovable: true, isInternal: false)
        let share = SidebarSourceModel.Volume(name: "Archive", path: "/Volumes/Archive",
                                              isRemovable: true, isInternal: false, isLocal: false)
        #expect(card.losesItsSourcesOnUnmount)
        #expect(!share.losesItsSourcesOnUnmount, "a network share is ejectable but does not lose its sources")
    }

    /// **One mounted-volume walk per refresh, not two.** `mountedVolumeURLs` plus a resource read
    /// per volume is not free, and under an unreachable network mount each read can block — the
    /// same reason the refresh's `reachable` call answers both its lists in one pass. Recording the
    /// volumes and building the rows both need the walk, and asking twice doubled that exposure.
    @Test func theRefreshWalksTheVolumesOnce() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        let refresh = try #require(Self.body(of: "func refreshFolderSidebarRows", in: host),
                                   "the refresh was renamed — this scan now reads nothing")
        #expect(refresh.components(separatedBy: "Self.mountedVolumes()").count - 1 == 1,
                "the refresh walks the mounted volumes more than once")
        #expect(host.contains("static func deviceEntries(_ volumes: [SidebarSourceModel.Volume])"),
                "deviceEntries makes its own walk again, so the refresh pays for two")
    }

    /// **The dialog's title is latched.** It is a plain parameter rather than part of the
    /// `presenting:` mechanism, so it is re-read on every render — including the ones during the
    /// dismissal animation, when the action has gone back to nil and a title derived from it would
    /// render as an empty heading on the way out.
    @Test func theDialogTitleCannotGoEmptyWhileItDismisses() throws {
        let sidebar = try Self.source("Sources/Dashboard/FolderSidebar.swift")
        #expect(sidebar.contains(".confirmationDialog(pendingRowTitle,"),
                "the dialog's title is derived from a value that goes nil as it dismisses")
        #expect(sidebar.contains("private func arm(_ action: PendingRowAction)"),
                "the title and the action are set separately and can drift")
    }

    /// **The two sides of `ejectablePaths` must key the same way**, or the set never matches and
    /// the item silently never appears — which is exactly what a `Set<String>` mismatch looks like
    /// from the outside.
    @Test func bothSidesOfTheEjectableSetNormaliseTheSameWay() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        #expect(host.contains("FolderSidebarView.mountKey($0.path)"),
                "the caller builds the ejectable set without normalising the mount point")
        #expect(FolderSidebarView.mountKey("/Volumes/CARD/") == FolderSidebarView.mountKey("/Volumes/CARD"),
                "the shared key does not fold a trailing slash")
    }

    /// Eject is `NSWorkspace`'s, and a refusal — a file on the card still open — has to reach the
    /// user. A menu item that silently does nothing is the failure mode this area has now been
    /// reported for twice.
    @Test func ejectingGoesThroughNSWorkspaceAndReportsARefusal() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        #expect(host.contains("NSWorkspace.shared.unmountAndEjectDevice"),
                "Eject does not actually eject anything")
        #expect(host.contains("Could not eject"),
                "a refused eject is swallowed rather than reported")
    }

    // MARK: The three subscriptions that make an unmount actionable

    /// **All three, because the unmount alone cannot answer its own question.** `didUnmount` says a
    /// volume went; only a record taken while it was mounted says whether it was a card or a share.
    /// Dropping any one of these leaves the feature working for some cards and not others, which is
    /// the worst of the available failures.
    @Test func contentViewRecordsMountsAndActsOnUnmounts() throws {
        let content = try Self.appSource("ContentView.swift")
        for name in ["didMountNotification", "willUnmountNotification", "didUnmountNotification"] {
            #expect(content.contains(name), "nothing subscribes to \(name)")
        }
        #expect(content.contains("forgetFolderSidebarSourcesOnUnmount"),
                "the unmount notification is subscribed to but not acted on")
        // The launch walk. `refreshFolderSidebarRows` returns early wherever the column is hidden,
        // so a card already in the reader would otherwise never be recorded at all.
        //
        // **Through `mountedVolumesAsLastSeen`, which is the walk and its cache in one.** It was a
        // bare `mountedVolumes()` here, and the refresh on the very next line walked the same
        // unchanged set again — two `mountedVolumeURLs` calls plus two `resourceValues` reads per
        // volume at launch, either of which can block on a network mount. Asserted on the accessor
        // rather than on the walk so that a future edit reaching past the cache fails here.
        #expect(content.contains("Self.rememberMountedVolumes(Self.mountedVolumesAsLastSeen())"),
                "nothing records the volumes already mounted at launch")
        #expect(!content.contains("Self.rememberMountedVolumes(Self.mountedVolumes())"),
                "a recorder walks the volumes directly again, so launch and each mount pay for two walks")
    }

    /// **Every notification that changes what is mounted drops the cached walk**, and `willUnmount`
    /// deliberately does not.
    ///
    /// The walk is no longer made per refresh — it belongs to the four events that can change its
    /// answer. A handler that forgot to invalidate would leave the column drawing a volume that has
    /// gone, or missing one that arrived, until something else happened to invalidate; nothing
    /// would fail to compile and no other test would notice.
    ///
    /// `willUnmount` is the exception and it is the sharp one: the volume has NOT gone yet, and
    /// dropping the cache there sends the very next reader — this handler's own record — back to a
    /// filesystem that is being torn down. That is the walk most likely to block, which is the
    /// whole reason the cache exists.
    @Test func everyMountEventDropsTheCachedWalkExceptTheOneThatMustNot() throws {
        let content = try Self.appSource("ContentView.swift")
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        try #require(host.contains("static func forgetMountedVolumes()"),
                     "the invalidation is gone — this scan is aimed at nothing")

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
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        #expect(host.contains("MountedVolumeMemory.shared.isDetachable(volume: path)"),
                "sources are removed on an unmount without checking what the volume was")
        #expect(host.contains("settings.removeFolderSources(onVolume: path)"),
                "the unmount does not remove the sources on the volume")
        #expect(host.contains("MountedVolumeMemory.shared.forget(volume: path)"),
                "the record is never dropped — the map grows for the life of the process")
    }

    /// **The pins are deliberately NOT cleared**, and that is worth a guard: they are keyed by
    /// path, so a card plugged back in and added again finds them where they were. A later edit
    /// "tidying up after" an unmount would throw away something nothing gains from losing.
    @Test func anUnmountDoesNotClearThePinnedFolders() throws {
        let host = try Self.appSource("ContentView+FolderSidebar.swift")
        let handler = try #require(Self.body(of: "func forgetFolderSidebarSourcesOnUnmount", in: host),
                                   "the unmount handler was renamed — this scan now reads nothing")
        #expect(!handler.contains("FolderJumpStore"),
                "the unmount handler now touches the jump store; the pins were meant to survive it")
    }

    /// **The reader every scan above goes through**, so none of them is bounded by a character
    /// count guessed at the time it was written. A fixed `prefix(n)` reads less than the function
    /// the moment the function grows, and a scan that reads less is a scan that quietly stops
    /// covering the end of what it was pointed at.
    /// The text between two markers — for a scan that has to read one member of a type rather than
    /// a whole function. Nil when either marker has moved, so a rename fails the test loudly
    /// instead of quietly scanning an empty string.
    private static func between(_ start: String, _ end: String, in source: String) -> String? {
        guard let from = source.range(of: start),
              let to = source.range(of: end, range: from.upperBound..<source.endIndex)
        else { return nil }
        return String(source[from.upperBound..<to.lowerBound])
    }

    private static func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        // The next member's own declaration line, at the same indentation — every member of this
        // extension is declared at four spaces, so this is the file's real boundary.
        guard let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    func ")
                        ?? rest.range(of: "\n    nonisolated ") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    // MARK: Reading the tree

    private static let moduleDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Modules/Dashboard/Tests/Dashboard
        .deletingLastPathComponent()   // …/Modules/Dashboard/Tests
        .deletingLastPathComponent()   // …/Modules/Dashboard

    private static func source(_ relative: String) throws -> String {
        let url = moduleDir.appendingPathComponent(relative)
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(url.path) — the scan would pass vacuously")
    }

    private static func appSource(_ name: String) throws -> String {
        let url = moduleDir
            .deletingLastPathComponent()   // …/Modules
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("MacApp").appendingPathComponent(name)
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(url.path) — the scan would pass vacuously")
    }
}
