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
}
