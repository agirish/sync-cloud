import SwiftUI
import Design
import Sync

/// Names made from inside files on Ask Claude's filing cards (TE328). Their own views, hooked into
/// the panel by one line each.

/// Under a row on a card: the old name and where the new one's style came from, or why the file
/// keeps its name.
struct AskClaudeRowNameLine: View {
    let row: AskClaudePlan.Row

    var body: some View {
        if row.newName != nil || row.nameKept != nil {
            VStack(alignment: .leading, spacing: 1) {
                if row.newName != nil {
                    (Text("Was ") + Text(row.name).strikethrough()).lineLimit(1).truncationMode(.middle)
                    if let basis = row.nameBasis { Text(basis).foregroundStyle(.purple).lineLimit(2) }
                } else if let kept = row.nameKept {
                    Text(kept).lineLimit(2)
                }
            }
            .scaledFont(.footnote).foregroundStyle(.secondary)
            .padding(.leading, 47)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// In a row's details: the name it lands under, editable; Keep puts its own name back.
struct AskClaudeNameDetails: View {
    let row: AskClaudePlan.Row
    let editable: Bool
    /// The typed name, or nil to keep its own.
    let onName: (String?) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var ext: String {
        guard case .move(let from, _) = row.change else { return "" }
        return (from as NSString).pathExtension
    }

    var body: some View {
        if case .move = row.change, row.newName != nil || row.nameKept != nil || editable {
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    HStack(spacing: 2) {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit(save)
                            .onExitCommand { editing = false }
                            .accessibilityLabel("New name, without .\(ext)")
                        if !ext.isEmpty { Text(".\(ext)").scaledFont(.callout).foregroundStyle(.secondary) }
                    }
                    if let problem = ContentName.stemProblem(draft) {
                        Text(problem).scaledFont(.footnote).foregroundStyle(.orange)
                    } else {
                        Text("Return keeps it; Esc puts it back.").scaledFont(.footnote).foregroundStyle(.secondary)
                    }
                } else if editable {
                    HStack(spacing: 6) {
                        Button(row.newName == nil ? "Name It…" : "Rename…") {
                            draft = ((row.newName ?? row.name) as NSString).deletingPathExtension
                            editing = true
                        }
                        .help("Names the file before it moves. Nothing changes until you click Apply.")
                        if row.newName != nil {
                            Button("Keep \(row.name)") { onName(nil) }
                                .help("Moves it under its own name.")
                        }
                    }
                    .controlSize(.small)
                }
            }
            .onChange(of: editing) { _, now in if now { focused = true } }
        }
    }

    private func save() {
        guard ContentName.stemProblem(draft) == nil else { return }
        editing = false
        onName(draft)
    }
}

/// Under a folder on filing help's card: the name the file takes there.
struct AskClaudeFolderNameLine: View {
    let folder: AskClaudeFilingCard.Folder

    var body: some View {
        if let name = folder.newName {
            VStack(alignment: .leading, spacing: 1) {
                Text("As \(name)").scaledFont(.callout)
                    .lineLimit(1).truncationMode(.middle)
                if let basis = folder.nameBasis {
                    Text(basis).scaledFont(.footnote).foregroundStyle(.purple).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

/// The card's strip: who has the new names, and Share Names and Folders while Claude hasn't.
struct AskClaudeHeldNamesStrip: View {
    let names: AskClaudeHeldNames
    /// The card's new names.
    let count: Int
    /// The card can still share (it's proposed).
    let canShare: Bool
    let onShare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let off = names.unavailable {
                Label(off, systemImage: "info.circle").foregroundStyle(.orange)
            }
            if count > 0 {
                Label {
                    Text(names.line(count))
                } icon: {
                    Image(systemName: names.sharedBy != nil ? "lock.open" : names.shared ? "checkmark.circle" : "lock")
                        .foregroundStyle(names.shared ? AnyShapeStyle(.secondary) : AnyShapeStyle(.purple))
                }
                .foregroundStyle(names.shared ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if !names.shared {
                    Text(AskClaudeHeldNames.foot).scaledFont(.footnote).foregroundStyle(.secondary)
                    if canShare {
                        Button(AskClaudeHeldNames.shareButton(count), action: onShare)
                            .controlSize(.small)
                            .help("Claude gets each new name and its folder with your next question, and nothing else from the files.")
                    }
                }
            }
        }
        .scaledFont(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
