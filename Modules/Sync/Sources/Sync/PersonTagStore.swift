import Events
import Foundation

/// His verdicts on whose document is whose — `person-tags.json`, the second writable filing
/// artifact after `people.json`.
///
/// **Deliberately writable, and for the same reason the roster is.** The folder profile, the filing
/// memory and the corpus all *describe* the tree, and a half-finished scan writing any of them back
/// would be worse than not having them. Who a document belongs to is not a description of anything
/// — it is a judgement, and the app is not entitled to make it. So the channels compute, the queue
/// asks, and only the answer is kept.
///
/// **Confirming never moves a file.** Filing is Organize's verb and stays one click away on the same
/// row; this store's whole vocabulary is "yes" and "no".
@MainActor
public final class PersonTagStore: ObservableObject {
    /// Every verdict on disk. Published so the person view re-renders the instant a row is judged.
    @Published public private(set) var tags: [PersonTag] = []

    private let directory: URL
    private let profileId: String
    private let fileManager: FileManager
    /// Verdicts written by a newer build, kept out of the way and written back untouched.
    private var carried: [PersonTag] = []

    public var fileURL: URL {
        directory.appendingPathComponent("\(profileId)/person-tags.json")
    }

    public init(directory: URL, profileId: String, fileManager: FileManager = .default) {
        self.directory = directory
        self.profileId = profileId
        self.fileManager = fileManager
        load()
    }

    /// A store with no file behind it, for tests and previews — verdicts stay in memory.
    public init(tags: [PersonTag] = []) {
        self.directory = URL(fileURLWithPath: "/dev/null")
        self.profileId = ""
        self.fileManager = .default
        self.tags = tags
    }

    private var isPersistent: Bool { !profileId.isEmpty }

    // MARK: - Reading

    /// The verdicts, indexed for the gather.
    ///
    /// Built once per gather rather than searched per document: the sweep asks about every surveyed
    /// document, and a linear scan of the verdict list inside that loop is the shape that turns a
    /// 10,171-document walk into a quadratic one.
    public var index: PersonTagIndex { PersonTagIndex(tags: tags) }

    // MARK: - Writing

    /// Records a verdict, replacing any earlier one for the same person and document.
    ///
    /// **Replaces rather than appends**, because the user changing their mind is ordinary: a
    /// rejection followed by a confirmation must leave one tag saying yes, not two disagreeing ones
    /// whose winner depends on read order.
    ///
    /// **Matched on the document, not only on the key.** The key is decided at judgement time —
    /// a fingerprint where the document has one, the path otherwise — and that answer can change
    /// between two judgements of the same file: it is evicted to iCloud, or locked, and the
    /// extractor declines. Matching on `(personId, key)` alone then stored the reversal *beside*
    /// the original as a differently-keyed tag, which is the "two disagreeing ones whose winner
    /// depends on read order" this method's own rule forbids, arriving by the other door.
    ///
    /// **Which one wins, precisely:** `PersonFiles.gather` asks `verdict(personId:path:)` with no
    /// fingerprint, so `PersonTagIndex` consults `.path` first and falls back to the recorded path.
    /// A *path*-keyed tag therefore beats a fingerprint-keyed one on the same document — so the
    /// direction that went stale is a path-keyed "yes" followed by a fingerprint-keyed "no", where
    /// the withdrawn confirmation kept winning. (An earlier version of this note had it the other
    /// way round.) The reverse order was already answered correctly by that precedence, but it
    /// left the confirmation in `confirmedPaths`, so the `unseenConfirmations` sweep re-listed a
    /// rejected document as "theirs" — the same wrong answer by a different route. Both are gone.
    ///
    /// Two limits, deliberate: a tag written before the `at` field existed decodes with an empty
    /// `recordedPath` and so is never matched here, and a path the user re-uses (a scanner writing
    /// `Inbox/Scan.pdf` again) will supersede the previous document's tag. Both need document
    /// identity to do better, which is the same thing `keyKind` says the gather does not yet have.
    public func record(personId: String, key: PersonTagKey, verdict: PersonTagVerdict,
                       path: String) {
        let tag = PersonTag(personId: personId, key: key, verdict: verdict, recordedPath: path)
        if let i = tags.firstIndex(where: { $0.personId == personId && $0.key == key }) {
            guard tags[i].verdict != verdict else { return }
            tags[i] = tag
        } else {
            tags.append(tag)
        }
        // Any other tag this person holds on the same document, under the other kind of key, is a
        // superseded answer to the question just answered. Dropped rather than left to lose a
        // precedence contest it should never have been in.
        tags.removeAll { $0.personId == personId && $0.key != key && $0.recordedPath == path }
        save()
        Logger.shared.info("People: \(path) is \(verdict == .rejected ? "NOT " : "")\(personId)'s "
                           + "— \(keyKind(key))")
    }

    /// Withdraws a verdict entirely, putting the document back in front of whatever the channels
    /// say about it. The undo for a misclick, and the only way a row returns to the queue.
    public func clear(personId: String, key: PersonTagKey) {
        guard let i = tags.firstIndex(where: { $0.personId == personId && $0.key == key })
        else { return }
        let removed = tags.remove(at: i)
        save()
        Logger.shared.info("People: withdrew the verdict on \(removed.recordedPath) for \(personId)")
    }

