import Foundation

/// What one Read Documents did, for its line in the log: counts and kinds only.
///
/// Never a number, a holder's name or a file's name. A file's name can hold the very number it
/// carries ("e-PAN Anna - ABCPE1234F.pdf"), and the log is plain text anyone with the Mac can open.
public struct VaultReadTally: Equatable, Sendable {
    /// Every document in the chosen folders.
    public var documents = 0
    /// Those opened this time: new, changed, or all of them when every file is read again.
    public var opened = 0
    /// Opened, but gave no text at all: a locked PDF, an empty page, a photo with no words.
    public var textless = 0
    /// Numbers read this time, by kind, each counted once however many files carry it.
    public private(set) var byCategory: [VaultCategory: Int] = [:]
    /// Numbers a document only names (a passport number on an I-94), counted once each.
    public private(set) var mentions = 0
    /// New to To Confirm.
    public var added = 0
    /// Files passed over and why, pages not recognised, and how pages were read (VT25).
    public var notes = VaultReadNotes()
    private var seen = Set<String>()
    private var seenMentions = Set<String>()

    public init() {}

    /// Counts what one document gave.
    public mutating func record(_ pages: [[String]], _ read: (finds: [VaultFind], mentions: [VaultMention])) {
        opened += 1
        if pages.allSatisfy({ $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }) { textless += 1 }
        for find in read.finds where seen.insert(VaultReading.normalized(find.value)).inserted {
            byCategory[find.category, default: 0] += 1
        }
        for mention in read.mentions where seenMentions.insert(VaultReading.normalized(mention.value)).inserted {
            mentions += 1
        }
    }

    /// "Vault: 2224 document(s), 2224 opened in 31m 12s (4 gave no text); read 7 Passports,
    /// 2 Driver’s Licenses, 3 Aadhaar; 5 named only; 9 new number(s) to confirm".
    public func summary(seconds: TimeInterval) -> String {
        let kinds = VaultCategory.allCases.compactMap { category -> String? in
            byCategory[category].map { "\($0) \(category.title)" }
        }
        var line = "Vault: \(documents) document(s), \(opened) opened in \(Self.duration(seconds))"
        if textless > 0 { line += " (\(textless) gave no text)" }
        line += kinds.isEmpty ? "; no numbers read" : "; read " + kinds.joined(separator: ", ")
        if mentions > 0 { line += "; \(mentions) named only" }
        return line + "; \(added) new number(s) to confirm" + notes.summary
    }

    /// "45s", "31m 12s", "1h 02m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}
