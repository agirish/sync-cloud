import Foundation

/// Re-derives ``FilingMemory`` from what is on disk now, reading only what changed. A folder the
/// memory hasn't learned ranks on its name alone, which routes far worse than learned content.
///
/// Extraction is the expensive part (page 1 of every document takes hours; the arithmetic takes
/// under a second), so ``FilingCorpus`` keeps the tokens and a re-survey reads only documents whose
/// size or mtime moved. The memory is then rebuilt in full: IDF is corpus-wide, and a partial
/// rebuild would weigh a new folder's anchors on a different denominator, quietly worsening ranks.
///
/// A rule-for-rule port of the offline builder (`build_memory_extended.py`), sharing
/// ``FilingRouter/tokenize(_:)``: a token split differently from the stored memory's silently stops
/// matching.
public enum FilingSurvey {

    // MARK: - What the walk saw

    /// Size and whole-second mtime — the pair that decides whether a document must be read again.
    public struct Stamp: Sendable, Equatable, Hashable {
        public let size: Int
        public let modified: Int
        public init(size: Int, modified: Int) {
            self.size = size
            self.modified = modified
        }
    }

    /// The tree flattened to what a survey needs: every folder's mtime, every document's stamp.
    public struct Tree: Sendable, Equatable {
        /// Folder path relative to the root → its own whole-second mtime.
        public let folders: [String: Int]
        /// Document path relative to the root → its stamp.
        public let documents: [String: Stamp]

        /// Folders the walk did not descend into (permission denied, a depth cap, a symlink cycle),
        /// spelled as in `folders`. **Keeps "nobody looked" apart from "deleted".** Without it, one
        /// unreadable folder drops every document under it from the corpus on the next survey
        /// (``merge(corpus:tree:read:)``).
        public let unexplored: Set<String>

        /// `unexplored` defaults to empty so fixtures about folders and documents stay short.
        public init(folders: [String: Int], documents: [String: Stamp],
                    unexplored: Set<String> = []) {
            self.folders = folders
            self.documents = documents
            self.unexplored = unexplored
        }

        /// Whether `path` sits under a folder this walk never descended into — so its absence from
        /// `documents` says nothing about whether it is still on disk.
        public func wasNotWalked(_ path: String) -> Bool {
            unexplored.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        /// Whether this walk is evidence that `path` is gone: it looked where the document was and
        /// didn't find it. One member so every caller agrees: if `relocations` counted an unwalked
        /// document as lost while `merge` kept it, a stamp match would write it at both paths.
        public func showsGone(_ path: String) -> Bool {
            documents[path] == nil && !wasNotWalked(path)
        }
    }

    /// Extensions a re-survey will open: the offline generator's set, intersected with what this
    /// app can read. Office files are left out because their helper isn't here; this gates reading,
    /// not keeping, so one already in the corpus keeps its tokens and follows moves
    /// (``relocations(tree:corpus:)``). Never wider than the generator's (no `.md`, say): a survey
    /// extends the corpus, so it reads only what the corpus was made of, or the IDF mixes in notes.
    public static let readableExtensions: Set<String> = [
        "pdf", "txt", "csv", "jpg", "jpeg", "png",
    ]

