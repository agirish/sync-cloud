import Events
import Foundation

/// The user's verdicts on whose document is whose: `person-tags.json`, the second writable
/// filing artifact after `people.json`.
///
/// Writable for the same reason the roster is: the profile, memory and corpus describe the tree,
/// but who a document belongs to is a judgement the app may not make. The channels compute, the
/// queue asks, and only the answer is kept.
///
/// Confirming never moves a file; filing is Organize's verb. This store only says "yes" and "no".
@MainActor
public final class PersonTagStore: ObservableObject {
    /// Every verdict on disk. Published so the person view re-renders as soon as a row is judged.
    @Published public private(set) var tags: [PersonTag] = []

    /// Bumped after each successful write of `person-tags.json`, and never otherwise, as
    /// ``PeopleStore/savedRevision`` is: `$tags` says the array changed, not the file. They diverge
    /// for a whole session while the set-aside keeps failing, and `record` checks this before
    /// claiming a verdict was saved.
    @Published public private(set) var savedRevision: Int = 0

    private let directory: URL
    private let profileId: String
    private let fileManager: FileManager
    /// Verdicts written by a newer build, kept out of the way and written back untouched.
    private var carried: [PersonTag] = []
    /// Entries this build could not decode into a tag at all, held verbatim so the next save
    /// doesn't delete them (``PersonTagFile/unreadable``). `carried` is the milder case: a tag
    /// that decoded with an unknown verdict.
    private var unreadable: [JSONFragment] = []
    /// The schema the file on disk was written under, carried so a newer number is not stamped down.
    private var loadedSchema = PersonTagFile.currentSchema

    public var fileURL: URL {
        directory.appendingPathComponent("\(profileId)/person-tags.json")
    }

    public init(directory: URL, profileId: String, fileManager: FileManager = .default) {
        self.directory = directory
        self.profileId = profileId
        self.fileManager = fileManager
        load()
    }

    /// A store with no file behind it, for tests and previews: verdicts stay in memory.
    public init(tags: [PersonTag] = []) {
        self.directory = URL(fileURLWithPath: "/dev/null")
        self.profileId = ""
        self.fileManager = .default
        self.tags = tags
    }

    private var isPersistent: Bool { !profileId.isEmpty }

