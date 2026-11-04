import AppKit
import Design
import Quartz
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The Info inspector's preview's half of a download, mounted beside the real pane that watches it.
///
/// Everything below the pane was tested and everything above it was tested; the expressions joining
/// them were not, and each survived deletion once:
///
/// - `ColumnPreviewColumn(… paneToken:)` — the argument was optional with a `nil` default, and
///   `requestDownload` downgraded nil to "requested, unwatched" behind a debug log. Deleting it
///   compiled and left the suite green while every preview-started download lost its watch. That
///   one is now a compile error (the property has no default), which is why no test here can fail
///   for it.
/// - `ColumnPreviewColumn(… isAwaitingDownload:)` — pinning it to `false` at the call site leaves
///   the column sitting on its pre-download answer for good: no "Downloading…", and no re-probe
///   when the content lands. That is what `thePaneWatchIsWhatTellsThePreviewTheFileArrived` fails
///   on.
/// - **The one watch.** The inspector is outside the pane's view tree, so it cannot be handed the
///   pane's watches the way a row is; it used to run a `PaneDownloadWatch` of its own beside the
///   pane's — two polls and two memo `forget`s per download. It follows the pane's watch now, from
///   the request to the pane's `.cloudDownloadWatchEnded`, and the test above mounts the real pair
///   to prove that hop is live: with the post in `PaneDownloadWatch.begin` deleted, the column never
///   re-probes.
///
/// **What no test here can reach, and why.** Clicking the column's own Download button. It renders
/// only for a `.cloudOnly` probe, and `requestDownload` then calls
/// `MaterializationStatus.download` — which throws for a file that is not a real cloud placeholder,
/// as every fixture here is, and falls back to `NSWorkspace.activateFileViewerSelecting`, i.e. it
/// opens Finder on the test machine. So the
/// button's `paneToken` argument is proven by the type system (no default to fall back to) and its
/// value by the derivation test, not by a click.
///
/// The probe is injected through the environment (`ColumnPreviewProbeReader`) because `.cloudOnly`
/// is otherwise unreachable: `SF_DATALESS` is an `SF_` system flag, settable only by root and in
/// practice only by a File Provider. Every caption this suite reads renders in that state alone.
///
/// **The pane this suite mounts is on a `NotificationCenter` of its own, and the one post below
/// goes through that same one.** Suites run in PARALLEL, `.default` is process-wide, and a mounted
/// `FileTreeView` is a live subscriber that accepts any post carrying its own token no matter which
/// test made it — a token names a SURFACE, not a test. A pane mounted here on `.default` therefore
/// latched posts `CloudDownloadWiringTests` issues to prove another pane ignores them, and its
/// watch's `CloudOnlyBadgeCache.forget` cleared the very ghost that suite asserts on: measured,
/// `theRightPaneIgnoresTheLeftPanesRequest` failed in 3 of 3 full runs and passed under `--filter`
/// every time. Picking a surface nobody else posts to was the old answer here and it is gone — all
/// three are already spoken for as the *ignored* token somewhere, so there was no fourth to pick,
/// and it hid the opposite failure too (a foreign pane satisfying a positive control for the pane
/// under test). A channel nobody else holds is reachable by nothing else, whatever token it
/// carries. See `docs/flaky-tests.md` mechanism 9.
///
/// Which leaves the token free to be the one this pane really is: `isSingleSource: true` mounts the
/// single-source rail, so it derives `.singleSource`, and the post below sends from `.singleSource` because
/// that is what the inspector sends for a file selected in the rail.
///
/// The `.default` the app runs on is no longer exercised end to end from here. Both halves of that
/// default are pinned directly instead — `CloudDownloadRoutingTests.theDefaultChannelIsTheAppsOwn`
/// for the poster, `FileTreeViewPaneNameTests.testAPaneMountsOnTheAppsChannelByDefault` for the
/// receiver.
///
/// `.serialized` because the badge memo is process-wide. The download notification no longer is,
/// for this suite — that is what the channel above buys — so the memo is now the whole reason.
@MainActor
@Suite(.serialized) struct ColumnPreviewDownloadWiringTests {

