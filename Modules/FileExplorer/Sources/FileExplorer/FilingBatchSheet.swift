import SwiftUI
import Sync
import Design

/// One line of File All's sheet: a Matched card, its route in short, and how many it files.
struct FilingBatchLine: Identifiable, Equatable {
    let item: FilingCardItem
    /// "American Express", or the file's name for a card with no account.
    let title: String
    /// "5652", shown "••5652" after the title; nil with no account.
    let ending: String?
    let count: Int
    let from: FilingRoutePath
    let to: FilingRoutePath
    /// What placed a card with no account: "by its name", "by a rule you taught". nil for an account.
    let source: String?
    /// What else filing it does, said on its line: "into the archive", "also copies into Roth IRA
    /// 5442". The route's own new-folder tags are on `to`.
    var extras: [String] = []
    var id: String { item.id }
    var accountRoot: String? { item.suggestions.first?.best?.account?.root }
    var isStatements: Bool {
        item.suggestions.allSatisfy { $0.best?.account?.kind == .statement }
    }
}

/// File All's sheet in words, apart from the view so it can be tested: which cards it lists, what
/// it says, and what the ticked ones file (decision OQ).
enum FilingBatchPlan {
    /// Every Matched card with something to move, in the list's order. Check first and Needs your
    /// pick are never here (``FilingSuggestion/isMatched``).
    ///
    /// `destinations` are homes typed on a card (a new folder's name), by file id; `copies` says what
    /// filing a file copies into under the preferences now.
    static func lines(_ items: [FilingCardItem], scannedRoot: String?,
                      destinations: [String: FilingDestination] = [:],
                      copies: (FilingSuggestion) -> [FilingCopy] = { $0.best?.alsoCopiesTo ?? [] }) -> [FilingBatchLine] {
        items.compactMap { item in
            let files = item.toFile.filter(\.isMatched)
            guard let first = files.first, let best = destinations[first.id] ?? first.best else { return nil }
            let from = FilingRouteText.short(FilingRouteText.from(files, scannedRoot: scannedRoot), keep: 2)
            let to = FilingRouteText.short(FilingRouteText.movesTo(best, providerRoot: first.providerRoot), keep: 3, dropRoot: true)
            var extras: [String] = []
            if best.account?.archived == true { extras.append("into the archive") }
            var seen = Set<String>()
            let copied = files.flatMap(copies).filter { seen.insert($0.account.root).inserted }
            if !copied.isEmpty {
                extras.append("also copies into " + ListFormatter.localizedString(byJoining: copied.map(FilingCopiesText.accountLabel)))
            }
            if let account = best.account {
                let bank: String
                if case .group(let g) = item { bank = FilingGroupText.bank(g) }
                else { bank = account.institutionName.isEmpty ? FilingGroupText.titleCased(account.institution) : account.institutionName }
                return FilingBatchLine(item: item, title: bank, ending: account.ending, count: files.count,
                                       from: from, to: to, source: nil, extras: extras)
            }
            return FilingBatchLine(item: item, title: first.fileName, ending: nil, count: files.count, from: from, to: to,
                                   source: "by " + FilingBatchLog.source(of: best), extras: extras)
        }
    }

    /// "File 210 statements into 21 accounts?", or files and folders when any card has no account.
    static func title(_ lines: [FilingBatchLine], unticked: Set<String> = []) -> String {
        let ticked = lines.filter { !unticked.contains($0.id) }
        let n = ticked.reduce(0) { $0 + $1.count }
        let accounts = ticked.allSatisfy { $0.accountRoot != nil }
        let places = Set(ticked.map { $0.accountRoot ?? $0.item.suggestions.first?.best?.path ?? $0.id }).count
        let noun = accounts && ticked.allSatisfy(\.isStatements) ? "statement" : "file"
        return "File \(n.formatted()) \(n == 1 ? noun : noun + "s") into \(places.formatted()) "
            + (accounts ? (places == 1 ? "account" : "accounts") : (places == 1 ? "folder" : "folders")) + "?"
    }

    /// "Unticked: Charles Schwab ••9312 (10) stays as its card." nil with nothing unticked.
    static func footer(_ lines: [FilingBatchLine], unticked: Set<String>) -> String? {
        let off = lines.filter { unticked.contains($0.id) }
        guard !off.isEmpty else { return nil }
        if off.count == 1, let l = off.first {
            return "Unticked: \(name(l)) (\(l.count)) stays as its card."
        }
        let files = off.reduce(0) { $0 + $1.count }
        return "Unticked: \(off.count) cards (\(files) files) stay as they are."
    }

