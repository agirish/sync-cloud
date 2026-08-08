import Foundation

/// A loose file handed to an intelligent Filing backend (on-device LLM, opt-in cloud, …) for
/// classification against the provider's folder taxonomy. Pure data — no model dependency, so the
/// Sync module stays UI/framework-free and the backend is injected by the app.
public struct FilingCandidateFile: Sendable, Equatable, Identifiable {
    /// Absolute path — the file's identity and the key verdicts come back under.
    public let filePath: String
    public var id: String { filePath }
    public let fileName: String
    public let ext: String
    /// Modification year, if known — a cheap, strong signal for date-organized folders.
    public let year: String?
    /// A bounded excerpt of the file's text (PDF/OCR/plain), or nil when contents weren't read
    /// (read-contents off, evicted iCloud file, unsupported type). The backend may reason from the
    /// name and taxonomy alone when this is nil.
    public let contentSnippet: String?
    /// Folders (relative paths) the user has already rejected for this file — the backend must not
    /// suggest them again. Empty on a normal scan; populated on a "Try another" re-ask.
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
    /// Destination folder as a path **relative to the provider root** (e.g. "Documents/Family/Divit").
    /// May name an existing folder or propose a new sub-path under an existing parent. Empty ⇒ the
    /// backend had no confident home (the file keeps its heuristic suggestion, if any).
    public let relativePath: String
    public let confidence: FilingConfidence
    public let reason: String
    /// The backend's own statement that this path names a folder that does not exist yet.
    ///
    /// **Declared, not inferred.** Both schemas allow answering with a new subfolder — that is how
    /// a genuinely new destination gets proposed — and until this existed, "a path not on the list"
    /// was the only expression of it. So a deliberate proposal and an invented path segment were
    /// the same signal, and nothing downstream could tell them apart. Asked where
    /// `Divit - eOCI.pdf` belonged, the on-device model answered
    /// `Immigration/OCI/Divit/eOCI.pdf` — splitting the FILE'S OWN NAME into a folder and a child,
    /// while its reason called the result an "existing folder … containing the eOCI.pdf file". It
    /// could not have known that file exists: the folder list it is shown holds directories only,
    /// and this PDF has no text layer, so there was no excerpt either. Both halves of the sentence
    /// were invented, and a folder called `eOCI.pdf` was created on disk.
    ///
    /// With the claim made explicit, an undeclared new segment is detectable — see
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

/// Which backends a classification call is allowed to reach.
///
/// Organize runs in two passes, and the difference between them is **not** a quality setting the
/// user tunes — it is which backends are permitted to answer, and therefore whether the pass can
/// cost money. The tier is what carries that permission from the caller to the app's router, so
/// "this pass is free" is a property of the call rather than a promise about the state of a
/// toggle somewhere. That distinction is the whole point: the previous design gated an
/// auto-started scan by *inspecting* settings and the verdict cache to predict whether cloud
/// would be reached, and the prediction disagreed with the router in an ordinary state (cloud on,
/// no readable key), which put a payment dialog in front of a scan that was going to be free.
public enum FilingClassifierTier: Sendable, Equatable {
    /// The pass every scan runs. **On-device backends only** — a backend that bills the user must
    /// never be reached here, whatever the cloud toggle says. Because no scan can spend at this
    /// tier, no scan needs a spend pre-flight, and an auto-started rescan is free by construction
    /// rather than by a check that has to agree with the router.
    case free
    /// The opt-in second pass, reached only by an explicit click on the results. May use the cloud
    /// (Claude) backend when the user has enabled it and stored a key, and falls back to the
    /// on-device model when it can't. This is the only tier at which Organize can spend money.
    case refine
}

/// What a backend gets to reason about: the taxonomy, and what the app has learned about it.
///
/// This replaced a bare `[String]` of folder paths. The paths are still the contract — a verdict
/// names one of them — but a backend handed only paths has to re-derive per file the facts that are
/// stable properties of the tree, and the on-device tier, which has the least room to reason, got
/// the least help.
///
/// Both learned parts are **optional and per-tree**. Nothing here ships with a default: a context
/// with no profile and no memory is exactly the input backends received before this existed, which
/// is what makes the whole thing additive.
public struct FilingContext: Sendable {
    /// Destination folders, relative to the provider root. Still the vocabulary a verdict must
    /// answer in.
    public let taxonomyFolders: [String]
    /// What each folder *is* — role, axes, naming convention, and whether it may receive files.
    public let profile: FolderProfile?
    /// What each folder has *received* — the discriminative content already filed in it.
    public let memory: FilingMemory?

    public init(taxonomyFolders: [String], profile: FolderProfile? = nil, memory: FilingMemory? = nil) {
        self.taxonomyFolders = taxonomyFolders
        self.profile = profile
        self.memory = memory
    }

    /// Folders that may actually receive a file. **A backend must route into this, not into
    /// `taxonomyFolders`** — 138 of one tree's folders are inboxes, and listing an inbox among
    /// destinations actively teaches a classifier to file into the very place the user put things
    /// when they had nowhere to put them.
    /// The same rule the router applies, asked the same way — a profile when there is one, the
    /// name rule when there is not. Answering it two different ways in two places is how one of
    /// them ends up offering `TODO` as a home.
    public var destinations: [String] {
        taxonomyFolders.filter { profile?.acceptsNewFiles($0) ?? !FolderProfile.isInboxPath($0) }
    }
}

/// The seam the app injects. Classifies a batch of files against the folder taxonomy. Returns a
/// verdict per `filePath`; an absent key means the backend declined (no confident home), so that
/// file falls back to the heuristic engine's suggestion. Runs off the main actor and should honor
/// task cancellation.
///
/// **`tier` is a constraint on the implementation, not a hint.** An implementation that reaches a
/// paid backend for `.free` breaks the guarantee every free-pass caller relies on; `Sync` checks
/// the app's own routing answer for `.free` before classifying (see
/// ``FileSyncManager/freePassWouldReachAPaidBackend``) rather than taking it on trust, but the
/// contract lives here.
public typealias FilingClassifier =
    @Sendable (_ context: FilingContext, _ files: [FilingCandidateFile],
               _ tier: FilingClassifierTier) async -> [String: FilingVerdict]
