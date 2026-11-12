import Events
import Foundation

/// Filing help for Ask Claude: "where should this go?" for one file, answered from the Filing
/// profile with the router To File uses. Free, on this Mac, no model call.
///
/// The same evidence To File has: the profile's folders, memory and person registry, the file's
/// name and page 1, then the cross-person rule. Two differences on purpose: a folder the caller
/// says is hidden is dropped before ranking, so it is never named, not even as a runner-up; and
/// there is no keyword engine, since the answer promises the person's own conventions, so with no
/// profile it says so.
public struct FilingHelpAnswer: Sendable, Equatable {

    public enum Outcome: Sendable, Equatable {
        /// Best first; a runner-up only when the best isn't High.
        case suggested([Suggestion])
        /// No Filing profile: Setup's survey never ran.
        case noProfile
        /// The place they named isn't under the folder the profile surveyed, absolute: the caller
        /// names it by source, since an answer to Claude never carries an absolute path. Where the
        /// file itself sits doesn't matter: a file in Downloads is placed like any other.
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
        /// They named a place and this folder isn't in it: kept because the file plainly belongs
        /// here.
        public let outsidePlace: Bool
        /// Not made yet: a folder named like its siblings (TE327), made on the card with the move.
        public let isNew: Bool
        /// For a new folder, the siblings it is named like.
        public let siblings: [String]
        /// What chose it, for the filing scorecard (TE341): a saved rule, or the survey by name
        /// or by page 1.
        public var evidence: FilingScorecard.Evidence

        public init(folder: String, relativePath: String, confidence: FilingConfidence, reason: String,
                    evidenceToken: String?, outsidePlace: Bool = false, isNew: Bool = false, siblings: [String] = []) {
            self.evidence = evidenceToken == nil ? .survey : .page
            self.folder = folder
            self.relativePath = relativePath
            self.confidence = confidence
            self.reason = reason
            self.evidenceToken = evidenceToken
            self.outsidePlace = outsidePlace
            self.isNew = isNew
            self.siblings = siblings
        }
    }

    public let outcome: Outcome
    /// When the profile's folders were surveyed; nil when unknown.
    public let surveyedAt: Date?
    /// The best folder's siblings, when they are plain names and no dated folder was offered:
    /// Claude may name a new one like them (decision JG).
    public let namedSiblings: FilingNewHome.NamedSiblings?
    /// The survey's root the answer came from, for the scorecard's area.
    public let root: String?

    public init(outcome: Outcome, surveyedAt: Date?, namedSiblings: FilingNewHome.NamedSiblings? = nil,
                root: String? = nil) {
        self.root = root
        self.outcome = outcome
        self.surveyedAt = surveyedAt
        self.namedSiblings = namedSiblings
    }

    /// Days since the survey, counted as Restructure counts them: calendar days, midnight to
    /// midnight, so the two agree about the same survey. Nil when its date is unknown.
    public func surveyAgeDays(now: Date, calendar: Calendar = .current) -> Int? {
        guard let surveyedAt else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: surveyedAt),
                                       to: calendar.startOfDay(for: now)).day
    }

    /// 21 days or more, the age at which Restructure calls a survey stale. Unknown is not stale.
    public func isStale(now: Date, calendar: Calendar = .current) -> Bool {
        (surveyAgeDays(now: now, calendar: calendar) ?? 0) >= 21
    }
}

extension FileSyncManager {

