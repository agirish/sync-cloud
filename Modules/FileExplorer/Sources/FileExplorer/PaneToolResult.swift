import Foundation
import Sync

/// **How a pane-launched PDF tool or Save as PDF ended, as a result message** (Banner Room, TE207).
///
/// These results were cards of their own at the window's foot, 44pt above its edge and up to 640pt
/// wide, sticky until their ✕ — over the bottom rows of every pane. They are results of what you
/// just did, so they go where every other result goes now: the pane's result message, with the same
/// timing (a success leaves after 5 s, a failure stays) and their doors as its buttons. The run's
/// PROGRESS stays at the foot; only the ending moves.
///
/// The message is plain `OperationBanner` data, so it routes, times out and is announced like the
/// rest; the doors are the run's own host's, carried beside it for the message's buttons to call.
public struct PaneToolResult {
    public let banner: OperationBanner
    public let open: (String) -> Void
    public let reveal: ([String]) -> Void
    public let download: (String) -> Void

    init(banner: OperationBanner, open: @escaping (String) -> Void, reveal: @escaping ([String]) -> Void,
         download: @escaping (String) -> Void = { _ in }) {
        self.banner = banner
        self.open = open
        self.reveal = reveal
        self.download = download
    }

    /// A PDF tool's ending — one copy, a batch's copies, a note, or a failure.
    init(_ result: EditorPDFToolBanner, host: PanePDFToolHost) {
        var followUps: [OperationBanner.FollowUp] = []
        let severity: OperationBanner.Severity
        switch result.kind {
        case .wrote(let path):
            severity = .success
            followUps = [.openInEdit(path), .revealInBrowse([path])]
        case .wroteSeveral(let paths):
            severity = .success
            followUps = [.revealInBrowse(paths)]
        case .note: severity = .warning
        case .failure: severity = .error
        }
        if let path = result.download { followUps.append(.download(path)) }
        self.init(banner: OperationBanner(message: result.message, severity: severity,
                                          detail: result.detail, followUps: followUps),
                  open: host.open, reveal: host.reveal, download: host.download)
    }

    /// Save as PDF's ending.
    init(_ result: SaveAsPDFBanner, host: PaneSaveAsPDFHost) {
        let severity: OperationBanner.Severity
        let followUps: [OperationBanner.FollowUp]
        switch result.kind {
        case .saved(let path):
            severity = .success
            followUps = [.openInEdit(path), .revealInBrowse([path])]
        case .savedSeveral(let paths):
            severity = .success
            followUps = [.revealInBrowse(paths)]
        case .note: (severity, followUps) = (.warning, [])
        case .failure: (severity, followUps) = (.error, [])
        }
        self.init(banner: OperationBanner(message: result.message, severity: severity,
                                          detail: result.detail, followUps: followUps),
                  open: host.open, reveal: host.reveal)
    }

    /// **The doors go to the files still there** — the rule Edit's banner and a batch's keep
    /// (``EditorPDFBatch/follow(_:_:)``): a copy trashed or moved since is left out. Empty when none
    /// is left, and the message then says so (``goneMessage(_:)``) instead of a door that does nothing.
    public static func stillThere(_ paths: [String],
                                  exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [String] {
        paths.filter(exists)
    }

    /// The batch's own words for it, so a door from either place says the same.
    public static func goneMessage(_ paths: [String]) -> String {
        paths.count == 1
            ? "“\((paths[0] as NSString).lastPathComponent)” is no longer there — it was moved or deleted."
            : "The copies are no longer there — they were moved or deleted."
    }
}
