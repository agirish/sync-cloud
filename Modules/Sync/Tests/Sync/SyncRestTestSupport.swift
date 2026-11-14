import Foundation
@testable import Sync

/// A continuation-backed latch: `wait()` suspends until `open()`, without blocking a
/// cooperative-pool thread (see docs/flaky-tests.md, "Every gate parks at once, on the pool their
/// releases need"). Holds an enqueued file operation, say, until the test has looked mid-flight.
actor AsyncLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

extension DuplicateCopy {
    /// A copy for a test, named after its path's last component unless `name` says otherwise.
    static func stub(_ path: String, keeper: Bool, name: String? = nil, isDirectory: Bool = false,
                     size: Int = 1000, itemCount: Int = 1, modified: Date? = nil, unique: Int = 0,
                     depth: Int = 0, protected: Bool = false,
                     snapshot: FolderContentSnapshot? = nil) -> DuplicateCopy {
        DuplicateCopy(id: path, name: name ?? (path as NSString).lastPathComponent, isDirectory: isDirectory,
                      size: size, itemCount: itemCount, modificationDate: modified, uniqueItemCount: unique,
                      depth: depth, isRecommendedKeeper: keeper, isProtectedFromRemoval: protected,
                      contentSnapshot: snapshot)
    }
}

extension DuplicateGroup {
    /// A group over `copies`, named after the first and a folder group when it is one, unless told
    /// otherwise. `reclaimable` defaults to what the copies that aren't the keeper hold.
    static func stub(_ copies: [DuplicateCopy], matchType: DuplicateMatchType = .identical,
                     name: String? = nil, isDirectory: Bool? = nil, reclaimable: Int? = nil) -> DuplicateGroup {
        DuplicateGroup(matchType: matchType, name: name ?? copies.first?.name ?? "",
                       isDirectory: isDirectory ?? copies.first?.isDirectory ?? false, copies: copies,
                       reclaimableBytes: reclaimable
                           ?? copies.filter { !$0.isRecommendedKeeper }.reduce(0) { $0 + $1.size })
    }
}

/// A tree view over a dictionary of folder → (folders, files). A path absent from the dictionary
/// does not exist, which is the distinction the planner's whole-move branch turns on.
func treeView(_ tree: [String: (folders: [String], files: [String])]) -> RestructureTreeView {
    RestructureTreeView(childFolders: { tree[$0]?.folders },
                        files: { tree[$0]?.files },
                        fileCount: { tree[$0]?.files.count })
}

/// A file node for in-memory trees: the path is its id, the last component its name. Suites that
/// need other defaults (the duplicate golden's 100 KB) keep their own, which shadow these.
func file(_ path: String, size: Int = 8192, modified: Date? = nil) -> FileNode {
    FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false,
             modificationDate: modified, fileSize: size)
}

/// A folder node holding `children`, named like ``file(_:size:modified:)``.
func dir(_ path: String, _ children: [FileNode], modified: Date? = nil) -> FileNode {
    FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
             children: children, modificationDate: modified)
}
