import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The reveal landing, driven through the real path: Organize mounted on its Duplicates rail item
/// (`lens: .filing` with the selection in defaults, as the app builds it), handed a reveal request
/// that resolves through its own `.task`.
///
/// Mounted, not called: `applyRevealRequest()` on an uninstalled `LensWorkspaceView` writes
/// `@State` SwiftUI never reads back, so every check would pass with the feature disconnected.
/// Pixels, not geometry or captions: the lens fills a fixed frame, so `fittingSize` can't see a
/// card open, and with no assistive client attached accessibility checks pass vacuously.
@MainActor
@Suite struct DuplicateRevealLandingTests {

    private static let canvas = CGSize(width: 520, height: 620)

    private static func copy(_ path: String, keeper: Bool) -> DuplicateCopy {
        DuplicateCopy(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                      size: 4_096, itemCount: 1, modificationDate: Date(timeIntervalSince1970: 0),
                      uniqueItemCount: 0, depth: 1, isRecommendedKeeper: keeper)
    }

    private static func group(_ paths: [String], name: String) -> DuplicateGroup {
        DuplicateGroup(matchType: .identical, name: name, isDirectory: false,
                       copies: paths.enumerated().map { copy($1, keeper: $0 == 0) },
                       reclaimableBytes: 4_096)
    }

    /// A manager holding a COMPLETED scan of `/root` with the given groups.
    private static func manager(groups: [DuplicateGroup]) -> FileSyncManager {
        let m = FileSyncManager()
        m.duplicateGroups = groups
        m.hasFoundDuplicates = true
        m.duplicateScanRoot = "/root"
        return m
    }