    /// Where `path` would go, from the active Filing profile. The file may be anywhere on this
    /// Mac; only the destination has to be in the survey. `snippet` is page 1 as read on this Mac
    /// (nil ranks by name alone); `place`, absolute, is a folder they named ("into Travel"), whose
    /// folders are preferred; `isHidden` is the Never show Claude list.
    ///
    /// The survey follows the source: a file in a source with its own survey (Google Drive) is
    /// answered and placed from that survey, anything else from the primary one. A named place
    /// decides first, so "into Finance in iCloud" about a Google Drive file is answered from iCloud's.
    /// `quiet` logs nothing per file: Ask Claude's look-ahead asks about 50 at a time (TE343).
    public func whereToFile(_ path: String, snippet: String?, preferring place: String? = nil, quiet: Bool = false,
                            isHidden: (String) -> Bool) async -> FilingHelpAnswer {
        func log(_ line: @autoclosure () -> String) { if !quiet { Logger.shared.info(line()) } }
        guard let survey = filingHelpSurvey(for: place ?? path) else {
            return FilingHelpAnswer(outcome: .noProfile, surveyedAt: filingSurveyedAt)
        }
        let (profile, root, surveyedAt) = (survey.profile, survey.root, survey.surveyedAt)
        let placeRelative: String?
        if let place {
            guard let relative = Self.relative(place, toRoot: root) else {
                return FilingHelpAnswer(outcome: .outsideProfile(surveyed: root), surveyedAt: surveyedAt)
            }
            placeRelative = relative.isEmpty ? nil : relative
        } else {
            placeRelative = nil
        }
        // His saved rules lead, as in To File: a rule taught in this chat answers the next file
        // like it.
        if let ruled = ruleAnswer(path, snippet: snippet, root: root, profile: profile, isHidden: isHidden),
           placeRelative.map({ Self.isAtOrUnder(ruled.relativePath, $0) }) ?? true {
            log("Filing help: “\((path as NSString).lastPathComponent)” → \(ruled.relativePath) by a saved rule")
            return FilingHelpAnswer(outcome: .suggested([ruled]), surveyedAt: surveyedAt, root: root)
        }
        let registry = filingPersonRegistry
        let index = await filingHelpIndex(survey, isHidden: isHidden)
        let fileName = (path as NSString).lastPathComponent
        let ranking = await Task.detached(priority: .userInitiated) {
            // Deeper with a place named, so its folders are among the ranked even when others lead.
            let ranked = FilingRouter.rank(fileName: fileName, contentSnippet: snippet, index: index,
                                           limit: placeRelative == nil ? 5 : 12)
            // The scan's peer-name rerank too (a folder against its own subfolder), so this and
            // To File agree about the same file.
            let peers = PeerNameCache()
            let reranked = FilingRouter.rerankedByPeerNames(ranked, fileName: fileName) { peers.names(in: root + "/" + $0) }
            return Self.preferring(reranked, under: placeRelative)
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
            log("Filing help: every home for “\(fileName)” was someone else’s folder")
            return FilingHelpAnswer(outcome: .noMatch, surveyedAt: surveyedAt)
        }
        let shown = kept.prefix(confidence == .high ? 1 : 2).map { dest in
            let relative = String(dest.path.dropFirst(root.count + 1))
            return FilingHelpAnswer.Suggestion(folder: dest.path, relativePath: relative,
                                               confidence: confidence, reason: dest.reasons.first ?? "",
                                               evidenceToken: dest.evidenceToken,
                                               outsidePlace: placeRelative.map { !Self.isAtOrUnder(relative, $0) } ?? false)
        }
        log("Filing help: “\(fileName)” → \(shown.map(\.relativePath).joined(separator: ", ")) (\(confidence.rawValue)\(snippet == nil ? ", by name" : ""))")
        // TE327: a new folder named like its siblings leads, the closest folder second, whatever
        // its confidence (decision JH). Inside a named place when there is one.
        let base = placeRelative.map { root + "/" + $0 } ?? root
        let children = { [profile] (folder: String) in Self.childFolders(folder, root: root, profile: profile) }
        // Two folders and their parents listed, here: the hidden list's matcher stays on this actor.
        let newHome = FilingNewHome.dated(fileName: fileName, candidates: kept.prefix(2).map(\.path), within: base,
                                          childFolders: children, exists: { FileManager.default.fileExists(atPath: $0) },
                                          isHidden: isHidden)
        if let newHome, let best = shown.first {
            let relative = String(newHome.path.dropFirst(root.count + 1))
            log("Filing help: a new folder \(relative) for “\(fileName)”, named like its siblings")
            // It is made in or beside the folder it was found by, so a folder picked by a word
            // read from the file passes that word on: its path says what the file holds.
            let besideFolder = kept.prefix(2).first { [$0.path, ($0.path as NSString).deletingLastPathComponent].contains(newHome.parent) }
            let made = FilingHelpAnswer.Suggestion(folder: newHome.path, relativePath: relative, confidence: .medium,
                                                   reason: newHome.reason, evidenceToken: besideFolder?.evidenceToken, isNew: true,
                                                   siblings: newHome.siblings)
            return FilingHelpAnswer(outcome: .suggested([made, best]), surveyedAt: surveyedAt, root: root)
        }
        let named = shown.first.flatMap { best in
            FilingNewHome.named(parent: (best.folder as NSString).deletingLastPathComponent, within: base,
                                childFolders: children, isHidden: isHidden)
        }
        return FilingHelpAnswer(outcome: .suggested(Array(shown)), surveyedAt: surveyedAt, namedSiblings: named,
                                root: root)
    }

    /// The folders in `folder`: the survey's, and those on disk now (made since, or never surveyed).
    nonisolated static func childFolders(_ folder: String, root: String, profile: FolderProfile) -> [String] {
        var names = Set<String>()
        if let relative = relative(folder, toRoot: root) {
            for key in profile.folders.keys {
                let parent = (key as NSString).deletingLastPathComponent
                if parent == relative { names.insert((key as NSString).lastPathComponent) }
            }
        }
        let url = URL(fileURLWithPath: folder)
        let listed = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        for item in listed {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true, values?.isPackage != true { names.insert(item.lastPathComponent) }
        }
        return names.sorted()
    }

