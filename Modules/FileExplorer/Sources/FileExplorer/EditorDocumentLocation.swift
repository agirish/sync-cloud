import SwiftUI
import Design

/// Where the open document lives, as the Edit header says it — the answer to "where is this file?"
/// that the header used to leave to the file name's context menu (TE43).
///
/// **The host builds it, and builds it from the pane's own breadcrumb model.** The segments are the
/// names the left pane's breadcrumb would draw for the document's folder — the source's display
/// name first ("iCloud", "OneDrive (EMP)", whatever it was renamed to), then the folders below the
/// source's root — and each carries the pane-relative path a click on that crumb would navigate to.
/// This module cannot see `BreadcrumbTrail`, which lives above it, and must not re-derive a
/// provider's name on its own; so the value arrives finished and this side only draws it.
///
/// **Two styles, chosen by whether the source pane is open** — see ``Style``.
///
/// **With no document open it names the pane's folder instead** — the folder a new file would be
/// made in, which is what the empty page's header says. The host builds that value with the
/// folder's own level as words rather than a door (the pane is already there), so nothing here has
/// to know which of the two it is drawing.
public struct EditorDocumentLocation: Equatable, Sendable {

    /// One level of the path.
    public struct Segment: Equatable, Sendable {
        /// What the pane's breadcrumb calls this level.
        public let name: String
        /// The pane-relative path a click sends the LEFT pane to — `""` for the top of the source —
        /// or `nil` where the pane cannot go there: a document outside the pane's source, which
        /// the header still names but does not offer as a door.
        public let target: String?

        public init(name: String, target: String?) {
            self.name = name
            self.target = target
        }
    }

    /// Which of the two readings the header draws.
    public enum Style: Equatable, Sendable {
        /// `in Finance` — the folder's name alone. Offered while the source pane is open: the pane
        /// is on screen with its own full breadcrumb, so the header needs only to say which folder,
        /// and a click is "show me the file there" — the pane goes to the folder and selects it.
        case folderName
        /// `iCloud › Documents › Finance` — the whole path, each level a door. Offered while the pane
        /// is collapsed (the rail is showing, or "Just the text" is on): nothing else on screen says
        /// where the file is, and a click re-points the collapsed pane without opening it.
        case crumb

        /// **The one rule: the pane's state, and nothing else.** The folder sidebar only exists
        /// beside an open pane (`FolderSidebarModel.appliesTo`), so "the sidebar and the pane are
        /// open" and "the pane is open" are the same question — asking the second is asking the
        /// one bit that decides it.
        public static func forPane(isOpen: Bool) -> Style { isOpen ? .folderName : .crumb }
    }

    /// Source first, the document's folder last. Never empty for a document the host could place.
    public let segments: [Segment]
    public let style: Style
    /// The tooltip: the path as the pane's breadcrumb spells it (`iCloud › Documents › Finance`),
    /// or — for a folder outside the pane's source, which has no crumbs — its `~`-abbreviated path.
    public let help: String

    public init(segments: [Segment], style: Style, help: String) {
        self.segments = segments
        self.style = style
        self.help = help
    }

    /// Between two crumbs in a tooltip. The drawn crumb uses the pane's chevron glyph instead.
    public static let separator = " › "

    /// The segments joined the way the pane's breadcrumb reads — what a tooltip calls a place.
    static func spelled(_ segments: ArraySlice<Segment>) -> String {
        segments.map(\.name).joined(separator: separator)
    }

    // MARK: - What a click does

    /// What activating a part of the location does. The view draws these and hands them back; the
    /// host decides what each means for the pane.
    public enum Door: Equatable, Sendable {
        /// The pane goes to the document's folder and selects the document there.
        case showInPane
        /// The collapsed pane goes to this pane-relative path, and stays collapsed.
        case goTo(String)
    }

    /// One drawn piece of the location.
    enum Part: Equatable {
        /// A word that is a door, with its tooltip.
        case control(title: String, door: Door, help: String)
        /// A word that is not — a level the pane cannot reach, or the folded middle of a long path.
        case text(String, help: String)
        /// The glyph between two levels, the pane breadcrumb's own.
        case chevron
    }

