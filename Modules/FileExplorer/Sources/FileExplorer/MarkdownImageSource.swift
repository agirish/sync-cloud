import Foundation
import Sync

/// Whether an `![alt](source)` names something this preview will draw, and if not, why not.
///
/// **The rule is "already on this disk", not "looks like an image".** The preview renders a file the
/// user has open; it does not fetch. A remote URL is refused rather than downloaded — that is the
/// line the old placeholder was defending, and it still holds. What changed is that a *local* file
/// is not reaching out at all, so refusing it was defending nothing.
///
/// **A cloud-only file is refused too, and that is the rule with teeth.** These are iCloud and
/// Dropbox folders full of files that are placeholders until something reads them. Drawing one
/// would *materialise* it — a preview that silently downloads whatever a document links to, over
/// somebody's connection and into their disk quota, because they opened a note. The rail already
/// dims cloud-only rows for the same reason; this is the same rule in the same words.
enum MarkdownImageSource: Equatable, Sendable {

    /// An absolute path to a file that exists, is local, and is small enough to decode.
    case local(String)
    /// Not drawable, in prose the preview shows beside the alt text.
    case refused(String)

    /// The most a single image may weigh before the preview declines to decode it.
    ///
    /// **A cap on the FILE, checked before decoding, because decoding is the expensive part.** A
    /// 40-megapixel photo is a modest file and a very large bitmap; this does not pretend to catch
    /// that, and the render caps the drawn size instead. What it catches is the pathological case —
    /// a multi-hundred-megabyte TIFF next to a note — where the decode itself is the problem.
    static let maxBytes = 25 * 1024 * 1024

    /// Resolves a Markdown image source against the folder its document lives in.
    ///
    /// - Parameter folder: the open document's directory. `nil` when nothing is open, and then a
    ///   relative path has nothing to be relative to — which is a refusal rather than a guess at
    ///   the current working directory, a folder the user has never heard of.
    static func resolve(_ source: String, relativeTo folder: String?,
                        fileManager: FileManager = .default,
                        isCloudOnly: (String) -> Bool = {
                            MaterializationStatus.isCloudOnly(atPath: $0)
                        }) -> MarkdownImageSource {
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
            // **Percent-decoded, because a Markdown path with a space in it is written `%20`.**
            // Leaving it encoded turns "my notes/a b.png" into a path that does not exist, and the
            // refusal would read "not found" about a file that is right there.
            path = trimmed.removingPercentEncoding ?? trimmed
        }
        path = (path as NSString).expandingTildeInPath

        if !(path as NSString).isAbsolutePath {
            guard let folder, !folder.isEmpty else {
                return .refused("Nothing to resolve this path against.")
            }
            path = (folder as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .refused("Not found.")
        }
        guard !isCloudOnly(path) else {
            return .refused("Not downloaded — the preview won’t fetch it.")
        }
        let target = (path as NSString).resolvingSymlinksInPath
        let size = (try? fileManager.attributesOfItem(atPath: target))?[.size] as? NSNumber
        if let bytes = size?.intValue, bytes > maxBytes {
            return .refused("Too large to draw (\(FileSyncManager.formatBytes(bytes))).")
        }
        return .local(path)
    }
}
