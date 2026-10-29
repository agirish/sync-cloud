import Foundation
import Testing
@testable import FileExplorer

/// `MainThreadStallWatch` takes one stack per stall and says where it put it.
///
/// Driven over a private serial queue rather than the main one: a 1.5 s sleep on the main thread
/// would stall every other suite's main-actor work in the same process. The watch treats any queue
/// the same way, and is told which thread the stall is on. The real `/usr/bin/sample` runs against
/// this test process.
@Suite(.serialized) struct MainThreadStallWatchTests {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var stalls: [String] { lock.withLock { lines.filter { $0.hasPrefix("[stall] main thread went") } } }
        var all: [String] { lock.withLock { lines } }
        private var port: thread_act_t?
        var thread: thread_act_t? {
            get { lock.withLock { port } }
            set { lock.withLock { port = newValue } }
        }
    }

    @Test("An idle queue yields nothing; a 3 s stall yields one line and one stack of it")
    func aStallLeavesOneLineAndOneStack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stall-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = MainThreadStallWatch.Configuration()
        configuration.directory = directory
        configuration.beat = 0.2
        configuration.minimumGap = 0
        configuration.perSession = 10
        let lines = Lines()
        let queue = DispatchQueue(label: "stall-watch-test")
        let watch = MainThreadStallWatch(configuration: configuration, queue: queue,
                                         thread: { lines.thread },
                                         report: { lines.append($0) })
        watch.start()
        defer { watch.stop() }

        // The control: answered heartbeats are not stalls, however many go by.
        try await Task.sleep(for: .seconds(2))
        #expect(lines.stalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        queue.async {
            lines.thread = pthread_mach_thread_np(pthread_self())
            // 3 s, not 1.5: noticed 1.0–1.2 s in, a 1.5 s stall left a loaded runner a few
            // hundred milliseconds to take its first stack.
            Thread.sleep(forTimeInterval: 3)
        }

        // The sample records 2 s and then symbolicates; bounded, never open-ended.
        let deadline = Date().addingTimeInterval(20)
        while lines.stalls.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        // Long enough for a second, wrongful sample to have been started and reported.
        try await Task.sleep(for: .seconds(3))

        let stalls = lines.stalls
        #expect(stalls.count == 1, "\(stalls)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.count == 1, "\(files)")
        let line = try #require(stalls.first)
        let file = try #require(files.first)
        #expect(line.contains("Stack: \(directory.appendingPathComponent(file).path)"), "\(line)")
        // The line gives the stall's length, or says it is still going and then ends it.
        #expect(line.contains("— it lasted ") || line.contains("— still stalled "), "\(line)")
        let stack = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
        // The stack is OF the stall: the in-process half, taken the moment it was noticed, has the
        // sleep in it. `sample`'s half is not asserted on: it attaches half a second late, which
        // is why the in-process half exists, and a 1.5 s stall can be over by then.
        let inProcess = try #require(stack.components(separatedBy: "---- /usr/bin/sample").first)
        #expect(inProcess.contains("Main thread, sampled in-process"), "\(inProcess.prefix(300))")
        #expect(inProcess.contains("__semwait_signal") || inProcess.contains("nanosleep"),
                "the in-process stacks missed the stall: \(inProcess.prefix(1500))")
        #expect(stack.contains("Call graph"), "sample's report is missing")
        #expect(watch.samplesTaken == 1)
    }

    /// A semaphore wait outside the async context (unavailable there), bounded.
    private static func waitBriefly(_ semaphore: DispatchSemaphore) { _ = semaphore.wait(timeout: .now() + 5) }

    /// A thread idle in its own outermost run loop, entered through Foundation's `RunLoop` the way
    /// the main thread's is entered through HIToolbox. It waits for `.distantFuture`, so it never
    /// leaves the wait between samples; `perform` runs a block inside the loop, nested waits included.
    private final class RunLoopThread: Thread, @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private(set) var port: thread_act_t = 0
        private var loop: CFRunLoop?
        override func main() {
            port = pthread_mach_thread_np(pthread_self())
            loop = CFRunLoopGetCurrent()
            RunLoop.current.add(NSMachPort(), forMode: .default)   // a source, so it waits instead of returning
            ready.signal()
            while !isCancelled { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        func startAndWait() -> thread_act_t { start(); _ = ready.wait(timeout: .now() + 5); return port }
        func perform(_ block: @escaping () -> Void) {
            guard let loop else { return }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
            CFRunLoopWakeUp(loop)
        }
        func finish() { cancel(); if let loop { CFRunLoopStop(loop) } }
    }

    /// The idle test has to tell "idle in the outermost run loop" from every other kernel wait —
    /// nested run loops above all, which park in the very same frames — or it would throw real
    /// stalls away.
    @Test("Only an outermost idle run loop reads as idle; nested loops, port requests, opens, sleeps and semaphores do not")
    func theRunLoopParkIsToldFromOtherWaits() async throws {
        func parked(_ port: thread_act_t) -> Bool {
            ThreadStackSampler.isParkedInRunLoop(ThreadStackSampler.snapshot(of: port), enteredFrom: "Foundation")
        }
        let idle = RunLoopThread()
        let idlePort = idle.startAndWait()
        defer { idle.finish() }
        try await Task.sleep(for: .milliseconds(300))   // into its wait
        #expect(parked(idlePort), "an idle outermost loop must read as idle — the test proves nothing otherwise")

        // A nested run loop in a private mode: the same four frames, and a real stall.
        let nested = RunLoopThread()
        let nestedPort = nested.startAndWait()
        defer { nested.finish() }
        nested.perform {
            RunLoop.current.add(NSMachPort(), forMode: RunLoop.Mode("stall-watch-private"))
            _ = CFRunLoopRunInMode(CFRunLoopMode("stall-watch-private" as CFString), 3, false)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!parked(nestedPort), "a nested run loop read as idle")

        // Nested through the same entry as the outer loop — as a modal session nests through
        // HIToolbox on the main thread — so only the second `__CFRunLoopRun` tells it apart.
        let modal = RunLoopThread()
        let modalPort = modal.startAndWait()
        defer { modal.finish() }
        modal.perform {
            RunLoop.current.add(NSMachPort(), forMode: RunLoop.Mode("stall-watch-modal"))
            _ = RunLoop.current.run(mode: RunLoop.Mode("stall-watch-modal"), before: .now + 3)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!parked(modalPort), "a loop nested through the outer loop's own entry read as idle")

        // A synchronous message-port request whose reply is slow, as an Apple Event waits.
        let name = "stall-watch.\(getpid()).\(UUID().uuidString)" as CFString
        let server = RunLoopThread()
        _ = server.startAndWait()
        defer { server.finish() }
        let made = DispatchSemaphore(value: 0)
        server.perform {
            let local = CFMessagePortCreateLocal(nil, name, { _, _, _, _ in sleep(2); return nil }, nil, nil)!
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMessagePortCreateRunLoopSource(nil, local, 0), .defaultMode)
            made.signal()
        }
        Self.waitBriefly(made)
        let client = RunLoopThread()
        let clientPort = client.startAndWait()
        defer { client.finish() }
        client.perform {
            guard let remote = CFMessagePortCreateRemote(nil, name) else { return }
            var reply: Unmanaged<CFData>?
            _ = CFMessagePortSendRequest(remote, 1, nil, 5, 5, CFRunLoopMode.defaultMode.rawValue, &reply)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!parked(clientPort), "a port request waiting on its reply read as idle")

        let lines = Lines()
        // An open that blocks in the kernel: a FIFO with no writer, read through CoreFoundation.
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("stall-watch-\(UUID().uuidString)")
        mkfifo(fifo.path, 0o600)
        defer { unlink(fifo.path) }
        let opener = DispatchQueue(label: "stall-watch-open")
        opener.async {
            lines.thread = pthread_mach_thread_np(pthread_self())
            let stream = CFReadStreamCreateWithFile(nil, fifo as CFURL)!
            _ = CFReadStreamOpen(stream)
            CFReadStreamClose(stream)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!parked(try #require(lines.thread)), "a blocked open read as idle")
        let writer = open(fifo.path, O_WRONLY | O_NONBLOCK)   // lets the open finish
        if writer >= 0 { close(writer) }

        let gate = DispatchSemaphore(value: 0)
        lines.thread = nil
        DispatchQueue(label: "stall-watch-blocked").async {
            lines.thread = pthread_mach_thread_np(pthread_self()); _ = gate.wait(timeout: .now() + 10)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!parked(try #require(lines.thread)), "a semaphore wait read as idle")
        gate.signal()

        lines.thread = nil
        DispatchQueue(label: "stall-watch-sleeper").async {
            lines.thread = pthread_mach_thread_np(pthread_self()); Thread.sleep(forTimeInterval: 1)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!parked(try #require(lines.thread)), "a sleep read as idle")
    }

    /// The false stalls of 10-28: a heartbeat held back while the watched thread sits idle in its
    /// run loop. No line, no file, no sample spent — and the count reaches the next real line.
    @Test("An overdue heartbeat over an idle run loop is not sampled")
    func anIdleRunLoopIsNotAStall() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stall-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = MainThreadStallWatch.Configuration()
        configuration.directory = directory
        configuration.beat = 0.2
        configuration.minimumGap = 0
        configuration.runLoopEntry = "Foundation"
        configuration.reportHeldAfter = 1
        let idle = RunLoopThread()
        let port = idle.startAndWait()
        defer { idle.finish() }
        let lines = Lines()
        // The heartbeats queue here and never run, as the system held them on 10-28.
        let held = DispatchQueue(label: "stall-watch-held")
        held.suspend()
        var heldResumed = false
        defer { if !heldResumed { held.resume() } }
        let watch = MainThreadStallWatch(configuration: configuration, queue: held,
                                         thread: { port }, report: { lines.append($0) })
        watch.start()
        defer { watch.stop() }
        try await Task.sleep(for: .seconds(3))
        #expect(lines.stalls.isEmpty, "\(lines.stalls)")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(watch.samplesTaken == 0)
        #expect(watch.heldWhileIdle == 1, "one held heartbeat counts once, however often it is looked at")
        held.resume()
        heldResumed = true
        let deadline = Date().addingTimeInterval(5)
        while !lines.all.contains(where: { $0.contains("held by the system") }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(lines.all.contains { $0.contains("held by the system") && $0.contains("__CFRunLoopServiceMachPort") },
                "a held heartbeat leaves one line naming the idle stack: \(lines.all)")
    }

    /// A run of stalls costs one sample: a second, inside `minimumGap`, is not taken — and with no
    /// gap it is, which is what makes the first half mean something. The second stall is queued
    /// only after the first is reported and heartbeats are answering again, so the two are two
    /// stalls, not one long one.
    @Test("A second stall inside the gap is not sampled; with no gap it is", arguments: [600.0, 0.0])
    func theGapHoldsASecondStall(gap: TimeInterval) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stall-watch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = MainThreadStallWatch.Configuration()
        configuration.directory = directory
        configuration.beat = 0.2
        configuration.minimumGap = gap
        let lines = Lines()
        let queue = DispatchQueue(label: "stall-watch-gap-\(gap)")
        let watch = MainThreadStallWatch(configuration: configuration, queue: queue,
                                         thread: { lines.thread }, report: { lines.append($0) })
        watch.start()
        defer { watch.stop() }
        func stall() { queue.async { lines.thread = pthread_mach_thread_np(pthread_self()); Thread.sleep(forTimeInterval: 2) } }
        func waitForStalls(_ n: Int) async throws {
            let deadline = Date().addingTimeInterval(25)
            while lines.stalls.count < n, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        }
        stall()
        try await waitForStalls(1)
        try await Task.sleep(for: .seconds(1))   // heartbeats answer again: the first stall is over
        stall()
        if gap == 0 { try await waitForStalls(2) } else { try await Task.sleep(for: .seconds(5)) }
        #expect(watch.samplesTaken == (gap == 0 ? 2 : 1))
        #expect(lines.stalls.count == (gap == 0 ? 2 : 1), "\(lines.stalls)")
    }
}
