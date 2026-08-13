import Foundation
import Design
import Sync

/// Structured tokens for the Duplicates lens search — `kind:` plus size comparators on top of a
/// name substring — reusing the Compare grammar (and its `DifferenceSearch.parseSize`) so one
/// vocabulary works across surfaces. A query with no recognized tokens is a plain case-insensitive
/// match on the group's name, so an empty field shows everything. Pure, so it's unit-tested without
/// a view.
///
/// The mechanics (tokenizer, verbatim-raw fallback, all-occurrences removal, family-last-wins
/// chips) are Design's shared `TokenQuery` core; this grammar owns only its token table and
/// `matches()`.
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

    /// Class aliases for `kind:` — a single word matching a fixed extension set, so the "Images"
    /// suggestion can honestly mean images (it used to insert `kind:jpg`, silently excluding PNGs,
    /// HEICs, …). The table lives on `DifferenceSearch` (the shared grammar base, like `parseSize`)
    /// so Compare's `kind:image` means exactly the same thing.
    static let kindClasses: [String: Set<String>] = DifferenceSearch.kindClasses

    static func parse(_ raw: String) -> Query {
        var kind: String?
        var atLeast: Int?
        var atMost: Int?
        // No recognized tokens → freeText keeps the raw string verbatim (legacy substring search).
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

    /// A recognized filter word paired with a human label, so the lens search field can render
    /// removable chips like Compare's. `raw` is the exact word typed (e.g. `>5mb`), so a chip's ✕
    /// removes precisely that word; the label formats sizes the way the app displays them.
    struct Chip: Equatable, DimmableTokenChip {
        var raw: String
        var label: String
        /// Whether this chip is part of the effective query. `parse` is last-wins within a family
        /// (kind / `>` / `<` are each single-valued), so when a family appears twice only the LAST
        /// word filters anything; earlier ones render dimmed so the chips read as the query the
        /// filter actually runs. Their ✕ still removes the superseded word exactly.
        var isActive: Bool = true
    }

    /// The `kind:`/size words in `raw`, in order, as display chips. Free (name) text is excluded, so
    /// the chips are exactly the active structured filters. Within each family only the last
    /// occurrence is `isActive` — matching `parse`'s last-wins semantics (via
    /// `TokenQuery.lastWinsChips`).
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

    /// Removes every occurrence of `word` from `raw` — see `TokenQuery.removing` for why ALL
    /// occurrences is the honest ✕ semantics under last-wins parsing.
    static func removing(_ raw: String, word: String) -> String {
        TokenQuery.removing(raw, word: word)
    }
}
