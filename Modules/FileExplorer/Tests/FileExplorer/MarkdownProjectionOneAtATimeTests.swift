import Testing
import Foundation
@testable import FileExplorer

/// **A projection waits while another is building, at every door** — a whole build, a part
/// re-read, and the re-read that splices it in (``MarkdownProjection/oneAtATime(_:)``).
///
/// This holds the rule, not the abort it answers: a FileExplorer test process died on CI with four
/// projections building at once and an attribute dictionary they share freed under one of them,
/// and no rig made that happen again — see "Four projections at once, and a shared attribute
/// dictionary freed under one of them" in docs/flaky-tests.md. Each case holds the lock itself, as
/// a build on another thread would, and a projection asked for meanwhile must not finish until
/// it lets go — then must.
///
/// Mutation: drop `oneAtATime` from one door, and that case finishes inside the hold.
@Suite struct MarkdownProjectionOneAtATimeTests {

    enum Door: CaseIterable, CustomTestStringConvertible {
        case build, slice, reread
        var testDescription: String { "\(self)" }
    }

    @Test(arguments: Door.allCases)
    func aProjectionWaitsWhileAnotherIsBuilding(_ door: Door) {
        let source = "# A heading\n\n<div>\nhtml\n</div>\n\n    indented\n\n- an item\n"
        // Made before the hold, and read by the one thread the closure runs on.
        nonisolated(unsafe) let previous = MarkdownProjection.project(source)
        let finished = DispatchSemaphore(value: 0)

        // Held and let go on this thread, as `NSRecursiveLock` requires: the test is synchronous.
        MarkdownProjection.building.lock()
        Thread.detachNewThread {
            switch door {
            case .build:
                _ = MarkdownProjection.project(source)
            case .slice:
                _ = MarkdownProjection.projectSlice(NSRange(location: 0, length: (source as NSString).length),
                                                    of: source, index: MarkdownSourceIndex(source),
                                                    style: MarkdownProjection.Style(), topLevel: 0,
                                                    previousBlockSourceEnd: 0)
            case .reread:
                // The unchanged source: the one path through the splice that projects nothing
                // itself, so only the re-read's own hold can keep it waiting.
                _ = previous.reread(source)
            }
            finished.signal()
        }
        // Long enough for an unheld door to finish many times over on a loaded machine: a
        // projection of this note takes about a millisecond.
        let overlapped = finished.wait(timeout: .now() + 1) == .success
        MarkdownProjection.building.unlock()

        #expect(!overlapped, "\(door) finished while another projection held the lock")
        if !overlapped {
            #expect(finished.wait(timeout: .now() + 30) == .success, "\(door) never finished after the lock was let go")
        }
    }
}
