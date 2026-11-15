import AppKit
import SwiftUI
import Sync
import Design

// MARK: - The row's actions

/// What a file row's ⋯ and context menu offer, in their order, with Finder's shortcuts.
enum FilingFileAction: String, CaseIterable, Identifiable {
    case quickLook, open, reveal, openFolder, openDestinationFolder, copyPath, copyDestinationPath,
         pullOut, chooseFolder, setAside, trash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickLook: return "Quick Look"
        case .open: return "Open"
        case .reveal: return "Reveal in Finder"
        case .openFolder: return "Open Folder"
        case .openDestinationFolder: return "Open Destination Folder"
        case .copyPath: return "Copy Path"
        case .copyDestinationPath: return "Copy Destination Path"
        case .pullOut: return "Pull Out of This Card"
        case .chooseFolder: return "Choose a Folder for This File…"
        case .setAside: return "Set Aside"
        case .trash: return "Move to Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .quickLook: return "eye"
        case .open: return "arrow.up.forward.app"
        case .reveal: return RevealGlyph.inFinder
        case .openFolder: return "folder"
        case .openDestinationFolder: return "folder.badge.questionmark"
        case .copyPath: return "doc.on.clipboard"
        case .copyDestinationPath: return "arrow.turn.down.right"
        case .pullOut: return "rectangle.portrait.and.arrow.right"
        case .chooseFolder: return "folder"
        case .setAside: return "xmark"
        case .trash: return "trash"
        }
    }

    /// The menu's sections. Pull Out only where there is a card to pull out of; the destination's
    /// two only where there is a destination.
    static func sections(inGroup: Bool, hasDestination: Bool) -> [[FilingFileAction]] {
        [hasDestination ? [.quickLook, .open, .reveal, .openFolder, .openDestinationFolder]
                        : [.quickLook, .open, .reveal, .openFolder],
         hasDestination ? [.copyPath, .copyDestinationPath] : [.copyPath],
         inGroup ? [.pullOut, .chooseFolder, .setAside] : [.chooseFolder, .setAside],
         [.trash]]
    }

    /// The action the selected row's key press asks for, or nil: Finder's Space and ⌘Y for Quick
    /// Look, and ⌥⌘C for Copy Path. Not ⌘O, ⌘R or ⌘⌫: the menu bar holds those for the panes
    /// (Open in Edit, Rescan, Move Selection to Trash), and its key equivalents answer before a
    /// view's key press, so a row claiming them would never see them.
    static func forKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> FilingFileAction? {
        let mods = modifiers.intersection([.command, .option, .shift, .control])
        switch (key, mods) {
        case (.space, []), ("y", .command): return .quickLook
        case ("c", [.command, .option]): return .copyPath
        default: return nil
        }
    }
}

/// The words and paths a row's actions use, apart from the views so they can be tested.
enum FilingFileText {
    /// Where the file lands, in full: its home and the name it takes. nil with no home.
    static func destinationPath(_ s: FilingSuggestion) -> String? {
        guard let best = s.best else { return nil }
        return (best.path as NSString).appendingPathComponent(best.proposedName ?? s.fileName)
    }

    /// One line read from page 1: "Statement · Jan 29, 2026", "Tax form · 2025", or the page's first
    /// words. Only what To File read: no amounts, no summaries.
    static func pageLine(_ facts: DocumentFacts?) -> String? {
        guard let facts else { return nil }
        switch facts.kind {
        case .statement:
            return "Statement" + (facts.period.map { " · " + date($0) } ?? "")
        case .taxForm:
            return "Tax form" + (facts.period.map { " · \($0.year)" } ?? "")
        case .other:
            return facts.firstLine.map { "Page 1 begins “\($0)”" }
        }
    }

    /// "Jan 29, 2026", or "Jan 2026" when page 1 gives only the month.
    static func date(_ p: DocumentFacts.Period) -> String {
        let m = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard (1...12).contains(p.month) else { return "\(p.year)" }
        return p.day.map { "\(m[p.month - 1]) \($0), \(p.year)" } ?? "\(m[p.month - 1]) \(p.year)"
    }

    /// What the row's right column says: the name it lands under (its own, restated, when it keeps
    /// it), or, in quiet italics, why it doesn't move. nil with no confident home: the row ends at
    /// the file, and the section heading already says it needs a folder chosen.
    static func landing(_ s: FilingSuggestion) -> (text: String, moves: Bool)? {
        if s.isAlreadyFiled { return ("already filed", false) }
        if s.duplicateOf != nil { return ("a copy of another file here", false) }
        guard let best = s.best, s.hasConfidentHome else { return nil }
        return (best.proposedName ?? s.fileName, true)
    }

