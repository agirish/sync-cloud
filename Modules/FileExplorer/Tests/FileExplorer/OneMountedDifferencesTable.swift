import Testing

/// Admits one mounted `DifferencesView` at a time across the suites that build them.
///
/// Not a correctness gate: every mount seeds its own `ScratchDefaults` suite, so the suites share
/// no state. It limits load. A `DifferencesView` mount is the most expensive main-actor job in this
/// target, and with several such suites interleaving at their await points, other tests'
/// run-loop-hop deadlines start missing under load. Anything on the main actor with a clock pays
/// for unbounded concurrent mounts; this trait declines to make those odds worse.
///
/// Applied as a trait so a new mounting suite only has to add it to its declaration.
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
            // Released on the failure path too: a throwing test must not strand every suite
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
