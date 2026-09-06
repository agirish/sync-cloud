import Foundation
import Testing
@testable import Sync

/// The contract of the thread-blocking parks, and of the budget that stops them taking the whole
/// cooperative pool at once — see `docs/flaky-tests.md`, "Every gate parks at once, on the pool
/// their releases need".
///
/// **Why the primitive needs tests of its own.** A gate that never engages and a gate that engages
/// and is released look identical from the outside — that is the whole reason `releasedByTimeout`
/// exists, and it is also the shape a bad "fix" for this flake would take: quietly stop the gates
/// engaging and watch every suite go green. The three tests under *The park's two halves* pin both
/// directions and the detector that tells them apart.
@Suite struct ParkBudgetTests {

    /// Polls off the main actor. `waitUntil` is `@MainActor` and these tests are not: what they
    /// wait for is a plain thread finishing its bookkeeping, not a main-actor turn.
    private func waitForCondition(_ what: Comment, timeout: TimeInterval = 5,
                                  sourceLocation: SourceLocation = #_sourceLocation,
                                  _ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(condition(), what, sourceLocation: sourceLocation)
    }

    // MARK: - The park's two halves

    /// The park engages, is released, and records no timeout.
    ///
    /// Driven from `DispatchQueue.global()` — a NON-cooperative queue, which overcommits when its
    /// threads block — rather than from a `Task`, so this test does not itself take a thread out of
    /// the pool it exists to protect. That is also why it needs no `.parksAThread`.
    @Test func aParkThatIsReleasedRecordsNoTimeout() async {
        let gate = ParkGate()
        DispatchQueue.global().async { gate.park(timeout: 5) }
        await awaitSignal(gate.entered, timeout: 5, "the park never engaged")
        #expect(gate.didPark, "a park that engaged must say so")
        gate.release.signal()
        await waitForCondition("the parked call returns") { !gate.isParked }
        #expect(!gate.releasedByTimeout, "a park that was released must not record a timeout")
    }

    /// The bound expires, and THAT is recorded too — the half that is easiest to leave
    /// load-bearing in name only. Delete the assignment behind `releasedByTimeout` and only this
    /// test notices; every consumer's `try #require(!gate.releasedByTimeout)` still passes.
    @Test func aParkThatIsNeverReleasedRecordsItsTimeout() async {
        let gate = ParkGate()
        DispatchQueue.global().async { gate.park(timeout: 0.2) }
        await awaitSignal(gate.entered, timeout: 5, "the park never engaged")
        // Deliberately never signalled.
        await waitForCondition("the parked call gives up") { !gate.isParked }
        #expect(gate.releasedByTimeout, "a park that reached its bound must record the expiry")
        #expect(gate.didPark)
    }

