import Foundation
import Testing
import Sync
@testable import FileExplorer

/// **The pane bar's words and button** (RD68). The not-running sentence is the approved design's,
/// word for word; the button is the one thing that fixes the state, or none.
@Suite struct CloudAppWarningBarTests {

    @Test func notRunningSaysTheApprovedSentenceAndOffersToOpenTheApp() {
        let words = CloudAppWarningBar.sentence(for: .notRunning(.oneDrive), sourceName: "OneDrive - Personal", now: Date())
        #expect(words.lead + words.rest == "The OneDrive app isn’t running, so these files may be out of date, here and in Finder. "
                + "Changes from other devices won’t arrive, and folders not downloaded to this Mac won’t open, until it runs.")
        #expect(CloudAppWarningBar.action(for: .notRunning(.oneDrive), canOpen: { _ in true }) == .open(.oneDrive))
        #expect(CloudAppNotice.Action.open(.oneDrive).title == "Open OneDrive")
    }

    /// An app that is not installed gets no button rather than one that does nothing.
    @Test func anAppThatIsNotInstalledGetsNoButton() {
        #expect(CloudAppWarningBar.action(for: .notRunning(.googleDrive), canOpen: { _ in false }) == nil)
        #expect(CloudAppWarningBar.action(for: .notResponding, canOpen: { _ in true }) == nil)
        #expect(CloudAppWarningBar.action(for: .iCloudOff, canOpen: { _ in false }) == .openICloudSettings)
    }

    @Test func notUploadingCountsTheFilesAndTheMinutes() {
        let since = Date(timeIntervalSinceReferenceDate: 0)
        let problem = CloudAppProblem.notUploading(paths: ["/a", "/b", "/c"], since: since)
        let words = CloudAppWarningBar.sentence(for: problem, sourceName: "Dropbox", now: since + 40 * 60)
        #expect(words.lead + words.rest
                == "Dropbox hasn’t uploaded 3 files SyncCloud changed here for 40 min, so your other devices don’t have them yet.")
        #expect(CloudAppWarningBar.action(for: problem, canOpen: { _ in true }) == .show(["/a", "/b", "/c"]))
    }
}
