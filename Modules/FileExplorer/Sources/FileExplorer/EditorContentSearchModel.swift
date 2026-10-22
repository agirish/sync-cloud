import Foundation

/// **What the Files list's filter searches (RD38)**: file names — what it always did — or what is
/// inside the files.
///
/// **A switch in the filter, not a search box of its own** (decided 21 October). Header Find keeps
/// meaning "in this file"; a separate Search tab would have been a third search box in a column
/// already at its narrowest. No shortcut (decision BJ): ⇧⌘F is Fold All Differences, and ⌥⌘ chords
/// fire by accident while the ⌥ hints show.
public enum EditorRailFilterScope: String, CaseIterable, Sendable {
    case names
    case contents

    var title: String {
        switch self {
        case .names: return "Names"
        case .contents: return "Contents"
        }
    }

    /// The filter field's placeholder — what typing into it will do.
    var placeholder: String {
        switch self {
        case .names: return "Filter by name"
        case .contents: return "Search inside files"
        }
    }
}

/// **The Contents search's results and where they have got to** — the text scan
/// (``EditorContentSearch``) and the Spotlight query (``EditorContentSpotlight``), run together for
/// one folder and one query, and both stopped when either changes.
///
/// **Held by the window, not by the rail**, beside the filter's text: the rail is rebuilt by every
/// trip to another workspace, and the switch should still say Contents on the way back. Held, not
/// observed, there — only the rail's filter and results observe it, so a progress tick redraws
/// those and not the window.
@MainActor
public final class EditorContentSearchModel: ObservableObject {

    /// One question: this folder, this query (trimmed).
    struct Key: Equatable {
        var folder: String
        var query: String
    }

    enum TextPhase: Equatable {
        case idle
        case searching(EditorContentSearch.Progress)
        case finished(EditorContentSearch.Summary)
    }

    enum SpotlightPhase: Equatable {
        case idle
        case searching
        case finished
        /// The query could not be started — Spotlight off, or the index unreachable.
        case unavailable
    }

    @Published public var scope: EditorRailFilterScope = .names
    /// What the results on screen answer, or `nil` when nothing has been asked.
    @Published private(set) var key: Key?
    /// Text files that matched, in Finder's order folder by folder, whatever order they were read in.
    @Published private(set) var textHits: [EditorContentHit] = []
    /// PDFs, Word and PowerPoint files Spotlight says contain the word.
    @Published private(set) var documentHits: [EditorContentHit] = []
    @Published private(set) var textPhase: TextPhase = .idle
    @Published private(set) var spotlightPhase: SpotlightPhase = .idle

    /// The walk order of each of ``textHits``, side by side — what an arriving hit is placed by.
    private var orders: [Int] = []
    private var settling: Task<Void, Never>?
    private var scanning: Task<Void, Never>?
    private let spotlight = EditorContentSpotlight()

    /// The text half — a seam, so a test can count what is asked and hand back a stream it drives.
    var textSearch: (_ query: String, _ folder: String) -> AsyncStream<EditorContentSearch.Event> = {
        EditorContentSearch.search($0, in: $1)
    }
    /// Whether Spotlight is asked. Off in tests that hold the text half alone.
    var asksSpotlight = true
    /// Stands in for Spotlight when set — a test's answer, given at once or never.
    var spotlightSearch: ((_ query: String, _ folder: String,
                           _ answer: @escaping @MainActor ([EditorContentHit]?) -> Void) -> Void)?
    /// How long the typing must stop before a search starts — a word typed fast is one search.
    var typingSettle: Duration = .milliseconds(250)

    /// The fewest characters searched for. One letter is in nearly every file, and a search for it
    /// would be the folder listed again with a highlight in each line.
    nonisolated static let minimumQueryLength = 2

    public init() {}

    /// The trimmed query, when it is long enough to search for.
    nonisolated static func searchable(_ query: String) -> String? {
        guard let needle = EditorContentSearch.needle(query), needle.count >= minimumQueryLength else { return nil }
        return needle
    }

    /// The filter's text or folder moved: search again once the typing settles — or stop, when the
    /// switch is on Names, there is no folder, or there is nothing to search for yet.
    ///
    /// **The same question twice is answered once.** Coming back to Contents with the results of
    /// the same folder and query on screen keeps them; any difference starts over.
    func request(folder: String, query: String) {
        settling?.cancel()
        settling = nil
        guard scope == .contents, !folder.isEmpty, let needle = Self.searchable(query) else {
            cancel()
            return
        }
        let next = Key(folder: folder, query: needle)
        guard next != key else { return }
        let settle = typingSettle
        settling = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.run(next)
        }
    }

    /// Stops both halves and empties the results.
    func cancel() {
        settling?.cancel()
        settling = nil
        scanning?.cancel()
        scanning = nil
        spotlight.stop()
        key = nil
        textHits = []
        orders = []
        documentHits = []
        textPhase = .idle
        spotlightPhase = .idle
    }

    /// The question asked now, without the settle — for ↩ in the field, and for tests.
    func run(_ next: Key) {
        cancel()
        key = next
        textPhase = .searching(EditorContentSearch.Progress())
        let stream = textSearch(next.query, next.folder)
        scanning = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self, self.key == next else { return }
                self.take(event)
            }
        }
        guard asksSpotlight else { return }
        spotlightPhase = .searching
        let answer: @MainActor ([EditorContentHit]?) -> Void = { [weak self] hits in
            guard let self, self.key == next else { return }
            if let hits {
                self.documentHits = hits
                self.spotlightPhase = .finished
            } else {
                self.spotlightPhase = .unavailable
            }
        }
        if let spotlightSearch {
            spotlightSearch(next.query, next.folder, answer)
        } else {
            spotlight.start(next.query, in: next.folder, answer: answer)
        }
    }

    private func take(_ event: EditorContentSearch.Event) {
        switch event {
        case .hit(let hit, let order):
            let index = orders.firstIndex(where: { $0 > order }) ?? orders.count
            orders.insert(order, at: index)
            textHits.insert(hit, at: index)
        case .progress(let progress):
            textPhase = .searching(progress)
        case .finished(let summary):
            textPhase = .finished(summary)
        }
    }

    /// What ↩ in the field opens: the first text file at its first line, or else the first PDF.
    var firstResult: (hit: EditorContentHit, line: EditorContentLine?)? {
        if let hit = textHits.first { return (hit, hit.lines.first) }
        if let hit = documentHits.first { return (hit, nil) }
        return nil
    }
}
