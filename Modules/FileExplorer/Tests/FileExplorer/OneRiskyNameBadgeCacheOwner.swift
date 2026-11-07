import Testing

/// Admits one test at a time to `RiskyNameBadgeCache`, across every suite that touches it.
///
/// Unlike `OneMountedDifferencesTable`, a load gate, this one is a correctness gate for one thing:
/// `resetForTesting()` is a whole-process reset of a `@MainActor` static table. Called from another
/// suite mid-run, it empties the memo under whoever is measuring, every name on screen is evaluated
/// again, and `RiskyNameBadgeMemoTests` reports a regression. `.serialized` only orders the cases
/// within one suite.
///
/// The suites can interleave despite all being `@MainActor`: the mounted cases drive the run loop
/// (`CFRunLoopRunInMode`), which drains main-actor jobs, so another test's continuation resumes
/// inside the measurement window.
///
/// It does not keep other suites from using the memo: any suite that mounts a differences table
/// adds evaluations, and gating them all would silently miss the next new one. Instead
/// `RiskyNameBadgeCache.onEvaluateForTesting` reports the name, and the tests count only their own
/// fixture's.
///
/// Applied as a trait so a new suite that touches the memo only has to add it to its declaration.
/// Every current one does: `RiskyNameBadgePredicateTests`, `DifferencesRiskyNameRulesTests`,
/// `RiskyNameBadgeMemoTests`, and `RiskyNameBadgeCostBenchmark`.
struct OneRiskyNameBadgeCacheOwner: SuiteTrait, TestTrait, TestScoping {

    /// A cooperative gate, for the same reason `OneMountedDifferencesTable`'s is: waiting yields
    /// rather than blocks, so a `@MainActor` waiter cannot deadlock the actor that the holder
    /// needs in order to finish and release.
    private actor Gate {
        static let shared = Gate()
        private var isHeld = false

        func acquire() async {
            // No suspension point between the check and the set, so two waiters woken together
            // cannot both come through.
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
            // Released on the failure path too: a throwing case must not strand every other suite
            // behind it, turning one failure into a whole-run timeout.
            await Gate.shared.release()
            throw error
        }
        await Gate.shared.release()
    }
}

extension Trait where Self == OneRiskyNameBadgeCacheOwner {
    /// Grants the suite sole use of the process-wide risky-name memo for each of its cases.
    static var oneRiskyNameBadgeCacheOwner: Self { Self() }
}
