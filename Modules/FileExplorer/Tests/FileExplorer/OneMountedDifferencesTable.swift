import Testing

/// Admits one mounted `DifferencesView` at a time across the suites that build them.
///
/// This is NOT a correctness gate. Its predecessor (`ExclusiveGroupingPreference`) serialized
/// the same suites because they all drove `differencesGroupByFolder` in `UserDefaults.standard`
/// — shared state that is gone now that every mount seeds its own `ScratchDefaults` suite. What
/// remains is a bandwidth problem: a `DifferencesView` mount is the most expensive main-actor
/// job in this target, and with three such suites interleaving freely at their await points,
/// other tests' runloop-hop deadlines start missing. Measured on 2026-07-28 under six CPU
/// loaders: `PaneColumnsScrollTests.testLeakedHorizontalDriftIsRevertedDuringAVerticalGesture`
/// — whose enforcement hop then had to land inside the axis lock's 100ms recency window — went
/// from 0-in-10 full-suite failures with these suites serialized to 5-in-10 with them
/// concurrent, in the same interleaved batch. That particular test has since been freed of the
/// deadline (its gesture is future-dated now, b33c49c), but the measurement stands for what
/// unbounded concurrent mounts do to anything on the main actor with a clock: this trait just
/// declines to make those odds worse.
///
/// Applied as a trait so a fourth mounting suite only has to add it to its declaration.
struct OneMountedDifferencesTable: SuiteTrait, TestTrait, TestScoping {

    /// A cooperative gate. Waiting yields rather than blocks: these tests are async and several
    /// of them are `@MainActor`, so a blocking wait would deadlock the actor the held test needs
    /// to make progress on.
    private actor Gate {
        static let shared = Gate()
        private var isHeld = false

        func acquire() async {
            // The check and the set are not separated by a suspension point, so two waiters
            // released together cannot both come through.
            while isHeld { try? await Task.sleep(nanoseconds: 5_000_000) }
            isHeld = true
        }

        func release() { isHeld = false }
    }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        await Gate.shared.acquire()
        do {
            try await function()
        } catch {
            // Released on the failure path too — a throwing test must not strand every suite
            // behind it, which would turn one failure into a whole-run timeout.
            await Gate.shared.release()
            throw error
        }
        await Gate.shared.release()
    }
}

extension Trait where Self == OneMountedDifferencesTable {
    /// Grants the suite the sole right to have a `DifferencesView` mounted during each test.
    static var oneMountedDifferencesTable: Self { Self() }
}
