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
    /// Entries this build could not decode into a tag at all, held verbatim so the next save does
    /// not delete them. See ``PersonTagFile/unreadable`` — `carried` above is the milder case (a
    /// tag that decoded, whose VERDICT is unknown); this one never became a tag.
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
            // **Nothing to do only when the path is unchanged too.** The early return used to key
            // on the verdict alone, which made re-answering a MOVED document a permanent no-op:
            // the gather looks a fingerprint-keyed tag up by path (`byRecordedPath`), so after
            // Organize files the file the row comes back as an open question — and pressing the
            // same answer again computed the same key, saw the same verdict, and returned without
            // ever updating `recordedPath`. The row reappeared on every gather and the button did
            // nothing, for as long as the document stayed where it had been put.
            guard tags[i].verdict != verdict || tags[i].recordedPath != path else { return }
            tags[i] = tag
        } else {
            tags.append(tag)
        }
        // Any other tag this person holds on the same document, under the OTHER KIND of key, is a
        // superseded answer to the question just answered. Dropped rather than left to lose a
        // precedence contest it should never have been in.
        //
        // Only across kinds, and that is the narrow point: two fingerprint-keyed tags sharing a
        // recorded path are two different DOCUMENTS that occupied it in turn — a scanner rewriting
        // `Inbox/Scan.pdf` is ordinary — and the earlier one is a durable record about a document
        // that still exists somewhere else. A path-keyed tag, by contrast, is a claim about
        // "whatever is at this path", which the document being recorded now is.
        //
        // Not reached for a tag written before `recordedPath` existed: those decode with an empty
        // path and cannot be matched to anything. Such a pair keeps the pre-fix behaviour, where
        // the lookup precedence decides it.
        tags.removeAll { other in
            other.personId == personId && other.key != key
                && !other.recordedPath.isEmpty && other.recordedPath == path
                && Self.isDifferentKind(other.key, key)
        }
        save()
        Logger.shared.info("People: \(path) is \(verdict == .rejected ? "NOT " : "")\(personId)'s "
                           + "— \(keyKind(key))")
    }

    /// Whether two keys identify a document in different ways — a path against a fingerprint.
    ///
    /// Two of the same kind at one recorded path are two documents, not one answered twice.
    /// **Every pair spelled out, with no `default`.** `PersonTagKey` is persisted, and a third way
    /// to identify a document would fall into a `default: false` here — silently keeping both the
    /// new key's verdict and the old one for the same file, which is the bug this sweep exists to
    /// prevent, reintroduced without a diagnostic. Exhaustive, so adding a case fails to compile
    /// at the place the decision has to be made.
    static func isDifferentKind(_ a: PersonTagKey, _ b: PersonTagKey) -> Bool {
        switch (a, b) {
        case (.path, .fingerprint), (.fingerprint, .path): return true
        case (.path, .path), (.fingerprint, .fingerprint): return false
        }
    }

    /// Withdraws a verdict entirely, putting the document back in front of whatever the channels
    /// say about it. The undo for a misclick, and the only way a row returns to the queue.
    ///
    /// **Withdraws what `record` would have replaced, not merely the exact key.** `record`
    /// supersedes across key KINDS at one recorded path — a fingerprint-keyed verdict and a
    /// path-keyed one about the same document are one answer given twice, and it drops the older.
    /// Matching only the exact key here made the two halves disagree: clearing a document whose
    /// verdict happens to be stored under the other kind removed nothing, said nothing, and left
    /// the row judged. Whoever wires this to a control would have found a button that silently
    /// does nothing for exactly the documents the durable key was introduced for.
    ///
    /// **No production caller yet** — the People queue takes a judged row off screen and offers no
    /// way back, which is a UI gap this cannot close on its own. The correctness half is here so
    /// the control, when it exists, is wired to something that works.
    public func clear(personId: String, key: PersonTagKey, path: String? = nil) {
        let recordedPath = path ?? tags.first { $0.personId == personId && $0.key == key }?.recordedPath
        let before = tags.count
        tags.removeAll { tag in
            guard tag.personId == personId else { return false }
            if tag.key == key { return true }
            // The other kind of key naming the same document — what `record` would have superseded.
            guard let recordedPath, !recordedPath.isEmpty else { return false }
            return tag.recordedPath == recordedPath && Self.isDifferentKind(tag.key, key)
        }
        guard tags.count != before else { return }
        save()
        Logger.shared.info("People: withdrew the verdict on \(recordedPath ?? "(unknown path)") "
                           + "for \(personId)")
    }

    private func keyKind(_ key: PersonTagKey) -> String {
        switch key {
        // Says what the KEY is, not what the lookup currently does with it. `PersonFiles.gather`
        // asks `verdict(personId:path:)` and passes no fingerprint, so today a fingerprint-keyed
        // tag is still found by its recorded path — and `record` refreshes that path when the same
        // answer is given again somewhere new, which is what keeps a moved document answerable.
        //
        // **What closing the gap properly needs, since it is not obvious:** the gather would have
        // to look a digest up per document without fingerprinting 10,171 of them, and the obvious
        // source does not fit. `ContentHashCache.sharedFingerprints` is keyed on
        // `(path, mtime, size)` with mtime at full `timeIntervalSince1970` precision
        // (`FileSyncManager+Duplicates.contentHashKey`), while `FilingCorpusDocument.modified` is
        // whole seconds — so keys built from the corpus would miss except by coincidence, and the
        // feature would silently do nothing, which is the failure it exists to fix. Closing it
        // means either widening the corpus's stored precision (a persisted-format change with a
        // migration) or a path→digest index of its own. Not claimed here until one of those is
        // done.
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
            // **"Absent" and "there but unreadable" are different answers**, and the `try?` this
            // used to be conflated them. A file that exists but cannot be opened — mode 000, an
            // ACL, an I/O error — read as a first launch, so the set-aside below never armed, and
            // the first verdict's atomic write (which needs permission on the *directory*, not the
            // file) landed straight on top of every verdict already recorded. `attributesOfItem`
            // rather than `fileExists`, because only the former sees a symlink that does not
            // resolve: `fileExists` follows links and answers false for one whose target is on an
            // unmounted volume — and the write then replaces the link itself. Genuinely absent
            // stays silent, because a first launch has nothing to warn about.
            guard (try? fileManager.attributesOfItem(atPath: fileURL.path)) != nil else { return }
            Logger.shared.warning("Couldn't open person-tags.json "
                                  + "(\(error.localizedDescription)) — verdicts are unavailable "
                                  + "this session. The file is kept: the first verdict you record "
                                  + "moves it aside as a dated person-tags.json.unreadable-… file "
                                  + "rather than overwriting it.")
            fileWasUnreadable = true
            return
        }
        guard let file = try? JSONDecoder().decode(PersonTagFile.self, from: data) else {
            // The container decodes tag-by-tag, so reaching here means the *file* is not JSON at
            // all. A corrupt file the user can inspect is recoverable and one this build has
            // replaced is not — but "left as it is" was only true until the next verdict, because
            // `record` calls `save` and `save` wrote straight over it. So the bytes are set aside
            // on the FIRST save instead (see `save`), which keeps both halves of the promise: the
            // file is recoverable, and the app still works.
            Logger.shared.warning("Couldn't read person-tags.json — verdicts are unavailable this "
                                  + "session. The file is kept: the first verdict you record moves "
                                  + "it aside as a dated person-tags.json.unreadable-… file rather "
                                  + "than overwriting it.")
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
        // Said out loud, because the whole defect was that it was not. An entry that cannot be
        // decoded at all is a judgement the user made that this build cannot show them — the log
        // line is the only place it can be noticed at all, and its absence is what let the next
        // save destroy them silently.
        if !unreadable.isEmpty {
            Logger.shared.warning("People: \(unreadable.count) entry/entries in person-tags.json "
                                  + "could not be read by this build. They are NOT shown and are "
                                  + "not acted on, and they are written back exactly as found — "
                                  + "a newer version of SyncCloud should read them.")
        }
    }

    /// True when the file on disk could not be read or parsed at all, so the next save must not
    /// land on top of it. Cleared only once the bytes have actually been set aside — a failed
    /// set-aside leaves it armed, so every later save re-attempts the move and keeps refusing to
    /// write until one succeeds; see `save`. The move there
    /// works where the read did not: `moveItem` renames the directory entry, which no file-level
    /// permission gates, and a symlink is moved as itself rather than through its target.
    private var fileWasUnreadable = false

    private func save() {
        guard isPersistent else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            // **On the first save after an unreadable read — and again on every save until it
            // works.** `moveItem` rather than a copy, so the working file this build is about to
            // write cannot be mistaken for the original. The flag clears only on a SUCCESSFUL
            // move: clearing it up front meant one failed set-aside disarmed the guard, and the
            // next verdict's save ran unguarded and landed its atomic write on the user's
            // still-in-place file — the exact loss this path exists to prevent, one save later.
            // ("A second attempt would be moving this build's file" was only true after a move
            // that worked.) Retrying is safe precisely because the armed flag is the invariant:
            // while it is set, this method has never written `fileURL`, so every attempt moves
            // the user's bytes and never this build's. The costs are accepted as the honest
            // state — the error line below repeats once per verdict while the move keeps
            // failing, and verdicts live only in memory until it stops.
            if fileWasUnreadable {
                // The kept name is unique PER EPISODE — see `setAsideDestination`. An earlier
                // episode's set-aside is the ONLY copy of that episode's rescued verdicts (it is
                // never re-ingested), so nothing here may ever delete one: the old single-slot
                // name made a second unreadable episode's collision handling do exactly that,
                // under a comment claiming what moved in was "the more current of the two
                // records" — which is not a defence when the earlier record was never read back.
                // With per-episode names there is no collision to handle and no remove to
                // justify; the pathological same-instant case is disambiguated inside the
                // helper, and anything that still lands at the chosen path between the probe and
                // the move falls into the refusal below and is retried on the next save.
                let kept = Self.setAsideDestination(for: fileURL, at: Date(),
                                                    fileManager: fileManager)
                do {
                    try fileManager.moveItem(at: fileURL, to: kept)
                    fileWasUnreadable = false
                    Logger.shared.warning("person-tags.json could not be read, so it has been kept "
                                          + "as \(kept.lastPathComponent) and a fresh file written "
                                          + "beside it. Nothing you recorded before now is lost — "
                                          + "it is in that file.")
                } catch {
                    // **A source that is no longer there is not an obstruction — it is the
                    // protection having arrived by other means.** The user hand-deleting (or
                    // moving) the unreadable file mid-session makes the move fail source-absent,
                    // and that failure can never clear: retrying moves nothing, so a guard that
                    // stays armed refuses every save for the rest of the session and silently
                    // loses every verdict at quit. There is nothing left at the path to protect,
                    // so the fresh write below cannot overwrite anything of the user's. Probed
                    // with `attributesOfItem` rather than matched on the error code, because the
                    // probe also keeps the dangling-symlink case refusing: the link is still a
                    // directory entry, and `attributesOfItem` sees it where `fileExists` follows
                    // it and answers false.
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
            // Carried tags go back in. Dropping them would make this build's *read* of a newer
            // file destructive, which is the failure the tag-by-tag decode exists to prevent —
            // and it would be undone here if the write forgot them.
            let all = (tags + carried).sorted { $0.id < $1.id }
            let data = try encoder.encode(PersonTagFile(schemaVersion: loadedSchema, tags: all,
                                                        unreadable: unreadable))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.warning("Couldn't save person-tags.json — the verdict is in memory only "
                                  + "this session: \(error.localizedDescription)")
        }
    }

    /// Where this episode's set-aside goes: `person-tags.json.unreadable-<stamp>`, a name unique
    /// per episode so a later episode can never land on — and destroy — an earlier one.
    ///
    /// The stamp is ``FilingArtifactStamp``'s (the format every filing artifact dates itself
    /// with), colons swapped for dots because this one lives in a file NAME. Second precision
    /// means two episodes in one second would collide, so an occupied candidate gets a numeric
    /// disambiguator instead — probed with `attributesOfItem` rather than `fileExists`, which
    /// follows symlinks and would call a dangling-link occupant free. Static and internal so a
    /// test can pin the disambiguation with a frozen date; `save()` passes `Date()`.
    static func setAsideDestination(for fileURL: URL, at now: Date,
                                    fileManager: FileManager) -> URL {
        let stamp = FilingArtifactStamp.string(from: now)
            .replacingOccurrences(of: ":", with: ".")
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent + ".unreadable-" + stamp
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil {
            candidate = dir.appendingPathComponent(base + "-\(n)")
            n += 1
        }
        return candidate
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
    /// fingerprint index only exists once a duplicates scan has run. So a fingerprint-keyed tag is also
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
