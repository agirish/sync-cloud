import Foundation

/// A new folder for a file no existing folder holds well (TE327): a sibling named the way the
/// folders beside it are named, made on the same card as the move.
///
/// Two ways to name it (decision JG):
/// - **dated siblings** are named here, from the file's name: a year beside years (`2027` beside
///   `2012 … 2026`), a year range beside ranges of the same length (`2026-2027` beside `2015-2016 …`);
/// - **named siblings** (`India`, `Singapore`) can't be named from a pattern; their names go to
///   Claude, which may offer a new one with `propose_changes`.
///
/// Never inside a hidden folder, and never one that already exists.
public enum FilingNewHome {

    /// A folder to make for the file.
    public struct Offer: Equatable, Sendable {
        /// Absolute: where it is made, and its path.
        public let parent: String
        public let name: String
        /// The last few siblings it is named like, oldest first: "2024", "2025", "2026".
        public let siblings: [String]

        public var path: String { (parent as NSString).appendingPathComponent(name) }

        /// "Named like 2024, 2025, 2026".
        public var reason: String { "Named like " + siblings.joined(separator: ", ") }
    }

    /// The folders of one folder whose names are plain words, for Claude to name a new one like.
    public struct NamedSiblings: Codable, Equatable, Sendable {
        /// Absolute.
        public let parent: String
        public let names: [String]

        public init(parent: String, names: [String]) {
            self.parent = parent
            self.names = names
        }
    }

    /// The siblings a card shows as what the name follows.
    static let siblingsShown = 3
    /// The most sibling names Claude is given.
    static let namesSent = 12

    /// The new dated folder for `fileName`, tried beside each of `candidates` (best first): in the
    /// candidate itself, then in its parent. `childFolders` names a folder's folders; `exists`
    /// says whether a path is on disk.
    public static func dated(fileName: String, candidates: [String], within root: String,
                             childFolders: (String) -> [String], exists: (String) -> Bool,
                             isHidden: (String) -> Bool,
                             latestYear: Int = Calendar.current.component(.year, from: Date()) + 5) -> Offer? {
        var tried = Set<String>()
        for candidate in candidates {
            for parent in [candidate, (candidate as NSString).deletingLastPathComponent] {
                guard tried.insert(parent).inserted, isAtOrUnder(parent, root), !isHidden(parent) else { continue }
                let siblings = childFolders(parent).filter { !isHidden((parent as NSString).appendingPathComponent($0)) }
                guard let offer = yearOffer(fileName, parent: parent, siblings: siblings, latestYear: latestYear)
                        ?? rangeOffer(fileName, parent: parent, siblings: siblings, latestYear: latestYear),
                      !isHidden(offer.path), !exists(offer.path),
                      !siblings.contains(where: { $0.caseInsensitiveCompare(offer.name) == .orderedSame }) else { continue }
                return offer
            }
        }
        return nil
    }

    /// `parent`'s folders when they are plain names (no digits), three or more and most of them:
    /// the kind Claude may add one to. Hidden ones are left out, and never said.
    public static func named(parent: String, within root: String, childFolders: (String) -> [String],
                             isHidden: (String) -> Bool) -> NamedSiblings? {
        guard isAtOrUnder(parent, root), parent != root, !isHidden(parent) else { return nil }
        let siblings = childFolders(parent).filter { !isHidden((parent as NSString).appendingPathComponent($0)) }
        let words = siblings.filter { !$0.contains(where: \.isNumber) }
        guard words.count >= DestinationSuggestions.minimumYearPeers, words.count * 2 > siblings.count else { return nil }
        let sorted = words.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return NamedSiblings(parent: parent, names: Array(sorted.prefix(namesSent)))
    }

    // MARK: Patterns

    static func yearOffer(_ fileName: String, parent: String, siblings: [String], latestYear: Int) -> Offer? {
        guard let found = DestinationSuggestions.yearFolder(for: [fileName], in: parent, siblingFolders: siblings,
                                                            latestYear: latestYear), found.isNew else { return nil }
        let years = siblings.filter { DestinationSuggestions.isYear($0, latestYear: latestYear) }.sorted()
        return Offer(parent: parent, name: found.name, siblings: Array(years.suffix(siblingsShown)))
    }

    /// A range beside ranges: three or more `YYYY-YYYY` folders, most of the folders, all
    /// spanning the same years; the file names one range of that span ("FY 2026-27").
    static func rangeOffer(_ fileName: String, parent: String, siblings: [String], latestYear: Int) -> Offer? {
        let ranges = siblings.compactMap { name -> (String, Int)? in
            guard let r = range(name, latestYear: latestYear) else { return nil }
            return (name, r.end - r.start)
        }
        guard ranges.count >= DestinationSuggestions.minimumYearPeers, ranges.count * 2 > siblings.count,
              let span = ranges.first?.1, span > 0, ranges.allSatisfy({ $0.1 == span }) else { return nil }
        // The years the name says, in order; a range of the same span among them, and only one.
        let years = DestinationSuggestions.years(in: fileName, latestYear: latestYear).compactMap(Int.init)
        var found = Set<Int>()
        for (a, b) in zip(years, years.dropFirst()) where b - a == span { found.insert(a) }
        guard found.count == 1, let start = found.first,
              Set(years).isSubset(of: [start, start + span]) else { return nil }
        let name = "\(start)-\(start + span)"
        let sorted = ranges.map(\.0).sorted()
        return Offer(parent: parent, name: name, siblings: Array(sorted.suffix(siblingsShown)))
    }

    /// "2015-2016" as its two years.
    static func range(_ name: String, latestYear: Int) -> (start: Int, end: Int)? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 4 && DestinationSuggestions.isYear(String($0), latestYear: latestYear) }),
              let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
        return (a, b)
    }

    static func isAtOrUnder(_ path: String, _ root: String) -> Bool {
        let p = path.lowercased(), r = root.lowercased()
        return p == r || p.hasPrefix(r + "/")
    }
}
