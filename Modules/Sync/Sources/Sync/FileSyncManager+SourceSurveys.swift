import Events
import Foundation

// Surveys by source (GK–GN, 2026-10-31): iCloud's survey is the primary one; a source whose folders
// are mostly iCloud's (Dropbox, OneDrive) borrows it; one laid out differently (Google Drive) can
// learn its own from its folder names, on demand. See `FilingSurveyInUse` for the rule.
extension FileSyncManager {

    /// The profile To File places files with for the tree the last scan filed into.
    ///
    /// The active profile for iCloud and every source that borrows it — exactly what every scan
    /// used before surveys by source; the source's own for `.own`; none for `.byName`. Before the
    /// first scan, the active profile.
    var filingRoutingProfile: FolderProfile? {
        guard let use = filingSurveyInUse else { return filingFolderProfile }
        switch use.kind {
        case .primary, .borrowed: return filingFolderProfile
        case .own: return use.ownProfileId.flatMap { sourceSurveyProfiles[$0] }
        case .byName: return nil
        }
    }

    /// The learned memory that goes with ``filingRoutingProfile``. A source's own survey has one
    /// once its documents have been read (Read Documents); learned from folder names alone, none.
    var filingRoutingMemory: FilingMemory? {
        guard let use = filingSurveyInUse else { return filingMemory }
        switch use.kind {
        case .primary, .borrowed: return filingMemory
        case .own: return use.ownProfileId.flatMap { sourceSurveyMemory(id: $0) }
        case .byName: return nil
        }
    }

    /// The fingerprint cached verdicts are keyed with for the tree the last scan filed into.
    ///
    /// **A source's own survey is part of the question**, so it is part of the key: a verdict
    /// composed against Google Drive's survey before its documents were read must not be replayed
    /// after. The primary fingerprint stays in it too, since that is where the household lives.
    /// Nil — cache off — when either half is unreadable.
    var filingRoutingFingerprint: String? {
        guard let use = filingSurveyInUse, use.kind == .own, let id = use.ownProfileId else {
            return filingArtifactFingerprint
        }
        guard let primary = filingArtifactFingerprint, let own = sourceSurveyFingerprint(id: id) else { return nil }
        return primary + "+" + own
    }

    func sourceSurveyFingerprint(id: String) -> String? {
        if let cached = sourceSurveyFingerprints[id] { return cached }
        guard let directory = filingProfilesDirectory,
              let fingerprint = FilingProfileStore.fingerprint(id: id, in: directory) else { return nil }
        sourceSurveyFingerprints[id] = fingerprint
        return fingerprint
    }

    /// The source survey's learned memory, read once and kept; nil before its documents are read.
    func sourceSurveyMemory(id: String) -> FilingMemory? {
        if let cached = sourceSurveyMemories[id] { return cached }
        guard let directory = filingProfilesDirectory,
              let memory = FilingProfileStore.memory(id: id, in: directory) else { return nil }
        sourceSurveyMemories[id] = memory
        return memory
    }

    /// The source's own survey, read once and kept; nil when absent or unreadable.
    func sourceSurveyProfile(id: String) -> FolderProfile? {
        if let cached = sourceSurveyProfiles[id] { return cached }
        guard let directory = filingProfilesDirectory,
              let profile = FilingProfileStore.profile(id: id, in: directory) else { return nil }
        sourceSurveyProfiles[id] = profile
        return profile
    }

    /// Works out which survey places files filed into `providerRoot`, whose folders (relative to
    /// it) are `folders`, and publishes it. Run by every To File scan before its router is built.
    ///
    /// When the answer changes, the router index and the satellite map are dropped: both are keyed
    /// on the tree's folders, which do not move when only the survey does — choosing iCloud's
    /// survey for Google Drive and rescanning would otherwise reuse the index built from its own.
    @discardableResult
    func resolveFilingSurvey(providerRoot: String, folders: Set<String>) -> FilingSurveyInUse {
        let (matched, total) = FilingSurveyInUse.overlap(folders: folders,
                                                         primaryFolders: filingFolderProfile.map { Array($0.folders.keys) } ?? [])
        return resolveFilingSurvey(providerRoot: providerRoot, matched: matched, total: total)
    }

