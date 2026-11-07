import SwiftUI
import Design

/// The inline row ⌘N opens. Like New Folder, nothing exists on disk until Return.
///
/// Drawn in the rail's files list while the rail is on screen, and at the top of the document
/// column while it isn't, so ⌘N always lands somewhere visible; never both. It carries its own
/// focus handling so it opens focused in either home.
///
/// **Not wrapped in a `GeometryReader`**, here or at either call site: one around the rail
/// collapses its intrinsic height to 10pt.
struct EditorNamingRow: View {

    /// Whether the row is showing. A binding, because Esc closes it from in here and ⌘N opens it
    /// from outside, even from another workspace.
    @Binding var isNaming: Bool
    /// The name being typed, held by the host (``EditorFileRailView/typedName``).
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
    /// Commits a name. Returns `false` when the file was not created after all
    /// (``EditorFileRailView/onCreate``).
    let onCreate: (String) -> Bool
    /// Where the file will be created, for a caption beside the field, or `nil` where the screen
    /// already names the folder: the rail passes `nil`, since its folder line is just above; the
    /// document column passes the folder.
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
                        // `refusal(typedName)` again, not the captured `hint`, which was computed
                        // a keystroke or more ago: Return must check the string it creates.
                        guard refusal(typedName) == nil else { return }
                        // The row closes only once the file exists: a save prompt in between can
                        // be cancelled, and the typed name must survive that.
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
        // `initial: true` is the whole ⌘N-from-elsewhere path: the row doesn't exist until
        // `isNaming` is already true, so without it the row would appear empty and unfocused.
        .onChange(of: isNaming, initial: true) { _, naming in
            // Prefilled as it opens, not held between openings: the first free `Untitled` can
            // change while the row is closed, and a stale prefill could collide.
            guard naming else { return }
            if typedName.isEmpty { typedName = prefilledName() }
            nameFieldFocused = true
        }
        .onChange(of: namingFocus) { _, _ in
            guard isNaming else { return }
            nameFieldFocused = true
        }
    }

    /// Shuts the row and forgets what was typed, on Esc only. A row abandoned by clicking elsewhere
    /// keeps its text, since the next ⌘N is more likely a return to it than a fresh start.
    private func cancelNaming() {
        typedName = ""
        isNaming = false
    }
}
