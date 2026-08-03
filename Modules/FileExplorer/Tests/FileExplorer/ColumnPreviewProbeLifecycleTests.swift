import AppKit
import Quartz
import SwiftUI
import Sync
import Testing
import UniformTypeIdentifiers
@testable import FileExplorer

/// The preview column must never render one file's probe against another file's path.
///
/// `probe` and `hasSettled` were independent `@State`, reset at the top of `.task(id:)` — and a task
/// runs *after* the body that changed its id has already been committed. So the frame in which
/// `item` became the new file still carried the old file's `.quickLook` and its `hasSettled`, and
/// `case .quickLook where hasSettled` mounts `QLPreviewView` on `item.path`. On a cloud-only
/// placeholder that hands the new path to the Quick Look extension, which READS it — the provider
/// download `ColumnPreviewSource.cloudOnly` exists to prevent ("selecting a 4 GB video must not
/// start a 4 GB transfer"). The other two stale states are the same defect wearing different
/// clothes: an old `.cloudOnly` offers a Download button captioned for the new file, an old
/// `.missing` says "no longer here" about a file that is present.
///
/// The probe is injected (`ColumnPreviewProbeReader`) because `.cloudOnly` is unreachable
/// otherwise: `SF_DATALESS` is an `SF_` system flag, settable only by root and in practice only by
/// a File Provider.
///
/// **The assignment is what is watched, not the view tree.** Sampling for a `QLPreviewView` carrying
/// the new path cannot see this defect — measured: with it fully present, `previewItem` is assigned
/// the cloud-only path and the view is torn down again inside the SAME `layoutIfNeeded()`, so every
/// sample either side reads clean and the test passes green over the bug. What matters is the
/// assignment itself — that is the call that hands the path to the Quick Look extension and makes it
/// read — so this observes the live view's `previewItem` through KVO, which catches a value that
/// existed for no frames at all. The observer is proven live before it is trusted (see the control
/// below), because an unobservable property would make the whole test vacuous.
@MainActor
@Suite struct ColumnPreviewProbeLifecycleTests {

    /// Neither path exists on disk, deliberately: if the environment seam were ever bypassed and the
    /// real `ColumnPreviewProbe.read` used instead, `previewable` would classify `.missing`, no
    /// Quick Look would mount for it, and the positive control below fails rather than the whole
    /// test passing for the wrong reason.
    private static let previewable = "/probe-lifecycle/settled.txt"
    private static let cloudOnly = "/probe-lifecycle/placeholder.mov"

    /// How long the second file's probe is held out, so that the stale state is unambiguously the
    /// old one when the new item is committed — the render under test happens while this is
    /// outstanding.
    private static let heldProbe = Duration.milliseconds(1200)

    /// A path nothing renders, used once to prove the KVO channel is live.
    private static let kvoControl = "/probe-lifecycle/kvo-control"

    /// Which paths the injected probe has actually answered. The observation window closes on THIS,
    /// not on a timeout: a run where the second probe never completed sampled the wrong interval and
    /// must say so instead of passing.
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
                    return ColumnPreviewProbe(source: isCloudOnly ? .cloudOnly : .quickLook,
                                              created: nil)
                })
        }
    }

    private static func item(path: String) -> ColumnPreviewItem {
        ColumnPreviewItem(
            row: PaneRow(side: .left, version: 1,
                         node: FileNode(id: path, name: (path as NSString).lastPathComponent,
                                        isDirectory: false, fileSize: 5,
                                        kind: UTType.plainText.identifier),
                         children: nil))
    }

    /// Every path ever ASSIGNED to one `QLPreviewView`'s `previewItem`, including values overwritten
    /// within a single layout pass.
    ///
    /// Scoped to the one view this test mounts, and it keeps that view alive — an observed object
    /// deallocating with an observer still attached is a crash, and SwiftUI dismantles this one the
    /// moment the column stops previewing.
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
    /// passes that took.
    ///
    /// **Deliberately not `@discardableResult`.** The loop this wraps is bounded, and a bounded wait
    /// whose expiry nobody reads is the vacuous pass `docs/flaky-tests.md` mechanism 8 warns about:
    /// the wait returns, the test carries on against state it never reached, and the assertion after
    /// it means nothing. Both call sites below read `.held` and report `.pumps`; making the compiler
    /// insist on that is free.
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

        // Settle on a previewable file — the only state the defect needs, and the one that gives
        // this test a live `QLPreviewView` to watch.
        let settled = await wait(window, upTo: 10) { quickLookView(in: host) != nil }
        try #require(settled.held,
                     "no Quick Look mounted for the first file after \(settled.pumps) layout passes — the column never settled")
        let preview = try #require(quickLookView(in: host))

        let spy = PreviewItemSpy(watching: preview)
        defer { spy.stop() }

        // The channel's own positive control. `previewItem` is an ordinary Objective-C property, but
        // "ordinary" is an assumption, and an unobservable one would make every assertion below pass
        // for a column that was handing out cloud-only paths all day.
        preview.previewItem = URL(fileURLWithPath: Self.kvoControl) as NSURL
        try #require(spy.assigned.contains(Self.kvoControl),
                     "QLPreviewView.previewItem is not observable here — this test cannot see the assignment it forbids")
        // Put it back, so `updateNSView`'s own "same item?" guard sees what the app would see.
        preview.previewItem = URL(fileURLWithPath: Self.previewable) as NSURL
        spy.reset()

        box.item = Self.item(path: Self.cloudOnly)

        // Sampled until the second probe answers — the interval bounded by the work, not the clock.
        // The assignment this forbids happens in the FIRST committed body after the item changes,
        // which is inside the first pass below.
        let probed = await wait(window, upTo: 20) { log.completed.contains(Self.cloudOnly) }
        #expect(probed.held,
                "the second probe never completed after \(probed.pumps) layout passes — the interval sampled was not the stale one")
        #expect(!spy.assigned.contains(Self.cloudOnly),
                "\(Self.cloudOnly) was handed to Quick Look before its probe answered — mounting a preview on a cloud-only placeholder is the provider download this column exists to avoid")
    }
}
