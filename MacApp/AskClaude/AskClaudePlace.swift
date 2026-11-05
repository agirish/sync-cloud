import SwiftUI
import Design

/// The folder Claude sees: the one the next question describes. The header names it under the
/// title; the shield's popover gives its whole path and every privacy control.
struct AskClaudePlace: Equatable {
    var source: String
    /// Relative to the source; empty at its top.
    var folder: String
    var itemCount: Int?
    var isHidden: Bool
    /// In a folder shared without asking; never while hidden.
    var isShared = false
    /// Whether the pane showing it is on screen. Go to This Folder is for when it isn't: Edit and
    /// Organize can fold their file pane away.
    var isOnScreen: Bool
    /// Where Go to This Folder shows it: "Browse", "Compare", "Organize" or "Edit".
    var workspace: String
    /// The file open in Edit, when that is what's on screen.
    var openFile: String?

    private var parts: [String] { folder.split(separator: "/").map(String.init) }

    /// The folder's own name; the source's at its top.
    var name: String { parts.last ?? source }

    /// The way down to it: "iCloud › Documents › Immigration".
    var trail: String { ([source] + parts.dropLast()).joined(separator: " › ") }

    var fullPath: String { ([source] + parts).joined(separator: " › ") }

    var count: String? { itemCount.map { "\($0) item\($0 == 1 ? "" : "s")" } }

    /// Under the header's title: "iCloud › …/H-1B/2019-2022 · 2 items".
    var subtitle: String {
        if let openFile { return "Editing \(openFile)" }
        let path = parts.count > 2 ? "\(source) › …/" + parts.suffix(2).joined(separator: "/") : fullPath
        return [path, isHidden ? "hidden from Claude" : count].compactMap { $0 }.joined(separator: " · ")
    }

    var access: AskClaudeFolderAccess { isHidden ? .hide : isShared ? .share : .ask }
}

/// What Claude gets from a folder: asked each time, shared without asking, or hidden. Whole
/// documents always ask.
enum AskClaudeFolderAccess: CaseIterable {
    case ask, share, hide

    var title: String {
        switch self {
        case .ask: "Ask Each Time"
        case .share: "Share Without Asking"
        case .hide: "Hide from Claude"
        }
    }

    var caption: String {
        switch self {
        case .ask: "A card before anything from a file goes"
        case .share: "Answers, page text, search names and lookups go without a card. Whole documents still ask"
        case .hide: "Not even the names"
        }
    }
}

/// The shield's popover: the folder, then going to it, hiding it, and what Claude may read.
struct AskClaudePlaceMenu: View {
    let place: AskClaudePlace
    let spent: String
    let accentFill: Color
    let onAccent: Color
    let onGoTo: () -> Void
    let onSetAccess: (AskClaudeFolderAccess) -> Void
    let onEditHiddenList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            heading
            Divider().padding(.vertical, 2)
            AskClaudeMenuRow(title: "Go to This Folder", detail: "in \(place.workspace)", accentFill: accentFill, onAccent: onAccent,
                             action: onGoTo)
                .disabled(place.isOnScreen)
                .help(place.isOnScreen ? "You’re already in this folder." : "Shows this folder in \(place.workspace).")
            Divider().padding(.vertical, 2)
            Text("What Claude gets from this folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ForEach(AskClaudeFolderAccess.allCases, id: \.self) { access in
                AskClaudeAccessRow(access: access, isOn: place.access == access, accentFill: accentFill, onAccent: onAccent) {
                    if place.access != access { onSetAccess(access) }
                }
            }
            AskClaudeMenuRow(title: "Edit Folder Settings…", accentFill: accentFill, onAccent: onAccent, action: onEditHiddenList)
            Divider().padding(.vertical, 2)
            HStack {
                Text("This month")
                Spacer()
                Text(spent).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .help("Spent on Ask Claude this month, of the monthly limit in Settings ▸ Intelligence")
        }
        .font(.callout)
        .padding(6)
        .frame(width: 280)
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: place.isHidden ? "eye.slash" : "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accentFill)
                .frame(width: 26, height: 26)
                .background(accentFill.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.control))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(place.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let count = place.count { Text(count).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                if place.name != place.source {
                    Text(place.trail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if place.isHidden {
                    Text("Hidden from Claude: it sees only that something is here.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A row of the popover that reads like a menu item: lit under the pointer, dimmed when off.
/// One choice of what Claude gets from the folder: a tick on the one in force, and its caption.
private struct AskClaudeAccessRow: View {
    let access: AskClaudeFolderAccess
    let isOn: Bool
    let accentFill: Color
    let onAccent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isOn ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(access.title)
                    Text(access.caption)
                        .font(.caption)
                        .opacity(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(hovering ? AnyShapeStyle(onAccent) : AnyShapeStyle(.primary))
            .background(hovering ? AnyShapeStyle(accentFill) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct AskClaudeMenuRow: View {
    let title: String
    var detail: String? = nil
    let accentFill: Color
    let onAccent: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if let detail { Text(detail).opacity(0.75) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(lit ? AnyShapeStyle(onAccent) : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .background(lit ? AnyShapeStyle(accentFill) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var lit: Bool { hovering && isEnabled }
}
