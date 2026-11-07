import AppKit
import SwiftUI
import PDFToolkitCore
import Design
import Sync

/// The header's Tools menu, last of the file actions before the divider, for a PDF that is open or
/// locked. Every item writes a new copy next to the original; the open file stays read-only.
///
/// It also presents the tools' sheets, whichever surface asked (the Pages tab's menu sets
/// ``EditorPDFTools/sheet`` too). It is mounted whenever a sheet can be asked for, and in the other
/// phases ``EditorPDFTools/detach()`` has cleared any sheet, so none is left without a presenter.
///
/// It wears the file actions' bezel (``EditorPDFActionStyle``), a wrench and a chevron, through
/// `.menuStyle(.button)`, so it washes and tints like Find and Fill & Sign; a borderless menu's
/// AppKit pop-up chrome would grow the row past the height the header pins.
struct EditorPDFToolsMenu: View {
    @ObservedObject var tools: EditorPDFTools
    let accent: Color
    let accentFill: Color
    let onAccent: Color
    /// "Tools" beside the wrench, while the header's rung keeps the word.
    var worded = true

    var body: some View {
        Menu {
            EditorPDFToolsMenuItems(tools: tools)
        } label: {
            EditorPDFActionLabel(symbol: "wrench.and.screwdriver", word: worded ? "Tools" : nil, chevron: true,
                                 accentFill: accentFill, onAccent: onAccent)
        }
        .menuStyle(.button)
        .modifier(EditorPDFActionStyle(accent: accent))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("PDF tools — each writes a new copy and leaves this file as it is")
        .accessibilityLabel("PDF Tools")
        .accessibilityInputLabels(EditorSpokenNames.names(word: "Tools", label: "PDF Tools"))
        .sheet(item: $tools.sheet) { sheet in
            EditorPDFToolSheetView(tools: tools, sheet: sheet).presentedNativeControlAccent()
        }
    }
}

/// One line of the Tools menu as data (what it says, whether it can be chosen, what it does), so a
/// test can read the menu without opening it: a hosted `Menu`'s body never runs offscreen.
public struct EditorPDFToolsMenuEntry: Equatable {
    public enum Action: Equatable {
        case run(EditorPDFTool)
        case sheet(EditorPDFToolSheet)
        /// The Pages tab's dragged order, written as a copy: the reorder bar's Save Reordered Copy.
        case saveArrangement
        /// The dragged order put back: the reorder bar's Reset.
        case resetArrangement
        /// A line that only explains why the others are greyed out.
        case none
    }
    public var title: String
    public var enabled: Bool
    public var action: Action
    /// The submenu this line sits in, or `nil` at the top.
    public var submenu: String?
    /// A divider before this line.
    public var dividerBefore = false

    public init(title: String, enabled: Bool, action: Action, submenu: String? = nil, dividerBefore: Bool = false) {
        self.title = title
        self.enabled = enabled
        self.action = action
        self.submenu = submenu
        self.dividerBefore = dividerBefore
    }

