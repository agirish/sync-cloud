import Foundation
import Testing
@testable import Sync
@testable import Events

/// The `banner` didSet is the one place every user-visible refusal and completion toast passes
/// through, and it now logs each one. These tests pin that choke point — a dozen guards across the
/// manager refuse operations with nothing but a banner, so this single seam is what keeps "I
/// clicked sync and nothing happened" diagnosable from the log.
@Suite struct BannerLogChokePointTests {

    /// Entries whose message starts with `[banner] <marker>`, after a flush marker guarantees
    /// everything enqueued before it is visible (the log methods append via Tasks). Prefix, not
    /// equality: `warning`/`error` append a `| Location: …` suffix that `info` does not, and an
    /// exact match silently missed exactly those two severities.
    @MainActor
    private func bannerEntries(_ marker: String) async -> [LogEntry] {
        await Logger.shared.debug("banner-test flush marker").value
        return Logger.shared.entries.filter { $0.message.hasPrefix("[banner] \(marker)") }
    }

    @MainActor
    @Test func everySeverityLogsAtItsOwnLevel() async {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"

        manager.banner = .success(marker)
        var entries = await bannerEntries(marker)
        #expect(entries.map(\.level) == [.info])

        manager.banner = .warning(marker)
        entries = await bannerEntries(marker)
        #expect(entries.map(\.level) == [.info, .warning])

        manager.banner = .error(marker)
        entries = await bannerEntries(marker)
        #expect(entries.map(\.level) == [.info, .warning, .error])
    }

    @MainActor
    @Test func dismissalLogsNothing() async {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"
        manager.banner = .warning(marker)
        manager.banner = nil
        let entries = await bannerEntries(marker)
        #expect(entries.count == 1, "clearing the banner is not an event — only showing one is")
    }

    /// Re-assigning the very same banner (same id) must not double-log: SwiftUI bindings can
    /// write a value back, and one shown banner is one event.
    @MainActor
    @Test func reassigningTheSameBannerLogsOnce() async {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"
        let banner = OperationBanner.warning(marker)
        manager.banner = banner
        manager.banner = banner
        let entries = await bannerEntries(marker)
        #expect(entries.count == 1)
    }

    /// Two back-to-back banners with the SAME message are two events — per-publish identity is
    /// deliberately part of `OperationBanner`'s equality, and the log must agree with the UI.
    @MainActor
    @Test func aRepeatedMessageWithANewIdentityLogsAgain() async {
        let manager = FileSyncManager()
        let marker = "choke-\(UUID().uuidString)"
        manager.banner = .warning(marker)
        manager.banner = .warning(marker)
        let entries = await bannerEntries(marker)
        #expect(entries.count == 2)
    }
}