    /// The survey's router index for filing help, its hidden folders left out, kept per survey.
    func filingHelpIndex(_ survey: (profile: FolderProfile, memory: FilingMemory?, root: String, surveyedAt: Date?),
                         isHidden: (String) -> Bool) async -> FilingRouter.Index {
        let (profile, root, memory, registry) = (survey.profile, survey.root, survey.memory, filingPersonRegistry)
        // The satellite map is the primary survey's tree, and only when the last To File scan
        // built it for that tree: after a Dropbox scan it names Dropbox's folders, and the same
        // relative paths in iCloud would be demoted as copies. A source's own survey has none.
        let satellites = survey.profile.profileId == filingFolderProfile?.profileId
            && filingSatelliteRoot.map({ SourceSurveyStore.sameFolder($0, root) }) == true ? filingSatelliteHomes : [:]
        // Asked here, once per folder: the list's matcher reads the disk and stays on this actor.
        let hidden = Set(profile.folders.keys.filter { isHidden(root + "/" + $0) })
        let key = FilingHelpIndexCache.Key(profileId: profile.profileId,
                                           generation: filingHelpStamp(memory: memory, surveyedAt: survey.surveyedAt,
                                                                       satellites: satellites),
                                           hidden: hidden)
        return await Task.detached(priority: .userInitiated) {
            FilingHelpIndexCache.shared.index(for: key) {
                // Hidden folders never enter the index: a folder that can't be ranked can't be named.
                let destinations = profile.folders.keys.filter { !hidden.contains($0) }
                return FilingRouter.makeIndex(destinations: Array(destinations), profile: profile,
                                              memory: memory, registry: registry, satelliteHomes: satellites)
            }
        }.value
    }

    /// A named place's folders first: prefer it, allow others. A High answer outside it stands,
    /// since that file plainly belongs elsewhere (a W-2 asked into Travel); otherwise the place's
    /// best folder leads, with the margin taken against the strongest of the rest, so a stronger
    /// folder outside makes the answer unsure rather than vanishing.
    nonisolated static func preferring(_ ranking: FilingRouter.Ranking, under place: String?) -> FilingRouter.Ranking {
        guard let place, ranking.confidence != .high else { return ranking }
        let inside = ranking.candidates.filter { isAtOrUnder($0.relativePath, place) }
        guard let top = inside.first else { return ranking }
        let ordered = inside + ranking.candidates.filter { !isAtOrUnder($0.relativePath, place) }
        return FilingRouter.Ranking(candidates: ordered,
                                    margin: FilingRouter.margin(top: top.score, runnerUp: ordered.dropFirst().map(\.score).max()))
    }

    /// `relative` is `place` or a folder inside it, ignoring case as the volume does.
    nonisolated static func isAtOrUnder(_ relative: String, _ place: String) -> Bool {
        let r = relative.lowercased(), p = place.lowercased()
        return r == p || r.hasPrefix(p + "/")
    }

