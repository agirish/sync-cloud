import Foundation
import Sync

/// Structured tokens for the Tidy ▸ Duplicates search — `kind:` plus size comparators on top of a
/// name substring — reusing the Compare grammar (and its `DifferenceSearch.parseSize`) so one
/// vocabulary works across surfaces. A query with no recognized tokens is a plain case-insensitive
/// match on the group's name, so an empty field shows everything. Pure, so it's unit-tested without
/// a view.
enum DuplicateSearch {

    struct Query: Equatable {
        var kind: String?          // lowercased extension, no dot
        var sizeAtLeast: Int?      // bytes, against the keeper's size
        var sizeAtMost: Int?
        var text: String

        func matches(_ group: DuplicateGroup) -> Bool {
            if let kind, (group.name as NSString).pathExtension.lowercased() != kind { return false }
            let size = group.keeper.size
            if let sizeAtLeast, size < sizeAtLeast { return false }
            if let sizeAtMost, size > sizeAtMost { return false }
            if text.isEmpty { return true }
            return group.name.range(of: text, options: .caseInsensitive) != nil
        }
    }

    static func parse(_ raw: String) -> Query {
        let words = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var kind: String?
        var atLeast: Int?
        var atMost: Int?
        var freeWords: [String] = []
        var matchedAnyToken = false
        for word in words {
            let lower = word.lowercased()
            if lower.hasPrefix("kind:") {
                let ext = String(lower.dropFirst("kind:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !ext.isEmpty { kind = ext; matchedAnyToken = true; continue }
            }
            if lower.hasPrefix(">"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                atLeast = bytes; matchedAnyToken = true; continue
            }
            if lower.hasPrefix("<"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                atMost = bytes; matchedAnyToken = true; continue
            }
            freeWords.append(word)
        }
        let text = matchedAnyToken ? freeWords.joined(separator: " ") : raw
        return Query(kind: kind, sizeAtLeast: atLeast, sizeAtMost: atMost, text: text)
    }

    // MARK: Chips (UI)

    /// A recognized filter word paired with a human label, so the Tidy search field can render
    /// removable chips like Compare's. `raw` is the exact word typed (e.g. `>5mb`), so a chip's ✕
    /// removes precisely that word; the label formats sizes the way the app displays them.
    struct Chip: Equatable {
        var raw: String
        var label: String
    }

    /// The `kind:`/size words in `raw`, in order, as display chips. Free (name) text is excluded, so
    /// the chips are exactly the active structured filters.
    static func chips(_ raw: String) -> [Chip] {
        var out: [Chip] = []
        for word in raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            let lower = word.lowercased()
            if lower.hasPrefix("kind:") {
                let ext = String(lower.dropFirst("kind:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !ext.isEmpty { out.append(Chip(raw: word, label: "kind: \(ext)")) }
            } else if lower.hasPrefix(">"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                out.append(Chip(raw: word, label: "> \(FileSyncManager.formatBytes(bytes))"))
            } else if lower.hasPrefix("<"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                out.append(Chip(raw: word, label: "< \(FileSyncManager.formatBytes(bytes))"))
            }
        }
        return out
    }

    /// Removes the first occurrence of `word` from `raw`, leaving every other word as typed. Backs a
    /// chip's ✕ button.
    static func removing(_ raw: String, word: String) -> String {
        var removed = false
        var kept: [String] = []
        for candidate in raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
            if !removed, candidate == word { removed = true; continue }
            kept.append(candidate)
        }
        return kept.joined(separator: " ")
    }
}