    /// Flattens a walked tree into stamps, relative to the walk's root. Paths are built from node
    /// names, never by stripping the root string (as
    /// ``FilingEngine/relativeFolderPaths(of:limit:)`` does), so keys match even when the root comes
    /// as `/var/…` once and `/private/var/…` the next time.
    public static func flatten(_ taxonomy: [FileNode]) -> Tree {
        var folders: [String: Int] = [:]
        var documents: [String: Stamp] = [:]
        var unexplored: Set<String> = []
        func walk(_ node: FileNode, prefix: String) {
            // Dot-files are Finder and sync-provider bookkeeping, never filed documents.
            guard !node.name.hasPrefix(".") else { return }
            let rel = prefix.isEmpty ? node.name : prefix + "/" + node.name
            if node.isDirectory {
                // A folder whose children weren't walked must not be recorded as up to date: its
                // mtime would vouch for contents nobody looked at. Remembered, not just skipped, so
                // "nobody looked" stays distinct from "these documents are gone".
                guard node.isUnexplored != true else {
                    unexplored.insert(rel)
                    return
                }
                folders[rel] = Int(node.modificationDate?.timeIntervalSince1970 ?? 0)
                for child in node.children ?? [] { walk(child, prefix: rel) }
            } else {
                documents[rel] = Stamp(size: node.fileSize ?? 0,
                                       modified: Int(node.modificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        for node in taxonomy { walk(node, prefix: "") }
        return Tree(folders: folders, documents: documents, unexplored: unexplored)
    }

    // MARK: - What changed

    /// Folders that are new, or whose contents moved, since the memory learned them: one integer
    /// compare per folder. A folder absent from the memory counts as stale (new, or nothing in it
    /// was readable). A folder's mtime misses in-place edits of a child, so this only narrows what
    /// to report; ``documentsToRead(tree:corpus:)`` decides what gets opened.
    public static func staleFolders(tree: Tree, memory: FilingMemory?) -> Set<String> {
        var out: Set<String> = []
        for (folder, mtime) in tree.folders {
            guard let entry = memory?.folders[folder] else { out.insert(folder); continue }
            if entry.folderModified != mtime { out.insert(folder) }
        }
        return out
    }

    /// The part of the tree a survey belongs in: every folder on the path to something already
    /// surveyed. A survey extends a corpus and doesn't widen its scope; what the offline survey
    /// skipped leaves no readable mark, so scope comes from where documents were surveyed, closed
    /// upwards. A new folder under a surveyed one gets learned; a never-surveyed branch stays out.
    /// Empty means unscoped: with no corpus and no memory, the first survey reads the whole tree.
    public static func surveyedRegion(corpus: FilingCorpus?, memory: FilingMemory?) -> Set<String> {
        var out: Set<String> = []
        func addAncestors(of folder: String) {
            var current = folder
            while !current.isEmpty, !out.contains(current) {
                out.insert(current)
                current = (current as NSString).deletingLastPathComponent
            }
        }
        for path in corpus?.documents.keys ?? [:].keys {
            addAncestors(of: (path as NSString).deletingLastPathComponent)
        }
        for folder in memory?.folders.keys ?? [:].keys { addAncestors(of: folder) }
        return out
    }

    /// Whether a document sits inside the surveyed region: a folder above it was surveyed before.
    static func isInScope(_ path: String, region: Set<String>) -> Bool {
        guard !region.isEmpty else { return true }
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            if region.contains(folder) { return true }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Documents whose page 1 must be read again: new, restamped, or never indexed. Shallowest
    /// first, then by name, so progress is recognisable and two runs read in the same order.
    public static func documentsToRead(tree: Tree, corpus: FilingCorpus?,
                                       memory: FilingMemory? = nil) -> [String] {
        let relocated = relocations(tree: tree, corpus: corpus)
        let region = surveyedRegion(corpus: corpus, memory: memory)
        var out: [String] = []
        for (path, stamp) in tree.documents {
            let ext = (path as NSString).pathExtension.lowercased()
            guard readableExtensions.contains(ext) else { continue }
            guard isInScope(path, region: region) else { continue }
            // A file that only moved is already accounted for: its tokens travel with it.
            if relocated[path] != nil { continue }
            if let known = corpus?.documents[path], known.size == stamp.size, known.modified == stamp.modified {
                continue
            }
            out.append(path)
        }
        return FilingEngine.shallowestFirst(out, then: <)
    }

    /// New path → the corpus path whose tokens belong to it, for documents that only moved, the most
    /// common change. A move keeps size and mtime, so a gone corpus entry matches a new path with
    /// the same stamp and extension. Both sides must be unique for the stamp: guessing between two
    /// matches would credit one document's content to the other's folder.
    public static func relocations(tree: Tree, corpus: FilingCorpus?) -> [String: String] {
        guard let corpus, !corpus.isEmpty else { return [:] }
        var lostByStamp: [Stamp: [String]] = [:]
        // Lost means the walk looked and didn't find it. A document under a folder it couldn't
        // enter is unseen, and counting it lost lets a chance stamp match record a false move
        // (``Tree/showsGone(_:)``).
        for (path, doc) in corpus.documents where tree.showsGone(path) {
            lostByStamp[Stamp(size: doc.size, modified: doc.modified), default: []].append(path)
        }
        guard !lostByStamp.isEmpty else { return [:] }
        var foundByStamp: [Stamp: [String]] = [:]
        for (path, stamp) in tree.documents where corpus.documents[path] == nil {
            foundByStamp[stamp, default: []].append(path)
        }
        var out: [String: String] = [:]
        for (stamp, found) in foundByStamp {
            guard found.count == 1, let lost = lostByStamp[stamp], lost.count == 1 else { continue }
            guard (found[0] as NSString).pathExtension.lowercased()
                    == (lost[0] as NSString).pathExtension.lowercased() else { continue }
            out[found[0]] = lost[0]
        }
        return out
    }

    /// The corpus brought up to date: relocations followed, vanished documents dropped, freshly read
    /// ones merged in. Dropping matters: a document that left a folder must stop counting towards it.
    /// **Drop only what the walk looked for and missed.** A folder it couldn't enter contributes
    /// nothing to `tree.documents`; treating that as deletion would permanently erase everything
    /// learned under it, and this file is the only copy of months of reads (`Tree.wasNotWalked`).
    public static func merge(corpus: FilingCorpus, tree: Tree,
                             read: [String: FilingCorpusDocument]) -> FilingCorpus {
        let relocated = relocations(tree: tree, corpus: corpus)
        var documents: [String: FilingCorpusDocument] = [:]
        documents.reserveCapacity(corpus.documents.count + read.count)
        for (path, doc) in corpus.documents where !tree.showsGone(path) {
            documents[path] = doc
        }
        for (now, before) in relocated {
            guard let doc = corpus.documents[before] else { continue }
            documents[now] = doc
        }
        for (path, doc) in read { documents[path] = doc }
        return FilingCorpus(profileId: corpus.profileId, salt: corpus.salt, documents: documents)
    }

    // MARK: - Reading one document

    /// Whether a document's bytes are on this disk to be read. **A cloud-only placeholder is skipped
    /// whole**, not read and not stamped: the extractor won't download it and returns nothing, and
    /// stamping that as blank would never look again, writing off an offloaded folder in one pass.
    /// The check must be provider-agnostic (``MaterializationStatus``). iCloud's signals alone miss
    /// Dropbox, OneDrive, Google Drive and Box placeholders: opening one makes the provider download
    /// it (a scan must never do that), and offline it would be stamped blank for good.
    public static func isAvailable(_ path: String) -> Bool {
        isAvailable(path, statFlags: MaterializationStatus.realStatFlags)
    }

    /// The decision, with only the `lstat` substitutable (``MaterializationStatus/StatFlags`` says
    /// why that is the one honest test seam).
    static func isAvailable(_ path: String, statFlags: MaterializationStatus.StatFlags) -> Bool {
        // First, the provider-agnostic check: every File Provider, Apple's included, sets
        // `SF_DATALESS` on a placeholder, and an lstat reads it without fetching anything.
        if MaterializationStatus.isCloudOnly(atPath: path, statFlags: statFlags) { return false }
        // Then iCloud's own signal, which the flag lacks: `.downloaded` (not `.current`) means the
        // bytes are local but stale, still not the document to learn from.
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                             .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status == .current
    }

    /// How much of page 1 a document is judged on: the router's measured sample, also used by the
    /// offline builder and the folder profile. A statement or bill says what it is in its first
    /// lines.
    public static let snippetChars = 400

    /// One document's contribution, from the extractor's text. Taken as it came, with no whitespace
    /// normalisation: the stored memory and its measured accuracy were built under this rule, and
    /// changing the sample is a retuning, not a survey.
    public static func document(fromPage1 text: String, stamp: Stamp, salt: String) -> FilingCorpusDocument {
        let snippet = String(text.prefix(snippetChars))
        guard isDecodable(snippet) else {
            return FilingCorpusDocument(size: stamp.size, modified: stamp.modified,
                                        anchors: [], idHashes: [])
        }
        var anchors: Set<String> = []
        var ids: Set<String> = []
        for token in FilingRouter.tokenize(snippet) {
            if FilingRouter.isIdentifier(token) {
                ids.insert(FilingMemory.hash(token, salt: salt))
            } else if !token.allSatisfy(\.isNumber) {
                anchors.insert(token)
            }
        }
        // Sorted so the file is stable across runs and a diff of two corpora shows real change.
        return FilingCorpusDocument(size: stamp.size, modified: stamp.modified,
                                    anchors: anchors.sorted(), idHashes: ids.sorted())
    }

    /// Whether extracted text is words rather than glyph codes. A PDF whose fonts lack a `ToUnicode`
    /// map extracts without error and returns symbol soup, which would become the folder's anchors
    /// at top rarity. Deliberately crude: enough words of three letters or more, a few ordinary
    /// English ones, and an average word length glyph soup doesn't reach.
    static func isDecodable(_ text: String) -> Bool {
        var words: [String] = []
        var current = ""
        for ch in text.unicodeScalars {
            if CharacterSet.letters.contains(ch), ch.isASCII {
                current.unicodeScalars.append(ch)
            } else {
                if current.count >= 3 { words.append(current.lowercased()) }
                current = ""
            }
        }
        if current.count >= 3 { words.append(current.lowercased()) }
        guard words.count >= 8 else { return false }
        let ordinary = words.filter { commonWords.contains($0) }.count
        let totalLength = words.reduce(0) { $0 + $1.count }
        return Double(ordinary) / Double(words.count) >= 0.03
            && Double(totalLength) / Double(words.count) >= 3.5
    }

    /// Words ordinary enough that real correspondence contains some. Not a stop list: they are
    /// evidence for readability, and several are good anchors too.
    static let commonWords: Set<String> = [
        "the", "and", "for", "you", "your", "with", "from", "this", "that", "have", "has", "are",
        "was", "were", "will", "not", "all", "any", "account", "statement", "date", "total",
        "amount", "payment", "due", "balance", "page", "number", "service", "address", "name",
        "bill", "invoice", "tax", "year", "period", "charges", "usage", "summary", "customer",
        "credit", "card", "bank", "report", "notice", "letter", "form", "insurance", "policy",
        "claim", "member", "health", "plan", "visit", "dear", "please",
    ]

    // MARK: - Building the memory

    /// Caps and gates, matching the offline builder's.
    static let maxAnchors = 24
    static let maxIdHashes = 32
    /// A token in more than about half the tree carries nothing. `log((NF+1)/(df+1)) > 0.5` is
    /// roughly `df < 0.6 × NF`.
    static let minimumIDF = 0.5

    /// Rebuilds the whole memory from the corpus. `folderModified` is the walk's stamp for each
    /// entry, so the next survey compares against what was on disk when this one ran.
    public static func buildMemory(corpus: FilingCorpus, folderModified: [String: Int],
                                   profileId: String? = nil) -> FilingMemory {
        // Documents per token, per folder. Two counters, not the builder's one: an id arrives
        // hashed, and a hash with no digit would pass as an anchor and put hex in a prompt.
        var folderAnchors: [String: [String: Int]] = [:]
        var folderIds: [String: [String: Int]] = [:]
        var folderDocs: [String: Int] = [:]

        for (path, doc) in corpus.documents {
            guard !doc.isBlank else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            // A document sitting at the root belongs to no folder the router can suggest.
            guard !folder.isEmpty else { continue }
            // Content tokens plus the filename stem's, derived here so a rename costs nothing. The
            // extension is a type, not a subject.
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var anchors = Set(doc.anchors)
            var ids = Set(doc.idHashes)
            for token in FilingRouter.tokenize(stem) {
                if FilingRouter.isIdentifier(token) {
                    ids.insert(FilingMemory.hash(token, salt: corpus.salt))
                } else if !token.allSatisfy(\.isNumber) {
                    anchors.insert(token)
                }
            }
            folderDocs[folder, default: 0] += 1
            for t in anchors { folderAnchors[folder, default: [:]][t, default: 0] += 1 }
            for t in ids { folderIds[folder, default: [:]][t, default: 0] += 1 }
        }

        // Rarity is measured in folders, not documents: a token every payslip in one folder carries
        // is still a perfect signal for that folder.
        let folderCount = folderDocs.count
        var documentFrequency: [String: Int] = [:]
        for counts in folderAnchors.values {
            for t in counts.keys { documentFrequency[t, default: 0] += 1 }
        }
        for counts in folderIds.values {
            for t in counts.keys { documentFrequency[t, default: 0] += 1 }
        }
        let denominator = Double(folderCount + 1)
        func idf(_ token: String) -> Double {
            log(denominator / Double((documentFrequency[token] ?? 0) + 1))
        }

        var entries: [String: FilingMemoryEntry] = [:]
        for (folder, docs) in folderDocs {
            // With three or more documents, require recurrence: a token in only one is usually
            // extraction noise, which scores the highest rarity because it occurs nowhere else.
            let minimumCount = docs >= 3 ? 2 : 1
            let anchors = rank(folderAnchors[folder] ?? [:], documents: docs,
                               minimumCount: minimumCount, limit: maxAnchors, idf: idf,
                               dropBareNumbers: true)
            let ids = rank(folderIds[folder] ?? [:], documents: docs,
                           minimumCount: minimumCount, limit: maxIdHashes, idf: idf,
                           dropBareNumbers: false)
            entries[folder] = FilingMemoryEntry(docs: docs, anchors: anchors, idHashes: ids,
                                                folderModified: folderModified[folder])
        }
        return FilingMemory(profileId: profileId ?? corpus.profileId, salt: corpus.salt, folders: entries)
    }

    /// `memory` with documents filed since the last survey folded into their folders, so the next
    /// file like one just filed goes to the same place. Per folder, not a rebuild (that is the
    /// survey's job): token counts are read back from each kept token's share, the new documents
    /// added, and ``rank`` selects again under the same floor and cap.
    ///
    /// A kept token keeps its weight. A new one is priced by `foldersWith`, from
    /// ``folderFrequency(_:)`` over the survey's corpus; without it, by the folders whose kept
    /// anchors include it, which under-counts: a common word like `page` reads as rare, and a folder
    /// taught one document starts winning other folders' files on it.
    ///
    /// `filed` maps a folder (relative, as the memory keys it) to one anchor set per document.
    /// Identifiers are left out: they are stored hashed under the survey's salt, and a raw account
    /// number must not be persisted waiting for one.
    public static func memory(_ memory: FilingMemory, addingFiled filed: [String: [Set<String>]],
                              foldersWith counted: (folders: Int, perToken: [String: Int])? = nil) -> FilingMemory {
        let incoming = filed.filter { !$0.value.isEmpty }
        guard !incoming.isEmpty else { return memory }
        var foldersWith: [String: Int] = counted?.perToken ?? [:]
        if counted == nil {
            for entry in memory.folders.values {
                for t in entry.anchors { foldersWith[t.token, default: 0] += 1 }
            }
        }
        let folderCount = max(counted?.folders ?? 0, Set(memory.folders.keys).union(incoming.keys).count)
        var folders = memory.folders
        for (folder, documents) in incoming {
            let existing = memory.folders[folder]
            let kept = Dictionary(existing?.anchors.map { ($0.token, $0.weight) } ?? [],
                                  uniquingKeysWith: { a, b in max(a, b) })
            let before = existing?.docs ?? 0
            var counts: [String: Int] = [:]
            for t in existing?.anchors ?? [] {
                counts[t.token] = max(1, Int(((t.docFrequency ?? 1) * Double(before)).rounded()))
            }
            for anchors in documents {
                for t in anchors { counts[t, default: 0] += 1 }
            }
            let docs = before + documents.count
            let idf: (String) -> Double = { token in
                kept[token] ?? log(Double(folderCount + 1) / Double((foldersWith[token] ?? 0) + 1))
            }
            folders[folder] = FilingMemoryEntry(
                docs: docs,
                anchors: rank(counts, documents: docs, minimumCount: docs >= 3 ? 2 : 1,
                              limit: maxAnchors, idf: idf, dropBareNumbers: true),
                idHashes: existing?.idHashes ?? [], folderModified: existing?.folderModified)
        }
        return FilingMemory(profileId: memory.profileId, salt: memory.salt, folders: folders)
    }

    /// How many folders' documents carry each anchor, and how many folders hold documents: the
    /// rarity ``buildMemory(corpus:folderModified:profileId:)`` uses, so
    /// ``memory(_:addingFiled:foldersWith:)`` prices a newly filed word the same way.
    public static func folderFrequency(_ corpus: FilingCorpus) -> (folders: Int, perToken: [String: Int]) {
        var tokensIn: [String: Set<String>] = [:]
        for (path, doc) in corpus.documents where !doc.isBlank {
            let folder = (path as NSString).deletingLastPathComponent
            guard !folder.isEmpty else { continue }
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var anchors = Set(doc.anchors)
            for token in FilingRouter.tokenize(stem)
            where !FilingRouter.isIdentifier(token) && !token.allSatisfy(\.isNumber) {
                anchors.insert(token)
            }
            tokensIn[folder, default: []].formUnion(anchors)
        }
        var perToken: [String: Int] = [:]
        for tokens in tokensIn.values { for t in tokens { perToken[t, default: 0] += 1 } }
        return (tokensIn.count, perToken)
    }

    /// The anchors one filed document contributes: page 1 as the survey reads it, plus the name's
    /// stem as ``buildMemory(corpus:folderModified:profileId:)`` adds it, without identifiers.
    public static func filedAnchors(fileName: String, page1: String?) -> Set<String> {
        var anchors = Set(page1.map { document(fromPage1: $0, stamp: Stamp(size: 0, modified: 0), salt: "").anchors } ?? [])
        let stem = (fileName as NSString).deletingPathExtension
        for token in FilingRouter.tokenize(stem)
        where !FilingRouter.isIdentifier(token) && !token.allSatisfy(\.isNumber) {
            anchors.insert(token)
        }
        return anchors
    }

    /// The builder's selection rule for one folder's token counter. It sorts on one number and stores
    /// another, by design: selection weighs rarity by how often the folder saw the token
    /// (`idf × log(1 + n)`), while the stored weight is plain rarity, because the router scores how
    /// much a token discriminates, not how often this folder saw it.
    private static func rank(_ counts: [String: Int], documents: Int, minimumCount: Int, limit: Int,
                             idf: (String) -> Double, dropBareNumbers: Bool) -> [FilingMemoryToken] {
        var scored: [(token: String, score: Double, weight: Double, share: Double)] = []
        scored.reserveCapacity(counts.count)
        for (token, n) in counts where n >= minimumCount {
            if dropBareNumbers, token.allSatisfy(\.isNumber) { continue }
            let rarity = idf(token)
            guard rarity > minimumIDF else { continue }
            // Also store the share of this folder's documents the token recurs in, which a rule
            // needs alongside rarity (``FilingMemoryToken/docFrequency``).
            scored.append((token, rarity * log(1 + Double(n)), round2(rarity),
                           round2(Double(n) / Double(max(documents, 1)))))
        }
        // Ties broken by token, so the same corpus always produces the same file.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.token < $1.token }
        return scored.prefix(limit).map {
            FilingMemoryToken(token: $0.token, weight: $0.weight, docFrequency: $0.share)
        }
    }

    /// Two decimal places, ties to even — Python's `round`, so a cross-check against the offline
    /// builder diffs on substance rather than on the last digit of a weight.
    private static func round2(_ x: Double) -> Double {
        (x * 100).rounded(.toNearestOrEven) / 100
    }
}
