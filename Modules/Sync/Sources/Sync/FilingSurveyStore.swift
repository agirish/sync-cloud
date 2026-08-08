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

    /// The corpus for `id`, or nil when absent or unreadable.
    ///
    /// Nil is an ordinary state — it means the next survey reads every document rather than the
    /// changed ones, which is slow and correct, not broken.
    public static func corpus(id: String, in directory: URL) -> FilingCorpus? {
        guard let data = try? Data(contentsOf: corpusURL(id: id, in: directory)) else { return nil }
        do {
            return try JSONDecoder().decode(FilingCorpus.self, from: data)
        } catch {
            Logger.shared.warning("Couldn't read the filing corpus — the next survey will read every "
                                  + "document instead of the changed ones: \(error.localizedDescription)")
            return nil
        }
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

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

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