    /// The row's two lines. In a group, the file's name over what page 1 says; on a card of its
    /// own, whose title is the name already, what page 1 says over its size.
    static func lines(_ s: FilingSuggestion, facts: DocumentFacts?, inGroup: Bool) -> (primary: String, secondary: String) {
        let size = FileSyncManager.formatBytes(s.size)
        if inGroup { return (s.fileName, pageLine(facts) ?? size) }
        return (pageLine(facts) ?? s.fileName, size)
    }
}

// MARK: - The rows

/// What a card hands its rows: the page facts it shows, and what each action does.
struct FilingFileRowsHooks {
    var facts: (FilingSuggestion) -> DocumentFacts? = { _ in nil }
    /// Runs a menu action or the selected row's shortcut.
    var perform: (FilingFileAction, FilingSuggestion) -> Void = { _, _ in }
    /// Whether the action is offered for this file now.
    var isEnabled: (FilingFileAction, FilingSuggestion) -> Bool = { _, _ in true }
    /// Opens a folder in Finder: a group card's Open Folder with no row selected.
    var openFolder: (String) -> Void = { NSWorkspace.shared.open(URL(fileURLWithPath: $0, isDirectory: true)) }
}

/// A card's files as rows that share their columns: page-1 thumbnail, the file and one line read
/// from it, the arrow and the name it takes, and, in a group, ⋯ on the hovered or selected row.
/// Narrow, the new name moves under the file's own. Clicking a row selects it; the card's action
/// line then acts on that file.
struct FilingFileRows: View {
    let members: [FilingSuggestion]
    let inGroup: Bool
    let narrow: Bool
    let accent: Color
    let hooks: FilingFileRowsHooks

    /// The selected row, held by the card: its action line acts on that file.
    @Binding var selected: String?
    @State private var hovered: String?
    @State private var peeking: String?
    @FocusState private var focused: Bool

    /// Fixed columns: the thumbnail, the arrow and the actions. The file and its new name share
    /// what is left evenly, so arrows and names line up from row to row.
    static let thumb = CGSize(width: 30, height: 39)
    static let gap: CGFloat = 10
    static let arrow: CGFloat = 14
    static let acts: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(members) { s in row(s) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in
            if press.key == .downArrow || press.key == .upArrow {
                move(press.key == .downArrow ? 1 : -1)
                return .handled
            }
            guard let action = FilingFileAction.forKey(press.key, modifiers: press.modifiers),
                  let s = selectedMember, hooks.isEnabled(action, s) else { return .ignored }
            hooks.perform(action, s)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(inGroup ? "\(members.count) files" : "The file")
    }

    /// The row keys act on: only one drawn as selected, never a stand-in.
    private var selectedMember: FilingSuggestion? {
        members.first { $0.id == selected }
    }

    private func move(_ step: Int) {
        guard !members.isEmpty else { return }
        let i = members.firstIndex { $0.id == selected } ?? (step > 0 ? -1 : members.count)
        selected = members[min(max(i + step, 0), members.count - 1)].id
    }

