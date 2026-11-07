import Foundation
import Sync

/// How a pane-launched PDF tool or Save as PDF ended, as a result message.
///
/// It goes where every other result goes, the pane's result message, with the same timing (a
/// success leaves after 5 s, a failure stays) and its doors as buttons; the run's progress stays at
/// the window's foot. The message is plain `OperationBanner` data, so it routes, times out and is
/// announced like the rest; the doors are the run's host's, carried beside it.
public struct PaneToolResult {
    /// Which run it ends, so the window can send it where that run was started.
    public enum Source: Equatable, Sendable {
        case pdfTools
        case saveAsPDF
    }

    public let banner: OperationBanner
    public let source: Source
    public let open: (String) -> Void
    public let reveal: ([String]) -> Void
    public let download: (String) -> Void

    init(banner: OperationBanner, source: Source = .pdfTools, open: @escaping (String) -> Void,
         reveal: @escaping ([String]) -> Void, download: @escaping (String) -> Void = { _ in }) {
        self.banner = banner
        self.source = source
        self.open = open
        self.reveal = reveal
        self.download = download
    }

    /// A PDF tool's ending: one copy, a batch's copies, a note, or a failure.
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
                  source: .saveAsPDF, open: host.open, reveal: host.reveal)
    }

    /// The doors go to the files still there, the rule Edit's banner keeps
    /// (``EditorPDFTools/follow(_:_:)``): a copy trashed or moved since is left out. Empty when none
    /// is left, and the message then says so (``goneMessage(_:)``) instead of a door that does nothing.
    public static func stillThere(_ paths: [String],
                                  exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [String] {
        paths.filter(exists)
    }

    /// Edit's banner's words for it, so a door from either place says the same.
    public static func goneMessage(_ paths: [String]) -> String {
        paths.count == 1
            ? "“\((paths[0] as NSString).lastPathComponent)” is no longer there — it was moved or deleted."
            : "The copies are no longer there — they were moved or deleted."
    }
}