    /// The header menu, for the file the tools are attached to. With a selection, its rotate lines
    /// come first and Extract and Delete are filled in with it, as the Pages tab's menu does. File ▸
    /// PDF Tools is drawn from this list too, so the two can't disagree; that is why a pending
    /// reorder's two actions are here, last, while the reorder bar shows them.
    @MainActor
    public static func entries(_ tools: EditorPDFTools) -> [EditorPDFToolsMenuEntry] {
        // A sheet that is up counts as busy, Add Signature's included: the menu bar's copy of this
        // list stays live over a window-modal sheet, and a tool chosen there would run under it or
        // put a second sheet over it.
        let idle = tools.running == nil && tools.sheet == nil && tools.fill?.addingSignature == nil
        let pages = tools.offersPageTools && idle
        let selected = tools.order.filter(tools.selection.pages.contains)
        var out: [EditorPDFToolsMenuEntry] = []
        if let reason = tools.disabledReason {
            out.append(.init(title: reason, enabled: false, action: .none))
        }
        func rotations(_ target: [Int], in submenu: String) {
            for (title, turns) in [("Rotate Left", -1), ("Rotate Right", 1), ("Rotate 180°", 2)] {
                out.append(.init(title: title, enabled: pages,
                                 action: .run(.rotate(pages: target, quarterTurns: turns)), submenu: submenu))
            }
        }
        if !selected.isEmpty {
            rotations(selected, in: selected.count == 1 ? "Rotate Page \(selected[0] + 1)"
                                                       : "Rotate \(selected.count) Selected Pages")
        }
        rotations(Array(0..<tools.pageCount), in: "Rotate All Pages")
        let prefill = EditorPDFPageMenu.rangeText(selected)
        // Named for the selection as the rotate submenu and the Pages tab's menu are
        // (`EditorPDFPageMenu.title`); with none, the sheet asks which pages.
        func pagesTitle(_ verb: String) -> String {
            switch selected.count {
            case 0: return "\(verb) Pages…"
            case 1: return "\(verb) Page \(selected[0] + 1)…"
            default: return "\(verb) \(selected.count) Selected Pages…"
            }
        }
        out.append(.init(title: pagesTitle("Extract"), enabled: pages, action: .sheet(.pages(.extract, prefill: prefill)),
                         dividerBefore: true))
        out.append(.init(title: pagesTitle("Delete"), enabled: pages && tools.mayDelete(selected),
                         action: .sheet(.pages(.delete, prefill: prefill))))
        out.append(.init(title: "Compress…", enabled: pages, action: .sheet(.compress), dividerBefore: true))
        // A restricted file says why Clean Metadata is off in the item itself, kept short because a
        // menu row doesn't wrap.
        out.append(.init(title: tools.encryption == .restrictedOnly ? EditorPDFTools.metadataEncryptedReason
                                                                     : "Clean Metadata…",
                         enabled: tools.offersMetadata && idle, action: .sheet(.metadata)))
        if tools.offersRemovePassword {
            out.append(.init(title: "Remove Password…", enabled: idle, action: .sheet(.removePassword),
                             dividerBefore: true))
        } else {
            out.append(.init(title: "Protect with Password…", enabled: tools.offersProtect && idle,
                             action: .sheet(.protect), dividerBefore: true))
        }
        // The reorder bar's rule: shown while there is a dragged order and the file takes page tools.
        if tools.arrangement != nil, tools.offersPageTools {
            out.append(.init(title: "Save Reordered Copy", enabled: idle, action: .saveArrangement,
                             dividerBefore: true))
            out.append(.init(title: "Reset Page Order", enabled: idle, action: .resetArrangement))
        }
        return out
    }
}

/// The menu's items, drawn from ``EditorPDFToolsMenuEntry/entries(_:)``: the same view in the
/// header's Tools menu and in File ▸ PDF Tools.
public struct EditorPDFToolsMenuItems: View {
    @ObservedObject var tools: EditorPDFTools

    public init(tools: EditorPDFTools) {
        self.tools = tools
    }

    public var body: some View {
        let groups = Self.groups(EditorPDFToolsMenuEntry.entries(tools))
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            if let submenu = group.submenu {
                Menu(submenu) {
                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, entry in item(entry) }
                }
                .disabled(!group.items.contains(where: \.enabled))
            } else {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, entry in
                    if entry.dividerBefore { Divider() }
                    item(entry)
                }
            }
        }
    }

    /// Top-level lines and submenus, in the order the entries first name them.
    public static func groups(_ entries: [EditorPDFToolsMenuEntry])
        -> [(submenu: String?, items: [EditorPDFToolsMenuEntry])] {
        entries.reduce(into: []) { groups, entry in
            if let submenu = entry.submenu, let at = groups.firstIndex(where: { $0.submenu == submenu }) {
                groups[at].items.append(entry)
            } else {
                groups.append((entry.submenu, [entry]))
            }
        }
    }

    @ViewBuilder
    private func item(_ entry: EditorPDFToolsMenuEntry) -> some View {
        switch entry.action {
        case .none:
            Text(entry.title)
        case .run(let tool):
            Button(entry.title) { Task { await tools.run(tool) } }.disabled(!entry.enabled)
        case .sheet(let sheet):
            Button(entry.title) { tools.sheet = sheet }.disabled(!entry.enabled)
        case .saveArrangement:
            Button(entry.title) { Task { await tools.saveArrangement() } }.disabled(!entry.enabled)
        case .resetArrangement:
            Button(entry.title) { tools.resetArrangement() }.disabled(!entry.enabled)
        }
    }
}

