import Events
import Foundation

/// Filing help for Ask Claude (TE255): "where should this go?" for one file, answered from the
/// Filing profile with the router Organize's To File uses — free, on this Mac, no model call.
///
/// **The same evidence To File has**: the profile's folders, its memory and person registry, the
/// file's name and page 1 (decision EW), then the cross-person rule. Two things differ on purpose:
/// a folder the caller says is hidden is dropped before ranking, so it can never be named (not even
/// as a runner-up); and there is no keyword engine behind it, because the answer promises to come
/// from the person's own conventions (decision EX), so with no profile it says so instead.
public struct FilingHelpAnswer: Sendable, Equatable {

    public enum Outcome: Sendable, Equatable {
        /// Best first; a runner-up only when the best isn't High (decision EZ).
        case suggested([Suggestion])
        /// No Filing profile: Setup's survey never ran.
        case noProfile
        /// The file isn't under the folder the profile surveyed, which is named.
        case outsideProfile(surveyed: String)
        /// The profile has no folder that fits this file.
        case noMatch
    }

    public struct Suggestion: Sendable, Equatable {
        /// The folder, absolute, in the profile's own spelling.
        public let folder: String
        /// Relative to the surveyed folder, "Taxes/2025".
        public let relativePath: String
        public let confidence: FilingConfidence
        /// The reason the card shows, To File's own sentence.
        public let reason: String
        /// The word read from the file that decided it, when one did.
        public let evidenceToken: String?

        public init(folder: String, relativePath: String, confidence: FilingConfidence, reason: String,
                    evidenceToken: String?) {
            self.folder = folder
            self.relativePath = relativePath
            self.confidence = confidence
            self.reason = reason
            self.evidenceToken = evidenceToken
        }
    }

    public let outcome: Outcome
    /// When the profile's folders were surveyed; nil when unknown.
    public let surveyedAt: Date?

    public init(outcome: Outcome, surveyedAt: Date?) {
        self.outcome = outcome
        self.surveyedAt = surveyedAt
    }

    /// Over 21 days old, the age at which Restructure calls a survey stale.
    public func isStale(now: Date) -> Bool {
        guard let surveyedAt else { return false }
        return now.timeIntervalSince(surveyedAt) >= 21 * 86_400
    }
}

extension FileSyncManager {

    /// Where `path` would go, from the active Filing profile. `snippet` is page 1 as read on this
    /// Mac (nil ranks by name alone); `isHidden` is the Never show Claude list.
    public func whereToFile(_ path: String, snippet: String?, isHidden: (String) -> Bool) async -> FilingHelpAnswer {
        let surveyedAt = filingSurveyedAt
        guard let profile = filingFolderProfile, let root = profile.recordedFolderPath else {
            return FilingHelpAnswer(outcome: .noProfile, surveyedAt: surveyedAt)
        }
        guard Self.isInside(path, root: root) else {
            return FilingHelpAnswer(outcome: .outsideProfile(surveyed: profile.root), surveyedAt: surveyedAt)
        }
        let memory = filingMemory, registry = filingPersonRegistry, satellites = filingSatelliteHomes
        // Asked here, once per folder: the list's matcher reads the disk and stays on this actor.
        let hidden = Set(profile.folders.keys.filter { isHidden(root + "/" + $0) })
        let key = FilingHelpIndexCache.Key(profileId: profile.profileId, generation: filingHelpProfileStamp,
                                           hidden: hidden)
        let index = await Task.detached(priority: .userInitiated) {
            FilingHelpIndexCache.shared.index(for: key) {
                // Hidden folders never enter the index: a folder that can't be ranked can't be named.
                let destinations = profile.folders.keys.filter { !hidden.contains($0) }
                return FilingRouter.makeIndex(destinations: Array(destinations), profile: profile,
                                              memory: memory, registry: registry, satelliteHomes: satellites)
            }
        }.value
        let fileName = (path as NSString).lastPathComponent
        let ranking = await Task.detached(priority: .userInitiated) {
            let ranked = FilingRouter.rank(fileName: fileName, contentSnippet: snippet, index: index, limit: 5)
            // The scan's peer-name rerank too (a folder against its own subfolder), so this and
            // To File agree about the same file.
            let peers = PeerNameCache()
            return FilingRouter.rerankedByPeerNames(ranked, fileName: fileName) { peers.names(in: root + "/" + $0) }
        }.value
        guard !ranking.candidates.isEmpty else {
            return FilingHelpAnswer(outcome: .noMatch, surveyedAt: surveyedAt)
        }
        // The cross-person rule, on the same terms To File applies it: someone else's folder is
        // refused, however well it scored.
        let confidence = ranking.confidence
        let destinations = ranking.candidates.map { candidate in
            FilingDestination(path: root + "/" + candidate.relativePath, base: confidence,
                              evidence: candidate.evidenceToken == nil ? .name : .measuredContent,
                              reasons: [Self.reason(candidate)], newSegments: [],
                              evidenceToken: candidate.evidenceToken?.capitalized)
        }
        let suggestion = FilingSuggestion(filePath: path, fileName: fileName, size: 0, modificationDate: nil,
                                          candidates: destinations, providerRoot: root)
        var pageSamples: [String: String] = [:]
        if let snippet { pageSamples[path] = String(snippet.prefix(FilingRouter.contentSampleChars)) }
        let kept = FilingEngine.refusingCrossPersonHomes(
            [suggestion], providerRoot: root, profile: profile, registry: registry,
            identity: filingPersonIdentity, pageSamples: pageSamples).first?.candidates ?? []
        guard !kept.isEmpty else {
            Logger.shared.info("Filing help: every home for “\(fileName)” was someone else’s folder")
            return FilingHelpAnswer(outcome: .noMatch, surveyedAt: surveyedAt)
        }
        let shown = kept.prefix(confidence == .high ? 1 : 2).map { dest in
            FilingHelpAnswer.Suggestion(folder: dest.path,
                                        relativePath: String(dest.path.dropFirst(root.count + 1)),
                                        confidence: confidence, reason: dest.reasons.first ?? "",
                                        evidenceToken: dest.evidenceToken)
        }
        Logger.shared.info("Filing help: “\(fileName)” → \(shown.map(\.relativePath).joined(separator: ", ")) (\(confidence.rawValue)\(snippet == nil ? ", by name" : ""))")
        return FilingHelpAnswer(outcome: .suggested(Array(shown)), surveyedAt: surveyedAt)
    }

