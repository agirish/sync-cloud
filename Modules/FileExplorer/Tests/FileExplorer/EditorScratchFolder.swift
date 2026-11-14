import Foundation
@testable import FileExplorer

/// Scratch folders and opened files for the Edit suites; each test removes its folder in a `defer`.
enum EditorScratchFolder {
    /// A fresh folder in the temporary directory, named `prefix-<UUID>`.
    static func make(_ prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `contents` written to `name` in `folder` and loaded into a new document.
    @MainActor
    static func opened(_ contents: String, named name: String = "note.md",
                       in folder: URL) throws -> (EditorDocument, URL) {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        let document = EditorDocument()
        EditorFileStore.load(path: url.path, into: document)
        return (document, url)
    }
}
