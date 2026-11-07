import AppKit
import Events
import Sync

/// "Copy Log for Sharing", for the Activity Log's bar and Settings ▸ Advanced: the whole log file,
/// masked (``LogSharing``), on the clipboard. One body for both buttons, so they can't drift.
public enum CopyLogForSharing {
    /// The button's name and tooltip, shared by both places and the settings catalog.
    public static let title = "Copy Log for Sharing"
    public static let help = "Copy the whole log for a bug report, with email addresses, your home folder and the names in your People lists masked. The log file itself keeps everything."

    /// Reads and masks off the main actor, then puts the copy on the clipboard. Logs what it did,
    /// without the copy's text; false when the log file doesn't read.
    @MainActor @discardableResult
    public static func copy(logger: Logger = .shared) async -> Bool {
        let fileURL = logger.logFileURL
        let drainWriter = logger.diskWriteBarrier()
        let home = NSHomeDirectory()
        let profiles = FilingProfileStore.defaultDirectory()
        let text = await Task.detached(priority: .userInitiated) {
            LogSharing.sharedCopy(of: fileURL, drainWriter: drainWriter, home: home, profilesDirectory: profiles)
        }.value
        guard let text else {
            logger.warning("Copy Log for Sharing: \(fileURL.lastPathComponent) couldn’t be read; nothing was copied")
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Copy Log for Sharing: copied \(text.utf8.count) bytes, masked")
        return true
    }
}
