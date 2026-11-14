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
            manager.banner = .warning(marker, log: .warn)
            manager.banner = .error(marker, log: .error)
        }

        #expect(levels == ["INFO", "WARN", "ERROR"],
                "each banner must reach the log at the severity it wears, in the order shown")
    }

    /// One case: the banners shown in order, built from the test's marker, and the levels the log
    /// must hold for them.
    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let banners: @Sendable (String) -> [OperationBanner?]
        let levels: [String]
    }

    static let cases: [Case] = [
        // The copy's level is the banner's `log`, not its look: severity sets how it looks only.
        Case(testDescription: "the copy is written at the level the banner states, not its look",
             banners: { [.warning($0, log: .info), .success($0, log: .error)] },
             levels: ["INFO", "ERROR"]),
        // A site that already logged the fault keeps its copy, at INFO; an unmirrored one writes none.
        Case(testDescription: "a site-logged banner is copied at INFO, an unmirrored one not at all",
             banners: { [.warning($0, log: .loggedAtSite), .warning($0, log: .notMirrored), .error($0, log: .loggedAtSite)] },
             levels: ["INFO", "INFO"]),
        // Clearing the banner is not an event; only showing one is.
        Case(testDescription: "dismissal logs nothing",
             banners: { [.warning($0, log: .warn), nil] },
             levels: ["WARN"]),
        // SwiftUI bindings can write the same value back: one shown banner (same id) is one event.
        Case(testDescription: "reassigning the same banner logs once",
             banners: { let banner = OperationBanner.warning($0, log: .warn); return [banner, banner] },
             levels: ["WARN"]),
        // Per-publish identity is part of `OperationBanner`'s equality, and the log agrees with the UI.
        Case(testDescription: "a repeated message with a new identity logs again",
             banners: { [.warning($0, log: .warn), .warning($0, log: .warn)] },
             levels: ["WARN", "WARN"]),
    ]

    @MainActor
    @Test(arguments: cases)
    func theLogHoldsOneLineAtTheStatedLevelPerShownBanner(_ c: Case) async throws {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"
        let levels = try await bannerLevels(marker: marker) {
            for banner in c.banners(marker) { manager.banner = banner }
        }
        #expect(levels == c.levels, "\(levels)")
    }
}
