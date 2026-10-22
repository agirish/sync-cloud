import SwiftUI
import Design
import Sync

/// What the Files list needs to search inside files (RD38): the window's search, the folder it
/// searches, and what opening a result does. `nil` on the rail draws the name filter alone — the
/// previews and layout probes, which have no folder behind them.
struct EditorRailContentSearch {
    let model: EditorContentSearchModel
    /// The rail's folder, as a path — the search covers it and every folder inside.
    let folder: String
    /// Opens a result: a text file at one of its lines (`nil` for its first), a PDF with its find
    /// holding the word, a Word or PowerPoint file in Quick Look.
    let onOpen: (EditorContentHit, EditorContentLine?) -> Void
}

/// **Names | Contents**, under the filter's field and inside its surface — the rail's tab bar's
/// look, at the field's width.
struct EditorRailFilterScopeBar: View {
    @Binding var scope: EditorRailFilterScope
    let accentFill: Color
    let onAccent: Color

    static let lensChannel = SelectionLensChannel("editor.rail.filterScope")

    var body: some View {
        HStack(spacing: 3) {
            ForEach(EditorRailFilterScope.allCases, id: \.self) { segment($0) }
        }
        .selectionLensHost(Self.lensChannel, selected: scope, style: .fill(.capsule, color: accentFill))
        .padding(2)
        .chromeGlassTrack()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search")
    }

    private func segment(_ candidate: EditorRailFilterScope) -> some View {
        let isSelected = scope == candidate
        return Button {
            scope = candidate
        } label: {
            // Semibold either way, for the tab bar's reason: weight changes width.
            Text(candidate.title)
                .scaledFont(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .selectionLensLabelInk(isSelected: isSelected, onFill: onAccent, unselected: Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected { SelectionLensTodayMarker { Capsule().fill(accentFill) } }
                }
                .selectionLensStop(Self.lensChannel, id: candidate)
                .contentShape(Capsule())
        }
        .selectionLensChoiceButtonStyle(isSelected: isSelected, tint: accentFill)
        .accessibilityLabel(candidate == .names ? "Filter by name" : "Search inside files")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(candidate == .names ? "List the files here whose names hold the words"
                                  : "Search inside the files here and in the folders inside")
    }
}

/// The filter's field with the switch under it, for a rail that can search inside files.
///
/// **Observes the search, and that is why it is its own view**: the placeholder and ↩ follow the
/// switch, and the rail around it is redrawn on every keystroke in the document beside it — it
/// must not also redraw for every file the search reads.
///
/// **Where the search is asked for.** Only while the field is showing — it exists for exactly as
/// long as the filter is open — and stopped when it goes, so a search never runs behind a
/// folded filter, another tab or another workspace.
struct EditorRailFilterField: View {
    @ObservedObject var model: EditorContentSearchModel
    let search: EditorRailContentSearch
    @Binding var filter: String
    @Binding var isExpanded: Bool
    let accentFill: Color
    let onAccent: Color
    /// ↩ on Names: the rail's own — open the first row and hand the list the keys (TE110).
    let onSubmitNames: () -> Void

    var body: some View {
        ExpandingSearchField(text: $filter, isExpanded: $isExpanded,
                             placeholder: model.scope.placeholder,
                             accessories: { _ in
                                 EditorRailFilterScopeBar(scope: $model.scope, accentFill: accentFill,
                                                          onAccent: onAccent)
                                     .padding(.top, 4)
                             })
            .onSubmit {
                guard model.scope == .contents else { return onSubmitNames() }
                // ↩ asks now rather than after the settle, and opens the first result once there is
                // one — the name filter's ↩, for contents.
                if let first = model.firstResult, model.key?.query == EditorContentSearchModel.searchable(filter) {
                    search.onOpen(first.hit, first.line)
                } else if let needle = EditorContentSearchModel.searchable(filter) {
                    model.run(.init(folder: search.folder, query: needle))
                }
            }
            .onChange(of: RequestKey(folder: search.folder, query: filter, scope: model.scope), initial: true) { _, key in
                model.request(folder: key.folder, query: key.query)
            }
            .onDisappear { model.cancel() }
    }

    private struct RequestKey: Equatable {
        var folder: String
        var query: String
        var scope: EditorRailFilterScope
    }
}

/// The names list, or — with the switch on Contents — the files whose contents match.
struct EditorRailContentSwitch<Names: View>: View {
    @ObservedObject var model: EditorContentSearchModel
    let search: EditorRailContentSearch
    let folderName: String
    let query: String
    let accent: Color
    let selectedPath: String?
    let rowActions: EditorRailRowActions
    @ViewBuilder let names: () -> Names

