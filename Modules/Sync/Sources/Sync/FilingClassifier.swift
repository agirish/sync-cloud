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

    public init(filePath: String, fileName: String, ext: String, year: String?, contentSnippet: String?) {
        self.filePath = filePath
        self.fileName = fileName
        self.ext = ext
        self.year = year
        self.contentSnippet = contentSnippet
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

/// The seam the app injects. Classifies a batch of files against the folder taxonomy (folder paths
/// relative to the provider root). Returns a verdict per `filePath`; an absent key means the backend
/// declined (no confident home), so that file falls back to the heuristic engine's suggestion.
/// Runs off the main actor and should honor task cancellation.
public typealias FilingClassifier =
    @Sendable (_ taxonomyFolders: [String], _ files: [FilingCandidateFile]) async -> [String: FilingVerdict]
