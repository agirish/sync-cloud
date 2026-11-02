import Foundation

/// A folder the Move picker suggests, with the reason it gives.
///
/// **Offered only when the evidence is strong**, decided 2026-11-01: guesses that are right only
/// part of the time read as noise in a picker, so a weak one is never shown at all. The one
/// suggestion today is the year folder its neighbours imply (`yearFolder`), which is a fact
/// about the folder rather than a guess about the file.
public struct DestinationSuggestion: Equatable, Sendable {
    /// Absolute path of the folder, existing or to be made.
    public let path: String
    public let name: String
    /// True when the folder does not exist yet: choosing it makes it first.
    public let isNew: Bool
    /// Why, in the words the picker shows under the name.
    public let reason: String

    public init(path: String, name: String, isNew: Bool, reason: String) {
        self.path = path
        self.name = name
        self.isNew = isNew
        self.reason = reason
    }
}

public enum DestinationSuggestions {
    /// The fewest year-named folders beside the item that count as a pattern. Two could be chance;
    /// three in one folder, and a majority of its folders, is how a person files by year.
    public static let minimumYearPeers = 3

    /// **The year folder an item belongs in, when the folders beside it are years.**
    ///
    /// Moving `16. Sep 2026` out of a folder holding `2012 … 2025` and `Family`: the neighbours
    /// are years, the item names one, so it goes in `2026` — made here if it is not here yet. The
    /// reorganisation this was built from (Travel › Trips › IN-US, 2026-11-01) was exactly that,
    /// one trip at a time.
    ///
    /// Every condition is a refusal rather than a weaker answer:
    /// - at least `minimumYearPeers` sibling folders are years, and they are most of the folders;
    /// - every item names exactly one year, and all name the same one (a selection spanning two
    ///   years has no single home);
    /// - no item is itself a year folder (moving `2026` into `2026` is not a suggestion).
    ///
    /// - Parameters:
    ///   - itemPaths: the items being moved, all in `parent`.
    ///   - parent: the folder they are in.
    ///   - siblingFolders: names of the folders in `parent`, the items' own included or not.
    public static func yearFolder(for itemPaths: [String], in parent: String,
                                  siblingFolders: [String],
                                  latestYear: Int = Calendar.current.component(.year, from: Date()) + 5) -> DestinationSuggestion? {
        let itemNames = itemPaths.map { (PaneBrowsePath.normalized($0) as NSString).lastPathComponent }
        guard !itemNames.isEmpty, !parent.isEmpty else { return nil }
        let peers = siblingFolders.filter { !itemNames.contains($0) }
        let yearPeers = Set(peers.filter { isYear($0, latestYear: latestYear) })
        guard yearPeers.count >= minimumYearPeers, yearPeers.count * 2 > peers.count else { return nil }

        var year: String?
        for name in itemNames {
            guard !isYear(name, latestYear: latestYear) else { return nil }
            // The whole name, extension and all: "16.09.2026" and "Trip.2026" keep their year after
            // the last dot, and no file extension is a year standing alone.
            let found = Set(years(in: name, latestYear: latestYear))
            guard found.count == 1, let only = found.first else { return nil }
            if let year, year != only { return nil }
            year = only
        }
        guard let year else { return nil }
        let path = (PaneBrowsePath.normalized(parent) as NSString).appendingPathComponent(year)
        let exists = yearPeers.contains(year)
        return DestinationSuggestion(
            path: path, name: year, isNew: !exists,
            // Short: it is one line under the name in a narrow column.
            reason: exists ? "Like the years beside it" : "New, like the years beside it")
    }

    /// A folder named exactly as a year.
    static func isYear(_ name: String, latestYear: Int) -> Bool {
        name.count == 4 && years(in: name, latestYear: latestYear) == [name]
    }

    /// **The years `text` names, as words on their own** — 1900 to `latestYear`, four ASCII digits
    /// with no letter, digit or underscore against either side. "Sep 2026", "16.09.2026" and
    /// "2026-09-16" name 2026; a camera's "IMG_2047", "DSC_1999", "1920x1080", a flight "AI2016"
    /// and a PNR's digits name none — a counter that happens to fall in range is not a year, and a
    /// suggestion offered on one would be confidently wrong.
    ///
    /// A span written "2025-26" (a fiscal year, a season) names BOTH years, so it never has one
    /// home: the two-digit tail is read as the next year when it is exactly that.
    static func years(in text: String, latestYear: Int) -> [String] {
        guard latestYear >= 1900 else { return [] }   // an empty range would trap below
        let chars = Array(text)
        func isWordCharacter(_ c: Character?) -> Bool {
            guard let c else { return false }
            return c.isLetter || c.isNumber || c == "_"
        }
        var found: [String] = []
        var index = 0
        while index + 4 <= chars.count {
            let window = chars[index..<index + 4]
            if window.allSatisfy(\.isASCIIDigitCharacter),
               !isWordCharacter(index > 0 ? chars[index - 1] : nil),
               !isWordCharacter(index + 4 < chars.count ? chars[index + 4] : nil),
               let value = Int(String(window)), (1900...latestYear).contains(value) {
                found.append(String(window))
                // "2025-26": a dash, then exactly two digits that are the next year's last two.
                let tail = index + 5
                if tail + 2 <= chars.count, chars[index + 4] == "-" || chars[index + 4] == "–",
                   chars[tail..<tail + 2].allSatisfy(\.isASCIIDigitCharacter),
                   !isWordCharacter(tail + 2 < chars.count ? chars[tail + 2] : nil),
                   Int(String(chars[tail..<tail + 2])) == (value + 1) % 100 {
                    found.append(String(value + 1))
                }
                index += 4
            } else {
                index += 1
            }
        }
        return found
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