    var body: some View {
        if model.scope == .contents {
            EditorRailContentResults(model: model, search: search, folderName: folderName, query: query,
                                     accent: accent, selectedPath: selectedPath, rowActions: rowActions)
        } else {
            names()
        }
    }
}

/// **The Contents results**: the text files that hold the word, each with its matching lines, then
/// the PDFs (and Word and PowerPoint files) Spotlight says hold it — two groups, each labelled with
/// where its answer came from, because the two answer differently (``EditorContentSpotlight``).
struct EditorRailContentResults: View {
    @ObservedObject var model: EditorContentSearchModel
    let search: EditorRailContentSearch
    let folderName: String
    let query: String
    let accent: Color
    let selectedPath: String?
    let rowActions: EditorRailRowActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let caption = EditorRailContentCaption.status(
                    query: query, folderName: folderName, key: model.key, text: model.textPhase,
                    spotlight: model.spotlightPhase, textFiles: model.textHits.count,
                    documents: model.documentHits.count) {
                    Text(caption)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                }
                if !model.textHits.isEmpty {
                    heading(EditorRailContentCaption.textHeading(count: model.textHits.count))
                    ForEach(model.textHits) { hit in
                        fileRow(hit)
                        ForEach(hit.lines) { line in lineRow(line, in: hit) }
                        if hit.lineCount > hit.lines.count {
                            Text(EditorRailContentCaption.moreLines(hit.lineCount - hit.lines.count))
                                .scaledFont(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 38)
                                .padding(.vertical, 2)
                        }
                    }
                }
                if let heading = EditorRailContentCaption.documentHeading(model.documentHits,
                                                                          phase: model.spotlightPhase) {
                    self.heading(heading)
                    ForEach(model.documentHits) { hit in documentRow(hit) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .scaledFont(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    /// A text file: its name, and the folder it is in when that is not the one searched.
    private func fileRow(_ hit: EditorContentHit) -> some View {
        let isSelected = hit.path == selectedPath
        return Button {
            search.onOpen(hit, nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: EditorFileRailView.rowSymbol(.text))
                    .scaledFont(.system(size: 11))
                Text(hit.name)
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !hit.subfolder.isEmpty {
                    Text(hit.subfolder)
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(EditorFileRailView.rowOutline)
        }
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .row, tint: accent, shape: EditorFileRailView.rowShape))
        .help(EditorRailContentCaption.relativePath(hit))
        .contextMenu { EditorRailRowMenu(path: hit.path, isCloudOnly: false, actions: rowActions) }
    }

    /// One matching line: its number, and the line with the match lit.
    private func lineRow(_ line: EditorContentLine, in hit: EditorContentHit) -> some View {
        Button {
            search.onOpen(hit, line)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(line.line)")
                    .scaledFont(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 24, alignment: .trailing)
                Text(EditorRailContentCaption.snippet(line, accent: accent))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(EditorFileRailView.rowOutline)
        }
        .buttonStyle(.hoverAffordance(.row, tint: accent, shape: EditorFileRailView.rowShape))
        .accessibilityLabel("Line \(line.line): \(line.snippet)")
        .help("Line \(line.line) of \(hit.name)")
    }

    /// A PDF, Word or PowerPoint file Spotlight named. Dim when its content is not on this Mac — Edit
    /// says why when it is opened, as it does for the same file's row on Names.
    private func documentRow(_ hit: EditorContentHit) -> some View {
        let isSelected = hit.path == selectedPath
        return Button {
            search.onOpen(hit, nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hit.kind == .pdf ? EditorFileRailView.rowSymbol(.pdf) : "doc")
                    .scaledFont(.system(size: 11))
                Text(hit.name)
                    .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !hit.subfolder.isEmpty {
                    Text(hit.subfolder)
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .opacity(hit.isCloudOnly && !isSelected ? 0.5 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(EditorFileRailView.rowOutline)
        }
        .buttonStyle(.hoverAffordance(isSelected ? .filled : .row, tint: accent, shape: EditorFileRailView.rowShape))
        .help(EditorRailContentCaption.documentHelp(hit, query: query))
        .contextMenu { EditorRailRowMenu(path: hit.path, isCloudOnly: hit.isCloudOnly, actions: rowActions) }
    }
}

/// The words the Contents results say — **functions, so each distinction is testable**, the shape
/// ``EditorFileRailView/fileEmptyCaption(folderName:anyEntries:filter:otherFiles:)`` takes.
enum EditorRailContentCaption {

    /// The line above the results: what to type, how far the search has got, or what it did not
    /// read. `nil` when there is nothing to add to the results themselves.
    static func status(query: String, folderName: String, key: EditorContentSearchModel.Key?,
                       text: EditorContentSearchModel.TextPhase,
                       spotlight: EditorContentSearchModel.SpotlightPhase,
                       textFiles: Int, documents: Int) -> String? {
        let place = folderName.isEmpty ? "this folder" : "“\(folderName)”"
        guard let needle = EditorContentSearchModel.searchable(query) else {
            return "Type a word to search inside the text files and PDFs in \(place) and the folders inside it."
        }
        // Typed, and still settling — or answering an older query.
        guard key?.query == needle else { return "Searching…" }
        switch text {
        case .idle:
            return nil
        case .searching(let progress):
            guard progress.walked else { return "Looking through the folders…" }
            return "Searching \(progress.read.formatted()) of \(progress.found.formatted()) text files…"
        case .finished(let summary):
            var parts: [String] = []
            if textFiles == 0 && documents == 0 && spotlight != .searching {
                parts.append("Nothing in \(place) or the folders inside it contains “\(needle)”.")
            } else {
                parts.append(summary.read == 1 ? "1 text file searched."
                                               : "\(summary.read.formatted()) text files searched.")
            }
            if summary.notDownloaded > 0 {
                parts.append(summary.notDownloaded == 1
                             ? "1 not downloaded, so not searched."
                             : "\(summary.notDownloaded.formatted()) not downloaded, so not searched.")
            }
            if summary.tooLarge > 0 {
                parts.append(summary.tooLarge == 1
                             ? "1 over \(FileSyncManager.formatBytes(BoundedTextRead.maxBytes)), so not searched."
                             : "\(summary.tooLarge.formatted()) over \(FileSyncManager.formatBytes(BoundedTextRead.maxBytes)), so not searched.")
            }
            if summary.unansweredFolders > 0 {
                parts.append(summary.unansweredFolders == 1
                             ? "1 folder isn’t downloaded."
                             : "\(summary.unansweredFolders.formatted()) folders aren’t downloaded.")
            }
            switch summary.stop {
            case .fileLimit(let files):
                parts.append("Stopped at \(files.formatted()) files — type more of the word to narrow it.")
            case .entryLimit(let entries):
                parts.append("Stopped after \(entries.formatted()) items — search a smaller folder.")
            case nil:
                break
            }
            if spotlight == .unavailable {
                parts.append("Spotlight couldn’t be asked, so PDFs weren’t searched.")
            }
            return parts.joined(separator: " ")
        }
    }

    static func textHeading(count: Int) -> String {
        "Text Files · \(count.formatted())"
    }

    /// The Spotlight group's heading, or `nil` when the group is not drawn — no files, and not
    /// still asking.
    static func documentHeading(_ hits: [EditorContentHit], phase: EditorContentSearchModel.SpotlightPhase) -> String? {
        if hits.isEmpty {
            return phase == .searching ? "PDFs · asking Spotlight…" : nil
        }
        let title = hits.allSatisfy { $0.kind == .pdf } ? "PDFs" : "PDFs and Office Files"
        return "\(title) · \(hits.count.formatted()) · from Spotlight"
    }

    static func moreLines(_ count: Int) -> String {
        count == 1 ? "1 more line in this file" : "\(count.formatted()) more lines in this file"
    }

    /// Where a result is, under the folder searched.
    static func relativePath(_ hit: EditorContentHit) -> String {
        hit.subfolder.isEmpty ? hit.name : hit.subfolder + "/" + hit.name
    }

    static func documentHelp(_ hit: EditorContentHit, query: String) -> String {
        let word = EditorContentSearch.needle(query) ?? query
        let what = "\(relativePath(hit)) contains “\(word)”, Spotlight says."
        if hit.isCloudOnly { return what + " Not downloaded." }
        return hit.kind == .pdf ? what + " Opens with Find holding the word." : what + " Opens in Quick Look."
    }

    /// The line with the match drawn in the accent's wash.
    static func snippet(_ line: EditorContentLine, accent: Color) -> AttributedString {
        var text = AttributedString(line.snippet)
        let ns = line.snippet as NSString
        guard line.highlight.location != NSNotFound, NSMaxRange(line.highlight) <= ns.length,
              let range = Range(line.highlight, in: line.snippet),
              let lit = Range(range, in: text) else { return text }
        text[lit].backgroundColor = accent.opacity(0.28)
        text[lit].foregroundColor = .primary
        return text
    }
}
