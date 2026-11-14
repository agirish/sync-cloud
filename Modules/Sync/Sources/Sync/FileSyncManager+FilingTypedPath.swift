import Foundation

/// A home typed in full on the card (decision 7): `Vehicles/Tesla/Lease/Statements`, anywhere in the
/// surveyed tree, with the levels that don't exist yet made when the file is filed.
extension FileSyncManager {

    public enum TypedPathRefusal: Error, Equatable, Sendable {
        case noTree
        case empty
        case outsideTree(String)
        case invalidName(String)
        case hiddenName(String)
        case fileInTheWay(String)
        case intoSource
        case intoInbox(String)

        public var sentence: String {
            switch self {
            case .noTree: return "Scan a folder first."
            case .empty: return "Type a folder path."
            case .outsideTree(let root): return "Type a path inside “\((root as NSString).lastPathComponent)”."
            case .invalidName(let name): return "“\(name)” can’t be a folder name."
            case .hiddenName(let name): return "“\(name)” would be a hidden folder."
            case .fileInTheWay(let name): return "“\(name)” is a file, not a folder."
            case .intoSource: return "That’s the folder these files are being filed from."
            case .intoInbox(let name): return "“\(name)” is an inbox; files wait there to be filed."
            }
        }
    }

    /// `typed` as a home for `suggestion`, relative to the tree it was scanned against: the levels
    /// that exist (matched ignoring case and Unicode form, kept in their own spelling) and the ones
    /// it would create. A full path or `~/…` is fine when it is inside the tree.
    public func filingDestination(typed: String, for suggestion: FilingSuggestion) -> Result<FilingDestination, TypedPathRefusal> {
        guard let root = suggestion.providerRoot ?? filingLastProviderRoot else { return .failure(.noTree) }
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "~" || text.hasPrefix("~/") { text = (text as NSString).expandingTildeInPath }
        if text.hasPrefix("/") {
            guard let rel = Self.relativePath(text, under: root) else { return .failure(.outsideTree(root)) }
            text = rel
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        guard !parts.isEmpty else { return .failure(.empty) }
        for part in parts {
            if part == "." || part == ".." || part.isEmpty || Self.validateItemName(part) != nil { return .failure(.invalidName(part)) }
            if part.hasPrefix(".") { return .failure(.hiddenName(part)) }
        }
        for i in parts.indices where FolderProfile.isInboxPath(parts[i]) {
            return .failure(.intoInbox(parts[i]))
        }
        // On disk, not the walked tree: a typed level is NEW only if it really isn't there.
        let fm = fileManager
        func sameName(_ a: String, _ b: String) -> Bool {
            a.precomposedStringWithCanonicalMapping.lowercased() == b.precomposedStringWithCanonicalMapping.lowercased()
        }
        var existing = root
        var newSegments: [String] = []
        for part in parts {
            if newSegments.isEmpty,
               let match = ((try? FileManager.default.contentsOfDirectory(atPath: existing)) ?? []).first(where: { sameName($0, part) }) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: existing + "/" + match, isDirectory: &isDir), isDir.boolValue {
                    existing += "/" + match
                    continue
                }
                return .failure(.fileInTheWay(match))
            }
            newSegments.append(part)
        }
        // Through a link, the folder that exists may lie outside the tree or inside the source.
        let real = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        let realRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard PathBoundary.contains(real, under: realRoot) else { return .failure(.outsideTree(root)) }
        let path = ([existing] + newSegments).joined(separator: "/")
        if let source = filingScanFolder {
            let realSource = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
            if PathBoundary.contains(path, under: source) || PathBoundary.contains(real, under: realSource) {
                return .failure(.intoSource)
            }
        }
        return .success(FilingDestination(path: path, confidence: .high, reasons: ["You typed this path"],
                                          newSegments: newSegments,
                                          account: suggestion.best?.account.flatMap { PathBoundary.contains(path, under: $0.root) ? $0 : nil }))
    }

    /// Folders of the last scan's tree matching what is typed so far, shallowest first: the whole
    /// path's start, or the last segment's start under the folder already typed.
    public func filingPathCompletions(_ typed: String, limit: Int = 8) -> [String] {
        let t = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return [] }
        let folders = filingLastExistingFolders
        let parent = (t as NSString).deletingLastPathComponent
        let leaf = (t as NSString).lastPathComponent
        let hits = folders.filter { f in
            let l = f.lowercased()
            if l.hasPrefix(t) { return true }
            guard !parent.isEmpty, l.hasPrefix(parent + "/") else { return false }
            let rest = l.dropFirst(parent.count + 1)
            return !rest.contains("/") && rest.hasPrefix(leaf)
        }
        return hits.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
            .prefix(limit).map { $0 }
    }
}
