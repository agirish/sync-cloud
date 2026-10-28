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
        private var port: thread_act_t?
        var thread: thread_act_t? {
            get { lock.withLock { port } }
            set { lock.withLock { port = newValue } }
        }
    }

    @Test("An idle queue yields nothing; a 1.5 s stall yields one line and one stack of it")
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
            Thread.sleep(forTimeInterval: 1.5)
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
        // The stall ended before the 2 s sample did, so the line gives its length: 1.5 s, less the
        // up-to-one beat before the first unanswered heartbeat was posted.
        #expect(line.contains("— it lasted "), "\(line)")
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
}
