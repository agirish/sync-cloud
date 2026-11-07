import Foundation
import Design
import Sync

// MARK: - Per-lens token grammars
//
// Search in a lens workspace filters what the lens already has on screen; it never walks the disk.
// Each lens has the same shape (structured tokens where they parse, substring on the rest, built
// on Design's `TokenQuery`) but its own token table.
//
// A lens declares only tokens it can bind: a `RenamePlan` has no size, so the rename backlog has
// no `>5mb`, its parser doesn't recognise one and its placeholder never mentions one. So the
// grammar is not uniform across lenses, and each lens's placeholder teaches its own vocabulary
// (`LensSearch.placeholder(for:)`, a `switch` over `WorkspaceLensKind`).

/// The one place the Organize lenses answer `kind:` for a file, so they can't disagree about what
/// `image` covers: an exact extension, or a class alias from `DifferenceSearch.kindClasses`, the
/// table Compare uses.
///
/// Automations doesn't use this: a rule matches a kind, not a file, so its `kind:` binds to
/// `FileKind` (see `AutomationSearch`).
enum LensKind {
    static func matches(_ kind: String, fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let classExtensions = DifferenceSearch.kindClasses[kind] {
            return classExtensions.contains(ext)
        }
        return ext == kind
    }

    /// Parses the `kind:` word into its bare extension/class, or nil when it isn't one.
    static func word(_ lower: String) -> String? {
        guard lower.hasPrefix("kind:") else { return nil }
        let ext = String(lower.dropFirst("kind:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ext.isEmpty ? nil : ext
    }
}

/// The vocabulary each lens advertises, the only thing teaching which tokens bind where. Each
/// string must name exactly its lens's tokens, never one it would treat as free text.
enum LensSearch {
    static func placeholder(for lens: WorkspaceLensKind) -> String {
        switch lens {
        case .duplicates: return "kind:pdf, >5mb…"
        case .filing: return "kind:pdf, confidence:high, to:Invoices…"
        case .automations: return "Search rules — is:enabled, kind:pdf"
        case .storage: return "kind:pdf, >100mb…"
        }
    }

    /// The search toggle's tooltip and accessibility label, naming what this lens searches.
    static func help(for lens: WorkspaceLensKind) -> String {
        switch lens {
        case .duplicates: return "Search duplicate groups by name, kind, or size"
        case .filing: return "Search loose files by name, destination, or confidence"
        case .automations: return "Search rules by name, condition, or destination"
        case .storage: return "Search files by name, path, kind, or size"
        }
    }
}

// MARK: - Rename backlog

/// Organize ▸ the rename backlog. Filters `renamePlans`.
///
/// No token grammar at all: a row is a folder, with no confidence, kind (a plan spans whatever
/// extensions the folder holds) or size to filter by. Free text over the folder path and the file
/// names inside it, since the file you are looking for is often a name like `9829custbill…`.
///
/// It answers for the to-fix rows too (the `RiskyName` overload below). Any tokens those rows
/// ever need belong here, on the one grammar the list uses.
enum RenameBacklogSearch {

    static func matches(_ query: String, _ plan: RenamePlan) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        if plan.relativePath.range(of: text, options: .caseInsensitive) != nil { return true }
        if plan.steps.contains(where: {
            $0.currentName.range(of: text, options: .caseInsensitive) != nil
                || $0.proposedName.range(of: text, options: .caseInsensitive) != nil
        }) { return true }
        return plan.skips.contains { $0.fileName.range(of: text, options: .caseInsensitive) != nil }
    }

    /// The same free text over a risky name, because the backlog's list holds those too
    /// (`RenamePassLens.toFixSection`). Left unfiltered, one list would answer one query two ways.
    ///
    /// The `reason` isn't matched, though the row shows it: the plan half doesn't match its steps'
    /// reasons either, and a list that matched explanations in one half only would be worse.
    static func matches(_ query: String, _ risky: RiskyName) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return true }
        return risky.currentName.range(of: text, options: .caseInsensitive) != nil
            || risky.sanitizedName.range(of: text, options: .caseInsensitive) != nil
            || risky.relativePath.range(of: text, options: .caseInsensitive) != nil
    }
}

