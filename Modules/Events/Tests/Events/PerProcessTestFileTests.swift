import Testing
import Foundation
@testable import Events

/// The sweep that keeps dead test runs' per-process logs and history files from piling up in the
/// temp directory. Each test sweeps a private scratch directory, never the real one.
@Suite struct PerProcessTestFileTests {

    private let stem = PerProcessTestFile.logStem
    private let now = Date()
    private var old: Date { now.addingTimeInterval(-PerProcessTestFile.retention - 60) }

    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerProcessTestFileTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func touch(_ name: String, in directory: URL, modified: Date) throws {
        let url = directory.appendingPathComponent(name)
        try Data("x\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test func aDeadRunsFilesAreRemovedWithTheirSidecars() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["\(stem)-41.log", "\(stem)-41.log.lock", "\(stem)-41.log.sb-aaa8fe24-8yCw0i"] {
            try touch(name, in: directory, modified: old)
        }

        let removed = PerProcessTestFile.sweep(stem: stem, extension: "log", in: directory, now: now,
                                               isRunning: { _ in false })

        #expect(removed == ["\(stem)-41.log", "\(stem)-41.log.lock", "\(stem)-41.log.sb-aaa8fe24-8yCw0i"])
        #expect(try names(in: directory).isEmpty)
    }

    /// The one thing the sweep must never do: take a concurrent run's files. Uses the real
    /// liveness check against this process, however old the files look.
    @Test func aRunningProcesssFilesAreKept() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pid = ProcessInfo.processInfo.processIdentifier
        try touch("\(stem)-\(pid).log", in: directory, modified: old)
        try touch("\(stem)-\(pid).log.lock", in: directory, modified: old)

        let removed = PerProcessTestFile.sweep(stem: stem, extension: "log", in: directory, now: now)

        #expect(removed.isEmpty)
        #expect(try names(in: directory) == ["\(stem)-\(pid).log", "\(stem)-\(pid).log.lock"])
    }

    /// A finished run's log is the post-mortem `docs/flaky-tests.md` points at, so it outlives its
    /// process by `retention` — judged by the NEWEST file in the group, because the `.lock` is only
    /// ever created and keeps its birth time while the log goes on being written.
    @Test func aDeadRunWrittenWithinTheRetentionIsKept() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try touch("\(stem)-41.log", in: directory, modified: now.addingTimeInterval(-60))
        try touch("\(stem)-41.log.lock", in: directory, modified: old)

        let removed = PerProcessTestFile.sweep(stem: stem, extension: "log", in: directory, now: now,
                                               isRunning: { _ in false })

        #expect(removed.isEmpty)
        #expect(try names(in: directory) == ["\(stem)-41.log", "\(stem)-41.log.lock"])
    }

    /// Only the exact `<stem>-<digits>.<ext>` shape is ever touched: not the other resolver's
    /// files, not the production log, not a near miss.
    @Test func namesOutsideThePatternAreUntouched() throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bystanders = [
            "sync-cloud.log",
            "\(stem)-.log",
            "\(stem)-12a.log",
            "\(stem)-12.logx",
            "\(stem)-12.jsonl",
            "\(stem)-0.log",
            "\(PerProcessTestFile.historyStem)-12.jsonl",
            "x-\(stem)-12.log",
        ]
        for name in bystanders { try touch(name, in: directory, modified: old) }
        try touch("\(stem)-12.log", in: directory, modified: old)

        var asked: [pid_t] = []
        let removed = PerProcessTestFile.sweep(stem: stem, extension: "log", in: directory, now: now,
                                               isRunning: { asked.append($0); return false })

        #expect(removed == ["\(stem)-12.log"])
        #expect(asked == [12])
        #expect(try names(in: directory) == bystanders.sorted())
    }

    /// The premise of the liveness check: this process is running, and a child that has exited and
    /// been reaped is not.
    @Test func isRunningTellsALiveProcessFromAReapedOne() throws {
        #expect(PerProcessTestFile.isRunning(ProcessInfo.processInfo.processIdentifier))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(!PerProcessTestFile.isRunning(child.processIdentifier))
    }

    /// Both resolvers hand out names the sweep recognises as this process's — so a rename on
    /// either side cannot quietly turn the sweep off.
    @Test func theResolversNamesAreTheOnesTheSweepMatches() {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(PerProcessTestFile.pid(inFileNamed: Logger.defaultLogFileURL().lastPathComponent,
                                       stem: PerProcessTestFile.logStem, extension: "log") == pid)
        #expect(PerProcessTestFile.pid(inFileNamed: SyncHistoryStore.defaultFileURL().lastPathComponent,
                                       stem: PerProcessTestFile.historyStem, extension: "jsonl") == pid)
    }
}
