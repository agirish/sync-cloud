import SwiftUI
import Sync
import Design

/// One path on a card's route, as crumbs: what its From, Moves to, Best guess and Copies to lines
/// show. Written out in full and wrapped, never cut: the route is the whole point of the card.
struct FilingRoutePath: Equatable {
    struct Crumb: Equatable {
        let name: String
        /// The account and its year, which matter most.
        var bold = false
        /// The accent "new account" or "new folder" tag after it.
        var tag: String? = nil
    }
    var crumbs: [Crumb]
    /// A quiet note after the path: "new 2026 folder", a year made inside an account it has.
    var note: String? = nil

    /// "Documents › Finance › Credit 22002 › 2026", for tests, tooltips and VoiceOver.
    var text: String { crumbs.map(\.name).joined(separator: " › ") }

    /// The words VoiceOver reads: the path, with its tags and note.
    var spoken: String {
        let parts = crumbs.map { c in c.tag.map { c.name + ", " + $0 } ?? c.name }
        return parts.joined(separator: ", ") + (note.map { ", " + $0 } ?? "")
    }
}

/// One line of a card's route: its label in the fixed column, and its path.
struct FilingRouteLine: Equatable, Identifiable {
    let label: String
    let path: FilingRoutePath
    var id: String { label }
}

/// A card's route in words, apart from the views so it can be tested: "From" relative to the
/// folder the scan walked, "Moves to" relative to the tree it files into (decision of the cards
/// redesign, mockup v6).
enum FilingRouteText {
    /// The labels' column takes the widest of these, so paths start together on every card.
    static let labels = ["From", "Moves to", "Best guess", "Copies to"]

    /// The card's route lines: From, then Moves to (Best guess for a home it isn't sure of), then
    /// Copies to for a statement that names other accounts.
    static func lines(members: [FilingSuggestion], destination: FilingDestination?, scannedRoot: String?,
                      copies: [FilingCopy] = []) -> [FilingRouteLine] {
        var out = [FilingRouteLine(label: "From", path: from(members, scannedRoot: scannedRoot))]
        if let destination, let first = members.first {
            let label = destination.confidence >= .medium ? "Moves to" : "Best guess"
            out.append(FilingRouteLine(label: label, path: movesTo(destination, providerRoot: first.providerRoot)))
        }
        if !copies.isEmpty, let first = members.first {
            let paths = copies.map { movesTo(FilingDestination(path: $0.path, confidence: .high, reasons: [], newSegments: []),
                                             providerRoot: first.providerRoot) }
            var joined = FilingRoutePath(crumbs: [])
            for (i, p) in paths.enumerated() {
                joined.crumbs += i == 0 ? p.crumbs : [FilingRoutePath.Crumb(name: "and " + (p.crumbs.first?.name ?? ""))] + p.crumbs.dropFirst()
            }
            out.append(FilingRouteLine(label: "Copies to", path: joined))
        }
        return out
    }

    /// Where the files are now: the scanned folder's name, then the folders below it. Files from
    /// different folders give the folder they share, and each row then names its own
    /// (``rowFrom(_:members:scannedRoot:)``).
    static func from(_ members: [FilingSuggestion], scannedRoot: String?) -> FilingRoutePath {
        let folders = members.map { ($0.filePath as NSString).deletingLastPathComponent }
        let shared = commonFolder(folders)
        var path = FilingRoutePath(crumbs: components(of: shared, under: scannedRoot).map { .init(name: $0) })
        if Set(folders).count > 1 { path.note = "several folders" }
        return path
    }

    /// A row's own "from", when the card's files come from different folders: the folders below the
    /// one the card names. nil when they all share one.
    static func rowFrom(_ s: FilingSuggestion, members: [FilingSuggestion]) -> String? {
        let folders = members.map { ($0.filePath as NSString).deletingLastPathComponent }
        guard Set(folders).count > 1 else { return nil }
        let shared = commonFolder(folders)
        let own = (s.filePath as NSString).deletingLastPathComponent
        guard let rel = PathBoundary.relativize(own, under: shared), !rel.isEmpty else { return nil }
        return rel.split(separator: "/").joined(separator: " › ")
    }

    /// Where they go: the tree's name (`Documents`, `iCloud`), then each folder, with the account
    /// and what is below it in bold, and the folders it would make marked.
    static func movesTo(_ dest: FilingDestination, providerRoot: String?) -> FilingRoutePath {
        let comps = components(of: dest.path, under: providerRoot)
        let newStart = comps.count - min(dest.newSegments.count, comps.count)
        // Bold from the account folder down; with no account, the folder it lands in.
        let accountIndex: Int? = dest.account.flatMap { account in
            let depth = (dest.path as NSString).pathComponents.count - (account.root as NSString).pathComponents.count
            let i = comps.count - 1 - depth
            return i >= 0 && i < comps.count ? i : nil
        }
        let boldFrom = accountIndex ?? (comps.count - 1)
        var crumbs = comps.enumerated().map { i, name in FilingRoutePath.Crumb(name: name, bold: i >= boldFrom) }
        var note: String?
        if dest.isNew, newStart < crumbs.count {
            let made = Array(comps[newStart...])
            if dest.createsAccountFolder {
                // The account it invents: worth an accent. Its year below goes unmarked.
                let i = accountIndex.map { max($0, newStart) } ?? newStart
                crumbs[i].tag = "new account"
            } else if made.allSatisfy(isPeriodFolder) {
                // A year inside an account it has: a quiet note, not a shout.
                note = "new " + made.joined(separator: " › ") + " folder" + (made.count == 1 ? "" : "s")
            } else {
                crumbs[newStart].tag = made.count == 1 ? "new folder" : "new folders"
            }
        }
        return FilingRoutePath(crumbs: crumbs, note: note)
    }