    private func keyKind(_ key: PersonTagKey) -> String {
        switch key {
        // Says what the KEY is, not what the lookup currently does with it. `PersonFiles.gather`
        // asks `verdict(personId:path:)` and passes no fingerprint, so today a fingerprint-keyed
        // tag is still found by its recorded path and a move does re-open the question. The key
        // is the durable half and is what makes closing that gap possible; the gather needs a
        // path→digest source it can consult without fingerprinting every document it walks, which
        // is a change of a different size. Not claimed here until it is true.
        case .fingerprint: return "keyed to the document's text"
        case .path: return "keyed to its path, so moving the file loses the verdict"
        }
    }

    // MARK: - Persistence

    private func load() {
        guard isPersistent, let data = try? Data(contentsOf: fileURL) else { return }
        guard let file = try? JSONDecoder().decode(PersonTagFile.self, from: data) else {
            // The container decodes tag-by-tag, so reaching here means the *file* is not JSON at
            // all. Left on disk untouched rather than overwritten: a corrupt file the user can
            // inspect is recoverable, and one this build has replaced with `{}` is not.
            Logger.shared.warning("Couldn't read person-tags.json — verdicts are unavailable this "
                                  + "session, and the file has been left as it is")
            return
        }
        tags = file.tags.filter { $0.verdict.isActionable }
        carried = file.tags.filter { !$0.verdict.isActionable }
        if !carried.isEmpty {
            Logger.shared.info("People: \(carried.count) tag(s) carry a verdict this build does not "
                               + "know; they are kept as they are and written back unchanged")
        }
    }

    private func save() {
        guard isPersistent else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            // Carried tags go back in. Dropping them would make this build's *read* of a newer
            // file destructive, which is the failure the tag-by-tag decode exists to prevent —
            // and it would be undone here if the write forgot them.
            let all = (tags + carried).sorted { $0.id < $1.id }
            let data = try encoder.encode(PersonTagFile(tags: all))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.warning("Couldn't save person-tags.json — the verdict is in memory only "
                                  + "this session: \(error.localizedDescription)")
        }
    }
}

/// Verdicts, indexed by what the gather can ask about a document.
///
/// A plain value rather than a store method so the sweep can carry it across an actor boundary:
/// the gather runs off the main actor and `PersonTagStore` is `@MainActor`.
public struct PersonTagIndex: Sendable, Equatable {
    /// `personId` → key → verdict, for the key the tag was actually stored under.
    private var byKey: [String: [PersonTagKey: PersonTagVerdict]] = [:]
    /// `personId` → the path a **fingerprint-keyed** tag was recorded at → verdict.
    ///
    /// **This is what makes the durable key usable before anything has fingerprinted the tree.**
    /// A digest identifies a document but says nothing about where it is, and a gather walks paths:
    /// nothing computes 10,171 fingerprints to answer "whose is this?", and the persisted
    /// fingerprint index only exists once a Tidy scan has run. So a fingerprint-keyed tag is also
    /// findable at the path it was made at — the weaker match, used only when no digest is in hand.
    private var byRecordedPath: [String: [String: PersonTagVerdict]] = [:]
    /// `personId` → every path a confirmation was recorded at, so the gather can surface documents
    /// no channel would have found.
    private var confirmedPaths: [String: Set<String>] = [:]

    public init(tags: [PersonTag]) {
        for tag in tags where tag.verdict.isActionable {
            byKey[tag.personId, default: [:]][tag.key] = tag.verdict
            if case .fingerprint = tag.key, !tag.recordedPath.isEmpty {
                byRecordedPath[tag.personId, default: [:]][tag.recordedPath] = tag.verdict
            }
            if tag.verdict == .confirmed, !tag.recordedPath.isEmpty {
                confirmedPaths[tag.personId, default: []].insert(tag.recordedPath)
            }
        }
    }

    public var isEmpty: Bool { byKey.isEmpty }

    /// Every path this person was confirmed at.
    ///
    /// The gather needs these because a confirmation can name a document **no channel would ever
    /// produce** — the design's own example is a photo, which carries no text and no name either
    /// way. Without this the verdict would be recorded and then invisible.
    public func confirmedPaths(for personId: String) -> Set<String> {
        confirmedPaths[personId] ?? []
    }

    /// The verdict on this document for this person. Nil means unjudged, which is what puts a row
    /// in the queue.
    ///
    /// **The fingerprint wins where one is in hand**, because it is the identity that survives the
    /// file being renamed or moved. The path key is next, and the recorded-path fallback last.
    public func verdict(personId: String, path: String, fingerprint: String? = nil)
        -> PersonTagVerdict? {
        if let fingerprint, let v = byKey[personId]?[.fingerprint(fingerprint)] { return v }
        if let v = byKey[personId]?[.path(path)] { return v }
        return byRecordedPath[personId]?[path]
    }
}
