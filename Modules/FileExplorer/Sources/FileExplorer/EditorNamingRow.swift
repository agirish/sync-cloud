import SwiftUI
import Design

/// The inline row ⌘N opens — the same bargain New Folder strikes: the field opens, and nothing
/// exists on disk until Return.
///
/// **One row, two homes.** It is drawn in the rail's files list while the rail is on screen, and at
/// the top of the document column while it is not — the source pane is open, or "Just the text" is
/// on — because ⌘N still has to land somewhere the user can see. The two never both draw it: the
/// rail is not drawn when the column draws it. Extracted from the rail with its focus handling,
/// because a row drawn in the column with those left behind in the rail opened unfocused and empty.
///
/// **Not wrapped in a `GeometryReader`**, here or at either call site: one around the rail once
/// collapsed its intrinsic height to 10pt (see ``EditorFileRailView/outlineHeight``).
struct EditorNamingRow: View {

    /// Whether the row is showing. A binding, because Esc closes it from in here and ⌘N opens it
    /// from outside — from another workspace, even.
    @Binding var isNaming: Bool
    /// The name being typed. Held by the host — see ``EditorFileRailView/typedName``.
    @Binding var typedName: String
    /// A counter the host bumps on every ⌘N, so a row that is already open still takes focus.
    /// See ``EditorFileRailView/namingFocus``.
    var namingFocus: Int = 0
    let accent: Color
    /// The name the row is prefilled with when it opens. A closure, for the reason
    /// ``EditorFileRailView/prefilledName`` is one.
    let prefilledName: () -> String
    /// Why the typed name cannot be used, asked as the user types.
    let refusal: (String) -> String?
    /// Commits a name. Returns `false` when the file was not created after all — see
    /// ``EditorFileRailView/onCreate``.
    let onCreate: (String) -> Bool
    /// Where the file will be created, for a caption beside the field — or `nil` where something
    /// else on screen already names the folder. The rail passes `nil`: its folder line is directly
    /// above. The document column passes the folder, because nothing else in that column says
    /// where ⌘N is about to write.
    var folderName: String? = nil

    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        let hint = refusal(typedName)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Name", text: $typedName)
                    .textFieldStyle(.plain)
                    .scaledFont(.system(size: 12))
                    .focused($nameFieldFocused)
                    .onSubmit {
                        // **`refusal(typedName)` again, not the captured `hint`.** That value was
                        // computed when this body was built; the field has been typed into since,
                        // and a Return that validates one string while creating another is how a
                        // name gets past a check that was looking at the previous keystroke.
                        guard refusal(typedName) == nil else { return }
                        // **The row closes only once the file exists.** It used to close first and
                        // create second, so a prompt raised in between — "save your changes to the
                        // document you are leaving?" — could be cancelled, and the effect of
                        // answering Cancel to a question about one file was that the name typed for
                        // another was gone, with nothing on screen to say so.
                        if onCreate(typedName) {
                            typedName = ""
                            isNaming = false
                        }
                    }
                    .onExitCommand { cancelNaming() }
                if let folderName, !folderName.isEmpty {
                    Text("New text file in \(folderName)")
                        .scaledFont(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("New text file in \(folderName)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .fill(accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: Radius.control)
                .stroke(accent.opacity(0.5), lineWidth: 1))
            if let hint {
                Text(hint)
                    .scaledFont(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        // **`initial: true`, and that is the whole ⌘N-from-elsewhere path.** This row does not exist
        // until `isNaming` is already true — from another workspace, or from a rail that was not
        // drawn — so without `initial:` the change never happened as far as this modifier is
        // concerned, and the row appeared with an empty field, no focus, and a "Type a name for
        // the file." hint under it.
        .onChange(of: isNaming, initial: true) { _, naming in
            // Prefilled at the moment it opens, not held between openings: the first free
            // `Untitled` can change while the row is closed, and a stale prefill would land the
            // user on a name that now collides.
            guard naming else { return }
            if typedName.isEmpty { typedName = prefilledName() }
            nameFieldFocused = true
        }
        .onChange(of: namingFocus) { _, _ in
            guard isNaming else { return }
            nameFieldFocused = true
        }
    }

    /// Shuts the row and forgets what was typed. Esc, and nothing else — a row abandoned by
    /// clicking elsewhere keeps its text, because the next ⌘N is more likely to be a return to it
    /// than a fresh start.
    private func cancelNaming() {
        typedName = ""
        isNaming = false
    }
}
