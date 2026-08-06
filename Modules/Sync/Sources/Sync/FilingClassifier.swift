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

    public init(relativePath: String, confidence: FilingConfidence, reason: String) {
        self.relativePath = relativePath
        self.confidence = confidence
        self.reason = reason
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

/// The seam the app injects. Classifies a batch of files against the folder taxonomy (folder paths
/// relative to the provider root). Returns a verdict per `filePath`; an absent key means the backend
/// declined (no confident home), so that file falls back to the heuristic engine's suggestion.
/// Runs off the main actor and should honor task cancellation.
///
/// **`tier` is a constraint on the implementation, not a hint.** An implementation that reaches a
/// paid backend for `.free` breaks the guarantee every free-pass caller relies on; `Sync` checks
/// the app's own routing answer for `.free` before classifying (see
/// ``FileSyncManager/freePassWouldReachAPaidBackend``) rather than taking it on trust, but the
/// contract lives here.
public typealias FilingClassifier =
    @Sendable (_ taxonomyFolders: [String], _ files: [FilingCandidateFile],
               _ tier: FilingClassifierTier) async -> [String: FilingVerdict]