    private static let root = "/download-wiring"

    private struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleOpenInEditor(_ path: String) {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
    }

    private final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    /// What the injected probe answers, and every path it has answered for, in order.
    ///
    /// Mutable so the test can stage a materialization: `.cloudOnly` before the download,
    /// `.quickLook` after. Main-actor isolated (and therefore `Sendable`) so the `@Sendable` reader
    /// closure can reach it with one hop.
    ///
    /// A list rather than a set, because one of the tests below asks *how many times* a path was
    /// probed: a re-probe is the only trace the falling edge leaves when the download did not land,
    /// and a set cannot count it.
    @MainActor private final class ProbeSwitch {
        var source: ColumnPreviewSource = .cloudOnly
        var answered: [String] = []

        func probes(of path: String) -> Int { answered.filter { $0 == path }.count }
    }

    /// The whole pane, in Columns mode, as `ContentView` mounts it, with the Info inspector's preview
    /// of its selected file beside it — so the notification subscription, the pane's watch, the
    /// watch's end and the inspector's following it are all the app's own code rather than
    /// arguments this test supplied.
    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex
        let root: String
        let defaults: UserDefaults
        let probe: ProbeSwitch
        let channel: NotificationCenter

        var body: some View {
            let probe = self.probe
            return HStack(spacing: 0) {
                FileTreeView(
                    tree: tree,
                    otherTree: PaneTree(side: .right, version: 1, nodes: []),
                    isLoading: false, currentPath: root,
                    selection: $box.selection, otherSelection: [],
                    isLeft: true, delegate: StubDelegate(),
                    isSingleSource: true,
                    viewMode: .columns,
                    childrenIndex: index, browsePath: $box.browsePath,
                    downloadChannel: channel
                )
                .frame(width: 500)
                if let node = tree.nodes.first {
                    InspectorFilePreview(node: node, paneToken: .singleSource,
                                         downloadChannel: channel)
                        .frame(width: 400)
                }
            }
            .defaultAppStorage(defaults)
            // Out of reach, so the only thing that can end the inspector's "Downloading…" inside
            // this suite's waits is the pane's `.cloudDownloadWatchEnded`.
            .environment(\.inspectorDownloadDeadline, .seconds(3600))
            .environment(\.columnPreviewProbe, ColumnPreviewProbeReader { path in
                await MainActor.run {
                    probe.answered.append(path)
                    return ColumnPreviewProbe(source: probe.source)
                }
            })
        }
    }

    private static func tree(root: String = root) -> PaneTree {
        PaneTree(side: .left, version: 1, nodes: [
            FileNode(id: "\(root)/movie.mov", name: "movie.mov", isDirectory: false,
                     fileSize: 4_000_000_000, kind: UTType.quickTimeMovie.identifier),
        ])
    }

    /// The rail with the one file selected and the inspector's preview showing it, on a download
    /// channel of its own.
    ///
    /// The channel comes back with the window because it is the only way in: a post through
    /// anything else — including the `.default` the app runs on — reaches this pane not at all. See
    /// the suite comment.
    private func mount(root: String = root, probe: ProbeSwitch = ProbeSwitch())
    -> (window: NSWindow, host: NSView, channel: NotificationCenter) {
        let defaults = ScratchDefaults("ColumnPreviewDownloadWiringTests")
        defaults.set(Double(PaneViewMode.defaultColumnWidth),
                     forKey: PaneViewMode.columnWidthDefaultsKey)
        let box = Box()
        box.selection = ["\(root)/movie.mov"]
        let tree = Self.tree(root: root)
        let channel = NotificationCenter()
        let host = NSHostingView(rootView: Harness(
            box: box, tree: tree, index: PaneChildrenIndex(tree: tree, treeRoot: root),
            root: root, defaults: defaults, probe: probe, channel: channel))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return (window, host, channel)
    }

    /// Every path a live `QLPreviewView` in the tree is previewing.
    ///
    /// **The observation channel, and it is the only one available.** The captions are the obvious
    /// thing to read — "Not downloaded" against "Downloading…" — but SwiftUI builds no accessibility
    /// tree at all unless an assistive client is attached to the process, so `accessibilityChildren()`
    /// on a hosted pane comes back empty under `swift test` and every caption assertion would pass
    /// vacuously. An `NSViewRepresentable` is real AppKit and is simply there in the subtree, which
    /// makes the Quick Look mount readable.
    ///
    /// It is not a proxy for the caption either; it is the OTHER half of the same wiring, and the
    /// half with teeth. `ColumnPreviewColumn` re-probes on the FALLING edge of `isAwaitingDownload`
    /// — the pane's watch concluding is what tells a downloaded file it may be previewed — so a
    /// mount here proves the latch reached this column, went true, and went false again. Threading
    /// that is dead (the argument deleted, or a constant `nil`) never raises the edge and never
    /// re-probes: the column sits on its pre-download answer forever, which is exactly the shipped
    /// symptom.
    private func quickLookPaths(in root: NSView) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if let preview = view as? QLPreviewView,
               let url = (preview.previewItem as? NSURL) as URL? {
                found.append(url.path)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// Pumps until `condition` holds, or the deadline passes. Returns whether it held.
    ///
    /// The loop itself is `LayoutPumpWait.pump` — shared because a private copy of it per suite is
    /// how two of the three kept a defect the third had already fixed. See `pumpFloor` there for why
    /// a deadline alone is not a bound on a congested main actor.
    @discardableResult
    private func wait(_ window: NSWindow, upTo seconds: Double,
                      for condition: () -> Bool) async -> Bool {
        await LayoutPumpWait.pump(window, upTo: seconds, until: condition).held
    }

    /// A one-shot flag a queued block can set — the queue is the bound, not the clock.
    private final class Marker {
        var fired = false
    }

    /// How many main-queue turns an absence assertion in this suite is bounded by.
    ///
    /// A number rather than one queued block, because the effect being ruled out is not one turn
    /// long: a re-probe travels state write → `body` → `.onChange` → `.task(id:)` → the probe
    /// closure's own `await MainActor.run`, and each of those is at least a turn. Bounded by ONE,
    /// "nothing happened" and "it has not happened yet" are the same reading, which is mechanism 2
    /// in `docs/flaky-tests.md`.
    ///
    /// Comfortably above what a real re-probe costs here, and that margin is CHECKED rather than
    /// assumed — `aWatchThatEndsWithoutAnArrivalStillReleasesTheColumn` measures the live edge in
    /// these same units and fails naming the number if this constant ever stops clearing it.
    private static let absenceTurns = 24

    /// Runs `turns` real main-queue turns, laying the window out around each.
    ///
    /// Turns, not wall time: this is the self-hosted runner, where suites run in parallel and a
    /// fixed millisecond window is ample idle and nowhere near enough under load. `layoutIfNeeded`
    /// between them is what lets SwiftUI actually commit a render in the turn it was given, so the
    /// chain being bounded can make progress rather than merely be waited on.
    private func drain(_ window: NSWindow, turns: Int) async {
        for _ in 0..<turns {
            window.layoutIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        window.layoutIfNeeded()
    }

    // MARK: - The pane's watch reaches the inspector's preview

    /// A download started for the inspector's file is watched by the pane it was selected in, and
    /// the inspector's preview learns when that watch ends.
    ///
    /// The file answers `.cloudOnly` until the request goes out and `.quickLook` afterwards — a
    /// materialization, staged. The column may only notice it by way of the pane's watch: its probe
    /// re-runs on `probeGeneration`, and nothing else bumps that. So the Quick Look mount at the end
    /// is the whole chain reporting in — `CloudDownloadRequest.post` → the pane's scoped
    /// `.onReceive` → `PaneDownloadWatch.begin` → the watch concluding →
    /// `.cloudDownloadWatchEnded` → `InspectorFilePreview.awaiting` →
    /// `ColumnPreviewColumn(isAwaitingDownload:)` → the falling edge → the re-probe.
    ///
    /// Delete the post in `PaneDownloadWatch.begin` and the column waits out its deadline instead,
    /// which this harness puts an hour away — so this goes red, with no clock in the verdict. Posting through `.default` instead of this mount's channel fails it the same way, which
    /// is what says the pane really is listening where this test posts.
    ///
    /// **A REAL file, under a per-test directory, and that is load-bearing.** The pane's watch is
    /// the app's own `CloudDownloadPoll`, whose probe is the production
    /// `MaterializationStatus.isCloudOnlyIfKnown` — and that answers nil, not `false`, for a path
    /// with nothing behind it. Against the ghost path this used to post for, `stillCloudOnly ==
    /// false` never held, so every run spent the poll's full `attempts × interval` budget and
    /// concluded EXHAUSTED: ~10 s inside a `.serialized` suite, exercising the opposite branch to
    /// the one this name and prose describe. (It was not vacuous — the falling edge fires either
    /// way — but it silently stopped covering the arrival path when the probe went three-way.) With
    /// a file on disk the first probe lands, which is the ~1 s arrival this test is about; the
    /// exhaustion branch keeps its own test below.
    @Test func thePaneWatchIsWhatTellsThePreviewTheFileArrived() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ColumnPreviewDownloadWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("movie.mov").path
        try Data("frames".utf8).write(to: URL(fileURLWithPath: path))

        let probe = ProbeSwitch()
        let (window, host, channel) = mount(root: dir.path, probe: probe)
        // Torn down rather than merely kept alive: this pane (and the inspector) holds a live
        // `.cloudDownloadRequested` subscription, and one left listening past its test would go on
        // accepting posts through this channel. Belt and braces now that the channel is per-mount —
        // nothing later posts through this one — but `CloudDownloadWiringTests.teardown` documents
        // the failure a shared channel caused, and `close()` is still the wrong way to do it.
        defer { window.contentView = nil }

        // The resting state: a cloud-only placeholder is never handed to Quick Look.
        let settled = await wait(window, upTo: 10) { probe.answered.contains(path) }
        #expect(settled, "the column never probed its file — nothing below can be observed")
        #expect(!quickLookPaths(in: host).contains(path))

        // The content lands. On its own this changes nothing on screen: the column has no reason to
        // ask again, and a probe that re-ran for any other reason would make the mount below prove
        // nothing about the latch.
        probe.source = .quickLook
        let idle = Marker()
        DispatchQueue.main.async { MainActor.assumeIsolated { idle.fired = true } }
        var remountedUnprompted = false
        _ = await wait(window, upTo: 10) {
            if quickLookPaths(in: host).contains(path) { remountedUnprompted = true }
            return idle.fired
        }
        #expect(!remountedUnprompted, "the column re-probed without the pane's watch concluding")

        // Through this mount's own channel, which nothing else in the process holds — so the latch
        // that rises below can only be this pane's, and only this post can raise it.
        CloudDownloadRequest.post(path: path, from: .singleSource, through: channel)

        // `CloudDownloadPoll` is bounded by `attempts × interval`, so this cannot hang on a pane
        // that simply never concludes; it fails instead. The file is on disk, so the FIRST probe
        // lands and the budget is one interval rather than all ten.
        #expect(await wait(window, upTo: 30) { quickLookPaths(in: host).contains(path) },
                "the pane's watch never reached the inspector's preview of that file")
    }

    // MARK: - A watch that ends without an arrival

    /// The other end of the same latch: a download that never materializes.
    ///
    /// The falling edge is raised by the watch CONCLUDING, not by the content arriving, and both
    /// endings raise it. If only the arrival case re-probed, a stalled download would leave the
    /// column captioned "Downloading…" under a spinner for as long as the file stayed selected —
    /// the state `PreviewAccessory.decide` renders for `isAwaitingDownload`, with nothing left to
    /// take it down.
    ///
    /// Driven at the column instead of through the pane, for the reason the test above no longer
    /// has to be: reaching exhaustion through a mounted `FileTreeView` costs the poll's whole
    /// `attempts × interval` budget — ten seconds, inside a `.serialized` suite — and that budget
    /// is not injectable from here (`@StateObject private var downloads = PaneDownloadWatch()`).
    /// The pane's contribution is the edge itself, which the test above proves arrives; what is
    /// left is what the column does with an edge whose file did not change, and that needs no poll
    /// at all.
    ///
    /// The re-probe IS the observation. Nothing else changes: the file is still a placeholder, so
    /// no Quick Look mounts either way, and the caption is unreadable from a hosted view (see
    /// `quickLookPaths`). A probe that ran is the trace the column leaves.
    @Test func aWatchThatEndsWithoutAnArrivalStillReleasesTheColumn() async throws {
        let path = "\(Self.root)/stalled.mov"
        let probe = ProbeSwitch()
        let watching = WatchBox()
        let item = ColumnPreviewItem(node: FileNode(id: path, name: "stalled.mov",
                                                    isDirectory: false, fileSize: 4_000_000_000,
                                                    kind: UTType.quickTimeMovie.identifier))
        let host = NSHostingView(rootView: ColumnHarness(watching: watching, item: item,
                                                         probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        defer { window.contentView = nil }

        #expect(await wait(window, upTo: 10) { probe.probes(of: path) == 1 },
                "the column never probed its file — nothing below can be observed")

        // Arming the watch changes nothing on disk, so it must not cost a probe. Without this the
        // assertion below would pass on the RISING edge and prove the opposite of its name.
        watching.isAwaiting = true
        await drain(window, turns: Self.absenceTurns)
        #expect(probe.probes(of: path) == 1, "arming the watch re-probed a file nothing had touched")

        // The watch ends having found nothing — the file is still a placeholder.
        watching.isAwaiting = false

        // Counted in the same units the absence above was bounded in, so the two are comparable and
        // the margin between them can be asserted rather than hoped for. Deadlined as well, because
        // a starved main actor must report as a failed wait rather than spin.
        var turnsToReprobe = 0
        let deadline = Date().addingTimeInterval(10)
        while probe.probes(of: path) < 2, Date() < deadline {
            await drain(window, turns: 1)
            turnsToReprobe += 1
        }
        #expect(probe.probes(of: path) >= 2,
                "an exhausted watch left the column on its pre-download answer")

        // AT the edge, not past it — and this is the half that has teeth against an inverted edge.
        // `>=` above is satisfied the instant the count reaches 2, so a source that re-probed on
        // BOTH edges would sail through it on its way to 3; the exact count, read after the queue
        // has been given as long again as the absence was, is what refuses that.
        await drain(window, turns: Self.absenceTurns)
        #expect(probe.probes(of: path) == 2,
                "the falling edge cost more than one re-probe")

        // The absence above was bounded by more turns than a real re-probe actually needs, so
        // "nothing happened" there was a verdict and not a head start. This is the assertion that
        // keeps `absenceTurns` honest on a machine slower than the one it was measured on: if it
        // ever fails, raise the constant — do not delete the check.
        #expect(turnsToReprobe < Self.absenceTurns,
                "a real re-probe cost \(turnsToReprobe) turns; the absence above allowed only \(Self.absenceTurns)")

        #expect(!quickLookPaths(in: host).contains(path),
                "a placeholder was handed to Quick Look")
    }

    /// Whether the column's pane is watching a download of its file, drivable from a test.
    private final class WatchBox: ObservableObject {
        @Published var isAwaiting = false
    }

    /// The preview column alone, with the pane's latch replaced by a binding this test drives.
    private struct ColumnHarness: View {
        @ObservedObject var watching: WatchBox
        let item: ColumnPreviewItem
        let probe: ProbeSwitch

        var body: some View {
            let probe = self.probe
            return ColumnPreviewColumn(item: item, paneToken: .singleSource,
                                       isAwaitingDownload: watching.isAwaiting)
                .environment(\.columnPreviewProbe, ColumnPreviewProbeReader { path in
                    await MainActor.run {
                        probe.answered.append(path)
                        return ColumnPreviewProbe(source: probe.source)
                    }
                })
        }
    }

    // MARK: - One watch

    /// What the inspector shows as downloading, after each notice. Its own request starts it; the
    /// end of exactly that request's watch clears it; another pane's request, another file's, and
    /// the end of a SUPERSEDED request — a repeat Download of the same file — leave it alone.
    @Test func theInspectorFollowsThePanesWatchByRequest() {
        let path = "\(Self.root)/movie.mov"
        func note(_ name: Notification.Name, _ request: CloudDownloadRequest) -> Notification {
            Notification(name: name, object: request)
        }
        func after(_ n: Notification, _ current: CloudDownloadRequest?) -> CloudDownloadRequest? {
            InspectorFilePreview.awaiting(after: n, current: current, path: path, paneToken: .left)
        }
        let first = CloudDownloadRequest(path: path, paneToken: .left)
        let again = CloudDownloadRequest(path: path, paneToken: .left)

        #expect(after(note(.cloudDownloadRequested, first), nil) == first)
        #expect(after(note(.cloudDownloadRequested, CloudDownloadRequest(path: path, paneToken: .right)), nil) == nil,
                "the other pane's request for the same path was followed")
        #expect(after(note(.cloudDownloadRequested, CloudDownloadRequest(path: "\(Self.root)/other.mov",
                                                                         paneToken: .left)), nil) == nil,
                "a request for another file was followed")
        // A repeat supersedes; the old watch's end must not clear the new one.
        #expect(after(note(.cloudDownloadRequested, again), first) == again)
        #expect(after(note(.cloudDownloadWatchEnded, first), again) == again,
                "a superseded watch's end cleared the newer request")
        #expect(after(note(.cloudDownloadWatchEnded, again), again) == nil)
    }

    /// The pane says when its watch ends, on the channel it heard the request on — and only for
    /// the watch that concluded.
    @Test func thePanesWatchAnnouncesItsEndOnItsChannel() async {
        final class Heard: @unchecked Sendable { var ended: [CloudDownloadRequest] = [] }
        let channel = NotificationCenter()
        let heard = Heard()
        let token = channel.addObserver(forName: .cloudDownloadWatchEnded, object: nil, queue: nil) {
            if let request = $0.object as? CloudDownloadRequest { heard.ended.append(request) }
        }
        defer { channel.removeObserver(token) }
        let watch = PaneDownloadWatch(watch: { request, latch in request.concludes(latch: latch()) })
        let request = CloudDownloadRequest(path: "\(Self.root)/movie.mov", paneToken: .left)
        watch.begin(request, announcingOn: channel)
        for _ in 0..<50 where heard.ended.isEmpty { await Task.yield() }
        #expect(heard.ended == [request])
        #expect(watch.requests.isEmpty)
    }

    /// The inspector runs no watch of its own. A second `PaneDownloadWatch` here is the doubled
    /// poll and `forget` this view exists without.
    @Test func theInspectorOwnsNoWatch() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/InspectorFilePreview.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("PaneDownloadWatch("))
        #expect(!source.contains("CloudDownloadPoll.watch"))
    }

    /// **The column's Download is the row menu's verb, sent from its pane on its pane's channel.**
    /// It was a copy of that verb's try, post and reveal — the drift `requestDownload` was written
    /// to end. Its click is out of reach (see the suite's note), so the call is pinned by source.
    @Test func thePreviewsDownloadIsTheRowMenusVerb() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/ColumnPreviewColumn.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let flat = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("CloudDownloadRequest.requestDownload(path: item.path, name: item.name, "
                              + "from: paneToken, through: downloadChannel)"),
                "the preview's Download no longer goes through the shared verb, from its pane, on its channel")
        #expect(!source.contains("MaterializationStatus.download("),
                "the preview asks for the download itself again, beside the shared verb")
    }
}
