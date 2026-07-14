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

    public init(
        path: String,
        name: String,
        parentFolderName: String,
        parentPath: String,
        sizeBytes: Int,
        modificationDate: Date?,
        isDirectory: Bool,
        snippet: String? = nil
    ) {
        self.path = path
        self.name = name
        self.parentFolderName = parentFolderName
        self.parentPath = parentPath
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.snippet = snippet
    }

    public var fileExtension: String { (name as NSString).pathExtension }
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

    public init(id: String, fileName: String, ruleID: UUID, ruleName: String, verdict: AutomationVerdict) {
        self.id = id
        self.fileName = fileName
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.verdict = verdict
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
            return facts.sizeBytes > mb * bytesPerMB
        case .untouchedForDays(let days):
            guard let modified = facts.modificationDate else { return false }
            return now.timeIntervalSince(modified) >= Double(days) * 86_400
        case .contentContains(let term):
            guard let snippet = facts.snippet else { return false }
            let needle = term.trimmingCharacters(in: .whitespaces).lowercased()
            return !needle.isEmpty && snippet.contains(needle)
        }
    }

    /// Whether the whole rule matches the file. Incomplete conditions are ignored; a rule with no
    /// complete conditions never matches.
    public static func matches(_ rule: AutomationRule, _ facts: AutomationFileFacts, now: Date) -> Bool {
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
        let active = rule.conditions.filter { $0.isComplete }
        guard !active.isEmpty else { return false }
        func value(_ c: AutomationCondition) -> Bool { c.requiresContent ? true : matches(c, facts, now: now) }
        switch rule.matchMode {
        case .all: return active.allSatisfy(value)
        case .any: return active.contains(where: value)
        }
    }

    /// The first enabled, runnable rule (in the given order) that matches — the rule that "claims"
    /// the file. Rules should be passed in the user's priority order.
    public static func firstMatch(in rules: [AutomationRule], for facts: AutomationFileFacts, now: Date) -> AutomationRule? {
        rules.first { $0.enabled && $0.isRunnable && matches($0, facts, now: now) }
    }

    // MARK: Destination templates

    /// The tokens a destination template understands, for the editor's insert menu.
    public static let supportedTokens = ["{year}", "{month}", "{yyyy-mm}", "{kind}", "{ext}", "{provider}"]

    /// Expands a provider-relative template against a file. Each token resolves from the file's own
    /// local metadata; an unfillable token yields ``DestinationResolution/unresolved(token:)`` so
    /// the preview can say what's missing rather than invent a folder.
    public static func resolveDestination(
        _ template: String,
        for facts: AutomationFileFacts,
        providerName: String?,
        now: Date
    ) -> DestinationResolution {
        var result = template
        let cal = Calendar(identifier: .gregorian)

        func year() -> String? {
            guard let d = facts.modificationDate else { return nil }
            return String(cal.component(.year, from: d))
        }
        func month() -> String? {
            guard let d = facts.modificationDate else { return nil }
            return String(format: "%02d", cal.component(.month, from: d))
        }

        // Ordered so a failed lookup can report the exact token. Each replacement is skipped (left in
        // place) when it can't resolve; the leftover-token sweep below then flags it.
        let substitutions: [(token: String, value: String?)] = [
            ("{yyyy-mm}", (year() != nil && month() != nil) ? "\(year()!)-\(month()!)" : nil),
            ("{year}", year()),
            ("{month}", month()),
            ("{kind}", FileKind.of(fileName: facts.name)?.label),
            ("{ext}", facts.fileExtension.isEmpty ? nil : facts.fileExtension.lowercased()),
            ("{provider}", providerName?.trimmingCharacters(in: .whitespaces).nilIfEmpty)
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
