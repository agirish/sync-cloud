import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// The landing itself, driven through the real path: a mounted Duplicates lens handed a reveal
/// request, resolving through its own `.task` exactly as it does when the workspace switch mounts
/// it.
///
/// **Mounted, not called.** The tempting shape is to build a `TidyView` value and invoke
/// `applyRevealRequest()` on it — which writes `@State` on a view SwiftUI never installed, so
/// every assertion afterwards reads back the initial values and passes with the whole feature
/// disconnected. These mount the view and read back what it PAINTS, so the task, the state writes
/// and the re-render all have to actually happen.
///
/// **Pixels, not geometry and not captions.** The lens fills a fixed frame, so `fittingSize` is
/// the frame whatever the content does — it cannot see a card open. And nothing here can read a
/// caption: with no assistive client attached to this process, accessibility assertions pass
/// vacuously. What is left, and what is actually being claimed, is what ends up on screen.
///
/// The sharp assertion is `theGroupHoldingTheFileIsTheOneOpened`: revealing one file must paint
/// something DIFFERENT from revealing another. A resolver that always opened the first group would
/// satisfy every "something changed" case in here and fail only that one.
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

    /// One mounted lens, kept alive together with the window it needs to paint into.
    private final class Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(host: NSHostingView<AnyView>, window: NSWindow) {
            self.host = host
            self.window = window
        }
    }

    /// Mounts the Duplicates lens.
    ///
    /// The window background is not decoration: without one the content composites against the
    /// borderless window's own buffer and every comparison below reads as zero difference —
    /// "nothing painted", whatever the code did.
    private func mount(_ manager: FileSyncManager, request: DuplicateRevealRequest?,
                       onRevealHandled: ((UUID) -> Void)? = nil) -> Mounted {
        let subject = TidyView(syncManager: manager, lens: .duplicates,
                               providerName: "Projects", scanTargetFolder: "/root",
                               onFindDuplicates: {}, revealRequest: request,
                               onRevealHandled: onRevealHandled)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window)
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

    /// This mount's painted screen once IT has stopped changing.
    ///
    /// **Every comparison in this suite settles each mount on its own and then compares — never
    /// "poll one host until it differs from another host's screen".** That second form is
    /// unsound, and measurably so: two hosts mounted from identical state and snapshotted
    /// immediately differ by ~27,000 pixels, because a fresh `NSHostingView` has not finished
    /// drawing. A poll whose first check runs at that moment returns `true` on the drawing noise,
    /// and the test then passes however the feature behaves. It cost a real regression here — the
    /// not-scanned case passed with its rule mutated away.
    ///
    /// Bounded by `LayoutPumpWait`, which floors on layout PASSES rather than seconds and returns
    /// the count: what these waits wait for arrives on main-actor turns, and under full-suite
    /// congestion a wall-clock deadline buys fewer of those exactly when more are needed (see
    /// `docs/flaky-tests.md`, mechanism 2). Quiet means `stableFrames` consecutive identical
    /// frames, not one matching pair, so a gap between two render stages cannot be mistaken for
    /// the end.
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

    /// Polls until the mounted lens paints the same screen as `reference`. The arrival check: a
    /// landing is not "a repaint happened", it is "the screen is now the one it should be".
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

    /// **A reveal changes what is on screen at all.** Every case below reads a landing as a change
    /// in paint, so if the mount painted identically with and without a request they would all
    /// pass against a feature that does nothing.
    @Test func aRevealChangesWhatIsPainted() async throws {
        let target = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")
        let quiet = try #require(await settled(mount(Self.manager(groups: [target]), request: nil),
                                              "no request"))
        let landed = try #require(await settled(
            mount(Self.manager(groups: [target]),
                  request: DuplicateRevealRequest(path: "/root/b/x.txt")), "the reveal"))
        #expect(pixelsDiffering(quiet, landed) > 0,
                "the reveal painted nothing new — the card never opened")
    }

    /// **An answered request is reported back, exactly once, with its id — and a waiting one is
    /// not.** The callback is the cross-mount half of the applied-id guard: `appliedRevealID` is
    /// `@State` and dies with the lens, so without the host retiring the request, every return to
    /// a lens workspace after a trip through Compare replayed the whole plan over the user's
    /// filter and query. Driven through the real mount so the `.task` and the state writes have
    /// to actually happen.
    @Test func anAnsweredRequestIsHandedBackAndAWaitingOneIsNot() async throws {
        let target = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")
        final class Handled: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [UUID] = []
            func record(_ id: UUID) { lock.lock(); ids.append(id); lock.unlock() }
            var value: [UUID] { lock.lock(); defer { lock.unlock() }; return ids }
        }

        // Answered: the file is in a group, the reveal applies, the id comes back.
        let answered = Handled()
        let request = DuplicateRevealRequest(path: "/root/b/x.txt")
        let mounted = mount(Self.manager(groups: [target]), request: request,
                            onRevealHandled: { answered.record($0) })
        _ = try #require(await settled(mounted, "the reveal"))
        #expect(answered.value == [request.id],
                "an applied plan must hand its request back for retirement — once, with the right id")

        // Waiting: a scan is running, nothing is answered, nothing is handed back — retiring a
        // waiting request would drop the answer its scan is about to earn.
        let waitingLog = Handled()
        let scanning = FileSyncManager()
        scanning.isFindingDuplicates = true
        let waitingMount = mount(scanning,
                                 request: DuplicateRevealRequest(path: "/root/b/x.txt"),
                                 onRevealHandled: { waitingLog.record($0) })
        _ = try #require(await settled(waitingMount, "the waiting lens"))
        #expect(waitingLog.value.isEmpty,
                "a request the scan has not answered yet must stay standing")
    }

    // MARK: Landing on the right group

    /// **The group holding the FILE is the one opened — not simply the first one.**
    ///
    /// Two groups, and two requests naming a file in each. A resolver that always opened the first
    /// group (or that opened all of them, or none) paints the same thing both times; only one that
    /// follows the requested path paints differently. This is the assertion the "something
    /// changed" cases cannot make.
    @Test func theGroupHoldingTheFileIsTheOneOpened() async throws {
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

    /// **A request made mid-scan resolves when the results land, not before.** The common
    /// first-use shape — no scan yet, so the handoff starts one — and the case a fixture that only
    /// ever tests completed scans would miss entirely.
    ///
    /// The scan is ended here the way `findDuplicates` ends one: publish the results, then clear
    /// the running flag. Nothing else is touched, and nothing re-triggers the request.
    @Test func aRequestMadeDuringAScanLandsWhenTheResultsArrive() async throws {
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

        // **"Something repainted" is not the claim.** The results arriving repaints the lens on
        // its own — a request that had already given up and answered `notFound` from the empty
        // pre-scan groups would repaint too, and would satisfy the assertion above while never
        // opening anything. So the late landing is held to the EAGER one: mounting the same
        // request against the same completed results is known (from the cases above) to open the
        // group, and resolving late must arrive at exactly that screen.
        let eager = mount(Self.manager(groups: [target]),
                          request: DuplicateRevealRequest(path: "/root/b/x.txt"))
        let reference = try #require(await settled(eager, "eager reference"))
        let arrived = await settled(mounted, matching: reference,
                                    "resolving after the scan landed somewhere other than where resolving immediately lands")
        #expect(arrived)
    }

    /// The named empty state: a file in no group must land on an answer, not on a list that has
    /// quietly filtered itself to nothing.
    ///
    /// Compared against revealing a file that IS grouped, in the same results — so the difference
    /// is the outcome and not merely "a request happened".
    @Test func aFileInNoGroupLandsSomewhereElseThanAGroupedOne() async throws {
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

    /// **A file the scan never looked at gets a DIFFERENT screen from one it cleared.**
    ///
    /// Both land with an empty list; the claims are opposite. Driven through the mount so the
    /// pure rule in `DuplicateReveal.outcome` is shown to actually reach the user — the shipped
    /// version answered "no duplicates of x" for both, which is the false confidence this whole
    /// feature is built to avoid.
    ///
    /// **The two files share a NAME and differ only in folder**, which is what makes this bite.
    /// An earlier form used `lonely.txt` against `x.txt` and passed with the rule mutated away:
    /// both screens then read *No duplicates of “<name>”*, and the pixels differed because the
    /// NAMES did. Holding the name fixed leaves the state as the only thing that can move.
    @Test func aFileTheScanNeverLookedAtLandsSomewhereElseThanOneItCleared() async throws {
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

    /// **A `notScanned` landing applied over a POPULATED list must not sit latent and surface
    /// later.** The sequence is real: ask about a file the last scan never covered while that
    /// scan's groups are on screen (the landing is invisible — the list has rows), then resolve
    /// every group. The list empties with an empty query, and the stored landing used to surface
    /// "wasn't in the last scan" over the all-clear the user had just earned — a claim about a
    /// file they asked about an hour before. This pins `applyRevealPlan`'s CALL of
    /// `landingToStore`, which the pure tests beside that function cannot: they pass however the
    /// view wires it.
    @Test func aLatentNotScannedLandingDoesNotSurfaceOverALaterAllClear() async throws {
        let group = Self.group(["/root/a/x.txt", "/root/b/x.txt"], name: "x.txt")

        // The reference: the same end state with no request ever made — everything resolved.
        let refManager = Self.manager(groups: [group])
        let reference = mount(refManager, request: nil)
        _ = try #require(await settled(reference, "reference with groups"))
        refManager.duplicateGroups = []
        let allClear = try #require(await settled(reference, "reference all-clear"))

        // The subject: an outsideScan request answered while the list had rows, then the same
        // resolve-everything.
        let manager = Self.manager(groups: [group])
        let mounted = mount(manager, request: DuplicateRevealRequest(path: "/elsewhere/x.txt"))
        _ = try #require(await settled(mounted, "landing applied over a populated list"))
        manager.duplicateGroups = []
        let after = try #require(await settled(mounted, "subject after resolving everything"))

        #expect(pixelsDiffering(allClear, after) == 0,
                "resolving the last group surfaced a latent 'wasn't in the last scan' claim instead of the all-clear")
    }

    /// A scan that found NO groups at all still answers about the file rather than showing the
    /// folder's generic all-clear. The user asked about a file; an answer about the folder leaves
    /// them to infer it covered the thing they clicked.
    @Test func aScanWithNoGroupsAtAllStillAnswersAboutTheFile() async throws {
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
