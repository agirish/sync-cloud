import FileProvider
import Foundation
import Testing
import Sync
@testable import FileExplorer

/// **RD68's rules** — when a cloud app's sources say it isn't syncing, and when they say nothing.
/// Driven through `CloudAppMonitor` with a fake system and a hand-turned clock, so every answer is
/// the one the panes, the source menu, the sidebar and Activity read.
@MainActor
@Suite struct CloudAppStatusTests {

    /// What the fake system says. Every field is touched under the lock, which is what the
    /// `@unchecked` stands on.
    final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var _running: Set<CloudApp> = Set(CloudApp.allCases)
        private var _iCloud = true
        private var _dead: Set<String> = []
        private var _readings: [String: CloudAppStatusModel.UploadReading] = [:]
        private var _unanswered: [String] = []
        private var _changes: [(path: String, at: Date)] = []
        var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        func set(running app: CloudApp, _ running: Bool) {
            lock.lock(); defer { lock.unlock() }
            if running { _running.insert(app) } else { _running.remove(app) }
        }
        func set(reading: CloudAppStatusModel.UploadReading, for path: String) {
            lock.lock(); _readings[path] = reading; lock.unlock()
        }
        func set(iCloud: Bool) { lock.lock(); _iCloud = iCloud; lock.unlock() }
        func set(deadAccount folder: String) { lock.lock(); _dead.insert(folder); lock.unlock() }
        func set(unanswered: [String]) { lock.lock(); _unanswered = unanswered; lock.unlock() }
        func isDead(_ folder: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _dead.contains(folder) }
        func change(_ path: String) { lock.lock(); _changes.append((path, now)); lock.unlock() }

