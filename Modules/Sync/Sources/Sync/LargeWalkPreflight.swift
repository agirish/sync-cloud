import Events
import Foundation

/// What a whole-tree pass found out before committing to it. Handed to
/// `FileSyncManager.largeWalkConfirmer` when a probe walk hits its budget, so the user can decide
/// whether the pass is worth its cost rather than meet a wedged app.
public struct LargeWalkPreflight: Sendable, Equatable {

    /// Which pass wants to run. The prompt names it: a long wait means something different for a
    /// storage reading than for a duplicate hunt.
    public enum Pass: String, Sendable, CaseIterable {
        case storageLens
        case duplicates
        case rename
        case filing

        /// A name for the prompt, in the workspace's own words: nothing in the UI says "storage lens".
        public var title: String {
            switch self {
            case .storageLens: return "Storage"
            case .duplicates: return "Find Duplicates"
            case .rename: return "Rename"
            case .filing: return "Filing"
            }
        }

        /// Whether this pass also reads file contents, a different order of cost the prompt states.
        /// Duplicates hashes every size-colliding file; Filing reads the first page of documents it
        /// cannot place by name.
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
    /// The probe's limit, and the only figure the prompt may quote, as "more than" and never as a
    /// total: a probe that stopped can't know how much it didn't see.
    public let probeLimit: Int

    public init(pass: Pass, rootPath: String, probeLimit: Int) {
        self.pass = pass
        self.rootPath = rootPath
        self.probeLimit = probeLimit
    }

    /// The folder's display name, so the prompt doesn't read as a path. Uses the rule a source is
    /// named by (`FolderSource.defaultDisplayName`), which calls the home folder and the startup
    /// disk, the roots this guard mostly meets, “Home folder” and the volume's own name. Reads one
    /// cached resource value for a path with no last component, nothing otherwise
    /// (`FolderSource.volumeName(of:)`).
    public var rootName: String {
        FolderSource.defaultDisplayName(forPath: rootPath, volumeName: FolderSource.volumeName(of:))
    }
}
