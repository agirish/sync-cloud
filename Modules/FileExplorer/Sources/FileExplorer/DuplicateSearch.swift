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
            if let kind, !LensKind.matches(kind, fileName: group.name) { return false }
            let size = group.keeper.size
            if let sizeAtLeast, size < sizeAtLeast { return false }
            if let sizeAtMost, size > sizeAtMost { return false }
            if text.isEmpty { return true }
            return group.name.range(of: text, options: .caseInsensitive) != nil
        }
    }

    static func parse(_ raw: String) -> Query {
        var kind: String?
        var atLeast: Int?
        var atMost: Int?
        // No recognized tokens: freeText keeps the raw string verbatim, a plain substring search.
        let text = TokenQuery.freeText(raw) { word in
            let lower = word.lowercased()
            if let ext = LensKind.word(lower) { kind = ext; return true }
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
    /// chips like Compare's; the label formats sizes the way the app shows them. kind, `>` and `<`
    /// are each single-valued, so each is a last-wins family.
    typealias Chip = TokenChip

    /// The `kind:` and size words in `raw`, in order, as chips; free name text is left out. Within
    /// each family only the last is `isActive`, matching `parse` (via `TokenQuery.lastWinsChips`).
    static func chips(_ raw: String) -> [Chip] {
        TokenQuery.lastWinsChips(raw) { word in
            let lower = word.lowercased()
            if let ext = LensKind.word(lower) { return (Chip(raw: word, label: "kind: \(ext)"), "kind") }
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