    /// The same, from the overlap already measured — what a choice or a learned survey re-decides
    /// with, since neither changes the tree's folders.
    @discardableResult
    func resolveFilingSurvey(providerRoot: String, matched: Int, total: Int) -> FilingSurveyInUse {
        let entry = filingProfilesDirectory.flatMap { SourceSurveyStore.entry(forRoot: providerRoot, in: $0) }
        let ownId = entry?.profileId.flatMap { sourceSurveyProfile(id: $0) != nil ? $0 : nil }
        let decided: (kind: FilingSurveyInUse.Kind, chosen: Bool)
        if filingFolderProfile != nil, filingFolderProfile?.recordedFolderPath == nil {
            // A profile that records no tree has always been applied to every tree; nothing here
            // can say which one it describes, so it keeps doing that.
            decided = (.primary, false)
        } else {
            decided = FilingSurveyInUse.resolve(providerRoot: providerRoot,
                                                primaryRoot: filingFolderProfile?.recordedFolderPath,
                                                entry: entry, hasOwn: ownId != nil,
                                                matched: matched, total: total)
        }
        let use = FilingSurveyInUse(kind: decided.kind, root: providerRoot, matched: matched, total: total,
                                    chosen: decided.chosen, ownProfileId: ownId,
                                    ownLearnedAt: ownId == nil ? nil : entry?.learnedAt,
                                    ownFolderCount: ownId == nil ? nil : entry?.folderCount,
                                    ownDocumentsReadAt: ownId == nil ? nil : entry?.documentsReadAt,
                                    ownDocumentsRead: ownId == nil ? nil : entry?.documentsRead)
        let previous = filingSurveyInUse
        if let note = sourceSurveyNote, !SourceSurveyStore.sameFolder(note.root, providerRoot) { sourceSurveyNote = nil }
        if previous?.kind != use.kind || previous?.ownProfileId != use.ownProfileId
            || previous?.ownDocumentsReadAt != use.ownDocumentsReadAt
            || previous.map({ SourceSurveyStore.sameFolder($0.root, use.root) }) != true {
            invalidateFilingRouterIndex()
            filingSatelliteKey = nil
            filingSatelliteHomes = [:]
            Logger.shared.info("Filing: placing files in \((providerRoot as NSString).lastPathComponent) with "
                + Self.surveyLogPhrase(use))
        }
        if previous != use { filingSurveyInUse = use }
        return use
    }

    nonisolated static func surveyLogPhrase(_ use: FilingSurveyInUse) -> String {
        let match = "\(use.matched) of \(use.total) folders match the primary survey"
        switch use.kind {
        case .primary: return "the primary survey"
        case .borrowed: return "the primary survey, borrowed (\(use.chosen ? "chosen" : match))"
        case .own: return "its own survey (\(use.ownFolderCount ?? 0) folders\(use.chosen ? ", chosen" : ""))"
        case .byName: return "no survey — by name (\(match))"
        }
    }

    public func dismissSourceSurveyNote() { sourceSurveyNote = nil }

    /// Why learning a source's folders did not happen, in a sentence for the user.
    public enum SourceSurveyFailure: Error, Equatable, Sendable {
        case noProfilesDirectory
        case alreadyLearning
        case unreadable(String)
        case nothingToLearn(String)
        case refused(String)
        /// The source's documents are being read into the survey this would replace or forget.
        case readingDocuments

        public var sentence: String {
            switch self {
            case .noProfilesDirectory: return "SyncCloud has nowhere to keep folder surveys."
            case .alreadyLearning: return "Another folder’s layout is being learned. Try again when it finishes."
            case .unreadable(let path): return "“\((path as NSString).lastPathComponent)” can’t be read."
            case .nothingToLearn(let path): return "“\((path as NSString).lastPathComponent)” holds no folders to learn."
            case .refused(let why): return why
            case .readingDocuments:
                return "Its documents are being read. Try again when the reading finishes, or stop it first."
            }
        }
    }

    /// Learns `root`'s folders as the source's own survey (GL): names and layout only — no document
    /// is opened, so nothing in the cloud downloads. Replaces an earlier survey of the same tree
    /// (Learn Its Folders Again), which goes to the Trash once the new one is written, and chooses
    /// it for the source — so learning Dropbox's own folders uses them though Dropbox matches iCloud.
    ///
    /// The household is the primary survey's (one list of people for every survey), and so are the
    /// place names it confirmed: a jurisdiction is a word the tree cannot be asked about.
    public func learnSourceSurvey(root: String, now: Date = Date()) async -> Result<FilingSurveyInUse?, SourceSurveyFailure> {
        guard let directory = filingProfilesDirectory else { return .failure(.noProfilesDirectory) }
        guard learningSourceSurveyRoot == nil else { return .failure(.alreadyLearning) }
        guard !isReadingDocuments(ofSource: root) else { return .failure(.readingDocuments) }
        learningSourceSurveyRoot = root
        defer { learningSourceSurveyRoot = nil }
        sourceSurveyNote = nil
        let result = await learnSourceSurveyFolders(root: root, directory: directory, now: now)
        switch result {
        case .success: sourceSurveyNote = SourceSurveyNote(root: root, learnedFolders: SourceSurveyStore.entry(forRoot: root, in: directory)?.folderCount, failure: nil)
        case .failure(let failure): sourceSurveyNote = SourceSurveyNote(root: root, learnedFolders: nil, failure: failure)
        }
        return result
    }

