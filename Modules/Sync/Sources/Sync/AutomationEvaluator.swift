import Foundation

// MARK: - File facts (the pure input a rule is tested against)

/// Everything the evaluator needs about one candidate file, gathered from the scan so evaluation
/// never touches disk. `snippet` is the on-device text excerpt, lowercased and filled in only when
/// a rule reads content.
public struct AutomationFileFacts: Sendable, Equatable {
    public let path: String
    public let name: String
    /// The immediate parent folder's name.
    public let parentFolderName: String
    /// The absolute path of the parent folder (used by the manager to spot "already there").
    public let parentPath: String
    public let sizeBytes: Int
    public let modificationDate: Date?
    public let isDirectory: Bool
    /// On-device text excerpt (PDFKit / OCR / plain text), already lowercased. nil = not read.
    public var snippet: String?
    /// Canonical tokens from the file's *contents* (from the Organize scan's content pass, or
    /// derived from `snippet` in the dry run). Feeds `mentionsAll` only: `contentContains` reads
    /// the raw `snippet`, so "contains" means the same substring on every surface. Empty = no
    /// content read.
    public var contentTokens: Set<String>
    /// Which household members this document is about, as ``Person`` ids. Resolved by the caller,
    /// since attribution needs the roster and this type stays a plain description of a file. Empty
    /// with no roster, so no `personIs` rule matches.
    public var personIds: Set<String> = []
    /// The folder name of the one person this document is about, for the `{person}` destination
    /// token. nil when nobody, or more than one, is named: two people have no single folder, and
    /// guessing is worse than reporting it unresolved.
    public var personFolderName: String?

    public init(
        path: String,
        name: String,
        parentFolderName: String,
        parentPath: String,
        sizeBytes: Int,
        modificationDate: Date?,
        isDirectory: Bool,
        snippet: String? = nil,
        contentTokens: Set<String> = [],
        personIds: Set<String> = [],
        personFolderName: String? = nil
    ) {
        self.path = path
        self.name = name
        self.parentFolderName = parentFolderName
        self.parentPath = parentPath
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.snippet = snippet
        self.contentTokens = contentTokens
        self.personIds = personIds
        self.personFolderName = personFolderName
    }

    /// The same facts with the household resolved onto them. Shared by the dry run, the Organize
    /// scan and the rule proposer; a proposer that skipped it would silently drop every person
    /// variant from its offer.
    public func attributing(_ registry: PersonRegistry?,
                            identity: PersonIdentityIndex? = nil) -> AutomationFileFacts {
        guard let registry else { return self }
        var out = self
        out.personIds = registry.attribute(fileName: name, pageSample: snippet, identity: identity)
        out.personFolderName = out.personIds.count == 1
            ? registry.people.first { $0.id == out.personIds.first }?.displayName
            : nil
        return out
    }

    public var fileExtension: String { (name as NSString).pathExtension }

    /// The filename's canonical tokens (extension stripped), from the Organize engine's tokenizer,
    /// so `mentionsAll` behaves the same on both surfaces.
    public var nameTokens: Set<String> { FilingEngine.fileTokens(name) }
}

// MARK: - Destination resolution

/// The outcome of expanding a rule's destination template against a file.
public enum DestinationResolution: Sendable, Equatable {
    /// A clean provider-relative folder path (no leading/trailing slash, no empty segments).
    case resolved(String)
    /// A `{token}` in the template couldn't be filled from this file (e.g. `{provider}` with no
    /// provider, or `{year}` on a file with no modification date). Carries the offending token.
    case unresolved(token: String)
}

// MARK: - Verdict & dry-run report

/// What a rule *would* do to a file. Preview-only: no verdict moves anything.
public enum AutomationVerdict: Sendable, Equatable {
    /// Would file into this provider-relative destination folder.
    case wouldFile(destination: String)
    /// The rule matched but something needs a human — a name collision, or a template token that
    /// couldn't resolve. Carries a plain-words reason.
    case needsAttention(String)
    /// The file already lives in the destination the rule resolves to — nothing to do.
    case alreadyThere
}

