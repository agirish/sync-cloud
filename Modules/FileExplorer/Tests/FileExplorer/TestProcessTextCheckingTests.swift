import AppKit
import Testing
import TestProcessTextChecking

/// **The spell checker in this test process finds nothing and takes no lock**, because the target
/// links `TestProcessTextChecking`, whose constructor replaces both of its checking methods before
/// any test runs. Fails if the target stops linking it — and then every SwiftUI field a test types
/// into checks through the real one, which can deadlock a focus move: `docs/flaky-tests.md` ▸
/// *A spell check and a defaults change from another process deadlock a SwiftUI focus move*.
@Suite struct TestProcessTextCheckingTests {
    private let misspelt = "Thsi sentance is mispelt."

    @Test @MainActor func aSynchronousCheckFindsNothing() {
        #expect(TestProcessTextCheckingIsQuiet())
        let results = NSSpellChecker.shared.check(
            misspelt, range: NSRange(location: 0, length: (misspelt as NSString).length),
            types: NSTextCheckingAllTypes, options: nil, inSpellDocumentWithTag: 0,
            orthography: nil, wordCount: nil)
        #expect(results.isEmpty)
    }

    /// The handler is `@Sendable` because AppKit calls it on a background queue, as the replacement
    /// does: inferred main-actor, it would trap there.
    @Test @MainActor func aRequestedCheckAnswersWithNothing() async {
        let checker = NSSpellChecker.shared
        let text = misspelt
        let found: Int = await withCheckedContinuation { done in
            _ = checker.requestChecking(
                of: text, range: NSRange(location: 0, length: (text as NSString).length),
                types: NSTextCheckingAllTypes, options: nil, inSpellDocumentWithTag: 0
            ) { @Sendable _, results, _, _ in done.resume(returning: results.count) }
        }
        #expect(found == 0)
    }
}
