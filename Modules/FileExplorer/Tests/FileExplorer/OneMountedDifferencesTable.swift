import Testing

/// Admits one mounted `DifferencesView` at a time across the suites that build them.
///
/// Not a correctness gate (every mount seeds its own `ScratchDefaults`): it limits load. A
/// `DifferencesView` mount is the most expensive main-actor job in this target, and several
/// interleaving at their await points make other tests' run-loop-hop deadlines miss under load.
///
/// Applied as a trait so a new mounting suite only has to add it to its declaration.
struct OneMountedDifferencesTable: SuiteTrait, TestTrait, TestScoping {

    private static let gate = Gate()

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await Self.gate.holding(function)
    }

    /// A cooperative gate, one instance per trait. Waiting yields rather than blocks: these tests
    /// are async and several of them are `@MainActor`, so a blocking wait would deadlock the actor
    /// the held test needs to make progress on. `OneRiskyNameBadgeCacheOwner` has its own.
    actor Gate {
        private var isHeld = false

        func holding(_ body: @Sendable () async throws -> Void) async throws {
            // The check and the set are not separated by a suspension point, so two waiters
            // released together cannot both come through.
            while isHeld { try? await Task.sleep(nanoseconds: 5_000_000) }
            isHeld = true
            // Released on the failure path too: a throwing test must not strand every suite
            // behind it, which would turn one failure into a whole-run timeout.
            defer { isHeld = false }
            try await body()
        }
    }
}

extension Trait where Self == OneMountedDifferencesTable {
    /// Grants the suite the sole right to have a `DifferencesView` mounted during each test.
    static var oneMountedDifferencesTable: Self { Self() }
}
