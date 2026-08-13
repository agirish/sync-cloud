import Foundation
import Design
import Sync

// MARK: - Per-lens token grammars
//
// Search in a lens workspace is a FILTER over what a lens already has on screen — never a disk walk.
// Each lens gets the same shape (structured tokens where they parse, plain substring on everything
// else, built on Design's shared `TokenQuery` core) but its OWN token table.
//
// The rule that shapes all of this: a lens only ever declares a token it can actually bind. The
// rename backlog has no size on a `RenamePlan`, so `>5mb` has nothing to answer — and so it simply
// does not have that token, its parser doesn't recognize one, and its placeholder never mentions
// one. There are no struck-through "understood but useless" chips anywhere.
//
// The accepted consequence: the grammar is deliberately NOT uniform. A token learned in Duplicates
// is not necessarily a token in Filing. The per-lens placeholder is what teaches each vocabulary,
// which is why `LensSearch.placeholder(for:)` is one string per lens rather than one shared one —
// and why it is a `switch` over `WorkspaceLensKind` rather than a count anybody has to keep.

/// The one place the Organize lenses answer `kind:` for a FILE, so they can't disagree about what
/// `image` covers. An exact extension match, or one of the shared class aliases from
/// `DifferenceSearch.kindClasses` — the same table Compare uses.
///
/// Automations deliberately does NOT route through here: a rule matches a *kind*, not a file, so
/// its `kind:` binds to `FileKind` instead (see `AutomationSearch`).
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

/// The vocabulary each lens advertises. This is the ONLY thing teaching the user which tokens bind
/// where, so each string must name exactly the tokens its lens declares — never a token it would
/// silently treat as free text.
enum LensSearch {
    static func placeholder(for lens: WorkspaceLensKind) -> String {
        switch lens {
        case .duplicates: return "kind:pdf, >5mb…"
        case .filing: return "kind:pdf, confidence:high, to:Invoices…"
        case .automations: return "Search rules — is:enabled, kind:pdf"
        case .storage: return "kind:pdf, >100mb…"
        }
    }

    /// The search toggle's tooltip and accessibility label — names what THIS lens searches, since
    /// that differs per lens.
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
/// **The thinnest grammar here, and deliberately.** A row is a *folder*, and what you look for is
/// a folder — "PG&E", "2021", "HDFC". There is no confidence to filter by, no kind (a plan spans
/// whatever extensions the folder holds), and no size. So this is free text over the folder path
/// and the names inside it, with no token grammar at all, and the placeholder never suggests one.
///
/// It answers for the **to-fix rows too** (the `RiskyName` overload below), which is what retired
/// `RiskyNameSearch` — a `kind:` / `is:folder` grammar that only the standalone rename lens ever
/// offered. Those tokens are gone rather than hidden; if the to-fix rows ever want them back, they
/// belong here, on the one grammar the list actually uses.
///
/// Matching the file names too is what makes it useful rather than decorative: 129 folders is a lot
/// to scroll, and the file you are actually looking for is `9829custbill…`.
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

    /// The same free text over a **risky name**, because the backlog's list holds those too.
    ///
    /// The fold put the "to fix" rows at the head of this list (`RenamePassLens.toFixSection`) and
    /// left them unfiltered, on the argument that applying the backlog's grammar to a name would
    /// hide fixes behind a query about something else. There is no grammar to misapply: this search
    /// has no tokens at all — it is free text over the folder and the names inside it, and a name
    /// is precisely what a risky row carries. Unfiltered, one list answered one query two ways
    /// (three plans, and all five fixes) under a header counting a third thing.
    ///
    /// **The `reason` is deliberately not matched**, though the row shows it: the plan half does
    /// not match its steps' reasons either, and a query that found rows by their explanation in one
    /// half of a list and not the other would be worse than either rule on its own.
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
/// `confidence:` binds to the tier the card actually SHOWS (`FilingConfidenceTier`), not to the
/// raw destination confidence — a suggestion with no candidate at all displays under "Needs your
/// pick", so that's what `confidence:low` must mean.
///
/// `to:` matches only the BEST destination — the one the card is offering. Matching any candidate
/// would surface a file under `to:Invoices` while its card offered Receipts.
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
            // `to:` keeps the ORIGINAL casing of the word — folder names are matched
            // case-insensitively anyway, but the chip should read back what was typed.
            if lower.hasPrefix("to:") {
                let folder = String(word.dropFirst("to:".count))
                if !folder.isEmpty { destination = folder; return true }
            }
            return false
        }
        return Query(kind: kind, sizeAtLeast: atLeast, sizeAtMost: atMost,
                     confidence: confidence, destination: destination, text: text)
    }

    /// The tier words. "low" and "needs" both reach the "Needs your pick" tier, since that's the
    /// label on screen — a user reading the section header shouldn't have to guess it's "low".
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
/// `kind:` binds to `FileKind` — the coarse family a rule can actually test (`image`, `pdf`,
/// `video`, `audio`, `archive`, `document`) — because a RULE matches a kind rather than being a
/// file with an extension. `kind:jpg` is therefore free text here even though it's a real token in
/// Duplicates; that asymmetry is the per-lens-honesty rule doing its job, and the placeholder
/// advertises `kind:pdf` accordingly.
///
/// Free text matches the rule's NAME as well as its `summary`. The spec expected `summary` alone
/// to cover it — "the prebuilt one-liner folding name + conditions + destination". It does not:
/// `AutomationRule.summary` is built from the conditions and the destination template and never
/// reads `self.name`, so a rule named "Invoices" whose conditions say `text contains "bill"` would
/// be invisible to a search for `invoice`. Matching name ∪ summary is what actually delivers the
/// intended "find it by name, by condition, or by where it files".
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
/// The treemap is deliberately NOT filtered. It is a part-of-whole picture of the scanned tree,
/// and drawing it from a subset would misstate every proportion in it — "Photos is 60% of this
/// folder" would silently start meaning "60% of what survived your query". Its areas are folders
/// besides, which no `kind:` can match, and its synthetic "Files"/"Other" buckets carry empty
/// paths, so a path filter would drop them for reasons a reader could never see. The lists answer
/// the query; the map keeps telling the truth about the whole.
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
