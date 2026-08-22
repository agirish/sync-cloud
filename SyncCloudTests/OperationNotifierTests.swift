import Testing
import UserNotifications
@testable import SyncCloud
import Settings
import Sync

/// Pins the background-notification path end to end short of UNUserNotificationCenter itself:
/// the gate, the title mapping, the request `postIfEnabled` builds (via the injected `post`
/// seam), and — the finding this suite grew from — that the app actually CALLS it. The gate and
/// title were unit-tested to perfection while `postIfEnabled` and its one call site were pinned
/// by nothing: one deleted line shipped the whole feature dead with every test green.
@MainActor
@Suite struct OperationNotifierTests {

    @Test func testNotifiesOnlyWhenEnabledAndInBackground() {
        #expect(OperationNotifier.shouldNotify(enabled: true, appIsActive: false))
        #expect(!OperationNotifier.shouldNotify(enabled: true, appIsActive: true))
        #expect(!OperationNotifier.shouldNotify(enabled: false, appIsActive: false))
        #expect(!OperationNotifier.shouldNotify(enabled: false, appIsActive: true))
    }

    @Test func testTitlesPerSeverity() {
        #expect(OperationNotifier.title(for: .success) == "Operation complete")
        #expect(OperationNotifier.title(for: .warning) == "Operation finished with warnings")
        #expect(OperationNotifier.title(for: .error) == "Operation failed")
    }

    /// The request really is built from the banner: title per severity, the banner message as the
    /// body, and the banner's own id as the identifier — the per-publish UUID is what stops the
    /// system coalescing two genuinely different outcomes into one notification.
    @Test func postIfEnabledBuildsTheRequestFromTheBanner() {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set(true, forKey: GeneralSettings.notifyOnBackgroundCompletionKey)
        let banner = OperationBanner(message: "Copied 3 items", severity: .warning)

        var posted: [UNNotificationRequest] = []
        OperationNotifier.postIfEnabled(for: banner, defaults: test.defaults,
                                        appIsActive: false, post: { posted.append($0) })

        #expect(posted.count == 1)
        #expect(posted.first?.content.title == "Operation finished with warnings")
        #expect(posted.first?.content.body == "Copied 3 items")
        #expect(posted.first?.identifier == banner.id.uuidString)
        #expect(posted.first?.content.sound != nil)
        #expect(posted.first?.trigger == nil, "an outcome notification fires now, not on a schedule")
    }

    /// The three silent combinations stay silent through the REAL entry point, not just through
    /// the extracted gate: opted out, or the app frontmost (a visible banner is enough).
    @Test(arguments: [(false, false), (false, true), (true, true)])
    func postIfEnabledIsSilentUnlessOptedInAndBackground(enabled: Bool, active: Bool) {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set(enabled, forKey: GeneralSettings.notifyOnBackgroundCompletionKey)

        var postCount = 0
        OperationNotifier.postIfEnabled(for: OperationBanner(message: "x", severity: .success),
                                        defaults: test.defaults, appIsActive: active,
                                        post: { _ in postCount += 1 })
        #expect(postCount == 0)
    }

    /// An absent key is opted OUT — the setting is default-off, and a fresh install must not
    /// notify. Pinned apart from the explicit-false case because `bool(forKey:)` conflates them
    /// and a future migration could seed the key.
    @Test func anUnsetPreferenceMeansNo() {
        let test = TestDefaults()
        defer { test.wipe() }
        var postCount = 0
        OperationNotifier.postIfEnabled(for: OperationBanner(message: "x", severity: .success),
                                        defaults: test.defaults, appIsActive: false,
                                        post: { _ in postCount += 1 })
        #expect(postCount == 0)
    }

    /// The call-site pin: the banner `onChange` in ContentView must hand every new banner to
    /// `postIfEnabled`. This is the one line whose deletion previously shipped the feature dead.
    @Test func theBannerChangeHandlerCallsTheNotifier() throws {
        let source = try macAppFile("ContentView.swift")
        #expect(source.contains("OperationNotifier.postIfEnabled(for:"),
                "nothing in ContentView hands a new banner to OperationNotifier — the background-notification feature is unwired")
    }
}

/// One MacApp file, with the same non-vacuity guard `macAppSources()` carries.
func macAppFile(_ name: String) throws -> String {
    let url = macAppDirectory().appendingPathComponent(name)
    let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read MacApp/\(name) — the scan would be vacuous")
    try #require(text.count > 500, "MacApp/\(name) read as \(text.count) characters — truncated?")
    return text
}
