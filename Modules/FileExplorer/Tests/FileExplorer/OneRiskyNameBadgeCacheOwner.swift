import Testing

/// Admits one test at a time to `RiskyNameBadgeCache`, across every suite that touches it.
///
/// Unlike `OneMountedDifferencesTable` — a bandwidth gate — this one IS a correctness gate, and it
/// guards exactly one thing: `resetForTesting()` is a whole-process reset of a `@MainActor` static
/// table. A case in another suite calling it mid-run empties the memo underneath whoever is
/// measuring, and every name still on screen is then evaluated a second time — which is precisely
/// what `RiskyNameBadgeMemoTests` reports as a regression. `.serialized` does not help: it orders
/// the cases *within* one suite and says nothing about two suites running at once.
///
/// And these suites really can interleave despite all being `@MainActor`: the mounted cases drive
/// the runloop (`CFRunLoopRunInMode`), which drains main-actor jobs — so another test's
/// continuation resumes inside the measurement window rather than after it.
///
/// What this trait deliberately does NOT try to do is keep other suites from *using* the memo.
/// `DifferencesView` asks it directly, so any suite that mounts a differences table adds
/// evaluations, and gating them all would leave the next such suite to reintroduce the problem in
/// silence. That is handled where it belongs — `RiskyNameBadgeCache.onEvaluateForTesting` reports
/// the name, and the tests count only their own fixture's.
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
            // Released on the failure path too — a throwing case must not strand every other suite
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
