import SwiftUI
import Design

/// Where the open document lives, as the Edit header says it.
///
/// The host builds it from the pane's breadcrumb model: the source's display name first, then the
/// folders below its root, each with the pane-relative path its crumb would go to. This module
/// can't see `BreadcrumbTrail` and must not re-derive a provider's name, so it only draws.
/// Two styles, chosen by whether the source pane is open (``Style``). With no document open it
/// names the pane's folder, where a new file would be made, its own level as words, not a door.
public struct EditorDocumentLocation: Equatable, Sendable {

    /// One level of the path.
    public struct Segment: Equatable, Sendable {
        /// What the pane's breadcrumb calls this level.
        public let name: String
        /// The pane-relative path a click sends the left pane to (`""` for the source's top), or
        /// `nil` where the pane can't go: a level outside its source, named but not a door.
        public let target: String?

        public init(name: String, target: String?) {
            self.name = name
            self.target = target
        }
    }

    /// Which of the two readings the header draws.
    public enum Style: Equatable, Sendable {
        /// `in Finance`, the folder's name alone, while the source pane is open: the pane shows its
        /// own full breadcrumb, and a click makes the pane go to the folder and select the file.
        case folderName
        /// `iCloud › Documents › Finance`, each level a door, while the pane is collapsed: nothing
        /// else says where the file is, and a click re-points the pane without opening it.
        case crumb

        /// Decided by the pane's state alone. The folder sidebar only exists beside an open pane
        /// (`FolderSidebarModel.appliesTo`), so the pane's state is the one bit that decides it.
        public static func forPane(isOpen: Bool) -> Style { isOpen ? .folderName : .crumb }
    }

    /// Source first, the document's folder last. Never empty for a document the host could place.
    public let segments: [Segment]
    public let style: Style
    /// The tooltip: the path as the pane's breadcrumb spells it (`iCloud › Documents › Finance`),
    /// or, for a folder outside the pane's source, its `~`-abbreviated path.
    public let help: String

    /// The user's other source that a folder outside the pane's lies in, such as the Dropbox copy
    /// opened while the pane shows iCloud. The segments start from its name, as words, and the
    /// folder-name reading says it too ("in Dropbox › Backup"), since "in Backup" doesn't say
    /// which cloud. `nil` for a folder in the pane's own source or in no source.
    public let otherSourceName: String?

    public init(segments: [Segment], style: Style, help: String, otherSourceName: String? = nil) {
        self.segments = segments
        self.style = style
        self.help = help
        self.otherSourceName = otherSourceName
    }

    /// Between two crumbs in a tooltip. The drawn crumb uses the pane's chevron glyph instead.
    public static let separator = " › "