/// What the tools are doing or did, across the top of the PDF card: a run in flight with Stop (for
/// runs no sheet shows, such as Rotate and Save Reordered Copy), or the last run's word, with Open
/// in Edit and Reveal in Browse for a copy. A pane-launched run's ending (``PaneToolResult``) offers
/// the same doors in the same order. ``EditorDiskBannerView``'s shape: the sentence wraps rather
/// than truncates, and the buttons go under it in a narrow column.
struct EditorPDFToolBannerView: View {
    @ObservedObject var tools: EditorPDFTools
    let accent: Color

    var body: some View {
        if let running = tools.running, tools.sheet == nil {
            Self.strip(symbol: nil, tint: accent, message: Self.runningMessage(running, progress: tools.progress)) {
                Button("Stop") { tools.cancelRun() }
                    .controlSize(.small)
                    .help("Stop — nothing is written")
            }
        } else if let banner = tools.banner {
            Self.strip(symbol: Self.symbol(banner.kind), tint: banner.kind == .failure ? .red : accent,
                  message: banner.message) {
                if case .wrote(let path) = banner.kind {
                    Button("Open in Edit") { tools.follow(path) { tools.host.open($0) } }
                        .controlSize(.small)
                        .help("Open the copy in Edit")
                    Button("Reveal in Browse") { tools.follow(path) { tools.host.reveal($0) } }
                        .controlSize(.small)
                        .help("Show the copy in Browse")
                }
                // A file only in the cloud now: fetched here, not from a file pane's menu.
                if let path = banner.download {
                    Button(EditorPDFTools.downloadTitle) {
                        tools.banner = nil
                        tools.host.download(path)
                    }
                    .controlSize(.small)
                    .help(EditorPDFTools.downloadHelp)
                }
                Button {
                    tools.banner = nil
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.hoverAffordance(.glyph, tint: accent))
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
        }
    }

    /// The strip itself: the run's message and its buttons.
    static func strip<Buttons: View>(symbol: String?, tint: Color, message: String,
                                     @ViewBuilder buttons: () -> Buttons) -> some View {
        let sentence = HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(message)
                .scaledFont(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        let row = HStack(spacing: 6) { buttons() }.fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                sentence
                Spacer(minLength: 8)
                row
            }
            VStack(alignment: .leading, spacing: 6) {
                sentence
                row
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .accessibilityElement(children: .contain)
    }

    /// "Compressing — page 4 of 12". Until its lane turn begins, a run says it is waiting behind
    /// other PDF work; after, tools that report no pages say only what they are doing.
    static func runningMessage(_ running: EditorPDFTools.Running, progress: EditorPDFTools.Progress?) -> String {
        guard running.started else { return "\(running.sentence) — \(waitingWords)" }
        guard running.reportsProgress, let progress, progress.total > 0 else { return "\(running.sentence)…" }
        return "\(running.sentence) — page \(progress.page) of \(progress.total)"
    }

    /// Find's words for the same wait (``EditorPDFFind/waitingCaption``), in the middle of a sentence.
    static let waitingWords = "waiting for other PDF work…"

    static func symbol(_ kind: EditorPDFToolBanner.Kind) -> String {
        switch kind {
        case .wrote, .wroteSeveral: return "checkmark.circle.fill"
        case .note: return "info.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }
}

extension EditorPDFTools {
    /// The banner's door to a copy, or, when it is gone (trashed, moved), a banner saying so instead
    /// of a door that silently does nothing.
    func follow(_ path: String, _ door: (String) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else {
            banner = EditorPDFToolBanner(
                message: "“\((path as NSString).lastPathComponent)” is no longer there — it was moved or deleted.",
                kind: .note)
            return
        }
        door(path)
    }
}