    private func row(_ s: FilingSuggestion) -> some View {
        let isSelected = selected == s.id && focused
        // A group's rows keep their own ⋯ for one file of many; a single file's card has its
        // actions on the card's own line.
        let showsActs = inGroup && (selected == s.id || hovered == s.id)
        let lines = FilingFileText.lines(s, facts: hooks.facts(s), inGroup: inGroup)
        let landing = FilingFileText.landing(s)
        let ownFrom = inGroup ? FilingRouteText.rowFrom(s, members: members) : nil
        return HStack(alignment: .center, spacing: Self.gap) {
            thumbnail(s)
            VStack(alignment: .leading, spacing: 1) {
                Text(lines.primary)
                    .scaledFont(.system(size: 12.5))
                    .lineLimit(1).truncationMode(.middle)
                Text(ownFrom.map { "from \($0) · " + lines.secondary } ?? lines.secondary)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                if narrow, let landing { landingText(landing, prefix: "→ ") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !narrow, let landing {
                Text("→").scaledFont(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(width: Self.arrow)
                    .accessibilityHidden(true)
                landingText(landing, prefix: "")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if inGroup { acts(s).frame(width: Self.acts, alignment: .trailing).opacity(showsActs ? 1 : 0) }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(selected == s.id ? accent.opacity(focused ? 0.16 : 0.09) : .clear))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(isSelected ? accent : .clear, lineWidth: 1.5))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture { selected = s.id; focused = true }
        .onHover { hovered = $0 ? s.id : (hovered == s.id ? nil : hovered) }
        .contextMenu { menuItems(s) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lines.primary + (landing.map { ", " + ($0.moves ? "files as " : "") + $0.text } ?? ""))
        .accessibilityAddTraits(selected == s.id ? .isSelected : [])
        // The combined row hides its buttons from VoiceOver, so each is a named action instead.
        .accessibilityActions {
            Button("Show Page 1") { peeking = s.id }
            ForEach(FilingFileAction.sections(inGroup: inGroup, hasDestination: s.best != nil).joined()
                .filter { hooks.isEnabled($0, s) }) { action in
                Button(action.title) { hooks.perform(action, s) }
            }
        }
    }

    private func landingText(_ landing: (text: String, moves: Bool), prefix: String) -> some View {
        Text(prefix + landing.text)
            .scaledFont(.system(size: 11.5, design: landing.moves ? .monospaced : .default))
            .italic(!landing.moves)
            .foregroundStyle(landing.moves ? Color.primary : Color.secondary)
            .lineLimit(1).truncationMode(.middle)
    }

    /// Page 1, made only for rows on screen; a click opens the app's own page-1 view.
    private func thumbnail(_ s: FilingSuggestion) -> some View {
        Button { peeking = s.id } label: {
            FilingPageThumbnail(path: s.filePath, name: s.fileName, modified: s.modificationDate, size: Self.thumb)
        }
        .buttonStyle(.plain)
        .help("Page 1, with what To File read marked")
        .accessibilityLabel("Show page 1 of \(s.fileName)")
        .popover(isPresented: Binding(get: { peeking == s.id }, set: { if !$0 { peeking = nil } }), arrowEdge: .leading) {
            FilingPagePeek(members: members, start: s.id, facts: hooks.facts)
                .presentedNativeControlAccent()
        }
    }

    @ViewBuilder
    private func acts(_ s: FilingSuggestion) -> some View {
        HStack(spacing: 4) {
            Menu { menuItems(s) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions for \(s.fileName)")
        }
        .scaledFont(.system(size: 12))
    }

    /// The menu's items, the same in ⋯ and the context menu. No key equivalents on them: in this
    /// always-mounted list they would be window-wide (`BareKeyEquivalentScanTests`); the selected
    /// row answers its keys itself (``FilingFileAction/forKey(_:modifiers:)``).
    @ViewBuilder
    private func menuItems(_ s: FilingSuggestion) -> some View {
        let sections = FilingFileAction.sections(inGroup: inGroup, hasDestination: s.best != nil)
        ForEach(Array(sections.enumerated()), id: \.offset) { i, section in
            if i > 0 { Divider() }
            ForEach(section) { action in
                Button(role: action == .trash ? .destructive : nil) { hooks.perform(action, s) } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(!hooks.isEnabled(action, s))
            }
        }
    }
}

/// Page 1 of a file, small: QuickLook's thumbnail, or the file's icon while it renders or when it
/// can't.
struct FilingPageThumbnail: View {
    let path: String
    let name: String
    let modified: Date?
    let size: CGSize
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: FileIconCache.icon(name: name, isDirectory: false)).resizable().aspectRatio(contentMode: .fit)
                    .padding(4)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: path) {
            image = DuplicateThumbnail.cached(path: path, side: size.height, scale: displayScale, modified: modified,
                                              in: DuplicateThumbnail.imageCache)
            if image == nil {
                image = await DuplicateThumbnail.image(path: path, side: size.height, scale: displayScale,
                                                       modified: modified, in: DuplicateThumbnail.imageCache)
            }
        }
    }
}

// MARK: - Running an action

/// What each row action does, with the system's parts (Quick Look, the workspace, the pasteboard)
/// passed in so a test can see each one asked for exactly what it should.
struct FilingFileActionRunner {
    /// Quick Look over the card's files, starting at this one.
    var quickLook: ([URL], URL) -> Void
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    var pasteboard: NSPasteboard = .general
    var pullOut: (FilingSuggestion) -> Void
    var chooseFolder: (FilingSuggestion) -> Void
    var setAside: (FilingSuggestion) -> Void
    /// To the Trash, never deleted, with ⌘Z.
    var trash: (FilingSuggestion) -> Void

    func perform(_ action: FilingFileAction, on s: FilingSuggestion, members: [FilingSuggestion]) {
        let url = URL(fileURLWithPath: s.filePath)
        switch action {
        case .quickLook:
            let urls = members.map { URL(fileURLWithPath: $0.filePath) }
            quickLook(urls.contains(url) ? urls : [url], url)
        case .open: open(url)
        case .reveal: reveal(url)
        case .openFolder: open(url.deletingLastPathComponent())
        case .openDestinationFolder: if let best = s.best { open(URL(fileURLWithPath: best.path, isDirectory: true)) }
        case .copyPath: copy(s.filePath)
        case .copyDestinationPath: if let path = FilingFileText.destinationPath(s) { copy(path) }
        case .pullOut: pullOut(s)
        case .chooseFolder: chooseFolder(s)
        case .setAside: setAside(s)
        case .trash: trash(s)
        }
    }

    private func copy(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
