import Foundation
import Design
import Sync

/// Structured tokens for the Duplicates lens search: `kind:` and size comparators on top of a name
/// substring, reusing the Compare grammar (and its `DifferenceSearch.parseSize`) so one vocabulary
/// works across surfaces. A query with no recognized tokens is a plain case-insensitive match on
/// the group's name, so an empty field shows everything. Pure, so it's unit-tested without a view.
///
/// The mechanics (tokenizer, verbatim fallback, all-occurrences removal, last-wins chips) are
/// Design's shared `TokenQuery`; this grammar owns only its token table and `matches()`.
enum DuplicateSearch {

    struct Query: Equatable {
        var kind: String?          // lowercased extension, no dot
        var sizeAtLeast: Int?      // bytes, against the keeper's size
        var sizeAtMost: Int?
        var text: String

        func matches(_ group: DuplicateGroup) -> Bool {
            if let kind {
                let ext = (group.name as NSString).pathExtension.lowercased()
                if let classExtensions = DuplicateSearch.kindClasses[kind] {
                    if !classExtensions.contains(ext) { return false }
                } else if ext != kind {
                    return false
                }
            }
            let size = group.keeper.size
            if let sizeAtLeast, size < sizeAtLeast { return false }
            if let sizeAtMost, size > sizeAtMost { return false }
            if text.isEmpty { return true }
            return group.name.range(of: text, options: .caseInsensitive) != nil
        }
    }

    /// Class aliases for `kind:`: one word for a fixed extension set, so the "Images" suggestion
    /// means every image type, not just `jpg`. The table lives on `DifferenceSearch`, so Compare's
    /// `kind:image` means exactly the same thing.
    static let kindClasses: [String: Set<String>] = DifferenceSearch.kindClasses

    static func parse(_ raw: String) -> Query {
        var kind: String?
        var atLeast: Int?
        var atMost: Int?
        // No recognized tokens: freeText keeps the raw string verbatim, a plain substring search.
        let text = TokenQuery.freeText(raw) { word in
            let lower = word.lowercased()
            if lower.hasPrefix("kind:") {
                let ext = String(lower.dropFirst("kind:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !ext.isEmpty { kind = ext; return true }
            }
            if lower.hasPrefix(">"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                atLeast = bytes; return true
            }
            if lower.hasPrefix("<"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                atMost = bytes; return true
            }
            return false
        }
        return Query(kind: kind, sizeAtLeast: atLeast, sizeAtMost: atMost, text: text)
    }

    // MARK: Chips (UI)

    /// A recognized filter word with a human label, so the lens search field can draw removable
    /// chips like Compare's. `raw` is the exact word typed (e.g. `>5mb`), so a chip's ✕ removes
    /// precisely that word; the label formats sizes the way the app shows them.
    struct Chip: Equatable, DimmableTokenChip {
        var raw: String
        var label: String
        /// Whether this chip is part of the effective query. `parse` is last-wins within a family
        /// (kind, `>` and `<` are each single-valued), so only the last word of a family filters;
        /// earlier ones draw dimmed. Their ✕ still removes the superseded word.
        var isActive: Bool = true
    }

    /// The `kind:` and size words in `raw`, in order, as chips; free name text is left out. Within
    /// each family only the last is `isActive`, matching `parse` (via `TokenQuery.lastWinsChips`).
    static func chips(_ raw: String) -> [Chip] {
        TokenQuery.lastWinsChips(raw) { word in
            let lower = word.lowercased()
            if lower.hasPrefix("kind:") {
                let ext = String(lower.dropFirst("kind:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !ext.isEmpty { return (Chip(raw: word, label: "kind: \(ext)"), "kind") }
            }
            if lower.hasPrefix(">"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                return (Chip(raw: word, label: "> \(FileSyncManager.formatBytes(bytes))"), ">")
            }
            if lower.hasPrefix("<"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                return (Chip(raw: word, label: "< \(FileSyncManager.formatBytes(bytes))"), "<")
            }
            return nil
        }
    }
}