    /// The pieces of one rung of the location, left to right.
    ///
    /// **Pure and non-private so the doors are testable without a click**, which a `swift test`
    /// host cannot synthesize (see `PaneBackgroundDeselectMountedTests.testSyntheticClicksCannotDriveThisHarness`).
    /// Which word opens which door is the whole behaviour of this control; the view only lays these
    /// out and routes a press to the door it was handed.
    ///
    /// - Parameter rung: the segment indexes to draw, `nil` for the folded middle — one of
    ///   ``rungs(segmentCount:)``. Ignored by `.folderName`, which has one reading only.
    func parts(rung: [Int?]) -> [Part] {
        switch style {
        case .folderName:
            guard let folder = segments.last else { return [] }
            let title = "in \(folder.name)"
            return folder.target == nil
                ? [.text(title, help: help)]
                : [.control(title: title, door: .showInPane, help: help)]
        case .crumb:
            var parts: [Part] = []
            for (position, index) in rung.enumerated() {
                if position > 0 { parts.append(.chevron) }
                guard let index, segments.indices.contains(index) else {
                    // The folded middle says what it folds, in the tooltip — the whole path.
                    parts.append(.text("…", help: help))
                    continue
                }
                let segment = segments[index]
                let place = Self.spelled(segments[...index])
                if let target = segment.target {
                    parts.append(.control(title: segment.name, door: .goTo(target),
                                          help: "Go to \(place)"))
                } else {
                    parts.append(.text(segment.name, help: help))
                }
            }
            return parts
        }
    }

    // MARK: - Fitting a long path

    /// The crumb's rungs, widest first — what `ViewThatFits` tries in order.
    ///
    /// **Middle levels go first; the source and the folder stay.** The source says which cloud this
    /// is and the folder says which folder, and those are the two words a reader is looking for —
    /// so a long path keeps both and folds what lies between into `…`, taking levels from just
    /// under the source first, so the ones nearest the folder survive longest. The last rung is the
    /// folder on its own, which the view lets truncate: at that point the row is out of room for
    /// anything else, and a truncated folder name is still a name where a wrapped row would push
    /// the header taller than the pane's toolbar card it is pinned to.
    ///
    /// Static and non-private for the reason ``parts(rung:)`` is.
    static func rungs(segmentCount n: Int) -> [[Int?]] {
        guard n > 0 else { return [] }
        guard n > 1 else { return [[0]] }
        var rungs: [[Int?]] = [Array(0..<n)]
        // Keep the source and the last `keep` levels; one fewer each rung.
        var keep = n - 2
        while keep >= 1 {
            rungs.append([0, nil] + Array((n - keep)..<n))
            keep -= 1
        }
        rungs.append([n - 1])
        return rungs
    }
}

/// The location, drawn on the header's meta row.
///
/// **Nothing painted at rest, like the status word beside it.** Each door goes through the app's
/// one hover-affordance choke point — no chrome until the pointer is over it, then the wash and the
/// pointing cursor — so a row that reads as a quiet line of text is also, on hover, plainly a set of
/// places to go. The wash's room is horizontal padding cancelled by an equal negative padding
/// outside, the pane breadcrumb's own recipe: the wash gets room round the letters and the row's
/// layout does not move by a point, which matters on a row whose height the header's own height
/// depends on.
struct EditorLocationLabel: View {
    let location: EditorDocumentLocation
    let accent: Color
    let onDoor: (EditorDocumentLocation.Door) -> Void

    var body: some View {
        switch location.style {
        case .folderName:
            row(location.parts(rung: []), compressible: true)
        case .crumb:
            let rungs = EditorDocumentLocation.rungs(segmentCount: location.segments.count)
            // Widest first; the last rung is the folder alone and the only one allowed to truncate,
            // because `ViewThatFits` falls back to it when nothing fits and proposes it the width
            // there actually is.
            ViewThatFits(in: .horizontal) {
                ForEach(Array(rungs.enumerated()), id: \.offset) { index, rung in
                    row(location.parts(rung: rung), compressible: index == rungs.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ parts: [EditorDocumentLocation.Part], compressible: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                piece(part, compressible: compressible)
            }
        }
    }

    @ViewBuilder
    private func piece(_ part: EditorDocumentLocation.Part, compressible: Bool) -> some View {
        switch part {
        case .chevron:
            // The pane breadcrumb's separator, so the two trails read as one vocabulary.
            Image(systemName: "chevron.compact.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        case .text(let words, let help):
            label(words, compressible: compressible)
                .help(help)
        case .control(let title, let door, let help):
            Button { onDoor(door) } label: {
                label(title, compressible: compressible)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            .padding(.horizontal, -4)
            .help(help)
            .accessibilityLabel(Self.accessibilityLabel(title: title, door: door))
        }
    }

    /// One word of the path. `fixedSize` on every rung but the last, so a rung either fits whole or
    /// is passed over — a crumb whose levels truncated one by one would read `iC… › Do… › Fi…`.
    @ViewBuilder
    private func label(_ words: String, compressible: Bool) -> some View {
        let text = Text(words).lineLimit(1).truncationMode(.middle)
        if compressible { text } else { text.fixedSize() }
    }

    /// What activating a door does, for VoiceOver — the words on screen say where, not what.
    static func accessibilityLabel(title: String, door: EditorDocumentLocation.Door) -> String {
        switch door {
        case .showInPane: return "Show this file \(title) in the file pane"
        case .goTo: return "Go to \(title) in the file pane"
        }
    }
}
