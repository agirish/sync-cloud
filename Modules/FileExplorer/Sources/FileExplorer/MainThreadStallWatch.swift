import AppKit
import Darwin
import Events
import Foundation

/// Takes a stack of the main thread while it is stalled, so a multi-second freeze leaves evidence.
///
/// **Why the hitch monitor cannot.** `MainThreadHitchMonitor` times a turn from its run-loop
/// observers, so it learns a turn was long only once the turn ends — by then the stack that took
/// the time is gone. It is also DEBUG-level and armed only with the pane trace, both off on a
/// normal install. The stalls this exists for (2–8 s on the Compare header, 5.4 s once at launch)
/// left a duration at best and nothing to name it by.
///
/// **How.** A background timer posts a heartbeat onto the main queue every `beat` seconds and
/// waits for it to run. A heartbeat still unanswered after `stallAfter` means the main thread has
/// not finished a turn for that long — in its own code, in layout, in drawing, anywhere. The watch
/// then samples the main thread's stack from inside the process at once (`ThreadStackSampler`), and
/// runs `/usr/bin/sample <own pid> 2` beside it for every thread's; both go into one file, and one
/// INFO line names it, says how long the stall lasted and how much CPU the main thread spent in it.
/// `sample` alone missed short stalls: it takes about half a second to attach. Not a run-loop
/// observer: an order-0 observer closes the turn before Core Animation's commit, and a stall inside
/// that layout would never be seen to start.
///
/// **On in every build**, because the stalls happen in the installed Release app. It costs two
/// main-queue wakes a second while running; a sample is rate-limited (`minimumGap`, `perSession`)
/// and old files are pruned (`keep`). The test host never starts it — the start sits inside the
/// app's `!isRunningTests` launch block.
public final class MainThreadStallWatch: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// How long the main queue may go without answering before a stack is taken.
        public var stallAfter: TimeInterval = 1.0
        /// How often a heartbeat is posted. A stall is noticed between `stallAfter` and
        /// `stallAfter + beat` after it begins: each heartbeat is checked exactly `stallAfter`
        /// after it is posted, and the first one a stall holds up was posted up to a beat late.
        public var beat: TimeInterval = 0.5
        /// How long `sample` records, in whole seconds.
        public var sampleSeconds = 2
        /// The least time between two samples, so a run of stalls costs one sample, not one each.
        public var minimumGap: TimeInterval = 60
        /// The most samples one launch takes.
        public var perSession = 20
        /// Stack files kept in `directory`; older ones are deleted after each new one.
        public var keep = 30
        /// How long `sample` may run past its own seconds before it is stopped and the file is
        /// finished without it. A `sample` that never exits must not switch the watch off.
        public var sampleGrace: TimeInterval = 30
        /// The image whose frame enters the watched thread's outermost run loop — HIToolbox's event
        /// loop on the main thread. See `ThreadStackSampler.isParkedInRunLoop`.
        public var runLoopEntry = "HIToolbox"
        /// A heartbeat the system held this long over an idle app gets one INFO line, so a wrong
        /// idle verdict could never hide stalls without a trace. At most `perSession` of them.
        public var reportHeldAfter: TimeInterval = 3
        /// Where stack files go.
        public var directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SyncCloud/Stalls", isDirectory: true)
        public init() {}
    }

    /// The app's watch, over the main queue.
    public static let shared = MainThreadStallWatch(configuration: Configuration(), queue: .main,
                                                    report: { _ = Logger.shared.info($0) })

    let configuration: Configuration
    private let watched: DispatchQueue
    private let report: @Sendable (String) -> Void
    /// The watched thread, when a test watches a queue of its own. `nil` in the app, which reads
    /// the main thread's port in `start()`.
    private let threadForTesting: (@Sendable () -> thread_act_t?)?
    private let state = DispatchQueue(label: "com.abhishekgirish.SyncCloud.stall-watch", qos: .userInitiated)
    /// Where the in-process sampler runs: not `state`, which must stay free to hear the stall end.
    private let snapshots = DispatchQueue(label: "com.abhishekgirish.SyncCloud.stall-watch.stacks",
                                          qos: .userInteractive)

    // Everything below is touched only on `state`.
    private var timer: DispatchSourceTimer?
    /// The watched queue's thread, for its stack and CPU time. Set by `start()` when that runs on
    /// the main thread watching the main queue; otherwise `threadForTesting` answers.
    private var mainThread: thread_act_t?
    private var thread: thread_act_t? { threadForTesting?() ?? mainThread }
    /// When the outstanding heartbeat was posted, and the watched thread's CPU time then. `nil`
    /// once it has run.
    private var posted: (at: TimeInterval, cpu: TimeInterval?)?
    /// What the last answered heartbeat saw of the app, for the line about a stall that follows it.
    private var lastContext = "app state unknown"
    /// The stall being recorded, and the two halves of its file as they arrive.
    private var sampling: (stallBegan: TimeInterval, cpuBegan: TimeInterval?, file: URL,
                           stacks: String?, sampleStatus: Int32?, process: Process?)?
    /// When the stall being sampled ended, once its heartbeat finally ran, and the watched
    /// thread's CPU time then — read at the end of the stall, not when the file is finished
    /// seconds later, or the line credits the stall with work done after it.
    private var sampledStallEnded: (at: TimeInterval, cpu: TimeInterval?)?
    /// A stall whose line went out while it was still going: its end gets a line of its own.
    private var unfinishedStall: (began: TimeInterval, cpuBegan: TimeInterval?)?
    /// Overdue heartbeats while the main thread sat idle in its run loop — held back by the
    /// system, not stalls. Counted once per heartbeat, so the next real stall's line can say so.
    private(set) var heldWhileIdle = 0
    /// The held heartbeat: when it was posted, and the idle stack that excused it.
    private var held: (postedAt: TimeInterval, stack: [UInt])?
    private var heldReported = 0
    /// A held heartbeat's first busy look after idle ones. A timer turn of a few milliseconds can
    /// run while the system still holds the heartbeat, so one busy look is not yet a stall: it
    /// restarts the clock, and only a second busy look a full `stallAfter` later is sampled.
    private var busyAfterHold = false
    /// Whether a modal session was up at the last answered heartbeat. Its loop nests inside the
    /// event loop and drains the main queue, so it idles two loops deep.
    private var modalUp = false
    private var lastSample: TimeInterval?
    private(set) var samplesTaken = 0

    init(configuration: Configuration, queue: DispatchQueue,
         thread: (@Sendable () -> thread_act_t?)? = nil,
         report: @escaping @Sendable (String) -> Void) {
        self.configuration = configuration
        self.watched = queue
        self.threadForTesting = thread
        self.report = report
    }

    /// Starts watching. Idempotent. Call it on the main thread for the main queue's watch, so the
    /// watch can read the main thread's CPU time.
    public func start() {
        let port: thread_act_t? = (Thread.isMainThread && watched === DispatchQueue.main)
            ? pthread_mach_thread_np(pthread_self()) : nil
        state.sync {
            guard timer == nil else { return }
            mainThread = port
            let source = DispatchSource.makeTimerSource(queue: state)
            source.schedule(deadline: .now() + configuration.beat, repeating: configuration.beat,
                            leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
        report(String(format: "[stall] watch armed — a stack is sampled after %.1f s without a main-thread turn, into %@",
                      configuration.stallAfter, configuration.directory.path))
    }

    func stop() {
        state.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Uptime, not wall time: a Mac asleep with a heartbeat outstanding is not a stall.
    private static func now() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    private func threadCPU() -> TimeInterval? {
        guard let thread else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        func seconds(_ t: time_value_t) -> TimeInterval { TimeInterval(t.seconds) + TimeInterval(t.microseconds) / 1e6 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    private func tick() {
        let now = Self.now()
        guard let posted else {
            self.posted = (now, threadCPU())
            let isMain = watched === DispatchQueue.main
            watched.async { [weak self] in
                let answered = Self.now()
                // Read here, on the main thread, while it is free: once it stalls nothing can be.
                let context = isMain ? MainActor.assumeIsolated { MainThreadHitchMonitor.appContext() } : nil
                let modal = isMain ? MainActor.assumeIsolated { NSApp.modalWindow != nil } : false
                self?.state.async { self?.modalUp = modal; self?.answered(at: answered, context: context) }
            }
            // Checked on its own deadline rather than at the next beat, which could be up to a
            // beat later — time a short stall cannot spare: the sample has to start inside it.
            state.asyncAfter(deadline: .now() + configuration.stallAfter) { [weak self] in self?.check() }
            return
        }
        check()
    }

    private func check() {
        let now = Self.now()
        guard let posted, now - posted.at >= configuration.stallAfter, sampling == nil else { return }
        // An idle main thread with a heartbeat still queued is the system holding the app back,
        // not the app stalling. Checked from one stack — microseconds, and taken off this queue's
        // clock — before anything is spent on it: each false sample cost a 230 KB file, a run
        // of `sample`, and the minute and the per-launch budget a real stall would need. Checked
        // BEFORE the budget and the gap, so the clock keeps restarting while they hold sampling
        // off; otherwise the first stall after the gap was dated from a heartbeat a minute old.
        if let thread {
            let stack = ThreadStackSampler.snapshot(of: thread)
            if isIdle(stack) {
                if held == nil {
                    held = (posted.at, stack)
                    heldWhileIdle += 1
                }
                busyAfterHold = false
                // A stall whose sample ended while it went on, now over: its end is here.
                if let unfinished = unfinishedStall, unfinished.began == posted.at {
                    reportEnd(of: unfinished, at: now)
                }
                // The stall clock restarts here: if the app does stall once it wakes, the line must
                // not blame it for the time the system held it. It also means the next look is a
                // full `stallAfter` away, rather than suspending the thread twice a second for hours.
                self.posted = (now, threadCPU())
                return
            }
            if held != nil, !busyAfterHold {
                busyAfterHold = true
                self.posted = (now, threadCPU())
                return
            }
        }
        guard samplesTaken < configuration.perSession,
              lastSample.map({ now - $0 >= configuration.minimumGap }) ?? true
        else { return }
        // A heartbeat excused as idle and then caught stalling is a stall, not a hold: it gets
        // the stall's line alone, not a "held by the system" line beside it.
        held = nil
        busyAfterHold = false
        beginSample(stallBegan: posted.at, cpuBegan: posted.cpu, at: now)
    }

    private func isIdle(_ stack: [UInt]) -> Bool {
        ThreadStackSampler.isParkedInRunLoop(stack, enteredFrom: configuration.runLoopEntry, loops: 1)
            || (modalUp && ThreadStackSampler.isParkedInRunLoop(stack, enteredFrom: configuration.runLoopEntry, loops: 2))
    }

    private func reportEnd(of unfinished: (began: TimeInterval, cpuBegan: TimeInterval?), at time: TimeInterval) {
        var line = String(format: "[stall] the stall noticed earlier ended after %.2f s", time - unfinished.began)
        if let cpuBegan = unfinished.cpuBegan, let cpu = threadCPU() {
            line += String(format: ", main thread CPU %.2f s", cpu - cpuBegan)
        }
        report(line)
        unfinishedStall = nil
    }

    private func answered(at time: TimeInterval, context: String?) {
        if let held {
            let wait = time - held.postedAt
            if wait >= configuration.reportHeldAfter, heldReported < configuration.perSession {
                heldReported += 1
                report(String(format: "[stall] a heartbeat waited %.1f s with the main thread idle in its run loop "
                              + "— held by the system, not sampled. Its stack: ", wait)
                       + ThreadStackSampler.describe(held.stack, count: 6))
            }
            self.held = nil
        }
        if let began = posted?.at {
            if let sampling, began == sampling.stallBegan {
                sampledStallEnded = (time, threadCPU())
            } else if let unfinished = unfinishedStall, began == unfinished.began {
                reportEnd(of: unfinished, at: time)
            }
        }
        posted = nil
        if let context { lastContext = context }
    }

    private func beginSample(stallBegan: TimeInterval, cpuBegan: TimeInterval?, at now: TimeInterval) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withDashSeparatorInDate])
        let file = configuration.directory.appendingPathComponent("stall-\(stamp).txt")
        try? FileManager.default.createDirectory(at: configuration.directory, withIntermediateDirectories: true)
        sampling = (stallBegan, cpuBegan, file, nil, nil, nil)
        sampledStallEnded = nil
        lastSample = now
        samplesTaken += 1

        let interval: TimeInterval = 0.005
        let limit = TimeInterval(configuration.sampleSeconds)
        if let thread {
            snapshots.async { [weak self] in
                // The stall ends at the first stack that shows the thread idle again, not when the
                // heartbeat finally runs: the system can hold that heartbeat on past the stall (on
                // 10-29 a 2.0 s sleep was logged as 2.89 s, 0.8 s of it idle).
                let stacks = ThreadStackSampler.sample(thread: thread, every: interval, limit: limit) { latest in
                    guard let self else { return true }
                    let idle = self.state.sync { self.isIdle(latest) }
                    if idle {
                        let at = Self.now(), cpu = self.state.sync { self.threadCPU() }
                        self.state.sync { if self.sampledStallEnded == nil { self.sampledStallEnded = (at, cpu) } }
                        return true
                    }
                    return self.state.sync { self.sampledStallEnded != nil }
                }
                let text = ThreadStackSampler.render(stacks, interval: interval)
                self?.state.async { self?.part(stacks: text) }
            }
        } else {
            part(stacks: "No in-process stacks: the watched thread is unknown.\n")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // No `-mayDie`: it reads every image's symbols BEFORE sampling starts, which on the Release
        // app took longer than the rest of a 1.5 s stall — the stack showed an idle main thread.
        process.arguments = [String(getpid()), String(configuration.sampleSeconds), "-file", Self.sampleFile(file).path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            // Only for its own stall: a `sample` stopped at the timeout can exit after the next
            // stall began, and must not close that one's file.
            self?.state.async { if self?.sampling?.file == file { self?.part(sampleStatus: status) } }
        }
        do {
            try process.run()
            sampling?.process = process
            state.asyncAfter(deadline: .now() + limit + configuration.sampleGrace) { [weak self] in
                guard let self, let open = self.sampling, open.file == file, open.sampleStatus == nil else { return }
                open.process?.terminate()
                self.part(sampleStatus: -2)
            }
        } catch {
            part(sampleStatus: -1)
        }
    }

    /// Where `sample` writes, before its report is put under the in-process stacks.
    private static func sampleFile(_ file: URL) -> URL { file.appendingPathExtension("sample") }

    /// Takes one half of the stall's file, and finishes once both are in. The in-process stacks
    /// are written the moment they exist: `sample` records and symbolicates for 10–17 s after a
    /// stall, and someone who force-quits a frozen app in that time should still leave a stack.
    private func part(stacks: String? = nil, sampleStatus: Int32? = nil) {
        guard sampling != nil else { return }
        if let stacks {
            sampling?.stacks = stacks
            if sampling?.sampleStatus == nil, let file = sampling?.file {
                try? (stacks + "\n---- /usr/bin/sample still running ----\n")
                    .write(to: file, atomically: true, encoding: .utf8)
            }
        }
        if let sampleStatus { sampling?.sampleStatus = sampleStatus }
        guard let done = sampling, let text = done.stacks, let status = done.sampleStatus else { return }
        let fm = FileManager.default
        let sampled = Self.sampleFile(done.file)
        var body = text
        if let report = try? String(contentsOf: sampled, encoding: .utf8), !report.isEmpty {
            body += "\n---- /usr/bin/sample, every thread, started about half a second after the stall was noticed ----\n\n" + report
        } else if status == -2 {
            body += "\n---- /usr/bin/sample did not finish in time and was stopped ----\n"
        } else {
            body += "\n---- /usr/bin/sample wrote nothing (exit \(status)) ----\n"
        }
        try? fm.removeItem(at: sampled)
        try? body.write(to: done.file, atomically: true, encoding: .utf8)
        finishSample(status: status)
    }

    private func finishSample(status: Int32) {
        guard let sampling else { return }
        self.sampling = nil
        let now = Self.now()
        let wrote = FileManager.default.fileExists(atPath: sampling.file.path)
        var line = String(format: "[stall] main thread went %.1f s without a turn", configuration.stallAfter)
        if let ended = sampledStallEnded {
            line += String(format: " — it lasted %.2f s", ended.at - sampling.stallBegan)
        } else {
            line += String(format: " — still stalled %.2f s in", now - sampling.stallBegan)
            unfinishedStall = (sampling.stallBegan, sampling.cpuBegan)
        }
        if let began = sampling.cpuBegan, let cpu = sampledStallEnded.map({ $0.cpu }) ?? threadCPU() {
            let wall = (sampledStallEnded?.at ?? now) - sampling.stallBegan
            line += String(format: ", main thread CPU %.2f s of %.2f s", cpu - began, wall)
        }
        if heldWhileIdle > 0 {
            line += "; \(heldWhileIdle) earlier heartbeat(s) this launch were held by the system over an idle app, not sampled"
        }
        line += "; before it: \(lastContext)"
        line += wrote ? ". Stack: \(sampling.file.path)" : ". No stack file could be written (sample exit \(status))"
        report(line)
        prune()
    }

    /// Keeps the newest `keep` stack files, newest by modification date — the names are local
    /// time with no offset, so a clock or zone change would misorder them. Also clears `.sample`
    /// files a quit left behind before they were merged.
    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: configuration.directory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let named = files.filter { $0.lastPathComponent.hasPrefix("stall-") }
        let stacks = named.filter { $0.pathExtension == "txt" }.sorted { modified($0) > modified($1) }
        for old in stacks.dropFirst(configuration.keep) { try? fm.removeItem(at: old) }
        // Runs once a stall is finished, so no `.sample` here belongs to one in progress.
        for orphan in named where orphan.pathExtension == "sample" { try? fm.removeItem(at: orphan) }
    }

    /// Stalls the main thread once, three seconds after launch, when the app is launched with
    /// `-SyncCloudStallOnce <seconds>` (up to 10) — the way to see a real stall produce its line
    /// and stack. An argument, never a default: it applies to the one launch that names it and
    /// cannot persist. Once per process, however often App.init runs.
    public static func stallOnceIfAsked() { _ = stallOnce }

    private static let stallOnce: Void = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-SyncCloudStallOnce"), flag + 1 < arguments.count,
              let seconds = TimeInterval(arguments[flag + 1]), seconds > 0, seconds <= 10
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Logger.shared.info(String(format: "[stall] stalling the main thread %.1f s, as -SyncCloudStallOnce asked", seconds))
            Thread.sleep(forTimeInterval: seconds)
        }
    }()
}