    static func name(_ l: FilingBatchLine) -> String { l.title + (l.ending.map { " ••" + $0 } ?? "") }

    /// The cards to file: the ticked ones, in the sheet's order.
    static func ticked(_ lines: [FilingBatchLine], unticked: Set<String>) -> [FilingCardItem] {
        lines.filter { !unticked.contains($0.id) }.map(\.item)
    }

    static func fileCount(_ lines: [FilingBatchLine], unticked: Set<String>) -> Int {
        lines.filter { !unticked.contains($0.id) }.reduce(0) { $0 + $1.count }
    }

    /// Lines shown before "N more · Show All".
    static let shownBeforeMore = 6
}

/// File All N…: every Matched card, each ticked, each with an untick box and its route, looked
/// over before anything moves. One ⌘Z undoes all of it.
struct FilingBatchSheet: View {
    let lines: [FilingBatchLine]
    let accent: Color
    let onFile: ([FilingCardItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var unticked: Set<String> = []
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(FilingBatchPlan.title(lines, unticked: unticked))
                    .scaledFont(.system(size: 14, weight: .semibold))
                Text("Every move can be undone with ⌘Z, all at once.")
                    .scaledFont(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            // A short list is shown whole; a long one scrolls in a box of its own.
            if showsAll && lines.count > FilingBatchPlan.shownBeforeMore {
                ScrollView { list }.frame(height: 420)
            } else {
                list
            }
            Divider()
            HStack(spacing: 8) {
                if let footer = FilingBatchPlan.footer(lines, unticked: unticked) {
                    Text(footer).scaledFont(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                let n = FilingBatchPlan.fileCount(lines, unticked: unticked)
                Button("File \(n.formatted())") {
                    let items = FilingBatchPlan.ticked(lines, unticked: unticked)
                    dismiss()
                    onFile(items)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).accentedProminent()
                .disabled(n == 0)
            }
            .padding(14)
        }
        .frame(width: 640)
    }

    private var list: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 0) {
            let shown = showsAll ? lines : Array(lines.prefix(FilingBatchPlan.shownBeforeMore))
            ForEach(shown) { line in
                lineRow(line)
                if line.id != shown.last?.id || lines.count > shown.count { Divider().gridCellUnsizedAxes(.horizontal) }
            }
            if lines.count > shown.count {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("\(lines.count - shown.count) more")
                        .foregroundStyle(.secondary)
                    Button("Show All") { showsAll = true }
                        .buttonStyle(.link)
                }
                .scaledFont(.system(size: 12.5))
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func lineRow(_ line: FilingBatchLine) -> some View {
        GridRow {
            Toggle(isOn: Binding(get: { !unticked.contains(line.id) },
                                 set: { on in if on { unticked.remove(line.id) } else { unticked.insert(line.id) } })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("File \(FilingBatchPlan.name(line))")
            (Text(line.title).fontWeight(.semibold)
             + Text(line.ending.map { " ••" + $0 } ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
             + Text(" · \(line.count)").foregroundStyle(.secondary))
                .scaledFont(.system(size: 12.5))
                .lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 150, maxWidth: 220, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.from.text).lineLimit(1).truncationMode(.middle)
                (Text("→ ").foregroundStyle(.tertiary) + boldPath(line.to)
                 + Text(line.source.map { "  " + $0 } ?? "").font(.system(size: 10.5)).foregroundStyle(.tertiary))
                    .lineLimit(1).truncationMode(.head)
                if !line.extras.isEmpty {
                    Text(line.extras.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scaledFont(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .opacity(unticked.contains(line.id) ? 0.55 : 1)
    }

    private func boldPath(_ p: FilingRoutePath) -> Text {
        var t = Text("")
        for (i, c) in p.crumbs.enumerated() {
            if i > 0 { t = t + Text(" › ").foregroundStyle(.tertiary) }
            t = t + Text(c.name).fontWeight(c.bold ? .semibold : .regular).foregroundStyle(c.bold ? Color.primary : Color.secondary)
            // What the batch makes, as the card says it.
            if let tag = c.tag { t = t + Text(" " + tag).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(accent) }
        }
        if let note = p.note { t = t + Text("  (" + note + ")").font(.system(size: 10.5)).italic().foregroundStyle(.tertiary) }
        return t
    }
}
