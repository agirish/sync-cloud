import Foundation
import Testing
import TestProcessRendering

/// **Every hosting view in this test process draws on the main thread**, because the target links
/// `TestProcessRendering`, whose constructor turns SwiftUI's async rendering off before any test
/// runs. Fails if the target stops linking it, or if a defaults domain above the registration one
/// turns it back on — and then a display-link render can run inside a table row's teardown and abort
/// the process: `docs/flaky-tests.md` ▸ *A table row's teardown runs SwiftUI's display-link update,
/// which takes a weak reference to the dying row*.
///
/// This holds the wiring, not the abort, which no rig made happen: see that entry.
@Suite struct TestProcessRenderingTests {
    @Test func asyncRenderingIsOff() {
        #expect(TestProcessRenderingIsOnMain())
    }
}
