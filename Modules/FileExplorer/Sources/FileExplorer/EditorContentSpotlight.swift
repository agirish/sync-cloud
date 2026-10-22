import Foundation
import Sync

/// **Search inside files (RD38): the PDF half** — Spotlight's index, asked which PDFs, Word and
/// PowerPoint files in the folder contain the word.
///
/// **Asked, never read here.** His documents are PDFs — 10,614 of them in ~/Documents — and
/// extracting their text ourselves would take about five and a half minutes on the PDFKit lane the
/// duplicate scan and Filing wait on (`PDFKitSerialAccess`). Spotlight has already read them: the
/// same question took 0.5–3 s on his Mac on 21 October.
///
/// **What Spotlight answers is narrower than the text half's**, and the group says it is from
/// Spotlight so the difference has a name: it matches whole words and word starts (`lentil` finds
/// "lentils", `ntil` finds nothing), every word of the query separately, and it has not indexed a
/// file whose content is not on this Mac. It says which files match, not where — opening one runs
/// Edit's own PDF find with the word.
///
/// Text kinds are left out of the query — the text half reads those, and Spotlight skips `.yml`
/// and `.json` anyway.
@MainActor
final class EditorContentSpotlight {

    /// The kinds asked about: PDF, and Word and PowerPoint old and new.
    nonisolated static let contentTypes = [
        "com.adobe.pdf",
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
    ]

    /// The most files listed. More than a person reads in a rail; a word that common wants narrowing.
    nonisolated static let maxResults = 500

    /// The Spotlight query string for `query`, or `nil` when it has no word in it.
    ///
    /// Each word is a prefix (`*`), compared ignoring case and diacritics (`cd`) and as a word
    /// (`w`) — `mdfind`'s syntax, which `NSPredicate(fromMetadataQueryString:)` takes as written.
    /// A quote, a backslash or a `*` typed into the field is escaped, so it is searched for rather
    /// than read as syntax.
    nonisolated static func queryString(for query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return nil }
        let content = words.map { word -> String in
            var escaped = ""
            for character in word {
                if character == "\\" || character == "\"" || character == "*" { escaped.append("\\") }
                escaped.append(character)
            }
            return "kMDItemTextContent == \"\(escaped)*\"cdw"
        }
        let kinds = contentTypes.map { "kMDItemContentTypeTree == \"\($0)\"" }.joined(separator: " || ")
        return content.map { "(\($0))" }.joined(separator: " && ") + " && (\(kinds))"
    }

    /// The hit a Spotlight result is listed as, or `nil` for one outside the folder or under a
    /// hidden folder, which the text half does not walk either.
    ///
    /// **Re-spelled under the folder as the rail spells it.** Spotlight answers with the real path,
    /// and a folder reached through a link — `/var` is one, and iCloud Drive links in Desktop and
    /// Documents — would otherwise list paths the rail's own rows never use.
    nonisolated static func hit(forPath path: String, root: String, resolvedRoot: String) -> EditorContentHit? {
        let base: String
        if path.hasPrefix(root + "/") { base = root } else if path.hasPrefix(resolvedRoot + "/") {
            base = resolvedRoot
        } else { return nil }
        let relative = String(path.dropFirst(base.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        let spelled = (root as NSString).appendingPathComponent(relative)
        let kind: EditorContentHit.Kind = PairContentKind.classify(path: name) == .pdf ? .pdf : .document
        return EditorContentHit(path: spelled, name: name,
                                subfolder: parts.dropLast().joined(separator: "/"), kind: kind)
    }

    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    /// The running query's folder, both spellings, and who is waiting for it.
    private var root = ""
    private var resolvedRoot = ""
    private var answer: (@MainActor ([EditorContentHit]?) -> Void)?

    /// Starts a query, replacing any running. `answer` is called once, with the files in Finder's
    /// order by path — or with `nil` when Spotlight could not be asked at all.
    func start(_ text: String, in root: String, answer: @escaping @MainActor ([EditorContentHit]?) -> Void) {
        stop()
        guard let string = Self.queryString(for: text),
              let predicate = NSPredicate(fromMetadataQueryString: string) else {
            answer([])
            return
        }
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = [URL(fileURLWithPath: root, isDirectory: true)]
        self.root = root
        self.resolvedRoot = (root as NSString).resolvingSymlinksInPath
        self.answer = answer
        self.query = query
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.gathered() }
            }
        if !query.start() {
            stop()
            answer(nil)
        }
    }

    /// The query has read the index: list what it found, stop it, and answer.
    private func gathered() {
        guard let query, let answer else { return }
        query.disableUpdates()
        var hits: [EditorContentHit] = []
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let hit = Self.hit(forPath: path, root: root, resolvedRoot: resolvedRoot)
            else { continue }
            hits.append(hit)
        }
        stop()
        hits.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        // The `lstat` for each row kept, not for each of thousands Spotlight found.
        var kept = Array(hits.prefix(Self.maxResults))
        for index in kept.indices {
            kept[index].isCloudOnly = MaterializationStatus.isCloudOnly(atPath: kept[index].path)
        }
        answer(kept)
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query?.stop()
        query = nil
        answer = nil
    }
}
