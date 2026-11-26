import AppKit
import PDFKit
import SwiftUI
import Sync
import Design

/// The app's own page-1 view of a card's file: the page, with what To File read marked where it
/// sits (the account number it matched on and the statement's date), and where it moves. ← and →
/// step through the card's files. Nothing files from here: it is the look before File.
struct FilingPagePeek: View {
    let members: [FilingSuggestion]
    let start: String
    let facts: (FilingSuggestion) -> DocumentFacts?

    @State private var index: Int?
    @State private var page: FilingPageRender?
    @State private var loading = true
    @FocusState private var focused: Bool

    private var current: Int { index ?? members.firstIndex { $0.id == start } ?? 0 }
    private var file: FilingSuggestion? { members.indices.contains(current) ? members[current] : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text((file?.fileName ?? "") + " · page 1")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if members.count > 1 {
                    Text("\(current + 1) of \(members.count)").monospacedDigit()
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).disabled(current == 0)
                        .help("Previous file (←)")
                        .accessibilityLabel("Previous file")
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless).disabled(current >= members.count - 1)
                        .help("Next file (→)")
                        .accessibilityLabel("Next file")
                }
            }
            .scaledFont(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            pageView
                .frame(width: 340, height: 440)
                .padding(12)
            Divider()
            if let file { factsGrid(file).padding(12) }
        }
        .frame(width: 364)
        // ← and → step through the card's files, answered here rather than as key equivalents,
        // which would be window-wide.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .task(id: file?.id) { await load() }
    }

    @ViewBuilder
    private var pageView: some View {
        if let page {
            GeometryReader { geo in
                let fit = FilingPageRender.fit(page.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: page.image).resizable().frame(width: fit.width, height: fit.height)
                    ForEach(Array(page.marks.enumerated()), id: \.offset) { _, mark in
                        let r = FilingPageRender.scaled(mark, from: page.size, to: fit)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.yellow.opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.orange, lineWidth: 1))
                            .frame(width: r.width + 4, height: r.height + 2)
                            .offset(x: r.minX - 2, y: r.minY - 1)
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .accessibilityLabel("Page 1 of \(file?.fileName ?? "the file")")
        } else if loading {
            ProgressView().controlSize(.small)
        } else if let file {
            FilingPageThumbnail(path: file.filePath, name: file.fileName, modified: file.modificationDate,
                                size: CGSize(width: 300, height: 400))
        }
    }

    private func factsGrid(_ s: FilingSuggestion) -> some View {
        let f = facts(s)
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            if let matched = FilingPageRender.matchedLine(s, facts: f, marked: !(page?.marks.isEmpty ?? true)) {
                GridRow {
                    label("Matched")
                    Text(matched).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let best = s.best {
                GridRow {
                    label("Moves to")
                    Text(FilingRouteText.short(FilingRouteText.movesTo(best, providerRoot: s.providerRoot), keep: 2).text
                         + " as " + (best.proposedName ?? s.fileName))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .scaledFont(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased()).scaledFont(.system(size: 9.5, weight: .semibold)).tracking(0.4).foregroundStyle(.tertiary)
    }

    private func step(_ by: Int) {
        index = min(max(current + by, 0), members.count - 1)
    }

    private func load() async {
        guard let file else { return }
        loading = true
        page = nil
        let marks = FilingPageRender.searchTerms(file, facts: facts(file))
        let rendered = await FilingPageRender.render(path: file.filePath, marking: marks)
        guard !Task.isCancelled else { return }
        page = rendered
        loading = false
    }
}

/// Page 1 drawn to an image, and where on it the marked words sit, in the page's own points with
/// the origin at its top left.
struct FilingPageRender: @unchecked Sendable {
    let image: NSImage
    let size: CGSize
    let marks: [CGRect]

    /// What to mark: the account number's last digits as printed, and the statement date in the
    /// spellings statements use.
    static func searchTerms(_ s: FilingSuggestion, facts: DocumentFacts?) -> [String] {
        var out: [String] = []
        // The card's own account, not the page's first number: a page can print a reference or
        // another account's number first.
        if let own = s.best?.account?.ending ?? facts?.ownNumbers.first?.ending { out.append(own) }
        if let p = facts?.period { out += dateSpellings(p) }
        return out
    }

    /// "01/29/26", "01/29/2026", "1/29/2026", "January 29, 2026", "Jan 29, 2026".
    static func dateSpellings(_ p: DocumentFacts.Period) -> [String] {
        guard (1...12).contains(p.month), let d = p.day else { return [] }
        // Statements print English month names, whatever this Mac's language.
        let long = ["January", "February", "March", "April", "May", "June", "July", "August",
                    "September", "October", "November", "December"][p.month - 1]
        let short = String(long.prefix(3))
        let mm = String(format: "%02d", p.month), dd = String(format: "%02d", d), yy = String(format: "%02d", p.year % 100)
        return ["\(mm)/\(dd)/\(yy)", "\(mm)/\(dd)/\(p.year)", "\(p.month)/\(d)/\(p.year)",
                "\(long) \(d), \(p.year)", "\(short) \(d), \(p.year)"]
    }

    /// "account ••44928, Jan 29, 2026 (marked)": what page 1 matched on, in words, and "(marked)"
    /// only when the picture marks something.
    static func matchedLine(_ s: FilingSuggestion, facts: DocumentFacts?, marked: Bool) -> String? {
        var parts: [String] = []
        if let ending = s.best?.account?.ending { parts.append("account ••" + ending) }
        if let p = facts?.period { parts.append(FilingFileText.date(p)) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ") + (marked ? " (marked)" : "")
    }

    /// Where `term` first sits in `text` as a whole number or phrase: not inside a longer run of
    /// digits, so "9312" never marks part of "193120".
    static func wholeRange(of term: String, in text: String) -> NSRange? {
        let pattern = "(?<![0-9])" + NSRegularExpression.escapedPattern(for: term) + "(?![0-9])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
    }

    static func render(path: String, marking terms: [String]) async -> FilingPageRender? {
        guard (path as NSString).pathExtension.lowercased() == "pdf" else { return nil }
        return await PDFKitSerialAccess.perform { () -> FilingPageRender? in
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked,
                  let page = doc.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            // A turned page draws turned: its picture is the other way round, and its marks would
            // need turning too, so a turned page shows without them.
            let turned = page.rotation % 180 != 0
            let size = turned ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
            let image = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .cropBox)
            var marks: [CGRect] = []
            for term in terms where !term.isEmpty && page.rotation == 0 {
                // The first place a term sits on page 1; the account number's digits print once in
                // the header on most statements, and a date may repeat in the transactions.
                guard let text = page.string, let range = wholeRange(of: term, in: text),
                      let hit = page.selection(for: range) else { continue }
                let r = hit.bounds(for: page)
                marks.append(CGRect(x: r.minX - bounds.minX, y: bounds.maxY - r.maxY, width: r.width, height: r.height))
                if marks.count >= 3 { break }
            }
            return FilingPageRender(image: image, size: size, marks: marks)
        }
    }

    /// `size` fitted inside `box`, keeping its ratio.
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    static func scaled(_ r: CGRect, from page: CGSize, to shown: CGSize) -> CGRect {
        guard page.width > 0 else { return .zero }
        let s = shown.width / page.width
        return CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
    }
}
