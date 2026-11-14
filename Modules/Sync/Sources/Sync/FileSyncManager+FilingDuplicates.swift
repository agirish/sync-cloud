import Events
import Foundation

// Phase 2.9 of the filing scan: is this document already in the tree? Without it, a document the
// tree already holds would be offered a home as if it were new, and the copy would land under its
// own name in a folder that fits, the hardest kind of duplicate to notice.
//
// Identity is the one `SatelliteFolders` uses: the PDF text fingerprint where there is one, else
// the byte hash. Not an optimisation: the provider stamps a fresh `/ID` into every download, so
// two downloads of one statement share no byte hash.
extension FileSyncManager {

    /// Marks every suggestion whose document the tree already holds somewhere else. Cost is bounded
    /// by the queue, not the tree: only the loose files on offer are read, against indexes already
    /// on disk. A PDF is parsed once and cached under the duplicate scan's
    /// `(path, mtime, size, file number, ctime)` key, so a rescan of an untouched inbox parses nothing.
    func markingAlreadyFiled(_ suggestions: [FilingSuggestion],
                             providerRoot: String, excludingSubtree source: String? = nil) async -> [FilingSuggestion] {
        guard !suggestions.isEmpty, filingReadsContents else { return suggestions }
        // Injected, never defaulted (see `contentIndexDirectory`): nil is a no-op, not a fallback
        // to the real home directory.
        guard let directory = contentIndexDirectory else { return suggestions }
        let identityIndex = await alreadyFiledIndex(in: directory, providerRoot: providerRoot)
        let existsOnDisk: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        guard identityIndex.holdsAnyPath(existsOnDisk: existsOnDisk) else { return suggestions }

        // Fingerprintable files go through the extractor, the rest through the byte hash:
        // `canFingerprint` says whether the extractor reads the type at all, and a `.docx` handed to
        // it returns nil only after the work of finding out.
        let paths = suggestions.map(\.filePath)
        let documentPaths = paths.filter { ContentFingerprint.canFingerprint(path: $0) }
        let fm = fileManager
        // Byte-hashed only up to `unaskedPassMaxFileBytes`: this runs on every filing scan before its
        // list appears, and a 10 GB download would be read whole. Sized from the file, not the
        // suggestion, whose 0 for an unsizable file would let anything through. Off the main actor,
        // since it stats every file.
        let byteCandidates = paths.filter { !ContentFingerprint.canFingerprint(path: $0) }
        let bytePaths = await Task.detached(priority: .utility) {
            byteCandidates.filter { Self.isWithinUnaskedLimit($0, fileManager: fm) }
        }.value

        var identities: [String: String] = [:]
        if !documentPaths.isEmpty {
            let digests = await Self.fingerprintDocuments(
                documentPaths, fileManager: fm, cache: .sharedFingerprints, textless: .sharedTextless,
                extract: PDFTextExtractor.fingerprintReading)
            for (path, hex) in digests { identities[path] = "f:" + hex }
        }
        if !bytePaths.isEmpty {
            let hashes = await Self.hashFiles(bytePaths, fileManager: fm, cache: .shared)
            for (path, hex) in hashes { identities[path] = "b:" + hex }
        }
        // Saved here as Duplicates saves its own, or this scan's new digests and last-used stamps
        // are lost at quit unless a duplicate scan saves later.
        await ContentHashCache.shared.save()
        await ContentHashCache.sharedFingerprints.save()
        await ContentHashCache.sharedTextless.save()
        guard !identities.isEmpty else { return suggestions }

        var marked = 0
        let out = suggestions.map { s -> FilingSuggestion in
            guard let id = identities[s.filePath] else { return s }
            // The file's own folder is excluded: a loose file in `TODO` is not a copy of itself, and
            // it is in the index once a duplicate scan has run over the inbox.
            let own = String(((s.filePath as NSString).deletingLastPathComponent + "/")
                .dropFirst(providerRoot.count + 1).dropLast())
            // And the whole folder scanned, when it was read with its subfolders: a copy in a
            // sibling inbox folder is another loose file, not a filed one.
            let sourceRelative = source.flatMap { Self.relativePath($0, under: providerRoot) }
            let elsewhere = identityIndex.folders(holding: id, excluding: own,
                                                  providerRoot: providerRoot, existsOnDisk: existsOnDisk)
                .filter { folder in sourceRelative.map { !FileSyncManager.isAtOrUnder(folder, $0) } ?? true }
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

    /// The identity index behind ``markingAlreadyFiled(_:providerRoot:)``, rebuilt only when an
    /// index file changes. Decoded and built off the main actor, since the files hold every
    /// document a duplicate scan has hashed. Existence is checked per lookup, in
    /// ``DocumentIdentityIndex/folders(holding:excluding:providerRoot:existsOnDisk:)``, so a file
    /// deleted since the build stops vouching for its folder.
    func alreadyFiledIndex(in directory: URL, providerRoot: String) async -> DocumentIdentityIndex {
        let hashURL = directory.appendingPathComponent("content-hash-index.json")
        let fingerprintURL = directory.appendingPathComponent("content-fingerprint-index.json")
        let textlessURL = directory.appendingPathComponent("content-textless-index.json")
        // Date and size both: a rewrite inside one timestamp tick still moves the size. And the
        // directory, so an index read from one place is never served for another. Links are
        // followed, or a linked index would never look changed.
        let key = [providerRoot, directory.path] + [hashURL, fingerprintURL, textlessURL].map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
            return "\(date ?? -1) \((attributes?[.size] as? Int) ?? -1)"
        }
        if let cached = filingAlreadyFiledIndex, cached.key == key { return cached.index }
        let index = await Task.detached(priority: .userInitiated) {
            DocumentIdentityIndex.build(hashes: ContentHashIndexStore.load(from: hashURL),
                                        fingerprints: ContentHashIndexStore.load(from: fingerprintURL),
                                        textless: ContentHashIndexStore.load(from: textlessURL),
                                        providerRoot: providerRoot, existsOnDisk: { _ in true })
        }.value
        filingAlreadyFiledIndex = (key, index)
        return index
    }
}
