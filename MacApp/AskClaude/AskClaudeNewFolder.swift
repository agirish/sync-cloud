import SwiftUI
import Sync

/// A new folder on Ask Claude's filing cards (TE327): named like its siblings, made on the same
/// card as the move. Its own views, hooked into the panel by one line each.
enum AskClaudeNewFolderButtons {

    /// Go to Folder, or for a folder not made yet, Go to the folder it would be made in.
    static func goTo(_ folder: AskClaudeFilingCard.Folder, action: @escaping (String) -> Void) -> some View {
        let isNew = folder.isNew == true
        let parent = (folder.path as NSString).deletingLastPathComponent
        return Button(isNew ? "Go to \((parent as NSString).lastPathComponent)" : "Go to Folder") {
            action(isNew ? parent : folder.path)
        }
        .controlSize(.small)
        .help(isNew ? "Shows the folder it would be made in. Nothing is made or moved." : "Shows this folder in Browse. Nothing is moved.")
    }
}

/// Rename… for a new folder in a card row's details: Return keeps the name, Esc puts it back.
struct AskClaudeNewFolderNameField: View {
    let name: String
    let onRename: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            VStack(alignment: .leading, spacing: 3) {
                TextField("Folder name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(keep)
                    .onExitCommand { editing = false }
                    .accessibilityLabel("New folder name")
                if let problem = AskClaudePlan.folderNameProblem(draft) {
                    Text(problem).scaledFont(.footnote).foregroundStyle(.orange)
                } else {
                    Text("Return keeps it; Esc puts it back. Its files follow the new name.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
            }
            .onAppear { focused = true }
        } else {
            Button("Rename…") {
                draft = name
                editing = true
            }
            .controlSize(.small)
            .help("Names the new folder before it’s made. Its files follow the new name.")
        }
    }

    private func keep() {
        guard AskClaudePlan.folderNameProblem(draft) == nil else { return }
        editing = false
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) != name { onRename(draft) }
    }
}
