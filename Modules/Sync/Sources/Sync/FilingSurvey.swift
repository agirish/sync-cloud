import Foundation

/// Re-derives ``FilingMemory`` from what is on disk now, reading only what changed.
///
/// The memory shipped as a static artifact: a survey produced it offline and the app read it. That is
/// fine for a tree that stands still, and this one does not — the whole point of Filing is that
/// documents land in folders, and a folder created after the last survey has no learned content at
/// all, so it ranks on its name alone (the 28.9% signal) while every surveyed sibling ranks on what
/// it has received (58.2%).
///
/// **The expensive half is extraction, and only extraction.** Deriving the memory from tokens is
/// arithmetic over a few hundred thousand entries — under a second. Reading page 1 of every document
/// to *get* those tokens is hours. So ``FilingCorpus`` keeps the tokens, the walk that Organize
/// already does supplies the stamps, and a re-survey reads only the documents whose size or mtime
/// moved. The memory itself is then rebuilt **in full**, every time: IDF is a corpus-wide quantity,
/// and a partial rebuild would weigh a new folder's anchors on a different denominator from its
/// neighbours' — the kind of divergence that shows up as a quietly worse ranking and nothing else.
///
/// This is a port of the offline builder (`build_memory_extended.py`), rule for rule, and it shares
/// the router's tokenizer rather than restating it — see ``FilingRouter/tokenize(_:)``. The two
/// tokenizers agreeing is not a nicety: an anchor this side splits differently from the one the
/// stored memory holds simply stops matching, silently, as a lower score.
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

        public init(folders: [String: Int], documents: [String: Stamp]) {
            self.folders = folders
            self.documents = documents
        }
    }

    /// Extensions the app's own extractor can read — PDF text layers, plain text, and images via
    /// OCR. **Deliberately narrower than the offline generator's list**, which also reads `.docx`,
    /// `.pptx` and `.xlsx` through a helper this app does not carry.
    ///
    /// The narrowness is contained rather than damaging, because it gates *reading*, not *keeping*:
    /// an Office document already in the corpus keeps its tokens, and follows its folder when it
    /// moves (see ``relocations(tree:corpus:)``). What the app cannot read, it leaves alone — the
    /// alternative, reading it, failing, and recording a blank, would delete a real signal and call
    /// it a survey.
    public static let readableExtensions: Set<String> = [
        "pdf", "txt", "md", "markdown", "csv", "tsv", "log", "text",
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "bmp",
    ]

    /// Flattens a walked tree into stamps, relative to the walk's root.
    ///
    /// Paths are built structurally from node names, never by string-stripping the root — the same
    /// rule ``FilingEngine/relativeFolderPaths(of:limit:)`` follows, so a corpus key and a memory key
    /// name the same folder even when the root arrives as `/var/…` one time and `/private/var/…` the
    /// next.
    public static func flatten(_ taxonomy: [FileNode]) -> Tree {
        var folders: [String: Int] = [:]
        var documents: [String: Stamp] = [:]
        func walk(_ node: FileNode, prefix: String) {
            // Dot-files are Finder and sync-provider bookkeeping, never filed documents.
            guard !node.name.hasPrefix(".") else { return }
            let rel = prefix.isEmpty ? node.name : prefix + "/" + node.name
            if node.isDirectory {
                // A folder whose children were not walked (depth cap, symlink cycle) must not be
                // recorded as up-to-date: its mtime would then vouch for contents nobody looked at.
                guard node.isUnexplored != true else { return }
                folders[rel] = Int(node.modificationDate?.timeIntervalSince1970 ?? 0)
                for child in node.children ?? [] { walk(child, prefix: rel) }
            } else {
                documents[rel] = Stamp(size: node.fileSize ?? 0,
                                       modified: Int(node.modificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        for node in taxonomy { walk(node, prefix: "") }
        return Tree(folders: folders, documents: documents)
    }

    // MARK: - What changed

    /// Folders that are new, or whose contents moved, since the memory learned them.
    ///
    /// This is the cheap question — one integer compare per folder, against stamps the walk already
    /// carries — and it is what makes the whole feature affordable. A folder absent from the memory
    /// counts as stale, which covers both a genuinely new folder and one whose documents never
    /// yielded anything readable.
    ///
    /// Note what a directory mtime does and does not see: it moves when a child is added, removed or
    /// renamed, and **not** when a child is edited in place. That is why documents are stamped
    /// individually as well — this narrows *which folders to look at* for reporting, while
    /// ``documentsToRead(tree:corpus:)`` decides what actually gets opened.
    public static func staleFolders(tree: Tree, memory: FilingMemory?) -> Set<String> {
        var out: Set<String> = []
        for (folder, mtime) in tree.folders {
            guard let entry = memory?.folders[folder] else { out.insert(folder); continue }
            if entry.folderModified != mtime { out.insert(folder) }
        }
        return out
    }

    /// Documents whose page 1 has to be read again — new, restamped, or never indexed.
    ///
    /// Ordered shallowest-first then by name so a long survey progresses through the tree in a way a
    /// person watching a counter can recognise, and so two runs over the same tree read in the same
    /// order.
    public static func documentsToRead(tree: Tree, corpus: FilingCorpus?) -> [String] {
        let relocated = relocations(tree: tree, corpus: corpus)
        var out: [String] = []
        for (path, stamp) in tree.documents {
            let ext = (path as NSString).pathExtension.lowercased()
            guard readableExtensions.contains(ext) else { continue }
            // A file that only moved is already accounted for: its tokens travel with it.
            if relocated[path] != nil { continue }
            if let known = corpus?.documents[path], known.size == stamp.size, known.modified == stamp.modified {
                continue
            }
            out.append(path)
        }
        return out.sorted { a, b in
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            if da != db { return da < db }
            return a < b
        }
    }

    /// New path → the corpus path whose tokens belong to it, for documents that only moved.
    ///
    /// **A move is the most common change in this tree, and re-reading one is pure waste** — filing a
    /// document is exactly what Organize does for a living. A rename or a move leaves size and mtime
    /// untouched, so a corpus entry whose path is gone can be matched to a new path with the same
    /// stamp and extension. Both sides must be unique for that stamp: two files that genuinely share
    /// a size to the byte and an mtime to the second are indistinguishable here, and guessing between
    /// them would attribute one document's content to the other's folder. The offline builder makes
    /// the same call from the same motive, matching on basename and requiring exactly one candidate.
    public static func relocations(tree: Tree, corpus: FilingCorpus?) -> [String: String] {
        guard let corpus, !corpus.isEmpty else { return [:] }
        var lostByStamp: [Stamp: [String]] = [:]
        for (path, doc) in corpus.documents where tree.documents[path] == nil {
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
    /// ones merged in.
    ///
    /// **Dropping is as important as adding.** A document that moved out of a folder must stop
    /// counting towards it, or the folder keeps recommending itself for the very thing that left —
    /// and since every filing move is a departure from somewhere, a corpus that only ever grows is
    /// wrong within a day of use.
    public static func merge(corpus: FilingCorpus, tree: Tree,
                             read: [String: FilingCorpusDocument]) -> FilingCorpus {
        let relocated = relocations(tree: tree, corpus: corpus)
        var documents: [String: FilingCorpusDocument] = [:]
        documents.reserveCapacity(corpus.documents.count + read.count)
        for (path, doc) in corpus.documents where tree.documents[path] != nil {
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

    /// Whether a document is actually on this disk to be read.
    ///
    /// **An evicted iCloud file is not an unreadable document, and the difference is permanent.**
    /// The extractor declines to force-download one, so it comes back with nothing — exactly like an
    /// image-only scan. Recording that as "read, nothing there" would stamp it and never look again,
    /// and on a tree that lives in iCloud Documents an offloaded folder would be written off in one
    /// pass. So availability is asked separately, and an unavailable document is skipped whole:
    /// not read, not stamped, still there to be learned from once it comes back.
    public static func isAvailable(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                             .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus else { return true }
        return status == .current
    }

    /// How much of page 1 a document is judged on. The router's own measured sample, and the rule
    /// the offline builder and the folder profile both follow: a statement, form, letter or bill says
    /// what it is in its first few lines, and what follows is line items.
    public static let snippetChars = 400

    /// One document's contribution, from the text the extractor produced.
    ///
    /// **The text is taken as it came — no whitespace normalisation.** Collapsing runs of spaces
    /// would fit more words into the same 400 characters and, on the face of it, read better; it
    /// would also mean these tokens were derived under a different rule from the 9,525 documents the
    /// shipped memory was built from, and the routing accuracy that memory is measured at was
    /// measured under this one. Changing the sample is a retuning exercise, not a survey.
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

    /// Whether extracted text is words rather than glyph codes.
    ///
    /// **A PDF whose fonts carry no `ToUnicode` map extracts *successfully* and returns nonsense** —
    /// a utility's bills came back as `') ! ) ) ! A A @ A 1 < H <`. No error is raised and the text
    /// is not empty, so without this the nonsense becomes the folder's anchors, and takes top rarity
    /// precisely because it occurs nowhere else. Three states, not two: readable, undecodable,
    /// absent.
    ///
    /// The test is deliberately crude — enough three-letter-plus words, a few of them ordinary
    /// English, and an average word length a glyph soup does not reach.
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

    /// Words ordinary enough that real correspondence contains some of them. Not a stop list — these
    /// are evidence *for* readability, and several are also perfectly good anchors.
    static let commonWords: Set<String> = [
        "the", "and", "for", "you", "your", "with", "from", "this", "that", "have", "has", "are",
        "was", "were", "will", "not", "all", "any", "account", "statement", "date", "total",
        "amount", "payment", "due", "balance", "page", "number", "service", "address", "name",
        "bill", "invoice", "tax", "year", "period", "charges", "usage", "summary", "customer",
        "credit", "card", "bank", "report", "notice", "letter", "form", "insurance", "policy",
        "claim", "member", "health", "plan", "visit", "dear", "please",
    ]

    // MARK: - Building the memory

    /// Caps and gates, named where the builder that wrote today's artifact has them.
    static let maxAnchors = 24
    static let maxIdHashes = 32
    /// A token in more than about half the tree carries nothing. `log((NF+1)/(df+1)) > 0.5` is
    /// roughly `df < 0.6 × NF`.
    static let minimumIDF = 0.5

    /// Rebuilds the whole memory from the corpus.
    ///
    /// `folderModified` supplies the stamp each entry is written with — the walk's reading, so the
    /// next survey compares against what was actually on disk when this one ran.
    public static func buildMemory(corpus: FilingCorpus, folderModified: [String: Int],
                                   profileId: String? = nil) -> FilingMemory {
        // Documents-per-token, per folder. Two counters rather than the builder's one: an id arrives
        // already hashed, and a hash that happened to contain no digit would be re-classified as a
        // readable anchor — a one-in-millions event that would put a hex string in a prompt. Keeping
        // the two spaces apart makes it impossible rather than unlikely.
        var folderAnchors: [String: [String: Int]] = [:]
        var folderIds: [String: [String: Int]] = [:]
        var folderDocs: [String: Int] = [:]

        for (path, doc) in corpus.documents {
            guard !doc.isBlank else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            // A document sitting at the root belongs to no folder the router can suggest.
            guard !folder.isEmpty else { continue }
            // Content tokens, plus the filename's — derived here rather than stored, so a rename
            // costs nothing. The stem only: the extension is a type, not a subject.
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

        // Rarity is measured in folders, not documents: a token that fourteen payslips in one folder
        // all carry is still a perfect signal for that folder.
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
            // **Recurrence, where there is enough evidence to ask for it.** A token appearing in
            // exactly one of a folder's documents is usually extraction noise, and noise takes the
            // highest rarity score precisely because it occurs nowhere else — this is what put `d9`,
            // `lm` and `g8` at the top of a utility folder's anchors ahead of `pge`.
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

    /// The builder's selection rule for one folder's token counter.
    ///
    /// **What is sorted on and what is stored are different numbers**, and that is the builder's
    /// design rather than an oversight: selection weighs rarity by how often the folder actually saw
    /// the token (`idf × log(1 + n)`), so a rare word seen once loses to a slightly commoner word
    /// seen in half the folder's documents. What is *stored* is the plain rarity, because the router
    /// scores a match on how much the token discriminates, not on how often this folder happened to
    /// see it — the count is already reflected in the folder having been chosen at all.
    private static func rank(_ counts: [String: Int], documents: Int, minimumCount: Int, limit: Int,
                             idf: (String) -> Double, dropBareNumbers: Bool) -> [FilingMemoryToken] {
        var scored: [(token: String, score: Double, weight: Double, share: Double)] = []
        scored.reserveCapacity(counts.count)
        for (token, n) in counts where n >= minimumCount {
            if dropBareNumbers, token.allSatisfy(\.isNumber) { continue }
            let rarity = idf(token)
            guard rarity > minimumIDF else { continue }
            // The share of this folder's documents the token comes back in — the recurrence half,
            // which answers the opposite question from rarity and which a rule needs. See
            // ``FilingMemoryToken/docFrequency``. The count is already here; dropping it is how the
            // proposer ended up keying `awesome` over `autopay`.
            scored.append((token, rarity * log(1 + Double(n)), round2(rarity),
                           round2(Double(n) / Double(max(documents, 1)))))
        }
        // Ties broken by token, so the same corpus always produces the same file — the offline
        // builder leaned on dictionary insertion order here, which is reproducible within one Python
        // run and meaningless across two.
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