        var system: CloudAppMonitor.System {
            CloudAppMonitor.System(
                isRunning: { app in self.lock.lock(); defer { self.lock.unlock() }; return self._running.contains(app) },
                iCloudAvailable: { self.lock.lock(); defer { self.lock.unlock() }; return self._iCloud },
                isLiveAccount: { folder in !self.isDead(folder) },
                reading: { path in self.lock.lock(); defer { self.lock.unlock() }; return self._readings[path] ?? .pending },
                unanswered: { self.lock.lock(); defer { self.lock.unlock() }; return self._unanswered },
                changes: {
                    self.lock.lock(); defer { self.lock.unlock() }
                    let drained = self._changes
                    self._changes = []
                    return drained
                })
        }
    }

    static let storage = "/Users/u/Library/CloudStorage"
    static let personal = CloudProvider(id: "OneDrive-Personal", displayName: "OneDrive - Personal", imageName: "onedrive",
                                        rootPath: "\(storage)/OneDrive-Personal", type: .oneDrive)
    static let work = CloudProvider(id: "OneDrive-Work", displayName: "OneDrive - Work", imageName: "onedrive",
                                    rootPath: "\(storage)/OneDrive-Work", type: .oneDrive)
    static let dropbox = CloudProvider(id: "Dropbox", displayName: "Dropbox", imageName: "dropbox",
                                       rootPath: "\(storage)/Dropbox", type: .dropBox)
    static let iCloud = CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                                      rootPath: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs", type: .iCloud)
    static let folder = CloudProvider(id: "/Users/u/Work", displayName: "Work", imageName: "folder",
                                      rootPath: "/Users/u/Work", type: .localFolder)

    private func monitor(_ fake: Fake, providers: [CloudProvider] = [personal, work, dropbox, iCloud, folder],
                         disabled: Set<String> = []) -> CloudAppMonitor {
        let monitor = CloudAppMonitor(system: fake.system, clock: { fake.now })
        monitor.setProviders(providers, disabled: disabled)
        return monitor
    }

    // MARK: Not running

    /// **Five minutes missing, and not a second less.** A restart of the app, or a slow login,
    /// must not flash a warning; one that stays gone must be said. The grace runs from the first
    /// time it was seen missing — a refresh in between does not restart it.
    @Test func anAppMissingFiveMinutesIsNotRunningAndNotBefore() async {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        let monitor = monitor(fake)
        await monitor.refresh()
        #expect(monitor.problems.isEmpty, "said at once — there is no grace")

        fake.now += CloudAppStatusModel.notRunningGrace - 1
        await monitor.refresh()
        #expect(monitor.problems.isEmpty, "said a second before the grace was over")

        fake.now += 1
        await monitor.refresh()
        #expect(monitor.problems == [Self.personal.id: .notRunning(.oneDrive), Self.work.id: .notRunning(.oneDrive)])
        #expect(CloudAppStatusModel.notRunningGrace == 300)
    }

    /// A quit seen as a notification starts the grace at the quit, not at SyncCloud's launch — and
    /// at any time, not only at login.
    @Test func aQuitLaterInTheSessionStartsItsOwnGrace() async {
        let fake = Fake()
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += 3600
        fake.set(running: .dropbox, false)
        await monitor.refresh()   // what a change to the running apps asks for
        fake.now += CloudAppStatusModel.notRunningGrace - 1
        await monitor.refresh()
        #expect(monitor.problems.isEmpty)
        fake.now += 1
        await monitor.refresh()
        #expect(monitor.problems == [Self.dropbox.id: .notRunning(.dropbox)])
    }

    /// **The moment the app launches, the warning goes** — in the refresh the change to the running
    /// apps asks for, without waiting out a grace the other way.
    @Test func aLaunchClearsTheWarningAtOnce() async {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.problems[Self.personal.id] == .notRunning(.oneDrive))
        #expect(monitor.notices.map(\.id) == ["not-running"])

        fake.set(running: .oneDrive, true)
        await monitor.refresh()
        #expect(monitor.problems.isEmpty, "a launch did not clear it")
        #expect(monitor.notices.isEmpty)

        // And a later quit starts a new grace, not the old one's remainder.
        fake.now += 60
        fake.set(running: .oneDrive, false)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace - 1
        await monitor.refresh()
        #expect(monitor.problems.isEmpty, "a second quit inherited the first one's grace")
    }

    // MARK: What gets nothing

    /// **A source turned off in Settings shows nothing**, while its sibling account of the same
    /// app, still on, does — so a rule that ignored `disabled` and one that hid every account of
    /// the app would both fail here.
    @Test func aDisabledSourceShowsNothingAndItsSiblingStillDoes() async {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        let monitor = monitor(fake, disabled: [Self.work.id])
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.problems == [Self.personal.id: .notRunning(.oneDrive)])

        monitor.setProviders([Self.personal, Self.work, Self.dropbox, Self.iCloud, Self.folder], disabled: [Self.personal.id])
        await monitor.refresh()
        #expect(monitor.problems == [Self.work.id: .notRunning(.oneDrive)])
    }

    /// An account folder File Provider no longer knows is a leftover whose account is gone: it
    /// gets nothing, while a live account of the same app does.
    @Test func aLeftoverAccountFolderShowsNothing() async {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        fake.set(deadAccount: Self.work.rootPath)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.problems == [Self.personal.id: .notRunning(.oneDrive)])
    }

    // MARK: Not responding, iCloud

    /// A folder not downloaded here that didn't answer marks the source it is in — and only that
    /// one.
    @Test func anUnansweredFolderMarksItsSourceNotResponding() async {
        let fake = Fake()
        fake.set(unanswered: ["\(Self.storage)/OneDrive-Work/.Trash"])
        let monitor = monitor(fake)
        await monitor.refresh()
        #expect(monitor.problems == [Self.work.id: .notResponding])
        #expect(monitor.notices.first?.title == "OneDrive isn’t responding")

        fake.set(unanswered: [])
        await monitor.refresh()
        #expect(monitor.problems.isEmpty)
    }

    @Test func iCloudSignedOutMarksICloudOnly() async {
        let fake = Fake()
        fake.set(iCloud: false)
        let monitor = monitor(fake)
        await monitor.refresh()
        #expect(monitor.problems == [Self.iCloud.id: .iCloudOff])
        #expect(monitor.notices.map(\.actions) == [[.openICloudSettings]])
    }

    // MARK: Uploads

    /// **A refusal is skipped; a file still waiting is not uploading** — and only after 30 minutes.
    /// The refused file is named first in the fixture so a rule that took any error as "not
    /// uploading" would put it in the problem.
    @Test func aRefusedFileIsSkippedAndAWaitingOneIsNotUploading() async {
        let fake = Fake()
        let refused = "\(Self.storage)/Dropbox/Icon file"
        let waiting = "\(Self.storage)/Dropbox/Report.pdf"
        fake.set(reading: .refused("Dropbox won’t take this name"), for: refused)
        fake.set(reading: .pending, for: waiting)
        fake.change(refused)
        fake.change(waiting)
        let monitor = monitor(fake)
        await monitor.refresh()
        #expect(monitor.problems.isEmpty, "a file just changed is not late")
        #expect(monitor.skipped == [Self.dropbox.id: [CloudSkippedFile(path: refused, reason: "Dropbox won’t take this name")]])

        fake.now += CloudAppStatusModel.uploadDeadline - 1
        await monitor.refresh()
        #expect(monitor.problems.isEmpty, "said before 30 minutes")

        fake.now += 1
        await monitor.refresh()
        #expect(monitor.problems == [Self.dropbox.id: .notUploading(paths: [waiting], since: fake.now - CloudAppStatusModel.uploadDeadline)])
        #expect(CloudAppStatusModel.uploadDeadline == 1800)

        // Uploaded: it stops being watched, and the problem goes.
        fake.set(reading: .uploaded, for: waiting)
        await monitor.refresh()
        #expect(monitor.problems.isEmpty)
        #expect(monitor.skipped[Self.dropbox.id]?.map(\.path) == [refused])
    }

    /// Only files inside a cloud source are watched, and never a hidden one — Dropbox reports its
    /// ignored `.DS_Store` as not uploaded, with no error, for good (measured 2026-10-30).
    @Test func hiddenFilesAndFilesOutsideEveryCloudSourceAreNotWatched() async {
        let fake = Fake()
        fake.change("\(Self.storage)/Dropbox/.DS_Store")
        fake.change("/Users/u/Work/notes.txt")
        fake.change("\(Self.storage)/OneDrive-Work/Plan.docx")
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.uploadDeadline
        await monitor.refresh()
        #expect(monitor.problems.keys.sorted() == [Self.work.id])
        #expect(CloudAppStatusModel.reading(at: "/no/such/.DS_Store") == .unknown)
    }

    /// The refusal rule: the provider refusing this file, never the account or the network.
    @Test func onlyAnItemRefusalIsARefusal() {
        func error(_ code: NSFileProviderError.Code) -> NSError { NSError(domain: NSFileProviderErrorDomain, code: code.rawValue) }
        #expect(CloudAppStatusModel.isRefusal(error(.excludedFromSync)))
        #expect(CloudAppStatusModel.isRefusal(error(.filenameCollision)))
        #expect(CloudAppStatusModel.isRefusal(error(.cannotSynchronize)))
        #expect(!CloudAppStatusModel.isRefusal(error(.serverUnreachable)))
        #expect(!CloudAppStatusModel.isRefusal(error(.notAuthenticated)))
        #expect(!CloudAppStatusModel.isRefusal(error(.insufficientQuota)))
        #expect(!CloudAppStatusModel.isRefusal(NSError(domain: NSCocoaErrorDomain, code: NSFileProviderError.Code.excludedFromSync.rawValue)))
    }

    // MARK: Activity

    /// **A dismissed row stays dismissed while it says the same, and comes back when it changes.**
    @Test func aDismissedRowComesBackWhenTheStateChanges() async throws {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        let row = try #require(monitor.notices.first)
        #expect(row.title == "OneDrive isn’t running")
        #expect(row.detail == "Files in its 2 folders may be out of date, here and in Finder")
        #expect(row.actions == [.open(.oneDrive)])

        monitor.dismiss(row)
        #expect(monitor.notices.isEmpty)
        fake.now += 60
        await monitor.refresh()
        #expect(monitor.notices.isEmpty, "a refresh that changed nothing brought it back")

        fake.set(running: .dropbox, false)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.notices.map(\.title) == ["Dropbox and OneDrive aren’t running"])
        #expect(monitor.notices.first?.actions == [.open(.dropbox), .open(.oneDrive)])
    }

    /// Open is offered for an installed app only — known from the refresh, never asked of
    /// LaunchServices while a view renders.
    @Test func openIsOfferedOnlyForAnInstalledApp() async {
        let fake = Fake()
        var system = fake.system
        system.appURL = { $0 == .oneDrive ? URL(fileURLWithPath: "/Applications/OneDrive.app") : nil }
        let monitor = CloudAppMonitor(system: system, clock: { fake.now })
        #expect(!monitor.canOpen(.oneDrive), "offered before anything was read")
        await monitor.refresh()
        #expect(monitor.canOpen(.oneDrive))
        #expect(!monitor.canOpen(.dropbox))
    }

    // MARK: Running apps

    /// The bundle an executable sits in — the last `Contents/MacOS`, so a helper app nested inside
    /// another is its own bundle and is never taken for the app around it.
    @Test func anExecutableBelongsToTheInnermostBundle() {
        #expect(RunningBundles.bundlePath(ofExecutable: "/Applications/Dropbox.app/Contents/MacOS/Dropbox")
                == "/Applications/Dropbox.app")
        #expect(RunningBundles.bundlePath(ofExecutable: "/Applications/Google Drive.app/Contents/Library/Helper.app/Contents/MacOS/Helper")
                == "/Applications/Google Drive.app/Contents/Library/Helper.app")
        #expect(RunningBundles.bundlePath(ofExecutable: "/usr/libexec/fileproviderd") == nil)
    }

    /// The kernel route finds an app that is certainly running — this test's own host, by its
    /// identifier — so an empty answer can never pass as "nothing is running".
    @Test func theKernelRouteFindsARunningApp() throws {
        let ids = RunningBundles.shared.identifiers()
        #expect(!ids.isEmpty)
        #expect(ids.contains("com.apple.dock") || ids.contains("com.apple.finder"), "found \(ids.count) bundles, but neither the Dock nor Finder")
    }
}
