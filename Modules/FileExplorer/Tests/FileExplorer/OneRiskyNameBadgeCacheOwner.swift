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
struct OneRiskyNameBadgeCacheOwner: SuiteTrait, TestTrait, TestScoping {

    /// `OneMountedDifferencesTable`'s cooperative gate, a separate instance: the two locks guard
    /// different things.
    private static let gate = OneMountedDifferencesTable.Gate()

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await Self.gate.holding(function)
    }
}

extension Trait where Self == OneRiskyNameBadgeCacheOwner {
    /// Grants the suite sole use of the process-wide risky-name memo for each of its cases.
    static var oneRiskyNameBadgeCacheOwner: Self { Self() }
}