    /// The segments joined the way the pane's breadcrumb reads, as a tooltip names a place.
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
        /// A word that is not: a level the pane can't reach, or a folded middle none of whose
        /// levels it can.
        case text(String, help: String)
        /// The folded middle of a long crumb, "…", as a menu of every level of the path: the
        /// document's folder first and ticked, climbing to the source, like Finder's path menu and
        /// the Files list's folder menu. Each is a door where the pane can go.
        case folded([Segment], help: String)
        /// The glyph between two levels, the pane breadcrumb's own.
        case chevron
    }

    /// The pieces of one rung of the location, left to right. Pure and non-private so which word
    /// opens which door is testable without a click, which a `swift test` host can't synthesize
    /// (`docs/flaky-tests.md`, "When you fix one").
    ///
    /// - Parameter rung: the segment indexes to draw, `nil` for the folded middle: one of
    ///   ``rungs(segmentCount:)``. Ignored by `.folderName`, which has one reading only.
    func parts(rung: [Int?]) -> [Part] {
        switch style {
        case .folderName:
            guard let folder = segments.last else { return [] }
            // Another source's name before the folder, unless the folder IS that source's top.
            let title = otherSourceName.map { segments.count > 1 ? "in \($0)\(Self.separator)\(folder.name)" : "in \($0)" }
                ?? "in \(folder.name)"
            return folder.target == nil
                ? [.text(title, help: help)]
                : [.control(title: title, door: .showInPane, help: help)]
        case .crumb:
            var parts: [Part] = []
            for (position, index) in rung.enumerated() {
                if position > 0 { parts.append(.chevron) }
                guard let index, segments.indices.contains(index) else {
                    // The folded middle's tooltip is the whole path, and its menu lists the whole
                    // path deepest first, so every level stays one click away. Words alone when no
                    // folded level is a door: a menu that reaches nothing it hides adds nothing.
                    let before = rung[..<position].compactMap { $0 }.max() ?? -1
                    let after = rung[(position + 1)...].compactMap { $0 }.min() ?? segments.count
                    let folded = segments.indices.filter { $0 > before && $0 < after }.map { segments[$0] }
                    parts.append(folded.contains { $0.target != nil }
                                 ? .folded(segments.reversed(), help: help)
                                 : .text("…", help: help))
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

    /// The crumb's rungs, widest first, as `ViewThatFits` tries them.
    ///
    /// A long path keeps the source (which cloud) and the folder (which folder) and folds the
    /// middle into `…`, from just under the source first, so levels nearest the folder last
    /// longest. The last rung is the folder alone, which may truncate: a wrapped row would push the
    /// header taller than the toolbar card it is pinned to. Static and non-private for testing.
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
/// Nothing painted at rest, like the status word beside it: each door wears the app's hover
/// affordance, so the wash and pointing cursor appear only on hover. The wash's room is horizontal
/// padding cancelled by equal negative padding outside, the pane breadcrumb's recipe, so the row's
/// layout doesn't move by a point; the header's height depends on it.
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
            // Widest first. Only the last rung, the folder alone, may truncate: `ViewThatFits` falls
            // back to it when nothing fits and proposes it the width there is.
            ViewThatFits(in: .horizontal) {
                ForEach(Array(rungs.enumerated()), id: \.offset) { index, rung in
                    row(location.parts(rung: rung), compressible: index == rungs.count - 1)
                }
            }
        }
    }

    /// One rung, laid out. Internal so a test can draw a chosen rung rather than whichever one
    /// `ViewThatFits` picks at the width it was given.
    @ViewBuilder
    func row(_ parts: [EditorDocumentLocation.Part], compressible: Bool) -> some View {
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
        case .folded(let levels, let help):
            // A `Menu` in the button style draws the button style's label, so the "…" keeps the
            // row's text and hover wash; AppKit's pop-up chrome would grow the pinned header.
            // The items match `EditorRailFolderMenu`: the document's folder first and ticked, then
            // up to the source, each with a folder glyph.
            Menu {
                ForEach(Array(Self.foldedItems(levels).enumerated()), id: \.offset) { _, item in
                    if item.isTicked {
                        // Ticked, and still a door: the pane need not be showing the document's
                        // folder.
                        Toggle(isOn: Binding(get: { true },
                                             set: { _ in if let door = item.door { onDoor(door) } })) {
                            Label(item.name, systemImage: "folder")
                        }
                        .disabled(item.door == nil)
                    } else {
                        Button {
                            if let door = item.door { onDoor(door) }
                        } label: {
                            Label(item.name, systemImage: "folder")
                        }
                        .disabled(item.door == nil)
                    }
                }
            } label: {
                label("…", compressible: compressible)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.hoverAffordance(.segment, tint: accent))
            .menuIndicator(.hidden)
            .padding(.horizontal, -4)
            .help(help)
            .accessibilityLabel("Collapsed folders")
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

    /// One item of the folded middle's menu.
    struct FoldedItem: Equatable {
        let name: String
        /// The document's folder: the first item, and the only ticked one.
        let isTicked: Bool
        /// Where a pick sends the pane, or `nil` for a level it can't reach, drawn greyed.
        let door: EditorDocumentLocation.Door?
    }

    /// The folded middle's menu in drawn order, from ``EditorDocumentLocation/Part/folded(_:help:)``'s
    /// levels, deepest first. A function so the tick and the doors are testable.
    static func foldedItems(_ levels: [EditorDocumentLocation.Segment]) -> [FoldedItem] {
        levels.enumerated().map { index, level in
            FoldedItem(name: level.name, isTicked: index == 0, door: level.target.map { .goTo($0) })
        }
    }

    /// One word of the path. `fixedSize` on every rung but the last, so a rung fits whole or is
    /// passed over; levels truncating one by one would read `iC… › Do… › Fi…`.
    @ViewBuilder
    private func label(_ words: String, compressible: Bool) -> some View {
        let text = Text(words).lineLimit(1).truncationMode(.middle)
        if compressible { text } else { text.fixedSize() }
    }

    /// What activating a door does, for VoiceOver: the words on screen say where, not what.
    static func accessibilityLabel(title: String, door: EditorDocumentLocation.Door) -> String {
        switch door {
        case .showInPane: return "Show this file \(title) in the file pane"
        case .goTo: return "Go to \(title) in the file pane"
        }
    }
}
