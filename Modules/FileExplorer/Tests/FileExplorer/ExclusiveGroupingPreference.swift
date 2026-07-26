import Testing

/// Serializes every suite that mounts `DifferencesView` and drives the process-global
/// "Group by folder" preference.
///
/// `@Suite(.serialized)` orders the cases WITHIN one suite; swift-testing still runs different
/// suites in parallel. `@AppStorage("differencesGroupByFolder")` reads `UserDefaults.standard`,
/// which the whole test process shares, so two such suites in flight each see the other's writes.
///
/// `DifferencesTableIdentityTests` named that hazard in its own header — "two of these in flight
/// would fight over it" — while it was still the only claimant. `FoldAllToggleBindingTests` became
/// the second, and both failed exactly as predicted: the ungrouped mount came up already grouped,
/// and the flat fixture drew 140 rows where it expected 120. Neither test was wrong and neither
/// product behavior had changed; they were reading each other's preference.
///
/// Applied as a trait rather than by wrapping each test body, so a third claimant only has to add
/// it to its suite declaration — and so the reason lives in one place instead of in N comments.
struct ExclusiveGroupingPreference: SuiteTrait, TestTrait, TestScoping {

    /// A cooperative gate. Waiting yields rather than blocks: these tests are async and several of
    /// them are `@MainActor`, so a blocking wait would deadlock the actor the held test needs to
    /// make progress on.
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

extension Trait where Self == ExclusiveGroupingPreference {
    /// Grants the suite exclusive use of `differencesGroupByFolder` for the duration of each test.
    static var exclusiveGroupingPreference: Self { Self() }
}