    /// Writes an empty `person-tags.json` for `profileId` when nothing is at its path, for a Setup
    /// walk of a folder with no history: verdicts are keyed by paths in the folder walked, so
    /// another folder's must not come along, and a missing file would strand the old one under the
    /// retire sweep's "only copy" rule (``RestructureRootMap/startEmptyHistory(in:profileId:)``).
    /// False when the write failed.
    @discardableResult
    static func startEmptyFile(in directory: URL, profileId: String) -> Bool {
        let store = PersonTagStore(directory: directory, profileId: profileId)
        guard (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)) == nil
        else { return true }
        let before = store.savedRevision
        store.save()
        return store.savedRevision != before
    }

    // MARK: - Reading

    /// The verdicts, indexed for the gather.
    ///
    /// Built once per gather rather than searched per document, since a linear scan inside the
    /// sweep would make it quadratic.
    public var index: PersonTagIndex { PersonTagIndex(tags: tags) }

    // MARK: - Writing

    /// Records a verdict, replacing any earlier one for the same person and document.
    ///
    /// Replaces rather than appends: a rejection then a confirmation must leave one tag saying
    /// yes, not two disagreeing ones whose winner depends on read order.
    ///
    /// Matched on the document, not only the key. The key (fingerprint if available, else path)
    /// can change between two judgements of one file, say when it is evicted to iCloud and the
    /// extractor declines, so the reversal must replace the differently-keyed original. Otherwise a
    /// path-keyed tag would keep winning the lookup (`PersonFiles.gather` passes no fingerprint),
    /// or a stale confirmation would linger in `confirmedPaths` and re-list a rejected document.
    ///
    /// Two deliberate limits: a tag with an empty `recordedPath` (written before `at` existed) is
    /// never matched here, and a reused path (a scanner writing `Inbox/Scan.pdf` again) supersedes
    /// the previous document's tag. Both need document identity the gather doesn't have yet.
    public func record(personId: String, key: PersonTagKey, verdict: PersonTagVerdict,
                       path: String) {
        let tag = PersonTag(personId: personId, key: key, verdict: verdict, recordedPath: path)
        if let i = tags.firstIndex(where: { $0.personId == personId && $0.key == key }) {
            // Nothing to do only when the path is unchanged too. The gather finds a
            // fingerprint-keyed tag by path (`byRecordedPath`), so after a move the row returns as
            // a question, and the same answer must refresh `recordedPath` or the button does nothing.
            guard tags[i].verdict != verdict || tags[i].recordedPath != path else { return }
            tags[i] = tag
        } else {
            tags.append(tag)
        }
        // Any other tag this person holds on the same document under the other kind of key is a
        // superseded answer: drop it. Only across kinds: two fingerprint-keyed tags at one recorded
        // path are two documents that held it in turn, and the earlier is a durable record of a
        // document now elsewhere. A path-keyed tag is about whatever is at the path. Tags with an
        // empty recorded path can't be matched, and lookup precedence decides them.
        tags.removeAll { other in
            other.personId == personId && other.key != key
                && !other.recordedPath.isEmpty && other.recordedPath == path
                && Self.isDifferentKind(other.key, key)
        }
        let before = savedRevision
        save()
        // The log may only claim what happened: while the set-aside is failing, `save` refuses
        // and the verdict is in memory only, lost at quit. Conditioned on `savedRevision`, as in
        // `PeopleStore.dismissSuggestion`. A memory-only store makes no durability claim.
        let persisted = !isPersistent || savedRevision != before
        Logger.shared.info("People: \(path) is \(verdict == .rejected ? "NOT " : "")\(personId)'s "
                           + "— \(keyKind(key))"
                           + (persisted ? "" : " — NOT saved: held in memory only this session"))
    }

    /// Whether two keys identify a document in different ways: a path against a fingerprint. Two
    /// of the same kind at one recorded path are two documents, not one answered twice.
    ///
    /// Every pair spelled out, with no `default`: `PersonTagKey` is persisted, and a new case
    /// falling into `default: false` would silently keep two verdicts for one file. Exhaustive, so
    /// a new case fails to compile here.
    static func isDifferentKind(_ a: PersonTagKey, _ b: PersonTagKey) -> Bool {
        switch (a, b) {
        case (.path, .fingerprint), (.fingerprint, .path): return true
        case (.path, .path), (.fingerprint, .fingerprint): return false
        }
    }

    /// Withdraws a verdict entirely, putting the document back in front of whatever the channels
    /// say about it. The undo for a misclick, and the only way a row returns to the queue.
    ///
    /// Withdraws what `record` would have replaced, not only the exact key: a fingerprint-keyed and
    /// a path-keyed verdict at one recorded path are one answer, so clearing one kind alone would
    /// leave the row judged and the button doing nothing.
    ///
    /// No production caller yet: the People queue offers no way back to a judged row.
    public func clear(personId: String, key: PersonTagKey, path: String? = nil) {
        let recordedPath = path ?? tags.first { $0.personId == personId && $0.key == key }?.recordedPath
        let countBefore = tags.count
        tags.removeAll { tag in
            guard tag.personId == personId else { return false }
            if tag.key == key { return true }
            // The other kind of key naming the same document: what `record` would have superseded.
            guard let recordedPath, !recordedPath.isEmpty else { return false }
            return tag.recordedPath == recordedPath && Self.isDifferentKind(tag.key, key)
        }
        guard tags.count != countBefore else { return }
        let revisionBefore = savedRevision
        save()
        // Conditioned on `savedRevision`, as in `record`: while the set-aside keeps failing a
        // withdrawal lives in memory only, and "withdrew the verdict" is a durability claim.
        let persisted = !isPersistent || savedRevision != revisionBefore
        Logger.shared.info("People: withdrew the verdict on \(recordedPath ?? "(unknown path)") "
                           + "for \(personId)"
                           + (persisted ? "" : " — NOT saved: held in memory only this session"))
    }

    private func keyKind(_ key: PersonTagKey) -> String {
        switch key {
        // Says what the key is, not what the lookup does with it: `PersonFiles.gather` passes no
        // fingerprint, so a fingerprint-keyed tag is still found by its recorded path, which
        // `record` refreshes on a re-answer.
        //
        // Looking digests up per document can't reuse `ContentHashCache.sharedFingerprints`: its
        // keys hold mtime at full precision (`FileSyncManager+Duplicates.contentHashKey`), while
        // `FilingCorpusDocument.modified` is whole seconds, so lookups would silently miss. It
        // needs a wider corpus precision (a format migration) or its own path→digest index.
        case .fingerprint: return "keyed to the document's text"
        case .path: return "keyed to its path, so moving the file loses the verdict"
        }
    }

    // MARK: - Persistence

    private func load() {
        guard isPersistent else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Absent and there-but-unreadable are different answers. An unopenable file (mode 000,
            // an ACL, an I/O error) must arm the set-aside: the atomic write needs only directory
            // permission and would land on every recorded verdict. `attributesOfItem`, not
            // `fileExists`, which follows links and answers false for a dangling one, whose link
            // the write would then replace. Truly absent stays silent: a first launch.
            guard (try? fileManager.attributesOfItem(atPath: fileURL.path)) != nil else { return }
            // Says to relaunch, like `PeopleStore`'s warning: the store is built once per launch,
            // so a fix mid-session isn't re-read, and the first save still moves the file aside.
            Logger.shared.warning("Couldn't open person-tags.json "
                                  + "(\(error.localizedDescription)) — verdicts are unavailable "
                                  + "this session. The file is kept: the first verdict you record "
                                  + "moves it aside as a dated person-tags.json.unreadable-… file "
                                  + "rather than overwriting it. Fix \(fileURL.path) and relaunch "
                                  + "before recording anything to use it again — this session "
                                  + "will still move it aside rather than re-read it.")
            fileWasUnreadable = true
            return
        }
        guard let file = try? JSONDecoder().decode(PersonTagFile.self, from: data) else {
            // The container decodes tag by tag, so reaching here means the file is not JSON at all.
            // A corrupt file the user can inspect is recoverable; one this build replaced is not.
            // So the first save sets the bytes aside (see `save`): the file stays recoverable and
            // the app still works.
            Logger.shared.warning("Couldn't read person-tags.json — verdicts are unavailable this "
                                  + "session. The file is kept: the first verdict you record moves "
                                  + "it aside as a dated person-tags.json.unreadable-… file rather "
                                  + "than overwriting it. Fix \(fileURL.path) and relaunch before "
                                  + "recording anything to use it again — this session will still "
                                  + "move it aside rather than re-read it.")
            fileWasUnreadable = true
            return
        }
        tags = file.tags.filter { $0.verdict.isActionable }
        carried = file.tags.filter { !$0.verdict.isActionable }
        unreadable = file.unreadable
        loadedSchema = file.schemaVersion
        if !carried.isEmpty {
            Logger.shared.info("People: \(carried.count) tag(s) carry a verdict this build does not "
                               + "know; they are kept as they are and written back unchanged")
        }
        // Logged, because an entry that can't be decoded is a judgement this build can't show,
        // and the log is the only place it can be noticed.
        if !unreadable.isEmpty {
            Logger.shared.warning("People: \(unreadable.count) entry/entries in person-tags.json "
                                  + "could not be read by this build. They are NOT shown and are "
                                  + "not acted on, and they are written back exactly as found — "
                                  + "a newer version of SyncCloud should read them.")
        }
    }

    /// True when the file on disk could not be read or parsed, so the next save must not land on
    /// it. Cleared only once the bytes are set aside: a failed set-aside leaves it armed, and every
    /// later save retries the move and refuses to write until one succeeds (see `save`). The move
    /// works where the read didn't: `moveItem` renames the directory entry, which no file-level
    /// permission gates, and moves a symlink as itself.
    private var fileWasUnreadable = false

    private func save() {
        guard isPersistent else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            // On the first save after an unreadable read, and on every save until it works.
            // `moveItem`, not a copy, so the file this build writes can't be mistaken for the
            // original. The flag clears only on a successful move: cleared up front, one failed
            // set-aside would let the next save write over the user's file. Retrying is safe:
            // while the flag is set this method has never written `fileURL`, so every attempt moves
            // the user's bytes. Accepted cost: the error repeats per verdict while the move fails,
            // and verdicts stay in memory until it succeeds.
            if fileWasUnreadable {
                // The kept name is unique per episode (``UnreadableSetAside``). An earlier
                // episode's set-aside is the only copy of its verdicts (never re-read), so nothing
                // here may delete one. The helper disambiguates a same-instant name; anything that
                // lands at the chosen path before the move falls into the refusal below and is
                // retried on the next save.
                let kept = UnreadableSetAside.destination(for: fileURL, at: Date(),
                                                         fileManager: fileManager)
                do {
                    try fileManager.moveItem(at: fileURL, to: kept)
                    fileWasUnreadable = false
                    // "Will be", not "has been": the fresh write is still ahead and can throw.
                    // Only the set-aside has happened.
                    Logger.shared.warning("person-tags.json could not be read, so it has been kept "
                                          + "as \(kept.lastPathComponent); a fresh file will be "
                                          + "written beside it. Nothing you recorded before now is "
                                          + "lost — it is in that file.")
                } catch {
                    // A source that is gone is not an obstruction: if the user deleted or moved
                    // the file mid-session, retrying can never succeed, and an armed guard would
                    // refuse every save and lose every verdict at quit. With nothing at the path,
                    // the fresh write overwrites nothing of the user's. Probed with
                    // `attributesOfItem`, not the error code, so a dangling symlink, still a
                    // directory entry, keeps refusing.
                    if (try? fileManager.attributesOfItem(atPath: fileURL.path)) == nil {
                        fileWasUnreadable = false
                        Logger.shared.warning("The unreadable person-tags.json is no longer there "
                                              + "— deleted or moved since it failed to read. "
                                              + "Nothing is left to set aside, so a fresh file is "
                                              + "written.")
                    } else {
                        Logger.shared.error("Couldn't set aside the unreadable person-tags.json "
                                            + "(\(error.localizedDescription)) — NOT overwriting "
                                            + "it; this session's verdicts stay in memory only, "
                                            + "and the set-aside is attempted again on the next "
                                            + "one")
                        return
                    }
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            // Carried tags go back in, or merely opening a newer build's file in this one would
            // destroy them.
            let all = (tags + carried).sorted { $0.id < $1.id }
            let data = try encoder.encode(PersonTagFile(schemaVersion: loadedSchema, tags: all,
                                                        unreadable: unreadable))
            try data.write(to: fileURL, options: .atomic)
            savedRevision &+= 1
        } catch {
            Logger.shared.error("Couldn't save person-tags.json — the verdict is in memory only "
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
    /// `personId` → the path a fingerprint-keyed tag was recorded at → verdict.
    ///
    /// Makes the durable key usable before anything has fingerprinted the tree: a gather walks
    /// paths and computes no digests, so a fingerprint-keyed tag is also found at the path it was
    /// made at. The weaker match, used only when no digest is in hand.
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
    /// A confirmation can name a document no channel would produce (a photo with no text and no
    /// name), and without these the verdict would be recorded and then invisible.
    public func confirmedPaths(for personId: String) -> Set<String> {
        confirmedPaths[personId] ?? []
    }

    /// The verdict on this document for this person. Nil means unjudged, which is what puts a row
    /// in the queue.
    ///
    /// The fingerprint wins where one is in hand, since it survives renames and moves; then the
    /// path key, then the recorded-path fallback.
    public func verdict(personId: String, path: String, fingerprint: String? = nil)
        -> PersonTagVerdict? {
        if let fingerprint, let v = byKey[personId]?[.fingerprint(fingerprint)] { return v }
        if let v = byKey[personId]?[.path(path)] { return v }
        return byRecordedPath[personId]?[path]
    }
}
