import Foundation
import Sync

/// Whether an `![alt](source)` names something this preview will draw, and if not, why not.
///
/// The rule is "already on this disk": the preview never fetches, so a remote URL is refused, and
/// a local file is drawn.
///
/// A cloud-only file is refused too. In iCloud and Dropbox folders a file is a placeholder until
/// something reads it, and drawing one would download whatever a note links to, over the user's
/// connection and into their quota. The rail dims cloud-only rows for the same reason.
enum MarkdownImageSource: Equatable, Sendable {

    /// An absolute path to a file that exists, is local, and is small enough to decode.
    case local(String)
    /// Not drawable, in prose the preview shows beside the alt text.
    case refused(String)

    /// The most a single image may weigh before the preview declines to decode it.
    ///
    /// A cap on the file, checked before decoding, because decoding is the expensive part. It
    /// catches a huge TIFF next to a note, not a large-bitmap photo in a modest file; the render
    /// caps the drawn size for that.
    static let maxBytes = 25 * 1024 * 1024

    /// Resolves a Markdown image source against the folder its document lives in.
    ///
    /// - Parameter folder: the open document's directory. `nil` when nothing is open; a relative
    ///   path is then refused rather than resolved against the working directory.
    static func resolve(_ source: String, relativeTo folder: String?,
                        fileManager: FileManager = .default,
                        isCloudOnly: (String) -> Bool = {
                            MaterializationStatus.isCloudOnly(atPath: $0)
                        }) -> MarkdownImageSource {
        let located = location(of: source, relativeTo: folder)
        guard case .local(let path) = located else { return located }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .refused("Not found.")
        }
        let target = MaterializationStatus.linkTarget(of: path)
        guard !isCloudOnly(target) else {
            return .refused("Not downloaded — the preview won’t fetch it.")
        }
        let size = (try? fileManager.attributesOfItem(atPath: target))?[.size] as? NSNumber
        if let bytes = size?.intValue, bytes > maxBytes {
            return .refused("Too large to draw (\(FileSyncManager.formatBytes(bytes))).")
        }
        return .local(path)
    }

    /// Where `source` would be on disk, before the disk is asked: `.local` with the path, or the
    /// refusal nothing on disk can change — no path, a remote URL, a relative path with no folder.
    /// The editable Preview looks again for a picture the disk refused, and never for one of these.
    static func location(of source: String, relativeTo folder: String?) -> MarkdownImageSource {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused("No image path.") }

        // A scheme other than `file:` is somewhere else entirely.
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme != "file" {
            return .refused("Remote images aren’t downloaded.")
        }

        var path: String
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            path = url.path
        } else {
            // Percent-decoded, because Markdown writes a space in a path as `%20`; left encoded,
            // "my notes/a b.png" would be reported not found.
            path = trimmed.removingPercentEncoding ?? trimmed
        }
        path = (path as NSString).expandingTildeInPath

        if !(path as NSString).isAbsolutePath {
            guard let folder, !folder.isEmpty else {
                return .refused("Nothing to resolve this path against.")
            }
            path = (folder as NSString).appendingPathComponent(path)
        }
        return .local((path as NSString).standardizingPath)
    }
}
