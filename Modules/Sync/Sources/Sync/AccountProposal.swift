import Foundation

/// A statement from a bank the tree knows, for an account no folder holds yet: a new account folder
/// named and placed like the accounts beside it (decision 7, design §2.8). Chase checking statements,
/// with BofA's `Bank Accounts/Bank of America/Checking 5696` filed by year, become
/// `Bank Accounts/Chase/Checking 0779/2026`. Always NEW, never above Medium, and the path is the
/// user's to edit before anything is created.
public enum AccountProposal {

    public struct Proposal: Sendable, Equatable {
        /// The new account folder, relative to the walked root (`Bank Accounts/Chase/Checking 0779`).
        public let accountRoot: String
        /// Below it, the year folder when the accounts it copies file by year ("" otherwise).
        public let yearFolder: String
        /// The trailing segments that don't exist yet.
        public let newSegments: [String]
        public let ending: String
        /// The account it was named after (`Bank Accounts/Bank of America/Checking 5696`), for the
        /// card's "named like" line; nil when it fell back to the bank's folder alone.
        public let namedLike: String?

        public var folder: String { yearFolder.isEmpty ? accountRoot : accountRoot + "/" + yearFolder }
    }

    /// The type and number a source folder names (`Checking 0779` → ("Checking", "0779")), from the
    /// deepest hint segment that has both; nil when none does.
    /// The type, number and name an inbox folder gives an account. Only the account-level folder
    /// counts, the deepest one that isn't a year (a bank-level `ScholarShare 529` names none), and its
    /// own spelling is the name (`Credit 31001 (Shweta)`, `401k 4138`).
    static func typeAndDigits(inHint hint: String) -> (type: String, digits: String, name: String)? {
        guard let seg = hint.split(separator: "/").map(String.init)
            .last(where: { !FolderProfileEntry.looksLikeYear($0) }) else { return nil }
        guard let digits = AccountIndex.accountDigits(inFolderNamed: seg).last,
              seg.contains(where: \.isLetter) else { return nil }
        // The type is the words before the number: `Checking`, `Auto Lease`, `401k`.
        let beforeNumber = seg.components(separatedBy: digits).first ?? seg
        let type = beforeNumber.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.contains(where: \.isLetter) }.joined(separator: " ")
        return (type.isEmpty ? seg : type, String(digits.suffix(4)), seg)
    }

    /// The proposal for a statement whose page names `institution` and matches no account. `type`
    /// comes from the folder it arrived in (`Checking 0779`), so a statement loose in an inbox, or
    /// in a folder naming no type and number, gets no proposal; `ending` from the page, else that
    /// folder.
    public static func propose(institution: String, type: String?, ending: String?, name: String? = nil,
                               index: AccountIndex, tree: [FileNode], period: DocumentFacts.Period?,
                               fileName: String = "statement.pdf",
                               isArchived: (String) -> Bool = { _ in false }) -> Proposal? {
        let institutionFolders = folders(namedFor: institution, in: tree, isArchived: isArchived)
        guard !institutionFolders.isEmpty else { return nil }
        // 1. A live account of the same type: its category, and this bank's folder in it. Never an
        //    archived one, whose category could be `Archive` itself.
        var model: AccountIndex.Account?
        if let type {
            let t = type.lowercased()
            let same = index.accounts.filter { a in
                // Archived by name at any level, or by the survey at any level, the account's own included.
                let segs = a.root.split(separator: "/").map(String.init)
                guard !a.archived, !segs.contains(where: AccountIndex.isArchiveName),
                      !segs.indices.contains(where: { isArchived(segs[...$0].joined(separator: "/")) }) else { return false }
                let n = (a.root as NSString).lastPathComponent.lowercased()
                return n.hasPrefix(t + " ") || n == t
            }
            model = same.first { $0.institution == institution } ?? same.first
        }
        var parent: String?
        if let model, let modelInstitution = AccountIndex.institutionFolder(of: model.root, isArchived: isArchived)?.0 {
            let category = (modelInstitution as NSString).deletingLastPathComponent
            parent = institutionFolders.first { ($0 as NSString).deletingLastPathComponent == category }
                ?? (category.isEmpty ? nil : category + "/" + displayName(institution, from: institutionFolders))
        }
        // 2. Else this bank's folder holding the most live accounts.
        if parent == nil {
            func live(_ f: String) -> Int { index.accounts.filter { !$0.archived && $0.root.hasPrefix(f + "/") }.count }
            parent = institutionFolders.max { live($0) < live($1) }
        }
        guard let parent else { return nil }
        let accountName = name ?? [type, ending].compactMap { $0 }.joined(separator: " ")
        guard !accountName.isEmpty, !accountName.hasPrefix("."), FileSyncManager.validateItemName(accountName) == nil else { return nil }
        let accountRoot = parent + "/" + accountName
        // Inside it, the layout of the account it copies (`<year>`, `Statements/<year>`).
        var inside = ""
        if let model, let node = node(at: model.root, in: tree) {
            let place = AccountPlacement.place(in: node, period: period, taxForm: false, fileName: fileName)
            if !place.yearUnknown { inside = place.folder }
        }
        let full = inside.isEmpty ? accountRoot : accountRoot + "/" + inside
        return Proposal(accountRoot: accountRoot, yearFolder: inside,
                        newSegments: missing(full, in: tree), ending: ending ?? "", namedLike: model?.root)
    }

    /// Folders, outside any archive, whose own name is the institution's (case-insensitive).
    static func folders(namedFor institution: String, in tree: [FileNode],
                        isArchived: (String) -> Bool = { _ in false }) -> [String] {
        var out: [String] = []
        func visit(_ nodes: [FileNode], _ prefix: String, depth: Int) {
            guard depth < 6 else { return }
            for n in nodes where n.isDirectory {
                let rel = prefix.isEmpty ? n.name : prefix + "/" + n.name
                // Never an archive, never an inbox.
                if AccountIndex.isArchiveName(n.name) || isArchived(rel) || FolderProfile.isInboxPath(rel) { continue }
                if n.name.lowercased() == institution { out.append(rel) }
                visit(n.children ?? [], rel, depth: depth + 1)
            }
        }
        visit(tree, "", depth: 0)
        return out
    }

    static func displayName(_ institution: String, from folders: [String]) -> String {
        folders.first.map { ($0 as NSString).lastPathComponent }
            ?? institution.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func node(at path: String, in tree: [FileNode]) -> FileNode? {
        var nodes = tree
        var found: FileNode?
        for seg in path.split(separator: "/").map(String.init) {
            guard let n = nodes.first(where: { $0.isDirectory && $0.name == seg }) else { return nil }
            found = n
            nodes = n.children ?? []
        }
        return found
    }

    /// The trailing segments of `path` that don't exist in `tree`, compared ignoring case.
    static func missing(_ path: String, in tree: [FileNode]) -> [String] {
        var nodes = tree
        var out: [String] = []
        for seg in path.split(separator: "/").map(String.init) {
            if out.isEmpty, let n = nodes.first(where: { $0.isDirectory && $0.name.compare(seg, options: .caseInsensitive) == .orderedSame }) {
                nodes = n.children ?? []
            } else {
                out.append(seg)
            }
        }
        return out
    }
}