// MARK: - Organize

/// The Filing search. Filters `filingSuggestions`, upstream of the confidence grouping.
///
/// `confidence:` binds to the tier the card shows (`FilingConfidenceTier`), not the raw
/// confidence: a suggestion with no candidate shows under "Needs your pick", so `confidence:low`
/// must find it.
///
/// `to:` matches only the best destination, the one the card offers. Matching any candidate would
/// show a file under `to:Invoices` while its card offered Receipts.
enum FilingSearch {

    struct Query: Equatable {
        var kind: String?
        var sizeAtLeast: Int?
        var sizeAtMost: Int?
        var confidence: FilingConfidenceTier?
        var destination: String?
        var text: String

        func matches(_ suggestion: FilingSuggestion) -> Bool {
            if let kind, !LensKind.matches(kind, fileName: suggestion.fileName) { return false }
            if let sizeAtLeast, suggestion.size < sizeAtLeast { return false }
            if let sizeAtMost, suggestion.size > sizeAtMost { return false }
            if let confidence, FilingConfidenceTier.of(suggestion) != confidence { return false }
            if let destination {
                guard let best = suggestion.best?.path,
                      best.range(of: destination, options: .caseInsensitive) != nil else { return false }
            }
            if text.isEmpty { return true }
            if suggestion.fileName.range(of: text, options: .caseInsensitive) != nil { return true }
            if let best = suggestion.best?.path, best.range(of: text, options: .caseInsensitive) != nil { return true }
            return suggestion.candidates.contains { candidate in
                candidate.reasons.contains { $0.range(of: text, options: .caseInsensitive) != nil }
            }
        }
    }

    static func parse(_ raw: String) -> Query {
        var kind: String?
        var atLeast: Int?
        var atMost: Int?
        var confidence: FilingConfidenceTier?
        var destination: String?
        let text = TokenQuery.freeText(raw) { word in
            let lower = word.lowercased()
            if let ext = LensKind.word(lower) { kind = ext; return true }
            if lower.hasPrefix(">"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                atLeast = bytes; return true
            }
            if lower.hasPrefix("<"), let bytes = DifferenceSearch.parseSize(String(lower.dropFirst())) {
                atMost = bytes; return true
            }
            if lower.hasPrefix("confidence:"), let tier = parseTier(String(lower.dropFirst("confidence:".count))) {
                confidence = tier; return true
            }
            // `to:` keeps the word's original casing: matching ignores case, but the chip should
            // read back what was typed.
            if lower.hasPrefix("to:") {
                let folder = String(word.dropFirst("to:".count))
                if !folder.isEmpty { destination = folder; return true }
            }
            return false
        }
        return Query(kind: kind, sizeAtLeast: atLeast, sizeAtMost: atMost,
                     confidence: confidence, destination: destination, text: text)
    }

    /// The tier words. "low" and "needs" both reach the "Needs your pick" tier, so someone reading
    /// the section header needn't guess it's "low".
    private static func parseTier(_ word: String) -> FilingConfidenceTier? {
        switch word {
        case "high": return .high
        case "medium", "med": return .medium
        case "low", "needs": return .low
        default: return nil
        }
    }

    struct Chip: Equatable, DimmableTokenChip {
        var raw: String
        var label: String
        var isActive: Bool = true
    }

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
            if lower.hasPrefix("confidence:"), let tier = parseTier(String(lower.dropFirst("confidence:".count))) {
                return (Chip(raw: word, label: tier.title), "confidence")
            }
            if lower.hasPrefix("to:") {
                let folder = String(word.dropFirst("to:".count))
                if !folder.isEmpty { return (Chip(raw: word, label: "→ \(folder)"), "to") }
            }
            return nil
        }
    }

    static func removing(_ raw: String, word: String) -> String { TokenQuery.removing(raw, word: word) }
}

// MARK: - Automations

