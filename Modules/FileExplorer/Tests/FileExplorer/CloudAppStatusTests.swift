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
        /// When set, every upload read waits on it — a provider that has stopped answering.
        var gate: DispatchSemaphore?
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
        func set(liveAccount folder: String) { lock.lock(); _dead.remove(folder); lock.unlock() }
        func isDead(_ folder: String) -> Bool { lock.lock(); defer { lock.unlock() }; return _dead.contains(folder) }
        func change(_ path: String) { lock.lock(); _changes.append((path, now)); lock.unlock() }

        var system: CloudAppMonitor.System {
            CloudAppMonitor.System(
                isRunning: { app in self.lock.lock(); defer { self.lock.unlock() }; return self._running.contains(app) },
                iCloudAvailable: { self.lock.lock(); defer { self.lock.unlock() }; return self._iCloud },
                isLiveAccount: { folder in !self.isDead(folder) },
                reading: { path in
                    self.gate?.wait()
                    self.lock.lock(); defer { self.lock.unlock() }
                    return self._readings[path] ?? .pending
                },
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
    }

    /// The refusal rule: the provider refusing this file, never the account or the network.
    @Test func onlyAnItemRefusalIsARefusal() {
        func error(_ code: NSFileProviderError.Code) -> NSError { NSError(domain: NSFileProviderErrorDomain, code: code.rawValue) }
        #expect(CloudAppStatusModel.isRefusal(error(.excludedFromSync)))
        #expect(CloudAppStatusModel.isRefusal(error(.filenameCollision)))
        // A general failure, maybe the account's: "not uploading", never hidden as "skipped".
        #expect(!CloudAppStatusModel.isRefusal(error(.cannotSynchronize)))
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

    /// The kernel route finds an app that is certainly running in a logged-in session — the Dock
    /// or Finder — so an empty answer can never pass as "nothing is running".
    @Test func theKernelRouteFindsARunningApp() throws {
        let ids = RunningBundles.shared.identifiers()
        #expect(!ids.isEmpty)
        #expect(ids.contains("com.apple.dock") || ids.contains("com.apple.finder"), "found \(ids.count) bundles, but neither the Dock nor Finder")
    }

    // MARK: Review fixes, 2026-10-30

    /// **The same problem coming back is a change.** Dismiss "OneDrive isn't running", OneDrive
    /// runs again, then quits again: the row is back. And iCloud's row, whose words never change.
    @Test func aDismissedRowComesBackWhenTheSameProblemReturns() async throws {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        fake.set(iCloud: false)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        for notice in monitor.notices { monitor.dismiss(notice) }
        #expect(monitor.notices.isEmpty)

        fake.set(running: .oneDrive, true)
        fake.set(iCloud: true)
        await monitor.refresh()
        fake.set(running: .oneDrive, false)
        fake.set(iCloud: false)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.notices.map(\.id).sorted() == ["icloud-off", "not-running"])
    }

    /// **The worst that applies, and no "not responding" while an app is merely missing.** A
    /// missing app's folders do not answer; within the grace nothing is said, after it "not
    /// running" is. A running app's unanswered folder outranks a late upload.
    @Test func notRunningOutranksAndSilencesNotResponding() async {
        let fake = Fake()
        let trash = "\(Self.storage)/OneDrive-Work/.Trash"
        let plan = "\(Self.storage)/OneDrive-Work/Plan.docx"
        fake.change(plan)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.uploadDeadline
        fake.set(unanswered: [trash])
        await monitor.refresh()
        #expect(monitor.problems == [Self.work.id: .notResponding], "a late upload outranked an unanswered folder")

        fake.set(running: .oneDrive, false)
        await monitor.refresh()
        #expect(monitor.problems.isEmpty, "said \(monitor.problems) within the grace")
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.problems == [Self.personal.id: .notRunning(.oneDrive), Self.work.id: .notRunning(.oneDrive)])
    }

    /// `since` is the OLDEST waiting change — the newest is first in the fixture, so a `.max()`
    /// or a `.first` would both answer wrong — and a file changed again starts its wait over.
    @Test func sinceIsTheOldestWaitAndAChangeRestartsIt() async {
        let fake = Fake()
        let old = "\(Self.storage)/Dropbox/Old.pdf"
        let new = "\(Self.storage)/Dropbox/A-new.pdf"
        let started = fake.now
        fake.change(old)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += 600
        fake.change(new)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.uploadDeadline
        await monitor.refresh()
        #expect(monitor.problems == [Self.dropbox.id: .notUploading(paths: [new, old], since: started)])

        fake.change(old)   // changed again: its 30 minutes start now
        await monitor.refresh()
        #expect(monitor.problems == [Self.dropbox.id: .notUploading(paths: [new], since: started + 600)])
    }

    /// A file whose upload state is not known yet stays watched — and is counted once its provider
    /// says "not uploaded" — instead of being dropped at the first look.
    @Test func aFileNotYetKnownStaysWatched() async {
        let fake = Fake()
        let file = "\(Self.storage)/Dropbox/Fresh.pdf"
        fake.set(reading: .unknown, for: file)
        fake.change(file)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.set(reading: .pending, for: file)
        fake.now += CloudAppStatusModel.uploadDeadline
        await monitor.refresh()
        #expect(monitor.problems == [Self.dropbox.id: .notUploading(paths: [file], since: fake.now - CloudAppStatusModel.uploadDeadline)])
    }

    /// The watch list keeps the newest `watchLimit` changes, trimmed once per batch.
    @Test func theWatchListKeepsTheNewest() {
        var model = CloudAppStatusModel()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<(CloudAppStatusModel.watchLimit + 5) {
            model.noteChanged("/f\(String(format: "%05d", i))", at: start + Double(i))
        }
        model.trimToLimit()
        #expect(model.watchedPaths.count == CloudAppStatusModel.watchLimit)
        #expect(model.watchedPaths.first == "/f00005", "kept an old change and dropped a new one")
    }

    /// Names the providers skip without an error are never watched.
    @Test func namesProvidersNeverUploadAreNotWatched() {
        var model = CloudAppStatusModel()
        for name in [".DS_Store", "Thumbs.db", "desktop.ini", "~$Report.docx", "Icon\r", "Report.docx"] {
            model.noteChanged("/x/\(name)", at: Date())
        }
        #expect(model.watchedPaths == ["/x/Report.docx"])
    }

    /// **A failed File Provider check is asked again**, so a moment it was unavailable does not hide
    /// a source until the next wake; a "known" answer is kept.
    @Test func aFailedAccountCheckIsAskedAgain() async {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        fake.set(deadAccount: Self.work.rootPath)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.problems[Self.work.id] == nil)
        fake.set(liveAccount: Self.work.rootPath)
        await monitor.refresh()
        #expect(monitor.problems[Self.work.id] == .notRunning(.oneDrive))
    }

    /// **A change made through a link into an account counts** — `~/Dropbox/x.pdf` is the Dropbox
    /// account's file, though spelled outside CloudStorage.
    @Test func aChangeSpelledThroughALinkIsWatched() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rd68-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let account = base.appendingPathComponent("Library/CloudStorage/Dropbox")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("Dropbox")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: account)
        let realAccount = account.resolvingSymlinksInPath().path
        let dropbox = CloudProvider(id: "Dropbox", displayName: "Dropbox", imageName: "dropbox",
                                    rootPath: realAccount, type: .dropBox)
        let fake = Fake()
        fake.change(link.appendingPathComponent("x.pdf").path)
        let monitor = monitor(fake, providers: [dropbox])
        await monitor.refresh()
        fake.now += CloudAppStatusModel.uploadDeadline
        await monitor.refresh()
        #expect(monitor.problems == [dropbox.id: .notUploading(paths: [realAccount + "/x.pdf"], since: fake.now - CloudAppStatusModel.uploadDeadline)])
    }

    /// **A stuck upload read does not freeze the status.** With every upload read hanging, a
    /// launch still clears "not running" — through the same request a change to the running apps
    /// makes, not a test-only path.
    @Test func aStuckUploadReadDoesNotHoldBackALaunch() async throws {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        let monitor = monitor(fake)
        await monitor.refresh()
        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.problems[Self.personal.id] == .notRunning(.oneDrive))

        let gate = DispatchSemaphore(value: 0)
        fake.gate = gate
        defer { for _ in 0..<8 { gate.signal() } }
        fake.change("\(Self.storage)/Dropbox/Stuck.pdf")
        monitor.requestRefresh()            // its slow half now hangs on the read
        try await Task.sleep(for: .milliseconds(200))
        fake.set(running: .oneDrive, true)
        monitor.requestRefresh()
        let deadline = ContinuousClock.now + .seconds(5)
        while !monitor.problems.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(monitor.problems.isEmpty, "a hung upload read kept the warning after the app launched")
    }

    @Test func durationsRollIntoHours() {
        #expect(CloudAppNotice.duration(30) == "1 min")
        #expect(CloudAppNotice.duration(40 * 60) == "40 min")
        #expect(CloudAppNotice.duration(120 * 60) == "2 h")
        #expect(CloudAppNotice.duration(125 * 60) == "2 h 5 min")
    }

    /// OneDrive ships under two IDs; either running is OneDrive running.
    @Test func oneDriveIsKnownByBothItsIDs() {
        #expect(CloudApp.oneDrive.bundleIdentifiers == ["com.microsoft.OneDrive-mac", "com.microsoft.OneDrive"])
        #expect(CloudAppNotice.Action.show(["/a"]).title == "Show It")
        #expect(CloudAppNotice.Action.show(["/a", "/b"]).title == "Show Them")
    }

    // MARK: Asked about at once (decision DN)

    /// **A source the user picks says "not running" at once; one restored at launch waits.** The
    /// launch's own refresh with OneDrive already quit shows nothing — the grace — and picking a
    /// OneDrive source then shows it with no wait, on every OneDrive account (it is the app that
    /// is down). Activity's row still waits out the grace: it appears on its own.
    @Test func aPickedSourceSaysNotRunningAtOnceAndARestoredOneWaits() async {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        let monitor = monitor(fake)
        await monitor.refresh()   // launch, with the panes' restored tabs on OneDrive
        #expect(monitor.problems.isEmpty, "a restored tab did not wait out the grace")

        fake.now += 10
        await monitor.check([Self.personal.id])
        #expect(monitor.problems == [Self.personal.id: .notRunning(.oneDrive), Self.work.id: .notRunning(.oneDrive)],
                "picking the source did not say so at once")
        #expect(monitor.notices.isEmpty, "Activity's row skipped the grace")

        fake.now += CloudAppStatusModel.notRunningGrace
        await monitor.refresh()
        #expect(monitor.notices.map(\.id) == ["not-running"])
    }

    /// Once the app runs, the at-once rule is spent: a later quit nobody asked about waits again.
    @Test func aLaunchEndsTheAtOnceRule() async {
        let fake = Fake()
        fake.set(running: .dropbox, false)
        let monitor = monitor(fake)
        await monitor.check([Self.dropbox.id])
        #expect(monitor.problems == [Self.dropbox.id: .notRunning(.dropbox)])

        fake.set(running: .dropbox, true)
        await monitor.refresh()
        #expect(monitor.problems.isEmpty)
        fake.now += 60
        fake.set(running: .dropbox, false)
        await monitor.refresh()
        #expect(monitor.problems.isEmpty, "a quit nobody asked about skipped the grace")
    }

    /// Asking about a running app, a disabled source, iCloud or a folder shows nothing.
    @Test func askingAboutAHealthyOrDisabledSourceShowsNothing() async {
        let fake = Fake()
        fake.set(running: .oneDrive, false)
        let monitor = monitor(fake, disabled: [Self.personal.id, Self.work.id])
        await monitor.check([Self.personal.id, Self.work.id, Self.dropbox.id, Self.iCloud.id, Self.folder.id])
        #expect(monitor.problems.isEmpty, "said \(monitor.problems)")
    }

    /// **The four places that ask, and the one that must not.** A pick in the source menu and the
    /// pointer reaching its chip, a click on a sidebar source, and Settings ▸ Sources on screen
    /// all check at once; the window's own provider restore does not — ContentView's one call is
    /// the Settings one.
    @Test func theUserGesturesAskAndARestoreDoesNot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let menu = try source("Modules/FileExplorer/Sources/FileExplorer/ProviderMenu.swift")
        #expect(menu.contains("cloudApps.checkNow([id])\n                onSelect(id)"), "a pick does not check before selecting")
        #expect(menu.contains(".onHover { inside in\n            if inside { cloudApps.checkNow(providers.map(\\.id)) }"),
                "reaching the chip does not check what the menu lists")
        let sidebar = try source("Modules/Dashboard/Sources/Dashboard/FolderSidebar.swift")
        #expect(sidebar.contains("cloudApps.checkNow([source.id])\n            onOpenSource("), "a sidebar click does not check")
        let window = try source("MacApp/ContentView.swift")
        #expect(window.components(separatedBy: "checkNow(").count - 1 == 1, "ContentView checks somewhere other than Settings ▸ Sources")
        #expect(window.contains(".onChange(of: showSettings && settingsTab == .providers)"), "Settings ▸ Sources does not check")
    }
}
