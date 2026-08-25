import Foundation

// MARK: - File facts (the pure input a rule is tested against)

/// Everything the evaluator needs to know about one candidate file, gathered from the scan (never
/// re-touching disk during evaluation). `snippet` is the on-device text excerpt, lowercased and
/// filled in only when a rule actually reads content.
public struct AutomationFileFacts: Sendable, Equatable {
    public let path: String
    public let name: String
    /// The immediate parent folder's name (last path component of the parent).
    public let parentFolderName: String
    /// The absolute path of the parent folder (used by the manager to spot "already there").
    public let parentPath: String
    public let sizeBytes: Int
    public let modificationDate: Date?
    public let isDirectory: Bool
    /// On-device text excerpt (PDFKit / OCR / plain text), already lowercased. nil = not read.
    public var snippet: String?
    /// Canonical tokens extracted from the file's *contents* (the Organize scan supplies these from
    /// its content pass; the dry run derives them from `snippet`). Feeds `mentionsAll` alone —
    /// `contentContains` reads the raw `snippet` only, so "contains" means the same substring on
    /// every surface. Empty = no content read.
    public var contentTokens: Set<String>
    /// Which household members this document is about, as ``Person`` ids.
    ///
    /// Resolved by the caller rather than here, because attribution needs the roster and this type
    /// is deliberately a plain description of a file that a pure evaluator can reason over. Empty
    /// when there is no roster, which makes every `personIs` rule simply not match — the same
    /// behaviour the app had before people existed.
    public var personIds: Set<String> = []
    /// The folder name of the one person this document is about, for the `{person}` destination
    /// token. nil when nobody — or more than one — is named, because a document naming two people
    /// has no single folder to go to and guessing is worse than reporting it unresolved.
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

    /// The same facts with the household resolved onto them.
    ///
    /// A helper rather than three copies of the same two lines: the dry run, the Organize scan and
    /// the rule proposer all need this, and the proposer forgetting it would silently filter every
    /// person variant out of its own offer.
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

    /// The filename's canonical tokens (extension stripped) — the same tokenizer the Organize
    /// engine matches with, so `mentionsAll` behaves identically on both surfaces.
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
    /// The absolute folder the file would move into when filed — set for actionable rows (would-file
    /// and name-collision), nil for the no-op cases (already-there, unresolved token). A nil here is
    /// the single source of truth for "this row can be filed."
    public let destinationDir: URL?
    /// The provider-relative destination shown to the user (e.g. "Invoices/2026").
    public let destinationLabel: String?
    /// The folder that must **already exist** for `destinationDir` to be safe to create — the
    /// provider root the preview resolved against.
    ///
    /// Everything below it is the rule's to create (`Documents/Invoices/{year}` is a template, and
    /// building the whole path is the feature), so the root itself is the one thing filing may not
    /// invent. Without it the apply path's `createDirectory(withIntermediateDirectories: true)`
    /// happily rebuilds an unmounted provider as an ordinary local folder and moves files into it
    /// under a success banner — out of a live tree into one nothing ever syncs.
    ///
    /// **Required, not optional.** A row that cannot say what must already be there cannot be
    /// filed safely, and a defaulted `nil` would leave the guard silently unarmed at any call site
    /// that forgot it — the compiler asks instead.
    public let destinationAnchor: URL

