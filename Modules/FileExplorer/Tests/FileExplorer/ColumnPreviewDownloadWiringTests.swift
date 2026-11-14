import AppKit
import Design
import Quartz
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The Info inspector's preview's half of a download, mounted beside the real pane that watches
/// it, so the joins between them are the app's own code; the inspector follows the pane's watch
/// rather than running its own. The column's Download click would open Finder for a fixture, so
/// that call is pinned by source. The probe is injected (`ColumnPreviewProbeReader`) because
/// `.cloudOnly` needs `SF_DATALESS`, which only a File Provider sets.
///
/// The pane gets a `NotificationCenter` of its own (`docs/flaky-tests.md`, "A mounted view is a
/// live subscriber, in every suite at once"), so its token can be the real `.singleSource`;
/// `CloudDownloadRoutingTests.theDefaultChannelIsTheAppsOwn` pins `.default`. `.serialized`
/// because the badge memo is process-wide.
@MainActor
@Suite(.serialized) struct ColumnPreviewDownloadWiringTests {

    private static let root = "/download-wiring"

    private final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    /// What the injected probe answers, and every path it has answered for, in order. Main-actor
    /// isolated, so the `@Sendable` reader reaches it in one hop. A list, not a set, because a test
    /// counts re-probes: the only trace the falling edge leaves when the download didn't land.
    @MainActor private final class ProbeSwitch {
        var source: ColumnPreviewSource = .cloudOnly
        var answered: [String] = []

        func probes(of path: String) -> Int { answered.filter { $0 == path }.count }
    }

    /// The whole pane in Columns mode, as `ContentView` mounts it, with the Info inspector's preview
    /// of its selected file beside it, so the subscription, the watch, its end and the inspector's
    /// following it are all the app's own code.
    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex
        let root: String
        let defaults: UserDefaults
        let probe: ProbeSwitch
        let channel: NotificationCenter
        /// The inspector's downloads, made once per mount, not per render. Their deadline is out of
        /// reach, so only the pane's `.cloudDownloadWatchEnded` ends "Downloading…" in these waits.
        let downloads: InspectorDownloads