    /// One mounted lens, kept alive with the window it paints into and the defaults suite holding
    /// its rail selection, which wipes itself when the last reference goes.
    private final class Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let defaults: ScratchDefaults
        init(host: NSHostingView<AnyView>, window: NSWindow, defaults: ScratchDefaults) {
            self.host = host
            self.window = window
            self.defaults = defaults
        }
    }

    /// Mounts Organize on Duplicates, as the app does: `lens: .filing`, with Duplicates found
    /// through `@AppStorage(OrganizeLens.defaultsKey)`, so `lens` and `effectiveLens` differ as in
    /// the app; a mount where they were equal would hide code that reads the wrong one.
    ///
    /// The window background matters: without one the content composites against the borderless
    /// window's buffer and every comparison reads as no difference.
    ///
    /// The selection goes through a fresh `ScratchDefaults` suite: `@AppStorage` binds one
    /// process-wide location per (store, key), other suites write this key
    /// (`FilingRefineControlTests`), and suites run in parallel. With `selectsDuplicates` false
    /// nothing is stored, so no rail item is selected.
    private func mount(_ manager: FileSyncManager, request: DuplicateRevealRequest?,
                       selectsDuplicates: Bool = true,
                       onRevealHandled: ((UUID) -> Void)? = nil) -> Mounted {
        let defaults = ScratchDefaults(selectsDuplicates ? "DuplicateRevealLandingTests"
                                                         : "DuplicateRevealLandingTests-overview")
        if selectsDuplicates {
            defaults.set(OrganizeLens.duplicates.rawValue, forKey: OrganizeLens.defaultsKey)
        }
        let subject = LensWorkspaceView(syncManager: manager, lens: .filing,
                               providerName: "Projects", scanTargetFolder: "/root",
                               onFindDuplicates: {}, revealRequest: request,
                               onRevealHandled: onRevealHandled)
            .defaultAppStorage(defaults)
        let (host, window) = ReviewLensHost.mount(subject, size: Self.canvas)
        return Mounted(host: host, window: window, defaults: defaults)
    }

    /// The mount really stands on Duplicates, which every case assumes but none can see. Checked by
    /// paint: with no rail selection the same manager draws the overview, and the two must differ,
    /// as they wouldn't if `.defaultAppStorage` failed to reach `railLens`.
    @Test(.machinePinned(.pixelSampling)) func theMountLandsOnDuplicatesAndNotOnTheOverview() async throws {
        let groups = [Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")]
        let selected = try #require(await settled(mount(Self.manager(groups: groups), request: nil),
                                                  "duplicates selected"))

        let overview = try #require(await settled(
            mount(Self.manager(groups: groups), request: nil, selectsDuplicates: false), "no selection"))
        #expect(pixelsDiffering(selected, overview) > 0,
                "the stored rail selection changed nothing — this suite is mounting the overview")
    }

    private func snapshot(_ mounted: Mounted) -> NSBitmapImageRep? {
        mounted.host.layoutSubtreeIfNeeded()
        guard let rep = mounted.host.bitmapImageRepForCachingDisplay(in: mounted.host.bounds)
        else { return nil }
        mounted.host.cacheDisplay(in: mounted.host.bounds, to: rep)
        return rep
    }

    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        var differing = 0
        for y in stride(from: 0, to: min(lhs.pixelsHigh, rhs.pixelsHigh), by: 2) {
            for x in stride(from: 0, to: min(lhs.pixelsWide, rhs.pixelsWide), by: 2) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        return differing
    }

    /// This mount's painted screen once it has stopped changing.
    ///
    /// Settle each mount on its own, then compare; never poll one host until it differs from
    /// another. Two hosts mounted from identical state differ by thousands of pixels until a fresh
    /// `NSHostingView` finishes drawing, so such a poll passes on drawing noise.
    ///
    /// Bounded by `LayoutPumpWait`, which floors on layout passes, not seconds (`docs/flaky-tests.md`,
    /// "Fixed pumps and fixed sleeps"). Quiet means `stableFrames` identical frames in a row, so a
    /// gap between two render stages isn't mistaken for the end.
    private func settled(_ mounted: Mounted, stableFrames: Int = 4,
                         within timeout: TimeInterval = 10,
                         _ what: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> NSBitmapImageRep? {
        var previous: NSBitmapImageRep?
        var latest: NSBitmapImageRep?
        var quiet = 0
        let (held, pumps) = await LayoutPumpWait.pump(mounted.host, upTo: timeout) {
            guard let current = snapshot(mounted) else { return false }
            if let previous, pixelsDiffering(previous, current) == 0 { quiet += 1 } else { quiet = 0 }
            previous = current
            latest = current
            return quiet >= stableFrames
        }
        #expect(held, "\(what) — still moving after \(pumps) layout passes",
                sourceLocation: sourceLocation)
        return latest ?? snapshot(mounted)
    }

    /// Polls until the mounted lens paints the same screen as `reference`: a landing is the screen
    /// it should be, not just a repaint.
    private func settled(_ mounted: Mounted,
                         matching reference: NSBitmapImageRep,
                         within timeout: TimeInterval = 10,
                         _ what: String,
                         sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        var differing = Int.max
        let (held, pumps) = await LayoutPumpWait.pump(mounted.host, upTo: timeout) {
            guard let current = snapshot(mounted) else { return false }
            differing = pixelsDiffering(reference, current)
            return differing == 0
        }
        #expect(held, "\(what) — \(differing) pixels still differ after \(pumps) layout passes",
                sourceLocation: sourceLocation)
        return held
    }

    // MARK: The premise

    /// A reveal changes what is on screen at all. Every case below reads a landing as a change in
    /// paint, so without this they could all pass against a feature that does nothing.
    @Test(.machinePinned(.pixelSampling)) func aRevealChangesWhatIsPainted() async throws {
        let target = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")
        let quiet = try #require(await settled(mount(Self.manager(groups: [target]), request: nil),
                                              "no request"))
        let landed = try #require(await settled(
            mount(Self.manager(groups: [target]),
                  request: DuplicateRevealRequest(path: "/root/b/x.txt")), "the reveal"))
        #expect(pixelsDiffering(quiet, landed) > 0,
                "the reveal painted nothing new — the card never opened")
    }

    /// An answered request is reported back once, with its id; a waiting one is not.
    /// `appliedRevealID` is `@State` and dies with the lens, so without the host retiring the
    /// request every return to the workspace would replay the plan over the user's filter and query.
    @Test func anAnsweredRequestIsHandedBackAndAWaitingOneIsNot() async throws {
        let target = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")
        final class Handled: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [UUID] = []
            func record(_ id: UUID) { lock.lock(); ids.append(id); lock.unlock() }
            var value: [UUID] { lock.lock(); defer { lock.unlock() }; return ids }
        }

        // Waiting: a scan is running, so nothing is handed back; retiring the request would drop
        // the answer its scan is about to give.
        let waitingLog = Handled()
        let scanning = FileSyncManager()
        scanning.isFindingDuplicates = true
        let waitingMount = mount(scanning,
                                 request: DuplicateRevealRequest(path: "/root/b/x.txt"),
                                 onRevealHandled: { waitingLog.record($0) })

        // Answered: the file is in a group, the reveal applies, the id comes back. Waited for by
        // the id itself, not by paint, so this runs unpinned.
        let answered = Handled()
        let request = DuplicateRevealRequest(path: "/root/b/x.txt")
        let mounted = mount(Self.manager(groups: [target]), request: request,
                            onRevealHandled: { answered.record($0) })
        let (handed, pumps) = await LayoutPumpWait.pump(mounted.host, upTo: 10) { !answered.value.isEmpty }
        try #require(handed, "the applied plan never handed its request back (\(pumps) passes)")
        // More turns, in which a second hand-back, or one from the waiting lens, would land.
        _ = await LayoutPumpWait.pump(waitingMount.host, upTo: 1) { false }
        #expect(answered.value == [request.id],
                "an applied plan must hand its request back for retirement — once, with the right id")
        #expect(waitingLog.value.isEmpty,
                "a request the scan has not answered yet must stay standing")
    }

    // MARK: Landing on the right group

    /// The group holding the file is the one opened, not simply the first. Two groups, two requests
    /// naming a file in each: a resolver that opened the first, all, or none paints the same both
    /// times; only one following the requested path paints differently.
    @Test(.machinePinned(.pixelSampling)) func theGroupHoldingTheFileIsTheOneOpened() async throws {
        let first = Self.group(["/root/a/aaa.txt", "/root/b/aaa.txt"], name: "aaa.txt")
        let second = Self.group(["/root/a/zzz.txt", "/root/b/zzz.txt"], name: "zzz.txt")

        let openFirst = try #require(await settled(
            mount(Self.manager(groups: [first, second]),
                  request: DuplicateRevealRequest(path: "/root/b/aaa.txt")), "first"))
        let openSecond = try #require(await settled(
            mount(Self.manager(groups: [first, second]),
                  request: DuplicateRevealRequest(path: "/root/b/zzz.txt")), "second"))
        #expect(pixelsDiffering(openFirst, openSecond) > 0,
                "revealing two different files opened the same group — the requested path is not what decides")
    }

    /// A request made mid-scan resolves when the results land, not before: the common first-use
    /// shape, where the handoff starts a scan. The scan ends as `findDuplicates` ends one (publish
    /// the results, then clear the running flag), and nothing re-triggers the request.
    @Test(.machinePinned(.pixelSampling)) func aRequestMadeDuringAScanLandsWhenTheResultsArrive() async throws {
        let target = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")
        let manager = FileSyncManager()
        manager.isFindingDuplicates = true

        let mounted = mount(manager, request: DuplicateRevealRequest(path: "/root/b/x.txt"))
        let scanning = try #require(await settled(mounted, "scanning"))

        manager.duplicateGroups = [target]
        manager.hasFoundDuplicates = true
        manager.duplicateScanRoot = "/root"
        manager.isFindingDuplicates = false

        let landed = try #require(await settled(mounted, "after the results landed"))
        #expect(pixelsDiffering(scanning, landed) > 0,
                "the pending request never resolved once the scan published its results")

        // A repaint alone isn't the claim: the results repaint the lens anyway, even for a request
        // that already answered `notFound` from the empty pre-scan groups. So the late landing
        // must match the eager one, the same request mounted against the completed results.
        let eager = mount(Self.manager(groups: [target]),
                          request: DuplicateRevealRequest(path: "/root/b/x.txt"))
        let reference = try #require(await settled(eager, "eager reference"))
        let arrived = await settled(mounted, matching: reference,
                                    "resolving after the scan landed somewhere other than where resolving immediately lands")
        #expect(arrived)
    }

    /// A file in no group lands on a named answer, not a list quietly filtered to nothing. Compared
    /// against a grouped file in the same results, so the difference is the outcome.
    @Test(.machinePinned(.pixelSampling)) func aFileInNoGroupLandsSomewhereElseThanAGroupedOne() async throws {
        let groups = [Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")]
        let grouped = try #require(await settled(
            mount(Self.manager(groups: groups),
                  request: DuplicateRevealRequest(path: "/root/b/x.txt")), "grouped"))
        let lonely = try #require(await settled(
            mount(Self.manager(groups: groups),
                  request: DuplicateRevealRequest(path: "/root/c/lonely.txt")), "ungrouped"))
        #expect(pixelsDiffering(grouped, lonely) > 0,
                "a file in no group landed on the same screen as one that has a group")
    }

    /// A file the scan never looked at gets a different screen from one it cleared: both show an
    /// empty list, with opposite claims, so the rule in `DuplicateReveal.outcome` must reach the
    /// screen. The two files share a name and differ only in folder, or the pixels would differ
    /// even with the rule removed.
    @Test(.machinePinned(.pixelSampling)) func aFileTheScanNeverLookedAtLandsSomewhereElseThanOneItCleared() async throws {
        // The manager records a completed scan of /root, so /elsewhere was never examined.
        let cleared = try #require(await settled(
            mount(Self.manager(groups: []),
                  request: DuplicateRevealRequest(path: "/root/x.txt")), "cleared"))
        let unscanned = try #require(await settled(
            mount(Self.manager(groups: []),
                  request: DuplicateRevealRequest(path: "/elsewhere/x.txt")), "unscanned"))
        #expect(pixelsDiffering(cleared, unscanned) > 0,
                "a file the scan never covered was given the same answer as one it cleared")
    }

    /// A `notScanned` landing applied over a populated list must not surface later. Ask about a file
    /// the last scan never covered while its groups are on screen, then resolve every group: the
    /// list must show the all-clear, not "wasn't in the last scan" about a file asked about long
    /// before. Pins `applyRevealPlan`'s call of `landingToStore`, which its pure tests can't see.
    @Test(.machinePinned(.pixelSampling)) func aLatentNotScannedLandingDoesNotSurfaceOverALaterAllClear() async throws {
        let group = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")

        // The reference: the same end state with no request ever made.
        let refManager = Self.manager(groups: [group])
        let reference = mount(refManager, request: nil)
        _ = try #require(await settled(reference, "reference with groups"))
        refManager.duplicateGroups = []
        let allClear = try #require(await settled(reference, "reference all-clear"))

        // The subject: an outsideScan request answered while the list had rows, then the same resolve.
        let manager = Self.manager(groups: [group])
        let mounted = mount(manager, request: DuplicateRevealRequest(path: "/elsewhere/x.txt"))
        _ = try #require(await settled(mounted, "landing applied over a populated list"))
        manager.duplicateGroups = []
        let after = try #require(await settled(mounted, "subject after resolving everything"))

        #expect(pixelsDiffering(allClear, after) == 0,
                "resolving the last group surfaced a latent 'wasn't in the last scan' claim instead of the all-clear")
    }

    /// A scan that found no groups still answers about the file, not with the folder's generic
    /// all-clear, which would leave the user to infer it covered what they clicked.
    @Test(.machinePinned(.pixelSampling)) func aScanWithNoGroupsAtAllStillAnswersAboutTheFile() async throws {
        func emptyManager() -> FileSyncManager {
            let m = FileSyncManager()
            m.hasFoundDuplicates = true
            m.duplicateScanRoot = "/root"
            return m
        }
        let clean = try #require(await settled(mount(emptyManager(), request: nil), "clean state"))
        let named = try #require(await settled(
            mount(emptyManager(), request: DuplicateRevealRequest(path: "/root/c/lonely.txt")),
            "named answer"))
        #expect(pixelsDiffering(clean, named) > 0,
                "the folder's all-clear was shown for a question about one file")
    }
}
