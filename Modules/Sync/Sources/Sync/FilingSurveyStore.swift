import Events
import Foundation

/// Reads and writes the artifacts a re-survey owns: ``FilingCorpus`` and ``FilingMemory``. The one
/// place that writes a filing artifact, kept apart from the read-only ``FilingProfileStore``. It
/// writes only a complete rebuild, atomically, so the file is always a whole memory, old or new,
/// never a blend. The folder profile is never written: what a folder is isn't a survey's to revise.
public enum FilingSurveyStore {

    public static func corpusURL(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id)/filing-corpus.json")
    }

    public static func memoryURL(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id)/filing-memory.json")
    }

    /// How a corpus read went. **Absent and unreadable must stay distinct.** No corpus means re-read
    /// everything. A corpus on disk that can't be read says nothing about the tree; treated as
    /// absent, a survey would merge this pass into an empty corpus and write a near-empty memory
    /// over the learned one, and the moved fingerprint would discard every cached classification.
    public enum CorpusRead: Sendable {
        /// No corpus file: an ordinary state, and the next survey reads everything.
        case absent
        /// A corpus file on disk that couldn't be opened (mode 000, an ACL, an I/O error, a
        /// dangling symlink) or parsed. Nothing may be inferred about the tree from it.
        case unreadable
        case loaded(FilingCorpus)

        /// The corpus when there is one; nil for both absent and unreadable, for callers that
        /// don't need to tell them apart.
        public var corpus: FilingCorpus? {
            if case .loaded(let c) = self { return c }
            return nil
        }
    }

    /// The corpus for `id`, saying which of the three states it found. **Unreadable includes a file
    /// that is present but won't open**, not just a decode failure: an atomic write needs only
    /// directory permission, so a mode-000 corpus taken as absent would be overwritten and lost.
    /// `attributesOfItem`, not `fileExists`, which follows symlinks and says false for a link into
    /// an unmounted volume, so the write would replace the link.
    ///
    /// **Nothing is moved aside here**, unlike ``StorageLensStore``, ``FilingVerdictStore`` and
    /// ``PersonTagStore``, which must write what their caller holds. `FileSyncManager+FilingSurvey`
    /// refuses the whole pass instead, leaving the bytes as they are, so fixing the permission
    /// recovers everything; a set-aside file is never re-read, forcing a full re-survey.
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

    /// The corpus for `id`, or nil when absent or unreadable: fine for a caller that just reads
    /// every document without one. **A caller about to write over learned state must use
    /// ``corpusRead(id:in:)``.**
    public static func corpus(id: String, in directory: URL) -> FilingCorpus? {
        corpusRead(id: id, in: directory).corpus
    }

    /// The corpus's `surveyedAt` stamp alone; nil when the file is absent, unreadable, or has no
    /// stamp. A separate read so launch can show one date without building the whole document
    /// dictionary: the JSON is still parsed, but only this field is decoded.
    public static func surveyedAt(id: String, in directory: URL) -> Date? {
        struct StampOnly: Decodable { let surveyedAt: String? }
        guard let data = try? Data(contentsOf: corpusURL(id: id, in: directory)),
              let decoded = try? JSONDecoder().decode(StampOnly.self, from: data)
        else { return nil }
        return decoded.surveyedAt.flatMap(FilingArtifactStamp.date(from:))
    }

    /// Writes both artifacts atomically. Throws rather than logging, so a caller that promised a
    /// survey can say it failed. **`memory` is written only when it differs from `previousMemory`**:
    /// its bytes feed ``FilingProfileStore/fingerprint(id:in:)``, part of every cached
    /// classification's key, so a fresh `generated` stamp alone would discard every cached verdict.
    @discardableResult
    public static func write(corpus: FilingCorpus, memory: FilingMemory, previousMemory: FilingMemory?,
                             id: String, in directory: URL, root: String,
                             now: Date = Date()) throws -> Bool {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Stamped here, at the write every survey goes through, so "last surveyed" moves even when
        // nothing changed, while the memory below writes only on change to keep the fingerprint.
        var stamped = corpus
        stamped.surveyedAt = now
        try encoder.encode(stamped).write(to: corpusURL(id: id, in: directory), options: .atomic)

        guard memory != previousMemory else { return false }
        let document = MemoryDocument(memory: memory, root: root, generated: Self.stamp(now),
                                      sourceDocuments: corpus.documents.values.filter { !$0.isBlank }.count)
        try encoder.encode(document).write(to: memoryURL(id: id, in: directory), options: .atomic)
        return true
    }

    /// The instant both filing artifacts are dated with, via ``FilingArtifactStamp``, shared with
    /// ``FilingProfileStore`` so the companion files can't drift apart.
    private static func stamp(_ date: Date) -> String { FilingArtifactStamp.string(from: date) }

    /// The full on-disk shape, header and all. The header lets someone auditing a wrong suggestion
    /// see what the file is, when it was made and what it sampled. The fields match the offline
    /// builder's, so a memory made here and one made there are the same document.
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
