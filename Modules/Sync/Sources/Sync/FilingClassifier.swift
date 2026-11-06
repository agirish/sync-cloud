import Foundation

/// A loose file handed to an intelligent Filing backend (on-device LLM, opt-in cloud) to classify
/// against the provider's folder taxonomy. Pure data, so Sync stays framework-free and the app
/// injects the backend.
public struct FilingCandidateFile: Sendable, Equatable, Identifiable {
    /// Absolute path: the file's identity and the key its verdict comes back under.
    public let filePath: String
    public var id: String { filePath }
    public let fileName: String
    public let ext: String
    /// Modification year, if known: a cheap, strong signal for date-organized folders.
    public let year: String?
    /// A bounded excerpt of the file's text (PDF, OCR, plain), or nil when it wasn't read (contents
    /// off, evicted iCloud file, unsupported type). The backend then reasons from name and
    /// taxonomy.
    public let contentSnippet: String?
    /// Folders (relative paths) the user already rejected for this file, which the backend must not
    /// suggest again. Empty on a normal scan; filled on a "Try another" re-ask.
    public let excludedRelativePaths: [String]

    public init(filePath: String, fileName: String, ext: String, year: String?, contentSnippet: String?,
                excludedRelativePaths: [String] = []) {
        self.filePath = filePath
        self.fileName = fileName
        self.ext = ext
        self.year = year
        self.contentSnippet = contentSnippet
        self.excludedRelativePaths = excludedRelativePaths
    }
}

/// A backend's verdict for one file.
public struct FilingVerdict: Sendable, Equatable {
    /// Destination folder relative to the provider root (e.g. "Documents/Family/Son"). May name an
    /// existing folder or a new sub-path under an existing parent. Empty means no confident home,
    /// and the file keeps its heuristic suggestion, if any.
    public let relativePath: String
    public let confidence: FilingConfidence
    public let reason: String
    /// The backend's own statement that this path names a folder that doesn't exist yet. Declared,
    /// not inferred: both schemas allow a new subfolder, so without this a deliberate proposal and
    /// an invented segment (a model splitting the file's own name into a folder) look the same.
    /// With it, an undeclared new segment is detectable; see
    /// ``FilingEngine/applyVerdicts(_:to:existingRelative:providerRoot:rejectedByFile:contentBlind:routerShortlists:)``.
    public let proposesNewFolder: Bool

    public init(relativePath: String, confidence: FilingConfidence, reason: String,
                proposesNewFolder: Bool = false) {
        self.relativePath = relativePath
        self.confidence = confidence
        self.reason = reason
        self.proposesNewFolder = proposesNewFolder
    }

    /// Confidence from a 0–100 score, the shape guided-generation models return.
    public static func confidence(fromScore score: Int) -> FilingConfidence {
        score >= 80 ? .high : (score >= 50 ? .medium : .low)
    }
}

/// Which backends a classification call may reach. Organize's two passes differ not in quality but
/// in whether they can cost money, and the tier carries that permission from caller to router, so
/// "this pass is free" is a property of the call, not a prediction from settings that could
/// disagree with the router and put a payment dialog in front of a free scan.
public enum FilingClassifierTier: Sendable, Equatable {
    /// The pass every scan runs: **on-device backends only**. A billing backend must never be
    /// reached here, whatever the cloud toggle says, so no scan needs a spend pre-flight and an
    /// auto-started rescan is free by construction.
    case free
    /// The opt-in second pass, reached only by an explicit click on the results. May use the cloud
    /// (Claude) backend when enabled with a stored key, else the on-device model. The only tier at
    /// which Organize can spend money.
    case refine
}

/// What a backend reasons about: the taxonomy, and what the app has learned about it. The folder
/// paths are still the contract (a verdict names one); the learned parts save a backend from
/// re-deriving per file what is stable about the tree. Both are optional and per-tree, with no
/// default: a context with neither is a bare taxonomy.
public struct FilingContext: Sendable {
    /// Destination folders, relative to the provider root: the vocabulary a verdict answers in.
    public let taxonomyFolders: [String]
    /// What each folder *is*: role, axes, naming convention, and whether it may receive files.
    public let profile: FolderProfile?
    /// What each folder has *received*: the discriminative content already filed in it.
    public let memory: FilingMemory?

    public init(taxonomyFolders: [String], profile: FolderProfile? = nil, memory: FilingMemory? = nil) {
        self.taxonomyFolders = taxonomyFolders
        self.profile = profile
        self.memory = memory
    }

    /// Folders that may actually receive a file. **A backend must route into this, not
    /// `taxonomyFolders`**: listing an inbox as a destination teaches a classifier to file into the
    /// place the user puts things that have no home. Asked the same way the router asks it (the
    /// profile if there is one, else the name rule), so the two can't disagree.
    public var destinations: [String] {
        taxonomyFolders.filter { profile?.acceptsNewFiles($0) ?? !FolderProfile.isInboxPath($0) }
    }
}

/// The seam the app injects. Classifies a batch of files against the taxonomy and returns a verdict
/// per `filePath`; a missing key means the backend declined, and that file keeps the heuristic
/// engine's suggestion. Runs off the main actor and should honor task cancellation.
///
/// **`tier` is a constraint, not a hint.** Reaching a paid backend for `.free` breaks the guarantee
/// every free-pass caller relies on. `Sync` also checks the app's routing answer for `.free` before
/// classifying (``FileSyncManager/freePassWouldReachAPaidBackend``), but the contract lives here.
public typealias FilingClassifier =
    @Sendable (_ context: FilingContext, _ files: [FilingCandidateFile],
               _ tier: FilingClassifierTier) async -> [String: FilingVerdict]
