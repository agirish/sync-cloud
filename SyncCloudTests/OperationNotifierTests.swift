import Testing
import Foundation
import UserNotifications
@testable import SyncCloud
import Settings
import Sync

/// Pins the background-notification path end to end, short of UNUserNotificationCenter: the gate,
/// the titles, the request `postIfEnabled` builds (via the injected `post` seam), and that the app
/// actually calls it. Without the call-site pin, deleting one line would ship the feature dead
/// with every other test green.
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

    /// The request is built from the banner: title per severity, message as body, and the
    /// banner's id as identifier, so the system doesn't coalesce two different outcomes into one.
    @Test func postIfEnabledBuildsTheRequestFromTheBanner() {
        let test = TestDefaults()
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

    /// A message that ends a run is titled with the run, carries its detail, and names itself: the
    /// click opens that row in Activity, which the id in `userInfo` finds.
    @Test func aRunsEndingIsTitledWithTheRunAndNamesItsRow() {
        let test = TestDefaults()
        test.defaults.set(true, forKey: GeneralSettings.notifyOnBackgroundCompletionKey)
        let banner = OperationBanner(message: "Merged “Photos”", severity: .warning, detail: "Skipped IMG_3120.jpg")
        var posted: [UNNotificationRequest] = []
        OperationNotifier.postIfEnabled(for: banner, runTitle: "Merging “Photos”", defaults: test.defaults,
                                        appIsActive: false, post: { posted.append($0) })
        #expect(posted.first?.content.title == "Merging “Photos”")
        #expect(posted.first?.content.body == "Merged “Photos”\nSkipped IMG_3120.jpg")
        #expect(posted.first?.content.userInfo[OperationNotifier.activityMessageKey] as? String == banner.id.uuidString)
    }

    /// The run is named only when it ended a moment ago — an old run's name on an unrelated
    /// message would be a wrong title.
    @Test func onlyARunThatJustEndedNamesTheNotification() {
        let now = Date()
        #expect(OperationNotifier.runTitle(lastFinished: (title: "Copying 12 items", ended: now.addingTimeInterval(-1)),
                                           now: now) == "Copying 12 items")
        // The same window as the app's own routing: a copy that ended 5 s before another message
        // is not that message's run.
        #expect(OperationNotifier.runTitle(lastFinished: (title: "Copying 12 items", ended: now.addingTimeInterval(-5)),
                                           now: now) == nil)
        #expect(OperationNotifier.runTitle(lastFinished: nil, now: now) == nil)
    }

    /// The three silent combinations stay silent through the real entry point, not just the gate:
    /// opted out, or the app frontmost (a visible banner is enough).
    @Test(arguments: [(false, false), (false, true), (true, true)])
    func postIfEnabledIsSilentUnlessOptedInAndBackground(enabled: Bool, active: Bool) {
        let test = TestDefaults()
        test.defaults.set(enabled, forKey: GeneralSettings.notifyOnBackgroundCompletionKey)

        var postCount = 0
        OperationNotifier.postIfEnabled(for: OperationBanner(message: "x", severity: .success),
                                        defaults: test.defaults, appIsActive: active,
                                        post: { _ in postCount += 1 })
        #expect(postCount == 0)
    }

    /// An absent key is opted out: the setting is default-off, so a fresh install must not notify.
    /// Pinned apart from explicit false, which `bool(forKey:)` conflates with it.
    @Test func anUnsetPreferenceMeansNo() {
        let test = TestDefaults()
        var postCount = 0
        OperationNotifier.postIfEnabled(for: OperationBanner(message: "x", severity: .success),
                                        defaults: test.defaults, appIsActive: false,
                                        post: { _ in postCount += 1 })
        #expect(postCount == 0)
    }

    /// The call-site pin: the banner `onChange` in ContentView must hand every new banner to
    /// `postIfEnabled`. Deleting that one line would ship the feature dead.
    @Test func theBannerChangeHandlerCallsTheNotifier() throws {
        // Comment lines stripped, so a commented-out call doesn't count as one.
        let code = try macAppFile("ContentView.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("OperationNotifier.postIfEnabled(for:"),
                "nothing in ContentView hands a new banner to OperationNotifier — the background-notification feature is unwired")
    }
}

/// One MacApp file, with the same non-vacuity guard `macAppSources()` carries. Finds `MacApp/`
/// from this file itself, not through `macAppDirectory()`, so the suite stays self-contained.
func macAppFile(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)   // …/SyncCloudTests/OperationNotifierTests.swift
        .deletingLastPathComponent()            // …/SyncCloudTests
        .deletingLastPathComponent()            // repo root
        .appendingPathComponent("MacApp/\(name)")
    let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read MacApp/\(name) — the scan would be vacuous")
    try #require(text.count > 500, "MacApp/\(name) read as \(text.count) characters — truncated?")
    return text
}
