import AppKit
import SwiftUI
import Testing
@testable import FileExplorer
import Design
import Sync

/// **A run that stops being cancellable loses its Stop and ⌘. while it is on screen** (L7).
///
/// A copy, move or merge whose work is done and whose undo is still being armed calls
/// `markFinishing`, and the capsule went on offering Stop and ⌘. for the rest of the run: it read
/// `isCancellable` once, when the run's entry was built, while everything else in it is re-read
/// every tick. Driven through a real window's key-equivalent pass, as `ProgressCapsuleCancelKeyTests`
/// drives the capsule itself — here through `RunCapsuleHost`, which is where the stale read was.
@MainActor
@Suite(.serialized) struct RunCapsuleFinishingTests {

    private func host(_ progress: Progress) async throws -> NSWindow {
        let hostView = NSHostingView(rootView: RunCapsuleHost(
            activeProgress: progress, activeProgressStartedAt: Date(), center: ActivityCenter(),
            runWriteLock: nil, style: .full))
        hostView.frame = CGRect(x: 0, y: 0, width: 400, height: 120)
        let window = NSWindow(contentRect: hostView.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        try await settle(hostView)
        return window
    }

    /// Several of the capsule's 0.1 s ticks, with layout passes between them.
    private func settle(_ view: NSView) async throws {
        for _ in 0..<30 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func commandPeriod(_ window: NSWindow) throws -> NSEvent {
        // keyCode 47 is the period key.
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: ".", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47))
    }

    private func running() -> Progress {
        let progress = Progress(totalUnitCount: 3)
        progress.localizedDescription = "Copying 3 items"
        progress.isCancellable = true
        progress.completedUnitCount = 3
        return progress
    }

    @Test func aRunMarkedFinishingNoLongerTakesCommandPeriod() async throws {
        // The control: the same host, still cancellable, takes ⌘. — so the harness can see it.
        let live = running()
        let liveWindow = try await host(live)
        defer { liveWindow.close() }
        #expect(liveWindow.performKeyEquivalent(with: try commandPeriod(liveWindow)),
                "premise: ⌘. is not claimed by a cancellable run's capsule, so the absence below proves nothing")
        #expect(live.isCancelled)

        let finishing = running()
        let window = try await host(finishing)
        defer { window.close() }
        finishing.markFinishing()
        try await settle(try #require(window.contentView))

        #expect(!window.performKeyEquivalent(with: try commandPeriod(window)),
                "⌘. is still claimed by a run that has nothing left to stop")
        #expect(!finishing.isCancelled, "⌘. cancelled a run that is only arming its undo")
    }
}