        var body: some View {
            let probe = self.probe
            return HStack(spacing: 0) {
                FileTreeView(
                    tree: tree,
                    otherTree: PaneTree(side: .right, version: 1, nodes: []),
                    isLoading: false, currentPath: root,
                    selection: $box.selection, otherSelection: [],
                    isLeft: true, delegate: NoOpFileActionDelegate(),
                    isSingleSource: true,
                    viewMode: .columns,
                    childrenIndex: index, browsePath: $box.browsePath,
                    downloadChannel: channel
                )
                .frame(width: 500)
                if let node = tree.nodes.first {
                    InspectorFilePreview(node: node, paneToken: .singleSource, paneWatches: true,
                                         downloads: downloads, downloadChannel: channel)
                        .frame(width: 400)
                }
            }
            .defaultAppStorage(defaults)
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
    /// channel of its own. The channel is returned because it is the only way in: a post through
    /// anything else, `.default` included, doesn't reach this pane.
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
            root: root, defaults: defaults, probe: probe, channel: channel,
            downloads: InspectorDownloads(channel: channel, deadline: .seconds(3600))))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        return (window, host, channel)
    }

    /// Every path a live `QLPreviewView` in the tree is previewing: the only observation channel.
    /// SwiftUI builds no accessibility tree unless an assistive client is attached, so captions read
    /// through `accessibilityChildren()` would come back empty under `swift test` and pass vacuously.
    /// The column re-probes on the falling edge of `isAwaitingDownload`, so a mount here proves the
    /// latch reached this column, went true and went false again.
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

    /// Pumps until `condition` holds or the deadline passes, through `LayoutPumpWait.pump`; see
    /// `pumpFloor` there for why a deadline alone doesn't bound a congested main actor.
    @discardableResult
    private func wait(_ window: NSWindow, upTo seconds: Double,
                      for condition: () -> Bool) async -> Bool {
        await LayoutPumpWait.pump(window, upTo: seconds, until: condition).held
    }

    /// A one-shot flag a queued block can set, so the queue is the bound, not the clock.
    private final class Marker {
        var fired = false
    }

    /// How many main-queue turns bound an absence assertion in this suite. Several, because a
    /// re-probe travels state write → `body` → `.onChange` → `.task(id:)` → the probe's
    /// `await MainActor.run`, each at least a turn; bounded by one, "nothing happened" and "not yet"
    /// read the same (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps"). The margin is checked:
    /// `aWatchThatEndsWithoutAnArrivalStillReleasesTheColumn` measures a real re-probe in turns.
    private static let absenceTurns = 24

    /// Runs `turns` real main-queue turns, laying the window out around each. Turns, not wall time,
    /// since a fixed window that is ample idle is too short under load. `layoutIfNeeded` lets
    /// SwiftUI commit a render each turn, so the chain can make progress.
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
    /// the inspector's preview learns when that watch ends. The probe answers `.cloudOnly` until the
    /// request and `.quickLook` after, and the column re-probes only on `probeGeneration`, so the
    /// final Quick Look mount proves the whole chain, `CloudDownloadRequest.post` through
    /// `PaneDownloadWatch.begin`, `.cloudDownloadWatchEnded` and `InspectorDownloads` to the
    /// re-probe. Fails, with no clock in the verdict (the inspector's deadline is an hour away), if
    /// the post in `PaneDownloadWatch.begin` is deleted or the request goes through `.default`.
    ///
    /// A real file in a per-test directory: the pane's poll uses the production
    /// `MaterializationStatus.isCloudOnlyIfKnown`, which answers nil for a missing path, so a ghost
    /// would exhaust the poll's budget instead of covering the arrival.
    @Test func thePaneWatchIsWhatTellsThePreviewTheFileArrived() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ColumnPreviewDownloadWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("movie.mov").path
        try Data("frames".utf8).write(to: URL(fileURLWithPath: path))

        let probe = ProbeSwitch()
        let (window, host, channel) = mount(root: dir.path, probe: probe)
        // Torn down, not just released: the pane and inspector hold live `.cloudDownloadRequested`
        // subscriptions. Belt and braces with a per-mount channel; not `close()`, which
        // over-releases (see `CloudDownloadWiringTests.teardown`).
        defer { window.contentView = nil }

        // The resting state: a cloud-only placeholder is never handed to Quick Look.
        let settled = await wait(window, upTo: 10) { probe.answered.contains(path) }
        #expect(settled, "the column never probed its file — nothing below can be observed")
        #expect(!quickLookPaths(in: host).contains(path))

        // The content lands. On its own this changes nothing on screen; a probe that re-ran for any
        // other reason would make the mount below prove nothing about the latch.
        probe.source = .quickLook
        let idle = Marker()
        DispatchQueue.main.async { MainActor.assumeIsolated { idle.fired = true } }
        var remountedUnprompted = false
        _ = await wait(window, upTo: 10) {
            if quickLookPaths(in: host).contains(path) { remountedUnprompted = true }
            return idle.fired
        }
        #expect(!remountedUnprompted, "the column re-probed without the pane's watch concluding")

        // Through this mount's own channel, so only this post can raise this pane's latch.
        CloudDownloadRequest.post(path: path, from: .singleSource, through: channel)

        // `CloudDownloadPoll` is bounded by `attempts × interval`, so a pane that never concludes
        // fails rather than hangs. The file is on disk, so the first probe lands.
        #expect(await wait(window, upTo: 30) { quickLookPaths(in: host).contains(path) },
                "the pane's watch never reached the inspector's preview of that file")
    }

    // MARK: - A watch that ends without an arrival

    /// A download that never materializes still releases the column. The falling edge comes from
    /// the watch concluding, either way; were it only on arrival, a stalled download would leave
    /// "Downloading…" up for as long as the file stayed selected.
    ///
    /// Driven at the column, not through the pane: exhaustion through a mounted `FileTreeView` costs
    /// the poll's whole budget, which isn't injectable from here. The re-probe is the observation,
    /// since no Quick Look mounts on a placeholder and the caption can't be read (`quickLookPaths`).
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

        // Arming the watch changes nothing on disk, so it must not cost a probe; otherwise the
        // assertion below could pass on the rising edge.
        watching.isAwaiting = true
        await drain(window, turns: Self.absenceTurns)
        #expect(probe.probes(of: path) == 1, "arming the watch re-probed a file nothing had touched")

        // The watch ends having found nothing: the file is still a placeholder.
        watching.isAwaiting = false

        // Counted in the units the absence above was bounded in, so the margin can be asserted.
        // Deadlined too, so a starved main actor fails the wait rather than spinning.
        var turnsToReprobe = 0
        let deadline = Date().addingTimeInterval(10)
        while probe.probes(of: path) < 2, Date() < deadline {
            await drain(window, turns: 1)
            turnsToReprobe += 1
        }
        #expect(probe.probes(of: path) >= 2,
                "an exhausted watch left the column on its pre-download answer")

        // Exactly one re-probe: `>=` above would also pass a source that re-probed on both edges, on
        // its way to 3. The exact count, after as long again as the absence, refuses that.
        await drain(window, turns: Self.absenceTurns)
        #expect(probe.probes(of: path) == 2,
                "the falling edge cost more than one re-probe")

        // Keeps `absenceTurns` honest: the absence above must allow more turns than a real re-probe
        // needs. If this fails on a slower machine, raise the constant; don't delete the check.
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

    /// What the inspector shows as downloading, kept by `InspectorDownloads`, which outlives the
    /// preview. A request starts it and the end of exactly that request's watch clears it; another
    /// file's request and a superseded request's end leave it alone. Every end counts against its
    /// file, which makes the preview look again.
    ///
    /// The state lives in the host because a click on a folder and back rebuilds the preview, which
    /// would otherwise offer Download again for a watched file; so no preview is mounted here.
    @Test func theInspectorFollowsEachWatchByRequest() {
        let channel = NotificationCenter()
        let downloads = InspectorDownloads(channel: channel, deadline: .seconds(3600))
        let path = "\(Self.root)/movie.mov"
        let first = CloudDownloadRequest(path: path, paneToken: .left)
        let again = CloudDownloadRequest(path: path, paneToken: .left)

        channel.post(name: .cloudDownloadRequested, object: first)
        #expect(downloads.isAwaiting(path))
        channel.post(name: .cloudDownloadRequested,
                     object: CloudDownloadRequest(path: "\(Self.root)/other.mov", paneToken: .left))
        #expect(downloads.isAwaiting(path), "another file's request cleared this one")
        #expect(downloads.isAwaiting("\(Self.root)/other.mov"))
        channel.post(name: .cloudDownloadRequested, object: again)
        channel.post(name: .cloudDownloadWatchEnded, object: first)
        #expect(downloads.isAwaiting(path), "a superseded watch's end cleared the newer request")
        channel.post(name: .cloudDownloadWatchEnded, object: again)
        #expect(!downloads.isAwaiting(path))
        #expect(downloads.watchesEnded(path) == 2)
    }

    /// A watch that ends after the inspector's deadline still makes the preview look again;
    /// otherwise a late end would match nothing and the preview would offer Download for a file on
    /// disk until reselected.
    @Test func aWatchEndingAfterTheDeadlineStillCounts() async {
        let channel = NotificationCenter()
        let downloads = InspectorDownloads(channel: channel, deadline: .milliseconds(1))
        let path = "\(Self.root)/movie.mov"
        let request = CloudDownloadRequest(path: path, paneToken: .left)
        channel.post(name: .cloudDownloadRequested, object: request)
        for _ in 0..<500 where downloads.isAwaiting(path) {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(!downloads.isAwaiting(path), "the deadline never gave up on an unanswered request")
        #expect(downloads.watchesEnded(path) == 1, "giving up did not count as an ending")
        channel.post(name: .cloudDownloadWatchEnded, object: request)
        #expect(downloads.watchesEnded(path) == 2, "a late end was dropped")
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

    /// One watch per download. A request a pane will watch is only followed here, since a second
    /// `PaneDownloadWatch` would double the poll and the memo `forget`. Only a request no pane hears
    /// (Edit with its file pane folded, say) is watched here, once however often it is asked.
    @Test func theInspectorWatchesOnlyWhatNoPaneWill() async {
        final class Began: @unchecked Sendable { var paths: [String] = [] }
        let began = Began()
        let channel = NotificationCenter()
        let watch = PaneDownloadWatch(watch: { request, _ in
            began.paths.append(request.path)
            return false
        })
        let downloads = InspectorDownloads(channel: channel, deadline: .seconds(3600), watch: watch)
        let watched = CloudDownloadRequest(path: "\(Self.root)/a.mov", paneToken: .left)
        channel.post(name: .cloudDownloadRequested, object: watched)
        for _ in 0..<20 { await Task.yield() }
        #expect(began.paths.isEmpty, "the inspector watched a download a pane is watching")

        let unheard = CloudDownloadRequest(path: "\(Self.root)/b.mov", paneToken: .left)
        channel.post(name: .cloudDownloadRequested, object: unheard)
        downloads.watchUnheard(unheard)
        downloads.watchUnheard(unheard)
        for _ in 0..<50 where began.paths.isEmpty { await Task.yield() }
        #expect(began.paths == [unheard.path], "the unheard download was watched \(began.paths.count) times")
        #expect(downloads.isAwaiting(unheard.path))
    }

    /// The column's Download is the row menu's verb, `requestDownload`, sent from its pane on its
    /// pane's channel, so the two can't drift. Its click is out of reach (see the suite comment), so
    /// the call is pinned by source.
    @Test func thePreviewsDownloadIsTheRowMenusVerb() throws {
        let source = try SourceText.fileExplorer("ColumnPreviewColumn.swift")
        let flat = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("CloudDownloadRequest.requestDownload(path: item.path, name: item.name, "
                              + "from: paneToken, through: downloadChannel)"),
                "the preview's Download no longer goes through the shared verb, from its pane, on its channel")
        #expect(!source.contains("MaterializationStatus.download("),
                "the preview asks for the download itself again, beside the shared verb")
    }
}
