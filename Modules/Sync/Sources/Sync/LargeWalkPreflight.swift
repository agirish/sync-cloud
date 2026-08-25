import Events
import Foundation

/// **What a whole-tree pass found out before committing to it.**
///
/// Handed to `FileSyncManager.largeWalkConfirmer` when a probe walk hits its budget, so the user
/// can decide whether the pass is worth its cost instead of discovering the answer as a wedged app.
public struct LargeWalkPreflight: Sendable, Equatable {

    /// Which pass wants to run. The prompt names it, because "this will take a while" is a
    /// different proposition for a storage reading than for a duplicate hunt.
    public enum Pass: String, Sendable, CaseIterable {
        case storageLens
        case duplicates
        case rename
        case filing

        /// A human name for the prompt. Deliberately the workspace's own vocabulary rather than the
        /// function's: nothing in the UI says "storage lens".
        public var title: String {
            switch self {
            case .storageLens: return "Storage"
            case .duplicates: return "Find Duplicates"
            case .rename: return "Rename"
            case .filing: return "Filing"
            }
        }

        /// Whether this pass reads file CONTENTS past the walk, which is a different order of cost
        /// and the prompt says so. Duplicates hashes every size-colliding file; Filing reads the
        /// first page of documents it cannot place by name.
        public var readsFileContents: Bool {
            switch self {
            case .duplicates, .filing: return true
            case .storageLens, .rename: return false
            }
        }
    }

    public let pass: Pass
    /// The folder the pass would walk.
    public let rootPath: String
    /// The probe's limit, and **the only figure the prompt is allowed to quote** — as "more than",
    /// never as a total, because a probe that stopped cannot know how much it did not see.
    ///
    /// There was an `entriesProbed` beside this, counted with a whole-tree `countItems` at all four
    /// call sites and read by nothing: the prompt is forbidden to print a total, no decision took
    /// it, and a probe stops at its budget so the number was always this one again to within a
    /// directory. A field that costs a walk of the tree to carry no information is worse than
    /// absent, because a reader assumes something consults it.
    public let probeLimit: Int

    public init(pass: Pass, rootPath: String, probeLimit: Int) {
        self.pass = pass
        self.rootPath = rootPath
        self.probeLimit = probeLimit
    }

    /// The folder's display name, for a prompt that should not read as a path dump.
    public var rootName: String {
        let leaf = (rootPath as NSString).lastPathComponent
        return leaf.isEmpty || leaf == "/" ? rootPath : leaf
    }
}
