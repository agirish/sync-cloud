import Foundation
import Testing
@testable import Sync
@testable import Events

/// The `banner` didSet logs every user-visible refusal and completion toast. Many guards refuse
/// with nothing but a banner, so this one seam keeps "I clicked sync and nothing happened"
/// diagnosable from the log.
///
/// Reads the log file, not `Logger.shared.entries`: that array keeps only the newest 1000 and
/// every suite writes to it, so a parallel run can evict this test's early entries before it
/// asserts (`logLines(tag:during:)`). The per-process file keeps every line in order.
@Suite struct BannerLogChokePointTests {

    /// The levels of the `[banner] <marker>` lines written inside `body`, in call order. Matches by
    /// prefix: `warning` and `error` append a `| Location: …` suffix that an exact match would
    /// miss. The marker is a per-test UUID, so sibling suites' banners in the shared log don't count.
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

    /// Two banners with the same message are two events: per-publish identity is part of
    /// `OperationBanner`'s equality, and the log must agree with the UI.
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