/// One matched file in a dry run: which rule claimed it and what would happen.
public struct AutomationDryRunRow: Sendable, Equatable, Identifiable {
    public let id: String            // the file's absolute path
    public let fileName: String
    public let ruleID: UUID
    public let ruleName: String
    public let verdict: AutomationVerdict
    /// The absolute folder the file would move into: set for actionable rows (would-file and
    /// name-collision), nil for the no-op cases (already-there, unresolved token). Non-nil is the
    /// single source of truth for "this row can be filed."
    public let destinationDir: URL?
    /// The provider-relative destination shown to the user (e.g. "Invoices/2026").
    public let destinationLabel: String?
    /// The folder that must **already exist** for `destinationDir` to be safe to create: the
    /// provider root the preview resolved against. Everything below it is the rule's to create,
    /// but the root is the one thing filing may not invent. Without this check,
    /// `createDirectory(withIntermediateDirectories: true)` would rebuild an unmounted provider as
    /// a plain local folder and move files into it under a success banner, where nothing syncs.
    ///
    /// Required, not optional: a defaulted `nil` would leave the guard unarmed at any call site
    /// that forgot it.
    public let destinationAnchor: URL

    /// What the file was when the preview read it, so applying can tell it is still that file.
    /// Minutes can pass between preview and apply while the user reads the report, and a path is
    /// not a file: without this, whatever took `row.id`'s place would be moved instead, into a
    /// destination chosen for a different document.
    ///
    /// Read with ``ItemIdentity/snapshot(at:fileManager:)``, not built from the walk's `FileNode`:
    /// the walk's `modificationDate` comes from a different API than `snapshot`'s, and if the two
    /// ever disagreed about a `Date` the apply would refuse every row.
    ///
    /// nil means "not recorded", and apply proceeds without the check. Every production row records
    /// one (`FileSyncManager.previewAutomations`, pinned by
    /// `everyPreviewedRowCarriesTheIdentityItWasReadWith`); nil is for hand-built test rows.
    public let sourceIdentity: ItemIdentity?

    public init(id: String, fileName: String, ruleID: UUID, ruleName: String,
                verdict: AutomationVerdict, destinationDir: URL? = nil, destinationLabel: String? = nil,
                destinationAnchor: URL, sourceIdentity: ItemIdentity? = nil) {
        self.id = id
        self.fileName = fileName
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.verdict = verdict
        self.destinationDir = destinationDir
        self.destinationLabel = destinationLabel
        self.destinationAnchor = destinationAnchor
        self.sourceIdentity = sourceIdentity
    }
}

/// The result of previewing the enabled rules over a folder — what would happen if the rules ran,
/// with nothing actually moved.
public struct AutomationDryRunReport: Sendable, Equatable {
    /// The scanned root (for the "previewed <folder>" label).
    public let root: String
    public let providerName: String?
    /// How many loose files were considered (matched or not).
    public let filesScanned: Int
    /// One row per file that matched a rule, in scan order.
    public let rows: [AutomationDryRunRow]

    public init(root: String, providerName: String?, filesScanned: Int, rows: [AutomationDryRunRow]) {
        self.root = root
        self.providerName = providerName
        self.filesScanned = filesScanned
        self.rows = rows
    }

    public var wouldFileCount: Int {
        rows.filter { if case .wouldFile = $0.verdict { return true } else { return false } }.count
    }
    public var needsAttentionCount: Int {
        rows.filter { if case .needsAttention = $0.verdict { return true } else { return false } }.count
    }
    public var alreadyThereCount: Int {
        rows.filter { $0.verdict == .alreadyThere }.count
    }
}

// MARK: - Evaluator

/// Pure, deterministic, offline. Decides whether a rule matches a file, whether the expensive
/// content read is worth doing, and how a destination template resolves. It never touches disk or
/// the network; the manager adds the disk-aware verdicts (collision, already-there).
public enum AutomationEvaluator {

    /// Bytes per megabyte, decimal, as Finder reports sizes, so "100 MB" means what the user sees.
    static let bytesPerMB = 1_000_000

    // MARK: Condition matching