    /// The guess's button on a card with no confident home: "File in Social Security › 2026", or
    /// "File in 2026" on the narrowest line.
    static func guessButton(_ dest: FilingDestination, providerRoot: String?, short: Bool) -> String {
        let names = movesTo(dest, providerRoot: providerRoot).crumbs.map(\.name)
        return "File in " + names.suffix(short ? 1 : 2).joined(separator: " › ")
    }

    /// A weak guess's "why", worded as one: no "Matched".
    static func weakGuess(token: String) -> String {
        "A guess: only the word “\(token)” in the file ties it there"
    }

    /// A year or month folder (`2026`, `01`, `03 - March`).
    static func isPeriodFolder(_ name: String) -> Bool {
        FolderProfileEntry.looksLikeYear(name) || FilingPeriod.monthSlot(ofFolderNamed: name) != nil
    }

    /// Whether the card may offer "Create as": only for a folder it invents, never a year inside
    /// an account (renaming that in place is no use and an easy mistake).
    static func offersCreateAs(_ dest: FilingDestination) -> Bool {
        guard let leaf = dest.newSegments.last else { return false }
        return dest.createsAccountFolder || !isPeriodFolder(leaf)
    }

    /// `path`'s folders under `root`, led by the root's own name; tilde-abbreviated when it isn't
    /// under the root.
    static func components(of path: String, under root: String?) -> [String] {
        if let root, !root.isEmpty, let rel = PathBoundary.relativize(path, under: root) {
            return [rootLabel(root)] + rel.split(separator: "/").map(String.init)
        }
        return (path as NSString).abbreviatingWithTildeInPath.split(separator: "/").map(String.init)
    }

    /// The deepest folder every path is in.
    static func commonFolder(_ folders: [String]) -> String {
        guard var shared = folders.first.map({ ($0 as NSString).pathComponents }) else { return "" }
        for f in folders.dropFirst() {
            let c = (f as NSString).pathComponents
            shared = Array(zip(shared, c).prefix { $0 == $1 }.map(\.0))
        }
        return NSString.path(withComponents: shared)
    }

    /// A tree's name: `iCloud`, `Dropbox`, `Google Drive` for a cloud's own root, else the folder's.
    static func rootLabel(_ root: String) -> String {
        // Only the cloud's own root: a folder inside it (`…/CloudDocs/Documents/TODO`) is named
        // for itself.
        let url = URL(fileURLWithPath: root).standardizedFileURL
        let last = url.lastPathComponent
        if last.lowercased() == "com~apple~clouddocs" { return "iCloud" }
        if url.deletingLastPathComponent().lastPathComponent == "CloudStorage" {
            let vendor = last
            let base = vendor.split(separator: "-").first.map(String.init) ?? vendor
            switch base.lowercased() {
            case "googledrive": return "Google Drive"
            case "onedrive": return "OneDrive"
            case "dropbox": return "Dropbox"
            case "box": return "Box"
            default: if !base.isEmpty { return base }
            }
        }
        return last.isEmpty ? "Cloud" : last
    }

    /// The sheet's short form: the first folder, "…", and the last `keep`; or, `dropRoot`, "…"
    /// and the last `keep` alone, where the end is what tells two cards apart.
    static func short(_ path: FilingRoutePath, keep: Int, dropRoot: Bool = false) -> FilingRoutePath {
        guard path.crumbs.count > keep + (dropRoot ? 0 : 1) else { return path }
        var out = path
        out.crumbs = (dropRoot ? [] : [path.crumbs[0]]) + [.init(name: "…")] + path.crumbs.suffix(keep)
        return out
    }
}

/// A card's route: each label in one fixed column, so every card's paths start together; or, in
/// a narrow column, each label above its path.
struct FilingRouteGrid: View {
    let lines: [FilingRouteLine]
    let narrow: Bool
    let accent: Color
    /// Wide enough for "BEST GUESS", the longest label.
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 78

    var body: some View {
        if narrow {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        label(line.label).padding(.top, line.id == lines.first?.id ? 0 : 3)
                        FilingRoutePathText(path: line.path, accent: accent)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spoken(line))
                }
            }
        } else {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(lines) { line in
                    GridRow {
                        label(line.label).frame(width: labelWidth, alignment: .leading)
                        FilingRoutePathText(path: line.path, accent: accent)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spoken(line))
                }
            }
        }
    }

    /// "Moves to: Documents, Finance, …": which path is which, for VoiceOver.
    static func spoken(_ line: FilingRouteLine) -> String { line.label + ": " + line.path.spoken }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .scaledFont(.system(size: 9.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// One route path, wrapped rather than cut.
struct FilingRoutePathText: View {
    let path: FilingRoutePath
    let accent: Color

    var body: some View {
        var text = Text("")
        for (i, crumb) in path.crumbs.enumerated() {
            if i > 0 { text = text + Text(" › ").foregroundStyle(.tertiary) }
            // Wrapped only between folders, never inside a name: "Credit 22002" stays one piece.
            text = text + Text(crumb.name.replacingOccurrences(of: " ", with: "\u{00A0}"))
                .fontWeight(crumb.bold ? .semibold : .regular)
                .foregroundStyle(crumb.bold ? Color.primary : Color.secondary)
            if let tag = crumb.tag {
                text = text + Text("  " + tag.replacingOccurrences(of: " ", with: "\u{00A0}")).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent)
            }
        }
        if let note = path.note {
            text = text + Text("  " + note.replacingOccurrences(of: " ", with: "\u{00A0}")).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        return text
            .scaledFont(.system(size: 11.5, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(path.spoken)
    }
}