    /// What the file was when the preview read it, so applying can tell it is still that file.
    ///
    /// **A preview is not applied at the moment it is taken.** The report sits on screen while the
    /// user reads it — and the walkthrough has them step through it row by row — so minutes can
    /// pass between "this is what would happen" and the move. `applyAutomationFiling` gated on
    /// `fileExists(atPath:)`, and a path is not a file: anything that took `row.id`'s place in the
    /// meantime got moved instead, out of the folder the user was looking at and into a
    /// destination chosen for a document it is not.
    ///
    /// Read with ``ItemIdentity/snapshot(at:fileManager:)`` rather than assembled from the walk's
    /// `FileNode`, deliberately. The walk populates `modificationDate` from
    /// `resourceValues(.contentModificationDateKey)` while `snapshot` reads
    /// `attributesOfItem[.modificationDate]`; an identity built from one and compared against the
    /// other would rest on two APIs agreeing about a `Date`, and where they did not the apply
    /// would refuse every row and look like a filesystem problem.
    ///
    /// **Optional, and nil means "not recorded" — apply proceeds as it did before.** Every
    /// production row records one (`FileSyncManager.previewAutomations`, pinned by
    /// `everyPreviewedRowCarriesTheIdentityItWasReadWith`); nil exists for rows built by hand in
    /// tests that are about something else entirely, and refusing those would have made this
    /// change about rewriting fixtures rather than about the guard.
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

    public var matchedCount: Int { rows.count }
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

/// Pure, deterministic, offline. Decides whether a rule matches a file, whether the (expensive)
/// content read is worth doing, and how a destination template resolves. It never touches disk or
/// the network — the manager layers the disk-aware verdicts (collision, already-there) on top.
public enum AutomationEvaluator {