    /// To File's sentences, so the card and Organize say the same thing about the same folder.
    nonisolated static func reason(_ candidate: FilingRouter.Candidate) -> String {
        candidate.evidenceToken.map { "Matched “\($0.capitalized)” read from the file — a word this folder’s documents use" }
            ?? "Fits how this folder is used"
    }

    /// `path` is at or under `root`, in either spelling of a link on the way (iCloud's Documents
    /// is a link to a folder in Mobile Documents).
    nonisolated static func isInside(_ path: String, root: String) -> Bool {
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let candidates = [(path, root), (real(path), real(root))]
        return candidates.contains { p, r in p.hasPrefix(r + "/") }
    }

    /// Changes whenever the profile, memory or registry is replaced, so a cached index never
    /// answers for an older survey.
    var filingHelpProfileStamp: Int {
        var hasher = Hasher()
        hasher.combine(filingProfileDirectoryId)
        hasher.combine(filingSurveyedAt)
        hasher.combine(filingMemory?.profileId)
        // The folders themselves, not their counts: two surveys of the same size are not the same
        // survey. Thousands of short strings, well under a millisecond.
        for folder in (filingFolderProfile?.folders.keys).map({ $0.sorted() }) ?? [] { hasher.combine(folder) }
        for (folder, entry) in (filingMemory?.folders ?? [:]).sorted(by: { $0.key < $1.key }) {
            hasher.combine(folder)
            hasher.combine(entry.docs)
        }
        hasher.combine(filingPersonRegistry == nil)
        return hasher.finalize()
    }
}

/// The router index filing help ranks against, built once per profile and hidden list: building
/// it walks every folder's anchors, which is too slow to repeat per question.
final class FilingHelpIndexCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let profileId: String
        let generation: Int
        /// The profile's folders on the Never show Claude list: the index is rebuilt when they change.
        let hidden: Set<String>
    }

    static let shared = FilingHelpIndexCache()
    private let lock = NSLock()
    private var cached: (key: Key, index: FilingRouter.Index)?

    func index(for key: Key, build: () -> FilingRouter.Index) -> FilingRouter.Index {
        lock.lock()
        if let cached, cached.key == key { lock.unlock(); return cached.index }
        lock.unlock()
        let index = build()
        lock.lock(); cached = (key, index); lock.unlock()
        return index
    }
}

extension FileSyncManager {

    /// Page 1 of a file for filing help, read on this Mac the way To File reads it (decision EW):
    /// nil when Organize's "read contents" is off or no reader is set.
    public func filingHelpPage(_ path: String) async -> String? {
        guard filingReadsContents, let extract = filingSnippetExtractor else { return nil }
        return await extract(path)
    }

    /// Whether filing help's card may offer Refine with Claude (decision EY): Organize's own rule
    /// for showing its Refine button.
    public var filingHelpCanRefine: Bool { filingCloudRefineAvailable && filingUsesAI && filingClassifier != nil }

    /// Refine with Claude for one file, from filing help's card (decision EY), after the Organize
    /// scan of its folder that the card's button started. It is Organize's own pass on this file
    /// alone: the price is shown and agreed to before anything is sent, and the answer lands on
    /// Organize's card. Nil when it didn't run.
    public func refineAfterScan(filePath: String) async -> FilingRefineSummary? {
        await filingScanTask?.value
        guard let suggestion = filingSuggestions.first(where: { $0.filePath == filePath }) else {
            Logger.shared.info("Filing help: Refine found no card for “\((filePath as NSString).lastPathComponent)” after the scan")
            return nil
        }
        return await refineFilingSuggestions([suggestion])
    }
}
