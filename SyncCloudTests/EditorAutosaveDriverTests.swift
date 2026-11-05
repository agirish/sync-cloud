import Testing
import SwiftUI
import AppKit
import FileExplorer
@testable import SyncCloud

/// The autosave debounce, mounted.
///
/// The text lives on `EditorBuffer`, which `ContentView` isn't told about, so nothing above the
/// modifier re-renders on a keystroke: the modifier's own `@ObservedObject` on the buffer must be
/// what restarts the timer. If it isn't, autosave silently stops, with the header's dot lit and
/// the file never written. Reading the code can't settle it (it is a claim about how SwiftUI
/// installs a `DynamicProperty` on a `ViewModifier`), so it is mounted and measured.
///
/// The pump waits by the clock, which matters: `CFRunLoopRunInMode(_:_:true)` returns the moment
/// one source is handled, so a hundred of them can finish in under a millisecond, long enough for
/// a `.task` with no `await` and nowhere near long enough for one that sleeps.
@MainActor
@Suite(.serialized) struct EditorAutosaveDriverTests {

    /// Counts what the driver asked for.
    @MainActor
    final class Writes {
        var count = 0
    }

    /// Nothing but the modifier on a one-pixel view, so what is measured is the modifier's own
    /// invalidation, not a parent's.
    private struct Host: View {
        let document: EditorDocument
        let quiet: Duration
        let writes: Writes
        /// What the host's write does besides being counted: nothing, unless a test models it.
        var also: @MainActor () -> Void = {}
        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .modifier(EditorAutosaveDriver(document: document, buffer: document.buffer,
                                               quiet: quiet) { writes.count += 1; also() })
        }
    }

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("autosave-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real, saveable document: the driver schedules nothing for one that can't be written, so a
    /// fabricated one would make every assertion below vacuous.
    private func openedDocument(in folder: URL) throws -> EditorDocument {
        let url = folder.appendingPathComponent("note.md")
        try Data("one\n".utf8).write(to: url)
        let document = EditorDocument()
        EditorFileStore.load(path: url.path, into: document)
        return document
    }

    private func mount(_ document: EditorDocument, quiet: Duration, writes: Writes,
                       also: @escaping @MainActor () -> Void = {}) -> NSWindow {
        let host = NSHostingView(rootView: AnyView(
            Host(document: document, quiet: quiet, writes: writes, also: also)))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        window.layoutIfNeeded()
        return window
    }

    /// One turn of the main run loop, with the main actor released.
    ///
    /// The `await` is the point, not the wait. A synchronous pump holds the main actor throughout,
    /// so nothing SwiftUI or `Task.sleep` enqueued onto it can run, and every test here would fail
    /// with correct code. Suspending lets the work under test happen.
    ///
    /// So it runs no run loop of its own either. A nested `CFRunLoopRunInMode` inside a main-actor
    /// job is that synchronous pump in miniature: GCD doesn't drain the main queue from inside one
    /// of its own callouts, so no main-actor job runs meanwhile, this suite's `.task` included, and
    /// every other suite waits. Releasing the actor lets the app's own run loop lay the window out
    /// and start the `.task`.
    private func turn(_ window: NSWindow) async {
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(5))
    }

    /// Pumps for a fixed interval. Only for waiting out a quiet period that is supposed to pass
    /// with nothing happening.
    private func pump(_ window: NSWindow, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { await turn(window) }
    }

    /// Pumps until `condition` holds, or the ceiling is reached.
    ///
    /// A bounded wait, not a fixed sleep: suites run in parallel on a machine that is also the CI
    /// runner, so a budget quick on an idle machine is a red on a busy one. This returns the
    /// instant the thing happens and spends the ceiling only when it doesn't.
    ///
    /// Bounded by turns as well as seconds: at least `waitPollFloor`, the floor the target's
    /// `waitUntil` uses. The driver's `.task` starting, then resuming after its sleep, are each a
    /// job at the back of the FIFO main queue behind every other suite's main-actor work, which can
    /// hold the main thread for seconds at a stretch. So the budget counts passes, not wall time.
    @discardableResult
    private func wait(_ window: NSWindow, upTo seconds: Double = 10,
                      until condition: () -> Bool) async -> Bool {
        var turns = 0
        let deadline = Date().addingTimeInterval(seconds)
        while turns < waitPollFloor || Date() < deadline {
            if condition() { return true }
            turns += 1
            await turn(window)
        }
        return condition()
    }

    /// The harness control: a document already dirty when the view appears is written by the
    /// first `.task`, with no invalidation involved. Without it, a zero count below could mean "the
    /// harness doesn't run tasks" rather than "the driver is deaf".
    @Test func aDirtyDocumentIsWrittenByTheModifiersFirstTask() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try openedDocument(in: folder)
        document.text = "one\ndirty before it was ever shown\n"
        let writes = Writes()
        let window = mount(document, quiet: .milliseconds(30), writes: writes)
        await wait(window) { writes.count >= 1 }
        #expect(writes.count >= 1, "the modifier's first .task never ran in this harness")
        // Never closed: closing an NSWindow in a test process can crash it.
        withExtendedLifetime(window) {}
    }

    /// A keystroke starts the timer and the timer fires, with nothing above the modifier
    /// re-rendered to make it happen.
    @Test func aKeystrokeStillReachesTheWriteThroughTheDriverAlone() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try openedDocument(in: folder)
        let writes = Writes()
        let window = mount(document, quiet: .milliseconds(30), writes: writes)
        // Long enough that the quiet interval has passed many times over, on any machine.
        await pump(window, seconds: 0.5)

        // A clean document schedules nothing: the control that makes the count below mean "the
        // keystroke did it", not "the mount did it". Not load-sensitive: no amount of waiting
        // writes a document with nothing to write.
        #expect(writes.count == 0, "a clean document was written on mount")

        document.text = "one\ntwo\n"
        await wait(window) { writes.count >= 1 }
        #expect(writes.count >= 1,
                "a keystroke never reached the write: the debounce is not being restarted at all")
        withExtendedLifetime(window) {}
    }

    /// A burst of typing writes once, at the end of it: the debounce, which is why the id is a
    /// version counter rather than the text. A driver that woke on anything would pass the test
    /// above and fail this one.
    @Test func aBurstOfTypingWritesOnceAtTheEndOfIt() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try openedDocument(in: folder)
        let writes = Writes()
        // A long quiet interval on purpose: six keystrokes inside one interval produce one write,
        // so it must outlast the burst even when load stretches a 20ms pump much longer.
        let window = mount(document, quiet: .milliseconds(3000), writes: writes)
        await pump(window, seconds: 0.2)

        // Six keystrokes well inside one quiet interval, each cancelling the last one's wait.
        for index in 1...6 {
            document.text = "one\n" + String(repeating: "x", count: index) + "\n"
            await pump(window, seconds: 0.02)
        }
        // No mid-burst assertion: "nothing written yet" holds only while the burst is shorter than
        // the quiet interval, which load can break. The final count isn't load-sensitive: a driver
        // that wrote per keystroke lands on six whatever the machine is doing.
        await wait(window, upTo: 15) { writes.count >= 1 }
        #expect(writes.count == 1, "a burst of typing produced \(writes.count) writes, not one")
        withExtendedLifetime(window) {}
    }

    /// The host's background write, modelled as `ContentView.runAutosave` does it: one out at a
    /// time and the rest turned away, with the disk held until the test lets it answer.
    @MainActor
    final class SlowLane {
        var writing = false
        var dispatched = 0
        var turnedAway = 0
        var diskAnswers = false

        func run(_ document: EditorDocument) {
            guard !writing else { turnedAway += 1; return }
            guard let snapshot = EditorAutosave.snapshot(of: document) else { return }
            writing = true
            dispatched += 1
            Task { @MainActor in
                // A slow volume: the write is out until the test says the disk has answered.
                let deadline = Date().addingTimeInterval(30)
                while !self.diskAnswers, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
                _ = await EditorAutosave.write(snapshot, into: document)
                self.writing = false
            }
        }
    }

    /// Typing whose debounce fired while a write was still out is written once that write commits.
    /// The host turns the debounce away meanwhile, and with the version and path unchanged nothing
    /// would restart the wait, leaving the last sentence unsaved for a crash to take. The commit
    /// moves the stamp, which the debounce is keyed on.
    @Test func typingTurnedAwayWhileAWriteWasOutIsWrittenWhenItCommits() async throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try openedDocument(in: folder)
        let file = try #require(document.path)
        let writes = Writes()
        let lane = SlowLane()
        let window = mount(document, quiet: .milliseconds(30), writes: writes) { lane.run(document) }
        await pump(window, seconds: 0.2)

        document.text = "one\ntwo\n"
        try #require(await wait(window) { lane.dispatched == 1 }, "the first pause never dispatched a write")
        // More typing, and a pause, while the first write is still out: its debounce is turned away.
        document.text = "one\ntwo\nthree\n"
        try #require(await wait(window) { lane.turnedAway >= 1 }, "the second pause never reached the host")

        lane.diskAnswers = true
        await wait(window, upTo: 15) {
            !document.isDirty && (try? String(contentsOfFile: file, encoding: .utf8)) == "one\ntwo\nthree\n"
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "one\ntwo\nthree\n",
                "the typing turned away while a write was out was never written")
        #expect(!document.isDirty)
        #expect(lane.dispatched == 2, "\(lane.dispatched) writes dispatched, not the one per pause expected")
        withExtendedLifetime(window) {}
    }
}