/// The Automations search. Filters `automationRules`.
///
/// `kind:` binds to `FileKind`, the coarse family a rule can test (`image`, `pdf`, `video`,
/// `audio`, `archive`, `document`), because a rule matches a kind rather than being a file. So
/// `kind:jpg` is free text here though it's a token in Duplicates, and the placeholder advertises
/// `kind:pdf`.
///
/// Free text matches the rule's name as well as its `summary`, because `AutomationRule.summary`
/// never reads the name: a rule named "Invoices" testing `text contains "bill"` would otherwise be
/// invisible to a search for `invoice`.
enum AutomationSearch {

    struct Query: Equatable {
        /// nil = either; true = `is:enabled`; false = `is:disabled`.
        var enabled: Bool?
        var kind: FileKind?
        var text: String

        func matches(_ rule: AutomationRule) -> Bool {
            if let enabled, rule.enabled != enabled { return false }
            if let kind, !rule.conditions.contains(.kindIs(kind)) { return false }
            if text.isEmpty { return true }
            return rule.name.range(of: text, options: .caseInsensitive) != nil
                || rule.summary.range(of: text, options: .caseInsensitive) != nil
        }
    }

    static func parse(_ raw: String) -> Query {
        var enabled: Bool?
        var kind: FileKind?
        let text = TokenQuery.freeText(raw) { word in
            let lower = word.lowercased()
            if lower == "is:enabled" { enabled = true; return true }
            if lower == "is:disabled" { enabled = false; return true }
            if let word = LensKind.word(lower), let parsed = FileKind(rawValue: word) {
                kind = parsed; return true
            }
            return false
        }
        return Query(enabled: enabled, kind: kind, text: text)
    }

    struct Chip: Equatable, DimmableTokenChip {
        var raw: String
        var label: String
        var isActive: Bool = true
    }

    static func chips(_ raw: String) -> [Chip] {
        TokenQuery.lastWinsChips(raw) { word in
            let lower = word.lowercased()
            if lower == "is:enabled" { return (Chip(raw: word, label: "enabled"), "is") }
            if lower == "is:disabled" { return (Chip(raw: word, label: "disabled"), "is") }
            if let kindWord = LensKind.word(lower), let parsed = FileKind(rawValue: kindWord) {
                return (Chip(raw: word, label: "kind: \(parsed.label)"), "kind")
            }
            return nil
        }
    }

    static func removing(_ raw: String, word: String) -> String { TokenQuery.removing(raw, word: word) }
}

// MARK: - Storage

/// The Storage search. Filters the report's three ranked FILE lists (largest / stale / reclaim
/// candidates).
///
/// The treemap is not filtered. It is a part-of-whole picture, and drawn from a subset every
/// proportion would silently mean "of what survived your query". Its areas are also folders, which
/// no `kind:` matches, and its synthetic "Files"/"Other" buckets have empty paths that a path
/// filter would drop invisibly.
enum StorageSearch {

    struct Query: Equatable {
        var kind: String?
        var sizeAtLeast: Int?
        var sizeAtMost: Int?
        var text: String

        var isEmpty: Bool { kind == nil && sizeAtLeast == nil && sizeAtMost == nil && text.isEmpty }

        func matches(_ entry: StorageEntry) -> Bool {
            if let kind, !LensKind.matches(kind, fileName: entry.name) { return false }
            if let sizeAtLeast, entry.bytes < sizeAtLeast { return false }
            if let sizeAtMost, entry.bytes > sizeAtMost { return false }
            if text.isEmpty { return true }
            return entry.name.range(of: text, options: .caseInsensitive) != nil
                || entry.path.range(of: text, options: .caseInsensitive) != nil
        }
    }

    static func parse(_ raw: String) -> Query {
        var kind: String?
        var atLeast: Int?
        var atMost: Int?
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

    struct Chip: Equatable, DimmableTokenChip {
        var raw: String
        var label: String
        var isActive: Bool = true
    }

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

    static func removing(_ raw: String, word: String) -> String { TokenQuery.removing(raw, word: word) }
}
