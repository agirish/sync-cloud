import Testing
import SwiftUI
import AppKit
import FileExplorer
@testable import SyncCloud

/// **The debounce, mounted — because what drives it changed underneath it.**
///
/// The buffer used to be `@Published` on `EditorDocument`, which `ContentView` holds as an
/// `@ObservedObject` and the App scene as a `@StateObject`. So a keystroke re-evaluated the whole
/// window and the whole menu tree, and *that* re-evaluation is what handed this modifier a new
/// `.task(id:)` to restart on. The text now lives on `EditorBuffer`, `ContentView` is not told about
/// it, and the modifier's own `@ObservedObject` on the buffer has to be what restarts the timer.
///
/// If it is not, autosave simply stops — silently, with the header's dot lit and the file never
/// written. That is the single most expensive way this change could be wrong, and reading the code
/// does not settle it: it is a claim about how SwiftUI installs a `DynamicProperty` on a
/// `ViewModifier`. So it is mounted and measured.
///
/// **The pump waits by the clock, and that is load-bearing.** `CFRunLoopRunInMode(_:_:true)` returns
/// the moment one source is handled, so a loop of a hundred of them can finish in well under a
/// millisecond — long enough for a `.task` with no `await` in it, and nowhere near long enough for
/// one that sleeps. Written that way, every test here failed while the code was correct, and the
/// plain-`.task` control passed: exactly the shape of a harness bug wearing a regression's clothes.
@MainActor
@Suite(.serialized) struct EditorAutosaveDriverTests {

    /// Counts what the driver asked for.
    @MainActor
    final class Writes {
        var count = 0
    }

    /// Nothing but the modifier: a one-pixel view, so what is measured is the modifier's own
    /// invalidation rather than some parent's.
    private struct Host: View {
        let document: EditorDocument
        let quiet: Duration
        let writes: Writes
        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .modifier(EditorAutosaveDriver(document: document, buffer: document.buffer,
                                               quiet: quiet) { writes.count += 1 })
        }
    }

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("autosave-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real, saveable document — the driver schedules nothing for one that cannot be written, so
    /// a fabricated one would make every assertion below vacuous.
    private func openedDocument(in folder: URL) throws -> EditorDocument {
        let url = folder.appendingPathComponent("note.md")
        try Data("one\n".utf8).write(to: url)
        let document = EditorDocument()
        EditorFileStore.load(path: url.path, into: document)
        return document
    }

    private func mount(_ document: EditorDocument, quiet: Duration, writes: Writes) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(
            Host(document: document, quiet: quiet, writes: writes)))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        window.layoutIfNeeded()
        return window
    }

    /// One turn of the main run loop, with the main actor RELEASED.
    ///
    /// **The `await` is the point, not the wait.** A synchronous pump holds the main actor for its
    /// whole duration, so nothing SwiftUI or `Task.sleep` enqueued onto the main actor can run —
    /// and written that way every test here failed while the code was correct, including a control
    /// that did nothing but sleep. Suspending is what lets the work under test actually happen.
    private func turn(_ window: NSWindow) async {
        window.layoutIfNeeded()
        _ = CFRunLoopRunInMode(.defaultMode, 0.005, false)
        try? await Task.sleep(for: .milliseconds(5))
    }

    /// Pumps for a fixed interval. Only for waiting out a quiet period that is *supposed* to pass
    /// with nothing happening.
    private func pump(_ window: NSWindow, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { await turn(window) }
    }

    /// Pumps until `condition` holds, or the ceiling is reached.
    ///
    /// **A bounded wait, not a fixed sleep**, for the reason every wait in this repo is one: these
    /// suites run in parallel on the machine that is also the CI runner, so a budget tight enough
    /// to be quick when the machine is idle is a red when it is not. This returns the instant the
    /// thing happens and only spends the ceiling when it does not.
    @discardableResult
    private func wait(_ window: NSWindow, upTo seconds: Double = 10,
                      until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await turn(window)
        }
        return condition()
    }

    /// The harness control: a document already dirty when the view appears is written by the very
    /// first `.task`, with no invalidation involved. Without this passing, a zero count below would
    /// mean "the harness does not run tasks" rather than "the driver is deaf".
    @Test func aDirtyDocumentIsWrittenByTheModifiersFirstTask() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try openedDocument(in: folder)
        document.text = "one\ndirty before it was ever shown\n"
        let writes = Writes()
        let window = mount(document, quiet: .milliseconds(30), writes: writes)
        await wait(window) { writes.count >= 1 }
        #expect(writes.count >= 1, "the modifier's first .task never ran in this harness")
        // Never closed: closing an NSWindow in a test process is a crash this repo already avoids.
        withExtendedLifetime(window) {}
    }

    /// **A keystroke still starts the timer, and the timer still fires — with nothing above the
    /// modifier re-rendered to make it happen.**
    @Test func aKeystrokeStillReachesTheWriteThroughTheDriverAlone() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try openedDocument(in: folder)
        let writes = Writes()
        let window = mount(document, quiet: .milliseconds(30), writes: writes)
        // Long enough that the quiet interval has passed many times over, on any machine.
        await pump(window, seconds: 0.5)

        // A clean document schedules nothing — the control that makes the count below mean "the
        // keystroke did it" rather than "the mount did it". Not load-sensitive in the other
        // direction: no amount of waiting writes a document that has nothing to write.
        #expect(writes.count == 0, "a clean document was written on mount")

        document.text = "one\ntwo\n"
        await wait(window) { writes.count >= 1 }
        #expect(writes.count >= 1,
                "a keystroke never reached the write: the debounce is not being restarted at all")
        withExtendedLifetime(window) {}
    }

    /// **And a burst of typing writes once, at the end of it** — the debounce, which is the whole
    /// reason the id is a version counter rather than the text. A driver that woke on nothing in
    /// particular would pass the test above and fail this one.
    @Test func aBurstOfTypingWritesOnceAtTheEndOfIt() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try openedDocument(in: folder)
        let writes = Writes()
        // **A long quiet interval on purpose.** The claim is that six keystrokes inside ONE
        // interval produce one write, so the interval has to outlast the burst even when the
        // machine is busy enough to stretch a 20ms pump into a much longer one.
        let window = mount(document, quiet: .milliseconds(3000), writes: writes)
        await pump(window, seconds: 0.2)

        // Six keystrokes well inside one quiet interval, each cancelling the last one's wait.
        for index in 1...6 {
            document.text = "one\n" + String(repeating: "x", count: index) + "\n"
            await pump(window, seconds: 0.02)
        }
        // **No mid-burst assertion, deliberately.** "Nothing has been written yet" is true only
        // while the burst is shorter than the quiet interval, and on a loaded machine — this repo's
        // CI runner is this Mac — a 120ms burst can take longer than that to pump. The count at the
        // end is the claim worth making and is not load-sensitive: a driver that wrote per
        // keystroke lands on six here whatever the machine is doing.
        await wait(window, upTo: 15) { writes.count >= 1 }
        #expect(writes.count == 1, "a burst of typing produced \(writes.count) writes, not one")
        withExtendedLifetime(window) {}
    }
}