    private func learnSourceSurveyFolders(root: String, directory: URL, now: Date) async -> Result<FilingSurveyInUse?, SourceSurveyFailure> {

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? FileManager.default.contentsOfDirectory(atPath: root)) != nil else {
            return .failure(.unreadable(root))
        }
        Logger.shared.info("Source survey: learning the folders of \(root)")
        let url = URL(fileURLWithPath: root)
        // Unbounded, as Setup's walk is: the tree is the one To File just walked to scan, and a
        // survey of part of it would read as a survey of all of it.
        let tree = await Self.buildTree(url: url, sortOption: .name)
        let recordedRoot = Self.recordedRoot(for: url)
        let id = Self.availableSourceProfileId(now: now, in: directory)
        let registry = filingPersonRegistry
        let jurisdictions = Set((filingFolderProfile?.folders.values).map { $0.compactMap { $0.axes["jurisdiction"] } } ?? [])
        let profile = await Task.detached(priority: .userInitiated) {
            FolderSurveyBuilder.build(tree: tree, root: recordedRoot, profileId: id,
                                      registry: registry, jurisdictionValues: jurisdictions)
        }.value
        let learned = profile.folders.keys.filter { $0 != FolderSurveyBuilder.rootEntryPath }.count
        guard learned > 0 else { return .failure(.nothingToLearn(root)) }

