import Foundation
@testable import Sync

/// One shape for the `"a/b/c"` fixture trees the tree-reading suites are written against, so
/// ``PersonCandidatesTests``, ``JurisdictionCandidatesTests`` and the setup walk agree on what a
/// tree is (node ids are whole paths). Folders only unless files are asked for: a fixture that
/// carried files by default is one a folder-name rule could pass by reading the wrong thing.
enum FixtureTree {

    /// A folder-only tree. Paths share their parents, and every level is sorted by name.
    static func of(_ paths: [String], root: String = "/root") -> [FileNode] {
        of(folders: paths, files: [], root: root)
    }

    /// A tree whose `folders` are directories and whose `files` are leaves.
    ///
    /// A file path's last component is the file; everything before it is folders, created whether
    /// or not `folders` names them. Every file gets the same size and stamp, since no rule reading
    /// these trees compares two files.
    static func of(folders: [String], files: [String], root: String = "/root",
                   fileSize: Int = 1_024,
                   modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> [FileNode] {
        final class Box {
            var children: [String: Box] = [:]
            var files: Set<String> = []
            func child(_ name: String) -> Box {
                if let existing = children[name] { return existing }
                let made = Box(); children[name] = made; return made
            }
        }
        let top = Box()
        for path in folders {
            var here = top
            for component in path.split(separator: "/") { here = here.child(String(component)) }
        }
        for path in files {
            let components = path.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            var here = top
            for component in components.dropLast() { here = here.child(component) }
            here.files.insert(name)
        }
        func nodes(_ box: Box, prefix: String) -> [FileNode] {
            let directories = box.children.keys.sorted().map { name -> FileNode in
                let path = prefix + "/" + name
                return FileNode(id: path, name: name, isDirectory: true,
                                children: nodes(box.children[name]!, prefix: path))
            }
            let leaves = box.files.sorted().map { name in
                FileNode(id: prefix + "/" + name, name: name, isDirectory: false,
                         modificationDate: modified, fileSize: fileSize)
            }
            return directories + leaves
        }
        return nodes(top, prefix: root)
    }
}