    /// A gate that never parks never signals `entered`. That is what makes a silently-disengaged
    /// gate detectable at all: `releasedByTimeout` is false in that case too, so a consumer's
    /// `await awaitSignal(gate.entered)` is the assertion that fails, not the `#require` after it.
    @Test func aGateThatNeverParksNeverSignalsEntered() {
        let gate = ParkGate()
        #expect(gate.entered.wait(timeout: .now()) == .timedOut,
                "an unparked gate signalled `entered`, so nothing tells it from a held one")
        #expect(!gate.didPark)
        #expect(!gate.releasedByTimeout)
    }

    // MARK: - The budget

    @Test func theBudgetAdmitsNoMoreThanItsWidthAtOnce() async {
        let budget = ParkThreadBudget()
        for _ in 0..<parkThreadBudget { await budget.reserve(1) }
        #expect(await budget.inFlight == parkThreadBudget)

        // One more does not fit; it suspends until something is handed back.
        let extra = Task { await budget.reserve(1) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await budget.inFlight == parkThreadBudget, "the budget admitted more than its width")

        await budget.relinquish(1)
        await extra.value
        #expect(await budget.inFlight == parkThreadBudget)
        #expect(await budget.highWaterMark == parkThreadBudget)
    }

    /// A reservation wider than the whole budget is admitted alone rather than deadlocking. Two
    /// real tests need this on a ten-core machine, where the budget is 2: the six-wide hash window
    /// in `FileSyncManagerDuplicatesTests` and the four-worker rendezvous in
    /// `BulkSyncCancellationAndReservationTests`.
    @Test func aReservationWiderThanTheBudgetIsAdmittedAlone() async {
        let budget = ParkThreadBudget()
        await budget.reserve(parkThreadBudget + 4)
        #expect(await budget.inFlight == parkThreadBudget + 4)
        await budget.relinquish(parkThreadBudget + 4)
        #expect(await budget.inFlight == 0)
    }

    /// FIFO, so a wide reservation is not starved by narrow ones queueing behind it. Without the
    /// ticket, `held == 0` never comes around under a steady stream of one-thread tests, and the
    /// widest test — the one holding the most pool threads — is the one that reaches its bound.
    @Test func aWideReservationIsNotOvertakenByNarrowOnesBehindIt() async {
        let budget = ParkThreadBudget()
        await budget.reserve(1)                              // something is already in flight
        let order = LockedBox<[String]>([])

        let wide = Task { await budget.reserve(99); order.withLock { $0.append("wide") } }
        try? await Task.sleep(nanoseconds: 50_000_000)       // let `wide` take the earlier ticket
        let narrow = Task { await budget.reserve(1); order.withLock { $0.append("narrow") } }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(order.withLock { $0 }.isEmpty, "neither may enter while the first reservation is held")

        // Bounded waits, not `await wide.value` — a queue that has stopped being FIFO leaves the
        // wide reservation waiting for a `held` that never comes, and joining it turns a failing
        // test into a package run that never finishes. That is not hypothetical: it is what
        // dropping the FIFO clause actually did before this was written this way.
        await budget.relinquish(1)
        await waitForCondition("the wide reservation is admitted first") {
            order.withLock { $0 }.first == "wide"
        }
        #expect(order.withLock { $0 } == ["wide"], "the narrow reservation overtook the wide one")
        await budget.relinquish(99)
        await waitForCondition("and the narrow one follows it in") { order.withLock { $0 }.count == 2 }
        #expect(order.withLock { $0 } == ["wide", "narrow"])
        _ = (wide, narrow)
    }

    /// **The bound is bounded, and it says so.** Both halves in one test: a reservation that can
    /// never be served gives up rather than hanging the package run, and records why — a limiter
    /// that has quietly stopped limiting must not read like one that is working.
    /// **The bound is bounded, and it says so.** Both halves in one test: a reservation that can
    /// never be served goes ahead rather than hanging the package run, and reports why.
    ///
    /// The time limit is this test's own bound — it is the one test here whose failure mode, if the
    /// give-up check is ever removed, is a run that never finishes rather than a red one.
    @Test(.timeLimit(.minutes(1))) func aReservationThatCanNeverBeServedGivesUpAndSaysSo() async {
        let said = LockedBox<[String]>([])
        let budget = ParkThreadBudget(giveUpAfter: .milliseconds(200),
                                      report: { m in said.withLock { $0.append(m) } })
        await budget.reserve(parkThreadBudget)      // fills it, and nothing gives it back
        await budget.reserve(parkThreadBudget)
        #expect(await budget.inFlight == parkThreadBudget * 2,
                "having given up, the reservation must go ahead rather than hang")
        let reported = said.withLock { $0 }
        #expect(reported.count == 1, "the give-up must be reported exactly once")
        #expect(reported.first?.contains("ungoverned") == true,
                "the report must say what happened, not merely that something did: \(reported)")
    }

    /// The seam above is a test affordance, and this is the half it cannot prove by exercising it:
    /// that a give-up in a REAL run is a test failure rather than a silent one. Read off the source
    /// rather than triggered, because triggering it would leave a known issue on the summary line of
    /// every package run — which is exactly the cost the seam exists to avoid.
    @Test func theGiveUpDefaultsToARealTestFailure() throws {
        let source = try Self.testSources.first { $0.name == "TestSupport.swift" }?.text
        let text = try #require(source)
        let ctor = try #require(text.range(of: "init(giveUpAfter: Duration"),
                                "`ParkThreadBudget`'s initialiser was renamed — this scan measures nothing")
        let decl = String(text[ctor.lowerBound...].prefix(240))
        #expect(decl.contains("Issue.record"), """
            the default give-up reporter no longer records a test failure, so a wedged budget would \
            go unreported: \(decl)
            """)
    }

    // MARK: - Adoption: the two ways this fix rots

    /// Directory of this target's sources.
    private static var testSources: [(name: String, text: String)] {
        get throws {
            let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".swift") }.sorted()
            return try names.map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
        }
    }

    /// Every stand-in in this target that holds a seam call by BLOCKING the calling thread. A test
    /// that builds one must declare it, because production reaches those seams from
    /// `Task.detached` and the thread it blocks is a cooperative-pool thread.
    ///
    /// **Two were missing until 2026-09-06, and both had unbudgeted tests.** `GateFileManager`
    /// (`RestructureApplyGuardTests`) is one letter from `GatedFileManager` and read as already
    /// listed; `SamplerObservedTrash` (`MergeUndoGroupingAndGateTests`) is not gate-shaped by
    /// name at all — it is a `FileManager` subclass whose trash holds a rendezvous. A name is a
    /// weak key, which is why the second scan below is derived from the source instead.
    private static let threadBlockingGates = [
        "ParkGate", "FirstStatGate", "FirstOpGate", "FirstAttributesGate",
        "GatedFileManager", "GateFileManager", "DestinationStatGate", "BarrierCancelGate",
        "SlowWalkFileManager", "GatingFileManager", "SamplerObservedTrash",
    ]

    /// **Rot #1: a new gated test that forgets the trait.** It would pass on its own and go on
    /// costing the whole package run a pool thread at the moment every suite starts.
    @Test func everyTestThatBuildsAThreadBlockingGateDeclaresIt() throws {
        var undeclared: [String] = []
        var checked = 0
        for (name, text) in try Self.testSources where name != "ParkBudgetTests.swift" {
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Locals only. A stored property (`private let gate = ParkGate()`) belongs to a
                // gate's own implementation, not to a test that uses one.
                guard trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") else { continue }
                guard Self.threadBlockingGates.contains(where: { trimmed.contains("= \($0)(") }) else { continue }
                // The nearest `@Test` above it is the test that owns the construction.
                guard let attr = lines[..<i].lastIndex(where: { $0.contains("@Test") }) else { continue }
                checked += 1
                if !lines[attr].contains("parksAThread") && !lines[attr].contains("parksThreads") {
                    undeclared.append("\(name):\(attr + 1) \(lines[attr].trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        // Non-vacuity: this scan finds nothing if the gates are ever renamed wholesale, and a scan
        // that matches nothing passes exactly like one that matches everything.
        #expect(checked >= 20, "the gate scan found only \(checked) constructions — it has stopped matching")
        #expect(undeclared.isEmpty, """
            these tests build a gate that blocks a cooperative-pool thread but do not declare it \
            with `.parksAThread` / `.parksThreads(n)`:
            \(undeclared.joined(separator: "\n"))
            """)
    }

    /// **Rot #2: a new park primitive nobody registered.** `threadBlockingGates` above is a list,
    /// and a list is only ever as complete as its last edit — so this half is derived from the
    /// source instead: every thread-blocking wait in the target must be one of these known lines.
    /// A new `DispatchSemaphore.wait` or a new blocking sleep is the moment to decide whether the
    /// test around it owes a reservation.
    @Test func everyThreadBlockingWaitInThisTargetIsAccountedFor() throws {
        // file → the distinct blocking-wait lines it is allowed to contain, and why each is fine.
        let known: [String: Set<String>] = [
            // Off the cooperative pool by construction: `DispatchQueue.global()` overcommits.
            "TestSupport.swift": [
                "cont.resume(returning: semaphore.wait(timeout: .now() + timeout))",
                "let expired = release.wait(timeout: .now() + timeout) == .timedOut",   // ParkGate.park
                "if release.wait(timeout: .now() + 10) == .timedOut {",                 // FirstStatGate
            ],
            "DeepFolderIdentityTests.swift": [
                "if release.wait(timeout: .now() + 10) == .timedOut {",   // FirstAttributesGate
                "Thread.sleep(forTimeInterval: 0.005)",                   // brief: a scheduling nudge
            ],
            "ProgressAccountingTests.swift": ["if gate.wait(timeout: .now() + 10) == .timedOut {"],
            // GateFileManager parks the landing's executor thread, which IS a cooperative-pool
            // one — `enqueueFileOperation` runs its operation in `Task.detached`. Both of its
            // tests declare `.parksAThread`; the test-side wait is `awaitSignal`, registered
            // under TestSupport.swift above.
            "RestructureApplyGuardTests.swift": [
                "if fire { entered.signal(); release.wait() }",
            ],
            "MergeUndoPromiseTests.swift": ["if release.wait(timeout: .now() + 10) == .timedOut {"],
            "BulkSyncCancellationAndReservationTests.swift": [
                "if barrier.wait(timeout: .now() + 30) == .timedOut { recordTimeout() }",
                "Thread.sleep(forTimeInterval: 0.005)",
            ],
            "FileSyncManagerDuplicatesTests.swift": ["if mustWait { semaphore.wait() }"],
            "ScanSupersedenceTests.swift": [
                "Thread.sleep(forTimeInterval: delay)",
                "mockFM.enumeratorDelay = 0.15", "mockFM.enumeratorDelay = 0.05",
            ],
            // `MockFileManager`'s per-entry sleep blocks the walk's thread too, but its LENGTH
            // lives at the call sites, so those are registered as well: a sixth one, or a longer
            // one, is a new thread-hog that no reader of `MockFileManager.swift` would see.
            // The five below run 50-150 ms per entry and always finish on their own, which is why
            // they hold no reservation — a gate, by contrast, is held until its test lets go.
            "MockFileManager.swift": ["Thread.sleep(forTimeInterval: enumeratorDelay)"],
            "BulkOperationsTests.swift": ["mockFM.enumeratorDelay = 0.05"],
            "ProgressiveLoadTests.swift": ["mockFM.enumeratorDelay = 0.05", "mockFM.enumeratorDelay = 0.1"],
            "MergeCancelMidCopyTests.swift": ["Thread.sleep(forTimeInterval: 0.005)"],
            // `SamplerObservedTrash`'s rendezvous: the trash blocks its pool thread until the
            // main-actor observation it enqueued signals back. Bounded, records its expiry, and
            // its test declares `.parksAThread`.
            "MergeUndoGroupingAndGateTests.swift": ["if sampled.wait(timeout: .now() + 10) == .timedOut {"],
        ]
        var found: [String: Set<String>] = [:]
        for (name, text) in try Self.testSources where name != "ParkBudgetTests.swift" {
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//") && !line.hasPrefix("///") else { continue }
                let blocks = line.contains("Thread.sleep(forTimeInterval:")
                    || line.contains("enumeratorDelay = ")
                    || (line.contains(".wait(") && !line.contains("await ") && !line.contains("waitUntil"))
                if blocks { found[name, default: []].insert(line) }
            }
        }
        for (file, lines) in found.sorted(by: { $0.key < $1.key }) {
            let allowed = known[file] ?? []
            #expect(lines.subtracting(allowed).isEmpty, """
                \(file) has a thread-blocking wait this scan does not know about:
                \(lines.subtracting(allowed).sorted().joined(separator: "\n"))
                A park that blocks a cooperative-pool thread needs its test to declare \
                `.parksAThread`; register the line here once you have decided which it is.
                """)
        }
        for (file, lines) in known where !lines.subtracting(found[file] ?? []).isEmpty {
            // A registered line that no longer exists means this scan is guarding less than it
            // claims — the same silent shrink `#expect(checked >= 20)` guards against above.
            Issue.record("""
                \(file) no longer contains \(lines.subtracting(found[file] ?? []).sorted()); \
                drop it from this scan's registry.
                """)
        }
    }
}