        let previousId = SourceSurveyStore.entry(forRoot: root, in: directory)?.profileId
        do {
            try FilingProfileStore.writeSourceProfile(profile, in: directory, now: now)
            // GP, 2026-10-31: learning the folders again keeps what reading the documents learned.
            let carried = previousId.map { carryDocumentReading(from: $0, to: profile, in: directory, now: now) } ?? false
            try SourceSurveyStore.update(root: root, in: directory) {
                $0.profileId = id
                $0.learnedAt = now
                $0.folderCount = learned
                $0.choice = .own
                if !carried {
                    $0.documentsReadAt = nil
                    $0.documentsRead = nil
                }
            }
        } catch {
            Logger.shared.warning("Source survey: could not save \(root)'s survey: \(error)")
            return .failure(.refused(FolderWalkFailure.plainRefusal(error)))
        }
        sourceSurveyProfiles[id] = profile
        if let previousId, previousId != id { retireSourceSurveyFolder(previousId, in: directory) }
        Logger.shared.info("Source survey: learned \(learned) folder(s) of \(root) as '\(id)'")
        return .success(refreshSurveyInUse(forRoot: root))
    }

    /// Sets which survey `root` uses — `.primary` (iCloud's), `.own`, or nil for the measured
    /// default — and re-resolves the one on screen when it is that tree's.
    public func setSourceSurveyChoice(root: String, _ choice: SourceSurveyChoice?) {
        guard let directory = filingProfilesDirectory else { return }
        do {
            try SourceSurveyStore.update(root: root, in: directory) { $0.choice = choice }
            Logger.shared.info("Source survey: \((root as NSString).lastPathComponent) now uses "
                + (choice.map { $0 == .own ? "its own survey" : "the primary survey" } ?? "its measured default"))
        } catch {
            Logger.shared.warning("Source survey: could not save the choice for \(root): \(error)")
        }
        refreshSurveyInUse(forRoot: root)
    }

    /// Forgets `root`'s own survey: its folder goes to the Trash and the source returns to its
    /// measured default.
    public func forgetSourceSurvey(root: String) {
        guard let directory = filingProfilesDirectory,
              let entry = SourceSurveyStore.entry(forRoot: root, in: directory) else { return }
        guard !isReadingDocuments(ofSource: root) else {
            Logger.shared.info("Source survey: not forgetting \(root)'s survey — its documents are being read")
            return
        }
        do {
            try SourceSurveyStore.update(root: root, in: directory) {
                $0.profileId = nil
                $0.learnedAt = nil
                $0.folderCount = nil
                $0.choice = nil
                $0.documentsReadAt = nil
                $0.documentsRead = nil
            }
        } catch {
            Logger.shared.warning("Source survey: could not forget \(root)'s survey: \(error)")
            return
        }
        if let id = entry.profileId { retireSourceSurveyFolder(id, in: directory) }
        refreshSurveyInUse(forRoot: root)
    }

    /// Re-resolves the survey on screen after a change to `root`'s record, when the last scan was
    /// of that tree; the cards themselves change at the next scan.
    @discardableResult
    func refreshSurveyInUse(forRoot root: String) -> FilingSurveyInUse? {
        guard let current = filingSurveyInUse, SourceSurveyStore.sameFolder(current.root, root) else { return nil }
        return resolveFilingSurvey(providerRoot: current.root, matched: current.matched, total: current.total)
    }

    /// Which survey `root` would use, measured now — for the Settings list, which shows sources no
    /// scan has looked at. Walks the folders off the main actor, a budget's worth at most: the
    /// share it measures is as good from 50,000 folders as from all of them.
    public func sourceSurveyStatus(root: String) async -> FilingSurveyInUse {
        let budget = NodeBudget(50_000)
        let tree = await Self.buildTree(url: URL(fileURLWithPath: root), sortOption: .name,
                                        fileManager: fileManager, maxDepth: nil, budget: budget)
        let folders = await Task.detached(priority: .utility) { FilingEngine.relativeFolderPathSet(of: tree) }.value
        let entry = filingProfilesDirectory.flatMap { SourceSurveyStore.entry(forRoot: root, in: $0) }
        let ownId = entry?.profileId.flatMap { sourceSurveyProfile(id: $0) != nil ? $0 : nil }
        let (matched, total) = FilingSurveyInUse.overlap(folders: folders,
                                                         primaryFolders: filingFolderProfile.map { Array($0.folders.keys) } ?? [])
        let decided = FilingSurveyInUse.resolve(providerRoot: root,
                                                primaryRoot: filingFolderProfile?.recordedFolderPath,
                                                entry: entry, hasOwn: ownId != nil,
                                                matched: matched, total: total)
        return FilingSurveyInUse(kind: decided.kind, root: root, matched: matched, total: total,
                                 chosen: decided.chosen, ownProfileId: ownId,
                                 ownLearnedAt: ownId == nil ? nil : entry?.learnedAt,
                                 ownFolderCount: ownId == nil ? nil : entry?.folderCount,
                                 ownDocumentsReadAt: ownId == nil ? nil : entry?.documentsReadAt,
                                 ownDocumentsRead: ownId == nil ? nil : entry?.documentsRead)
    }

    /// The survey Ask Claude answers from for a file at `path` (GM: it follows the source) — the
    /// own survey of the source holding it, when that source uses one, else the primary survey.
    func filingHelpSurvey(for path: String) -> (profile: FolderProfile, memory: FilingMemory?, root: String, surveyedAt: Date?)? {
        if let directory = filingProfilesDirectory {
            let holding = SourceSurveyStore.entries(in: directory)
                .filter { $0.profileId != nil && $0.choice != .primary
                    && FilingSurveyInUse.isAtOrInside(path, $0.root) }
                // The deepest root, should one source's tree hold another's.
                .max { $0.root.count < $1.root.count }
            if let holding, let id = holding.profileId, let profile = sourceSurveyProfile(id: id),
               let root = profile.recordedFolderPath {
                return (profile, sourceSurveyMemory(id: id), root, holding.documentsReadAt ?? holding.learnedAt)
            }
        }
        guard let profile = filingFolderProfile, let root = profile.recordedFolderPath else { return nil }
        return (profile, filingMemory, root, filingSurveyedAt)
    }

    /// A source survey's folder, to the Trash rather than deleted (``sourceSurveyRetire``).
    func retireSourceSurveyFolder(_ id: String, in directory: URL) {
        sourceSurveyProfiles[id] = nil
        sourceSurveyMemories[id] = nil
        sourceSurveyFingerprints[id] = nil
        let folder = directory.appendingPathComponent(id)
        do {
            try sourceSurveyRetire(folder)
        } catch {
            Logger.shared.warning("Source survey: could not move '\(id)' to the Trash: \(error)")
        }
    }

    /// Reads a source's documents from a plan its sheet confirmed, and says how it went on the
    /// banner — the one start both To File's survey menu and Settings use.
    @discardableResult
    public func readSourceDocuments(plan: DocumentSurveyPlan) async -> Result<DocumentSurveyReport, DocumentSurveyRefusal> {
        let result = await runDocumentSurvey(plan: plan)
        switch result {
        case .success(let report):
            banner = report.isComplete ? .success(report.summary) : .warning(report.summary)
        case .failure(let refusal):
            Logger.shared.info("Document survey: not started — \(refusal.sentence)")
            banner = .warning(refusal.sentence)
        }
        return result
    }

    /// Whether a reading of `root`'s own survey is running now.
    public func isReadingDocuments(ofSource root: String) -> Bool {
        documentSurveySourceRoot.map { SourceSurveyStore.sameFolder($0, root) } ?? false
    }

    /// What a finished Read Documents leaves behind for a source: its memory in use, its entry
    /// dated, and the scan on screen re-decided so the cards follow at the next scan.
    func recordSourceDocumentsRead(sourceRoot: String, profileId: String, memory: FilingMemory?,
                                   documentsRead: Int, in directory: URL, now: Date) {
        if let memory { sourceSurveyMemories[profileId] = memory }
        sourceSurveyFingerprints[profileId] = nil
        do {
            try SourceSurveyStore.update(root: sourceRoot, in: directory) {
                $0.documentsReadAt = now
                $0.documentsRead = documentsRead
            }
        } catch {
            Logger.shared.warning("Source survey: could not date the reading of \(sourceRoot): \(error)")
        }
        refreshSurveyInUse(forRoot: sourceRoot)
    }

    /// Copies a source survey's reading — its corpus and memory — to the survey learned to replace
    /// it, before the old one goes to the Trash (GP). The memory keeps only folders the new survey
    /// still has: a folder that is gone has nothing left to place files in. False when there was
    /// nothing read to carry, or it could not be carried.
    func carryDocumentReading(from oldId: String, to profile: FolderProfile, in directory: URL, now: Date) -> Bool {
        guard case .loaded(let corpus) = FilingSurveyStore.corpusRead(id: oldId, in: directory), !corpus.isEmpty,
              let memory = FilingProfileStore.memory(id: oldId, in: directory),
              let root = profile.recordedFolderPath else { return false }
        let newId = profile.profileId
        let carried = FilingMemory(profileId: newId, salt: memory.salt,
                                   folders: memory.folders.filter { profile.folders[$0.key] != nil })
        do {
            _ = try FilingSurveyStore.write(corpus: FilingCorpus(profileId: newId, salt: corpus.salt,
                                                                 documents: corpus.documents),
                                            memory: carried, previousMemory: nil,
                                            id: newId, in: directory, root: root,
                                            now: corpus.surveyedAt ?? now)
        } catch {
            Logger.shared.warning("Source survey: could not carry the documents read from '\(oldId)' to '\(newId)': \(error)")
            return false
        }
        Logger.shared.info("Source survey: carried the documents read from '\(oldId)' to '\(newId)' — "
                           + "\(carried.folders.count) of \(memory.folders.count) folder(s) still there")
        return true
    }

    /// Downloads a cloud-only document and waits, bounded, for its content to land (GL). Returns
    /// at once for a provider that refuses; the reading then counts the document unavailable.
    nonisolated static func fetchCloudOnly(_ path: String, deadline: Duration = .seconds(120),
                                           pollEvery: Duration = .milliseconds(250)) async {
        do {
            try MaterializationStatus.download(atPath: path)
        } catch {
            Logger.shared.info("Document survey: the provider would not download \((path as NSString).lastPathComponent): \(error.localizedDescription)")
            return
        }
        let clock = ContinuousClock()
        let end = clock.now + deadline
        while clock.now < end, !Task.isCancelled {
            // Nil is a file gone mid-download: nothing more will land.
            guard MaterializationStatus.isCloudOnlyIfKnown(atPath: MaterializationStatus.linkTarget(of: path)) == true else { return }
            try? await Task.sleep(for: pollEvery)
        }
        Logger.shared.info("Document survey: \((path as NSString).lastPathComponent) had not downloaded after \(deadline) — left for a later reading")
    }

    /// `source-<stamp>`, unique on disk — the walk's id scheme, with its own prefix so a person
    /// reading `profiles/` can tell a source's survey from a Setup walk.
    static func availableSourceProfileId(now: Date, in directory: URL) -> String {
        let base = "source-" + walkProfileId(now: now).dropFirst("walk-".count)
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
            if suffix > 100 { return "\(base)-\(UUID().uuidString.prefix(8))" }
        }
        return candidate
    }
}

/// What the last Learn Its Folders did — see ``FileSyncManager/sourceSurveyNote``.
public struct SourceSurveyNote: Equatable, Sendable {
    public let root: String
    public let learnedFolders: Int?
    public let failure: FileSyncManager.SourceSurveyFailure?
}
