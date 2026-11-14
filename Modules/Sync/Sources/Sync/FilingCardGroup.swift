import Foundation

/// One card for every statement going to the same account folder: "10 Schwab statements →
/// Traditional IRA 7863", filed with one click and undone with one ⌘Z (design §5.1). Only files
/// matched to an account by the number their page prints group; everything else stays a card of
/// its own, and so does a file that is the only one for its folder.
public struct FilingCardGroup: Identifiable, Sendable, Equatable {
    /// The account root and the folder the members go to.
    public var id: String { account.root + "\u{0}" + destination.path + "\u{0}" + destination.confidence.rawValue + "\u{0}" + account.ending }
    public let account: FilingAccount
    /// The shared home: the first member's best, which every member's best equals.
    public let destination: FilingDestination
    /// The files to move, in name order.
    public let members: [FilingSuggestion]
    /// Members whose document is already in the tree; not moved by File N.
    public var alreadyFiled: [FilingSuggestion] { members.filter(\.isAlreadyFiled) }
    /// Members that are another member's identical copy; not moved by File N.
    public var copies: [FilingSuggestion] { members.filter { $0.duplicateOf != nil } }
    /// What File N moves.
    public var toFile: [FilingSuggestion] { members.filter { !$0.isAlreadyFiled && $0.duplicateOf == nil } }

    /// The statements' periods, earliest and latest, from their proposed names or file names.
    public var dateRange: (first: DocumentFacts.Period, last: DocumentFacts.Period)? {
        let periods = members.compactMap { s in
            StatementFamily.period(ofName: s.best?.proposedName ?? s.fileName, folder: "")
                ?? StatementFamily.period(ofName: s.fileName, folder: "")
        }
        guard let first = periods.min(), let last = periods.max() else { return nil }
        return (first, last)
    }
}

public enum FilingCardItem: Identifiable, Sendable, Equatable {
    case single(FilingSuggestion)
    case group(FilingCardGroup)

    public var id: String {
        switch self {
        case .single(let s): return s.id
        case .group(let g): return "group:" + g.id
        }
    }

    public var suggestions: [FilingSuggestion] {
        switch self {
        case .single(let s): return [s]
        case .group(let g): return g.members
        }
    }
}

public enum FilingCardGrouping {
    /// `suggestions` as cards, keeping their order: files matched to the same account and going to
    /// the same folder at the same confidence become one group card where the first of them stood.
    /// `pulledOut` are files the user took out of a group; they stay cards of their own.
    public static func items(_ suggestions: [FilingSuggestion], pulledOut: Set<String> = []) -> [FilingCardItem] {
        func key(_ s: FilingSuggestion) -> String? {
            guard !pulledOut.contains(s.id), let best = s.best, let account = best.account,
                  best.confidence >= .medium else { return nil }
            // The same own number too: a card says "account ••X on page 1 of all N".
            return account.root + "\u{0}" + best.path + "\u{0}" + best.confidence.rawValue + "\u{0}" + account.ending
        }
        var members: [String: [FilingSuggestion]] = [:]
        for s in suggestions { if let k = key(s) { members[k, default: []].append(s) } }
        var emitted = Set<String>()
        var out: [FilingCardItem] = []
        for s in suggestions {
            guard let k = key(s), let group = members[k], group.count >= 2 else { out.append(.single(s)); continue }
            guard emitted.insert(k).inserted, let best = group[0].best, let account = best.account else { continue }
            out.append(.group(FilingCardGroup(account: account, destination: best,
                                              members: group.sorted { $0.fileName < $1.fileName })))
        }
        return out
    }
}
