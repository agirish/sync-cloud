import Testing
import Foundation
import Events
@testable import Sync

/// `resolveDuplicateCopy(_:keeper:)` — the single-copy trash the Compare Copies surface reaches.
///
/// **Failure paths first, and most of this file is them.** The verb destroys one of a user's files
/// on the strength of a scan that may be minutes old, and the two things that make it safe are the
/// pair verdict and the removal gate — neither of which shows up in a success. A resolve that
/// merely *works* would pass with every refusal deleted.
///
/// The one behaviour a group resolve could not stand in for is pinned here too: on a three-copy
/// group this trashes the compared copy and leaves the third alone, where
/// `resolveDuplicateGroup` would take both.
@Suite struct DuplicatePairResolveTests {

    private static let scanned = Date(timeIntervalSince1970: 1_000)

    @MainActor
    private func makeManager(_ fm: MockFileManager) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        return manager
    }

    private func stub(size: Int = 1000, modified: Date? = scanned) -> MockFileManager.FileStub {
        var attrs: [FileAttributeKey: Any] = [.size: size]
        if let modified { attrs[.modificationDate] = modified }
        return MockFileManager.FileStub(isDirectory: false, attributes: attrs, contents: nil)
    }

    private func copy(_ path: String, keeper: Bool, size: Int = 1000,
                      modified: Date? = scanned, isDirectory: Bool = false,
                      snapshot: FolderContentSnapshot? = nil) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory,
                      size: size, itemCount: 1, modificationDate: modified,
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper,
                      contentSnapshot: snapshot)
    }

    private func group(_ copies: [DuplicateCopy],
                       matchType: DuplicateMatchType = .identical,
                       name: String = "x") -> DuplicateGroup {
        DuplicateGroup(matchType: matchType, name: name, isDirectory: false, copies: copies,
                       reclaimableBytes: copies.filter { !$0.isRecommendedKeeper }
                           .reduce(0) { $0 + $1.size })
    }

    /// Reads the DISK log rather than `Logger.shared.entries` — the in-memory array is capped and
    /// a parallel run can evict this suite's line before the assertion reads it.
    @MainActor
    private func loggedLine(containing fragment: String) async -> String? {
        await loggedLineOnDisk(containing: fragment)
    }

    // MARK: Refusals

    /// **The stale-scan case, and the reason the payload never carries a group UUID.** A rescan
    /// replaces `duplicateGroups` wholesale, so a surface left open across one is describing
    /// copies no current group holds. Nothing here has been re-verified against a live grouping,
    /// and "unverified" must not resolve to "removed".
    @MainActor
    @Test func noLiveGroupRefusesAndTrashesNothing() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = []   // the rescan landed while the surface was open

        let ok = await manager.resolveDuplicateCopy(other, keeper: keeper)

        #expect(ok == false)
        #expect(fm.virtualDisk["/b/x"] != nil, "a copy no live group holds was trashed anyway")
        #expect(fm.trashedPaths.isEmpty)
        #expect(manager.banner?.message.contains("rescan") == true
                    || manager.banner?.message.contains("Rescan") == true)
    }

    /// A group holding only ONE of the two paths is not the pair's group. Reachable: the other
    /// copy was resolved from the card while the surface was open, which leaves the group listed
    /// with the remaining copies.
    @MainActor
    @Test func aGroupHoldingOnlyOneOfThePairIsNotALiveGroupForIt() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub()
        fm.virtualDisk["/c/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [group([keeper, copy("/c/x", keeper: false)])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false)
        #expect(fm.virtualDisk["/b/x"] != nil)
    }

    /// **The lookup is by PATH, so a fresh scan's brand-new UUID changes nothing.** This is the
    /// positive control for the refusal above: without it, "refused" and "the id moved" would be
    /// indistinguishable, and a lookup keyed on `DuplicateGroup.id` would pass the refusal test
    /// while breaking every ordinary rescan.
    @MainActor
    @Test func aRescanThatMintsANewGroupIdStillResolves() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]
        let idBefore = manager.duplicateGroups[0].id
        // What a rescan does: same copies, a new group value with a new UUID.
        manager.duplicateGroups = [group([keeper, other])]
        try #require(manager.duplicateGroups[0].id != idBefore)

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == true)
        #expect(fm.virtualDisk["/b/x"] == nil)
    }

    /// The keeper is the copy being *kept*: if it is gone, trashing the other one takes the last
    /// instance of its content.
    @MainActor
    @Test func aMissingKeeperRefuses() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/b/x"] = stub()   // and not "/a/x"
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false)
        #expect(fm.virtualDisk["/b/x"] != nil)
        #expect(manager.banner?.message.contains("no longer what the scan saw") == true)
        #expect(await loggedLine(containing: "refused to trash /b/x") != nil,
                "a refusal he can see on screen must also be in the log he audits")
    }

    /// A same-LENGTH rewrite of the keeper — the case size alone waves through, which is why the
    /// drift check compares mtime as well.
    @MainActor
    @Test func aKeeperRewrittenInPlaceAtTheSameLengthRefuses() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub(modified: Date(timeIntervalSince1970: 9_999))
        fm.virtualDisk["/b/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false)
        #expect(fm.virtualDisk["/b/x"] != nil)
    }

    /// The dangerous half: the copy being DESTROYED changed after the scan, so it is no longer
    /// provably a duplicate of anything — it may now be the only instance of its new content.
    @MainActor
    @Test func aDriftedCopyRefusesAndNamesIt() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub(size: 2000)
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false)
        #expect(fm.virtualDisk["/b/x"] != nil)
        #expect(manager.banner?.message.contains("changed since it was scanned") == true)
        #expect(manager.banner?.message.contains("x") == true)
    }

    /// A folder copy with NO scan baseline was never fully read, so "changed since it was scanned"
    /// would assert a change nobody measured — and send the user to a rescan that records nil
    /// again. The refusal stands either way; only the claim changes.
    @MainActor
    @Test func aFolderCopyWithNoBaselineRefusesWithoutClaimingItChanged() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/d"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: [])
        fm.virtualDisk["/b/d"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: [])
        let keeper = copy("/a/d", keeper: true, isDirectory: true,
                          snapshot: FolderContentSnapshot(entries: [:], ignoredNames: []))
        let other = copy("/b/d", keeper: false, isDirectory: true, snapshot: nil)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false)
        let message = try #require(manager.banner?.message)
        #expect(message.contains("couldn't be fully checked"))
        #expect(!message.contains("changed since it was scanned"))
    }

    /// The keeper and the copy are the same file — a caller bug that would trash the very copy it
    /// promised to keep. Refused before anything is measured.
    @MainActor
    @Test func trashingTheKeeperItselfIsRefused() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        manager.duplicateGroups = [group([keeper, copy("/b/x", keeper: false)])]

        #expect(await manager.resolveDuplicateCopy(keeper, keeper: keeper) == false)
        #expect(fm.virtualDisk["/a/x"] != nil)
    }

    // MARK: The gate's window

    /// **The pre-check is the first verdict, not the last.** `deleteItems` holds the
    /// permanent-delete confirmation open for as long as the user leaves it, and what follows it
    /// is unrecoverable. The gate re-runs the same assessment after the confirmation — here the
    /// copy is rewritten *inside* the dialog, and the removal must not proceed.
    @MainActor
    @Test func driftInsideThePermanentDeleteDialogIsRefusedByTheGate() async throws {
        let fm = MockFileManager()
        fm.shouldFailTrash = true            // no Trash on this volume: the dialog is reached
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]
        manager.permanentDeleteConfirmer = { _ in
            // The user thinks about it, and something rewrites the copy meanwhile.
            fm.virtualDisk["/b/x"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [.size: 4242, .modificationDate: Date(timeIntervalSince1970: 5_000)],
                contents: nil)
            return true
        }

        let ok = await manager.resolveDuplicateCopy(other, keeper: keeper)

        #expect(ok == false)
        #expect(fm.virtualDisk["/b/x"] != nil,
                "the gate's post-confirmation pass let a drifted copy be destroyed permanently")
    }

    /// The nil-`self` branch of the gate, reached directly: a manager torn down mid-delete cannot
    /// verify anything, so it must refuse everything rather than wave paths through. Unreachable
    /// through the call site, which holds `self` on the awaiting frame — which is exactly why it
    /// is exercised here instead.
    @MainActor
    @Test func theGateRefusesEverythingWhenItsManagerIsGone() async throws {
        var gate: (@Sendable ([String]) async -> Set<String>)?
        weak var weakManager: FileSyncManager?
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        do {
            let manager = FileSyncManager(fileManager: MockFileManager())
            weakManager = manager
            gate = manager.duplicatePairRemovalGate(copy: other, keeper: keeper)
        }
        try #require(weakManager == nil,
                     "the manager outlived its scope — the nil-self branch was never reached, so this pins nothing")
        let closure = try #require(gate)
        #expect(await closure(["/b/x"]) == ["/b/x"])
    }

    // MARK: Success

    /// **The whole reason this verb exists.** On a three-copy group the pair verdict is about one
    /// copy; `resolveDuplicateGroup` would trash both redundant copies, destroying a file the user
    /// decided nothing about.
    @MainActor
    @Test func onlyTheComparedCopyIsTrashedNotEveryRedundantOne() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub()
        fm.virtualDisk["/c/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        let third = copy("/c/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other, third])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == true)
        #expect(fm.virtualDisk["/b/x"] == nil)
        #expect(fm.virtualDisk["/c/x"] != nil, "the third copy was trashed by a pair verdict")
        // The group survives with two copies; its reclaim figure follows.
        let remaining = try #require(manager.duplicateGroups.first)
        #expect(remaining.copies.map(\.path).sorted() == ["/a/x", "/c/x"])
    }

    /// A two-copy group has nothing left to be a duplicate of, so it leaves the list — the same
    /// in-memory update the Compare review's trash performs.
    @MainActor
    @Test func aResolvedTwoCopyGroupLeavesTheList() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == true)
        #expect(manager.duplicateGroups.isEmpty)
        #expect(manager.banner?.message.contains("Reclaimed") == true)
        #expect(manager.banner?.isUndoable == true)
    }

    /// One file can legitimately sit in two groups — the same-text pass lets an identical group's
    /// keeper anchor a same-text group as well. Both must be updated, or the second goes on
    /// listing a file that is now in the Trash.
    @MainActor
    @Test func everyGroupHoldingTheTrashedPathIsUpdated() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/b/x"] = stub()
        fm.virtualDisk["/c/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [
            group([keeper, other, copy("/c/x", keeper: false)]),
            group([copy("/b/x", keeper: true), copy("/c/x", keeper: false)], matchType: .sameText),
        ]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == true)
        #expect(manager.duplicateGroups.allSatisfy { !$0.copies.contains { $0.path == "/b/x" } },
                "a group left listing a file that is now in the Trash")
    }

    /// On a Trash-less volume the copy was destroyed, not trashed. The banner must not offer a ⌘Z
    /// that would fire at whatever was previously on the undo stack, and the log must say which
    /// way it went — he reads that log to find things in the Trash.
    @MainActor
    @Test func aPermanentRemovalDoesNotPromiseUndoAndSaysSoInTheLog() async throws {
        let fm = MockFileManager()
        fm.shouldFailTrash = true
        let manager = makeManager(fm)
        manager.permanentDeleteConfirmer = { _ in true }
        fm.virtualDisk["/a/perm-x"] = stub()
        fm.virtualDisk["/b/perm-x"] = stub()
        let keeper = copy("/a/perm-x", keeper: true)
        let other = copy("/b/perm-x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == true)
        #expect(fm.virtualDisk["/b/perm-x"] == nil)
        #expect(manager.banner?.message.contains("⌘Z") != true)
        #expect(manager.banner?.isUndoable != true)
        #expect(await loggedLine(containing: "permanently deleted the compared copy /b/perm-x") != nil)
    }

    /// **A vanished copy is not drift.** There is nothing to trash and nothing was lost, so the
    /// verb says so and drops the copy rather than warning about a change the user probably made
    /// themselves in Finder a moment ago.
    @MainActor
    @Test func aVanishedCopyIsDroppedRatherThanRefusedAsDrift() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()   // and "/b/x" is already gone
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/b/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false,
                "nothing left the disk, so the verb reports no removal")
        #expect(manager.duplicateGroups.isEmpty, "the group went on listing a file that is gone")
        #expect(manager.banner?.message.contains("already gone") == true)
    }

    // MARK: Protected copies

    /// A copy that may never be offered for removal, refused by the ENGINE rather than by the
    /// surface that happens to be driving it.
    ///
    /// **The surface disabling its button was the whole protection, and the verb is `public`.**
    /// `recommendedRemovalPaths` filters these copies out of every batch, and the Compare surface
    /// greys its trash button for one — but neither is a rule the engine kept, so any other caller,
    /// or the same one a release later, could trash a file out of a folder another group is
    /// keeping. The bytes survive in the pair's keeper; the kept folder's snapshot does not, and
    /// every later resolve of THAT group then refuses as drifted.
    @MainActor
    @Test func aProtectedCopyIsRefusedByTheEngineNotJustTheButton() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/kept/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = DuplicateCopy(id: "/kept/x", name: "x", isDirectory: false, size: 1000,
                                  itemCount: 1, modificationDate: Self.scanned, uniqueItemCount: 0,
                                  depth: 1, isRecommendedKeeper: false,
                                  isProtectedFromRemoval: true)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false)
        #expect(fm.virtualDisk["/kept/x"] != nil, "a protected copy was trashed")
        #expect(manager.banner?.message.contains("another duplicate group is keeping") == true,
                "the refusal did not say why: \(manager.banner?.message ?? "no banner")")
    }

    /// The positive control the case above needs. The same shape with the flag cleared really does
    /// remove the copy — so the refusal is the protection, not the fixture failing to line up.
    @MainActor
    @Test func theSamePairWithoutTheFlagIsRemoved() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/kept/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/kept/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == true)
        #expect(fm.virtualDisk["/kept/x"] == nil)
    }

    /// **Protection read from the LIVE group, not from the caller's value.** This is the window the
    /// gate exists for: the surface opened on a copy that was removable, a rescan then kept the
    /// folder it sits in, and the caller is still holding the value from before that scan. Asking
    /// the passed-in copy would answer about results that have moved on — and would trash it.
    @MainActor
    @Test func protectionAcquiredInARescanStillRefuses() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/kept/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let unprotected = copy("/kept/x", keeper: false)          // what the surface holds
        let protectedNow = DuplicateCopy(id: "/kept/x", name: "x", isDirectory: false, size: 1000,
                                         itemCount: 1, modificationDate: Self.scanned,
                                         uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false,
                                         isProtectedFromRemoval: true)
        manager.duplicateGroups = [group([keeper, protectedNow])] // what the rescan produced

        #expect(await manager.resolveDuplicateCopy(unprotected, keeper: keeper) == false,
                "the caller's stale value decided it, not the current results")
        #expect(fm.virtualDisk["/kept/x"] != nil)
    }

    /// And the same, arriving inside the permanent-delete dialog — the gate re-runs the assessment
    /// at the moment of removal, so protection acquired while the user was reading the alert is
    /// caught by the same check.
    @MainActor
    @Test func protectionAcquiredInsideTheDialogIsRefusedByTheGate() async throws {
        let fm = MockFileManager()
        fm.shouldFailTrash = true            // no Trash on this volume: the dialog is reached
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()
        fm.virtualDisk["/kept/x"] = stub()
        let keeper = copy("/a/x", keeper: true)
        let other = copy("/kept/x", keeper: false)
        manager.duplicateGroups = [group([keeper, other])]
        manager.permanentDeleteConfirmer = { [weak manager] _ in
            // While the alert is up, a rescan lands and keeps the folder this copy sits in.
            let protectedNow = DuplicateCopy(id: "/kept/x", name: "x", isDirectory: false,
                                             size: 1000, itemCount: 1, modificationDate: Self.scanned,
                                             uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false,
                                             isProtectedFromRemoval: true)
            manager?.duplicateGroups = [DuplicateGroup(matchType: .identical, name: "x",
                                                       isDirectory: false,
                                                       copies: [keeper, protectedNow],
                                                       reclaimableBytes: 1000)]
            return true
        }

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false)
        #expect(fm.virtualDisk["/kept/x"] != nil,
                "the gate destroyed a copy that became protected while the alert was open")
    }

    /// A protected copy that is also already GONE is reported as gone, not as protected: there is
    /// nothing left to protect, and the vanished path is what takes it out of the list. Pins the
    /// order of the two checks, which is otherwise invisible.
    @MainActor
    @Test func aVanishedProtectedCopyIsStillReportedAsVanished() async throws {
        let fm = MockFileManager()
        let manager = makeManager(fm)
        fm.virtualDisk["/a/x"] = stub()      // "/kept/x" is already gone
        let keeper = copy("/a/x", keeper: true)
        let other = DuplicateCopy(id: "/kept/x", name: "x", isDirectory: false, size: 1000,
                                  itemCount: 1, modificationDate: Self.scanned, uniqueItemCount: 0,
                                  depth: 1, isRecommendedKeeper: false,
                                  isProtectedFromRemoval: true)
        manager.duplicateGroups = [group([keeper, other])]

        #expect(await manager.resolveDuplicateCopy(other, keeper: keeper) == false)
        #expect(manager.banner?.message.contains("already gone") == true,
                "reported \(manager.banner?.message ?? "no banner") for a file that does not exist")
    }
}
