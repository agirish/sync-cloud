import Events
import Foundation

/// Reads and writes the artifacts a re-survey owns — ``FilingCorpus`` and ``FilingMemory``.
///
/// **The one place in the app that writes a filing artifact**, and separate from
/// ``FilingProfileStore`` on purpose. That store is read-only because a half-finished scan
/// overwriting a good profile is worse than having no profile; nothing here softens that. What it
/// writes is a *complete* rebuild, produced before the first byte is written and written atomically,
/// so the file on disk is only ever a whole memory — the previous one or the new one, never a blend.
/// The folder profile is still never written: it records what a folder *is*, which is a judgement
/// about names that a survey has no business revising.
public enum FilingSurveyStore {

    public static func corpusURL(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id)/filing-corpus.json")
    }

    public static func memoryURL(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id)/filing-memory.json")
    }

    /// How a corpus read went. **Absent and unreadable are different facts and the caller must be
    /// able to tell them apart**, which is the whole reason this type exists.
    ///
    /// A tree that has never been surveyed has no corpus, and re-reading every document is the
    /// correct answer. A corpus that is ON DISK and cannot be parsed says nothing about the tree —
    /// and a survey that treats it as absent starts from an empty corpus, merges whatever this pass
    /// happened to read into it, and writes the result over the memory. With the display asleep or
    /// files offloaded, that is a near-empty memory written over megabytes of learned content, and
    /// the moved fingerprint discards every cached classification with it. The unreadable-ROOT
    /// guard in `FileSyncManager+FilingSurvey` already refuses exactly this harm; it arrived
    /// through the corpus door instead.
    public enum CorpusRead: Sendable {
        /// No corpus file — an ordinary state, and the next survey reads everything.
        case absent
        /// A corpus file that is **on disk and could not be read** — could not be opened (mode
        /// 000, an ACL, an I/O error, a dangling symlink) or could not be parsed. Nothing may be
        /// inferred about the tree from it.
        case unreadable
        case loaded(FilingCorpus)

        /// The corpus when there is one. Absent and unreadable both answer nil, which is what the
        /// callers that genuinely cannot tell them apart already assumed.
        public var corpus: FilingCorpus? {
            if case .loaded(let c) = self { return c }
            return nil
        }
    }

    /// The corpus for `id`, saying which of the three states it found.
    ///
    /// **Unreadable is not only a decode failure.** This reached `.unreadable` through the `catch`
    /// alone, so every way a file can be present and unopenable — mode 000, an ACL, an I/O error,
    /// a symlink whose target is gone — answered `.absent` and walked straight into the harm the
    /// type exists to prevent. Measured: a mode-000 `filing-corpus.json` answered `.absent`, the
    /// survey merged into an empty corpus, and `write` replaced the file — an atomic write needs
    /// permission on the DIRECTORY, not on the file, so the learned content was destroyed rather
    /// than protected.
    ///
    /// `attributesOfItem` rather than `fileExists`, the same probe the four sibling stores use:
    /// `fileExists` follows symlinks and answers false for one whose target is on an unmounted
    /// volume — measured — and the atomic write then replaces the link itself.
    ///
    /// **Nothing is moved aside here, deliberately, unlike ``StorageLensStore``,
    /// ``FilingVerdictStore`` and ``PersonTagStore``.** Those three set the file aside because
    /// they are *committed to writing*: their caller has verdicts or judgements in hand and the
    /// only alternative to a rescue is losing them. This corpus has a third option and takes it —
    /// `FileSyncManager+FilingSurvey` refuses the whole pass, so the bytes are left exactly as
    /// they are and a fixed permission bit recovers the entire survey history. A set-aside here
    /// would be strictly worse: the kept file is never re-ingested, so renaming it would turn a
    /// recoverable permission problem into a full re-read of every document in the tree.
    public static func corpusRead(id: String, in directory: URL) -> CorpusRead {
        let url = corpusURL(id: id, in: directory)
        guard let data = try? Data(contentsOf: url) else {
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                Logger.shared.warning("The filing corpus at \(url.path) exists but could not be "
                                      + "opened — permission, an ACL, an I/O error or a broken "
                                      + "link. Nothing may be inferred about the tree from it.")
                return .unreadable
            }
            return .absent
        }
        do {
            return .loaded(try JSONDecoder().decode(FilingCorpus.self, from: data))
        } catch {
            Logger.shared.warning("Couldn't read the filing corpus: \(error.localizedDescription)")
            return .unreadable
        }
    }

    /// The corpus for `id`, or nil when absent or unreadable.
    ///
    /// Nil is an ordinary state for a caller that only wants to know whether a corpus is available
    /// — it means reading every document rather than the changed ones, which is slow and correct.
    /// A caller that is about to WRITE over learned state must use ``corpusRead(id:in:)`` instead.
    public static func corpus(id: String, in directory: URL) -> FilingCorpus? {
        corpusRead(id: id, in: directory).corpus
    }

    /// Writes both artifacts atomically. Throws rather than logging, so a caller that promised the
    /// user a survey can say it failed.
    ///
    /// `memory` is written only when it differs from `previousMemory`. **A re-survey that finds
    /// nothing must not touch the file**: the memory's bytes are hashed into
    /// ``FilingProfileStore/fingerprint(id:in:)``, which is part of every cached classification's
    /// key, so rewriting an unchanged memory with a fresh `generated` stamp would throw away every
    /// cached verdict to record that nothing happened.
    @discardableResult
    public static func write(corpus: FilingCorpus, memory: FilingMemory, previousMemory: FilingMemory?,
                             id: String, in directory: URL, root: String,
                             now: Date = Date()) throws -> Bool {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(corpus).write(to: corpusURL(id: id, in: directory), options: .atomic)

        guard memory != previousMemory else { return false }
        let document = MemoryDocument(memory: memory, root: root, generated: Self.stamp(now),
                                      sourceDocuments: corpus.documents.values.filter { !$0.isBlank }.count)
        try encoder.encode(document).write(to: memoryURL(id: id, in: directory), options: .atomic)
        return true
    }

    /// The instant both filing artifacts date themselves with — see ``FilingArtifactStamp``, which
    /// is shared with ``FilingProfileStore`` so the two companion files cannot drift apart.
    private static func stamp(_ date: Date) -> String { FilingArtifactStamp.string(from: date) }

    /// The full on-disk shape, header and all.
    ///
    /// The header is not decoration: these artifacts get opened and read by hand when a suggestion
    /// looks wrong, and a file that does not say what it is, when it was made, or what it sampled is
    /// one nobody can audit. The fields match what the offline builder writes, so a memory made here
    /// and one made there are the same document.
    private struct MemoryDocument: Encodable {
        let memory: FilingMemory
        let root: String
        let generated: String
        let sourceDocuments: Int

        static let note = """
            What each folder's already-filed documents say about it. Companion to \
            folder-profile.json: that records what a folder IS, this records what it has RECEIVED. \
            Anchors are readable; idHashes are salted hashes of digit-bearing tokens \
            (account/case/member numbers) so this file is not a readable list of them — \
            obfuscation, not a security boundary. No raw document text is stored.
            """

        enum Key: String, CodingKey {
            case schemaVersion, profileId, portable, generated, root, note, sampling
            case sourceDocuments, folderCount, idHashAlgorithm, salt, folders, builtBy
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(FilingProfileStore.currentSchema, forKey: .schemaVersion)
            try c.encode(memory.profileId, forKey: .profileId)
            try c.encode(false, forKey: .portable)
            try c.encode(generated, forKey: .generated)
            try c.encode(root, forKey: .root)
            try c.encode("SyncCloud — incremental re-survey", forKey: .builtBy)
            try c.encode(MemoryDocument.note, forKey: .note)
            try c.encode(["pdfPages": "1", "maxSnippetChars": "\(FilingSurvey.snippetChars)",
                          "rule": "First page only. Same rule as the folder profile."],
                         forKey: .sampling)
            try c.encode(sourceDocuments, forKey: .sourceDocuments)
            try c.encode(memory.folders.count, forKey: .folderCount)
            try c.encode("sha256(salt + token)[:16]", forKey: .idHashAlgorithm)
            try c.encode(memory.salt, forKey: .salt)
            try c.encode(memory.folders, forKey: .folders)
        }
    }
}
