import Foundation
import FileExplorer

/// **Text files on disk for tests — and gone when the test process is.**
///
/// Five suites carried a copy of the same `document(named:)`: make a folder under
/// `NSTemporaryDirectory()`, write the file, load it. None removed the folder, so every run left
/// one per call behind — hundreds a run, across the render suites that call it in loops. Here
/// every file is made under ONE folder per test process, removed when the process exits; a process
/// that died before it could (a crash, a killed run) has its folder swept by the next process to
/// make a file, once its pid is gone.
///
/// Each call still gets a folder of its own, so a test that lists a document's folder sees only
/// its own file.
public enum TestTextFiles {

    /// The per-process folder. Its first read sweeps dead processes' folders and arranges for this
    /// one to be removed at exit.
    public static let root: String = {
        let base = NSTemporaryDirectory()
        sweepFoldersOfExitedProcesses(in: base)
        let root = (base as NSString).appendingPathComponent("\(prefix)\(getpid())")
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(atPath: TestTextFiles.root) }
        return root
    }()

    static let prefix = "SyncCloudTestTextFiles-"

    /// Writes `text` as `name` in a fresh folder under ``root``, and returns the file's path.
    public static func write(_ text: String = "hello", named name: String) throws -> String {
        let folder = (root as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent(name)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// An `EditorDocument` loaded from a fresh file named `name` holding `text`.
    @MainActor
    public static func document(named name: String, text: String = "hello") throws -> EditorDocument {
        let path = try write(text, named: name)
        let document = EditorDocument()
        _ = EditorFileStore.load(path: path, into: document)
        return document
    }

    /// Removes each `<prefix><pid>` folder whose process no longer exists. A live pid's folder is
    /// never touched — another package's tests may be running beside this one.
    static func sweepFoldersOfExitedProcesses(in base: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        for name in names where name.hasPrefix(prefix) {
            guard let pid = pid_t(name.dropFirst(prefix.count)), pid != getpid() else { continue }
            if kill(pid, 0) == -1, errno == ESRCH {
                try? FileManager.default.removeItem(atPath: (base as NSString).appendingPathComponent(name))
            }
        }
    }
}