    /// Does a single, complete condition hold for the file? A content condition with no snippet
    /// loaded yet is `false` (the manager fetches the snippet first when it matters).
    static func matches(_ condition: AutomationCondition, _ facts: AutomationFileFacts, now: Date) -> Bool {
        switch condition {
        case .folderNamed(let name):
            return facts.parentFolderName.compare(name.trimmingCharacters(in: .whitespaces),
                                                  options: .caseInsensitive) == .orderedSame
        case .nameMatches(let glob):
            return IgnoreRules.nameMatches(facts.name, pattern: glob.trimmingCharacters(in: .whitespaces))
        case .kindIs(let kind):
            return kind.matches(fileExtension: facts.fileExtension)
        case .largerThanMB(let mb):
            // Overflow-safe: an absurd MB value (a 13+ digit paste) would trap on `mb * bytesPerMB`.
            // An overflowing threshold is larger than any real file, so nothing matches.
            let (threshold, overflow) = mb.multipliedReportingOverflow(by: bytesPerMB)
            return !overflow && facts.sizeBytes > threshold
        case .untouchedForDays(let days):
            guard let modified = facts.modificationDate else { return false }
            return now.timeIntervalSince(modified) >= Double(days) * 86_400
        case .contentContains(let term):
            let needle = term.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else { return false }
            // A substring of the raw excerpt, and nothing else. **Never** fall back to token
            // matching: "tax return" would match "tax" and "return" anywhere, and the scan that
            // moves files would read more broadly than the preview. Both gate their snippet fetch
            // the same way (`contentCouldStillDecide`), so no snippet means the text wasn't read,
            // and a condition about unread text holds nothing. Word matching is `mentionsAll`'s job.
            return facts.snippet?.contains(needle) ?? false
        case .mentionsAll(let tokens):
            let trigger = Set(tokens.map { $0.lowercased() }.filter { !$0.isEmpty })
            guard !trigger.isEmpty else { return false }
            return trigger.isSubset(of: facts.nameTokens.union(facts.contentTokens))
        case .mentionsAny(let phrases):
            // Each phrase as `mentionsAll` matches its tokens: "japan airlines" needs both words.
            let words = facts.nameTokens.union(facts.contentTokens)
            return phrases.contains { phrase in
                let trigger = Set(phrase.lowercased().split(separator: " ").map(String.init))
                return !trigger.isEmpty && trigger.isSubset(of: words)
            }
        case .personIs(let id):
            // Resolved onto the facts by the caller (see `attributing`). With no roster this is
            // empty and the rule simply never fires, rather than matching everything.
            return facts.personIds.contains(id)
        case .unrecognized:
            // A condition from a newer build. Never matches: a rule this build can't fully
            // understand must not file anything on a partial reading of it.
            return false
        }
    }

    /// Whether the whole rule matches the file. In ANY-OF mode incomplete conditions are ignored
    /// (dropping a disjunct only narrows); in ALL-OF mode an incomplete condition makes the rule
    /// match NOTHING, since ignoring it would silently broaden the rule. The editor's Save gate
    /// blocks such rules; this covers ones already stored. A rule with no complete conditions never
    /// matches.
    public static func matches(_ rule: AutomationRule, _ facts: AutomationFileFacts, now: Date) -> Bool {
        if rule.matchMode == .all, rule.conditions.contains(where: { !$0.isComplete }) {
            return false
        }
        let active = rule.conditions.filter { $0.isComplete }
        guard !active.isEmpty else { return false }
        switch rule.matchMode {
        case .all: return active.allSatisfy { matches($0, facts, now: now) }
        case .any: return active.contains { matches($0, facts, now: now) }
        }
    }

    /// Whether the rule could still match once its content conditions are known, treating each as
    /// satisfied. Decides whether the expensive text fetch is worth it: false skips the snippet.
    public static func couldMatchPendingContent(_ rule: AutomationRule, _ facts: AutomationFileFacts, now: Date) -> Bool {
        // Mirrors matches(): an ALL-OF rule with an incomplete condition never matches, so its
        // content is never worth reading. Without this an inert rule would trigger PDFKit/OCR
        // extraction for every loose file on every scan and preview.
        if rule.matchMode == .all, rule.conditions.contains(where: { !$0.isComplete }) {
            return false
        }
        let active = rule.conditions.filter { $0.isComplete }
        guard !active.isEmpty else { return false }
        func value(_ c: AutomationCondition) -> Bool { c.requiresContent ? true : matches(c, facts, now: now) }
        switch rule.matchMode {
        case .all: return active.allSatisfy(value)
        case .any: return active.contains(where: value)
        }
    }

    // MARK: Destination templates

    /// The tokens a destination template understands, for the editor's insert menu.
    public static let supportedTokens = ["{year}", "{month}", "{yyyy-mm}", "{kind}", "{ext}",
                                         "{provider}", "{person}",
                                         AutomationTravelDate.yearToken, AutomationTravelDate.monthToken]

