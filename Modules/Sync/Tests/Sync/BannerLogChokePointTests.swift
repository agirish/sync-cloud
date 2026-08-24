import Foundation
import Testing
@testable import Sync
@testable import Events

/// The `banner` didSet is the one place every user-visible refusal and completion toast passes
/// through, and it now logs each one. These tests pin that choke point — a dozen guards across the
/// manager refuse operations with nothing but a banner, so this single seam is what keeps "I
/// clicked sync and nothing happened" diagnosable from the log.
///
/// **Read off DISK, not off `Logger.shared.entries`.** The first cut of this suite asserted over
/// the in-memory array and went red on CI at `b96299f5` reporting `[.warning, .error]` where it
/// wanted `[.info, .warning, .error]` — `removed [Events.LogLevel.info]`, i.e. the entry this test
/// had itself published moments earlier. `entries` is trimmed to the newest 1000 and every suite
/// in the process writes to it, so a full parallel package run evicts the front of a window while
/// the test that opened it is still running. That is `logLines(tag:during:)`'s whole subject, and
/// this suite is a textbook instance of it: multi-step, cumulative, and asserting on entries it
/// published several awaits ago. The per-process log FILE keeps every line in call order.
@Suite struct BannerLogChokePointTests {

    /// The levels of the `[banner] <marker>` lines written inside `body`, in call order.
    ///
    /// Prefix, not equality, on the message: `warning`/`error` append a `| Location: …` suffix
    /// that `info` does not, and an exact match silently misses exactly those two severities.
    /// The marker is a per-test UUID, so the filter cannot pick up a sibling suite's banners —
    /// the disk log is per-process and carries every suite's lines.
    @MainActor
    private func bannerLevels(marker: String, during body: () -> Void) async throws -> [String] {
        let tag = UUID().uuidString
        let lines = try await logLines(tag: tag) { body() }
        return lines
            .filter { $0.contains("[banner] \(marker)") }
            .compactMap { line in
                // "[timestamp] [LEVEL] [banner] <marker>" — take the second bracketed field.
                guard let levelStart = line.range(of: "] [")?.upperBound,
                      let levelEnd = line.range(of: "]", range: levelStart..<line.endIndex)?.lowerBound
                else { return nil }
                return String(line[levelStart..<levelEnd])
            }
    }

    @MainActor
    @Test func everySeverityLogsAtItsOwnLevel() async throws {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"

        let levels = try await bannerLevels(marker: marker) {
            manager.banner = .success(marker)
            manager.banner = .warning(marker)
            manager.banner = .error(marker)
        }

        #expect(levels == ["INFO", "WARN", "ERROR"],
                "each banner must reach the log at the severity it wears, in the order shown")
    }

    @MainActor
    @Test func dismissalLogsNothing() async throws {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"

        let levels = try await bannerLevels(marker: marker) {
            manager.banner = .warning(marker)
            manager.banner = nil
        }

        #expect(levels == ["WARN"], "clearing the banner is not an event — only showing one is")
    }

    /// Re-assigning the very same banner (same id) must not double-log: SwiftUI bindings can
    /// write a value back, and one shown banner is one event.
    @MainActor
    @Test func reassigningTheSameBannerLogsOnce() async throws {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"
        let banner = OperationBanner.warning(marker)

        let levels = try await bannerLevels(marker: marker) {
            manager.banner = banner
            manager.banner = banner
        }

        #expect(levels == ["WARN"])
    }

    /// Two back-to-back banners with the SAME message are two events — per-publish identity is
    /// deliberately part of `OperationBanner`'s equality, and the log must agree with the UI.
    @MainActor
    @Test func aRepeatedMessageWithANewIdentityLogsAgain() async throws {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"

        let levels = try await bannerLevels(marker: marker) {
            manager.banner = .warning(marker)
            manager.banner = .warning(marker)
        }

        #expect(levels == ["WARN", "WARN"])
    }
}