    /// Bytes per megabyte, decimal — matches how macOS Finder reports sizes, so "100 MB" means what
    /// the user sees there.
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
            // **Substring of the raw excerpt, and nothing else.** There was a token-subset
            // fallback here for facts carrying content tokens but no snippet, and it was a second
            // semantic wearing the first's name: "tax return" matched any file with "tax"
            // somewhere and "return" somewhere else — order and adjacency gone — and the broad
            // reading lived on the Organize scan, the path that MOVES files, while the preview
            // answered with the strict one. Both surfaces gate their snippet fetch identically
            // (`contentCouldStillDecide`), so any file this condition could act on has its text
            // here; no snippet now means the text was not read — reads-contents off, or an
            // extractor-less host — and a condition about text that was never read holds nothing.
            // Word-of-the-term matching is `mentionsAll`'s job, and it still does it.
            return facts.snippet?.contains(needle) ?? false
        case .mentionsAll(let tokens):
            let trigger = Set(tokens.map { $0.lowercased() }.filter { !$0.isEmpty })
            guard !trigger.isEmpty else { return false }
            return trigger.isSubset(of: facts.nameTokens.union(facts.contentTokens))
        case .personIs(let id):
            // Resolved onto the facts by the caller (see `attributing`). With no roster this is
            // empty and the rule simply never fires, rather than matching everything.
            return facts.personIds.contains(id)
        case .unrecognized:
            // A condition from a newer build. Never matches — a rule this build cannot fully
            // understand must not file anything on a partial reading of it.
            return false
        }
    }

    /// Whether the whole rule matches the file. In ANY-OF mode incomplete conditions are ignored
    /// (dropping a disjunct only narrows); in ALL-OF mode an incomplete condition makes the rule
    /// match NOTHING — "all" cannot be proven when one condition is unevaluatable, and filtering
    /// it out silently broadened the rule to whatever the complete conditions match (the trap the
    /// editor's Save gate blocks going forward, and this closes for already-stored rules). A rule
    /// with no complete conditions never matches.
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

    /// Whether the rule could still match once its content conditions are known — i.e. treating any
    /// content condition optimistically as satisfied. Used to decide whether fetching the file's
    /// (expensive) text is worth it: if this is false, the snippet can be skipped entirely.
    public static func couldMatchPendingContent(_ rule: AutomationRule, _ facts: AutomationFileFacts, now: Date) -> Bool {
        // Mirrors matches(): an ALL-OF rule with any incomplete condition can never match, so
        // its content is never worth reading — without this, a permanently inert rule kept
        // triggering PDFKit/OCR extraction for every loose file on every scan and preview.
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
                                         "{provider}", "{person}"]

    /// Expands a destination template against a file. Each token resolves from the file's own
    /// local metadata; an unfillable token yields ``DestinationResolution/unresolved(token:)`` so
    /// the preview can say what's missing rather than invent a folder.
    ///
    /// Templates are normally provider-relative. A template starting with `/` is an **absolute**
    /// destination (a remembered rule migrated from F3 whose folder lay outside every known
    /// provider root) — it resolves to that absolute path verbatim, and callers must scope it
    /// (only act when it falls inside the provider being worked on).
    public static func resolveDestination(
        _ template: String,
        for facts: AutomationFileFacts,
        providerName: String?,
        now: Date
    ) -> DestinationResolution {
        // An absolute destination is a LITERAL folder path (it only ever comes from a migrated or
        // learned rule that filed into a real folder) — no token expansion, so a legacy folder
        // whose name happens to contain braces can never be misread as an unresolvable template.
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

        // {year} prefers the year the FILENAME names over the modification date, exactly like the
        // Organize engine (round 4): a 2023 tax form downloaded in 2024 belongs in Taxes/2023 —
        // mtime is merely when the bytes last changed. Rule matches are batch-eligible, so a
        // wrong-year {year} would blind-file into the wrong folder.
        func year() -> String? {
            if let named = FilingEngine.filenameYear(in: FilingEngine.fileTokens(facts.name), now: now) {
                return named
            }
            guard let d = facts.modificationDate else { return nil }
            return String(cal.component(.year, from: d))
        }
        func month() -> String? {
            guard let d = facts.modificationDate else { return nil }
            // Same contradiction guard as {yyyy-mm}: the month can only come from the mtime,
            // and when the filename names a DIFFERENT year the document's month is unknowable —
            // resolving would let a hand-composed "{year}-{month}" template mint the exact
            // neither-source date the composite token forbids.
            if let named = FilingEngine.filenameYear(in: FilingEngine.fileTokens(facts.name), now: now),
               named != String(cal.component(.year, from: d)) {
                return nil
            }
            return String(format: "%02d", cal.component(.month, from: d))
        }
        // {yyyy-mm} takes BOTH components from ONE clock — the mtime. {year} alone may prefer
        // the filename's year (Taxes/2023 for a 2023 form downloaded in 2024), but the month
        // can only come from the mtime, and composing filename-2023 with mtime-May-2024 minted
        // "2023-05" — a date belonging to neither source, blind-filed into by batch-eligible
        // rules. A filename year that CONTRADICTS the mtime year makes the composite
        // unknowable: resolve to nil so the leftover-token sweep flags it instead.
        func yearMonth() -> String? {
            guard let d = facts.modificationDate else { return nil }
            let mtimeYear = String(cal.component(.year, from: d))
            if let named = FilingEngine.filenameYear(in: FilingEngine.fileTokens(facts.name), now: now),
               named != mtimeYear {
                return nil
            }
            return "\(mtimeYear)-\(String(format: "%02d", cal.component(.month, from: d)))"
        }

        // Ordered so a failed lookup can report the exact token. Each replacement is skipped (left in
        // place) when it can't resolve; the leftover-token sweep below then flags it.
        let substitutions: [(token: String, value: String?)] = [
            ("{yyyy-mm}", yearMonth()),
            ("{year}", year()),
            ("{month}", month()),
            ("{kind}", FileKind.of(fileName: facts.name)?.label),
            ("{ext}", facts.fileExtension.isEmpty ? nil : facts.fileExtension.lowercased()),
            ("{provider}", providerName?.trimmingCharacters(in: .whitespaces).nilIfEmpty),
            // **The token that turns seven rules into one.** `Immigration/OCI/{person}` files each
            // person's card into their own folder, and a rule taught on one of them covers the
            // household. nil — and therefore `.unresolved`, never a guess — when the document
            // names nobody, or names two people and so has no single folder to go to.
            ("{person}", facts.personFolderName?.trimmingCharacters(in: .whitespaces).nilIfEmpty)
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

    /// Resolves a destination to the absolute folder it names under `providerRoot`, or nil when the
    /// destination is absolute but points outside that provider (the rule is inert there — the same
    /// provider scoping remembered rules always had). A relative destination is anchored at the root.
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