    /// Expands a destination template against a file. Each token resolves from the file's own
    /// local metadata; an unfillable token yields ``DestinationResolution/unresolved(token:)`` so
    /// the preview can say what's missing rather than invent a folder.
    ///
    /// Templates are normally provider-relative. One starting with `/` is an **absolute**
    /// destination (a migrated remembered rule whose folder lay outside every known provider root):
    /// it resolves to that path verbatim, and callers must act on it only inside the provider being
    /// worked on.
    public static func resolveDestination(
        _ template: String,
        for facts: AutomationFileFacts,
        providerName: String?,
        now: Date
    ) -> DestinationResolution {
        // An absolute destination is a literal folder path (only from a migrated or learned rule),
        // so no token expansion: a folder whose name holds braces is never misread as a template.
        if template.hasPrefix("/") {
            let cleaned = template
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { $0 != "." && $0 != ".." }
                .joined(separator: "/")
            return .resolved("/" + cleaned)
        }

        var result = template
        let cal = Calendar(identifier: .gregorian)

        // {year} prefers the year the filename names over the modification date, as the Organize
        // engine does: a 2023 tax form downloaded in 2024 belongs in Taxes/2023. Rule matches are
        // batch-eligible, so a wrong {year} would file blind into the wrong folder.
        func year() -> String? {
            if let named = FilingEngine.filenameYear(in: FilingEngine.fileTokens(facts.name), now: now) {
                return named
            }
            guard let d = facts.modificationDate else { return nil }
            return String(cal.component(.year, from: d))
        }
        func month() -> String? {
            guard let d = facts.modificationDate else { return nil }
            // Same guard as {yyyy-mm}: the month comes only from the mtime, so when the filename
            // names a different year the month is unknowable, and "{year}-{month}" would mint a
            // date from neither source.
            if let named = FilingEngine.filenameYear(in: FilingEngine.fileTokens(facts.name), now: now),
               named != String(cal.component(.year, from: d)) {
                return nil
            }
            return String(format: "%02d", cal.component(.month, from: d))
        }
        // {yyyy-mm} takes both parts from one clock, the mtime. Mixing a filename's 2023 with an
        // mtime of May 2024 would make "2023-05", a date from neither source, and batch-eligible
        // rules would file into it blind. A filename year that contradicts the mtime year makes
        // it unknowable: nil, so the template resolves `.unresolved`.
        func yearMonth() -> String? {
            guard let d = facts.modificationDate else { return nil }
            let mtimeYear = String(cal.component(.year, from: d))
            if let named = FilingEngine.filenameYear(in: FilingEngine.fileTokens(facts.name), now: now),
               named != mtimeYear {
                return nil
            }
            return "\(mtimeYear)-\(String(format: "%02d", cal.component(.month, from: d)))"
        }

        var travelDay: AutomationTravelDate.Day??
        func travel() -> AutomationTravelDate.Day? {
            if let travelDay { return travelDay }
            let day = facts.snippet.flatMap(AutomationTravelDate.first(in:))
            travelDay = .some(day)
            return day
        }

        // Ordered so a failed lookup reports the exact token; an unresolvable token returns
        // `.unresolved` at once.
        let substitutions: [(token: String, value: String?)] = [
            ("{yyyy-mm}", yearMonth()),
            ("{year}", year()),
            ("{month}", month()),
            ("{kind}", FileKind.of(fileName: facts.name)?.label),
            ("{ext}", facts.fileExtension.isEmpty ? nil : facts.fileExtension.lowercased()),
            ("{provider}", providerName?.trimmingCharacters(in: .whitespaces).nilIfEmpty),
            // `Immigration/OCI/{person}` files each person's card into their own folder, so one
            // rule covers the household. nil, so `.unresolved` and never a guess, when the
            // document names nobody or two people.
            ("{person}", facts.personFolderName?.trimmingCharacters(in: .whitespaces).nilIfEmpty),
            // The trip's date from page 1; unresolved when page 1 wasn't read.
            (AutomationTravelDate.yearToken, travel().map { String($0.year) }),
            (AutomationTravelDate.monthToken, travel()?.monthName),
        ]
        for (token, value) in substitutions {
            guard result.contains(token) else { continue }
            guard let value else { return .unresolved(token: token) }
            result = result.replacingOccurrences(of: token, with: value)
        }

        // Any remaining {…} is an unknown or unfilled token — surface it rather than guess.
        if let open = result.firstIndex(of: "{"), let close = result[open...].firstIndex(of: "}") {
            return .unresolved(token: String(result[open...close]))
        }

        // Clean into a safe provider-relative path: drop empty / "." / ".." segments so a stray
        // slash or an escape attempt can't produce a weird destination in the preview.
        let cleaned = result
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
        return .resolved(cleaned)
    }

    // MARK: Absolute destinations (migrated F3 rules)

    /// Resolves a destination to the absolute folder it names under `providerRoot`, or nil when it
    /// is absolute but outside that provider (the rule is inert there). A relative destination is
    /// anchored at the root.
    public static func absoluteDestination(_ resolved: String, providerRoot: String) -> String? {
        let dest: String
        if resolved.hasPrefix("/") {
            dest = resolved
        } else {
            dest = resolved.isEmpty ? providerRoot : providerRoot + "/" + resolved
        }
        guard dest == providerRoot || dest.hasPrefix(providerRoot + "/") else { return nil }
        return dest
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
