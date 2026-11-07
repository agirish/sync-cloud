import AppKit
import Quartz
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The preview column must never render one file's probe against another file's path. A
/// `.task(id:)` runs after the body that changed its id is committed, so state reset there leaves
/// one frame showing the old file's probe for the new item. With a stale `.quickLook` that mounts
/// `QLPreviewView` on a cloud-only placeholder, and Quick Look reads it: the provider download
/// `.cloudOnly` exists to prevent. The probe is injected (`ColumnPreviewProbeReader`) because
/// `.cloudOnly` needs `SF_DATALESS`, which only a File Provider sets.
///
/// The assignment is watched, not the view tree: the bad `previewItem` can be assigned and torn
/// down inside one `layoutIfNeeded()`, so sampling the tree passes over the bug. KVO on the live
/// view's `previewItem` sees a value that existed for no frames, and is proven live first.
@MainActor
@Suite struct ColumnPreviewProbeLifecycleTests {

    /// Neither path exists on disk, on purpose: if the seam were bypassed and the real
    /// `ColumnPreviewProbe.read` used, `previewable` would be `.missing`, nothing would mount, and
    /// the test fails instead of passing for the wrong reason.
    private static let previewable = "/probe-lifecycle/settled.txt"
    private static let cloudOnly = "/probe-lifecycle/placeholder.mov"

    /// How long the second file's probe is held out, so the render under test happens while the
    /// state is unambiguously the old file's.
    private static let heldProbe = Duration.milliseconds(1200)

    /// A path nothing renders, used once to prove the KVO channel is live.
    private static let kvoControl = "/probe-lifecycle/kvo-control"

    /// Which paths the injected probe has answered. The observation window closes on this, not a
    /// timeout, so a run whose second probe never completed says so instead of passing.
    @MainActor private final class ProbeLog {
        var completed: Set<String> = []
    }

    private final class Box: ObservableObject {
        @Published var item: ColumnPreviewItem
        init(_ item: ColumnPreviewItem) { self.item = item }
    }

    private struct Harness: View {
        @ObservedObject var box: Box
        let log: ProbeLog
        /// Captured as plain values: the reader closure is `@Sendable` and runs off the main actor,
        /// so it cannot reach this suite's main-actor statics.
        let cloudOnlyPath: String
        let heldFor: Duration

        var body: some View {
            let cloudOnlyPath = self.cloudOnlyPath
            let heldFor = self.heldFor
            let log = self.log
            return ColumnPreviewColumn(item: box.item, paneToken: .left, isAwaitingDownload: false)
                .frame(width: 420, height: 520)
                .environment(\.columnPreviewProbe, ColumnPreviewProbeReader { path in
                    let isCloudOnly = path == cloudOnlyPath
                    if isCloudOnly { try? await Task.sleep(for: heldFor) }
                    await MainActor.run { _ = log.completed.insert(path) }
                    return ColumnPreviewProbe(source: isCloudOnly ? .cloudOnly : .quickLook)
                })
        }
    }

    private static func item(path: String) -> ColumnPreviewItem {
        ColumnPreviewItem(node: FileNode(id: path, name: (path as NSString).lastPathComponent,
                                         isDirectory: false, fileSize: 5,
                                         kind: UTType.plainText.identifier))
    }

    /// Every path ever assigned to one `QLPreviewView`'s `previewItem`, including values overwritten
    /// within a layout pass. Keeps the view alive: SwiftUI dismantles it when the column stops
    /// previewing, and an observed object deallocating with an observer attached crashes.
    private final class PreviewItemSpy: NSObject {
        private let view: QLPreviewView
        private(set) var assigned: [String] = []

        init(watching view: QLPreviewView) {
            self.view = view
            super.init()
            view.addObserver(self, forKeyPath: "previewItem", options: [.new], context: nil)
        }

        func stop() { view.removeObserver(self, forKeyPath: "previewItem") }

        func reset() { assigned.removeAll() }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            if let url = (view.previewItem as? NSURL) as URL? { assigned.append(url.path) }
        }
    }

    /// The first `QLPreviewView` in a hosted tree, or nil if the column is not previewing anything.
    private func quickLookView(in root: NSView) -> QLPreviewView? {
        if let preview = root as? QLPreviewView { return preview }
        for subview in root.subviews {
            if let found = quickLookView(in: subview) { return found }
        }
        return nil
    }

    /// Pumps layout until `condition` holds, or until both the deadline has passed and
    /// `LayoutPumpWait.pumpFloor` passes have been made. Returns whether it held, and how many
    /// passes that took. Not `@discardableResult`: a bounded wait whose expiry nobody reads lets the
    /// test carry on against state it never reached.
    private func wait(_ window: NSWindow, upTo seconds: Double,
                      for condition: () -> Bool) async -> (held: Bool, pumps: Int) {
        await LayoutPumpWait.pump(window, upTo: seconds, until: condition)
    }

    @Test func walkingOntoACloudOnlyFileNeverHandsItToQuickLook() async throws {
        let log = ProbeLog()
        let box = Box(Self.item(path: Self.previewable))
        let host = NSHostingView(rootView: Harness(box: box, log: log,
                                                   cloudOnlyPath: Self.cloudOnly,
                                                   heldFor: Self.heldProbe))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }

        // Settle on a previewable file: the state the defect needs, and a live `QLPreviewView` to
        // watch.
        let settled = await wait(window, upTo: 10) { quickLookView(in: host) != nil }
        try #require(settled.held,
                     "no Quick Look mounted for the first file after \(settled.pumps) layout passes — the column never settled")
        let preview = try #require(quickLookView(in: host))

        let spy = PreviewItemSpy(watching: preview)
        defer { spy.stop() }

        // Positive control: if `previewItem` weren't observable, every assertion below would pass
        // for a column handing out cloud-only paths.
        preview.previewItem = URL(fileURLWithPath: Self.kvoControl) as NSURL
        try #require(spy.assigned.contains(Self.kvoControl),
                     "QLPreviewView.previewItem is not observable here — this test cannot see the assignment it forbids")
        // Put it back, so `updateNSView`'s own "same item?" guard sees what the app would see.
        preview.previewItem = URL(fileURLWithPath: Self.previewable) as NSURL
        spy.reset()

        box.item = Self.item(path: Self.cloudOnly)

        // Sampled until the second probe answers, bounded by the work, not the clock. The forbidden
        // assignment would happen in the first body committed after the change, in the first pass.
        let probed = await wait(window, upTo: 20) { log.completed.contains(Self.cloudOnly) }
        #expect(probed.held,
                "the second probe never completed after \(probed.pumps) layout passes — the interval sampled was not the stale one")
        #expect(!spy.assigned.contains(Self.cloudOnly),
                "\(Self.cloudOnly) was handed to Quick Look before its probe answered — mounting a preview on a cloud-only placeholder is the provider download this column exists to avoid")
    }
}
