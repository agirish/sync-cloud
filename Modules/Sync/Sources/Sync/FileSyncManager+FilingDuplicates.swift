import Events
import Foundation

// Phase 2.9 of the filing scan: is this document already in the tree?
//
// **To File and Duplicates never spoke to each other.** The filing path did not read the content
// indexes at all, so a document that already sat in the tree was offered a home exactly as if it
// were new — and the copy it would have become is the hardest kind of duplicate to notice
// afterwards, because it lands under a name of its own in a folder that genuinely fits.
//
// Identity is the same one `SatelliteFolders` uses: the PDF text fingerprint where there is one and
// the byte hash otherwise. That choice is not an optimisation — the provider re-stamps a fresh
// `/ID` into every download, so two downloads of one statement share no byte hash at all.
extension FileSyncManager {

    /// Marks every suggestion whose document the tree already holds somewhere else.
    ///
    /// Costs are bounded by the QUEUE, not by the tree: only the loose files being offered are
    /// read, against indexes that are already on disk. A PDF is parsed once and cached under the
    /// same `(path, mtime, size, file number, ctime)` key the duplicate scan uses, so a rescan of
    /// an inbox nobody touched re-parses nothing.
    func markingAlreadyFiled(_ suggestions: [FilingSuggestion],
                             providerRoot: String) async -> [FilingSuggestion] {
        guard !suggestions.isEmpty, filingReadsContents else { return suggestions }
        // Injected, never defaulted — see `contentIndexDirectory`. nil is a no-op, not a fallback
        // to the real home directory.
        guard let directory = contentIndexDirectory else { return suggestions }
        let identityIndex = await alreadyFiledIndex(in: directory, providerRoot: providerRoot)
        let existsOnDisk: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        guard identityIndex.holdsAnyPath(existsOnDisk: existsOnDisk) else { return suggestions }

        // Fingerprintable files go through the extractor; everything else through the byte hash.
        // Split rather than fingerprinting everything, because `canFingerprint` is what says the
        // extractor has a reader for the type at all — handing it a `.docx` returns nil after doing
        // the work of finding that out.
        let paths = suggestions.map(\.filePath)
        let documentPaths = paths.filter { ContentFingerprint.canFingerprint(path: $0) }
        let bytePaths = paths.filter { !ContentFingerprint.canFingerprint(path: $0) }
        let fm = fileManager

        var identities: [String: String] = [:]
        if !documentPaths.isEmpty {
            let digests = await Self.fingerprintDocuments(
                documentPaths, fileManager: fm, cache: .sharedFingerprints,
                extract: PDFTextExtractor.fingerprint)
            for (path, hex) in digests { identities[path] = "f:" + hex }
        }
        if !bytePaths.isEmpty {
            let hashes = await Self.hashFiles(bytePaths, fileManager: fm, cache: .shared)
            for (path, hex) in hashes { identities[path] = "b:" + hex }
        }
        guard !identities.isEmpty else { return suggestions }

        var marked = 0
        let out = suggestions.map { s -> FilingSuggestion in
            guard let id = identities[s.filePath] else { return s }
            // The file's own folder is excluded: a loose file in `TODO` is not a copy of itself,
            // and it is in the index the moment a duplicate scan has run over the inbox.
            let own = String(((s.filePath as NSString).deletingLastPathComponent + "/")
                .dropFirst(providerRoot.count + 1).dropLast())
            let elsewhere = identityIndex.folders(holding: id, excluding: own,
                                                  providerRoot: providerRoot, existsOnDisk: existsOnDisk)
            guard !elsewhere.isEmpty else { return s }
            marked += 1
            return s.alreadyFiled(at: elsewhere)
        }
        if marked > 0 {
            Logger.shared.info("Filing: \(marked) of \(suggestions.count) loose file(s) are already "
                               + "filed elsewhere in the tree")
        }
        return out
    }

    /// The identity index behind ``markingAlreadyFiled(_:providerRoot:)``, rebuilt only when
    /// either index file has changed.
    ///
    /// **Decoded and built off the main actor, and without asking whether each path still
    /// exists.** The two files hold every document a duplicate scan has hashed, and decoding them,
    /// building the index and statting every indexed path happened on the main thread at every To
    /// File scan, whether or not a single loose file matched. The existence check now runs per
    /// lookup, in ``DocumentIdentityIndex/folders(holding:excluding:providerRoot:existsOnDisk:)``,
    /// so a file deleted since the index was built still stops vouching for its folder.
    func alreadyFiledIndex(in directory: URL, providerRoot: String) async -> DocumentIdentityIndex {
        let hashURL = directory.appendingPathComponent("content-hash-index.json")
        let fingerprintURL = directory.appendingPathComponent("content-fingerprint-index.json")
        // Date and size, both: a rewrite inside one timestamp tick still moves the size.
        let key = [providerRoot] + [hashURL, fingerprintURL].map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
            return "\(date ?? -1) \((attributes?[.size] as? Int) ?? -1)"
        }
        if let cached = filingAlreadyFiledIndex, cached.key == key { return cached.index }
        let index = await Task.detached(priority: .userInitiated) {
            DocumentIdentityIndex.build(hashes: ContentHashIndexStore.load(from: hashURL),
                                        fingerprints: ContentHashIndexStore.load(from: fingerprintURL),
                                        providerRoot: providerRoot, existsOnDisk: { _ in true })
        }.value
        filingAlreadyFiledIndex = (key, index)
        return index
    }
}