    /// `path` relative to `root`: "" for the root itself, nil when it isn't at or under it, in
    /// either spelling of a link on the way.
    nonisolated static func relative(_ path: String, toRoot root: String) -> String? {
        func real(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        for (p, r) in [(path, root), (real(path), real(root))] {
            if p == r { return "" }
            if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        }
        return nil
    }

    /// `path` is the surveyed folder or inside it, either spelling of a link on the way.
    public nonisolated static func isAtOrUnderSurvey(_ path: String, root: String) -> Bool {
        relative(path, toRoot: root) != nil
    }

    /// A folder of the survey by what they called it: its path from the surveyed folder ("Travel/
    /// Trips", with or without the surveyed folder's own name in front), else the shallowest
    /// folder with that name. Absolute; nil when the survey has none.
    public func filingSurveyFolder(named name: String) -> String? {
        guard let profile = filingFolderProfile, let root = profile.recordedFolderPath else { return nil }
        var wanted = name.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
        let rootName = (root as NSString).lastPathComponent.lowercased()
        if wanted == rootName { return root }
        if wanted.hasPrefix(rootName + "/") { wanted = String(wanted.dropFirst(rootName.count + 1)) }
        guard !wanted.isEmpty else { return nil }
        let folders = profile.folders.keys
        if let exact = folders.first(where: { $0.lowercased() == wanted }) { return root + "/" + exact }
        let named = folders.filter { ($0 as NSString).lastPathComponent.lowercased() == wanted }
            .sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
        return named.first.map { root + "/" + $0 }
    }

    /// To File's sentences, so the card and Organize say the same thing about the same folder.
    nonisolated static func reason(_ candidate: FilingRouter.Candidate) -> String {
        candidate.evidenceToken.map { "Matched “\($0.capitalized)” read from the file — a word this folder’s documents use" }
            ?? "Fits how this folder is used"
    }

    /// Changes whenever the profile, memory or registry is replaced, so a cached index never
    /// answers for an older survey.
    var filingHelpProfileStamp: Int {
        var hasher = Hasher()
        hasher.combine(filingProfileDirectoryId)
        hasher.combine(filingSurveyedAt)
        // The folders themselves, not their counts: two surveys of the same size are not the same
        // survey. Thousands of short strings, well under a millisecond.
        for folder in (filingFolderProfile?.folders.keys).map({ $0.sorted() }) ?? [] { hasher.combine(folder) }
        Self.combine(filingMemory, into: &hasher)
        hasher.combine(filingPersonRegistry == nil)
        return hasher.finalize()
    }

    /// ``filingHelpProfileStamp`` plus what the survey answering this question brings: a source's
    /// own survey changes when its documents are read (its memory and date), which the primary
    /// survey's stamp never sees; and the satellite map, which moves with each To File scan.
    func filingHelpStamp(memory: FilingMemory?, surveyedAt: Date?, satellites: [String: Set<String>]) -> Int {
        var hasher = Hasher()
        hasher.combine(filingHelpProfileStamp)
        hasher.combine(surveyedAt)
        Self.combine(memory, into: &hasher)
        for (satellite, homes) in satellites.sorted(by: { $0.key < $1.key }) {
            hasher.combine(satellite)
            hasher.combine(homes.sorted())
        }
        return hasher.finalize()
    }

    private static func combine(_ memory: FilingMemory?, into hasher: inout Hasher) {
        hasher.combine(memory?.profileId)
        for (folder, entry) in (memory?.folders ?? [:]).sorted(by: { $0.key < $1.key }) {
            hasher.combine(folder)
            hasher.combine(entry.docs)
        }
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

    /// Page 1 of a file for filing help, read on this Mac the way To File reads it: nil when
    /// Organize's "read contents" is off or no reader is set.
    public func filingHelpPage(_ path: String, light: Bool = false) async -> String? {
        guard filingReadsContents, let extract = light ? filingLightSnippetExtractor : filingSnippetExtractor else { return nil }
        return await extract(path)
    }

    /// Whether filing help may read page 1 at all (Organize's "read contents"), asked again on
    /// every use of a page already read, so turning it off stops a kept page counting.
    public var filingHelpReadsPages: Bool { filingReadsContents }

    /// Whether filing help's card may offer Refine with Claude: Organize's own rule for showing its
    /// Refine button.
    public var filingHelpCanRefine: Bool { filingCloudRefineAvailable && filingUsesAI && filingClassifier != nil }

    /// Refine with Claude for one file, from filing help's card, after the Organize scan of its
    /// folder that the card's button started. Organize's own pass on this file alone. The app does
    /// not call this (its click is Send on a plan card in the chat); it stays for hosts without one.
    public func refineAfterScan(filePath: String) async -> FilingRefineSummary? {
        guard let suggestion = await suggestionAfterScan(filePath: filePath) else { return nil }
        return await refineFilingSuggestions([suggestion])
    }

    /// The card for `filePath` once the Organize scan of its folder has finished, for the chat to
    /// make a Refine plan for (TE335); nil when the scan found none.
    public func suggestionAfterScan(filePath: String) async -> FilingSuggestion? {
        await latestFilingScan()
        guard let suggestion = filingSuggestions.first(where: { $0.filePath == filePath }) else {
            Logger.shared.info("Filing help: Refine found no card for “\((filePath as NSString).lastPathComponent)” after the scan")
            return nil
        }
        return suggestion
    }

    /// The cards for `filePaths` once the Organize scan of their folder has finished, for Refine
    /// on a selection card (TE342), in no order; files the scan found no card for are left out.
    public func suggestionsAfterScan(filePaths: [String]) async -> [FilingSuggestion] {
        await latestFilingScan()
        let wanted = Set(filePaths)
        let found = filingSuggestions.filter { wanted.contains($0.filePath) }
        if found.count < wanted.count {
            Logger.shared.info("Filing help: Refine found cards for \(found.count) of \(wanted.count) files after the scan")
        }
        return found
    }

    /// Returns once the latest Organize scan has finished, not only the one running when this was
    /// called: a scan started meanwhile replaces it, and its cards are the ones on screen.
    func latestFilingScan() async {
        var awaited: Task<Void, Never>?
        while let scan = filingScanTask, scan != awaited {
            awaited = scan
            await scan.value
        }
    }
}
